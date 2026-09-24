// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Everything an engine needs to switch, computed once by the dispatcher.
struct SwitchContext {
    let current: Space?          // current space on the *target's* display, if known
    let isTrusted: Bool          // AXIsProcessTrusted()
    let animation: GestureAnimation
}

/// Whether an engine can attempt a given switch on this machine/target.
enum SwitchAvailability: Equatable {
    case available
    case unavailable(String)     // user-facing reason
}

/// Result of one switch attempt, for logging and the Settings scoreboard.
struct SwitchOutcome {
    let method: SwitchMethod
    let fromOrdinal: Int?        // 0-based ordinalOnDisplay of the origin, if known
    let toOrdinal: Int           // 0-based ordinalOnDisplay of the target
    let displayIndex: Int
    let ok: Bool
    let milliseconds: Int
    let reason: String?          // failure/refusal reason, else nil

    /// One-line summary, e.g. "gesture · display 1 · #3 → #6 · OK · 142 ms".
    var summary: String {
        let from = fromOrdinal.map { "#\($0 + 1)" } ?? "#?"
        let status = ok ? "OK" : "FAIL"
        let tail = reason.map { " · \($0)" } ?? ""
        return "\(method.rawValue) · display \(displayIndex + 1) · \(from) → #\(toOrdinal + 1) · \(status) · \(milliseconds) ms\(tail)"
    }
}

extension SwitchOutcome {
    static func selfChecks(_ check: (Bool, String) -> Void) {
        func outcome(from: Int?, ok: Bool, ms: Int, reason: String?) -> SwitchOutcome {
            SwitchOutcome(method: .gesture, fromOrdinal: from, toOrdinal: 5,
                          displayIndex: 0, ok: ok, milliseconds: ms, reason: reason)
        }
        check(outcome(from: 2, ok: true, ms: 142, reason: nil).summary
              == "gesture · display 1 · #3 → #6 · OK · 142 ms",
              "outcome summary: ok case, 1-based ordinals")
        check(outcome(from: 2, ok: false, ms: 90, reason: "timeout").summary
              == "gesture · display 1 · #3 → #6 · FAIL · 90 ms · timeout",
              "outcome summary: failure appends reason")
        check(outcome(from: nil, ok: true, ms: 0, reason: nil).summary.contains("#? → #6"),
              "outcome summary: unknown origin renders #?")
        check(!outcome(from: 0, ok: true, ms: 1, reason: nil).summary.contains("#0"),
              "outcome summary: ordinal 0 shown as #1, never #0")
    }
}

/// One switching technique. Implementations are pure w.r.t. the app; the dispatcher
/// owns availability routing, verification, and outcome publishing.
protocol SpaceSwitcher {
    var method: SwitchMethod { get }
    /// Synchronous pre-flight: can this engine attempt `target` right now?
    func availability(for target: Space, _ ctx: SwitchContext) -> SwitchAvailability
    /// Fire the switch. Verification is performed externally by SwitchVerifier.
    func perform(_ target: Space, _ ctx: SwitchContext) throws
}

/// With "Displays have separate Spaces", dock swipes and ⌃-arrow shortcuts are applied to
/// the display UNDER THE POINTER — so a cross-display switch must park the pointer on the
/// target display until the posted events have been consumed. The restore must NOT run
/// synchronously after posting: CGEvents are delivered to the Dock asynchronously, and an
/// immediate restore re-routes the whole switch to the pointer's original display.
enum DisplayRouting {
    /// CGDirectDisplayID for the display a space lives on, resolved via the space's
    /// display UUID (never via NSScreen array order, which need not match CGS order).
    static func displayID(for space: Space) -> CGDirectDisplayID? {
        if space.displayIdentifier == "Main" { return CGMainDisplayID() }
        guard let uuid = CFUUIDCreateFromString(nil, space.displayIdentifier as CFString) else { return nil }
        let did = CGDisplayGetDisplayIDFromUUID(uuid)
        return did == 0 ? nil : did
    }

    /// Move the pointer to the center of `space`'s display if it isn't already there.
    /// Returns an action that puts it back — run it only after the switch events have
    /// landed (e.g. a few hundred ms later), or nil if no warp was needed. All points
    /// are CG global coordinates (top-left origin) — never mix in NSEvent.mouseLocation,
    /// which is flipped.
    static func parkPointer(on space: Space) -> (() -> Void)? {
        guard NSScreen.screens.count > 1,
              let did = displayID(for: space),
              let loc = CGEvent(source: nil)?.location else { return nil }
        let bounds = CGDisplayBounds(did)
        guard !bounds.contains(loc) else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CGWarpMouseCursorPosition(center)
        // A real mouse-moved event makes the window server's routing notice the new
        // position immediately (a bare warp generates no events).
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        return { CGWarpMouseCursorPosition(loc) }
    }
}
