import AppKit
import UniformTypeIdentifiers

/// Settings window: a preferences-style tabbed window (toolbar tabs, like System
/// Settings) with five panes — General, Menu Bar, Shortcuts, Switcher, and Thumbnails.
final class SettingsController: NSWindowController {

    private weak var collapseToggle: NSButton?
    private weak var hideSingleToggle: NSButton?
    private weak var animationControl: NSSegmentedControl?
    private weak var outcomeLabel: NSTextField?
    private var outcomeObserver: NSObjectProtocol?
    private weak var switcherHoldRecorder: ShortcutRecorderView?
    private weak var holdStatusDot: NSImageView?
    private weak var holdStatusLabel: NSTextField?
    private var hotkeysReloadObserver: NSObjectProtocol?
    private weak var listBox: RevealBox?
    private weak var iconBox: RevealBox?
    private weak var invertBox: RevealBox?
    private weak var radioIcons: NSButton?
    private weak var defaultIconWell: NSImageView?
    private var iconPopover: NSPopover?
    private weak var tabs: SettingsTabViewController?
    private weak var mcNamesToggle: NSButton?
    private weak var mcBoldToggle: NSButton?
    private var mcIconCards: [IconStyleCardView] = []
    private weak var mcIconHint: NSTextField?
    private weak var globalModifierToggle: NSButton?
    private weak var globalModifierRecorder: ShortcutRecorderView?
    private weak var moveExtraToggle: NSButton?
    private weak var moveExtraRecorder: ShortcutRecorderView?
    /// Switching rows (symbolic-hotkey id → recorder). Editable native bindings when the Global
    /// Modifier is off; read-only derived (globalModifier + key) when it's on.
    private var switchingRecorders: [(id: Int, recorder: ShortcutRecorderView)] = []
    /// Move rows. Read-only derived (native switch + extra) when Extra Modifier is on; editable
    /// reprogrammable chords when it's off.
    private var moveRecorders: [(action: HotkeyAction, recorder: ShortcutRecorderView)] = []
    private var nativeShortcutsObserver: NSObjectProtocol?
    /// The Screen Recording banner on the Moving Windows sub-tab: moving a window between
    /// workspaces is the ONE feature that needs the grant, so its state is shown where the
    /// move shortcuts are. Re-read whenever the pane refreshes or the window becomes key —
    /// the user may have granted it in System Settings while this window stayed open.
    private weak var screenRecordingStatus: NSTextField?
    private weak var screenRecordingButton: NSButton?
    private var screenRecordingActiveObserver: NSObjectProtocol?
    private weak var spacingValueLabel: NSTextField?
    private weak var edgeValueLabel: NSTextField?
    private weak var switcherFlashDurationReadout: NSTextField?
    /// Every recorder in the Shortcuts sub-tabs with its action, for switching them
    /// between whole-chord and key-only capture when the global-modifier scheme flips.
    private var tabRecorders: [(action: HotkeyAction, recorder: ShortcutRecorderView)] = []

    static func outcomeText(_ outcome: SwitchOutcome?) -> String {
        guard let outcome else { return "Last switch: —" }
        return "Last switch: \(outcome.summary)"
    }

    static func selfChecks(_ check: SelfTest.Check) {
        check(outcomeText(nil) == "Last switch: —", "outcomeText: nil placeholder")
        let outcome = SwitchOutcome(method: .gesture, fromOrdinal: 0, toOrdinal: 1,
                                    displayIndex: 0, ok: true, milliseconds: 5, reason: nil)
        check(outcomeText(outcome) == "Last switch: \(outcome.summary)",
              "outcomeText: embeds the outcome summary")
    }

