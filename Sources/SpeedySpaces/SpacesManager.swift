import AppKit

/// Enumerates macOS Spaces via the private window-server API, tracks the current
/// space, and performs best-effort switching. All private calls are contained here.
final class SpacesManager {
    /// Called whenever the set of spaces or the current space may have changed.
    var onChange: (() -> Void)?

    /// Published space list, with the optimistic-switch prediction applied (see below).
    private(set) var spaces: [Space] = []
    /// The list exactly as enumerated from the window server — what verification judges.
    private var rawSpaces: [Space] = []
    /// Optimistic UI: the space we just asked an engine to switch to. The window server
    /// doesn't report the new space as current until the transition animation lands, so the
    /// menubar would otherwise lag the click by the whole animation. While set, `spaces`
    /// shows this space as current on its display; dropped when enumeration agrees, when the
    /// switch fails (revert), or after 3 s (safety).
    private var predicted: (uuid: String, displayIndex: Int, expires: Date)?
    /// Optimistic reorder: a space we just asked the window server to relocate (drag-to-
    /// reorder in the switcher HUD). Enumeration lags the move slightly, so `spaces` shows
    /// the new order right away; dropped when raw enumeration agrees or after 3 s (safety),
    /// at which point the HUD's row transition animates any disagreement as a revert.
    private var pendingReorder: (uuid: String, displayIdentifier: String, index: Int, expires: Date)?

    /// Back-and-forth memory: per display, the space that was current before the one that
    /// is current now. Maintained from raw enumeration diffs (native switches) and from
    /// `switchTo` (our own switches, so a rapid double back-and-forth is correct before
    /// enumeration catches up).
    private var lastCurrentUUIDByDisplay: [String: String] = [:]
    /// Per-display current uuid as of the last update — the diff baseline. Updated
    /// optimistically in `switchTo` so an app-initiated A→B→C records B (not A) as last.
    private var currentUUIDByDisplay: [String: String] = [:]

    init() {
        refresh()
        // Public notification — fires when the active space changes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // Switching the focused app often coincides with moving to another display;
        // refresh so the menubar can reflect the newly-focused display's space.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        SpacesManagerHolder.shared = self
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeSpaceChanged() {
        refresh()
    }

    var currentSpace: Space? {
        spaces.first(where: { $0.isCurrent })
    }

    /// The current space to surface in the menubar. When `preferFocusedDisplay` is set
    /// and we can identify the focused display, returns that display's current space;
    /// otherwise falls back to the global current space (correct for single-display).
    func currentSpace(preferFocusedDisplay: Bool) -> Space? {
        if preferFocusedDisplay, let match = currentSpaceOnFocusedDisplay() {
            return match
        }
        return currentSpace
    }

    /// Display index of the display the user is working on (pref-independent; falls back
    /// to the global current space's display). Drives the all-displays strip's collapse.
    func focusedDisplayIndex() -> Int? {
        (currentSpaceOnFocusedDisplay() ?? currentSpace)?.displayIndex
    }

    private func currentSpaceOnFocusedDisplay() -> Space? {
        guard let screen = NSScreen.main,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let candidateIDs = Self.displayIdentifiers(for: num.uint32Value)
        return spaces.first {
            $0.isCurrent && candidateIDs.contains($0.displayIdentifier)
        }
    }

    /// CGS identifier strings a display answers to: its UUID string, plus "Main" for the
    /// primary display (the window server labels it that way on some OSes).
    private static func displayIdentifiers(for displayID: CGDirectDisplayID) -> [String] {
        var candidateIDs: [String] = []
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let cfuuid = unmanaged.takeRetainedValue()  // "Create" => +1, we own it
            if let str = CFUUIDCreateString(nil, cfuuid) as String? {
                candidateIDs.append(str)
            }
        }
        if displayID == CGMainDisplayID() { candidateIDs.append("Main") }
        return candidateIDs
    }

