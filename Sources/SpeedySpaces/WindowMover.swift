// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Moves a window to another space with a server-side window drag (`moveViaServerDrag`) —
/// macOS has no stock keyboard path for this, and the private window-server move calls
/// silently no-op on this OS. The drag holds the window while the native "Switch to Desktop N"
/// chord fires, so the move always follows to the new space.
/// All failures throw a reason — callers log + beep rather than corrupting state.
enum WindowMover {
    /// True while a `moveViaServerDrag` walk is posting its synthetic ⌃+fn+arrows. The app's own
    /// SwitcherHUD active tap head-inserts on the session tap, so it *sees* those events, and
    /// with wrap enabled it strips the fn bit and matches ⌃-arrow — swallowing the very event
    /// the walk posts and running a viewport-only `switchTo` that leaves the grabbed window
    /// behind (the mid-walk stall). The tap checks this flag and stands down so the native
    /// "Move a space" shortcut carries the window. Written from main/background and read from
    /// the event-tap thread — lock-guarded so no reader observes a torn value.
    private static let dragFlag = Locked(false)
    static var windowDragInFlight: Bool {
        get { dragFlag.get() }
        set { dragFlag.set(newValue) }
    }

    /// Set by a peer app (MoreCorners) via distributed notification while IT
    /// performs a title-bar-drag window move. Our tap stands down for it exactly
    /// as for our own moves, so the native "Move a space" shortcut reaches the
    /// window server and carries the peer's grabbed window instead of us
    /// swallowing it. Lock-guarded (written on main, read on the tap thread).
    private static let externalFlag = Locked(false)
    static var externalMoveInFlight: Bool {
        get { externalFlag.get() }
        set { externalFlag.set(newValue) }
    }

    /// The tap stands down for either our own move or a peer's.
    static var standDownForMove: Bool { windowDragInFlight || externalMoveInFlight }

    private static var peerObservers: [NSObjectProtocol] = []
    private static var peerClearWork: DispatchWorkItem?

