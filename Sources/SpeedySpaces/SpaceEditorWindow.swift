// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// A small AppKit panel for editing a space's name and icon. For SF Symbols it shows a
/// searchable grid picker; for emoji it offers the system Character palette. A live
/// preview reflects the current choice. Pure AppKit so it builds without Xcode.
final class SpaceEditorController: NSWindowController, NSTextFieldDelegate {
    private let uuid: String
    private let displayName: String
    private var metadata: SpaceMetadata
    private let onSave: (SpaceMetadata) -> Void

    private let nameField = NSTextField()
    private let typeControl = NSSegmentedControl(labels: ["None", "SF Symbol", "Emoji"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let valueField = NSTextField()
    private let valueLabel = NSTextField(labelWithString: "Symbol name:")
    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    private let symbolPicker = SFSymbolPicker()
    private let emojiButton = NSButton(title: "Choose Emoji…", target: nil, action: nil)
    private let shortcutRecorder = ShortcutRecorderView()
    private let shortcutWarning = NSTextField(wrappingLabelWithString: "")

    init(uuid: String, spaceTitle: String, metadata: SpaceMetadata, onSave: @escaping (SpaceMetadata) -> Void) {
        self.uuid = uuid
        self.displayName = spaceTitle
        self.metadata = metadata
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Edit “\(spaceTitle)”"
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameField.stringValue = metadata.name ?? ""
        nameField.placeholderString = displayName
        nameField.delegate = self

        typeControl.selectedSegment = {
            switch metadata.iconType {
            case .none: return 0
            case .sfsymbol: return 1
            case .emoji: return 2
            }
        }()
        typeControl.target = self
        typeControl.action = #selector(typeChanged)

        valueField.stringValue = metadata.iconValue ?? ""
        valueField.delegate = self

        previewView.imageScaling = .scaleProportionallyUpOrDown

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        symbolPicker.translatesAutoresizingMaskIntoConstraints = false
        symbolPicker.onPick = { [weak self] name in
            self?.valueField.stringValue = name
            self?.refreshPreview()
        }

        emojiButton.target = self
        emojiButton.action = #selector(chooseEmoji)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 8

        // Global hotkey that jumps straight to this space (stored per-uuid, so it
        // survives reordering). Applied on Save like the rest of the metadata.
        shortcutRecorder.spec = metadata.shortcut
        shortcutRecorder.validate = { [uuid] in
            ConflictChecker.hotkeyConflicts(for: $0, excludingUUID: uuid)
        }
        shortcutRecorder.onConflicts = { [shortcutWarning] conflicts in
            shortcutWarning.stringValue = conflicts.map { "⚠︎ \($0.description)" }.joined(separator: "  ")
            shortcutWarning.isHidden = conflicts.isEmpty
        }
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        shortcutRecorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
        shortcutWarning.font = .systemFont(ofSize: 10)
        shortcutWarning.textColor = .systemOrange
        shortcutWarning.isHidden = true
        shortcutWarning.preferredMaxLayoutWidth = 320

        let form = NSStackView(views: [
            row(nameLabel, nameField),
            row(NSTextField(labelWithString: "Icon:"), typeControl),
            row(valueLabel, valueField),
            row(NSTextField(labelWithString: "Preview:"), previewView),
            row(NSTextField(labelWithString: "Shortcut:"), shortcutRecorder),
            shortcutWarning,
            emojiButton,
            symbolPicker,
            statusLabel,
            buttons
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            previewView.widthAnchor.constraint(equalToConstant: 22),
            previewView.heightAnchor.constraint(equalToConstant: 22),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            symbolPicker.widthAnchor.constraint(equalTo: form.widthAnchor),
            symbolPicker.heightAnchor.constraint(equalToConstant: 200),
        ])

        updateForType()
    }

    private func row(_ label: NSView, _ field: NSView) -> NSStackView {
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        if let label = label as? NSTextField {
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            label.alignment = .right
        }
        return stack
    }

    @objc private func typeChanged() { updateForType() }

    private func updateForType() {
        let isSymbol = typeControl.selectedSegment == 1
        let isEmoji = typeControl.selectedSegment == 2

        symbolPicker.isHidden = !isSymbol
        emojiButton.isHidden = !isEmoji
        valueField.isEnabled = isSymbol || isEmoji

        switch typeControl.selectedSegment {
        case 1:
            valueLabel.stringValue = "Symbol name:"
            valueField.placeholderString = "e.g. star.fill"
            symbolPicker.setSelected(valueField.stringValue.isEmpty ? nil : valueField.stringValue)
        case 2:
            valueLabel.stringValue = "Emoji:"
            valueField.placeholderString = "e.g. 🚀"
        default:
            valueLabel.stringValue = "—"
        }
        refreshPreview()
    }

    @objc private func chooseEmoji() {
        window?.makeFirstResponder(valueField)
        NSApp.orderFrontCharacterPalette(valueField)
    }

    func controlTextDidChange(_ obj: Notification) {
        if typeControl.selectedSegment == 1 {
            symbolPicker.setSelected(valueField.stringValue.isEmpty ? nil : valueField.stringValue)
        }
        refreshPreview()
    }

    private func currentDraft() -> SpaceMetadata {
        var draft = SpaceMetadata()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.name = name.isEmpty ? nil : name
        switch typeControl.selectedSegment {
        case 1: draft.iconType = .sfsymbol
        case 2: draft.iconType = .emoji
        default: draft.iconType = .none
        }
        let value = valueField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.iconValue = value.isEmpty ? nil : value
        draft.shortcut = shortcutRecorder.spec
        return draft
    }

    private func refreshPreview() {
        let draft = currentDraft()
        previewView.image = IconRendering.image(for: draft, pointSize: 18)
        if draft.iconType == .sfsymbol, let v = draft.iconValue, !IconRendering.isValidSymbol(v) {
            statusLabel.stringValue = "⚠︎ No SF Symbol named “\(v)”."
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func save() {
        onSave(currentDraft())
        close()
    }

    @objc private func cancel() { close() }

    /// `screen` places the editor on a specific display (the one whose label/title was
    /// clicked) — a window ordered onto that display lands on its current workspace.
    /// Without it the window centers on the default (focused) screen.
    func present(on screen: NSScreen? = nil) {
        if let screen, let window {
            let vf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                          y: vf.midY - size.height / 2))
        } else {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
