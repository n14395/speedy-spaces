import AppKit

/// Diagnostic: `SpeedySpaces --drive-mc [holdSeconds] [collapsed]` opens Mission Control and holds
/// it (expanded by default, or collapsed) so the running app's overlay can be observed/screenshot
/// unattended. Not part of the normal app; used only for testing. `holdSeconds <= 0` just ensures
/// Mission Control is closed and exits.
enum MissionControlDriver {
    /// True if the Mission Control spaces bar is on-screen.
    static func isOpen() -> Bool {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return infos.contains {
            (($0[kCGWindowOwnerName as String] as? String)?.localizedCaseInsensitiveContains("WindowManager") ?? false)
                && ($0[kCGWindowName as String] as? String) == "Spaces Bar"
        }
    }

    static func run(holdSeconds: Double, collapsed: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { exit(1) }

        if holdSeconds <= 0 {  // reset: ensure closed
            if isOpen() { _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            app.run(); exit(0)
        }

        var pin: Timer?
        func afterOpen() {
            if collapsed {
                CGWarpMouseCursorPosition(CGPoint(x: primary.frame.midX, y: primary.frame.height / 2))
            } else {
                // Oscillate the cursor near the top edge so the bar expands to thumbnails (a
                // static position posts zero-delta moves that don't register as hover movement).
                var flip = false
                let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    flip.toggle()
                    let p = CGPoint(x: primary.frame.midX, y: flip ? 3 : 12)
                    CGWarpMouseCursorPosition(p)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                }
                RunLoop.main.add(t, forMode: .common)
                pin = t
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
                pin?.invalidate()
                if isOpen() { _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
        func ensureOpen(_ attempt: Int) {
            if isOpen() { afterOpen(); return }
            guard attempt < 6 else { print("FAIL: could not open Mission Control"); exit(1) }
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { ensureOpen(attempt + 1) }
        }
        ensureOpen(0)
        app.run()
        exit(0)
    }
}
