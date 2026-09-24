// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices

/// The "move window to workspace" mechanism: a server-side window drag + Ctrl+fn+Arrow.
///
/// macOS carries a window that is being *dragged* across every space switch, and that is the
/// only route to moving a foreign window between spaces on macOS 26+ — the raw CGS move calls
/// are connection-gated to the caller's own windows and silently no-op. What changed here is
/// how the window gets held. It used to be a synthetic click on the title bar, which meant
/// finding a point that was both draggable chrome and on screen; that failed on windows whose
/// title bar is packed with toolbar/tab controls, and outright on windows pushed off the edge
/// of the display, where there is no such point to click at all.
///
/// Now the window is named to the window server by ID (`sm_dragWindowRelativeToMouse`) and the
/// press it binds to lands on our own invisible panel (`WindowGrabOverlay`), parked under
/// wherever the cursor already happens to be. Nothing about the target has to be clickable, or
/// on screen. The cursor is not warped, hidden, or restored — it never moves.
///
/// Measured side by side on macOS 27.0 (26A5421a) against a window at x = -600 (title bar off
/// the left edge): the title-bar press produced no drag at all, so the space switch was refused
/// and the window stayed put; the server-side drag carried it. See
/// `~/build/window-shift/window-move-mechanism-analysis-v1.md` for the mechanism's provenance.
///
/// Relative bursts are serialised through `RelativeWindowMover`; the wrap-takeover interaction
/// is guarded by `WindowMover.windowDragInFlight`.
extension WindowMover {

    // MARK: - Shared helpers

