import AppKit

/// The menu's header row: the app name on the left and, on the far right,
/// bordered icon buttons for Settings and Quit. Replaces the old "SpeedySpaces"
/// submenu — the two remaining actions are one click instead of a fly-out.
final class MenuHeaderRowView: NSView {
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    private enum Metric {
        static let outerInset: CGFloat = 5   // matches SpaceMenuRowView's highlight inset
        static let contentPad: CGFloat = 8
        static let height: CGFloat = 30
        static let buttonGap: CGFloat = 5
    }

    init(width: CGFloat, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onQuit = onQuit
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metric.height))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: "SpeedySpaces")
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .labelColor

        let quitButton = makeButton(symbol: "power", tooltip: "Quit SpeedySpaces",
                                    action: #selector(quitClicked))
        let settingsButton = makeButton(symbol: "gearshape", tooltip: "Settings…",
                                        action: #selector(settingsClicked))

        let inset = Metric.outerInset + Metric.contentPad
        for view in [label, quitButton, settingsButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor,
                                                     constant: -Metric.buttonGap),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.momentaryPushIn)
        button.toolTip = tooltip
        return button
    }

    /// Close the menu first, then act on the next runloop turn so the window (or app
    /// termination) lands after the menu's tracking loop has fully torn down — the same
    /// pattern as SpaceMenuRowView's click handling.
    private func perform(_ action: @escaping () -> Void) {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async(execute: action)
    }

    @objc private func settingsClicked() { perform(onSettings) }
    @objc private func quitClicked() { perform(onQuit) }

    // MARK: - Self-tests

    /// Layout invariants (label left, buttons right and inside the row) plus the
    /// target/action wiring, which can't be exercised by clicking in a headless run.
    static func selfChecks(_ check: SelfTest.Check) {
        _ = NSApplication.shared   // ensure AppKit is initialized before building views
        var settingsFired = false, quitFired = false
        let row = MenuHeaderRowView(width: 300,
                                    onSettings: { settingsFired = true },
                                    onQuit: { quitFired = true })
        row.layoutSubtreeIfNeeded()

        let label = row.subviews.compactMap { $0 as? NSTextField }.first
        check(label?.stringValue == "SpeedySpaces", "menu header: app-name label present")

        let buttons = row.subviews.compactMap { $0 as? NSButton }
            .sorted { $0.frame.minX < $1.frame.minX }
        check(buttons.count == 2, "menu header: two buttons")
        if let label, buttons.count == 2 {
            check(buttons[0].frame.minX > label.frame.maxX, "menu header: buttons sit right of the label")
            check(buttons[1].frame.maxX <= row.bounds.maxX, "menu header: buttons stay inside the row")
            check(buttons[0].toolTip == "Settings…" && buttons[1].toolTip == "Quit SpeedySpaces",
                  "menu header: settings left of quit, quit rightmost")
        }

        buttons.forEach { $0.performClick(nil) }
        // Actions land on the next main-queue turn (see perform(_:)) — drain it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(settingsFired && quitFired, "menu header: settings and quit actions fire")
    }
}