    convenience init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        self.init(window: window)
        self.tabs = tabs
        tabs.addTabViewItem(makeGeneralPane())
        tabs.addTabViewItem(makeMenuBarPane())
        tabs.addTabViewItem(makeShortcutsPane())
        tabs.addTabViewItem(makeSwitcherPane())
        tabs.addTabViewItem(makeThumbnailsPane())
        window.title = tabs.tabViewItems.first?.label ?? "Settings"
        layoutReveals(animated: false)
        layoutInvertReveal(animated: false)
        tabs.resizeWindowToSelectedPane(animate: false)
    }

    // MARK: - Panes

    /// Wrap a vertical stack of controls into a fixed-width tab pane. The bottom pin is
    /// below-required priority: the tab view stretches every pane to the tallest one's
    /// height, so the gap under the stack must be free to grow while the tab controller
    /// animates the window down to this pane's fitting size (see resizeWindowToSelectedPane).
    private func makePane(label: String, symbol: String, views: [NSView]) -> NSTabViewItem {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        bottom.priority = NSLayoutConstraint.Priority(900)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 550),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            bottom,
        ])

        let vc = NSViewController()
        vc.view = container
        vc.title = label
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func makeGeneralPane() -> NSTabViewItem {
        let loginToggle = NSButton(checkboxWithTitle: "Open SpeedySpaces at login",
                                   target: self, action: #selector(toggleLogin(_:)))
        loginToggle.state = LoginItem.isEnabled ? .on : .off

        let methodLabel = NSTextField(labelWithString: "Switch spaces using:")
        methodLabel.font = .systemFont(ofSize: 12)
        let methodPopup = NSPopUpButton()
        methodPopup.addItems(withTitles: SwitchMethod.allCases.map { $0.label })
        methodPopup.selectItem(withTitle: Prefs.switchMethod.label)
        methodPopup.target = self
        methodPopup.action = #selector(changeSwitchMethod(_:))
        let methodRow = NSStackView(views: [methodLabel, methodPopup])
        methodRow.orientation = .horizontal
        methodRow.spacing = 8

        let animationLabel = NSTextField(labelWithString: "Gesture animation:")
        animationLabel.font = .systemFont(ofSize: 12)
        let animationControl = NSSegmentedControl(
            labels: GestureAnimation.allCases.map { $0.label },
            trackingMode: .selectOne, target: self, action: #selector(changeAnimation(_:)))
        animationControl.selectedSegment = (Prefs.gestureAnimation == .instant) ? 0 : 1
        animationControl.isEnabled = (Prefs.switchMethod == .gesture)
        self.animationControl = animationControl
        let animationRow = NSStackView(views: [animationLabel, animationControl])
        animationRow.orientation = .horizontal
        animationRow.spacing = 8

        let outcomeLabel = NSTextField(labelWithString: SettingsController.outcomeText(SpacesManagerHolder.shared?.lastOutcome))
        outcomeLabel.font = .systemFont(ofSize: 11)
        outcomeLabel.textColor = .secondaryLabelColor
        outcomeLabel.preferredMaxLayoutWidth = 510
        self.outcomeLabel = outcomeLabel

        let namingNote = NSTextField(wrappingLabelWithString:
            "Custom names and icons are always active in SpeedySpaces’s menu and menubar.")
        namingNote.textColor = .secondaryLabelColor
        namingNote.font = .systemFont(ofSize: 11)
        namingNote.preferredMaxLayoutWidth = 510

        let backupHeader = NSTextField(labelWithString: "Configuration")
        backupHeader.font = .boldSystemFont(ofSize: 13)
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportConfig(_:)))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importConfig(_:)))
        let backupRow = NSStackView(views: [exportButton, importButton])
        backupRow.orientation = .horizontal
        backupRow.spacing = 8
        let backupNote = NSTextField(wrappingLabelWithString:
            "Save your space names, icons, per-space shortcuts and all preferences to a file — "
            + "or restore them. Wallpapers aren’t included. When restoring on another Mac, names "
            + "re-attach by display position where the space IDs differ.")
        backupNote.textColor = .secondaryLabelColor
        backupNote.font = .systemFont(ofSize: 11)
        backupNote.preferredMaxLayoutWidth = 510

        outcomeObserver = NotificationCenter.default.addObserver(
            forName: .speedySpacesSwitchOutcome, object: nil, queue: .main) { [weak self] note in
            let outcome = note.userInfo?["outcome"] as? SwitchOutcome
            self?.outcomeLabel?.stringValue = SettingsController.outcomeText(outcome)
        }

        let wrapToggle = NSButton(checkboxWithTitle: "Wrap around at the first and last workspace",
                                  target: self, action: #selector(toggleHotkeyWrap(_:)))
        wrapToggle.state = Prefs.hotkeyWrapAround ? .on : .off
        wrapToggle.toolTip = "Applies to this app's Next/Previous Space and relative window moves, "
            + "and also makes macOS's own Move-left/right-a-space shortcuts wrap past the ends "
            + "(requires Accessibility)."

        return makePane(label: "General", symbol: "gearshape", views: [
            loginToggle, methodRow, animationRow,
            wrapToggle, outcomeLabel, namingNote,
            backupHeader, backupRow, backupNote,
        ])
    }

    private func makeMenuBarPane() -> NSTabViewItem {
        func indent(_ view: NSView) -> NSStackView {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let row = NSStackView(views: [spacer, view])
            row.orientation = .horizontal
            row.spacing = 0
            return row
        }

        // Multi-display behavior — governs only what this menu bar item shows across
        // several screens, so it lives here rather than under General.
        let displaysHeader = NSTextField(labelWithString: "Displays")
        displaysHeader.font = .boldSystemFont(ofSize: 13)

        let displayToggle = NSButton(checkboxWithTitle: "Menu bar follows the focused display",
                                     target: self, action: #selector(toggleFollowDisplay(_:)))
        displayToggle.state = Prefs.menuBarFollowsFocusedDisplay ? .on : .off
        displayToggle.toolTip = "With multiple displays, show the current space of the display "
            + "you're working on. When off, the menu bar lists every display's workspaces."

        // Qualifiers for the all-displays menu bar (follows-focused OFF); disabled while
        // the menu bar follows the focused display.
        let collapseToggle = NSButton(checkboxWithTitle: "Collapse other displays to their current workspace",
                                      target: self, action: #selector(toggleCollapseDisplays(_:)))
        collapseToggle.state = Prefs.menuBarCollapseUnfocusedDisplays ? .on : .off
        collapseToggle.isEnabled = !Prefs.menuBarFollowsFocusedDisplay
        collapseToggle.toolTip = "Show the full workspace list only for the display you're working on; "
            + "other displays shrink to just their current workspace."
        self.collapseToggle = collapseToggle

        let hideSingleToggle = NSButton(checkboxWithTitle: "Hide displays with a single workspace",
                                        target: self, action: #selector(toggleHideSingleDisplays(_:)))
        hideSingleToggle.state = Prefs.menuBarHideSingleSpaceDisplays ? .on : .off
        hideSingleToggle.isEnabled = !Prefs.menuBarFollowsFocusedDisplay
        hideSingleToggle.toolTip = "Leave displays with only one workspace out of the menu bar."
        self.hideSingleToggle = hideSingleToggle

        let mbIconToggle = NSButton(checkboxWithTitle: "Current space icon",
                                    target: self, action: #selector(toggleMenuBarIcon(_:)))
        mbIconToggle.state = Prefs.menuBarShowIcon ? .on : .off

        let mbNameToggle = NSButton(checkboxWithTitle: "Current space name",
                                    target: self, action: #selector(toggleMenuBarName(_:)))
        mbNameToggle.state = Prefs.menuBarShowName ? .on : .off

        let mbNumberToggle = NSButton(checkboxWithTitle: "Current space number",
                                      target: self, action: #selector(toggleMenuBarNumber(_:)))
        mbNumberToggle.state = Prefs.menuBarShowNumber ? .on : .off
        mbNumberToggle.toolTip = "Show the current workspace's number (its position on the "
            + "display) — before the name when both are on."

        let mbSwitcherToggle = NSButton(checkboxWithTitle: "Show Other Workspaces",
                                        target: self, action: #selector(toggleMenuBarSwitcher(_:)))
        mbSwitcherToggle.state = Prefs.menuBarShowSwitcher ? .on : .off

        let styleLabel = NSTextField(labelWithString: "Workspace list:")
        styleLabel.font = .systemFont(ofSize: 12)
        let radioNumbers = NSButton(radioButtonWithTitle: "Numbers",
                                    target: self, action: #selector(changeWorkspaceListStyle(_:)))
        let radioIcons = NSButton(radioButtonWithTitle: "Icons",
                                  target: self, action: #selector(changeWorkspaceListStyle(_:)))
        (Prefs.workspaceListStyle == .icons ? radioIcons : radioNumbers).state = .on
        self.radioIcons = radioIcons
        let styleRow = NSStackView(views: [styleLabel, radioNumbers, radioIcons])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8

        let sizeLabel = NSTextField(labelWithString: "Size:")
        sizeLabel.font = .systemFont(ofSize: 12)
        let sizeSlider = NSSlider(value: Double(Prefs.menuBarSwitcherSquareSize),
                                  minValue: 12, maxValue: 22,
                                  target: self, action: #selector(changeSwitcherSquareSize(_:)))
        sizeSlider.isContinuous = true
        sizeSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let sizeRow = NSStackView(views: [sizeLabel, sizeSlider])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        // Spacing & padding: fine layout control over the strip. A shared helper keeps the
        // sliders aligned (fixed-width right-justified captions) and shows the live pt value
        // in a trailing readout that its action selector keeps in sync.
        func metricRow(_ caption: String, value: CGFloat, min: Double, max: Double,
                       action: Selector) -> (row: NSStackView, valueLabel: NSTextField) {
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 12)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let slider = NSSlider(value: Double(value), minValue: min, maxValue: max,
                                  target: self, action: action)
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let readout = NSTextField(labelWithString: "\(Int(value.rounded())) pt")
            readout.font = .systemFont(ofSize: 12)
            readout.textColor = .secondaryLabelColor
            readout.alignment = .left
            readout.widthAnchor.constraint(equalToConstant: 42).isActive = true
            let row = NSStackView(views: [label, slider, readout])
            row.orientation = .horizontal
            row.spacing = 8
            return (row, readout)
        }

        let spacingHeader = NSTextField(labelWithString: "Spacing & padding")
        spacingHeader.font = .boldSystemFont(ofSize: 13)
        let spacing = metricRow("Spacing:", value: Prefs.menuBarSpacing,
                                min: 0, max: 16, action: #selector(changeSpacing(_:)))
        self.spacingValueLabel = spacing.valueLabel
        let edge = metricRow("Edge padding:", value: Prefs.menuBarEdgePadding,
                             min: 0, max: 20, action: #selector(changeEdgePadding(_:)))
        self.edgeValueLabel = edge.valueLabel
        let marginRow = spacing.row
        let edgeRow = edge.row

        let backgroundToggle = NSButton(checkboxWithTitle: "Show background",
                                        target: self, action: #selector(toggleSwitcherGreyBackground(_:)))
        backgroundToggle.state = Prefs.menuBarSwitcherGreyBackground ? .on : .off

        let invertToggle = NSButton(checkboxWithTitle: "Invert Colours",
                                    target: self, action: #selector(toggleSwitcherInvertColours(_:)))
        invertToggle.state = Prefs.menuBarSwitcherInvertColours ? .on : .off
        let invertBox = RevealBox(views: [invertToggle], leftInset: 20, topInset: 0,
                                  hidesWhenCollapsed: true)
        self.invertBox = invertBox

        let iconLabel = NSTextField(labelWithString: "Default icon:")
        iconLabel.font = .systemFont(ofSize: 12)
        let iconWell = NSImageView()
        iconWell.imageScaling = .scaleProportionallyUpOrDown
        iconWell.image = IconRendering.image(for: Prefs.workspaceListDefaultIcon, pointSize: 18)
        iconWell.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        self.defaultIconWell = iconWell
        let changeButton = NSButton(title: "Change…", target: self,
                                    action: #selector(showDefaultIconPopover(_:)))
        let iconRow = NSStackView(views: [iconLabel, iconWell, changeButton])
        iconRow.orientation = .horizontal
        iconRow.spacing = 8

        // Nested reveals: iconBox (Default icon row, shown only for the Icons style)
        // sits last inside listBox (the whole group, shown while the list is enabled).
        // iconBox keeps its inter-row gap via its top inset — the stack spacing before
        // it is zeroed so nothing lingers when it collapses.
        let iconBox = RevealBox(views: [iconRow], leftInset: 20, topInset: 8,
                                hidesWhenCollapsed: false)
        self.iconBox = iconBox
        let listBox = RevealBox(views: [styleRow, iconBox],
                                leftInset: 20, topInset: 0, hidesWhenCollapsed: true)
        listBox.contentStack.setCustomSpacing(0, after: styleRow)
        self.listBox = listBox

        let mbNote = NSTextField(wrappingLabelWithString:
            "Choose what the menu bar shows. “Show Other Workspaces” adds a clickable square for each "
            + "space on the focused display — left-click a square to switch to it, right-click (or click "
            + "the current space) for the menu. Size, spacing, and padding apply to the whole menu "
            + "bar item — spacing adds margin around every icon (separating adjacent ones), and edge "
            + "padding insets both ends of the item.")
        mbNote.textColor = .secondaryLabelColor
        mbNote.font = .systemFont(ofSize: 11)
        mbNote.preferredMaxLayoutWidth = 510

        return makePane(label: "Menu Bar", symbol: "menubar.rectangle", views: [
            displaysHeader, displayToggle, indent(collapseToggle), indent(hideSingleToggle),
            mbIconToggle, mbNameToggle, mbNumberToggle, mbSwitcherToggle, listBox, sizeRow, backgroundToggle,
            invertBox, spacingHeader, marginRow, edgeRow, mbNote,
        ])
    }

    private func makeSwitcherPane() -> NSTabViewItem {
        // 1. Triggers — when the switcher appears.
        let triggersHeader = NSTextField(labelWithString: "Triggers")
        triggersHeader.font = .boldSystemFont(ofSize: 13)

        let flashToggle = NSButton(checkboxWithTitle: "Show the workspace switcher when changing workspaces",
                                   target: self, action: #selector(toggleSwitcherFlash(_:)))
        flashToggle.state = Prefs.switcherFlashOnSpaceChange ? .on : .off

        // Minimum on-screen time for that flash — a floor (hover / consecutive switches extend
        // it). Raise it when a quick programmatic switch flashes by too fast to read.
        let durationLabel = NSTextField(labelWithString: "Minimum time shown:")
        durationLabel.font = .systemFont(ofSize: 12)
        let durationSlider = NSSlider(value: Prefs.switcherFlashDuration, minValue: 0.5, maxValue: 5.0,
                                      target: self, action: #selector(changeSwitcherFlashDuration(_:)))
        durationSlider.isContinuous = true
        durationSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let durationReadout = NSTextField(labelWithString: String(format: "%.1f s", Prefs.switcherFlashDuration))
        durationReadout.font = .systemFont(ofSize: 12)
        durationReadout.textColor = .secondaryLabelColor
        durationReadout.widthAnchor.constraint(equalToConstant: 42).isActive = true
        self.switcherFlashDurationReadout = durationReadout
        let durationRow = NSStackView(views: [durationLabel, durationSlider, durationReadout])
        durationRow.orientation = .horizontal
        durationRow.spacing = 8
        durationRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        // 2. Show while a key is held: a checkbox, then — indented beneath it — the shortcut
        // recorder with a registration status light beside it.
        let holdToggle = NSButton(checkboxWithTitle: "Show the workspace switcher when holding down a key",
                                  target: self, action: #selector(toggleSwitcherHold(_:)))
        holdToggle.state = Prefs.switcherHoldEnabled ? .on : .off

        let recorder = ShortcutRecorderView()
        recorder.spec = Prefs.hotkey(for: .holdSwitcher)
        recorder.allowsBareShortcuts = true
        recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
        recorder.validate = { ConflictChecker.hotkeyConflicts(for: $0, excludingAction: .holdSwitcher) }
        recorder.onChange = { [weak self] in
            Prefs.setHotkey($0, for: .holdSwitcher)
            self?.syncHoldSwitcherUI()   // mirrors into the Shortcuts pane's App-tab row
        }
        recorder.onConflicts = { [weak self] _ in self?.updateHoldStatus() }
        self.switcherHoldRecorder = recorder

        let statusDot = NSImageView()
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        self.holdStatusDot = statusDot
        self.holdStatusLabel = statusLabel
        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 4

        let holdControls = NSStackView(views: [recorder, statusRow])
        holdControls.orientation = .horizontal
        holdControls.spacing = 10
        holdControls.alignment = .centerY
        holdControls.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let holdBlock = NSStackView(views: [holdToggle, holdControls])
        holdBlock.orientation = .vertical
        holdBlock.alignment = .leading
        holdBlock.spacing = 6

        // 3. Type selector: a heading, then the two positions of the app's own floating bar.
        let typeLabel = NSTextField(labelWithString: "Type")
        typeLabel.font = .boldSystemFont(ofSize: 13)
        let typeMimic = NSButton(radioButtonWithTitle: "Mimic Mission Control",
                                 target: self, action: #selector(changeSwitcherType(_:)))
        typeMimic.tag = 0
        typeMimic.toolTip = "The app's own bar, full-width along the top of the screen where "
            + "Mission Control's own bar sits."
        let typePopover = NSButton(radioButtonWithTitle: "Classic Popover",
                                   target: self, action: #selector(changeSwitcherType(_:)))
        typePopover.tag = 1
        typePopover.toolTip = "The app's own bar as a centered panel hugging the thumbnails, "
            + "up to 80% of the screen width — beyond that the thumbnails shrink."
        // A config stored from the retired "Native Mission Control" style resolves to .hud
        // (see Prefs.switcherStyle), so only the two positions can be selected here.
        if Prefs.switcherPosition == .classicPopover { typePopover.state = .on }
        else { typeMimic.state = .on }
        let typeRadios = NSStackView(views: [typeMimic, typePopover])
        typeRadios.orientation = .vertical
        typeRadios.alignment = .leading
        typeRadios.spacing = 6
        typeRadios.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        // 5. Concise, current description.
        let note = NSTextField(wrappingLabelWithString:
            "Shows your workspaces as thumbnails — briefly whenever the active workspace "
            + "changes, and/or for as long as you hold the chosen key (enable either above). "
            + "“Mimic Mission Control” and “Classic Popover” are two positions for the app's own bar. "
            + "The names, icons and bold weight on the thumbnails are set in the Thumbnails tab.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 510

        // Keep the hold-shortcut status light current: refresh after every registration pass
        // (recording, conflicts, another app grabbing the chord) and set the initial state.
        hotkeysReloadObserver = NotificationCenter.default.addObserver(
            forName: .speedySpacesHotkeysReloaded, object: nil, queue: .main) { [weak self] _ in
            self?.updateHoldStatus()
        }
        DispatchQueue.main.async { [weak self] in self?.updateHoldStatus() }

        return makePane(label: "Switcher", symbol: "rectangle.3.group.bubble", views: [
            triggersHeader, flashToggle, durationRow, holdBlock, typeLabel, typeRadios, note,
        ])
    }

    /// Reflect the hold-to-show shortcut's live state in the status light next to the recorder:
    /// green when registered, orange on an internal conflict, red when another app owns the
    /// chord, grey when none is set. Hidden entirely when the hold feature is switched off.
    private func updateHoldStatus() {
        guard let dot = holdStatusDot, let label = holdStatusLabel else { return }
        let on = Prefs.switcherHoldEnabled
        switcherHoldRecorder?.alphaValue = on ? 1 : 0.5
        func show(_ symbol: String, _ color: NSColor, _ text: String) {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            dot.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
                .withSymbolConfiguration(cfg)
            label.stringValue = text
            label.textColor = color
            dot.isHidden = false
            label.isHidden = false
        }
        guard on else { dot.isHidden = true; label.isHidden = true; return }
        guard let spec = Prefs.hotkey(for: .holdSwitcher) else {
            show("circle", .secondaryLabelColor, "No shortcut set")
            return
        }
        let conflicts = ConflictChecker.hotkeyConflicts(for: spec, excludingAction: .holdSwitcher)
        if !conflicts.isEmpty {
            show("exclamationmark.triangle.fill", .systemOrange,
                 "Conflicts with " + conflicts.map { $0.description }.joined(separator: ", "))
        } else if HotkeyManagerHolder.shared?.failedRegistrations["holdSwitcher"] != nil {
            show("xmark.circle.fill", .systemRed, "Already in use by another app")
        } else {
            show("checkmark.circle.fill", .systemGreen, "Shortcut registered")
        }
    }

    private func makeThumbnailsPane() -> NSTabViewItem {
        // Names: one toggle, its weight option riding alongside.
        let namesHeader = NSTextField(labelWithString: "Workspace Names")
        namesHeader.font = .boldSystemFont(ofSize: 13)
        let namesToggle = NSButton(checkboxWithTitle: "Show workspace names",
                                   target: self, action: #selector(toggleMissionControlNames(_:)))
        let boldToggle = NSButton(checkboxWithTitle: "Bold",
                                  target: self, action: #selector(toggleMissionControlLabelsBold(_:)))
        boldToggle.state = Prefs.missionControlLabelsBold ? .on : .off
        self.mcNamesToggle = namesToggle
        self.mcBoldToggle = boldToggle
        let namesRow = NSStackView(views: [namesToggle, boldToggle])
        namesRow.orientation = .horizontal
        namesRow.spacing = 16

        // Icons: where the icon sits, picked from four illustrated cards (the mini
        // previews mirror the live names toggle, so what you pick is what you get).
        let iconsHeader = NSTextField(labelWithString: "Workspace Icons")
        iconsHeader.font = .boldSystemFont(ofSize: 13)
        let cards: [IconStyleCardView] = [
            IconStyleCardView(style: .beforeName, title: "Before the name"),
            IconStyleCardView(style: .largeAbove, title: "Above the thumbnail"),
            IconStyleCardView(style: .largeOver, title: "On the thumbnail"),
            IconStyleCardView(style: .hidden, title: "No icons"),
        ]
        for card in cards {
            card.onSelect = { [weak self] style in
                Prefs.thumbnailIconStyle = style
                self?.refreshThumbnailControls()
            }
        }
        self.mcIconCards = cards
        let cardsRow = NSStackView(views: cards)
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 10
        cardsRow.alignment = .top

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 510
        self.mcIconHint = hint

        let mcNote = NSTextField(wrappingLabelWithString:
            "Names and icons label each workspace’s thumbnail — on the switcher’s tiles and above "
            + "the thumbnails in the real Mission Control, whichever switcher type you use. Apple’s "
            + "own “Desktop N” caption stays put below. No SIP or system changes required.")
        mcNote.textColor = .secondaryLabelColor
        mcNote.font = .systemFont(ofSize: 11)
        mcNote.preferredMaxLayoutWidth = 510

        refreshThumbnailControls()
        return makePane(label: "Thumbnails", symbol: "textformat", views: [
            namesHeader, namesRow, iconsHeader, cardsRow, hint, mcNote,
        ])
    }

    /// One source of truth for the Thumbnails pane's interlock: "large icons above the
    /// thumbnail" takes over the names row, so it locks the names toggle (shown off,
    /// disabled) without discarding the underlying pref; everything else re-reads live
    /// prefs. The cards mirror the effective names visibility in their previews.
    private func refreshThumbnailControls() {
        let style = Prefs.thumbnailIconStyle
        let namesLocked = (style == .largeAbove)
        mcNamesToggle?.isEnabled = !namesLocked
        mcNamesToggle?.state = Prefs.thumbnailNamesVisible ? .on : .off
        mcNamesToggle?.toolTip = namesLocked
            ? "Large icons above the thumbnail stand in for the names." : nil
        mcBoldToggle?.isEnabled = Prefs.thumbnailNamesVisible
        for card in mcIconCards {
            card.isSelected = (card.style == style)
            card.showsNameRow = Prefs.thumbnailNamesVisible
        }
        mcIconHint?.stringValue = Self.iconStyleHint(for: style)
    }

    private static func iconStyleHint(for style: Prefs.ThumbnailIconStyle) -> String {
        switch style {
        case .beforeName:
            return "A small icon leads each workspace’s name in the row above its thumbnail."
        case .largeAbove:
            return "A large icon stands in for the name above each thumbnail — workspace names are hidden."
        case .largeOver:
            return "A large icon sits in the middle of each thumbnail; names keep their row above."
        case .hidden:
            return "No icons — thumbnails carry workspace names only."
        }
    }

    deinit {
        if let outcomeObserver { NotificationCenter.default.removeObserver(outcomeObserver) }
        if let hotkeysReloadObserver { NotificationCenter.default.removeObserver(hotkeysReloadObserver) }
        if let nativeShortcutsObserver { NotificationCenter.default.removeObserver(nativeShortcutsObserver) }
        if let screenRecordingActiveObserver {
            NotificationCenter.default.removeObserver(screenRecordingActiveObserver)
        }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let result = LoginItem.setEnabled(sender.state == .on)
        if !result.ok {
            sender.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn’t update login item"
            alert.informativeText = (result.error ?? "Unknown error")
                + "\n\nTip: move SpeedySpaces.app to /Applications and try again."
            alert.runModal()
        }
    }

    @objc private func toggleSwitcherFlash(_ sender: NSButton) {
        Prefs.switcherFlashOnSpaceChange = sender.state == .on
    }

    @objc private func exportConfig(_ sender: NSButton) {
        guard let spaces = SpacesManagerHolder.shared, let store = MetadataStoreHolder.shared,
              let data = ConfigBackup.export(spaces: spaces, store: store) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "SpeedySpaces-backup-\(df.string(from: Date())).json"
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            if resp == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    @objc private func importConfig(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
                  let spaces = SpacesManagerHolder.shared, let store = MetadataStoreHolder.shared
            else { return }
            let summary = ConfigBackup.importConfig(from: data, spaces: spaces, store: store)
            let alert = NSAlert()
            if let s = summary {
                alert.messageText = "Configuration imported"
                alert.informativeText = "Spaces: \(s.applied) applied, \(s.remapped) remapped, "
                    + "\(s.unmatched) unmatched.\nPreferences restored."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t read that file"
                alert.informativeText = "It doesn’t look like a SpeedySpaces backup."
            }
            if let window = self?.window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    @objc private func toggleSwitcherHold(_ sender: NSButton) {
        Prefs.switcherHoldEnabled = sender.state == .on
        updateHoldStatus()
        refreshScreenRecordingBanner()
    }

    /// Re-read the Screen Recording grant and restate it. Granting takes effect for the
    /// window server on the next launch, so a freshly-granted app says so rather than
    /// claiming a capability this process does not yet have.
    fileprivate func refreshScreenRecordingBanner() {
        let granted = ScreenRecordingPermission.isGranted
        screenRecordingStatus?.stringValue = granted
            ? "✔︎ Screen Recording is allowed — moving windows between workspaces works."
            : "⚠︎ Screen Recording is not allowed — moving windows between workspaces won’t work."
        screenRecordingStatus?.textColor = granted ? .secondaryLabelColor : .systemOrange
        screenRecordingButton?.isHidden = granted
    }

    @objc fileprivate func openScreenRecordingSettings(_ sender: NSButton) {
        ScreenRecordingPermission.openSettings()
    }

    /// The three switcher types collapse the (style, position) prefs into one choice:
    /// tag 0 = the app's bar in the Mission Control position, tag 1 = the app's bar as a
    /// centered popover, tag 2 = the real Mission Control.
    @objc private func changeSwitcherType(_ sender: NSButton) {
        Prefs.switcherStyle = .hud
        Prefs.switcherPosition = sender.tag == 1 ? .classicPopover : .mimicMissionControl
    }

    @objc private func toggleFollowDisplay(_ sender: NSButton) {
        Prefs.menuBarFollowsFocusedDisplay = (sender.state == .on)
        collapseToggle?.isEnabled = sender.state == .off
        hideSingleToggle?.isEnabled = sender.state == .off
    }

    @objc private func toggleCollapseDisplays(_ sender: NSButton) {
        Prefs.menuBarCollapseUnfocusedDisplays = (sender.state == .on)
    }

    @objc private func toggleHideSingleDisplays(_ sender: NSButton) {
        Prefs.menuBarHideSingleSpaceDisplays = (sender.state == .on)
    }

    @objc private func changeSwitchMethod(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < SwitchMethod.allCases.count else { return }
        Prefs.switchMethod = SwitchMethod.allCases[idx]
        animationControl?.isEnabled = (Prefs.switchMethod == .gesture)
    }

    @objc private func changeAnimation(_ sender: NSSegmentedControl) {
        Prefs.gestureAnimation = (sender.selectedSegment == 0) ? .instant : .natural
    }

    @objc private func toggleMissionControlNames(_ sender: NSButton) {
        Prefs.missionControlLabels = (sender.state == .on)
        refreshThumbnailControls()
    }

    @objc private func toggleMissionControlLabelsBold(_ sender: NSButton) {
        Prefs.missionControlLabelsBold = (sender.state == .on)
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        Prefs.menuBarShowIcon = (sender.state == .on)
    }

    @objc private func toggleMenuBarName(_ sender: NSButton) {
        Prefs.menuBarShowName = (sender.state == .on)
    }

    @objc private func toggleMenuBarNumber(_ sender: NSButton) {
        Prefs.menuBarShowNumber = (sender.state == .on)
    }

    @objc private func toggleMenuBarSwitcher(_ sender: NSButton) {
        Prefs.menuBarShowSwitcher = (sender.state == .on)
        layoutReveals(animated: true)
    }

    @objc private func changeWorkspaceListStyle(_ sender: NSButton) {
        Prefs.workspaceListStyle = (sender == radioIcons) ? .icons : .numbers
        layoutReveals(animated: true)
    }

    /// Reconcile both reveal boxes with the prefs in one animation. The outer target is
    /// computed arithmetically — its current fitting height with the inner box's current
    /// constant swapped for the inner target — so the nested slide stays in sync. The
    /// pane's bottom is pinned, so the window height animates along with the reveal.
    private func layoutReveals(animated: Bool) {
        guard let outer = listBox, let inner = iconBox else { return }
        let listOn = Prefs.menuBarShowSwitcher
        let iconsOn = Prefs.workspaceListStyle == .icons
        let innerTarget = iconsOn ? inner.revealedHeight : 0
        let outerTarget = listOn ? outer.revealedHeight - inner.heightConstant + innerTarget : 0
        guard animated else {
            inner.apply(height: innerTarget, revealed: iconsOn, animated: false)
            outer.apply(height: outerTarget, revealed: listOn, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            inner.apply(height: innerTarget, revealed: iconsOn, animated: true)
            outer.apply(height: outerTarget, revealed: listOn, animated: true)
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            // Re-read the prefs: rapid toggling may have superseded this animation.
            self?.listBox?.finishCollapse(revealedNow: Prefs.menuBarShowSwitcher)
            self?.iconBox?.finishCollapse(revealedNow: Prefs.menuBarShowSwitcher
                                          && Prefs.workspaceListStyle == .icons)
            self?.tabs?.resizeWindowToSelectedPane(animate: true)
        })
    }

    @objc private func showDefaultIconPopover(_ sender: NSButton) {
        let picker = DefaultIconPickerView(current: Prefs.workspaceListDefaultIcon)
        picker.onChange = { [weak self] meta in
            self?.defaultIconWell?.image = IconRendering.image(for: meta, pointSize: 18)
        }
        let vc = NSViewController()
        vc.view = picker
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.behavior = .transient
        iconPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func toggleSwitcherGreyBackground(_ sender: NSButton) {
        Prefs.menuBarSwitcherGreyBackground = (sender.state == .on)
        layoutInvertReveal(animated: true)
    }

    @objc private func toggleSwitcherInvertColours(_ sender: NSButton) {
        Prefs.menuBarSwitcherInvertColours = (sender.state == .on)
    }

    /// Slide the "Invert Colours" toggle open/closed with the background checkbox. Its
    /// own animation (not layoutReveals'): the box is top-level, with no nested height
    /// arithmetic to coordinate.
    private func layoutInvertReveal(animated: Bool) {
        guard let box = invertBox else { return }
        let on = Prefs.menuBarSwitcherGreyBackground
        let target = on ? box.revealedHeight : 0
        guard animated else {
            box.apply(height: target, revealed: on, animated: false)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            box.apply(height: target, revealed: on, animated: true)
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.invertBox?.finishCollapse(revealedNow: Prefs.menuBarSwitcherGreyBackground)
            self?.tabs?.resizeWindowToSelectedPane(animate: true)
        })
    }

    @objc private func changeSwitcherSquareSize(_ sender: NSSlider) {
        Prefs.menuBarSwitcherSquareSize = CGFloat(sender.doubleValue)
    }

    @objc private func changeSwitcherFlashDuration(_ sender: NSSlider) {
        Prefs.switcherFlashDuration = sender.doubleValue
        switcherFlashDurationReadout?.stringValue = String(format: "%.1f s", Prefs.switcherFlashDuration)
    }

    @objc private func changeSpacing(_ sender: NSSlider) {
        let v = sender.doubleValue.rounded()
        Prefs.menuBarSpacing = CGFloat(v)
        spacingValueLabel?.stringValue = "\(Int(v)) pt"
    }

    @objc private func changeEdgePadding(_ sender: NSSlider) {
        let v = sender.doubleValue.rounded()
        Prefs.menuBarEdgePadding = CGFloat(v)
        edgeValueLabel?.stringValue = "\(Int(v)) pt"
    }

    func present() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Toolbar-style tab controller that mirrors the selected pane's name into the window
/// title (the window observes its content view controller's `title`, so that — not
/// `window.title` directly — is what must be set) and resizes the window to each pane's
/// fitting height on selection, matching the System Settings convention.
private final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        title = tabViewItem?.viewController?.title ?? tabViewItem?.label
        resizeWindowToSelectedPane(animate: view.window?.isVisible ?? false)
    }

    /// Animate the window frame (top edge fixed) so the content area matches the
    /// selected pane's fitting size. Also called after a RevealBox expands/collapses,
    /// since constraint changes inside a pane don't move the window frame on their own.
    func resizeWindowToSelectedPane(animate: Bool) {
        guard let window = view.window,
              selectedTabViewItemIndex >= 0,
              let paneView = tabViewItems[selectedTabViewItemIndex].viewController?.view
        else { return }
        paneView.layoutSubtreeIfNeeded()
        let target = paneView.fittingSize
        let content = window.contentRect(forFrameRect: window.frame)
        var newContent = content
        newContent.origin.y = content.maxY - target.height
        newContent.size = target
        window.setFrame(window.frameRect(forContentRect: newContent),
                        display: true, animate: animate)
    }
}

/// A settings sub-section that slides open/closed: a layer-clipped container whose
/// height constraint animates 0 ↔ the content stack's fitting height while the content
/// fades. `apply` only sets constraints/alpha so a controller can drive several boxes
/// (nested ones included) inside one NSAnimationContext group. Boxes that sit directly
/// in the window's main stack hide themselves once collapsed so the stack's inter-view
/// spacing collapses too (`hidesWhenCollapsed`); nested boxes instead keep their own
/// spacing via a top edge inset and never toggle isHidden.
private final class RevealBox: NSView {
    let contentStack: NSStackView
    private var heightC: NSLayoutConstraint!
    private let hidesWhenCollapsed: Bool

    /// Current constraint constant — read by the nested-height arithmetic.
    var heightConstant: CGFloat { heightC.constant }
    /// The height this box wants when revealed.
    var revealedHeight: CGFloat { contentStack.fittingSize.height }

    init(views: [NSView], leftInset: CGFloat, topInset: CGFloat, hidesWhenCollapsed: Bool) {
        contentStack = NSStackView(views: views)
        self.hidesWhenCollapsed = hidesWhenCollapsed
        super.init(frame: .zero)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: topInset, left: leftInset, bottom: 2, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        let h = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            h,
        ])
        heightC = h
        isHidden = hidesWhenCollapsed
        contentStack.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Set height/visibility. When `animated`, the caller provides the animation group
    /// and calls `finishCollapse` from its completion; un-hiding happens up front so
    /// the expansion is visible.
    func apply(height: CGFloat, revealed: Bool, animated: Bool) {
        if revealed && hidesWhenCollapsed { isHidden = false }
        if animated {
            heightC.animator().constant = height
            contentStack.animator().alphaValue = revealed ? 1 : 0
        } else {
            heightC.constant = height
            contentStack.alphaValue = revealed ? 1 : 0
            if hidesWhenCollapsed { isHidden = !revealed }
        }
    }

    /// Post-animation cleanup: hide if (still) collapsed per current prefs.
    func finishCollapse(revealedNow: Bool) {
        if hidesWhenCollapsed && !revealedNow { isHidden = true }
    }
}

// MARK: - Shortcuts pane

/// Top-anchored scroll content for the shortcuts list.
private final class FlippedContentView: NSView { override var isFlipped: Bool { true } }

/// One selectable "where does the icon go" card on the Thumbnails pane: a miniature
/// thumbnail preview illustrating the placement (a wallpaper swatch, a capsule standing in
/// for the name, a star standing in for the icon), its title beneath, and an accent ring
/// when chosen. Radio-group semantics live in the controller — exactly one card is selected.
private final class IconStyleCardView: NSView {
    let style: Prefs.ThumbnailIconStyle
    var onSelect: ((Prefs.ThumbnailIconStyle) -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    /// Mirrors the live names toggle so the mini name capsule appears exactly when a real
    /// name row would.
    var showsNameRow = true { didSet { if oldValue != showsNameRow { needsDisplay = true } } }

    private let title: String
    private static let cardSize = NSSize(width: 118, height: 64)
    private static let titleZone: CGFloat = 30

    init(style: Prefs.ThumbnailIconStyle, title: String) {
        self.style = style
        self.title = title
        super.init(frame: .zero)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.cardSize.width, height: Self.cardSize.height + Self.titleZone)
    }

    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onSelect?(style); return true }
    override func mouseDown(with event: NSEvent) { onSelect?(style) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0, y: Self.titleZone,
                         width: Self.cardSize.width, height: Self.cardSize.height)

        // Card ground; the selection ring doubles as the "radio" state.
        let card = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        card.fill()
        (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        card.lineWidth = isSelected ? 2 : 1
        card.stroke()

        // Mini wallpaper thumbnail, seated low so the label row has headroom above.
        let thumb = NSRect(x: box.midX - 33, y: box.minY + 9, width: 66, height: 30)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: thumb, xRadius: 5, yRadius: 5).addClip()
        NSGradient(starting: NSColor.systemIndigo.withAlphaComponent(0.75),
                   ending: NSColor.systemTeal.withAlphaComponent(0.75))?.draw(in: thumb, angle: 55)
        NSGraphicsContext.restoreGraphicsState()

        // The row above the thumbnail: name capsule and/or icon, per this card's style.
        let rowCenter = NSPoint(x: box.midX, y: thumb.maxY + 12)
        let ink = NSColor.labelColor.withAlphaComponent(0.55)
        switch style {
        case .beforeName:
            if showsNameRow, let star = Self.star(pointSize: 8, color: ink) {
                let total = star.size.width + 4 + 26
                drawStar(star, at: NSPoint(x: rowCenter.x - total / 2 + star.size.width / 2,
                                           y: rowCenter.y))
                drawCapsule(width: 26, center: NSPoint(x: rowCenter.x + total / 2 - 13,
                                                       y: rowCenter.y), color: ink)
            } else if let star = Self.star(pointSize: 8, color: ink) {
                drawStar(star, at: rowCenter)   // names off: the small icon stays small
            }
        case .largeAbove:
            if let star = Self.star(pointSize: 13, color: ink) { drawStar(star, at: rowCenter) }
        case .largeOver:
            if showsNameRow { drawCapsule(width: 30, center: rowCenter, color: ink) }
            if let star = Self.star(pointSize: 12, color: .white) {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                drawStar(star, at: NSPoint(x: thumb.midX, y: thumb.midY))
                NSGraphicsContext.restoreGraphicsState()
            }
        case .hidden:
            if showsNameRow { drawCapsule(width: 30, center: rowCenter, color: ink) }
        }

        // Title, centered under the card; up to two lines.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]).draw(with: NSRect(x: 0, y: Self.titleZone - 30, width: box.width, height: 28),
                options: [.usesLineFragmentOrigin])
    }

    private func drawStar(_ star: NSImage, at center: NSPoint) {
        star.draw(in: NSRect(x: center.x - star.size.width / 2,
                             y: center.y - star.size.height / 2,
                             width: star.size.width, height: star.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawCapsule(width: CGFloat, center: NSPoint, color: NSColor) {
        let rect = NSRect(x: center.x - width / 2, y: center.y - 2.25, width: width, height: 4.5)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2.25, yRadius: 2.25).fill()
    }

    /// The stand-in "workspace icon" glyph, flattened to a concrete color (symbol images
    /// only auto-tint inside cells; direct draws render them verbatim).
    private static func star(pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

extension SettingsController {

    /// The Shortcuts tab. Switching (Prev/Next Space, Switch-to-Space-N) binds to macOS's
    /// OWN Spaces shortcuts — editing a row rewrites the system symbolic hotkey, and external
    /// changes flow back in. The move-window rows are DERIVED (that switch chord + an extra
    /// modifier). App/Displays rows are ordinary app-owned chords. Each sub-tab's list lives
    /// in a fixed-height scroll so the window height stays sane.
    fileprivate func makeShortcutsPane() -> NSTabViewItem {
        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: 13)
            return label
        }

        func shortcutRow(_ action: HotkeyAction) -> NSView {
            let label = NSTextField(labelWithString: action.label)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let recorder = ShortcutRecorderView()
            recorder.spec = Prefs.hotkey(for: action)
            recorder.allowsBareShortcuts = (action == .holdSwitcher)
            if let suggestion = action.placeholderSuggestion { recorder.placeholder = suggestion }
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true

            let warning = NSTextField(wrappingLabelWithString: "")
            warning.font = .systemFont(ofSize: 10)
            warning.textColor = .systemOrange
            warning.isHidden = true
            warning.preferredMaxLayoutWidth = 480

            recorder.validate = { ConflictChecker.hotkeyConflicts(for: $0, excludingAction: action) }
            recorder.onChange = { [weak self] in
                Prefs.setHotkey($0, for: action)
                // Hold-to-show also has a recorder on the Switcher tab — keep it in step.
                if action == .holdSwitcher { self?.syncHoldSwitcherUI() }
            }
            recorder.onConflicts = { conflicts in
                warning.stringValue = conflicts.map { "⚠︎ \($0.description)" }.joined(separator: "  ")
                warning.isHidden = conflicts.isEmpty
            }

            let row = NSStackView(views: [label, recorder])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: 470).isActive = true
            let cell = NSStackView(views: [row, warning])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 2
            tabRecorders.append((action, recorder))
            return cell
        }

        /// One sub-tab: its rows in a scroll pinned to the tab item's view.
        func subTab(_ label: String, _ views: [NSView]) -> NSTabViewItem {
            let listStack = NSStackView(views: views)
            listStack.orientation = .vertical
            listStack.alignment = .leading
            listStack.spacing = 8
            listStack.translatesAutoresizingMaskIntoConstraints = false

            let doc = FlippedContentView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(listStack)

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.documentView = doc

            let container = NSView()   // frame-managed by the tab view
            container.addSubview(scroll)
            NSLayoutConstraint.activate([
                listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
                listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 2),
                listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = container
            return item
        }

        func titleLabel(_ text: String) -> NSTextField {
            let title = NSTextField(labelWithString: text)
            title.font = .systemFont(ofSize: 12)
            title.lineBreakMode = .byTruncatingTail
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return title
        }

        // A Switching row: editable native binding (Global Modifier off) or a read-only derived
        // "globalModifier + key" display (Global Modifier on) — toggled by refreshShortcutsPane.
        func switchingRow(_ id: Int, _ label: String) -> NSView {
            let recorder = ShortcutRecorderView()
            recorder.placeholder = "Record Shortcut"
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
            recorder.onChange = { spec in   // only fires while editable (Global Modifier off)
                let sc = spec.map {
                    SystemShortcuts.SpaceShortcut(keyCode: $0.keyCode,
                                                  flags: CGEventFlags(rawValue: UInt64($0.modifiers)))
                }
                SystemShortcuts.setBinding(id: id, sc)
                NativeShortcutsWatcher.shared.resync()   // our own write — don't re-report it
                NotificationCenter.default.post(name: .speedySpacesNativeShortcutsChanged, object: nil)
            }
            let row = NSStackView(views: [titleLabel(label), recorder])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: 470).isActive = true
            switchingRecorders.append((id, recorder))
            return row
        }

        // A Move row: read-only derived (native switch + extra) when Extra Modifier is on, or an
        // editable reprogrammable chord when it's off — toggled by refreshShortcutsPane.
        func moveRow(_ action: HotkeyAction) -> NSView {
            let recorder = ShortcutRecorderView()
            recorder.placeholder = "Record Shortcut"
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let warning = NSTextField(wrappingLabelWithString: "")
            warning.font = .systemFont(ofSize: 10)
            warning.textColor = .systemOrange
            warning.isHidden = true
            warning.preferredMaxLayoutWidth = 480
            recorder.validate = { ConflictChecker.hotkeyConflicts(for: $0, excludingAction: action) }
            recorder.onChange = { Prefs.setHotkey($0, for: action) }   // only fires while editable
            recorder.onConflicts = { conflicts in
                warning.stringValue = conflicts.map { "⚠︎ \($0.description)" }.joined(separator: "  ")
                warning.isHidden = conflicts.isEmpty
            }
            let row = NSStackView(views: [titleLabel(action.label), recorder])
            row.orientation = .horizontal
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: 470).isActive = true
            let cell = NSStackView(views: [row, warning])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 2
            moveRecorders.append((action, recorder))
            return cell
        }

        // A modifiers-only well (Caps-Lock mapping, Global Modifier, and the move extra modifier).
        func modifierWell(onSet: @escaping (UInt) -> Void) -> ShortcutRecorderView {
            let well = ShortcutRecorderView()
            well.capturesModifiersOnly = true
            well.rejectsRealKeys = true
            well.placeholder = "Record modifiers"
            well.onChange = { onSet($0?.modifiers ?? 0) }
            well.widthAnchor.constraint(equalToConstant: 110).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return well
        }

        // Hold-to-show switcher lives here, not in the App sub-tab.
        let holdRow = shortcutRow(.holdSwitcher)

        let intro = NSTextField(wrappingLabelWithString:
            "The Switching shortcuts below are macOS's own Spaces shortcuts — editing one changes "
            + "it system-wide (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control), "
            + "and changes made there appear here too.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 510

        // --- Global Modifier (governs the Switching rows) ------------------------
        let globalToggle = NSButton(checkboxWithTitle: "Use a Global Modifier:",
                                    target: self, action: #selector(toggleGlobalModifier(_:)))
        globalToggle.toolTip = "When on, every Switching shortcut is set to this modifier plus its "
            + "natural key (1–0 for the spaces, ←/→ for Previous/Next) and written to macOS's own "
            + "Spaces shortcuts. Turn it off to edit each switching shortcut individually."
        self.globalModifierToggle = globalToggle
        let globalWell = modifierWell { [weak self] mods in
            Prefs.globalModifier = mods
            if Prefs.globalModifierEnabled {
                SystemShortcuts.applyGlobalModifierToNative(mods)
                NativeShortcutsWatcher.shared.resync()
                NotificationCenter.default.post(name: .speedySpacesNativeShortcutsChanged, object: nil)
            }
            self?.refreshShortcutsPane()
        }
        self.globalModifierRecorder = globalWell
        let globalRow = NSStackView(views: [globalToggle, globalWell])
        globalRow.orientation = .horizontal
        globalRow.spacing = 8

        // --- Extra Modifier (governs the Move rows) ------------------------------
        let extraToggle = NSButton(checkboxWithTitle: "Use an Extra Global Modifier:",
                                   target: self, action: #selector(toggleMoveExtraModifier(_:)))
        extraToggle.toolTip = "When on, each Move & Follow shortcut is the matching switch shortcut "
            + "plus this modifier (change it and they all update). Turn it off to give each move its "
            + "own reprogrammable shortcut."
        self.moveExtraToggle = extraToggle
        let extraWell = modifierWell { [weak self] mods in
            Prefs.moveExtraModifier = mods
            self?.refreshShortcutsPane()
        }
        self.moveExtraRecorder = extraWell
        let extraRow = NSStackView(views: [extraToggle, extraWell])
        extraRow.orientation = .horizontal
        extraRow.spacing = 8

        // --- Screen Recording (governs whether the Move rows can work at all) ----
        // Moving a window to another workspace asks the window server to CARRY the window
        // through the workspace switch, and it only hands a window over to an app holding
        // Screen Recording. It refuses silently — the call reports success and the window
        // simply stays behind — so the state has to be surfaced rather than discovered.
        let permissionHeader = NSTextField(labelWithString: "Permission")
        permissionHeader.font = .boldSystemFont(ofSize: 13)

        let permissionStatus = NSTextField(labelWithString: "")
        permissionStatus.font = .systemFont(ofSize: 12)
        self.screenRecordingStatus = permissionStatus

        let permissionNote = NSTextField(wrappingLabelWithString:
            "Moving a window to another workspace asks macOS to carry the window along with the "
            + "workspace switch, which it only allows for an app with Screen Recording access. "
            + "SpeedySpaces never records or captures your screen — switching workspaces, the "
            + "switcher, and every other shortcut work without this. Without it, the move "
            + "shortcuts below do nothing.")
        permissionNote.textColor = .secondaryLabelColor
        permissionNote.font = .systemFont(ofSize: 11)
        permissionNote.preferredMaxLayoutWidth = 470

        let permissionButton = NSButton(title: "Open Screen Recording Settings",
                                        target: self, action: #selector(openScreenRecordingSettings(_:)))
        self.screenRecordingButton = permissionButton

        let permissionBox = NSStackView(views: [permissionHeader, permissionStatus,
                                                permissionNote, permissionButton])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .leading
        permissionBox.spacing = 4

        let permissionDivider = NSBox()
        permissionDivider.boxType = .separator
        permissionDivider.translatesAutoresizingMaskIntoConstraints = false
        permissionDivider.widthAnchor.constraint(equalToConstant: 470).isActive = true

        // The grant is picked up on relaunch, but the STATUS should not go stale while the
        // user is toggling it in System Settings with this window open.
        screenRecordingActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in self?.refreshScreenRecordingBanner()
        }

        let note = NSTextField(wrappingLabelWithString:
            "App and Displays shortcuts are optional — click a field and type a chord (⎋ cancels, "
            + "⌫ clears). Shortcuts for a specific space are set in that space's editor (pencil "
            + "icon in the menu). Bare F-keys require “Use F1, F2, etc. as standard function keys” "
            + "or holding fn.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 510

        // --- The app's own bindings, split into sub-tabs -------------------------
        let subTabs = NSTabView()
        subTabs.translatesAutoresizingMaskIntoConstraints = false
        subTabs.addTabViewItem(subTab("App", [
            shortcutRow(.openMenu),
            shortcutRow(.openMissionControl),
            shortcutRow(.openSettings),
            shortcutRow(.renameCurrentSpace),
        ]))
        subTabs.addTabViewItem(subTab("Switching Workspaces",
            [globalRow]
            + (1...12).map { switchingRow(SystemShortcuts.desktopBaseID + $0 - 1, "Switch to Space \($0)") }
            + [switchingRow(SystemShortcuts.moveRightID, "Next Space"),
               switchingRow(SystemShortcuts.moveLeftID, "Previous Space"),
               shortcutRow(.backAndForth)]))
        subTabs.addTabViewItem(subTab("Moving Windows",
            [permissionBox, permissionDivider, extraRow]
            + (1...12).map { moveRow(HotkeyAction(rawValue: "moveFollowToSpace\($0)")!) }
            + [moveRow(.moveFollowNext), moveRow(.moveFollowPrev)]))
        subTabs.addTabViewItem(subTab("Displays", [
            shortcutRow(.moveDisplayNext),
            shortcutRow(.moveDisplayPrev),
        ]))
        NSLayoutConstraint.activate([
            subTabs.widthAnchor.constraint(equalToConstant: 510),
            subTabs.heightAnchor.constraint(equalToConstant: 400),
        ])

        // Re-read the native rows + re-derive the move rows whenever the system shortcuts
        // change (our own edit above, or an external System Settings change via the watcher).
        nativeShortcutsObserver = NotificationCenter.default.addObserver(
            forName: .speedySpacesNativeShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshShortcutsPane()
        }
        refreshShortcutsPane()

        return makePane(label: "Shortcuts", symbol: "keyboard",
                        views: [intro, holdRow, subTabs, note])
    }

    /// A displayable spec for a symbolic-hotkey id's current binding (nil if it's disabled).
    static func nativeSpec(id: Int) -> ShortcutSpec? {
        guard let sc = SystemShortcuts.systemBinding(id: id) else { return nil }
        return ShortcutSpec(keyCode: sc.keyCode,
                            modifiers: ShortcutSpec.sanitizeRaw(UInt(sc.flags.rawValue)))
    }

    /// Converge every Switching / Moving row + the two wells on the current toggle state — after a
    /// toggle flip, a well edit, our own native edit, or an external System Settings change (watcher).
    /// Global Modifier on → switching rows show the derived "globalModifier + key" and go read-only;
    /// off → they're editable native bindings. Extra Modifier on → move rows show the derived
    /// "native switch + extra" and go read-only; off → they're editable reprogrammable chords.
    fileprivate func refreshShortcutsPane() {
        let globalOn = Prefs.globalModifierEnabled
        globalModifierToggle?.state = globalOn ? .on : .off
        globalModifierRecorder?.isEnabled = globalOn
        globalModifierRecorder?.spec = Prefs.globalModifier == 0 ? nil
            : ShortcutSpec(keyCode: ShortcutSpec.noKeyCode, modifiers: Prefs.globalModifier)
        for (id, recorder) in switchingRecorders {
            recorder.isEnabled = !globalOn
            recorder.spec = globalOn
                ? SystemShortcuts.globalSwitchSpec(id: id, modifiers: Prefs.globalModifier)
                : Self.nativeSpec(id: id)
        }

        let extraOn = Prefs.moveExtraModifierEnabled
        moveExtraToggle?.state = extraOn ? .on : .off
        moveExtraRecorder?.isEnabled = extraOn
        moveExtraRecorder?.spec = Prefs.moveExtraModifier == 0 ? nil
            : ShortcutSpec(keyCode: ShortcutSpec.noKeyCode, modifiers: Prefs.moveExtraModifier)
        for (action, recorder) in moveRecorders {
            recorder.isEnabled = !extraOn
            recorder.spec = extraOn ? HotkeyManager.moveChord(for: action)
                                    : Prefs.hotkey(for: action)
        }
        updateHoldStatus()
    }

    @objc fileprivate func toggleGlobalModifier(_ sender: NSButton) {
        Prefs.globalModifierEnabled = (sender.state == .on)
        // Turning it on assigns globalModifier + key to every switching shortcut (writes native).
        if Prefs.globalModifierEnabled {
            SystemShortcuts.applyGlobalModifierToNative(Prefs.globalModifier)
            NativeShortcutsWatcher.shared.resync()
            NotificationCenter.default.post(name: .speedySpacesNativeShortcutsChanged, object: nil)
        }
        refreshShortcutsPane()
    }

    @objc fileprivate func toggleMoveExtraModifier(_ sender: NSButton) {
        Prefs.moveExtraModifierEnabled = (sender.state == .on)   // setter reloads the hotkeys
        refreshShortcutsPane()
    }

    /// The hold-to-show chord is editable in two places (Switcher tab, and the App
    /// sub-tab's top row) — converge both on the stored pref.
    fileprivate func syncHoldSwitcherUI() {
        let stored = Prefs.hotkey(for: .holdSwitcher)
        switcherHoldRecorder?.spec = stored
        switcherHoldRecorder?.placeholder = "Record Shortcut"
        for (action, recorder) in tabRecorders where action == .holdSwitcher {
            recorder.spec = stored
            recorder.placeholder = "Record Shortcut"
        }
        updateHoldStatus()
    }

    @objc fileprivate func toggleHotkeyWrap(_ sender: NSButton) {
        Prefs.hotkeyWrapAround = (sender.state == .on)
    }

    /// The mapping well shows the current caps mapping and only takes input while the
    /// checkbox is on.
}

