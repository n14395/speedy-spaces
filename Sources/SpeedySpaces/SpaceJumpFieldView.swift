import AppKit

/// A search box embedded as a custom menu-item view at the top of the status-item menu:
/// type to filter the space rows below it, ↑/↓ to move the selection through the filtered
/// list, Return to jump to the selected space, Esc to clear/close.
///
/// NSMenu runs a modal tracking loop that consumes key events before they reach any local
/// event monitor (the reason a plain field can't type here), so keystrokes are captured
/// with a CGEventTap for the duration the field is in a shown menu. The tap needs
/// Accessibility, which the app already holds for space switching; without it the field
/// still renders but can't capture (falls back to click-only rows).
final class SpaceJumpFieldView: NSView {
    /// One filterable space row.
    struct Candidate {
        let uuid: String
        let title: String
        let named: Bool
        let item: NSMenuItem
        let header: NSMenuItem?
        var row: SpaceMenuRowView? { item.view as? SpaceMenuRowView }
    }

    private let onJump: (String) -> Void
    /// Assigned by the controller after the space rows are built (they don't exist yet when
    /// this view is constructed). Setting it re-applies the current filter.
    var candidates: [Candidate] = [] { didSet { applyFilter() } }

    /// Typed state is written by the TAP-THREAD callback and read by main-thread
    /// filtering/drawing — lock-guarded. Everything else (visible/selection/rows)
    /// stays main-confined.
    private let typed = Locked<(query: String, active: Bool)>((query: "", active: false))
    private var query: String {
        get { typed.get().query }
        set { typed.withLock { $0.query = newValue } }
    }
    private var active: Bool {
        get { typed.get().active }
        set { typed.withLock { $0.active = newValue } }
    }
    private var visible: [Candidate] = []   // filtered, in menu order
    private var selection = 0               // index into `visible`
    /// The space to pre-focus when the menu opens (the focused display's current space).
    /// Set by the controller before the menu is shown; consumed once in `startCapture`.
    var initialSelectionUUID: String?
    private var tap: CFMachPort?
    private let tapRef = Locked<CFMachPort?>(nil)
    private let reviver = TapReviver("jumpField")
    private var source: CFRunLoopSource?

    private enum Metric {
        static let height: CGFloat = 30
        static let outerInset: CGFloat = 5
        static let contentPad: CGFloat = 8
        static let corner: CGFloat = 6
        static let font: CGFloat = 13
    }

