import AppKit

/// Click-to-record shortcut field, mimicking the standard recorder look:
///  • unset     — secondary placeholder text (a suggested chord, or "Record Shortcut")
///  • set       — the chord's glyph string plus a small ✕ clear affordance
///  • recording — highlighted bezel, "Type shortcut…", Esc cancels, ⌫ clears
///
/// While recording, the app's registered hotkeys are paused (via HotkeyManagerHolder)
/// so typing a chord can't trigger the action it's replacing, and a local event monitor
/// swallows the keystrokes. A chord must include ≥1 of ⌃⌥⇧⌘ unless the key is an F-key
/// (the convention MASShortcut/KeyboardShortcuts established) — except when
/// `allowsBareShortcuts` is set, which lifts that requirement and additionally captures
/// modifier-only chords (bare ⌃, ⌃⌘, up to ⌃⌥⇧⌘) on modifier release.
final class ShortcutRecorderView: NSView {
    var spec: ShortcutSpec? {
        didSet { needsDisplay = true; clearButton.isHidden = (spec == nil || recording) }
    }
    /// Accept single unmodified keys and modifier-only chords (used by the hold-to-show
    /// switcher rows, where "held" can sensibly mean just a modifier). Off by default:
    /// press-triggered actions keep the ≥1-modifier convention.
    var allowsBareShortcuts = false
    /// Capture a modifier set (peak held set, accepted on first modifier release) OR a
    /// chord with a real key — used by the hold-switcher and Caps-Lock-mapping wells.
    var capturesModifiersOnly = false
    /// Strict wells (Caps Lock mapping): real keys beep instead of recording — a layer
    /// key there could swallow ordinary typing system-wide.
    var rejectsRealKeys = false
    /// Dim + ignore clicks (the scheme's wells while the scheme is off).
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            if !isEnabled { endRecording() }
        }
    }
    /// Called with the new binding (nil = cleared) after recording ends.
    var onChange: ((ShortcutSpec?) -> Void)?
    /// Returns conflict warnings for a candidate chord; rendered by the owning row.
    var validate: ((ShortcutSpec) -> [ConflictChecker.Conflict])?
    /// Called with the conflicts for a just-accepted chord ([] = clean) so the owning
    /// row can show/hide its warning label. Non-blocking — the binding is kept.
    var onConflicts: (([ConflictChecker.Conflict]) -> Void)?
    /// Placeholder shown while unset (e.g. the tiling-convention suggestion "⌥3").
    var placeholder: String = "Record Shortcut" {
        didSet { needsDisplay = true }
    }

    private var recording = false
    private var monitor: Any?
    /// Caps-as-hyper engages without any flagsChanged; CapsLockHyper notifies instead.
    private var hyperHeld = false
    private var hyperObserver: NSObjectProtocol?
    /// While recording with `allowsBareShortcuts`: the largest modifier set held so far
    /// in the current press. The first release accepts it as a modifier-only chord.
    private var pendingModifiers: UInt = 0
    private let clearButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clearButton.bezelStyle = .circular
        clearButton.isBordered = false
        clearButton.title = ""
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Clear shortcut")
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                   : NSColor.controlBackgroundColor).setFill()
        bezel.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        bezel.lineWidth = recording ? 1.5 : 1
        bezel.stroke()

        let font = NSFont.systemFont(ofSize: 12)
        let line = NSMutableAttributedString()
        func run(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text,
                                           attributes: [.font: font, .foregroundColor: color]))
        }
        if recording {
            if capturesModifiersOnly {
                run(rejectsRealKeys ? "Hold modifiers…" : "Modifiers or key…", .secondaryLabelColor)
            } else {
                run(allowsBareShortcuts ? "Key or modifiers…" : "Type shortcut…", .secondaryLabelColor)
            }
        } else if let spec {
            run(spec.displayString, .labelColor)
        } else {
            run(placeholder, .tertiaryLabelColor)
        }
        let size = line.size()
        line.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }

    // MARK: - Recording lifecycle

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if recording { endRecording() } else { beginRecording() }
    }

    private func beginRecording() {
        guard !recording else { return }
        recording = true
        clearButton.isHidden = true
        window?.makeFirstResponder(self)
        HotkeyManagerHolder.shared?.pauseForRecording()
        pendingModifiers = 0
        hyperHeld = false
        hyperObserver = NotificationCenter.default.addObserver(
            forName: .speedySpacesHyperKeyChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, self.recording,
                  self.allowsBareShortcuts || self.capturesModifiersOnly,
                  let down = note.userInfo?["down"] as? Bool else { return }
            self.hyperHeld = down
            self.handleModifierState(ShortcutSpec.sanitize(NSEvent.modifierFlags)
                                     | (down ? CapsLockHyper.hyperNSModifiers : 0))
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .flagsChanged {                // swallow; chord lands on keyDown…
                self.handleFlagsChanged(event)              // …unless it's modifiers alone
                return nil
            }
            self.handleRecorded(event)
            return nil
        }
        needsDisplay = true
    }

    private func handleRecorded(_ event: NSEvent) {
        let mods = ShortcutSpec.sanitize(event.modifierFlags)
        switch (event.keyCode, mods) {
        case (53, 0):                       // bare Esc — cancel
            endRecording()
            return
        case (51, 0):                       // bare Delete — clear the binding
            spec = nil
            onChange?(nil)
            onConflicts?([])
            endRecording()
            return
        default:
            break
        }
        if capturesModifiersOnly && rejectsRealKeys {
            NSSound.beep()   // this well takes modifiers only
            return
        }
        let candidate = ShortcutSpec(keyCode: event.keyCode, modifiers: mods)
        let isFKey = ShortcutSpec.specialKeyNames[event.keyCode]?.hasPrefix("F") == true
            && Int(ShortcutSpec.specialKeyNames[event.keyCode]?.dropFirst() ?? "") != nil
        guard mods != 0 || isFKey || allowsBareShortcuts || capturesModifiersOnly else {
            NSSound.beep()                  // modifier-less chords can't be global hotkeys
            return
        }
        accept(candidate)
    }

    /// Modifier-only capture: while the held set grows (⌃ → ⌃⌘ → …) keep tracking; the
    /// first release accepts the peak set as the chord. A keyDown in between routes
    /// through handleRecorded instead, which ends recording before any release arrives.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard allowsBareShortcuts || capturesModifiersOnly else { return }
        handleModifierState(ShortcutSpec.sanitize(event.modifierFlags)
                            | (hyperHeld ? CapsLockHyper.hyperNSModifiers : 0))
    }

    private func handleModifierState(_ raw: UInt) {
        let mods = raw
        if mods & ~pendingModifiers != 0 || mods == pendingModifiers {
            pendingModifiers |= mods
        } else if pendingModifiers != 0 {
            accept(ShortcutSpec(keyCode: ShortcutSpec.noKeyCode, modifiers: pendingModifiers))
        }
    }

    private func accept(_ candidate: ShortcutSpec) {
        spec = candidate
        onChange?(candidate)
        onConflicts?(validate?(candidate) ?? [])
        endRecording()
    }

    private func endRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let hyperObserver { NotificationCenter.default.removeObserver(hyperObserver); self.hyperObserver = nil }
        hyperHeld = false
        HotkeyManagerHolder.shared?.resumeAfterRecording()
        clearButton.isHidden = (spec == nil)
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        // Clicking anywhere else concludes the recording session.
        DispatchQueue.main.async { [weak self] in self?.endRecording() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endRecording() }
    }

    @objc private func clearPressed() {
        spec = nil
        onChange?(nil)
        onConflicts?([])
    }
}

