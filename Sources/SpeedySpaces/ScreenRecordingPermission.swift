import AppKit

/// The Screen Recording grant that "move a window to another workspace" depends on.
///
/// The move holds the window in a server-side drag (`sm_dragWindowRelativeToMouse`) while the
/// native "Move a space" shortcut carries it across. The window server only hands a FOREIGN
/// window over to a drag for a process that holds Screen Recording — and it declines quietly:
/// the call still returns success, the window simply never follows, so the viewport switches
/// and the window is left behind. Measured on macOS 27.0 (26A5421a) with the same binary run
/// under a granted and an ungranted identity against the same window.
///
/// Nothing else in SpeedySpaces needs the grant, so it is asked for at the point of use rather
/// than at launch: a user who never moves windows between workspaces is never prompted.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shown at most once per launch, so a burst of blocked move presses produces one alert.
    private static var alerted = false

    /// Explain what is blocked and why, then — only with the user's agreement — register the
    /// app with the system (which is what makes it appear in the list) and open the pane.
    /// MAIN THREAD ONLY.
    static func presentHelp() {
        guard !alerted else { return }
        alerted = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow SpeedySpaces to move windows between workspaces"
        alert.informativeText = """
        Moving a window to another workspace asks the window server to carry the window \
        along with the workspace switch. macOS only allows that for an app with Screen \
        Recording access.

        SpeedySpaces does not record or capture your screen — switching workspaces, \
        shortcuts and the workspace switcher all keep working without this.

        Turn on SpeedySpaces under Privacy & Security → Screen & System Audio Recording, \
        then quit and reopen SpeedySpaces.
        """
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        openSettings()
    }

    /// Register the app in the Screen Recording list — which is what makes it APPEAR there
    /// at all, so it must happen before the pane opens — and then show the pane.
    static func openSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Call from a move that failed for want of the grant: log it and offer the flow.
    static func reportBlockedMove() {
        HotkeyDiag.log("windowDrag: blocked — Screen Recording not granted")
        DispatchQueue.main.async { presentHelp() }
    }
}
