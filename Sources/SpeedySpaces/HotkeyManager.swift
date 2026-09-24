// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox

/// Opt-in file trace for hotkey delivery — this app's NSLog lines do not surface in
/// `log stream` on some systems, which makes registration/dispatch otherwise
/// unobservable. Enable with `defaults write com.n14395.SpeedySpaces hotkeyDebugLog
/// -bool true` (and relaunch); lines append to /tmp/speedyspaces-hotkey-diag.log.
enum HotkeyDiag {
    /// Writes are handed to this serial queue and NEVER performed inline: several call
    /// sites run on the event-tap thread, where an ACTIVE tap's callback gates keyboard
    /// delivery for the whole login session — a blocking open/seek/write/close there
    /// turns a busy disk into a session-wide input freeze (the same failure class as the
    /// cfprefsd read removed from SwitcherHUD's chord path).
    private static let queue = DispatchQueue(label: "speedyspaces.hotkeydiag", qos: .utility)
    /// Read once: `UserDefaults.bool` is cheap but this is on the keystroke path.
    private static let enabled = UserDefaults.standard.bool(forKey: "hotkeyDebugLog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        guard enabled else { return }
        // Timestamp at the CALL site (queue latency must not distort the ordering we read).
        let now = Date()
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            let line = "\(stamp.string(from: now)) \(pid) \(message)\n"
            guard let d = line.data(using: .utf8) else { return }
            if let h = FileHandle(forWritingAtPath: "/tmp/speedyspaces-hotkey-diag.log") {
                h.seekToEndOfFile(); h.write(d); h.closeFile()
            } else {
                FileManager.default.createFile(atPath: "/tmp/speedyspaces-hotkey-diag.log", contents: d)
            }
        }
    }
}

/// Registers the user's configured global shortcuts via Carbon RegisterEventHotKey
/// (permission-free — unlike an event tap) and dispatches them to app actions.
///
/// Lifecycle: `start()` installs one application-target Carbon event handler and performs
/// the initial registration pass; bindings re-register (coalesced) whenever Prefs or the
/// per-space metadata change. Recording UIs call `pauseForRecording()` so typing a chord
/// into a recorder can't trigger the action it's replacing.
final class HotkeyManager {
    enum Binding {
        case action(HotkeyAction)
        case space(uuid: String)

        /// Stable key for failure bookkeeping and logs.
        var id: String {
            switch self {
            case .action(let a): return a.rawValue
            case .space(let uuid): return "space:\(uuid)"
            }
        }
    }