/// Weak global handle so recorder controls (buried in Settings rows) can pause hotkey
/// registration during capture without threading the manager through every initializer.
enum HotkeyManagerHolder { static weak var shared: HotkeyManager? }

extension ConflictChecker {
    /// Assemble the full conflict list for a candidate chord: every other app-owned
    /// binding, the DERIVED move-window chords (native switch chord + extra modifier),
    /// every other space's binding, and the user's enabled macOS Mission Control
    /// shortcuts. `excludingAction`/`excludingUUID` suppress the row being edited.
    /// Switching actions are macOS-owned (they appear via `system:` below), so they're
    /// skipped here.
    static func hotkeyConflicts(for spec: ShortcutSpec,
                                excludingAction: HotkeyAction? = nil,
                                excludingUUID: String? = nil) -> [Conflict] {
        var own: [(label: String, spec: ShortcutSpec)] = []
        for action in HotkeyAction.allCases where action != excludingAction {
            switch HotkeyManager.trigger(for: action) {
            case .native:
                continue   // the native chord itself is compared via `system:`
            case .move:
                let s = Prefs.moveExtraModifierEnabled
                    ? HotkeyManager.moveChord(for: action) : Prefs.hotkey(for: action)
                if let s { own.append((action.label, s)) }
            case .app, .holdSwitcher:
                if let s = Prefs.hotkey(for: action) { own.append((action.label, s)) }
            }
        }
        if let store = MetadataStoreHolder.shared {
            for (uuid, meta) in store.entries where uuid != excludingUUID {
                if let s = meta.shortcut {
                    own.append(("the space “\(meta.name ?? "unnamed")”", s))
                }
            }
        }
        return conflicts(spec, own: own, system: SystemShortcuts.missionControlBindings())
    }
}