    /// The pointer display's spaces and current space. macOS's own space-switching
    /// shortcuts (⌃-arrows, ⌃N) act on the display under the POINTER — the app's
    /// switching hotkeys resolve here so they behave identically. Falls back to the
    /// focused display when the pointer's screen can't be identified.
    func pointerDisplaySpaces() -> (spaces: [Space], current: Space?) {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return focusedDisplaySpaces() }
        let ids = Self.displayIdentifiers(for: num.uint32Value)
        guard let cur = spaces.first(where: { $0.isCurrent && ids.contains($0.displayIdentifier) })
        else { return focusedDisplaySpaces() }
        let list = spaces.filter { $0.displayIndex == cur.displayIndex }
            .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        return (list, cur)
    }

    /// Re-query the window server and rebuild the space list.
    func refresh() {
        rawSpaces = Self.enumerateSpaces()
        if let p = predicted,
           Date() >= p.expires || rawSpaces.first(where: { $0.uuid == p.uuid })?.isCurrent == true {
            predicted = nil   // reality caught up (or the prediction went stale)
        }
        if let r = pendingReorder {
            // Converged once re-applying the move to raw is a no-op (raw already reflects it),
            // or expired (raw truth then flows through and the HUD animates the difference).
            let reappliedMatchesRaw = Self.sameOrder(
                Self.reordered(rawSpaces, moving: r.uuid, toDisplay: r.displayIdentifier, index: r.index),
                rawSpaces)
            if Date() >= r.expires || reappliedMatchesRaw { pendingReorder = nil }
        }
        // Track back-and-forth memory against RAW state (never the predicted overlay).
        var newCurrent: [String: String] = [:]
        for s in rawSpaces where s.isCurrent { newCurrent[s.displayIdentifier] = s.uuid }
        lastCurrentUUIDByDisplay = Self.updatedLastSpaces(
            previousCurrent: currentUUIDByDisplay, newCurrent: newCurrent,
            last: lastCurrentUUIDByDisplay)
        currentUUIDByDisplay = newCurrent
        spaces = overlaid(rawSpaces)
        onChange?()
        // Multicast change signal (onChange is a single closure owned by the status item).
        // Fires after `spaces` — including the optimistic prediction — is updated.
        NotificationCenter.default.post(name: .speedySpacesSpacesChanged, object: nil)
    }

    /// Pure diff step for the back-and-forth memory: any display whose current space
    /// changed rolls its old current into `last`.
    static func updatedLastSpaces(previousCurrent: [String: String],
                                  newCurrent: [String: String],
                                  last: [String: String]) -> [String: String] {
        var out = last
        for (display, cur) in newCurrent {
            if let prev = previousCurrent[display], prev != cur { out[display] = prev }
        }
        return out
    }

    /// The focused display's spaces (ordered by ordinalOnDisplay) and its current space —
    /// the list the menubar strip renders and hotkey space-numbering resolves against.
    func focusedDisplaySpaces() -> (spaces: [Space], current: Space?) {
        let cur = currentSpace(preferFocusedDisplay: Prefs.menuBarFollowsFocusedDisplay)
        let list = cur.map { c in
            spaces.filter { $0.displayIndex == c.displayIndex }
                .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        } ?? []
        return (list, cur)
    }

    /// The back-and-forth target: the previously-current space on the POINTER's display
    /// (the display the switch will act on — see pointerDisplaySpaces), if it still exists.
    func backAndForthTarget() -> Space? {
        guard let cur = pointerDisplaySpaces().current,
              let lastUUID = lastCurrentUUIDByDisplay[cur.displayIdentifier],
              lastUUID != cur.uuid
        else { return nil }
        return spaces.first { $0.uuid == lastUUID }
    }

    /// `rawSpaces` with the optimistic overlays applied: the pending reorder permutation
    /// first (so ordinals/captions renumber), then the switch prediction's current marker.
    private func overlaid(_ list: [Space]) -> [Space] {
        var out = list
        if let r = pendingReorder {
            out = Self.reordered(out, moving: r.uuid, toDisplay: r.displayIdentifier, index: r.index)
        }
        if let p = predicted {
            out = out.map { space in
                var space = space
                if space.displayIndex == p.displayIndex { space.isCurrent = space.uuid == p.uuid }
                return space
            }
        }
        return out
    }

    /// Pure permutation for the reorder overlay: move `uuid` to position `index` within
    /// display `displayID`, recomputing each affected space's `ordinalOnDisplay` (and its
    /// display membership for a cross-display move). Currency is preserved as enumerated —
    /// the HUD forbids moving a current space across displays, so no display loses its
    /// current space. Displays keep their first-seen order; a no-op input returns an
    /// equal-ordered list.
    static func reordered(_ list: [Space], moving uuid: String,
                          toDisplay displayID: String, index: Int) -> [Space] {
        guard let moved = list.first(where: { $0.uuid == uuid }) else { return list }
        var displayIndexFor: [String: Int] = [:]
        var order: [String] = []
        var byDisplay: [String: [Space]] = [:]
        for s in list {
            if displayIndexFor[s.displayIdentifier] == nil {
                displayIndexFor[s.displayIdentifier] = s.displayIndex
                order.append(s.displayIdentifier)
            }
            if s.uuid == uuid { continue }
            byDisplay[s.displayIdentifier, default: []].append(s)
        }
        if !order.contains(displayID) {
            order.append(displayID)
            displayIndexFor[displayID] = displayIndexFor[displayID] ?? order.count - 1
        }
        var target = byDisplay[displayID] ?? []
        target.insert(moved, at: max(0, min(index, target.count)))
        byDisplay[displayID] = target
        var out: [Space] = []
        for disp in order {
            let dIndex = displayIndexFor[disp] ?? 0
            for (ordinal, s) in (byDisplay[disp] ?? []).enumerated() {
                out.append(Space(uuid: s.uuid, managedSpaceID: s.managedSpaceID, type: s.type,
                                 displayIndex: dIndex, displayIdentifier: disp,
                                 ordinalOnDisplay: ordinal, isCurrent: s.isCurrent,
                                 fullscreenPID: s.fullscreenPID))
            }
        }
        return out
    }

    /// Order equality by (uuid, display, ordinal) — the fields the reorder overlay rewrites.
    static func sameOrder(_ a: [Space], _ b: [Space]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where
            x.uuid != y.uuid || x.displayIdentifier != y.displayIdentifier
            || x.ordinalOnDisplay != y.ordinalOnDisplay { return false }
        return true
    }

    // MARK: - Enumeration

    private static func enumerateSpaces() -> [Space] {
        let conn = sm_mainConnectionID()
        guard let displays = sm_copyManagedDisplaySpaces(conn) as? [[String: Any]] else {
            return []
        }
        return parseSpaces(displays: displays)
    }

    /// Pure dict → [Space] parse of the CGS managed-display-spaces payload,
    /// split from the live connection read so it is self-testable.
    static func parseSpaces(displays: [[String: Any]]) -> [Space] {
        var result: [Space] = []
        for (displayIndex, display) in displays.enumerated() {
            let displayID = (display["Display Identifier"] as? String) ?? "Display\(displayIndex)"
            let currentUUID = (display["Current Space"] as? [String: Any])?["uuid"] as? String
            let spaceDicts = (display["Spaces"] as? [[String: Any]]) ?? []

            for (ordinal, spaceDict) in spaceDicts.enumerated() {
                guard let uuid = spaceDict["uuid"] as? String else { continue }
                let managedID = (spaceDict["ManagedSpaceID"] as? Int) ?? -1
                let type = (spaceDict["type"] as? Int) ?? 0
                result.append(Space(
                    uuid: uuid,
                    managedSpaceID: managedID,
                    type: type,
                    displayIndex: displayIndex,
                    displayIdentifier: displayID,
                    ordinalOnDisplay: ordinal,
                    isCurrent: uuid == currentUUID,
                    fullscreenPID: (spaceDict["pid"] as? Int).map { pid_t($0) }
                ))
            }
        }
        return result
    }

    // MARK: - Switching (best-effort)

    /// Whether we can post the synthetic key events used to switch spaces.
    var canSwitch: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user for Accessibility permission (needed to post key events).
    @discardableResult
    func requestSwitchPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Engines keyed by method (dispatcher registry).
    private lazy var engines: [SwitchMethod: SpaceSwitcher] = [
        .gesture: GestureSwitcher(),
        .missionControl: MissionControlSwitcher(),
    ]
    private let verifier = SwitchVerifier()

    /// Invoked when the selected engine refuses because Accessibility isn't granted.
    var onAccessibilityNeeded: (() -> Void)?
    /// Most recent switch attempt (for the Settings scoreboard).
    private(set) var lastOutcome: SwitchOutcome?

    private func context(for target: Space) -> SwitchContext {
        let current = spaces.first { $0.isCurrent && $0.displayIndex == target.displayIndex }
        return SwitchContext(current: current,
                             isTrusted: AXIsProcessTrusted(), animation: Prefs.gestureAnimation)
    }

    /// True while an optimistic switch prediction is overlaid on `spaces` (the switch
    /// animation is presumed in flight and enumeration hasn't confirmed the target yet).
    var hasPendingPrediction: Bool { predicted != nil }

    @discardableResult
    func switchTo(_ target: Space, dismissedShowDesktop: Bool = false) -> Bool {
        // macOS "Show Desktop" (clicked wallpaper / F11 / hot corner) silently swallows every space
        // switch until it's dismissed — the switch just times out. Detect it (WindowManager's
        // full-screen layer-18 overlay, present even on an empty desktop), send the Dock's dismiss,
        // then re-run the switch once the overlay clears. Guarded so we ever dismiss at most once.
        if !dismissedShowDesktop, NativeBarWindows.showDesktopActive() {
            // Show the switcher immediately so the popover bridges the dismiss+settle delay,
            // staying up continuously until the space actually changes (the landing re-flashes it).
            NotificationCenter.default.post(name: .speedySpacesAnticipateSwitch, object: nil,
                                            userInfo: ["display": target.displayIdentifier,
                                                       "deferred": true])
            _ = sm_coreDockSendNotification("com.apple.showdesktop.awake" as CFString)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Wait for the overlay window to clear...
                for _ in 0..<30 {   // ≤ ~0.6 s; break the instant the overlay clears
                    if !NativeBarWindows.showDesktopActive() { break }
                    usleep(20_000)
                }
                // ...then let the dismiss's window slide-back finish. The overlay disappears well
                // before the WindowServer settles, and a switch fired mid-animation is still
                // swallowed (verified: the switch times out). This beat is what makes it land.
                usleep(500_000)
                DispatchQueue.main.async { self?.switchTo(target, dismissedShowDesktop: true) }
            }
            return true
        }
        guard let engine = engines[Prefs.switchMethod] else {
            let reason = "no engine registered for \(Prefs.switchMethod.rawValue)"
            NSLog("[SpeedySpaces] \(reason)")
            publish(SwitchOutcome(method: Prefs.switchMethod, fromOrdinal: nil,
                                  toOrdinal: target.ordinalOnDisplay, displayIndex: target.displayIndex,
                                  ok: false, milliseconds: 0, reason: reason))
            return false
        }
        let ctx = context(for: target)
        switch engine.availability(for: target, ctx) {
        case .unavailable(let reason):
            NSLog("[SpeedySpaces] switch(\(engine.method.rawValue)) refused: \(reason)")
            publish(SwitchOutcome(method: engine.method, fromOrdinal: ctx.current?.ordinalOnDisplay,
                                  toOrdinal: target.ordinalOnDisplay, displayIndex: target.displayIndex,
                                  ok: false, milliseconds: 0, reason: reason))
            if reason.localizedCaseInsensitiveContains("accessibility") { onAccessibilityNeeded?() }
            return false
        case .available:
            // Raise the switcher BEFORE the engine starts the transition. The window server
            // doesn't composite a window ordered in once the space slide is under way — it
            // surfaces only when the slide ends — so the popover used to appear after the
            // animation rather than ahead of it. The HUD shows synchronously on this
            // notification and holds through the transition (see SwitcherHUD.anticipateSwitch).
            // Not for the Mission Control engine: it puts the real Mission Control on screen,
            // which the HUD suppresses itself for — anticipating there is just a blink.
            if engine.method != .missionControl {
                NotificationCenter.default.post(name: .speedySpacesAnticipateSwitch, object: nil,
                                                userInfo: ["display": target.displayIdentifier])
            }
            let start = DispatchTime.now()
            do { try engine.perform(target, ctx) }
            catch {
                publish(SwitchOutcome(method: engine.method, fromOrdinal: ctx.current?.ordinalOnDisplay,
                                      toOrdinal: target.ordinalOnDisplay, displayIndex: target.displayIndex,
                                      ok: false, milliseconds: 0, reason: "\(error)"))
                return false
            }
            // Back-and-forth memory: record the from-space now (ctx.current predates the
            // prediction), and advance the diff baseline to the target so the eventual
            // enumeration catch-up doesn't overwrite `last` with a stale value.
            if let from = ctx.current, from.uuid != target.uuid {
                lastCurrentUUIDByDisplay[target.displayIdentifier] = from.uuid
                currentUUIDByDisplay[target.displayIdentifier] = target.uuid
            }
            // Optimistic UI: show the target as current right away — before the switch
            // animation runs — and let refresh()/publish() reconcile or revert it.
            predicted = (target.uuid, target.displayIndex, Date().addingTimeInterval(3))
            spaces = overlaid(rawSpaces)
            onChange?()
            // Multicast the prediction too, so the switcher HUD flashes at initiation
            // (with the animation still ahead) instead of on the post-switch refresh.
            NotificationCenter.default.post(name: .speedySpacesSpacesChanged, object: nil)
            // Verification must judge the RAW state — with the prediction overlaid on
            // `spaces`, reading it here would instantly (and falsely) confirm every switch.
            verifier.verify(method: engine.method, target: target, from: ctx.current, start: start,
                            refresh: { [weak self] in self?.refresh() },
                            isCurrentTarget: { [weak self] in self?.rawSpaces.first { $0.uuid == target.uuid }?.isCurrent ?? false },
                            completion: { [weak self] outcome in self?.publish(outcome) })
            return true
        }
    }

    /// Relocate a managed space to `index` on display `displayID` via the window server's
    /// own Mission-Control-tile-drag commit (invisible — no MC flash). Applies an optimistic
    /// overlay so the HUD shows the new order immediately, then reconciles against
    /// enumeration. Returns false if the window server rejected the move (the HUD then snaps
    /// the tile back). The move holds for the login session; `CGSPersistenceSaveSpaceConfiguration`
    /// is attempted best-effort but is Dock-privileged and usually rejected (see FEASIBILITY.md).
    @discardableResult
    func reorderSpace(_ uuid: String, toDisplayIdentifier displayID: String, index: Int) -> Bool {
        guard let space = rawSpaces.first(where: { $0.uuid == uuid }), space.managedSpaceID >= 0
        else { return false }
        let err = sm_moveManagedSpaceToDisplayIndex(UInt64(space.managedSpaceID),
                                                    displayID as CFString, UInt32(max(0, index)))
        guard err == 0 else {
            NSLog("[SpeedySpaces] reorder rejected: CGError \(err)")
            return false
        }
        pendingReorder = (uuid, displayID, index, Date().addingTimeInterval(3))
        spaces = overlaid(rawSpaces)
        onChange?()
        NotificationCenter.default.post(name: .speedySpacesSpacesChanged, object: nil)
        let perr = sm_persistenceSaveSpaceConfiguration()
        if perr != 0 { HotkeyDiag.log("reorder persist -> CGError \(perr) (session-only)") }
        return true
    }

    private func publish(_ outcome: SwitchOutcome) {
        lastOutcome = outcome
        if !outcome.ok, predicted != nil {
            predicted = nil
            refresh()   // revert the optimistic marker — the switch didn't land
        }
        NSLog("[SpeedySpaces] switch \(outcome.summary)")
        HotkeyDiag.log("switch \(outcome.summary)")   // externally observable for the test harness
        NotificationCenter.default.post(name: .speedySpacesSwitchOutcome, object: nil,
                                        userInfo: ["outcome": outcome])
    }

    /// Headless probe used by `--probe-switch`. Returns process exit code (0 pass, 1 fail).
    func probeSwitch(method: SwitchMethod, index: Int) -> Int32 {
        refresh()
        guard index >= 0 && index < spaces.count else { print("FAIL bad index \(index)"); return 1 }
        Prefs.switchMethod = method
        let target = spaces[index]
        var result: Int32 = 1
        let done = DispatchSemaphore(value: 0)
        let obs = NotificationCenter.default.addObserver(forName: .speedySpacesSwitchOutcome, object: nil, queue: .main) { note in
            if let o = note.userInfo?["outcome"] as? SwitchOutcome {
                print("\(o.ok ? "PASS" : "FAIL") \(o.summary)")
                result = o.ok ? 0 : 1
                done.signal()
            }
        }
        _ = switchTo(target)
        // Spin the runloop up to ~3s for the async verifier.
        let deadline = Date().addingTimeInterval(3.0)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        NotificationCenter.default.removeObserver(obs)
        return result
    }

}

