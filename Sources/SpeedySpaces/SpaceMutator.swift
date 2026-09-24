// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Adds and removes desktops by driving Mission Control's own controls with synthetic
/// mouse events. Both civilized routes are dead on this macOS: CGS-created spaces stay
/// unmanaged — the Dock ignores them (`--probe-space-mutation`) — and the Dock's `mc.*`
/// AX subtree no longer exposes children (`--probe-mc-tree`), which also broke the
/// mission-control switch engine. Synthetic MOUSE events still deliver
/// (`--probe-mouse`), so the one SIP-safe path left is the honest one: open Mission
/// Control, click the real "+" (or hover the target thumbnail and click its "✕"), and
/// close it again. Mission Control is visibly on screen for ~1 s per operation, and its
/// own add/remove animation plays — that visible flash is the cost of the Dock owning
/// desktop management.
enum SpaceMutator {
    private(set) static var busy = false

    /// Click Mission Control's "+" (right edge of the bar) on the given display.
    static func addDesktop(on screen: NSScreen, completion: ((Bool) -> Void)? = nil) {
        guard !busy, let did = screen.displayID else { completion?(false); return }
        busy = true
        let bounds = CGDisplayBounds(did)
        let restore = CGEvent(source: nil)?.location ?? .zero
        let countBefore = managedSpaceCount()
        // MC's add control is the half-hidden tile hugging the right screen edge at bar
        // height; hovering slides it out, but a click on the peek strip presses it too.
        let plusPoint = CGPoint(x: bounds.maxX - 8,
                                y: bounds.minY + SwitcherLayout.defaultTopInset
                                    + SwitcherLayout.fixedTileSize(screenSize: bounds.size).height / 2)
        HotkeyDiag.log("mutator add on display \(did)")
        NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen, object: nil)
        setMissionControl(open: true) { opened in
            guard opened else {
                finish(expectedChange: 1, countBefore: countBefore, restore: restore,
                       completion: completion)
                return
            }
            run([
                (0.35, { move(to: plusPoint) }),
                (0.30, {
                    // Re-arm HUD suppression (WillOpen auto-clears after 1.5 s).
                    NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen,
                                                    object: nil)
                    click(at: plusPoint)
                }),
                (0.55, { finish(expectedChange: 1, countBefore: countBefore, restore: restore,
                                completion: completion) }),
            ])
        }
    }

    /// Hover the target thumbnail in Mission Control's expanded bar and click its "✕".
    /// `ordinal`/`count` locate the tile with the same measured layout the HUD draws.
    static func removeDesktop(ordinal: Int, of count: Int, on screen: NSScreen,
                              completion: ((Bool) -> Void)? = nil) {
        guard !busy, let did = screen.displayID, ordinal < count else {
            completion?(false); return
        }
        busy = true
        let bounds = CGDisplayBounds(did)
        let restore = CGEvent(source: nil)?.location ?? .zero
        let countBefore = managedSpaceCount()
        let layout = SwitcherLayout.tiles(count: count, screenSize: bounds.size)
        guard layout.tileFrames.indices.contains(ordinal) else {
            busy = false; completion?(false); return
        }
        let tile = layout.tileFrames[ordinal]
        // Layout frames are bottom-left view coords; CGDisplayBounds is top-left global.
        func cgPoint(x: CGFloat, yFromBottom: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + x, y: bounds.minY + bounds.height - yFromBottom)
        }
        // MC opens with the bar COLLAPSED to a short strip of name pills at the very top;
        // thumbnails (and their ✕) only exist after hovering that strip. The thumbnail
        // coordinates below are only valid post-expansion.
        let expandPoint = cgPoint(x: bounds.width / 2, yFromBottom: bounds.height - 28)
        let tilePoint = cgPoint(x: tile.midX, yFromBottom: tile.midY)
        let crossPoint = cgPoint(x: tile.minX, yFromBottom: tile.maxY)
        HotkeyDiag.log("mutator remove ordinal \(ordinal)/\(count) display \(did)")
        NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen, object: nil)
        setMissionControl(open: true) { opened in
            guard opened else {
                finish(expectedChange: -1, countBefore: countBefore, restore: restore,
                       completion: completion)
                return
            }
            run([
                (0.30, { move(to: expandPoint) }),  // expand the pills into thumbnails
                (0.55, {
                    NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen,
                                                    object: nil)
                    move(to: tilePoint)             // hover the target: its ✕ fades in
                }),
                (0.50, { click(at: crossPoint) }),
                (0.65, { finish(expectedChange: -1, countBefore: countBefore, restore: restore,
                                completion: completion) }),
            ])
        }
    }

    // MARK: - Mission Control state

    /// `com.apple.expose.awake` is a TOGGLE — a run that starts with MC unexpectedly
    /// open (or a click that dismisses it mid-sequence) would otherwise invert every
    /// later toggle. Detect the real state the overlay's way: a Dock-owned on-screen
    /// window at the spaces-bar layer (14), by layer + geometry — no name access, so no
    /// Screen Recording needed.
    static func missionControlOpen() -> Bool {
        guard let dockPID = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == dockPID,
                  (info[kCGWindowLayer as String] as? Int) == 14,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return (b["Width"] ?? 0) > 600
        }
    }

    /// Toggle MC and wait for the wanted state (≤1.2 s). Returns success.
    private static func setMissionControl(open: Bool, then: @escaping (Bool) -> Void) {
        if missionControlOpen() == open {
            HotkeyDiag.log("mutator MC already \(open ? "open" : "closed")")
            then(true)
            return
        }
        let sent = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        HotkeyDiag.log("mutator toggle MC -> \(open ? "open" : "closed") sent=\(sent)")
        var waited: TimeInterval = 0
        func poll() {
            if missionControlOpen() == open {
                HotkeyDiag.log("mutator MC state reached after \(waited)s")
                then(true)
                return
            }
            waited += 0.1
            if waited >= 1.2 {
                HotkeyDiag.log("mutator MC state NOT reached (want open=\(open))")
                then(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
    }

    // MARK: - Plumbing

    private static func finish(expectedChange: Int, countBefore: Int, restore: CGPoint,
                               completion: ((Bool) -> Void)?) {
        // Whatever happened, leave Mission Control closed and the pointer restored.
        setMissionControl(open: false) { _ in
            CGWarpMouseCursorPosition(restore)
            busy = false
            let ok = managedSpaceCount() == countBefore + expectedChange
            HotkeyDiag.log("mutator done ok=\(ok)")
            SpacesManagerHolder.shared?.refresh()
            completion?(ok)
        }
    }

    private static func managedSpaceCount() -> Int {
        guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID())
                as? [[String: Any]] else { return 0 }
        return displays.reduce(0) { $0 + (($1["Spaces"] as? [[String: Any]])?.count ?? 0) }
    }

    private static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func click(at point: CGPoint) {
        move(to: point)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { up?.post(tap: .cghidEventTap) }
    }

    /// Sequential delayed steps on the main queue.
    private static func run(_ steps: [(TimeInterval, () -> Void)]) {
        guard let first = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + first.0) {
            first.1()
            run(Array(steps.dropFirst()))
        }
    }
}