    private let spaces: SpacesManager
    private let store: MetadataStore
    private unowned let status: StatusItemController

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, binding: Binding, spec: ShortcutSpec)] = [:]
    /// flagsChanged monitors (one global + one local) for a modifier-only holdSwitcher
    /// chord, which Carbon can't register. The global one delivers only while
    /// Accessibility is granted — which the app needs to switch spaces anyway.
    private var modifierOnlyMonitors: [Any] = []
    /// NotificationCenter observers paired with the modifier-only monitors (caps-hyper
    /// transitions arrive as notifications, not events).
    private var modifierOnlyObservers: [NSObjectProtocol] = []
    private var modifierChordHeld = false
    private var nextID: UInt32 = 1
    private var paused = false
    private var reloadScheduled = false
    private var promptedAXThisLaunch = false

    /// Chords that RegisterEventHotKey refused (typically eventHotKeyExistsErr: another
    /// app owns them), keyed by Binding.id — the Settings pane surfaces these per row.
    private(set) var failedRegistrations: [String: OSStatus] = [:]

    /// FourCC 'SPMN'.
    private static let signature: OSType = {
        var code: OSType = 0
        for byte in "SPMN".utf8 { code = code << 8 | OSType(byte) }
        return code
    }()

    init(spaces: SpacesManager, store: MetadataStore, status: StatusItemController) {
        self.spaces = spaces
        self.store = store
        self.status = status
        HotkeyManagerHolder.shared = self
    }

    func start() {
        installHandler()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload),
                                               name: .speedySpacesPrefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload),
                                               name: .speedySpacesMetadataChanged, object: nil)
        // The move-window chords are "native switch chord + extra modifier"; re-derive them
        // whenever the user's real macOS Spaces shortcuts change (System Settings or our own edit).
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReload),
                                               name: .speedySpacesNativeShortcutsChanged, object: nil)
        // Debug hook: `SpeedySpaces --fire-hotkey <actionId>` routes through the exact
        // dispatch path a Carbon callback takes. Synthetic keyboard events are dropped
        // system-wide on this macOS (IOHID provenance), so headless verification of the
        // dispatch layer needs this side door; real keypresses use the Carbon path.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugFire(_:)),
            name: Notification.Name("com.n14395.SpeedySpaces.debug.hotkey"), object: nil)
        // Shipping command side door: the `speedyspaces://` URL scheme, the CLI switch
        // flags, and the App Intents (Shortcuts) all funnel a canonical command string
        // here — see runCommand(_:). Kept out of the `.debug.` namespace on purpose.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(externalCommand(_:)),
            name: Notification.Name("com.n14395.SpeedySpaces.command"), object: nil)
    }

    @objc private func externalCommand(_ note: Notification) {
        guard let command = note.object as? String else { return }
        runCommand(command)
    }

    /// Single dispatch point for external drivers (URL scheme, CLI, App Intents). Parses a
    /// small verb vocabulary and routes through the same paths a hotkey takes. Runs on the
    /// main thread (async-hops if needed) since it touches AppKit and the space engines.
    func runCommand(_ command: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.runCommand(command) }
            return
        }
        HotkeyDiag.log("runCommand \(command)")
        switch command {
        case "next":            perform(.nextSpace)
        case "prev", "previous": perform(.previousSpace)
        case "back":            perform(.backAndForth)
        case "menu":            perform(.openMenu)
        case "settings":        perform(.openSettings)
        case "mission-control": perform(.openMissionControl)
        case "rename":          perform(.renameCurrentSpace)
        case "switcher":
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.n14395.SpeedySpaces.debug.switcher"),
                object: "show:1.5", userInfo: nil, deliverImmediately: true)
        default:
            if command.hasPrefix("switch:uuid:") {
                handleSpaceBinding(uuid: String(command.dropFirst("switch:uuid:".count)))
            } else if command.hasPrefix("switch:name:") {
                let name = String(command.dropFirst("switch:name:".count))
                if let uuid = resolveSpaceUUID(byName: name) { handleSpaceBinding(uuid: uuid) }
            } else if command.hasPrefix("switch:index:") {
                if let n = Int(command.dropFirst("switch:index:".count)) { switchToIndex(n) }
            }
        }
    }

    /// Resolve a user-typed space name to a uuid. Matches against each space's resolved
    /// display title (custom name → "Full-Screen App" → "Desktop N"), case- and
    /// whitespace-insensitive, preferring exact, then prefix, then substring. Custom-named
    /// spaces win over synthesized "Desktop N" titles at the same tier.
    private func resolveSpaceUUID(byName raw: String) -> String? {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let list = spaces.spaces
        let candidates = list.map {
            (title: $0.displayTitle(using: store),
             named: !(store.metadata(for: $0.uuid).name ?? "").isEmpty)
        }
        return SpaceNameRanker.bestIndex(candidates: candidates, query: raw).map { list[$0].uuid }
    }

    /// Switch to the nth space (1-based) on the pointer's display, matching the numbered
    /// switch hotkeys and `--switch #n`.
    private func switchToIndex(_ n: Int) {
        guard axAllowed() else { return }
        let list = spaces.pointerDisplaySpaces().spaces
        guard n >= 1, n <= list.count else { return }
        let target = list[n - 1]
        if !target.isCurrent { spaces.switchTo(target) }
    }

    @objc private func debugFire(_ note: Notification) {
        guard let id = note.object as? String else { return }
        HotkeyDiag.log("debugFire \(id)")
        if id.hasPrefix("holdSwitcher:") {
            // Simulate the hold chord's press/release through the real dispatch path.
            // The registered spec (if a chord is recorded) arms the HUD's physical-state
            // safety poll, exactly as a real press does.
            let spec = registered.values.first { $0.binding.id == HotkeyAction.holdSwitcher.rawValue }?.spec
                ?? Prefs.hotkey(for: .holdSwitcher)
            switch id.dropFirst("holdSwitcher:".count) {
            case "down": SwitcherHUDHolder.shared?.chordDown(spec: spec)
            case "up": SwitcherHUDHolder.shared?.chordUp()
            default: break
            }
        } else if let action = HotkeyAction(rawValue: id) {
            perform(action)
        } else if id.hasPrefix("space:") {
            handleSpaceBinding(uuid: String(id.dropFirst("space:".count)))
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    // MARK: - Recording pause

    func pauseForRecording() {
        paused = true
        unregisterAll()
    }

    func resumeAfterRecording() {
        paused = false
        reload()
    }

    // MARK: - Registration

    /// Coalesce bursts (prefs notifications fire per slider tick).
    @objc private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    /// How an action gets its keyboard trigger.
    /// - `.native`: macOS owns the keypress (Prev/Next Space, Switch-to-Space-N). We never
    ///   Carbon-register it; Settings edits the underlying symbolic hotkey instead.
    /// - `.move`: the chord is DERIVED — the native switch chord + `Prefs.moveExtraModifier`.
    /// - `.holdSwitcher`: modifier-only monitor, gated on the settings checkbox.
    /// - `.app`: an ordinary recorded chord with no native equivalent (Back-and-Forth,
    ///   Move-to-Display, Open Menu/MC/Settings, Rename).
    enum Trigger { case native, move, holdSwitcher, app }
    static func trigger(for action: HotkeyAction) -> Trigger {
        if action == .holdSwitcher { return .holdSwitcher }
        let r = action.rawValue
        if action == .nextSpace || action == .previousSpace || r.hasPrefix("switchToSpace") { return .native }
        if r.hasPrefix("moveFollow") { return .move }
        return .app
    }

    private func reload() {
        guard !paused else { return }
        unregisterAll()
        for action in HotkeyAction.allCases {
            switch Self.trigger(for: action) {
            case .native:
                continue   // macOS owns the keyboard for these; we edit them in Settings
            case .move:
                // Extra Modifier on → derived chord (native switch + extra); off → the user's
                // own reprogrammable chord stored per-action.
                let spec = Prefs.moveExtraModifierEnabled
                    ? Self.moveChord(for: action) : Prefs.hotkey(for: action)
                if let spec { register(spec, for: .action(action)) }
            case .holdSwitcher:
                // Registers only while the checkbox is on; unchecking disables the trigger
                // without discarding the recorded chord.
                guard Prefs.switcherHoldEnabled, let spec = Prefs.hotkey(for: action) else { continue }
                register(spec, for: .action(action))
            case .app:
                if let spec = Prefs.hotkey(for: action) { register(spec, for: .action(action)) }
            }
        }
        for (uuid, meta) in store.entries {
            if let spec = meta.shortcut {
                register(spec, for: .space(uuid: uuid))
            }
        }
        NotificationCenter.default.post(name: .speedySpacesHotkeysReloaded, object: nil)
    }

    /// The registrable chord for a "move window" action: the current native switch chord for
    /// the matching direction/number, PLUS the user's extra modifier (default ⇧). Tracks the
    /// native binding live (falls back to the factory chord); nil if there's no native base.
    static func moveChord(for action: HotkeyAction) -> ShortcutSpec? {
        func fromNative(id: Int) -> ShortcutSpec? {
            let keyCode: UInt16
            let baseModsRaw: UInt   // may carry the fn bit; sanitizeRaw drops it below
            if let sc = SystemShortcuts.systemBinding(id: id) {
                keyCode = sc.keyCode; baseModsRaw = UInt(sc.flags.rawValue)
            } else if let d = SystemShortcuts.defaultChord(id: id) {
                keyCode = UInt16(d.keyCode); baseModsRaw = UInt(bitPattern: d.mods)
            } else {
                return nil
            }
            let mods = ShortcutSpec.sanitizeRaw(baseModsRaw) | Prefs.moveExtraModifier
            return ShortcutSpec(keyCode: keyCode, modifiers: mods)
        }
        switch action {
        case .moveFollowNext: return fromNative(id: SystemShortcuts.moveRightID)
        case .moveFollowPrev: return fromNative(id: SystemShortcuts.moveLeftID)
        default:
            guard action.rawValue.hasPrefix("moveFollowToSpace"), let n = action.spaceNumber,
                  n >= 1, n <= SystemShortcuts.maxSwitchableDesktop else { return nil }
            return fromNative(id: SystemShortcuts.desktopBaseID + n - 1)
        }
    }

    private func register(_ spec: ShortcutSpec, for binding: Binding) {
        if spec.isModifierOnly {
            // Only the hold-to-show switcher records these (its recorder is the only one
            // with allowsBareShortcuts); a press-triggered action can't fire off flags.
            if case .action(.holdSwitcher) = binding {
                installModifierOnlyMonitor(spec)
            } else {
                failedRegistrations[binding.id] = OSStatus(paramErr)
            }
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        HotkeyDiag.log("register \(spec.displayString) for \(binding.id) -> \(status)")
        if status == noErr, let ref {
            registered[nextID] = (ref, binding, spec)
        } else {
            // eventHotKeyExistsErr (-9878): another app owns this chord.
            failedRegistrations[binding.id] = status
            NSLog("[SpeedySpaces] hotkey \(spec.displayString) for \(binding.id) failed to register (OSStatus \(status))")
        }
        nextID += 1
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
        failedRegistrations.removeAll()
        for m in modifierOnlyMonitors { NSEvent.removeMonitor(m) }
        modifierOnlyMonitors.removeAll()
        for o in modifierOnlyObservers { NotificationCenter.default.removeObserver(o) }
        modifierOnlyObservers.removeAll()
        if modifierChordHeld {
            modifierChordHeld = false
            SwitcherHUDHolder.shared?.chordUp()
        }
    }

    /// Hold-to-show on a keyless chord: down while the chord's modifiers are ALL held — extra
    /// modifiers held alongside are fine (⌃ shows it, and so does ⌃⇧, ⌃⌘, …), up as soon as any
    /// of the chord's own modifiers is released. (Incremental presses fire flagsChanged at every
    /// step, so the state is always observed.) Caps-as-hyper contributes its mapping without any
    /// flagsChanged (its tap rewrites key events only), so the hyper layer is OR'd into every
    /// evaluation and its down/up transitions re-evaluate via the in-process notification.
    private func installModifierOnlyMonitor(_ spec: ShortcutSpec) {
        let evaluate: (UInt) -> Void = { [weak self] mods in
            guard let self else { return }
            // Subset match: the chord's modifiers are a subset of what's currently held.
            let matches = spec.modifiers != 0 && (mods & spec.modifiers) == spec.modifiers
            if matches {
                guard !self.modifierChordHeld else { return }
                self.modifierChordHeld = true
                HotkeyDiag.log("modifierOnly down \(spec.displayString)")
                SwitcherHUDHolder.shared?.chordDown(spec: spec)
            } else if self.modifierChordHeld {
                self.modifierChordHeld = false
                HotkeyDiag.log("modifierOnly up \(spec.displayString)")
                SwitcherHUDHolder.shared?.chordUp()
            }
        }
        let handler: (NSEvent) -> Void = { event in
            evaluate(ShortcutSpec.sanitize(event.modifierFlags)
                     | (CapsLockHyper.isHyperDown ? CapsLockHyper.hyperNSModifiers : 0))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged,
                                                          handler: handler) {
            modifierOnlyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged,
                                                        handler: { handler($0); return $0 }) {
            modifierOnlyMonitors.append(local)
        }
        modifierOnlyObservers.append(NotificationCenter.default.addObserver(
            forName: .speedySpacesHyperKeyChanged, object: nil, queue: .main) { note in
            guard let down = note.userInfo?["down"] as? Bool else { return }
            evaluate(ShortcutSpec.sanitize(NSEvent.modifierFlags)
                     | (down ? CapsLockHyper.hyperNSModifiers : 0))
        })
        HotkeyDiag.log("register modifierOnly \(spec.displayString) for holdSwitcher")
    }

    private func installHandler() {
        // Released is registered alongside Pressed for the hold-to-show switcher; every
        // other binding ignores the release events.
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                        eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                        eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotkeyManager.signature else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { manager.handle(id: id, released: released) }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    // MARK: - Dispatch

    private func handle(id: UInt32, released: Bool) {
        HotkeyDiag.log("fired id \(id) released=\(released) -> \(registered[id]?.binding.id ?? "unknown")")
        guard let entry = registered[id] else { return }
        // Hold-to-show: press shows, release hides. Carbon repeats Pressed while the key
        // autorepeats — chordDown is idempotent.
        if case .action(.holdSwitcher) = entry.binding {
            if released {
                SwitcherHUDHolder.shared?.chordUp()
            } else {
                SwitcherHUDHolder.shared?.chordDown(spec: entry.spec)
            }
            return
        }
        guard !released else { return }
        switch entry.binding {
        case .space(let uuid):
            handleSpaceBinding(uuid: uuid)
        case .action(let action):
            perform(action)
        }
    }

    private func handleSpaceBinding(uuid: String) {
        guard axAllowed() else { return }
        // A binding whose space no longer exists stays registered and no-ops.
        if let target = spaces.spaces.first(where: { $0.uuid == uuid }), !target.isCurrent {
            spaces.switchTo(target)
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .openMenu:
            status.openMenu()
            return
        case .openSettings:
            status.presentSettings()
            return
        case .openMissionControl:
            // Not a bare Mission Control toggle: the spaces bar is hovered open into
            // wallpaper thumbnails, the same view the hold-to-show switcher's
            // "Native Mission Control" style presents.
            NativeMissionControlHold.toggleExpanded()
            return
        case .holdSwitcher:
            // Press/release routes through handle(id:released:) before reaching here;
            // nothing to do for a bare action dispatch (and no Accessibility needed).
            return
        default:
            break
        }

        guard axAllowed() else { return }
        switch action {
        case .renameCurrentSpace:
            if let current = spaces.focusedDisplaySpaces().current {
                status.presentEditor(uuid: current.uuid)
            }
        case .nextSpace, .previousSpace:
            // Switching resolves on the POINTER's display, like the system's own
            // ⌃-arrows (and like the gesture engine, which acts where the pointer is).
            if let target = relativeTarget(forward: action == .nextSpace,
                                           in: spaces.pointerDisplaySpaces()) {
                spaces.switchTo(target)
            }
        case .backAndForth:
            if let target = spaces.backAndForthTarget() {
                spaces.switchTo(target)
            }
        case .moveDisplayNext, .moveDisplayPrev:
            // Move the focused window to the adjacent display's CURRENT space (that's
            // what "another monitor" means in space terms); no space switch needed.
            let indexes = Set(spaces.spaces.map(\.displayIndex)).sorted()
            guard indexes.count > 1,
                  let current = spaces.focusedDisplaySpaces().current,
                  let i = indexes.firstIndex(of: current.displayIndex) else { return }
            _ = (indexes, i)   // geometry-based AX move; space model not needed
            do {
                try WindowMover.moveFocusedWindowToDisplay(forward: action == .moveDisplayNext)
                HotkeyDiag.log("moveDisplay ok forward=\(action == .moveDisplayNext)")
            } catch {
                NSSound.beep()
                HotkeyDiag.log("moveDisplay FAILED: \(error)")
            }
        case .moveFollowNext, .moveFollowPrev:
            // Window moves are relative to the FOCUSED display — that's where the
            // window being moved lives — and always follow to the new space.
            let forward = action == .moveFollowNext
            // Serialise grabs so a burst never overlaps (later presses would otherwise only
            // switch the space and leave the window behind); the batch glides in one grab.
            RelativeWindowMover.shared.press(forward: forward,
                                             wrap: Prefs.hotkeyWrapAround, spaces: spaces)
        default:
            guard let n = action.spaceNumber else { return }
            let isSwitch = action.rawValue.hasPrefix("switchToSpace")
            let list = isSwitch ? spaces.pointerDisplaySpaces().spaces
                                : spaces.focusedDisplaySpaces().spaces
            guard n <= list.count else { return }
            let target = list[n - 1]
            if isSwitch {
                if !target.isCurrent { spaces.switchTo(target) }
            } else {
                moveWindow(to: target)
            }
        }
    }

    private func moveWindow(to target: Space) {
        do {
            try WindowMover.moveFocusedWindow(to: target, spaces: spaces)
            HotkeyDiag.log("moveWindow ok -> ordinal \(target.ordinalOnDisplay)")
        } catch WindowMover.MoveError.screenRecordingRequired {
            ScreenRecordingPermission.reportBlockedMove()
        } catch {
            NSSound.beep()
            HotkeyDiag.log("moveWindow FAILED: \(error)")
            NSLog("[SpeedySpaces] move-window hotkey failed: \(error)")
        }
    }

    /// Neighbor of a display's current space, honoring the wrap pref. The caller picks
    /// the display resolution: pointer display for switching (native ⌃-arrow behavior),
    /// focused display for moving the focused window.
    func relativeTarget(forward: Bool,
                        in resolution: (spaces: [Space], current: Space?)) -> Space? {
        Self.relativeTarget(forward: forward, list: resolution.spaces,
                            current: resolution.current, wrap: Prefs.hotkeyWrapAround)
    }

    /// Pure core of the neighbor resolution (wrap injected so it is unit-testable).
    static func relativeTarget(forward: Bool, list: [Space],
                               current: Space?, wrap: Bool) -> Space? {
        guard let current, !list.isEmpty,
              let i = list.firstIndex(where: { $0.uuid == current.uuid }) else { return nil }
        var j = i + (forward ? 1 : -1)
        if wrap {
            j = (j % list.count + list.count) % list.count
        } else {
            guard list.indices.contains(j) else { return nil }
        }
        return j == i ? nil : list[j]
    }

    static func selfChecks(_ check: (Bool, String) -> Void) {
        func space(_ n: Int, current: Bool = false) -> Space {
            Space(uuid: "uuid-\(n)", managedSpaceID: n, type: 0, displayIndex: 0,
                  displayIdentifier: "Main", ordinalOnDisplay: n, isCurrent: current)
        }
        let list = (0..<4).map { space($0) }
        func target(_ forward: Bool, at i: Int, wrap: Bool) -> Space? {
            relativeTarget(forward: forward, list: list, current: list[i], wrap: wrap)
        }
        check(target(true, at: 1, wrap: false)?.uuid == "uuid-2", "relativeTarget: forward neighbor")
        check(target(false, at: 1, wrap: false)?.uuid == "uuid-0", "relativeTarget: backward neighbor")
        check(target(true, at: 3, wrap: true)?.uuid == "uuid-0", "relativeTarget: wraps last -> first")
        check(target(false, at: 0, wrap: true)?.uuid == "uuid-3", "relativeTarget: wraps first -> last")
        check(target(true, at: 3, wrap: false) == nil, "relativeTarget: no wrap stops at last")
        check(target(false, at: 0, wrap: false) == nil, "relativeTarget: no wrap stops at first")
        check(relativeTarget(forward: true, list: [space(0)], current: space(0), wrap: true) == nil,
              "relativeTarget: single space -> nil even with wrap")
        check(relativeTarget(forward: true, list: list, current: space(9), wrap: true) == nil,
              "relativeTarget: unknown current -> nil")
        check(relativeTarget(forward: true, list: [], current: space(0), wrap: true) == nil,
              "relativeTarget: empty list -> nil")
        check(relativeTarget(forward: true, list: list, current: nil, wrap: true) == nil,
              "relativeTarget: nil current -> nil")
    }

    /// Engine-backed actions need Accessibility. Prompt with the explanatory alert once
    /// per launch; later presses just beep so a forgotten grant can't spam modals.
    private func axAllowed() -> Bool {
        guard !spaces.canSwitch else { return true }
        if promptedAXThisLaunch {
            NSSound.beep()
            NSLog("[SpeedySpaces] hotkey ignored: Accessibility not granted")
        } else {
            promptedAXThisLaunch = true
            status.presentAccessibilityHelp()
        }
        return false
    }
}
