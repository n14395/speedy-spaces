import AppKit

/// Owns the menubar status item and builds the dynamic Spaces menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let spaces: SpacesManager
    private let store: MetadataStore
    private let menu = NSMenu()
    private let strip = MenuBarStripView()
    private var editor: SpaceEditorController?
    /// In-flight "switch to the space, then open its editor" request (see presentEditor).
    private var pendingEditorObserver: NSObjectProtocol?
    private var pendingEditorBackstop: DispatchWorkItem?
    private var settings: SettingsController?

    init(spaces: SpacesManager, store: MetadataStore) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.spaces = spaces
        self.store = store
        super.init()

        menu.delegate = self
        // Custom-view space rows carry no action selector; without this the menu's
        // auto-enable would disable them (a disabled item doesn't receive clicks).
        // Disabled display headers still work because they set isEnabled = false.
        menu.autoenablesItems = false
        // The menu is shown on demand (see openMenu), not bound to the status item, so a left-click
        // on a non-current numbered square can switch to that space instead of opening the menu.

        if let button = statusItem.button {
            strip.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                strip.topAnchor.constraint(equalTo: button.topAnchor),
                strip.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            strip.onSelect = { [weak self] uuid in self?.switchTo(uuid: uuid) }
            strip.onOpenMenu = { [weak self] in self?.openMenu() }
        }

        spaces.onChange = { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged),
            name: .speedySpacesPrefsChanged, object: nil
        )
        updateStatusItem()
        spaces.onAccessibilityNeeded = { [weak self] in self?.presentAccessibilityHelp() }
    }

    @objc private func prefsChanged() { updateStatusItem() }

    // MARK: - Title/label for a space

    private func title(for space: Space) -> String {
        space.displayTitle(using: store)
    }

    // MARK: - Menubar item (the composable strip)

    /// Rebuild the strip from the current prefs, and resize the item. Following the
    /// focused display shows that display's spaces; otherwise the strip carries EVERY
    /// display's spaces (grouped, each with its own current marked) instead of pinning
    /// to whichever display enumerates first.
    private func updateStatusItem() {
        guard statusItem.button != nil else { return }
        let displaySpaces: [Space]
        if Prefs.menuBarFollowsFocusedDisplay {
            displaySpaces = spaces.focusedDisplaySpaces().spaces
        } else {
            displaySpaces = Self.visibleSpaces(
                spaces.spaces,
                hideSingleSpaceDisplays: Prefs.menuBarHideSingleSpaceDisplays,
                collapseUnfocused: Prefs.menuBarCollapseUnfocusedDisplays,
                focusedDisplayIndex: (Prefs.menuBarCollapseUnfocusedDisplays
                    ? spaces.focusedDisplayIndex() : nil) ?? -1)
        }
        strip.update(
            displaySpaces: displaySpaces,
            currentUUIDs: Set(displaySpaces.filter(\.isCurrent).map(\.uuid)),
            showIcon: Prefs.menuBarShowIcon,
            showName: Prefs.menuBarShowName,
            showNumber: Prefs.menuBarShowNumber,
            showSwitcher: Prefs.menuBarShowSwitcher,
            title: { [weak self] in self?.title(for: $0) ?? "" },
            icon: { [weak self] space in
                guard let self else { return nil }
                return IconRendering.image(for: self.store.metadata(for: space.uuid), pointSize: 15)
            }
        )
        statusItem.length = strip.intrinsicContentSize.width
        // Hand the strip to AppKit as an image rather than letting the view paint the menu
        // bar directly: only images the button owns get the menu bar's vibrancy tint (which
        // pulls every native glyph toward the wallpaper's hue) and its dimming on unfocused
        // displays. Self-drawn pixels rendered at full labelColor — pure black on a light bar,
        // pure white on a tinted one — next to neighbours sitting well below full contrast.
        if let button = statusItem.button {
            button.image = strip.renderedImage()
            button.imagePosition = .imageOnly
        }
    }

    /// Pure filter for the all-displays strip: sorted by (display, ordinal), optionally
    /// dropping single-space displays and collapsing unfocused displays to their current
    /// space. Prefs injected so it is self-testable.
    static func visibleSpaces(_ spaces: [Space], hideSingleSpaceDisplays: Bool,
                              collapseUnfocused: Bool, focusedDisplayIndex: Int) -> [Space] {
        var all = spaces.sorted {
            ($0.displayIndex, $0.ordinalOnDisplay) < ($1.displayIndex, $1.ordinalOnDisplay)
        }
        if hideSingleSpaceDisplays {
            var counts: [Int: Int] = [:]
            for s in all { counts[s.displayIndex, default: 0] += 1 }
            all = all.filter { counts[$0.displayIndex, default: 0] > 1 }
        }
        if collapseUnfocused {
            all = all.filter { $0.displayIndex == focusedDisplayIndex || $0.isCurrent }
        }
        return all
    }

    static func selfChecks(_ check: SelfTest.Check) {
        func mk(_ uuid: String, disp: Int, ord: Int, cur: Bool = false) -> Space {
            Space(uuid: uuid, managedSpaceID: 0, type: 0, displayIndex: disp,
                  displayIdentifier: "d\(disp)", ordinalOnDisplay: ord, isCurrent: cur)
        }
        // Deliberately unsorted input: d1 has three spaces (B current), d2 one (X current).
        let all = [mk("C", disp: 0, ord: 2), mk("A", disp: 0, ord: 0),
                   mk("X", disp: 1, ord: 0, cur: true), mk("B", disp: 0, ord: 1, cur: true)]
        let plain = visibleSpaces(all, hideSingleSpaceDisplays: false,
                                  collapseUnfocused: false, focusedDisplayIndex: -1)
        check(plain.map(\.uuid) == ["A", "B", "C", "X"], "strip filter: sorts by display then ordinal")
        let noSingles = visibleSpaces(all, hideSingleSpaceDisplays: true,
                                      collapseUnfocused: false, focusedDisplayIndex: -1)
        check(noSingles.map(\.uuid) == ["A", "B", "C"], "strip filter: single-space display hidden")
        let collapsed = visibleSpaces(all, hideSingleSpaceDisplays: false,
                                      collapseUnfocused: true, focusedDisplayIndex: 0)
        check(collapsed.map(\.uuid) == ["A", "B", "C", "X"],
              "strip filter: collapse keeps unfocused display's current")
        let collapsedOther = visibleSpaces(all, hideSingleSpaceDisplays: false,
                                           collapseUnfocused: true, focusedDisplayIndex: 1)
        check(collapsedOther.map(\.uuid) == ["B", "X"],
              "strip filter: unfocused display reduced to its current space")
        let both = visibleSpaces(all, hideSingleSpaceDisplays: true,
                                 collapseUnfocused: true, focusedDisplayIndex: 1)
        check(both.map(\.uuid) == ["B"], "strip filter: filters compose")
    }

    /// Show the full menu on demand — a right-click anywhere, a left-click on the current
    /// segment, or the openMenu hotkey. Bound transiently so ordinary left-clicks on other
    /// squares switch instead.
    func openMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.statusItem.menu = self.menu
            button.performClick(nil)
            self.statusItem.menu = nil
        }
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        spaces.refresh()
        menu.removeAllItems()

        var lastDisplay = -1
        let multiDisplay = Set(spaces.spaces.map { $0.displayIndex }).count > 1
        let hints = spaces.spaces.map { shortcutHint(for: $0) }
        let rowWidth = SpaceMenuRowView.preferredWidth(
            forTitles: spaces.spaces.map { title(for: $0) }, hints: hints)

        let headerItem = NSMenuItem()
        headerItem.view = MenuHeaderRowView(
            width: rowWidth,
            onSettings: { [weak self] in self?.presentSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        menu.addItem(headerItem)
        if !spaces.canSwitch {
            let perm = NSMenuItem(title: "Enable Click-to-Switch…", action: #selector(enablePermission), keyEquivalent: "")
            perm.target = self
            applyIcon("accessibility", to: perm)
            menu.addItem(perm)
        }
        menu.addItem(.separator())

        // Jump-to-space search field: type to filter the rows below, Return jumps to the
        // top match. Only worthwhile past a single space. Populated after the rows exist.
        var jumpField: SpaceJumpFieldView?
        if spaces.spaces.count > 1 {
            let field = SpaceJumpFieldView(
                width: rowWidth, onJump: { [weak self] uuid in self?.switchTo(uuid: uuid) })
            let fieldItem = NSMenuItem()
            fieldItem.view = field
            menu.addItem(fieldItem)
            menu.addItem(.separator())
            jumpField = field
        }

        var candidates: [SpaceJumpFieldView.Candidate] = []
        var currentHeader: NSMenuItem?
        for (i, space) in spaces.spaces.enumerated() {
            if multiDisplay && space.displayIndex != lastDisplay {
                if lastDisplay != -1 { menu.addItem(.separator()) }
                let header = NSMenuItem(title: "Display \(space.displayIndex + 1)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastDisplay = space.displayIndex
                currentHeader = header
            }

            let uuid = space.uuid
            let rowTitle = title(for: space)
            let item = NSMenuItem()
            item.view = SpaceMenuRowView(
                icon: IconRendering.image(for: store.metadata(for: uuid), pointSize: 14),
                title: rowTitle,
                isCurrent: space.isCurrent,
                width: rowWidth,
                hint: hints[i],
                onSelect: { [weak self] in self?.switchTo(uuid: uuid) },
                onEdit: { [weak self] in self?.presentEditor(uuid: uuid) }
            )
            menu.addItem(item)
            candidates.append(SpaceJumpFieldView.Candidate(
                uuid: uuid, title: rowTitle,
                named: !(store.metadata(for: uuid).name ?? "").isEmpty,
                item: item, header: currentHeader))
        }
        jumpField?.candidates = candidates
        // Start keyboard focus on the focused display's current space, so the menu opens
        // "where you are": ↑/↓ move relative to it and Return re-selects it.
        jumpField?.initialSelectionUUID = spaces.focusedDisplaySpaces().current?.uuid
    }

    /// The chord that reaches this space directly, for the menu row's trailing hint:
    /// its per-space binding, else — for spaces on the focused display — the native
    /// "Switch to Desktop N" shortcut this app now binds the numbered switches to.
    private func shortcutHint(for space: Space) -> String? {
        if let spec = store.metadata(for: space.uuid).shortcut { return spec.displayString }
        guard let focused = spaces.focusedDisplaySpaces().current,
              focused.displayIndex == space.displayIndex else { return nil }
        let n = space.ordinalOnDisplay + 1
        guard n >= 1, n <= SystemShortcuts.maxSwitchableDesktop,
              let sc = SystemShortcuts.systemBinding(id: SystemShortcuts.desktopBaseID + n - 1)
        else { return nil }
        return ShortcutSpec(keyCode: sc.keyCode,
                            modifiers: ShortcutSpec.sanitizeRaw(UInt(sc.flags.rawValue))).displayString
    }

    /// macOS 27 hides menu-item images unless the item opts in
    /// (`preferredImageVisibility` defaults to .automatic, which typically hides them).
    private func applyIcon(_ symbolName: String, to item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }


    // MARK: - Actions

    /// Switch to the space with `uuid` (invoked by a row's body click).
    private func switchTo(uuid: String) {
        guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { return }
        spaces.switchTo(space)
    }

    /// Open the name/icon editor for `uuid` (a row's pencil affordance, the
    /// rename-current-space hotkey, or a clicked label/title — `screen` then pins the
    /// editor to the display where the click happened).
    ///
    /// The editor is an ordinary window, so it materialises on whichever space is current when
    /// it's ordered front — renaming a space you aren't standing on used to drop the panel on
    /// the wrong desktop. So land on the target space FIRST and only reveal the editor once the
    /// switch has been verified.
    func presentEditor(uuid: String, on screen: NSScreen? = nil) {
        guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { return }
        cancelPendingEditor()   // last rename request wins
        // A space belongs to exactly one display, and the editor has to open on THAT display —
        // centring it on any other screen would put it on that screen's current space, which is
        // not the space being renamed. Fall back to the caller's screen if the match fails.
        let target = displayScreen(for: space) ?? screen
        guard !space.isCurrent else { return showEditor(uuid: uuid, on: target) }

        var revealed = false
        let reveal = { [weak self] in
            guard let self, !revealed else { return }
            revealed = true
            self.cancelPendingEditor()
            self.showEditor(uuid: uuid, on: target)
        }
        // The verifier publishes exactly one outcome per switch — landed or gave up — and a
        // refused switch publishes synchronously from inside switchTo, so subscribe first.
        pendingEditorObserver = NotificationCenter.default.addObserver(
            forName: .speedySpacesSwitchOutcome, object: nil, queue: .main) { _ in reveal() }
        // Safety net so a rename the user asked for is never swallowed outright. Sized to clear
        // the slowest path that still reports: a Show-Desktop dismissal defers the real switch
        // by ~1.1 s and only then starts the verifier (whose own idle timeout is 2 s).
        let backstop = DispatchWorkItem { reveal() }
        pendingEditorBackstop = backstop
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: backstop)
        // `true` means in flight (including the deferred Show-Desktop retry) — wait for the
        // outcome. `false` is an outright refusal, already published above; don't stall on it.
        if !spaces.switchTo(space) { reveal() }
    }

    private func cancelPendingEditor() {
        if let observer = pendingEditorObserver { NotificationCenter.default.removeObserver(observer) }
        pendingEditorObserver = nil
        pendingEditorBackstop?.cancel()
        pendingEditorBackstop = nil
    }

    /// The screen a space lives on, matched through its CGS display identifier.
    private func displayScreen(for space: Space) -> NSScreen? {
        NSScreen.screens.first {
            SwitcherHUD.displayIdentifiers(for: $0).contains(space.displayIdentifier)
        }
    }

    /// Build and show the editor. Re-resolves the space so the title reflects any change the
    /// switch caused between the request and the reveal.
    private func showEditor(uuid: String, on screen: NSScreen?) {
        guard let space = spaces.spaces.first(where: { $0.uuid == uuid }) else { return }
        editor = SpaceEditorController(
            uuid: uuid,
            spaceTitle: title(for: space),
            metadata: store.metadata(for: uuid)
        ) { [weak self] newMeta in
            self?.store.set(newMeta, for: uuid)
            self?.updateStatusItem()
        }
        editor?.present(on: screen)
    }

    @objc private func enablePermission() {
        presentAccessibilityHelp()
    }

    /// Clear, opt-in Accessibility flow. Switching Spaces posts keyboard shortcuts,
    /// which macOS gates behind Accessibility access. We explain that, then (only if the
    /// user agrees) register the app with the system and open the settings pane.
    func presentAccessibilityHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow SpeedySpaces to switch Spaces"
        alert.informativeText = """
        SpeedySpaces switches desktops using the system “move between Spaces” keyboard \
        shortcuts, which macOS only permits with Accessibility access.

        Turn on SpeedySpaces under Privacy & Security → Accessibility, then quit and \
        reopen SpeedySpaces.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Registers the app in the Accessibility list (and shows the system prompt once).
        spaces.requestSwitchPermission()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Programmatic Settings entry point — the menu header's gear button and the
    /// `--show-settings` launch flag (used by headless UI verification) both land here.
    func presentSettings() {
        if settings == nil { settings = SettingsController() }
        settings?.present()
    }
}
