import AppKit

enum SwitcherHUDHolder {
    static weak var shared: SwitcherHUD?
}

extension Space {
    /// Display name precedence shared by the menu bar, menu rows, and the switcher HUD:
    /// custom name, else the fullscreen placeholder, else a per-display 1-based index.
    func displayTitle(using store: MetadataStore) -> String {
        let meta = store.metadata(for: uuid)
        if let name = meta.name, !name.isEmpty { return name }
        if isFullscreen { return "Full-Screen App" }
        return "Desktop \(ordinalOnDisplay + 1)"
    }
}

/// The floating Mission-Control-style space switcher: one click-through panel per display,
/// each showing that display's spaces as wallpaper tiles. Shown while the hold-switcher
/// chord is held and flashed briefly when the active space changes.
final class SwitcherHUD {
    private enum Visibility {
        case hidden
        case held
        case flashing
    }

    private let spaces: SpacesManager
    private let store: MetadataStore
    private let wallpapers: WallpaperStore
    private var panels: [CGDirectDisplayID: SwitcherPanel] = [:]
    private var visibility: Visibility = .hidden
    private var isChordHeld = false
    private var flashTimer: Timer?
    /// How long the switcher stays after a space change — a user-settable minimum
    /// (Settings ▸ Switcher). A floor: hover / consecutive switches can extend it.
    private var flashDuration: TimeInterval { Prefs.switcherFlashDuration }
    /// Flash duration for anticipated native switches (⌃-arrow key-down, gesture start).
    /// Must outlive the native slide (~0.85 s) plus notification delivery, or the HUD
    /// fades out right before the landing refresh re-flashes it — a visible blink.
    /// The landing itself restarts the normal `flashDuration` countdown, so this longer
    /// window only plays out in full when the switch never lands (edge-of-row rubber band).
    private var anticipationFlashDuration: TimeInterval { max(2.0, Prefs.switcherFlashDuration) }
    /// displayIdentifier -> current space uuid, for detecting which display changed.
    private var lastCurrentByDisplay: [String: String] = [:]
    /// When the active space last actually changed. Lets a hold that ends right after a switch
    /// (the switch/move shortcuts share modifiers with the hold chord) linger for the settable
    /// minimum instead of vanishing the instant the chord is released.
    private var lastSpaceChangeAt = Date.distantPast
    /// An anticipated switch is in flight until this deadline: initiation, the window
    /// server's slide, and the usual tail after it lands (plus the Dock's dismiss beat for a
    /// deferred Show-Desktop switch). Keeps the popover up across a chord release and stops
    /// the landing's re-flash from cutting the transition short, so it stays continuous from
    /// before the animation to after it. Set on `.speedySpacesAnticipateSwitch`.
    private var switchPendingUntil = Date.distantPast
    /// The window server's own space slide, measured at ~0.85 s from initiation to settle.
    private static let slideAllowance: TimeInterval = 0.9
    /// Extra cover for a deferred switch: the Show-Desktop overlay wait (≤0.6 s) plus the
    /// settle beat SpacesManager waits out before re-firing the switch (see switchTo).
    private static let showDesktopDismissAllowance: TimeInterval = 1.1
    /// True while the real Mission Control is (probably) on screen — never draw over it.
    private var mcSuppressed = false
    private var mcClearTimer: Timer?
    /// Safety net for a lost kEventHotKeyReleased: while held, poll the chord's physical
    /// state (both are permission-free queries) and synthesize the release if it's gone.
    private var chordSpec: ShortcutSpec?
    private var chordPollTimer: Timer?
    private var chordPollMisses = 0
    /// Native-switch anticipation: macOS's own ⌃-arrow/⌃N shortcuts run the switch
    /// animation before any notification reaches us. They are consumed by the window
    /// server's hotkey routing, so app-level NSEvent monitors never see them — only a
    /// session CGEvent tap placed ahead of hotkey routing does (the MC overlay's dismiss
    /// tap proves F3 arrives this way). Watch for the user's enabled Mission Control
    /// chords and flash at key-down, before the animation; the landing refresh then
    /// moves the highlight.
    private var nativeTap: CFMachPort?
    private var nativeTapSource: CFRunLoopSource?
    private let nativeTapRef = Locked<CFMachPort?>(nil)
    private let nativeTapReviver = TapReviver("hudNative")
    /// Separate LISTEN-ONLY tap for the trackpad gesture events — see
    /// installNativeSwitchTap for why these must never ride the active tap.
    private var gestureTap: CFMachPort?
    private var gestureTapSource: CFRunLoopSource?
    private let gestureTapRef = Locked<CFMachPort?>(nil)
    private let gestureTapReviver = TapReviver("hudGesture")
    private var nativeSwitchChords: [(label: String, sc: SystemShortcuts.SpaceShortcut)] = []
    private var nativeChordsLoadedAt = Date.distantPast
    /// The user's current "Move left/right a space" system shortcuts (remappable in System
    /// Settings), cached and refreshed at most 1/min like `nativeSwitchChords`. Used to make
    /// those shortcuts wrap past the ends when `Prefs.hotkeyWrapAround` is on — matched
    /// however they're mapped, falling back to ⌃←/⌃→ (macOS's shipped default) when unset.
    /// The user's live macOS Move-left/right-a-space chords. The TAP THREAD reads these on
    /// every arrow keypress, so they are a lock-guarded snapshot that MAIN refreshes — never
    /// derived on the tap thread. Deriving them there meant a blocking cfprefsd round trip
    /// (`persistentDomain(forName: "com.apple.symbolichotkeys")`, twice) inside an ACTIVE tap
    /// callback, whose verdict gates keyboard delivery for the WHOLE login session: normally
    /// 0.09 ms, but the window server recorded 21.9 s and 111 s stalls against these taps —
    /// the "no shortcut or gesture switches spaces" freezes, which cleared on their own once
    /// cfprefsd answered.
    private let directionalChords = Locked<(left: SystemShortcuts.SpaceShortcut,
                                            right: SystemShortcuts.SpaceShortcut)>(
        (left: SystemShortcuts.SpaceShortcut(keyCode: 123, flags: .maskControl),
         right: SystemShortcuts.SpaceShortcut(keyCode: 124, flags: .maskControl)))
    /// Throttle for the streaming dock-swipe gesture events (see nativeDockSwipe).
    private var lastDockSwipeFlash = Date.distantPast
    /// True while `barPointerMoved` holds a flash open under an actively-moving pointer.
    /// Paired with the release in `barHoverChanged`: only a flash that was actually pinned
    /// gets a fresh countdown when the pointer leaves, so a cursor merely crossing the band
    /// can't stretch an otherwise-normal flash. Cleared by any new countdown.
    private var hoverPinned = false

