import AppKit

/// A small borderless floating panel that behaves like a native tooltip but can show an icon
/// alongside the text — used by `MenuBarStripView` to reveal a space's name + icon on hover.
/// (AppKit's built-in tooltips are text-only.) It never activates the app or intercepts the
/// mouse (`ignoresMouseEvents`), so hovering and clicking the strip behave exactly as before.
final class MenuBarTooltip {
    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    private enum M {
        static let hPad: CGFloat = 7
        static let vPad: CGFloat = 4
        static let icon: CGFloat = 14
        static let gap: CGFloat = 5
        static let corner: CGFloat = 6
        static let belowBar: CGFloat = 3        // gap between the menu bar and the tooltip
        static let maxTextWidth: CGFloat = 260
        static let textInset: CGFloat = 4       // slack for NSTextField's internal text margin
        static let font = NSFont.systemFont(ofSize: 12)
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 24, height: 20),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Follow the user across spaces / into full-screen apps rather than vanishing.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // A frosted tooltip-material capsule with a hairline border, matching native tooltips.
        effect.material = .toolTip
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = M.corner
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        effect.addSubview(imageView)

        label.font = M.font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBezeled = false
        effect.addSubview(label)
    }

    /// Show the tooltip for `name`/`icon`, positioned just below `anchor` (a segment rect in
    /// screen coordinates), horizontally centered on it and clamped to the screen.
    func show(name: String?, icon: NSImage?, below anchor: NSRect) {
        let text = name ?? ""
        let hasText = !text.isEmpty
        let hasIcon = icon != nil
        guard hasText || hasIcon else { hide(); return }

        // Icon: tint template symbols to the label color; leave color/emoji images untinted.
        imageView.isHidden = !hasIcon
        if let icon {
            imageView.image = icon
            imageView.contentTintColor = icon.isTemplate ? .labelColor : nil
        }

        // Text
        label.isHidden = !hasText
        label.stringValue = text
        // Measure the string directly. (The field's own intrinsicContentSize is shortened by its
        // truncating line-break mode, and the bare NSString width omits the field's internal text
        // inset — either alone clips the tail, e.g. "Game of Thron…".) Add a small slack for that
        // inset; any overshoot is hidden inside the capsule padding. Truncation still applies once
        // the name is clamped to `maxTextWidth`.
        let measured = hasText ? (text as NSString).size(withAttributes: [.font: M.font]) : .zero
        let textW = hasText ? ceil(min(measured.width, M.maxTextWidth)) + M.textInset : 0
        let textH = ceil(measured.height)

        // Lay the icon + label out left-to-right and size the panel to fit.
        let contentH = max(hasIcon ? M.icon : 0, hasText ? textH : 0)
        let h = contentH + M.vPad * 2
        var w = M.hPad
        var cx = M.hPad
        if hasIcon {
            imageView.frame = NSRect(x: cx, y: (h - M.icon) / 2, width: M.icon, height: M.icon)
            cx += M.icon + (hasText ? M.gap : 0)
            w += M.icon + (hasText ? M.gap : 0)
        }
        if hasText {
            label.frame = NSRect(x: cx, y: (h - textH) / 2, width: textW, height: textH)
            w += textW
        }
        w += M.hPad

        // Position below the menu bar, centered on the anchor, clamped to the visible screen.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var x = anchor.midX - w / 2
        var y = anchor.minY - M.belowBar - h
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 2), vf.maxX - w - 2)
            if y < vf.minY { y = anchor.maxY + M.belowBar }   // fall back to above (unlikely at the top of the screen)
        }
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFront(nil)
    }

    func hide() { panel.orderOut(nil) }
}