/// Weak global handle so the Settings window can read the latest switch outcome at open time.
enum SpacesManagerHolder { static weak var shared: SpacesManager? }

extension SpacesManager {
    static func selfChecks(_ check: SelfTest.Check) {
        // Back-and-forth diff: a changed current rolls the old one into `last`.
        var last = updatedLastSpaces(previousCurrent: ["d1": "A"], newCurrent: ["d1": "B"], last: [:])
        check(last["d1"] == "A", "lastSpace: change rolls old current into last")
        // No change → last untouched.
        last = updatedLastSpaces(previousCurrent: ["d1": "B"], newCurrent: ["d1": "B"], last: last)
        check(last["d1"] == "A", "lastSpace: no-change keeps last")
        // Another change overwrites.
        last = updatedLastSpaces(previousCurrent: ["d1": "B"], newCurrent: ["d1": "C"], last: last)
        check(last["d1"] == "B", "lastSpace: second change advances last")
        // A display appearing for the first time (no baseline) records nothing.
        last = updatedLastSpaces(previousCurrent: [:], newCurrent: ["d2": "X"], last: last)
        check(last["d2"] == nil && last["d1"] == "B", "lastSpace: new display has no last yet")
        // Displays diff independently.
        last = updatedLastSpaces(previousCurrent: ["d1": "C", "d2": "X"],
                                 newCurrent: ["d1": "C", "d2": "Y"], last: last)
        check(last["d1"] == "B" && last["d2"] == "X", "lastSpace: per-display independence")

        // Reorder overlay — one display, three spaces A B C on "d".
        func mk(_ uuid: String, _ disp: String, _ idx: Int, _ ord: Int, cur: Bool = false) -> Space {
            Space(uuid: uuid, managedSpaceID: 0, type: 0, displayIndex: idx,
                  displayIdentifier: disp, ordinalOnDisplay: ord, isCurrent: cur)
        }
        let abc = [mk("A", "d", 0, 0), mk("B", "d", 0, 1), mk("C", "d", 0, 2)]
        let moved = reordered(abc, moving: "A", toDisplay: "d", index: 2)
        check(moved.map(\.uuid) == ["B", "C", "A"], "reorder: A→end gives B C A")
        check(moved.map(\.ordinalOnDisplay) == [0, 1, 2], "reorder: ordinals renumber after move")
        let noop = reordered(abc, moving: "A", toDisplay: "d", index: 0)
        check(sameOrder(noop, abc), "reorder: move to same index is a no-op")
        check(!sameOrder(moved, abc), "reorder: a real permutation is not sameOrder")
        // Cross-display: move C from d1 to end of d2.
        let two = [mk("A", "d1", 0, 0), mk("B", "d1", 0, 1), mk("C", "d1", 0, 2),
                   mk("X", "d2", 1, 0)]
        let cross = reordered(two, moving: "C", toDisplay: "d2", index: 1)
        check(cross.filter { $0.displayIdentifier == "d1" }.map(\.uuid) == ["A", "B"],
              "reorder: cross-display departs source")
        check(cross.filter { $0.displayIdentifier == "d2" }.map(\.uuid) == ["X", "C"],
              "reorder: cross-display arrives at destination")
        check(cross.first { $0.uuid == "C" }?.displayIndex == 1,
              "reorder: moved space adopts destination displayIndex")
        // Clamp: an out-of-range index appends rather than crashing.
        let clamped = reordered(abc, moving: "A", toDisplay: "d", index: 99)
        check(clamped.map(\.uuid) == ["B", "C", "A"], "reorder: over-range index clamps to end")

        // CGS payload parse — fixture mirrors sm_copyManagedDisplaySpaces' shape.
        let displaysFixture: [[String: Any]] = [
            ["Display Identifier": "UUID-A",
             "Current Space": ["uuid": "s2"],
             "Spaces": [
                ["uuid": "s1", "ManagedSpaceID": 101, "type": 0],
                ["uuid": "s2", "ManagedSpaceID": 102, "type": 0],
                ["ManagedSpaceID": 999],                      // malformed: no uuid
                ["uuid": "s3", "ManagedSpaceID": 103, "type": 4, "pid": 555],
             ]],
            ["Display Identifier": "UUID-B",
             "Current Space": ["uuid": "t1"],
             "Spaces": [["uuid": "t1", "ManagedSpaceID": 201, "type": 0]]],
        ]
        let parsed = parseSpaces(displays: displaysFixture)
        check(parsed.map(\.uuid) == ["s1", "s2", "s3", "t1"],
              "parseSpaces: order preserved, malformed entry skipped")
        check(parsed[1].isCurrent && !parsed[0].isCurrent && parsed[3].isCurrent,
              "parseSpaces: current flag resolved per display")
        check(parsed[2].isFullscreen && parsed[2].fullscreenPID == 555,
              "parseSpaces: fullscreen type + owning pid")
        check(parsed[0].fullscreenPID == nil, "parseSpaces: desktops carry no pid")
        check(parsed[3].displayIndex == 1 && parsed[3].displayIdentifier == "UUID-B"
                && parsed[3].ordinalOnDisplay == 0,
              "parseSpaces: display index/identifier/ordinal per display")
        check(parsed[0].managedSpaceID == 101, "parseSpaces: managed id carried")
        check(parseSpaces(displays: []).isEmpty, "parseSpaces: empty payload -> empty")
    }
}