    /// In-flight tile drag (drag-to-reorder). Coordinates across all panels: only
    /// `SwitcherHUD` sees every display, so the origin panel owns the mouse events while
    /// this resolves the target display/slot and pushes ghost + reflow to each panel.
    private struct DragSession {
        let originDisplayID: CGDirectDisplayID
        let draggedUUID: String
        let draggedTile: SwitcherTile
        let isCurrentSpace: Bool
        let originIndex: Int
        let originCount: Int
        /// Ordered tiles per display, captured at drag start (spaces don't change mid-drag;
        /// an add/remove aborts the drag).
        let tilesByDisplay: [CGDirectDisplayID: [SwitcherTile]]
        var targetDisplayID: CGDirectDisplayID
        var targetIndex: Int
        var pendingHideOnDrop = false
    }
    private var drag: DragSession?
    /// True only during the drop commit: the reorder posts a `spacesChanged` synchronously,
    /// and the panels are updated directly by `dragEnded`, so that notification must not
    /// kick off a fresh row transition (which would replay the move from the start).
    private var settlingDrop = false

    /// Window→workspace drop: while the switcher is HELD, an active pass-through session tap
    /// watches the global mouse. A window dragged onto a tile lands on that workspace via the
    /// ⌃N jump (`WindowMover.move`). Separate from the tile-reorder drag (which starts on the
    /// panel and rides AppKit); this one starts on a FOREIGN window, so it needs the global tap.
    private var dropTap: CFMachPort?
    private var dropTapSource: CFRunLoopSource?
    private let dropTapRef = Locked<CFMachPort?>(nil)
    private let dropTapReviver = TapReviver("hudDrop")
    private var dropCandidate: (wid: UInt32, pid: pid_t)?   // window pressed at drag start
    private var dropMoved = false                            // a drag actually occurred (not a click)

    /// Open the name/icon editor for a space uuid (wired to the status controller's
    /// editor by AppDelegate) — fired when a tile's title row is clicked. The screen is
    /// the display whose panel was clicked, so the editor opens there.
    var onEditRequest: ((String, NSScreen?) -> Void)?

    var enabled = false {
        didSet {
            guard enabled != oldValue, !enabled else { return }
            isChordHeld = false
            hideAll(animated: false)
        }
    }