    /// The top-most normal (layer-0) window under a global CG point (top-left origin, matching
    /// `kCGWindowBounds` and `CGEvent.location`), skipping `excludingPID` (our own app, so the
    /// switcher panels are never picked). Used to identify the window being dragged onto a tile.
    static func windowUnder(cgPoint p: CGPoint, excludingPID: pid_t) -> (wid: UInt32, pid: pid_t)? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in infos {   // front-to-back z-order
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != excludingPID,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(p) { return (wid, pid) }
        }
        return nil
    }

    /// The managed-space id currently visible on each display, read live from the window server
    /// (no `SpacesManager.refresh()` side effects). Used off-main to pace the walk — each step
    /// waits for its display's current space to reach the next target.
    static func currentSpaceIDs() -> Set<UInt64> {
        guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID()) as? [[String: Any]]
        else { return [] }
        var out = Set<UInt64>()
        for d in displays {
            guard let cur = d["Current Space"] as? [String: Any] else { continue }
            if let n = cur["ManagedSpaceID"] as? Int { out.insert(UInt64(n)) }
            else if let n = cur["ManagedSpaceID"] as? UInt64 { out.insert(n) }
        }
        return out
    }

    /// The window server's current bounds for one window (global CG, top-left origin).
    /// The drag offset is measured against this, so it has to be the server's view of the
    /// window and not Accessibility's.
    static func serverBounds(of wid: UInt32) -> CGRect? {
        var r = CGRect.zero
        if sm_getWindowBounds(wid, &r) { return r }
        guard let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let b = infos.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    // MARK: - Server-side drag + Ctrl+fn+Arrow

    /// How long the press waits for the grab overlay to reach the screen. It is normally there
    /// within a frame; firing before the window server has it would put a stray click into
    /// whatever app is under the cursor, so the move is abandoned instead.
    private static let overlayWait: TimeInterval = 0.4

    /// Grab a window with a server-side drag and carry it to `target`.
    /// Two modes, both single-grab (the OS carries the held window across each viewport switch):
    ///  - `jumpDesktop` set (a numbered "move to workspace N" shortcut) → drive the native
    ///    "Switch to Desktop N" chord ONCE — the window jumps straight there in one switch.
    ///  - `jumpDesktop` nil (relative next/prev) → tap ⌃+fn+Arrow once per space, paced to each
    ///    switch landing, so the window glides step by step.
    /// Per-window and fully synthetic. Wrap is already baked into `target`.
    static func moveViaServerDrag(wid: UInt32, target: Space, spaces: SpacesManager,
                                  jumpDesktop: Int? = nil,
                                  completion: (() -> Void)? = nil) throws {
        guard sm_dragWindowAvailable() else { throw MoveError.symbolsUnavailable }
        // The window server hands a foreign window over to our drag only for a process with
        // Screen Recording. Without it the call still returns success and the window simply
        // never follows — so the walk would switch the viewport and leave the window behind.
        // Preflighting is the only way to tell the difference without a visible test drag.
        guard CGPreflightScreenCaptureAccess() else { throw MoveError.screenRecordingRequired }
        spaces.refresh()
        let ids = spaceIDs(for: wid)
        guard let cur = spaces.spaces.first(where: {
            ids.contains(UInt64($0.managedSpaceID)) && !$0.isFullscreen }) else {
            throw MoveError.noFocusedWindow
        }
        let list = spaces.spaces.filter { $0.displayIndex == cur.displayIndex && !$0.isFullscreen }
            .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        guard let i = list.firstIndex(where: { $0.uuid == cur.uuid }),
              let j = list.firstIndex(where: { $0.uuid == target.uuid }) else {
            throw MoveError.sameSpace   // target not on the window's display
        }
        let steps = j - i
        guard steps != 0 else { throw MoveError.sameSpace }
        // The drag holds the grabbed point a fixed distance from the window's origin, so the
        // offset is read once, up front, against the server's own bounds.
        guard let frame = serverBounds(of: wid) else { throw MoveError.noFocusedWindow }
        let right = steps > 0, count = abs(steps)
        let dir = right ? 1 : -1
        let stepTargetIDs: [UInt64] = (1...count).map { UInt64(list[i + $0 * dir].managedSpaceID) }
        let finalID = UInt64(target.managedSpaceID)

        // Jump path: the native "Switch to Desktop N" chord (symbolic hotkey 118+N-1) whose viewport
        // switch carries the grabbed window straight to workspace N — used for the numbered move-to-
        // workspace shortcuts, so they land in one switch instead of walking arrows.
        struct Jump { let hkID: Int; let keyCode: CGKeyCode; let flags: CGEventFlags }
        let jump: Jump? = {
            guard let n = jumpDesktop, n >= 1, n <= SystemShortcuts.maxSwitchableDesktop else { return nil }
            let hkID = SystemShortcuts.desktopBaseID + n - 1
            if let sc = SystemShortcuts.systemBinding(id: hkID) {
                return Jump(hkID: hkID, keyCode: sc.keyCode, flags: sc.flags)
            } else if let d = SystemShortcuts.defaultChord(id: hkID) {
                return Jump(hkID: hkID, keyCode: CGKeyCode(d.keyCode),
                            flags: CGEventFlags(rawValue: UInt64(bitPattern: Int64(d.mods))))
            }
            return nil
        }()

        // Temporarily enable whichever symbolic hotkey we'll drive (jump → Switch-to-Desktop-N;
        // walk → Move-left/right-a-space 79/81), restoring prior enabled state after.
        let enableIDs: [Int] = jump.map { [$0.hkID] } ?? [SystemShortcuts.moveLeftID, SystemShortcuts.moveRightID]
        let wasEnabled = enableIDs.map { sm_symbolicHotKeyIsEnabled(Int32($0)) }
        for id in enableIDs where !sm_symbolicHotKeyIsEnabled(Int32(id)) {
            _ = sm_symbolicHotKeySetEnabled(Int32(id), true)
        }

        // The press goes wherever the pointer already is; the overlay catches it. Park the
        // overlay there now so the window server has it on screen by the time the press fires.
        let cursor = CGEvent(source: nil)?.location ?? CGPoint(x: frame.midX, y: frame.midY)
        let overlay = WindowGrabOverlay.shared
        overlay.show(atCG: cursor)

        HotkeyDiag.log("windowDrag: wid=\(wid) press @\(Int(cursor.x)),\(Int(cursor.y)) "
            + (jump != nil ? "jump -> desktop \(jumpDesktop!)" : "walk \(steps)")
            + " -> space \(target.managedSpaceID)")

        // Stand our own wrap-takeover tap down for the move — otherwise it swallows our synthetic
        // ⌃+fn+arrows (see WindowMover.windowDragInFlight). Set on main, before any post.
        windowDragInFlight = true
        // Single grab / single drop throughout. Off the main thread (CG posts are thread-safe;
        // no UI stall) — which is also why the overlay wait below may block.
        DispatchQueue.global(qos: .userInteractive).async {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.localEventsSuppressionInterval = 0
            func mouse(_ t: CGEventType, _ p: CGPoint) {
                let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
                // Clear any physically-held modifiers. The .hidSystemState source folds the LIVE
                // hardware modifier state into the event, and a held ⌃ (part of a ⌘⌥⌃⇧ move chord)
                // makes leftMouseDown a control-click — a right-click, which starts no drag. The
                // keyboard steps below set their own explicit flags, so only the mouse needs this.
                e?.flags = []
                e?.post(tap: .cgSessionEventTap)
            }
            func key(_ code: CGKeyCode, _ down: Bool, flags: CGEventFlags, flagsChanged: Bool = false) {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                if flagsChanged { e?.type = .flagsChanged }
                e?.flags = flags
                e?.post(tap: .cgSessionEventTap)
            }
            /// A representative modifier virtual-key for a flags set (for the flagsChanged frame).
            func modVK(_ f: CGEventFlags) -> CGKeyCode {
                if f.contains(.maskControl) { return 0x3B }
                if f.contains(.maskAlternate) { return 0x3A }
                if f.contains(.maskCommand) { return 0x37 }
                return 0x38   // shift
            }
            func waitFor(_ id: UInt64, tries: Int) -> Bool {
                for _ in 0..<tries { if currentSpaceIDs().contains(id) { return true }; usleep(30_000) }
                return false
            }
            func finish(_ settled: Bool, _ note: String?) {
                overlay.hide()
                for (idx, id) in enableIDs.enumerated() where !wasEnabled[idx] {
                    _ = sm_symbolicHotKeySetEnabled(Int32(id), false)   // restore native-shortcut state
                }
                DispatchQueue.main.async {
                    windowDragInFlight = false   // re-arm the wrap-takeover tap
                    spaces.refresh()
                    HotkeyDiag.log("windowDrag: released wid=\(wid) settled=\(settled)"
                        + (note.map { " (\($0))" } ?? ""))
                    completion?()
                }
            }

            // The press must land on the overlay, never in the user's app: if the window server
            // hasn't got the panel on screen yet, abandon rather than fire blind.
            guard overlay.waitUntilReady(timeout: overlayWait) else {
                finish(false, "grab overlay never reached the screen")
                return
            }
            // The user's hand must not steer the drag while the window is held: with the mouse
            // decoupled from the cursor, physical motion generates no movement for the server-side
            // drag to follow, so the window stays exactly where it is while it is carried across.
            CGAssociateMouseAndMouseCursorPosition(0)
            mouse(.mouseMoved, cursor); usleep(30_000)
            mouse(.leftMouseDown, cursor); usleep(110_000)              // ONE press, on the overlay
            let err = sm_dragWindowRelativeToMouse(
                wid, CGPoint(x: cursor.x - frame.minX, y: cursor.y - frame.minY))
            if err != 0 {
                mouse(.leftMouseUp, cursor)
                CGAssociateMouseAndMouseCursorPosition(1)
                finish(false, "window server refused the drag (error \(err))")
                return
            }

            if let jump = jump {
                let mv = modVK(jump.flags)
                key(mv, true, flags: jump.flags, flagsChanged: true); usleep(30_000)   // modifier DOWN
                key(jump.keyCode, true, flags: jump.flags); usleep(40_000)             // number key
                key(jump.keyCode, false, flags: jump.flags); usleep(10_000)
                key(mv, false, flags: [], flagsChanged: true)                          // modifier UP
                _ = waitFor(finalID, tries: 40)                                        // one big switch
                usleep(120_000)
            } else {
                // Drive the user's ACTUAL "Move left/right a space" shortcut (79/81) once per space.
                // It's remappable in System Settings, so a hardcoded ⌃+arrow can match nothing and the
                // window silently fails to walk.
                let moveID = right ? SystemShortcuts.moveRightID : SystemShortcuts.moveLeftID
                let sc = SystemShortcuts.systemBinding(id: moveID)
                let arrow: CGKeyCode = sc?.keyCode ?? (right ? 0x7C : 0x7B)
                // Arrow keys carry the fn/secondary-function bit; parseShortcut strips it, so add it back.
                let arrowFlags = (sc?.flags ?? .maskControl).union(.maskSecondaryFn)
                let modVKey = modVK(arrowFlags)
                key(modVKey, true, flags: arrowFlags, flagsChanged: true); usleep(40_000)   // modifiers DOWN, held
                for want in stepTargetIDs {
                    key(arrow, true, flags: arrowFlags); usleep(40_000)   // real move-a-space chord → one switch
                    key(arrow, false, flags: arrowFlags)
                    if !waitFor(want, tries: 30) { break }              // wait for THIS switch, else stop
                    usleep(45_000)                                      // brief beat, then the next tap
                }
                usleep(120_000)                                         // hold the grab while the last lands
                key(modVKey, false, flags: [], flagsChanged: true); usleep(30_000)   // modifiers UP
            }
            mouse(.leftMouseUp, cursor)                                // ONE drop, onto the target space
            var settled = false
            for _ in 0..<12 {                                          // confirm the window reached target
                if spaceIDs(for: wid).contains(finalID) { settled = true; break }
                usleep(50_000)
            }
            CGAssociateMouseAndMouseCursorPosition(1)                  // re-couple mouse ↔ cursor
            finish(settled, nil)
        }
    }
}
