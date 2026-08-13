import AppKit

/// Presence tests for the native spaces bar / tile windows, by layer + geometry (the
/// same bands MissionControlOverlay discovers with — window NAMES would need Screen
/// Recording, which ad-hoc rebuilds keep losing).
enum NativeBarWindows {
    static func barOnScreen() -> Bool {
        anyWindow(layer: 14) { $0.width > 600 && $0.height > 80 && $0.height < 280 }
    }

    static func tilesOnScreen() -> Bool {
        anyWindow(layer: 15) { $0.width > 100 && $0.width < 320 && $0.height > 90 && $0.height < 200 }
    }

    /// True while macOS's "Show Desktop" is engaged (clicked wallpaper / F11 / hot corner):
    /// WindowManager puts up a full-screen overlay at layer 18 (its window name is
    /// "ShowDesktopOverlay", but we match owner+layer+size so this needs no Screen Recording).
    /// It's present even on an EMPTY desktop — unlike window geometry — and that mode silently
    /// swallows every space switch until it's dismissed (`com.apple.showdesktop.awake`).
    static func showDesktopActive() -> Bool {
        anyWindow(layer: 18) { $0.width > 600 && $0.height > 400 }
    }

    private static func anyWindow(layer: Int, band: (CGSize) -> Bool) -> Bool {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return infos.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == layer,
                  let d = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return false }
            if let owner = w[kCGWindowOwnerName as String] as? String,
               !owner.isEmpty, !owner.localizedCaseInsensitiveContains("WindowManager") { return false }
            return band(r.size)
        }
    }

    static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }

    /// The screen the pointer (CG top-left coords) is on.
    static func pointerScreen(_ pointer: CGPoint) -> NSScreen? {
        let ns = NSPoint(x: pointer.x, y: primaryHeight() - pointer.y)
        return NSScreen.screens.first { $0.frame.contains(ns) } ?? NSScreen.main
    }

    static func warpPointer(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

/// Opens the real Mission Control and auto-expands its spaces bar into wallpaper
/// thumbnails. The bar only expands on pointer hover with actual movement, so the
/// pointer is briefly parked at the top edge of its display and oscillated (a static
/// warped cursor posts zero-delta moves that don't register as hover), then restored to
/// where the user left it.
///
/// Two entry points share that expansion:
/// * `begin()`/`end()` — the "missionControl" style of the hold-to-show switcher; the
///   chord release closes Mission Control again unless something else (a tile click)
///   already dismissed it.
/// * `toggleExpanded()` — the one-shot "Open Mission Control Workspace View" shortcut;
///   Mission Control stays up afterwards, and firing again closes it.
enum NativeMissionControlHold {
    private static var oscillator: Timer?
    private static var savedPointer: CGPoint?
    private static var oscillateFlip = false
    private static var startedAt: CFTimeInterval = 0
    private(set) static var active = false

    /// How long to keep nudging the pointer at the top edge before giving up and
    /// restoring it (the bar usually expands within ~0.3 s of hover).
    private static let expandDeadline: CFTimeInterval = 1.0

    static func begin() {
        guard !active else { return }
        active = true
        openExpanded()
        HotkeyDiag.log("nativeMC hold begin (bar=\(NativeBarWindows.barOnScreen()))")
    }

    /// One-shot: open Mission Control with the spaces bar expanded, or — if it's already
    /// up — close it again, matching the toggle feel of the system's own Mission Control
    /// shortcut. Unlike `begin()` this leaves nothing held; the user drives Mission
    /// Control from there.
    static func toggleExpanded() {
        if NativeBarWindows.barOnScreen() {
            NotificationCenter.default.post(name: .speedySpacesMissionControlWillClose, object: nil)
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
            HotkeyDiag.log("nativeMC workspace view toggle -> close")
            return
        }
        openExpanded()
        HotkeyDiag.log("nativeMC workspace view toggle -> open")
    }

    /// Open Mission Control (if it isn't already) and hover the spaces bar open, handing
    /// the pointer back once the thumbnails exist.
    private static func openExpanded() {
        // Same announcement the Mission Control switch engine makes: the overlay engine
        // bursts its probe cadence and the HUD suppresses itself.
        NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen, object: nil)
        let pointer = CGEvent(source: nil)?.location ?? .zero
        savedPointer = pointer
        startedAt = CACurrentMediaTime()
        // Expand the bar on the display the pointer is on (hover is per-display).
        let screen = NativeBarWindows.pointerScreen(pointer)
        let topCG = CGPoint(x: screen.map { $0.frame.midX } ?? 640,
                            y: screen.map { NativeBarWindows.primaryHeight() - $0.frame.maxY } ?? 0)
        // Hover-in-the-bar-zone BEFORE the open, and keep the movement dense: when
        // hover events land while the bar is still being built, it materializes
        // already-expanded (~230 ms to thumbnails, measured) instead of entering
        // collapsed and morphing after the hover dwell (~700 ms). The race needs
        // events in flight the whole way through the entrance — hence 16 ms cadence.
        NativeBarWindows.warpPointer(CGPoint(x: topCG.x, y: topCG.y + 8))
        if !NativeBarWindows.barOnScreen() {
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        }
        oscillator?.invalidate()
        oscillator = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            oscillateFlip.toggle()
            NativeBarWindows.warpPointer(CGPoint(x: topCG.x, y: topCG.y + (oscillateFlip ? 3 : 12)))
            // Done once the tile thumbnails exist (or on the deadline): hand the pointer back.
            if NativeBarWindows.tilesOnScreen()
                || CACurrentMediaTime() - startedAt > expandDeadline {
                stopOscillatorRestoringPointer()
            }
        }
    }

    static func end() {
        guard active else { return }
        active = false
        stopOscillatorRestoringPointer()
        // Close only if Mission Control is still up — clicking a tile auto-dismisses,
        // and a blind toggle would then RE-open it.
        if NativeBarWindows.barOnScreen() {
            // Tell the overlay we're closing NOW so its labels ride the close animation,
            // rather than detecting the teardown only after the animation finishes.
            NotificationCenter.default.post(name: .speedySpacesMissionControlWillClose, object: nil)
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        }
        HotkeyDiag.log("nativeMC hold end")
    }

    private static func stopOscillatorRestoringPointer() {
        oscillator?.invalidate()
        oscillator = nil
        if let p = savedPointer {
            savedPointer = nil
            NativeBarWindows.warpPointer(p)
        }
    }
}