    /// Observe MoreCorners' "window move in flight" distributed notifications so
    /// our tap stands down for the duration (see `standDownForMove`). Idempotent;
    /// a 3 s safety timer auto-clears if the peer dies before sending "ended".
    /// Call once at startup. Independent of MoreCorners — a no-op if it's absent.
    static func startPeerMoveCoordination() {
        guard peerObservers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let began = center.addObserver(
            forName: Notification.Name("dev.nwf.MoreCorners.windowMoveBegan"),
            object: nil, queue: .main) { _ in
            externalMoveInFlight = true
            peerClearWork?.cancel()
            let work = DispatchWorkItem { externalMoveInFlight = false }
            peerClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
        let ended = center.addObserver(
            forName: Notification.Name("dev.nwf.MoreCorners.windowMoveEnded"),
            object: nil, queue: .main) { _ in
            peerClearWork?.cancel(); peerClearWork = nil
            externalMoveInFlight = false
        }
        peerObservers = [began, ended]
    }

    enum MoveError: Error, CustomStringConvertible {
        case symbolsUnavailable
        case notTrusted
        case screenRecordingRequired
        case noFocusedWindow
        case fullscreenTarget
        case sameSpace
        case moveSilentlyFailed

        var description: String {
            switch self {
            case .symbolsUnavailable: return "window-move symbols unavailable on this macOS"
            case .notTrusted:         return "Accessibility not granted"
            case .screenRecordingRequired:
                return "Screen Recording not granted — the window server won't hand a window "
                     + "over to be carried between workspaces without it"
            case .noFocusedWindow:    return "no focused window"
            case .fullscreenTarget:   return "can't move a window into a full-screen space"
            case .sameSpace:          return "window is already on the target space"
            case .moveSilentlyFailed: return "window server ignored the move (both private calls)"
            }
        }
    }

    /// Move the focused window to the adjacent display by AX frame reposition — both
    /// displays' current spaces are visible, so no space-membership change is needed
    /// (those private calls no-op on macOS 26+). Preserves the window's offset from
    /// the display's top-left, clamped into the target's visible frame. AX coords are
    /// top-left-origin global; NSScreen frames are bottom-left — convert via primary.
    static func moveFocusedWindowToDisplay(forward: Bool) throws {
        guard AXIsProcessTrusted() else { throw MoveError.notTrusted }
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard screens.count > 1, let primary = NSScreen.screens.first else { throw MoveError.noFocusedWindow }
        let app = NSWorkspace.shared.frontmostApplication
        guard let pid = app?.processIdentifier else { throw MoveError.noFocusedWindow }
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() else { throw MoveError.noFocusedWindow }
        let window = win as! AXUIElement
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { throw MoveError.noFocusedWindow }
        func topLeft(_ f: NSRect) -> CGPoint { CGPoint(x: f.minX, y: primary.frame.maxY - f.maxY) }
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        let i = screens.firstIndex {
            let tl = topLeft($0.frame)
            return CGRect(x: tl.x, y: tl.y, width: $0.frame.width, height: $0.frame.height).contains(center)
        } ?? 0
        let target = screens[((i + (forward ? 1 : -1)) % screens.count + screens.count) % screens.count]
        let curTL = topLeft(screens[i].visibleFrame), tgtTL = topLeft(target.visibleFrame)
        var newPos = CGPoint(x: tgtTL.x + (pos.x - curTL.x), y: tgtTL.y + (pos.y - curTL.y))
        newPos.x = min(max(newPos.x, tgtTL.x), tgtTL.x + target.visibleFrame.width - min(size.width, target.visibleFrame.width))
        newPos.y = min(max(newPos.y, tgtTL.y), tgtTL.y + target.visibleFrame.height - min(size.height, target.visibleFrame.height))
        var p = newPos
        let value = AXValueCreate(.cgPoint, &p)!
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        else { throw MoveError.moveSilentlyFailed }
    }

    /// Space ids currently containing `wid` (per the window server).
    static func spaceIDs(for wid: UInt32) -> [UInt64] {
        guard let arr = sm_copySpaceIDsForWindow(wid) as? [NSNumber] else { return [] }
        return arr.map(\.uint64Value)
    }

    /// The frontmost app's focused window, resolved to a window-server ID via AX plus
    /// the private _AXUIElementGetWindow bridge.
    static func focusedWindow() throws -> (wid: UInt32, pid: pid_t) {
        guard AXIsProcessTrusted() else { throw MoveError.notTrusted }
        guard sm_axWindowIDSymbolAvailable() else { throw MoveError.symbolsUnavailable }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw MoveError.noFocusedWindow
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw MoveError.noFocusedWindow
        }
        var wid: UInt32 = 0
        guard sm_windowIDForAXElement((focused as! AXUIElement), &wid), wid != 0 else {
            throw MoveError.noFocusedWindow
        }
        return (wid, app.processIdentifier)
    }

    /// Move the focused window to `target`, then switch there (all window moves follow).
    static func moveFocusedWindow(to target: Space, spaces: SpacesManager) throws {
        try move(wid: try focusedWindow().wid, to: target, spaces: spaces)
    }

    /// Move a window to a SPECIFIC numbered `target` via the server-side drag (see
    /// `moveViaServerDrag`). This is the absolute "move to workspace N" path, so it jumps straight
    /// there by driving the native "Switch to Desktop N" chord once (N = the target's position on
    /// its display), rather than walking ⌃+arrow. Works for FOREIGN windows on macOS 26+.
    static func move(wid: UInt32, to target: Space, spaces: SpacesManager) throws {
        guard !target.isFullscreen else { throw MoveError.fullscreenTarget }
        // A CURRENT target space is fine (display moves target the other display's current
        // space); the membership check catches the real no-op (already on the target).
        let targetID = UInt64(target.managedSpaceID)
        guard !spaceIDs(for: wid).contains(targetID) else { throw MoveError.sameSpace }
        try moveViaServerDrag(wid: wid, target: target, spaces: spaces,
                              jumpDesktop: target.ordinalOnDisplay + 1)
    }

    // MARK: - Self-tests

    static func selfChecks(_ check: SelfTest.Check) {
        let all: [MoveError] = [.symbolsUnavailable, .notTrusted, .screenRecordingRequired,
                                .noFocusedWindow, .fullscreenTarget, .sameSpace, .moveSilentlyFailed]
        check(all.allSatisfy { !$0.description.isEmpty }, "MoveError: every case has a description")
        check(Set(all.map(\.description)).count == all.count, "MoveError: descriptions distinct")
    }
}