    init(spaces: SpacesManager, store: MetadataStore, wallpapers: WallpaperStore) {
        self.spaces = spaces
        self.store = store
        self.wallpapers = wallpapers
        SwitcherHUDHolder.shared = self
        wallpapers.onThumbnailLoaded = { [weak self] in self?.refreshVisible() }
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(spacesChanged),
                                               name: .speedySpacesSpacesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(anticipateSwitch(_:)),
                                               name: .speedySpacesAnticipateSwitch, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mcWillOpen),
                                               name: .speedySpacesMissionControlWillOpen, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mcOpened),
                                               name: .speedySpacesMissionControlOpened, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mcClosed),
                                               name: .speedySpacesMissionControlClosed, object: nil)
        for s in spaces.spaces where s.isCurrent {
            lastCurrentByDisplay[s.displayIdentifier] = s.uuid
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDirectionalChords),
                                               name: .speedySpacesNativeShortcutsChanged, object: nil)
        refreshDirectionalChords()   // seed before the tap can read the snapshot
        installNativeSwitchTap()
        wallpapers.scheduleRecord(spaces: { [weak self] in self?.spaces.spaces ?? [] })
        // Debug side door (`--show-switcher`, `--fire-hotkey holdSwitcher:*` routes here via
        // HotkeyManager): synthetic keyboard events are dropped system-wide on this macOS,
        // so headless verification drives the HUD through distributed notifications.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugCommand(_:)),
            name: Notification.Name("com.speedyspaces.debug.switcher"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        TapTeardown.tearDown(tap: nativeTap, source: nativeTapSource)
        TapTeardown.tearDown(tap: gestureTap, source: gestureTapSource)
        TapTeardown.tearDown(tap: dropTap, source: dropTapSource)
    }

    // MARK: - Native-switch anticipation

    /// Session event tap ahead of the window server's hotkey routing. Same permission
    /// dance as MissionControlOverlay.installDismissTap: keyboard delivery to LISTEN-ONLY
    /// taps is gated behind Input Monitoring, but an ACTIVE tap that passes every event
    /// through unmodified is fully served under Accessibility (already held for
    /// switching) — prefer it when trusted.
    private func installNativeSwitchTap() {
        guard nativeTap == nil else { return }
        // keyDown only for ⌃-arrow/⌃N anticipation. The gesture event types live on the
        // separate listen-only tap below: an active tap re-injects everything it passes
        // along, and the high-rate trackpad gesture stream (with its macOS-27 IOHID
        // payloads) is safer merely observed than round-tripped.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        // Runs on the TAP THREAD: the swallow decision below is pure event math over
        // lock-guarded / tap-thread-confined state; everything else hops to main.
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<SwitcherHUD>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.nativeTapRef.get() { me.nativeTapReviver.tapWasDisabled(tap) }
                return Unmanaged.passUnretained(event)
            }
            // A titleBarDrag walk posts its own ⌃+fn+arrows to drive the native "Move a space"
            // shortcut and carry the grabbed window. Be fully transparent for the walk — don't
            // take the switch over, don't anticipate-flash — so nothing we do perturbs it.
            if WindowMover.standDownForMove { return Unmanaged.passUnretained(event) }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if me.nativeDirectionalMoveHandled(keyCode: keyCode, eventFlags: event.flags) {
                return nil   // move-window chord (switch chord + extra modifier): run our own
                             // mover ahead of the WindowServer's flaky ⇧ "take window"
            }
            if me.nativeDirectionalSwitchHandled(keyCode: keyCode, eventFlags: event.flags) {
                return nil   // wrap is on — we own the switch (adjacent or wrapping)
            }
            me.nativeSwitchKeyDown(keyCode: keyCode, eventFlags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        var made: CFMachPort?
        if AXIsProcessTrusted() {
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .defaultTap, eventsOfInterest: mask,
                                     callback: callback, userInfo: info)
        }
        if made == nil {
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask,
                                     callback: callback, userInfo: info)
        }
        guard let tap = made else {
            HotkeyDiag.log("switcher native tap unavailable (needs Accessibility)")
            return
        }
        nativeTap = tap
        nativeTapRef.set(tap)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        TapThread.add(src)
        nativeTapSource = src
        HotkeyDiag.log("switcher native tap installed (AXTrusted=\(AXIsProcessTrusted()))")
        installGestureTap()
    }

    /// Passive tap for the private gesture event types the trackpad space-swipe rides
    /// on (29 = gesture, 30 = dock control), so the HUD can appear the moment the
    /// fingers start sliding the desktop. Gesture types are served to passive taps
    /// under Accessibility (unlike keyboard, which needs Input Monitoring), and a
    /// passive tap observes without re-injecting — see installNativeSwitchTap.
    private func installGestureTap() {
        guard gestureTap == nil else { return }
        let mask: CGEventMask = (1 << UInt64(Self.gestureEventType))
            | (1 << UInt64(Self.dockControlEventType))
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<SwitcherHUD>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.gestureTapRef.get() { me.gestureTapReviver.tapWasDisabled(tap) }
                return Unmanaged.passUnretained(event)
            }
            me.nativeDockSwipe(event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback, userInfo: info) else {
            HotkeyDiag.log("switcher gesture tap unavailable")
            return
        }
        gestureTap = tap
        gestureTapRef.set(tap)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        TapThread.add(src)
        gestureTapSource = src
        HotkeyDiag.log("switcher gesture tap installed (listen-only)")
    }

    /// Make macOS's own Move-left/right-a-space shortcuts behave like the app's own
    /// Next/Previous Space when wrap is enabled: adjacent mid-row, wrapping at the ends.
    ///
    /// We can't just intercept the edge press and pass the rest to macOS: macOS reports a
    /// landed switch only after its ~0.85 s animation, so during rapid presses our known
    /// position lags and we'd miss the edge (and desync after the big wrap jump). Instead,
    /// when wrap is on we take over EVERY directional press and route it through `switchTo`,
    /// exactly like the app's own next/prev. `switchTo`'s optimistic `predicted` overlay
    /// advances the current space immediately, so a burst of presses chains correctly and
    /// wraps past the ends — the accumulation behaviour the app's shortcuts already have.
    ///
    /// Returns true → the tap returns nil (swallow the native event). Needs the ACTIVE tap
    /// (Accessibility) to actually suppress; on a listen-only tap the shortcut just won't
    /// take over. When wrap is off this returns false and macOS handles the shortcut natively.
    /// Runs on the TAP THREAD: reads only thread-safe prefs, the lock-guarded drag flag,
    /// and the tap-thread-confined chord cache; the switch itself is dispatched to main.
    private func nativeDirectionalSwitchHandled(keyCode: UInt16, eventFlags: CGEventFlags) -> Bool {
        // The wrap takeover EMULATES macOS's own Move-left/right-a-space shortcuts, so it only
        // runs when the user asked for wrapping; otherwise macOS handles ⌃-arrow natively.
        guard Prefs.hotkeyWrapAround else { return false }
        // A titleBarDrag move posts its own ⌃+fn+arrows to drive the native "Move a space"
        // shortcut and carry the grabbed window; if we took those over here they'd become a
        // viewport-only switch and the window would stall mid-walk. Let them pass through.
        guard !WindowMover.standDownForMove else { return false }
        let chords = directionalChords.get()
        let relevant: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let flags = eventFlags.intersection(relevant)
        let forward: Bool
        if keyCode == chords.right.keyCode, flags == chords.right.flags { forward = true }
        else if keyCode == chords.left.keyCode, flags == chords.left.flags { forward = false }
        else { return false }
        // Resolve the target against the (optimistically-updated) current space at run time,
        // so ordered async presses each see the previous one's advance. ⌃-arrows act on the
        // pointer's display, like the app's own switching hotkeys.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (list, current) = self.spaces.pointerDisplaySpaces()
            guard let current,
                  let target = Self.wrapNeighbor(forward: forward, list: list, currentUUID: current.uuid)
            else { return }
            self.spaces.switchTo(target)
        }
        return true
    }

    /// A move-window chord is a native directional switch chord (Move-left/right-a-space) PLUS
    /// the user's extra modifier (default ⇧). macOS treats "a Move-a-space chord + ⇧" as "take
    /// the active window along", and the WindowServer runs that (flakily on 26/27) BEFORE our
    /// Carbon hotkey — so a PHYSICAL ⌘⌥⌃⇧+arrow never reaches the hotkey and the window doesn't
    /// move. (A Caps-Lock-hyper press works only because that tap adds the base modifiers AFTER
    /// the WindowServer stage, so the server sees just ⇧+arrow and ignores it.) This tap sits
    /// ahead of the WindowServer — proven by the wrap takeover suppressing native switches — so
    /// we catch base+extra here and run the app's own reliable mover. Numeric moves need no
    /// equivalent: desktop-switch shortcuts have no ⇧ take-window variant, so their Carbon
    /// hotkey fires unimpeded either way.
    private func nativeDirectionalMoveHandled(keyCode: UInt16, eventFlags: CGEventFlags) -> Bool {
        guard Prefs.moveExtraModifierEnabled, Prefs.moveExtraModifier != 0 else { return false }
        // A titleBarDrag walk posts its own ⌃+fn+arrows (no extra modifier) — let those pass.
        guard !WindowMover.standDownForMove else { return false }
        let chords = directionalChords.get()
        guard keyCode == chords.left.keyCode || keyCode == chords.right.keyCode else { return false }
        let relevant: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let extra = CGEventFlags(rawValue: UInt64(Prefs.moveExtraModifier))
        let flags = eventFlags.intersection(relevant)
        let forward: Bool
        if keyCode == chords.right.keyCode, flags == chords.right.flags.union(extra) { forward = true }
        else if keyCode == chords.left.keyCode, flags == chords.left.flags.union(extra) { forward = false }
        else { return false }
        HotkeyDiag.log("switcher MOVE chord match keyCode=\(keyCode) forward=\(forward) — dispatching")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            TitleBarDragRelativeMover.shared.press(forward: forward,
                                                   wrap: Prefs.hotkeyWrapAround, spaces: self.spaces)
        }
        return true
    }

    /// The neighbor in `forward`/backward direction, wrapping past the ends (used only when
    /// wrap is enabled). nil when the current space isn't in the list or there's nowhere to
    /// go (a single space). Pure — mirrors HotkeyManager.relativeTarget's wrap branch.
    static func wrapNeighbor(forward: Bool, list: [Space], currentUUID: String) -> Space? {
        guard !list.isEmpty, let i = list.firstIndex(where: { $0.uuid == currentUUID }) else { return nil }
        let n = list.count
        let j = ((i + (forward ? 1 : -1)) % n + n) % n
        return j == i ? nil : list[j]
    }

    /// Re-derive the directional chord snapshot the tap thread reads. MAIN THREAD ONLY —
    /// this reads the symbolichotkeys defaults domain, which can block on cfprefsd. Driven
    /// by `NativeShortcutsWatcher` (already polling that domain at 2 Hz on main and posting
    /// `.speedySpacesNativeShortcutsChanged`), plus once at start, so the tap path never
    /// pays for it.
    @objc private func refreshDirectionalChords() {
        let left = SystemShortcuts.systemBinding(id: SystemShortcuts.moveLeftID)
            ?? SystemShortcuts.SpaceShortcut(keyCode: 123, flags: .maskControl)
        let right = SystemShortcuts.systemBinding(id: SystemShortcuts.moveRightID)
            ?? SystemShortcuts.SpaceShortcut(keyCode: 124, flags: .maskControl)
        directionalChords.set((left: left, right: right))
    }

    /// keyDown from the tap (TAP THREAD): if the chord is one of the user's enabled macOS
    /// space-switching shortcuts, a native switch is about to run — flash the pointer's
    /// display now (⌃-arrows and ⌃N act on the display under the pointer). Only the chord
    /// matching (against the tap-thread-confined cache) happens here; the HUD state
    /// checks and the flash run on main, so the callback never delays the keystroke.
    private func nativeSwitchKeyDown(keyCode: UInt16, eventFlags: CGEventFlags) {
        // Arrows carry numeric-pad/fn bits; compare only the four real modifiers.
        let relevant: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let flags = eventFlags.intersection(relevant)
        guard !flags.isEmpty else { return }   // bare keys are never switch chords
        // The symbolichotkeys domain is user-editable at any time; reload at most 1/min.
        if Date().timeIntervalSince(nativeChordsLoadedAt) > 60 {
            nativeChordsLoadedAt = Date()
            nativeSwitchChords = SystemShortcuts.missionControlBindings()
                .filter { $0.label != "Mission Control" }   // F3 opens MC; suppression owns that
        }
        guard let match = nativeSwitchChords.first(where: {
            $0.sc.keyCode == keyCode && $0.sc.flags == flags
        }) else { return }
        HotkeyDiag.log("switcher native chord match keyCode=\(keyCode) \(match.label)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, Prefs.switcherFlashOnSpaceChange,
                  !self.mcSuppressed, self.visibility != .held else { return }
            let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            self.flash(displayIdentifiers: pointerScreen.map { Set(Self.displayIdentifiers(for: $0)) },
                       duration: self.anticipationFlashDuration)
        }
    }

    /// Private CGEvent types carrying trackpad gesture traffic (NSEventTypeGesture and
    /// the Dock-control event the space-swipe is delivered as — the same type the
    /// gesture switch engine synthesizes).
    static let gestureEventType: UInt32 = 29
    static let dockControlEventType: UInt32 = 30

    /// Gesture event from the tap. The system emits dock-swipe events (HID type 23,
    /// horizontal motion) the moment it recognizes a three-finger space slide — before
    /// any space-change notification — so the HUD can flash at gesture start instead
    /// of after landing.
    private func nativeDockSwipe(event: CGEvent) {
        // TAP THREAD: cheap event-field reads + the throttle (tap-thread-confined
        // lastDockSwipeFlash); HUD state checks and the flash happen on main.
        guard event.getIntegerValueField(GestureSwitcher.gestureHIDType)
                == GestureSwitcher.hidDockSwipe,
              event.getIntegerValueField(GestureSwitcher.swipeMotion)
                == GestureSwitcher.motionHorizontal else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDockSwipeFlash) > 0.1 else { return }
        lastDockSwipeFlash = now
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, Prefs.switcherFlashOnSpaceChange,
                  !self.mcSuppressed, self.visibility != .held else { return }
            let pointerScreen = NSScreen.screens.first {
                $0.frame.contains(NSEvent.mouseLocation)
            }
            self.flash(displayIdentifiers: pointerScreen.map {
                Set(Self.displayIdentifiers(for: $0))
            }, duration: self.anticipationFlashDuration)
        }
    }

    // MARK: - Triggers

    /// Idempotent: Carbon repeats kEventHotKeyPressed while the chord autorepeats.
    /// `spec` (when known) arms the physical-state safety poll.
    func chordDown(spec: ShortcutSpec? = nil) {
        guard enabled, !isChordHeld else { return }
        isChordHeld = true
        chordSpec = spec
        startChordPoll()
        // Native style: hand the hold to the real Mission Control (bar auto-expanded).
        // visibility stays .hidden so the mcClosed re-show logic never fires the HUD.
        if Prefs.switcherStyle == .missionControl {
            NativeMissionControlHold.begin()
            return
        }
        cancelFlashTimer()
        visibility = .held
        // Logically held even while MC covers the screen: re-shows when MC closes.
        guard !mcSuppressed else { return }
        show(displayFilter: nil, animated: true)
        installDropTap()   // enable window→workspace drag-and-drop for the duration of the hold
    }

    func chordUp() {
        guard isChordHeld else { return }
        isChordHeld = false
        stopChordPoll()
        if NativeMissionControlHold.active { NativeMissionControlHold.end() }
        // Mid-drag: keep the panels alive until the drop, then hide.
        if drag != nil { drag?.pendingHideOnDrop = true; return }
        guard visibility == .held else { return }
        // The switch / move-window shortcuts usually SHARE modifiers with the hold chord, so the
        // popover comes up as .held and would vanish the instant those modifiers lift — too brief
        // to read. Keep it up across the release if a workspace changed during the hold OR an
        // anticipated switch is still in flight, so the transition stays continuous instead of
        // blinking out between the release and the landing.
        let sinceSwitch = Date().timeIntervalSince(lastSpaceChangeAt)
        let pending = switchPendingUntil.timeIntervalSinceNow   // > 0 while a switch is in flight
        if Prefs.switcherFlashOnSpaceChange, pending > 0 || sinceSwitch < flashDuration {
            teardownDropTap()
            visibility = .flashing
            // Switch in flight: hold until it lands (spacesChanged re-flashes; capped at the
            // pending deadline). Otherwise just the remaining settable minimum.
            restartFlashTimer(pending > 0 ? max(flashDuration, pending) : flashDuration - sinceSwitch)
        } else {
            hideAll(animated: true)
        }
    }


    /// Show briefly (space-change flash, or the debug `show:` command with a custom hold).
    func flash(duration: TimeInterval? = nil) {
        guard enabled, !mcSuppressed, visibility != .held else { return }
        visibility = .flashing
        show(displayFilter: nil, animated: true)
        restartFlashTimer(duration ?? flashDuration)
    }

    /// Flash only the given displays (nil = all). `duration` defaults to the normal
    /// flash; anticipation callers pass the longer window that bridges the native slide.
    /// `animated: false` skips the fade-in for callers that need pixels on screen this turn.
    private func flash(displayIdentifiers: Set<String>?, duration: TimeInterval? = nil,
                       animated: Bool = true) {
        guard enabled, !mcSuppressed, visibility != .held else { return }
        visibility = .flashing
        show(displayFilter: displayIdentifiers, animated: animated, refreshData: false)
        restartFlashTimer(duration ?? flashDuration)
    }

    /// A switch is about to be initiated (see SpacesManager.switchTo, which posts this
    /// immediately before handing the switch to its engine — or, for a switch deferred behind a
    /// Show-Desktop dismiss, before the dismiss). Put the popover up NOW, ahead of the
    /// transition: a window ordered in once the window server has begun the slide isn't
    /// composited until the slide ends, so a flash raised at initiation used to surface only
    /// after the animation had already played out. Respects the flash-on-change preference like
    /// any space-change flash.
    @objc private func anticipateSwitch(_ note: Notification) {
        guard Prefs.switcherFlashOnSpaceChange else { return }
        // Mark the switch in flight so a chord release before it lands keeps the popover up
        // (chordUp) and the landing's re-flash doesn't shorten the transition (spacesChanged):
        // the deadline covers the slide plus the settable minimum, so the popover outlives the
        // animation by the same tail it used to show for on its own.
        let deferred = note.userInfo?["deferred"] as? Bool ?? false
        switchPendingUntil = Date().addingTimeInterval(
            (deferred ? Self.showDesktopDismissAllowance : 0) + Self.slideAllowance + flashDuration)
        let display = note.userInfo?["display"] as? String
        // Unanimated, then flushed: the caller starts the transition the moment this
        // notification finishes dispatching, so a 0.12 s fade-in — or even the run loop's
        // ordinary end-of-turn commit — would miss the window entirely.
        flash(displayIdentifiers: display.map { Set([$0]) },
              duration: max(anticipationFlashDuration, switchPendingUntil.timeIntervalSinceNow),
              animated: false)
        for panel in panels.values { panel.flushToScreen() }
    }

    // MARK: - Panels

    /// `displayFilter` limits which displays' panels show (by CGS display identifier);
    /// nil shows every display. `refreshData` re-enumerates first — skipped when the
    /// caller is itself reacting to a refresh.
    private func show(displayFilter: Set<String>?, animated: Bool, refreshData: Bool = true) {
        if refreshData { spaces.refresh() }
        for screen in NSScreen.screens {
            guard let did = screen.displayID else { continue }
            if let displayFilter,
               displayFilter.isDisjoint(with: Self.displayIdentifiers(for: screen)) { continue }
            let panel = panels[did] ?? {
                let p = SwitcherPanel(screenFrame: screen.frame)
                p.onTileClick = { [weak self] i in self?.tileClicked(i, displayID: did) }
                p.onNameClick = { [weak self] i in self?.nameClicked(i, displayID: did) }
                p.onHoverChanged = { [weak self] inside in self?.barHoverChanged(inside) }
                p.onBandPointerMoved = { [weak self] in self?.barPointerMoved() }
                p.onDragBegan = { [weak self] i, g in self?.dragBegan(displayID: did, tileIndex: i, global: g) }
                p.onDragMoved = { [weak self] g in self?.dragMoved(global: g) }
                p.onDragEnded = { [weak self] g in self?.dragEnded(global: g) }
                panels[did] = p
                return p
            }()
            panel.setFrame(screen.frame, display: false)
            let t = tiles(for: screen)
            panel.present(tiles: t, topInset: topInset(for: screen), animated: animated)
            HotkeyDiag.log("switcher show did=\(did) tiles=\(t.count) "
                           + "frame=\(panel.frame) visible=\(panel.isVisible) "
                           + "level=\(panel.level.rawValue)")
        }
    }

    private func hideAll(animated: Bool) {
        visibility = .hidden
        cancelFlashTimer()
        teardownDropTap()
        for panel in panels.values { panel.dismissPanel(animated: animated) }
    }

    // MARK: - Bar interaction

    private func screenAndSpaces(for displayID: CGDirectDisplayID)
        -> (screen: NSScreen, spaces: [Space])? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return nil }
        let ids = Self.displayIdentifiers(for: screen)
        let list = spaces.spaces
            .filter { ids.contains($0.displayIdentifier) }
            .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        return (screen, list)
    }

    private func tileClicked(_ index: Int, displayID: CGDirectDisplayID) {
        guard let (_, list) = screenAndSpaces(for: displayID),
              list.indices.contains(index), !list[index].isCurrent else { return }
        spaces.switchTo(list[index])
    }

    private func nameClicked(_ index: Int, displayID: CGDirectDisplayID) {
        guard let (screen, list) = screenAndSpaces(for: displayID),
              list.indices.contains(index) else { return }
        hideAll(animated: true)   // the editor is a regular window; clear the HUD first
        onEditRequest?(list[index].uuid, screen)
    }

    /// A flash stays open only while the pointer ACTIVELY hovers the band — but a cursor that
    /// merely rests where the flash happens to appear must NOT pin it (that left it up forever).
    /// So entering does nothing on its own; real movement over the bar (barPointerMoved) engages
    /// the pin, and leaving releases it into a fresh countdown. Both edges are reported by the
    /// panel's pointer watch — an AppKit mouseExited can't be relied on here (SwitcherPanel).
    private func barHoverChanged(_ inside: Bool) {
        guard drag == nil, visibility == .flashing else { return }
        if !inside, hoverPinned { restartFlashTimer(flashDuration) }
    }

    /// Actual pointer movement over the band engages the hover pin (Mission Control's bar behaves
    /// the same way); a stationary cursor never gets here, so the flash times out normally.
    private func barPointerMoved() {
        guard drag == nil, visibility == .flashing else { return }
        cancelFlashTimer()
        hoverPinned = true
    }

    // MARK: - Drag-to-reorder

    /// A tile drag crossed the threshold. Present every display (so the drag can cross onto
    /// them), snapshot each panel's tiles, freeze the panels' pointer watch, and start the
    /// ghost/reflow presentation.
    private func dragBegan(displayID: CGDirectDisplayID, tileIndex: Int, global: NSPoint) {
        guard enabled, Prefs.switcherStyle == .hud, drag == nil,
              let panel = panels[displayID] else { return }
        let originTiles = panel.currentTiles
        guard originTiles.indices.contains(tileIndex) else { return }
        let dragged = originTiles[tileIndex]
        cancelFlashTimer()
        // Make sure a panel exists on every display (a drag can begin during a one-display
        // flash); refreshData:false so the in-flight order isn't re-enumerated.
        show(displayFilter: nil, animated: false, refreshData: false)
        var tilesByDisplay: [CGDirectDisplayID: [SwitcherTile]] = [:]
        for (did, p) in panels { tilesByDisplay[did] = p.currentTiles }
        drag = DragSession(originDisplayID: displayID, draggedUUID: dragged.uuid,
                           draggedTile: dragged, isCurrentSpace: dragged.isCurrent,
                           originIndex: tileIndex, originCount: originTiles.count,
                           tilesByDisplay: tilesByDisplay,
                           targetDisplayID: displayID, targetIndex: tileIndex)
        for p in panels.values { p.dragActive = true }
        updateDragPresentations(global: global)
        HotkeyDiag.log("switcher drag began uuid=\(dragged.uuid.prefix(6)) display=\(displayID)")
    }

    private func dragMoved(global: NSPoint) {
        guard drag != nil else { return }
        updateDragPresentations(global: global)
    }

    private func dragEnded(global: NSPoint) {
        guard let started = drag else { return }
        updateDragPresentations(global: global)
        let session = drag ?? started
        drag = nil

        let sameSpot = session.targetDisplayID == session.originDisplayID
            && session.targetIndex == session.originIndex
        // Commit the move first (this updates the model to the new order). `settlingDrop`
        // makes the spacesChanged it posts a no-op for the panels, so the reflow the drag
        // already painted isn't torn down and replayed as a fresh row transition.
        settlingDrop = true
        if !sameSpot,
           let targetIdent = screenAndSpaces(for: session.targetDisplayID)?.spaces.first?.displayIdentifier
               ?? NSScreen.screens.first(where: { $0.displayID == session.targetDisplayID })
                   .flatMap({ Self.displayIdentifiers(for: $0).first }) {
            let ok = spaces.reorderSpace(session.draggedUUID,
                                         toDisplayIdentifier: targetIdent, index: session.targetIndex)
            HotkeyDiag.log("switcher drop uuid=\(session.draggedUUID.prefix(6)) "
                           + "-> \(targetIdent.prefix(8))[\(session.targetIndex)] ok=\(ok)")
        }
        settlingDrop = false
        // Swap every panel straight to the resulting order with no transition — the tiles
        // are already reflowed into these slots (or, on a rejected/no-op drop, this snaps
        // back to the truth).
        for screen in NSScreen.screens {
            guard let did = screen.displayID, let panel = panels[did] else { continue }
            panel.applySettled(tiles: tiles(for: screen), topInset: topInset(for: screen))
        }
        if session.pendingHideOnDrop || (!isChordHeld && visibility == .held) {
            hideAll(animated: true)
        } else if visibility == .flashing {
            restartFlashTimer(flashDuration)
        }
    }

    /// Abort a drag with no commit — snap every panel back to the enumerated order.
    private func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        for p in panels.values { p.dragActive = false; p.setDragPresentation(nil) }
        refreshVisible()
    }

    /// Recompute the target display/slot from the pointer and push a fresh presentation to
    /// every panel: the panel under the pointer opens a gap and shows the ghost; the origin
    /// panel (when the pointer is elsewhere) closes its gap; others draw normally.
    private func updateDragPresentations(global: NSPoint) {
        guard var session = drag else { return }
        var targetDID = (NSScreen.screens.first { $0.frame.contains(global) })?.displayID
            ?? session.originDisplayID
        // v1: a current space reorders only within its own display; never strand a display
        // with zero spaces. Either case pins the target back to the origin.
        if targetDID != session.originDisplayID,
           session.isCurrentSpace || session.originCount <= 1 {
            targetDID = session.originDisplayID
        }
        session.targetDisplayID = targetDID

        for (did, panel) in panels {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == did }) else {
                panel.setDragPresentation(nil); continue
            }
            let normal = session.tilesByDisplay[did] ?? panel.currentTiles
            let size = screen.frame.size
            let inset = topInset(for: screen)
            let localX = global.x - screen.frame.origin.x

            if did == targetDID {
                let isOrigin = did == session.originDisplayID
                let visible = isOrigin ? normal.filter { $0.uuid != session.draggedUUID } : normal
                let visLayout = SwitcherLayout.tiles(count: visible.count, screenSize: size,
                                                     topInset: inset, popover: hudPopover)
                let gap = SwitcherLayout.insertionIndex(forX: localX, in: visLayout.tileFrames)
                let slotLayout = SwitcherLayout.tiles(count: visible.count + 1, screenSize: size,
                                                      topInset: inset, popover: hudPopover)
                var targets: [SwitcherBarView.DragTarget] = []
                var vi = 0
                for (si, frame) in slotLayout.tileFrames.enumerated() where si != gap {
                    guard vi < visible.count else { break }
                    targets.append(.init(uuid: visible[vi].uuid, tile: visible[vi], frame: frame))
                    vi += 1
                }
                panel.setDragPresentation(.init(targets: targets, ghostTile: session.draggedTile,
                                                ghostFrame: ghostRect(localX: localX, layout: slotLayout,
                                                                      size: size, inset: inset)))
                session.targetIndex = gap
            } else if did == session.originDisplayID {
                let visible = normal.filter { $0.uuid != session.draggedUUID }
                let layout = SwitcherLayout.tiles(count: visible.count, screenSize: size,
                                                  topInset: inset, popover: hudPopover)
                var targets: [SwitcherBarView.DragTarget] = []
                for (i, tile) in visible.enumerated() where layout.tileFrames.indices.contains(i) {
                    targets.append(.init(uuid: tile.uuid, tile: tile, frame: layout.tileFrames[i]))
                }
                panel.setDragPresentation(.init(targets: targets, ghostTile: nil, ghostFrame: .zero))
            } else {
                panel.setDragPresentation(nil)
            }
        }
        drag = session
    }

    /// Ghost rect: tile-sized, centered on the pointer's x, pinned to the bar's tile row and
    /// clamped to the screen.
    private func ghostRect(localX: CGFloat, layout: SwitcherLayout.Result,
                           size: CGSize, inset: CGFloat) -> CGRect {
        let ts = layout.tileSize
        let y = layout.tileFrames.first?.minY ?? (size.height - inset - ts.height)
        let x = max(0, min(localX - ts.width / 2, size.width - ts.width))
        return CGRect(x: x, y: y, width: ts.width, height: ts.height)
    }

    // MARK: - Window → workspace drag-and-drop

    /// Install an ACTIVE pass-through session tap (mouse down/dragged/up) for the duration of a
    /// hold, so a window dragged from anywhere onto a tile can be caught. Only useful for the HUD
    /// style and only while Accessibility is granted (already required to switch); a no-op otherwise.
    private func installDropTap() {
        guard dropTap == nil, enabled, Prefs.switcherStyle == .hud, AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        // TAP THREAD, pure pass-through observer: always return the event unmodified so
        // the window's own drag is never disturbed, and do ALL handling (panel geometry,
        // hover highlights, the drop) on main — never on the event path.
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<SwitcherHUD>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.dropTapRef.get() { me.dropTapReviver.tapWasDisabled(tap) }
                return Unmanaged.passUnretained(event)
            }
            let location = event.location
            DispatchQueue.main.async { me.handleDropEvent(type: type, cgLocation: location) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: info) else {
            HotkeyDiag.log("switcher drop tap unavailable")
            return
        }
        dropTap = tap
        dropTapRef.set(tap)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        TapThread.add(src)
        dropTapSource = src
        HotkeyDiag.log("switcher drop tap installed")
        adoptInFlightDrag()
    }

    /// Main-thread tail of the drop tap. Only act while the switcher is held; ignore the
    /// move's OWN synthetic grab events (titleBarDragInFlight) so a drop doesn't
    /// re-trigger itself.
    private func handleDropEvent(type: CGEventType, cgLocation: CGPoint) {
        guard visibility == .held, !WindowMover.standDownForMove else { return }
        switch type {
        case .leftMouseDown:    dropMouseDown(cgPoint: cgLocation)
        case .leftMouseDragged: dropMouseDragged()
        case .leftMouseUp:      dropMouseUp()
        default: break
        }
    }

    /// If the user grabbed a window and started dragging BEFORE opening the switcher, the
    /// press already happened (no tap yet) so `dropMouseDown` never ran. Detect the in-flight
    /// drag when the tap installs — left button already down — and seed the candidate from the
    /// window currently under the cursor, so the remaining drag/drop is tracked as usual.
    private func adoptInFlightDrag() {
        guard dropCandidate == nil, NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let cg = CGEvent(source: nil)?.location ?? .zero   // current cursor, CG top-left
        guard let hit = WindowMover.windowUnder(cgPoint: cg, excludingPID: ourPID) else { return }
        dropCandidate = hit
        dropMoved = true   // a drag is already underway
        let g = NSEvent.mouseLocation
        for panel in panels.values { panel.setDropHover(panel.tileIndex(atGlobal: g)) }
        HotkeyDiag.log("switcher adopted in-flight drag wid=\(hit.wid)")
    }

    private func teardownDropTap() {
        dropCandidate = nil
        dropMoved = false
        for panel in panels.values { panel.setDropHover(nil) }
        dropTapRef.set(nil)
        TapTeardown.tearDown(tap: dropTap, source: dropTapSource)
        dropTapSource = nil
        dropTap = nil
    }

    /// Press: if it landed on the panel band it's a tile click / reorder (leave those alone);
    /// otherwise remember the foreign window under the cursor as the drag candidate.
    private func dropMouseDown(cgPoint: CGPoint) {
        dropCandidate = nil
        dropMoved = false
        let g = NSEvent.mouseLocation
        for panel in panels.values where panel.isPresented && panel.isInBand(global: g) { return }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        dropCandidate = WindowMover.windowUnder(cgPoint: cgPoint, excludingPID: ourPID)
    }

    /// Drag: light up the tile under the pointer (on whichever panel it's over), clear the rest.
    private func dropMouseDragged() {
        guard dropCandidate != nil else { return }
        dropMoved = true
        let g = NSEvent.mouseLocation
        for panel in panels.values { panel.setDropHover(panel.tileIndex(atGlobal: g)) }
    }

    /// Release: if it's over a tile (and the window actually moved), hide the panels and jump the
    /// dragged window onto that workspace. Deferred to the next runloop hop so we don't tear the
    /// tap down from inside its own callback, and the window's own drop settles first.
    private func dropMouseUp() {
        guard let cand = dropCandidate else { return }
        dropCandidate = nil
        let g = NSEvent.mouseLocation
        var target: Space?
        for (did, panel) in panels {
            guard let idx = panel.tileIndex(atGlobal: g),
                  let (_, list) = screenAndSpaces(for: did), list.indices.contains(idx) else { continue }
            target = list[idx]; break
        }
        for panel in panels.values { panel.setDropHover(nil) }
        guard dropMoved, let target, !target.isCurrent, !target.isFullscreen else { return }
        dropMoved = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            HotkeyDiag.log("windowDrop wid=\(cand.wid) -> space \(target.managedSpaceID) "
                           + "(#\(target.ordinalOnDisplay + 1))")
            do {
                try WindowMover.move(wid: cand.wid, to: target, spaces: self.spaces)
                // Deliberately DON'T hide the switcher: it stays as it is (held), so it fades only
                // when the hold shortcut is released — never pinned open by the pointer hovering the
                // band. Just pass the panels through for the move's synthetic re-grab (they
                // self-restore via pointerWatch once the move ends).
                for panel in self.panels.values { panel.suppressMouseForMove() }
            } catch { NSSound.beep(); HotkeyDiag.log("windowDrop failed: \(error)") }
        }
    }

    /// Refresh contents of any visible panel in place (space change while shown).
    private func refreshVisible() {
        for screen in NSScreen.screens {
            guard let did = screen.displayID, let panel = panels[did],
                  panel.isPresented else { continue }
            panel.refresh(tiles: tiles(for: screen), topInset: topInset(for: screen))
        }
    }

    /// Internal (not private) so the `--probe-switcher` headless render can reuse the
    /// exact production tile-building path.
    func tiles(for screen: NSScreen) -> [SwitcherTile] {
        let ids = Self.displayIdentifiers(for: screen)
        let display = spaces.spaces
            .filter { ids.contains($0.displayIdentifier) }
            .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        let scale = screen.backingScaleFactor
        let tileSize = SwitcherLayout.tiles(count: display.count,
                                            screenSize: screen.frame.size,
                                            popover: hudPopover).tileSize
        let pixelSize = CGSize(width: tileSize.width * scale, height: tileSize.height * scale)
        let fallbackPath = NSWorkspace.shared.desktopImageURL(for: screen)?.path
        return display.map { space in
            let meta = store.metadata(for: space.uuid)
            // Caption mirrors MC's own text under the tile; the custom name and icon go
            // in the row above, under the same prefs as the Mission Control overlay.
            var name: String?
            if Prefs.thumbnailNamesVisible, let n = meta.name, !n.isEmpty { name = n }
            var icon: NSImage?
            if Prefs.thumbnailIconStyle != .hidden {
                // Same sizes as the Mission Control overlay's labels: 14 pt inline beside a
                // name, 24 pt when the icon stands alone above or sits ON the thumbnail
                // (the panel routes it per the same style pref at draw time).
                icon = IconRendering.image(for: meta,
                                           pointSize: Prefs.thumbnailIconStyle == .beforeName ? 14 : 24)
            }
            let app = fullscreenApp(for: space)
            return SwitcherTile(uuid: space.uuid,
                                caption: space.isFullscreen
                                    ? (app?.name ?? "Full-Screen App")
                                    : "Desktop \(space.ordinalOnDisplay + 1)",
                                name: name,
                                icon: icon,
                                wallpaper: wallpapers.thumbnail(for: space.uuid,
                                                               fallbackPath: fallbackPath,
                                                               pixelSize: pixelSize),
                                appBadge: app?.icon,
                                isCurrent: space.isCurrent,
                                isFullscreen: space.isFullscreen)
        }
    }

    /// App identity (name + icon) behind a fullscreen space, from the pid the window
    /// server records in the space dictionary. Cached per pid so repeated refreshes
    /// reuse the same NSImage instance — SwitcherTile equality is identity-based, and a
    /// fresh icon every refresh would force a crossfade each time.
    private var fullscreenAppCache: [pid_t: (name: String?, icon: NSImage?)] = [:]
    private func fullscreenApp(for space: Space) -> (name: String?, icon: NSImage?)? {
        guard space.isFullscreen, let pid = space.fullscreenPID else { return nil }
        if let cached = fullscreenAppCache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let entry = (app.localizedName, app.icon)
        fullscreenAppCache[pid] = entry
        return entry
    }

    /// CGS display identifiers this screen answers to ("Main" for the main display).
    static func displayIdentifiers(for screen: NSScreen) -> [String] {
        guard let did = screen.displayID else { return [] }
        var ids: [String] = []
        if let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, u) as String? { ids.append(s) }
        if did == CGMainDisplayID() { ids.append("Main") }
        return ids
    }

    /// Tiles sit where MC's bar puts them: 39 pt of chrome below the safe area
    /// (pixel-matched against the real bar on the notched built-in display).
    private func topInset(for screen: NSScreen) -> CGFloat {
        SwitcherLayout.defaultTopInset + screen.safeAreaInsets.top
    }

    /// Classic Popover position selected: layout calls center the bar instead of pinning
    /// it under the menu bar (SwitcherPanel.apply reads the same pref for its own layout).
    private var hudPopover: Bool { Prefs.switcherPosition == .classicPopover }

    // MARK: - Timers & notifications

    private func restartFlashTimer(_ duration: TimeInterval) {
        hoverPinned = false   // any fresh countdown supersedes the hover pin
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.visibility == .flashing else { return }
            self.hideAll(animated: true)
        }
    }

    private func cancelFlashTimer() {
        flashTimer?.invalidate()
        flashTimer = nil
    }

    private func startChordPoll() {
        guard chordSpec != nil else { return }
        chordPollMisses = 0
        chordPollTimer?.invalidate()
        chordPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25,
                                              repeats: true) { [weak self] _ in
            guard let self, let spec = self.chordSpec else { return }
            if Self.chordPhysicallyDown(spec) {
                self.chordPollMisses = 0
            } else {
                // Two consecutive misses so a momentary rollover can't false-release.
                self.chordPollMisses += 1
                if self.chordPollMisses >= 2 { self.chordUp() }
            }
        }
    }

    private func stopChordPoll() {
        chordPollTimer?.invalidate()
        chordPollTimer = nil
        chordSpec = nil
    }

    /// Both are queries, not taps — no Accessibility/Input Monitoring needed. The
    /// caps-hyper layer counts as holding its mapped modifiers (physically it's a
    /// swallowed F18, invisible to NSEvent.modifierFlags).
    static func chordPhysicallyDown(_ spec: ShortcutSpec) -> Bool {
        var mods = ShortcutSpec.sanitize(NSEvent.modifierFlags)
        if CapsLockHyper.isHyperDown { mods |= CapsLockHyper.hyperNSModifiers }
        guard mods & spec.modifiers == spec.modifiers else { return false }
        // A modifier-only chord has no key to query (its keyCode is a sentinel).
        if spec.isModifierOnly { return true }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(spec.keyCode))
    }

    /// Spaces model changed (switch, add/remove, focus move). Records wallpapers
    /// (cache-on-visit), refreshes any visible panel in place, and — when a display's
    /// current space actually changed — triggers the flash on just that display.
    @objc private func spacesChanged() {
        // The drop commit updates the panels itself (see dragEnded) — ignore the
        // spacesChanged it posts so the settled reflow isn't replayed as a row transition.
        if settlingDrop { return }
        // Mid-drag: the drag presentation owns the panels. A change that keeps the same
        // uuid set is just our own optimistic reorder overlay (or a benign highlight move)
        // — ignore it so the reflow isn't stomped; a set change (space added/removed) makes
        // the drag stale, so abort it.
        if drag != nil {
            let live = Set(spaces.spaces.map(\.uuid))
            let captured = Set(drag!.tilesByDisplay.values.flatMap { $0 }.map(\.uuid))
            if live != captured { cancelDrag() }
            return
        }
        // Skip recording while a switch prediction is in flight: mid-animation the
        // display still reports the outgoing wallpaper, which would be filed under the
        // target space. The post-landing refresh records the settled truth.
        if !spaces.hasPendingPrediction {
            wallpapers.scheduleRecord(spaces: { [weak self] in self?.spaces.spaces ?? [] })
        }
        let previous = lastCurrentByDisplay
        var newCurrent: [String: String] = [:]
        for s in spaces.spaces where s.isCurrent { newCurrent[s.displayIdentifier] = s.uuid }
        let changed = Set(newCurrent.filter { previous[$0.key] != $0.value }.keys)
        lastCurrentByDisplay = newCurrent
        if !changed.isEmpty { lastSpaceChangeAt = Date() }
        switch visibility {
        case .held, .flashing:
            refreshVisible()
            // Rapid consecutive switches keep one continuous flash instead of flickering. An
            // anticipated switch lands here at INITIATION (the optimistic prediction posts
            // immediately), so honour its pending deadline too — otherwise the countdown would
            // start with the whole animation still ahead and the popover could go before the
            // transition finished. Once that deadline passes, the min-shown wins.
            if visibility == .flashing, !changed.isEmpty {
                restartFlashTimer(max(flashDuration, switchPendingUntil.timeIntervalSinceNow))
            }
        case .hidden:
            guard !changed.isEmpty, Prefs.switcherFlashOnSpaceChange else { return }
            flash(displayIdentifiers: changed)
        }
    }

    @objc private func mcWillOpen() { suppressForMissionControl(autoClear: 1.5) }
    @objc private func mcOpened() { suppressForMissionControl(autoClear: nil) }

    @objc private func mcClosed() {
        mcClearTimer?.invalidate()
        mcClearTimer = nil
        guard mcSuppressed else { return }
        mcSuppressed = false
        // Native style holds show MC / the bar itself — closing must not summon the HUD.
        if isChordHeld, Prefs.switcherStyle == .hud {
            show(displayFilter: nil, animated: true)
        }
    }

    /// Mission Control is taking the screen: drop the panels instantly (no fade — MC's own
    /// animation is running). A `WillOpen` without the overlay engine's `Opened`/`Closed`
    /// confirmation auto-clears after `autoClear` so suppression can't stick forever.
    private func suppressForMissionControl(autoClear: TimeInterval?) {
        cancelDrag()   // MC is taking the screen — abort any in-flight tile drag first
        mcClearTimer?.invalidate()
        mcClearTimer = nil
        mcSuppressed = true
        cancelFlashTimer()
        if visibility == .flashing { visibility = .hidden }
        for panel in panels.values { panel.dismissPanel(animated: false) }
        if let autoClear {
            mcClearTimer = Timer.scheduledTimer(withTimeInterval: autoClear,
                                                repeats: false) { [weak self] _ in
                self?.mcClosed()
            }
        }
    }

    @objc private func screensChanged() {
        let wasVisible = visibility != .hidden
        for panel in panels.values {
            panel.dismissPanel(animated: false)
            panel.close()
        }
        panels.removeAll()
        if wasVisible, !mcSuppressed { show(displayFilter: nil, animated: false) }
    }

    @objc private func debugCommand(_ note: Notification) {
        guard let payload = note.object as? String else { return }
        HotkeyDiag.log("switcher debugCommand \(payload) enabled=\(enabled) "
                       + "mcSuppressed=\(mcSuppressed) visibility=\(visibility)")
        if payload.hasPrefix("show:") {
            let seconds = TimeInterval(payload.dropFirst("show:".count)) ?? 3
            flash(duration: seconds)
        } else if payload == "down" {
            chordDown()
        } else if payload == "up" {
            chordUp()
        } else if payload == "frames" {
            // Log each visible panel's tile centers in global CG (top-left) coords, so the
            // --post-drag harness can aim at real tiles without re-deriving the layout math.
            let primaryH = NativeBarWindows.primaryHeight()
            for screen in NSScreen.screens {
                guard let did = screen.displayID, let panel = panels[did], panel.isPresented else { continue }
                let t = tiles(for: screen)
                let layout = SwitcherLayout.tiles(count: t.count, screenSize: screen.frame.size,
                                                  topInset: topInset(for: screen), popover: hudPopover)
                let centers = layout.tileFrames.map { f -> String in
                    let gx = Int(screen.frame.origin.x + f.midX)
                    let gy = Int(primaryH - (screen.frame.origin.y + f.midY))
                    return "\(gx),\(gy)"
                }
                HotkeyDiag.log("switcher frames did=\(did) n=\(t.count): \(centers.joined(separator: " "))")
            }
        }
    }
}

extension SwitcherHUD {
    static func selfChecks(_ check: SelfTest.Check) {
        func sp(_ uuid: String) -> Space {
            Space(uuid: uuid, managedSpaceID: 0, type: 0, displayIndex: 0,
                  displayIdentifier: "d", ordinalOnDisplay: 0, isCurrent: false)
        }
        let list = [sp("A"), sp("B"), sp("C")]
        check(wrapNeighbor(forward: true, list: list, currentUUID: "C")?.uuid == "A",
              "arrow wrap: right at last -> first")
        check(wrapNeighbor(forward: false, list: list, currentUUID: "A")?.uuid == "C",
              "arrow wrap: left at first -> last")
        check(wrapNeighbor(forward: true, list: list, currentUUID: "B")?.uuid == "C",
              "arrow wrap: right mid-row -> adjacent")
        check(wrapNeighbor(forward: false, list: list, currentUUID: "B")?.uuid == "A",
              "arrow wrap: left mid-row -> adjacent")
        check(wrapNeighbor(forward: true, list: [sp("A")], currentUUID: "A") == nil,
              "arrow wrap: single space -> nil")
        check(wrapNeighbor(forward: false, list: list, currentUUID: "Z") == nil,
              "arrow wrap: unknown current -> nil")
    }
}
