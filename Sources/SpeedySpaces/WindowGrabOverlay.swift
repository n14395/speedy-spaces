import AppKit
import CoreGraphics

/// The invisible click sink the "move a window to another workspace" grab presses on.
///
/// `sm_dragWindowRelativeToMouse` binds a window to a mouse button that is *already down*,
/// so the move has to put one down — but the cursor is wherever the user left it, and a real
/// click there would follow a link, select text, or start dragging some app's content. The
/// synthetic mouse-down lands on this panel instead. Delivery of the rest of the gesture
/// follows the button's owner, so the mouse-up comes back to us too and the app under the
/// cursor never sees any of it.
///
/// The panel replaces the old mechanism's title-bar aiming entirely: nothing about the
/// target window has to be clickable, or even on screen, because the drag names the window
/// by ID. It also replaces the cursor choreography that went with it — warping the pointer to
/// the title bar, hiding it so the user wouldn't see the jump, and putting it back afterwards.
/// The press happens where the pointer already is, so it never moves.
///
/// Properties that are load-bearing, each measured rather than assumed (they come from the
/// window-shift research; see `~/build/window-shift/window-move-mechanism-analysis-v1.md`):
///
///  - **Small, not screen-covering.** The obvious hardening — a panel over the whole desktop
///    so nothing can ever be under the cursor — does not work: the window server deliberately
///    hit-tests past display-covering windows at high levels, so such a panel absorbs nothing
///    at any alpha. 40 pt also keeps snap-on-drag utilities from attributing a drag to it.
///  - **The press must wait for the window server.** `orderFrontRegardless` returning does not
///    make the panel hit-testable; a mouse-down emitted in that gap falls through to the app
///    beneath, which then owns the whole gesture. Readiness is therefore confirmed by the
///    panel's own window-list entry reporting on-screen, not by the AppKit call returning.
///  - **Non-activating.** A plain window absorbs the press just as well, but its click makes
///    SpeedySpaces frontmost — which would steal focus from the very window being moved.
///  - **Joins all spaces.** The whole point is that the space changes underneath while the
///    button is held; a panel tied to the origin space would ride out with it.
///
/// `show`/`hide`/`waitUntilReady` are safe to call off the main thread (the AppKit work hops),
/// which matters because the move walk runs on a background queue.
final class WindowGrabOverlay {
    static let shared = WindowGrabOverlay()

    /// Deliberately small — see the type comment.
    private static let size: CGFloat = 40

    private var panel: NSPanel?
    private let lock = NSLock()
    private var windowID: CGWindowID = 0
    private var serverConfirmed = false

    /// Place the panel centred on a global CG (top-left origin) point and order it in.
    func show(atCG point: CGPoint) {
        lock.lock(); serverConfirmed = false; lock.unlock()
        onMain {
            // The flip uses the PRIMARY screen's height and AppKit's global coordinates,
            // which is correct for displays at negative coordinates too.
            guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
            let panel = self.panel ?? self.makePanel()
            panel.setFrameOrigin(NSPoint(x: point.x - Self.size / 2,
                                         y: primaryHeight - point.y - Self.size / 2))
            panel.orderFrontRegardless()
            self.lock.lock(); self.windowID = CGWindowID(panel.windowNumber); self.lock.unlock()
        }
    }

    /// Block (off-main) until the window server reports the panel on screen, or `timeout`
    /// elapses. False means the press must NOT be fired — it would land in the user's app.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady { return true }
            usleep(5_000)
        }
        return isReady
    }

    private var isReady: Bool {
        lock.lock()
        let confirmed = serverConfirmed
        let wid = windowID
        lock.unlock()
        guard wid != 0 else { return false }
        if confirmed { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
              let entry = list.first,
              (entry[kCGWindowIsOnscreen as String] as? Bool) == true else { return false }
        lock.lock(); serverConfirmed = true; lock.unlock()
        return true
    }

    func hide() {
        lock.lock(); serverConfirmed = false; lock.unlock()
        onMain { self.panel?.orderOut(nil) }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// MAIN THREAD ONLY.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above everything, including other utilities' resident full-display overlays: if one
        // of those wins the hit-test the press lands on it instead and the grab never happens.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false   // must NOT be click-through: it exists to catch the press
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.setAccessibilityElement(false)
        panel.contentView?.setAccessibilityElement(false)
        self.panel = panel
        return panel
    }
}
