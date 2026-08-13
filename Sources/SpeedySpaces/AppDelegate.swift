import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var hotkeys: HotkeyManager?
    /// speedyspaces:// commands that arrived before the hotkey router existed (cold launch
    /// via URL); flushed once setup completes.
    private var pendingCommands: [String] = []
    private let spaces = SpacesManager()
    private let store = MetadataStore()
    private lazy var overlay = MissionControlOverlay(spaces: spaces, store: store)
    private let wallpaperStore = WallpaperStore()
    private lazy var switcher = SwitcherHUD(spaces: spaces, store: store,
                                            wallpapers: wallpaperStore)
    private let capsHyper = CapsLockHyper()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register the classic GURL Apple-Event handler — the reliable delivery path for a
        // custom URL scheme, including a cold launch triggered by `open speedyspaces://…`.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Modern backup path: macOS may deliver scheme URLs here instead of / in addition to
    /// the GURL Apple Event. Idempotent with the Apple-Event handler (a URL fires one or
    /// the other, not a duplicated command).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { dispatch(url: url) }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      withReplyEvent reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        dispatch(url: url)
    }

    /// Translate a speedyspaces:// URL into a canonical command and route it. Unknown URLs
    /// are ignored. `switch` takes one of name / index / uuid query items.
    private func dispatch(url: URL) {
        guard let command = Self.command(fromURL: url) else { return }
        if let hotkeys { hotkeys.runCommand(command) } else { pendingCommands.append(command) }
    }

    /// Pure URL → command-string mapping (nil = ignore). Kept static for self-tests.
    static func command(fromURL url: URL) -> String? {
        guard url.scheme == "speedyspaces" else { return nil }
        switch (url.host ?? "").lowercased() {
        case "next":            return "next"
        case "prev", "previous": return "prev"
        case "back":            return "back"
        case "switcher":        return "switcher"
        case "mission-control": return "mission-control"
        case "menu":            return "menu"
        case "settings":        return "settings"
        case "rename":          return "rename"
        case "switch":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
            }
            if let uuid = value("uuid") { return "switch:uuid:\(uuid)" }
            if let idx = value("index"), Int(idx) != nil { return "switch:index:\(idx)" }
            if let name = value("name") { return "switch:name:\(name)" }
            return nil
        default: return nil
        }
    }

    static func selfChecks(_ check: SelfTest.Check) {
        func cmd(_ s: String) -> String? { URL(string: s).flatMap { command(fromURL: $0) } }
        check(cmd("speedyspaces://next") == "next", "url: next verb")
        check(cmd("speedyspaces://Previous") == "prev", "url: previous alias, host case-insensitive")
        check(cmd("speedyspaces://switch?uuid=ABC-123") == "switch:uuid:ABC-123", "url: switch by uuid")
        check(cmd("speedyspaces://switch?index=3") == "switch:index:3", "url: switch by index")
        check(cmd("speedyspaces://switch?index=three") == nil, "url: non-numeric index rejected")
        check(cmd("speedyspaces://switch?name=Mail%20Space") == "switch:name:Mail Space",
              "url: switch by name, percent-decoded")
        check(cmd("speedyspaces://switch?uuid=U&name=N") == "switch:uuid:U", "url: uuid outranks name")
        check(cmd("speedyspaces://switch?uuid=") == nil, "url: empty value treated as absent")
        check(cmd("speedyspaces://bogus") == nil, "url: unknown verb ignored")
        check(cmd("https://next") == nil, "url: foreign scheme ignored")
        check(cmd("speedyspaces://switch") == nil, "url: switch without params ignored")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.terminateOtherInstances()  // newest launch wins — a rebuild's binary replaces a stale one
        Prefs.seedDefaultShortcutsIfNeeded()   // ship default app-owned chords before the first reload
        statusController = StatusItemController(spaces: spaces, store: store)
        if let statusController {
            hotkeys = HotkeyManager(spaces: spaces, store: store, status: statusController)
            hotkeys?.start()
        }
        // Clicking a space's title — the HUD's name/caption rows or the labels drawn
        // over Mission Control's bar — opens the same editor as the menu rows' pencil,
        // placed on the display where the click happened.
        overlay.onLabelClick = { [weak self] uuid, screen in
            self?.statusController?.presentEditor(uuid: uuid, on: screen)
        }
        switcher.onEditRequest = { [weak self] uuid, screen in
            self?.statusController?.presentEditor(uuid: uuid, on: screen)
        }
        overlay.enabled = Prefs.missionControlLabels || Prefs.thumbnailIconStyle != .hidden
        overlay.start()  // no-op if disabled; didSet only fires on later changes
        // Always on: what the switcher shows is governed entirely by the flash-on-change
        // toggle and the hold-to-show shortcut (no separate master enable).
        switcher.enabled = true
        switcher.start()
        // Stand our switch tap down while a peer (MoreCorners) drags a window
        // between spaces, so its native "Move a space" shortcut carries the
        // grabbed window instead of us swallowing it. No-op if MoreCorners is absent.
        WindowMover.startPeerMoveCoordination()
        capsHyper.apply()
        // One-time migration off the removed "Disable Native Shortcuts" feature: if it had left
        // the system Spaces shortcuts disabled, re-enable them (switching now binds to them) and
        // drop the stale keys. Reads the raw defaults directly since the pref accessor is gone.
        if UserDefaults.standard.bool(forKey: "nativeShortcutsDisabled") {
            SystemShortcuts.reenableSpacesSet()
            UserDefaults.standard.removeObject(forKey: "nativeShortcutsDisabled")
            UserDefaults.standard.removeObject(forKey: "nativeShortcutsSnapshot")
        }
        // One-time: an earlier build persisted the Caps-Lock mapping as plain ⌃; clear that stale
        // value so it falls back to the intended ⌘⌥⌃ default (a mapping set after this is kept).
        if !UserDefaults.standard.bool(forKey: "didResetCapsMappingDefault") {
            UserDefaults.standard.set(true, forKey: "didResetCapsMappingDefault")
            UserDefaults.standard.removeObject(forKey: "capsLockMapping")
        }
        // Mirror the user's real macOS Spaces shortcuts: the switching rows bind to them and
        // the move-window chords derive from them, so watch for external (System Settings) edits.
        NativeShortcutsWatcher.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged),
                                               name: .speedySpacesPrefsChanged, object: nil)
        if CommandLine.arguments.contains("--show-settings") {
            statusController?.presentSettings()
        }
        // Flush any speedyspaces:// commands that arrived during launch, now the router exists.
        let queued = pendingCommands
        pendingCommands.removeAll()
        for command in queued { hotkeys?.runCommand(command) }
    }

    /// Terminate any other running instances of this app. macOS `open` on a running menu-bar
    /// (LSUIElement) agent only re-activates the existing process — it does NOT launch a rebuilt
    /// binary — so without this, a rebuild silently keeps running stale code. Newest launch wins.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mePID = NSRunningApplication.current.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != mePID {
            app.forceTerminate()
        }
    }

    @objc private func prefsChanged() {
        overlay.enabled = Prefs.missionControlLabels || Prefs.thumbnailIconStyle != .hidden
        capsHyper.apply()
    }

    /// Take the Caps Lock→F18 remap out on the way down — with the process (and its
    /// event tap) gone, a lingering remap would leave Caps Lock a dead key.
    func applicationWillTerminate(_ notification: Notification) {
        capsHyper.deactivate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
