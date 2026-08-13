import AppKit
import ApplicationServices

/// The "move window to workspace" mechanism: a synthetic native title-bar drag + Ctrl+fn+Arrow
/// (the Hammerspoon technique). It works for FOREIGN windows on macOS 26+, where the raw CGS move
/// calls are gated to the app's own windows. Relative bursts are serialised through
/// `TitleBarDragRelativeMover`; the wrap-takeover interaction is guarded by
/// `WindowMover.titleBarDragInFlight`.
extension WindowMover {

    // MARK: - Shared helpers

    /// Owning process of a window id.
    static func ownerPID(of wid: UInt32) -> pid_t? {
        guard let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let pid = infos.first?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return pid
    }

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

    // MARK: - AX helpers

    /// (wid, element) for each of `pid`'s AX windows, via the private _AXUIElementGetWindow bridge.
    static func axWindowElements(pid: pid_t) -> [(wid: UInt32, el: AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        var out: [(UInt32, AXUIElement)] = []
        for el in windows {
            var w: UInt32 = 0
            if sm_windowIDForAXElement(el, &w), w != 0 { out.append((w, el)) }
        }
        return out
    }

    static func axElement(forWid wid: UInt32) -> AXUIElement? {
        guard let pid = ownerPID(of: wid) else { return nil }
        return axWindowElements(pid: pid).first { $0.wid == wid }?.el
    }

    /// The managed-space id currently visible on each display, read live from the window server
    /// (no `SpacesManager.refresh()` side effects). Used off-main to pace the title-bar walk —
    /// each step waits for its display's current space to reach the next target.
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

    /// A window's AX frame (top-left-origin global coords, like AXPosition).
    static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pRef: CFTypeRef?, sRef: CFTypeRef?
        var p = CGPoint.zero, s = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef) == .success,
              AXValueGetValue(pRef as! AXValue, .cgPoint, &p),
              AXValueGetValue(sRef as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: - Native title-bar drag + Ctrl+fn+Arrow (Hammerspoon technique)

    /// The grab point for the title-bar drag: dead center of the gap between the close (red)
    /// and minimize (yellow) traffic-light buttons — the top-left of the title bar. That gap is
    /// draggable window chrome on every standard window, whereas the area to the RIGHT of the
    /// buttons is frequently a unified toolbar / tab bar (Terminal, browsers, Finder) that eats
    /// the grab — the "won't pick the window up" failures. A synthetic mouse-down landing on a
    /// button wouldn't move the window either (the button swallows it), so aim for the gap, not
    /// the buttons. Falls back to just right of the green zoom button, then the frame top-center.
    static func titleBarPoint(forWid wid: UInt32) -> CGPoint? {
        guard let el = axElement(forWid: wid) else { return nil }
        if let close = buttonRect(el, kAXCloseButtonAttribute),
           let minimize = buttonRect(el, kAXMinimizeButtonAttribute) {
            return CGPoint(x: (close.midX + minimize.midX) / 2,
                           y: (close.midY + minimize.midY) / 2)
        }
        if let zoom = buttonRect(el, kAXZoomButtonAttribute) {
            return CGPoint(x: zoom.maxX + 5, y: zoom.midY)
        }
        if let f = axFrame(el) { return CGPoint(x: f.midX, y: f.minY + 11) }
        return nil
    }

    /// The AX frame of a window's title-bar button (close / minimize / zoom), if it has one.
    private static func buttonRect(_ window: AXUIElement, _ attribute: String) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &ref) == .success,
              let b = ref, CFGetTypeID(b) == AXUIElementGetTypeID() else { return nil }
        return axFrame(b as! AXUIElement)
    }

    /// Grab the focused window's title bar with a synthetic mouse-down and carry it to `target`.
    /// Two modes, both single-grab (the OS carries the held window across each viewport switch):
    ///  - `jumpDesktop` set (a numbered "move to workspace N" shortcut) → drive the native
    ///    "Switch to Desktop N" chord ONCE — the window jumps straight there in one switch.
    ///  - `jumpDesktop` nil (relative next/prev) → tap ⌃+fn+Arrow once per space, paced to each
    ///    switch landing, so the window glides step by step.
    /// Per-window, fully synthetic (Hammerspoon technique). Wrap is already baked into `target`.
    static func moveViaTitleBarDrag(wid: UInt32, target: Space, spaces: SpacesManager,
                                    jumpDesktop: Int? = nil,
                                    completion: (() -> Void)? = nil) throws {
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
        guard let titlePt = titleBarPoint(forWid: wid) else { throw MoveError.noFocusedWindow }
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
        HotkeyDiag.log("titleBarDrag: wid=\(wid) grab @\(Int(titlePt.x)),\(Int(titlePt.y)) "
            + (jump != nil ? "jump -> desktop \(jumpDesktop!)" : "walk \(steps)") + " -> space \(target.managedSpaceID)")

        // Stand our own wrap-takeover tap down for the move — otherwise it swallows our synthetic
        // ⌃+fn+arrows (see WindowMover.titleBarDragInFlight). Set on main, before any post.
        titleBarDragInFlight = true
        // Single grab / single drop throughout: re-grabbing per step read as a title-bar double-click
        // and maximised the window. Off the main thread (CG posts are thread-safe; no UI stall).
        DispatchQueue.global(qos: .userInteractive).async {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.localEventsSuppressionInterval = 0
            let origMouse = CGEvent(source: nil)?.location ?? .zero
            // Grab the title bar INVISIBLY (window-shift's disguise). Posting real mouse events at
            // the title bar unavoidably moves the on-screen cursor there, so for the brief move we
            // HIDE the cursor (sm_setsCursorInBackground lets a background/accessory app's hide take
            // effect) and disassociate it from the mouse so trackpad motion can't fight the grab.
            // Position, visibility, and coupling are all restored at the end — to the user the
            // pointer never leaves where they left it while the window is grabbed and carried unseen.
            CGAssociateMouseAndMouseCursorPosition(0)
            sm_setsCursorInBackground()
            CGDisplayHideCursor(CGMainDisplayID())
            func mouse(_ t: CGEventType, _ p: CGPoint) {
                CGWarpMouseCursorPosition(p)
                let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
                // Clear any physically-held modifiers. The .hidSystemState source folds the LIVE
                // hardware modifier state into the event, and a held ⌃ (part of a ⌘⌥⌃⇧ move chord)
                // makes leftMouseDown a control-click — a right-click, which never grabs the window.
                // That's the physical-⌘⌥⌃⇧-vs-Caps-hyper asymmetry: the hyper tap adds modifiers to
                // KEY events only, so its grab stays clean. The keyboard steps below set their own
                // explicit flags, so only the mouse events need clearing.
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
            mouse(.mouseMoved, titlePt); usleep(30_000)
            mouse(.leftMouseDown, titlePt); usleep(110_000)              // ONE grab of the title bar
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
                // It's remappable in System Settings (this user runs a ⌘⌥⌃+arrow Global Modifier), so a
                // hardcoded ⌃+arrow matches nothing and the window silently fails to walk — Caps-hyper
                // only masked this by re-adding ⌘⌥⌃ to our synthetic keys; a physical press has no helper.
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
            mouse(.leftMouseUp, titlePt)                               // ONE drop, onto the target space
            var settled = false
            for _ in 0..<12 {                                          // confirm the window reached target
                if spaceIDs(for: wid).contains(finalID) { settled = true; break }
                usleep(50_000)
            }
            CGWarpMouseCursorPosition(origMouse)                       // put the cursor back where it was
            CGDisplayShowCursor(CGMainDisplayID())                     // reveal it there — never at the title bar
            CGAssociateMouseAndMouseCursorPosition(1)                  // re-couple mouse ↔ cursor
            for (idx, id) in enableIDs.enumerated() where !wasEnabled[idx] {
                _ = sm_symbolicHotKeySetEnabled(Int32(id), false)      // restore native-shortcut state
            }
            DispatchQueue.main.async {
                titleBarDragInFlight = false   // re-arm the wrap-takeover tap
                spaces.refresh()
                HotkeyDiag.log("titleBarDrag: released wid=\(wid) settled=\(settled)")
                completion?()
            }
        }
    }
}
