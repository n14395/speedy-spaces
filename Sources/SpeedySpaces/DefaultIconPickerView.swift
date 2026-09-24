// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Compact chooser for the workspace list's default icon, hosted in an NSPopover from
/// Settings. A trimmed echo of SpaceEditorController: SF Symbol / Emoji segmented
/// control, a value field with live preview, and the symbol grid or the system emoji
/// palette. Valid choices write Prefs.workspaceListDefaultIcon immediately and call
/// onChange; there is no separate save step (the popover just closes).
final class DefaultIconPickerView: NSView, NSTextFieldDelegate {
    var onChange: ((SpaceMetadata) -> Void)?

    private let typeControl = NSSegmentedControl(labels: ["SF Symbol", "Emoji"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let valueField = NSTextField()
    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let symbolPicker = SFSymbolPicker()
    private let emojiButton = NSButton(title: "Choose Emoji…", target: nil, action: nil)

    init(current: SpaceMetadata) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        typeControl.selectedSegment = (current.iconType == .emoji) ? 1 : 0
        valueField.stringValue = current.iconValue ?? ""
        build()
        updateForType()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func build() {
        typeControl.target = self
        typeControl.action = #selector(typeChanged)
        valueField.delegate = self
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.image = IconRendering.image(for: currentDraft(), pointSize: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        symbolPicker.translatesAutoresizingMaskIntoConstraints = false
        symbolPicker.onPick = { [weak self] name in
            self?.valueField.stringValue = name
            self?.valueChanged()
        }
        emojiButton.target = self
        emojiButton.action = #selector(chooseEmoji)

        let valueRow = NSStackView(views: [valueField, previewView])
        valueRow.orientation = .horizontal
        valueRow.spacing = 8

        let stack = NSStackView(views: [typeControl, valueRow, emojiButton, symbolPicker, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            valueField.widthAnchor.constraint(equalToConstant: 250),
            previewView.widthAnchor.constraint(equalToConstant: 22),
            previewView.heightAnchor.constraint(equalToConstant: 22),
            symbolPicker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            symbolPicker.heightAnchor.constraint(equalToConstant: 190),
        ])
    }

    @objc private func typeChanged() {
        updateForType()
        valueChanged()
    }

    private func updateForType() {
        let isSymbol = typeControl.selectedSegment == 0
        symbolPicker.isHidden = !isSymbol
        emojiButton.isHidden = isSymbol
        valueField.placeholderString = isSymbol ? "e.g. star.fill" : "e.g. 🚀"
        if isSymbol {
            symbolPicker.setSelected(valueField.stringValue.isEmpty ? nil : valueField.stringValue)
        }
    }

    @objc private func chooseEmoji() {
        window?.makeFirstResponder(valueField)
        NSApp.orderFrontCharacterPalette(valueField)
    }

    func controlTextDidChange(_ obj: Notification) {
        if typeControl.selectedSegment == 0 {
            symbolPicker.setSelected(valueField.stringValue.isEmpty ? nil : valueField.stringValue)
        }
        valueChanged()
    }

    private func currentDraft() -> SpaceMetadata {
        var draft = SpaceMetadata()
        draft.iconType = typeControl.selectedSegment == 0 ? .sfsymbol : .emoji
        let value = valueField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.iconValue = value.isEmpty ? nil : value
        return draft
    }

    /// Preview every keystroke; persist only valid drafts (symbol resolves / emoji
    /// non-empty), surfacing symbol typos exactly like the space editor does.
    private func valueChanged() {
        let draft = currentDraft()
        previewView.image = IconRendering.image(for: draft, pointSize: 18)
        let valid: Bool
        if draft.iconType == .sfsymbol {
            let name = draft.iconValue ?? ""
            valid = IconRendering.isValidSymbol(name)
            statusLabel.stringValue = (valid || name.isEmpty) ? "" : "⚠︎ No SF Symbol named “\(name)”."
        } else {
            valid = !(draft.iconValue?.isEmpty ?? true)
            statusLabel.stringValue = ""
        }
        guard valid else { return }
        Prefs.workspaceListDefaultIcon = draft
        onChange?(draft)
    }
}
