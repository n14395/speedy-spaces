import AppKit

/// Renders a space's assigned icon (SF Symbol or emoji) to an NSImage for use
/// in menu items and the status-bar button.
enum IconRendering {
    /// Returns an icon image for the given metadata, or nil if none is set / invalid.
    static func image(for metadata: SpaceMetadata, pointSize: CGFloat = 15) -> NSImage? {
        switch metadata.iconType {
        case .none:
            return nil
        case .sfsymbol:
            guard let name = metadata.iconValue,
                  let image = NSImage(systemSymbolName: name, accessibilityDescription: metadata.name)
            else { return nil }
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            return configured
        case .emoji:
            guard let emoji = metadata.iconValue, !emoji.isEmpty else { return nil }
            return emojiImage(emoji, pointSize: pointSize)
        }
    }

    /// Validates that an SF Symbol name resolves on this system.
    static func isValidSymbol(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func selfChecks(_ check: SelfTest.Check) {
        // OS-dependent smoke checks: same inputs are deterministic on a given macOS.
        check(isValidSymbol("star.fill"), "icons: known SF Symbol validates")
        check(!isValidSymbol("zzz.not.a.symbol.qq"), "icons: garbage symbol name rejected")
        check(!isValidSymbol(""), "icons: empty symbol name rejected")
        check(image(for: .empty) == nil, "icons: no icon set -> nil image")
        check(image(for: SpaceMetadata(name: nil, iconType: .sfsymbol, iconValue: "star.fill")) != nil,
              "icons: SF Symbol renders")
        check(image(for: SpaceMetadata(name: nil, iconType: .sfsymbol, iconValue: "zzz.not.a.symbol.qq")) == nil,
              "icons: invalid SF Symbol -> nil")
        let emoji = image(for: SpaceMetadata(name: nil, iconType: .emoji, iconValue: "🚀"))
        check(emoji != nil && emoji?.isTemplate == false, "icons: emoji renders in color")
        check(image(for: SpaceMetadata(name: nil, iconType: .emoji, iconValue: "")) == nil,
              "icons: empty emoji -> nil")
    }

    private static func emojiImage(_ emoji: String, pointSize: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: pointSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (emoji as NSString).size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        image.lockFocus()
        (emoji as NSString).draw(at: .zero, withAttributes: attrs)
        image.unlockFocus()
        image.isTemplate = false // keep emoji color
        return image
    }
}