    init(width: CGFloat, onJump: @escaping (String) -> Void) {
        self.onJump = onJump
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metric.height))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    // MARK: - Keystroke capture (scoped to while the menu is shown)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startCapture() } else { stopCapture() }
    }

    private func startCapture() {
        guard tap == nil else { return }
        query = ""; active = false; selection = 0
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<SpaceJumpFieldView>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            applyFilter(); needsDisplay = true; return   // no Accessibility → click-only
        }
        self.tap = tap
        tapRef.set(tap)
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = src
        // Serviced on the dedicated tap thread, which the menu's modal tracking loop
        // (and any main-thread stall) can never block.
        TapThread.add(src)
        CGEvent.tapEnable(tap: tap, enable: true)
        applyFilter()
        seedInitialSelection()
        needsDisplay = true
    }

    private func stopCapture() {
        tapRef.set(nil)
        TapTeardown.tearDown(tap: tap, source: source)
        // Clear any lingering selection highlight on the rows.
        candidates.forEach { $0.row?.setKeyboardSelected(false) }
        tap = nil; source = nil
    }

    /// CGEventTap callback body — runs on the TAP THREAD. Decides swallow-or-pass from
    /// the lock-guarded typed state only; row/selection updates are performed on the
    /// main run loop (in the menu-tracking mode, so they land while the menu is up).
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // The system disables a tap that's slow or on user input during creation — re-arm
        // (rate-limited so a wedged pipeline is never re-blocked immediately).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tapRef.get() { reviver.tapWasDisabled(tap) }
            return pass
        }
        guard type == .keyDown else { return pass }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case 126: onMain { self.moveSelection(-1) }; return nil // up
        case 125: onMain { self.moveSelection(1) }; return nil  // down
        case 36, 76: onMain { self.commit() }; return nil       // return / keypad enter
        case 53:                                                 // escape
            if query.isEmpty { return pass }                    // empty → let the menu close
            typed.set((query: "", active: false))
            onMain { self.refresh() }
            return nil
        case 51:                                                 // delete / backspace
            if query.isEmpty { return pass }
            typed.withLock {
                $0.query.removeLast()
                if $0.query.isEmpty { $0.active = false }
            }
            onMain { self.refresh() }
            return nil
        default:
            let flags = event.flags
            let hasChord = flags.contains(.maskCommand) || flags.contains(.maskControl)
                        || flags.contains(.maskAlternate)
            // CGEvent's own keyboard translation (thread-safe, unlike NSEvent bridging).
            var units = [UniChar](repeating: 0, count: 4)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: units.count,
                                           actualStringLength: &length, unicodeString: &units)
            let chars = String(utf16CodeUnits: units, count: length)
            if !hasChord, let first = chars.unicodeScalars.first,
               first.value >= 0x20, first.value != 0x7f {
                typed.withLock { $0.query.append(chars); $0.active = true }
                onMain { self.refresh() }
                return nil
            }
            return pass                                         // ⌘-keys, F-keys, etc. pass through
        }
    }

    /// Main-thread hop for UI work triggered from the tap thread, delivered in the
    /// menu-tracking run-loop mode (GCD main-queue blocks can sit out menu tracking).
    private func onMain(_ body: @escaping () -> Void) {
        MainThreadDispatch.performIncludingTracking(body)
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        active = true
        selection = max(0, min(visible.count - 1, selection + delta))
        applyHighlight()
        needsDisplay = true
    }

    /// Focus the focused display's current space when the menu opens, so ↑/↓ move relative to
    /// where you are and Return re-selects it. No-op if that space isn't in the visible list
    /// (e.g. no current space, or already filtered) — leaving the pre-key "nothing focused" state.
    private func seedInitialSelection() {
        guard let uuid = initialSelectionUUID,
              let idx = Self.initialSelectionIndex(visibleUUIDs: visible.map(\.uuid), focusedUUID: uuid)
        else { return }
        selection = idx
        active = true
        applyHighlight()
    }

    /// Index in `visibleUUIDs` to focus initially, or nil to leave the selection alone.
    static func initialSelectionIndex(visibleUUIDs: [String], focusedUUID: String?) -> Int? {
        guard let focusedUUID else { return nil }
        return visibleUUIDs.firstIndex(of: focusedUUID)
    }

    private func refresh() { applyFilter(); needsDisplay = true }

    private func commit() {
        guard visible.indices.contains(selection) else { return }
        let uuid = visible[selection].uuid
        enclosingMenuItem?.menu?.cancelTracking()
        let jump = onJump
        DispatchQueue.main.async { jump(uuid) }   // act after the tracking loop tears down
    }

    // MARK: - Filtering

    /// Hide non-matching rows, rebuild `visible` (menu order), and default the selection to
    /// the best-ranked match (exact → prefix → substring; custom names beat "Desktop N").
    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        visible.removeAll()
        for c in candidates {
            let rank = SpaceNameRanker.rank(title: c.title, query: q)
            c.item.isHidden = (rank == nil)
            if rank != nil { visible.append(c) }
        }
        // Hide a display header once all its spaces are filtered out.
        for header in Set(candidates.compactMap { $0.header }) {
            header.isHidden = candidates.filter { $0.header === header }.allSatisfy { $0.item.isHidden }
        }
        selection = SpaceNameRanker.bestIndex(
            candidates: visible.map { (title: $0.title, named: $0.named) }, query: q) ?? 0
        applyHighlight()
    }

    private func applyHighlight() {
        for (i, c) in visible.enumerated() {
            c.row?.setKeyboardSelected(active && i == selection)
        }
        // Rows filtered out shouldn't keep a stale highlight.
        let visibleUUIDs = Set(visible.map { $0.uuid })
        for c in candidates where !visibleUUIDs.contains(c.uuid) { c.row?.setKeyboardSelected(false) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: Metric.outerInset, dy: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: Metric.corner, yRadius: Metric.corner).fill()

        var textX = box.minX + Metric.contentPad
        let glyphSide: CGFloat = 13
        if let mag = SpaceJumpFieldView.magnifier {
            let r = NSRect(x: textX, y: box.midY - glyphSide / 2, width: glyphSide, height: glyphSide)
            mag.draw(in: r)
            textX = r.maxX + 5
        }

        let showPlaceholder = query.isEmpty
        let text = showPlaceholder ? "Jump to space…" : query
        let color: NSColor = showPlaceholder ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Metric.font), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let maxW = box.maxX - Metric.contentPad - textX
        (text as NSString).draw(in: NSRect(x: textX, y: box.midY - size.height / 2,
                                           width: maxW, height: size.height),
                                withAttributes: attrs)
    }

    private static let magnifier: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let base = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()

    // MARK: - Self-tests

    static func selfChecks(_ check: SelfTest.Check) {
        check(initialSelectionIndex(visibleUUIDs: ["A", "B", "C"], focusedUUID: "B") == 1,
              "jump field: initial focus lands on the focused display's current space")
        check(initialSelectionIndex(visibleUUIDs: ["A", "B", "C"], focusedUUID: "Z") == nil,
              "jump field: a focus uuid not in the list leaves the selection unseeded")
        check(initialSelectionIndex(visibleUUIDs: ["A", "B", "C"], focusedUUID: nil) == nil,
              "jump field: no focus uuid leaves the selection unseeded")
    }
}
