import AppKit

/// A custom menu-item view for a single Space row: the space's icon in a left
/// gutter, its name (bold when current), and a pencil affordance on the right
/// that opens the editor.
///
/// Native `NSMenuItem`s can't show an icon in the state column *and* paint a
/// persistent background behind the current (non-hovered) row, so the space
/// rows are drawn here instead. The highlight is an `NSVisualEffectView` with
/// the `.selection` material — the same vibrancy pill the system draws for
/// native menu items — emphasized for the hovered row, unemphasized for the
/// current space.
final class SpaceMenuRowView: NSView {
    private let icon: NSImage?
    private let titleText: String
    private let isCurrent: Bool
    /// Formatted shortcut chord shown right-aligned before the pencil (e.g. "⌥3").
    private let hint: String?
    private let onSelect: () -> Void
    private let onEdit: () -> Void

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let highlight = NSVisualEffectView()
    private let content = ContentView()

    private enum Metric {
        static let outerInset: CGFloat = 5   // gap between the view edge and the highlight rect
        static let vInset: CGFloat = 1       // vertical inset of the highlight rect
        static let contentPad: CGFloat = 8   // padding inside the highlight (left/right)
        static let gutter: CGFloat = 20      // icon column width
        static let gap: CGFloat = 6          // gap between columns
        static let pencil: CGFloat = 14      // pencil glyph box
        static let height: CGFloat = 22
        static let corner: CGFloat = 6
        static let font: CGFloat = 13
        static let maxText: CGFloat = 175    // same cap as the Mission Control overlay labels
    }

    init(icon: NSImage?, title: String, isCurrent: Bool, width: CGFloat,
         hint: String? = nil,
         onSelect: @escaping () -> Void, onEdit: @escaping () -> Void) {
        self.icon = icon
        self.titleText = title
        self.isCurrent = isCurrent
        self.hint = hint
        self.onSelect = onSelect
        self.onEdit = onEdit
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metric.height))
        // `width` is only a minimum; the menu's real width is driven by its widest item
        // (often a footer row). Stretch to fill it so labels, highlight, and the pencil
        // span the full menu instead of stopping short.
        autoresizingMask = [.width]

        highlight.frame = highlightRect
        highlight.autoresizingMask = [.width, .height]
        highlight.material = .selection
        highlight.blendingMode = .behindWindow
        highlight.state = .active
        highlight.maskImage = SpaceMenuRowView.highlightMask
        highlight.isEmphasized = false
        highlight.isHidden = !isCurrent
        addSubview(highlight)

        // A view's own draw(_:) renders *below* its subviews, so the icon/text/pencil
        // live in a content subview stacked above the highlight.
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        content.row = self
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Uniform row width so every row's highlight spans the same distance. Measured with
    /// the bold font (the widest case) so a bolded current row never clips. Text wider
    /// than `Metric.maxText` doesn't widen the menu — it truncates with an ellipsis.
    /// The widest shortcut hint (plus its gap) is added so hinted rows don't squeeze titles.
    static func preferredWidth(forTitles titles: [String], hints: [String?] = []) -> CGFloat {
        let font = NSFont.boldSystemFont(ofSize: Metric.font)
        let maxText = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let maxHint = hints.compactMap { $0 }
            .map { ($0 as NSString).size(withAttributes: [.font: hintFont]).width }.max() ?? 0
        let hintExtra = maxHint > 0 ? ceil(maxHint) + Metric.gap : 0
        let w = Metric.outerInset * 2 + Metric.contentPad * 2
              + Metric.gutter + Metric.gap * 2 + min(ceil(maxText), Metric.maxText)
              + hintExtra + Metric.pencil
        return max(200, w)
    }

    override var isFlipped: Bool { true }

    // MARK: - Column frames

    private var highlightRect: NSRect { bounds.insetBy(dx: Metric.outerInset, dy: Metric.vInset) }
    private var iconRect: NSRect {
        NSRect(x: highlightRect.minX + Metric.contentPad, y: 0, width: Metric.gutter, height: bounds.height)
    }
    private var pencilRect: NSRect {
        NSRect(x: highlightRect.maxX - Metric.contentPad - Metric.pencil, y: 0,
               width: Metric.pencil, height: bounds.height)
    }
    /// Hint column width for this row (0 when there is no hint).
    private var hintWidth: CGFloat {
        guard let hint else { return 0 }
        return ceil((hint as NSString).size(withAttributes: [.font: Self.hintFont]).width)
    }
    private var hintRect: NSRect {
        NSRect(x: pencilRect.minX - Metric.gap - hintWidth, y: 0,
               width: hintWidth, height: bounds.height)
    }
    private var textRect: NSRect {
        let x = iconRect.maxX + Metric.gap
        let end = hint == nil ? pencilRect.minX : hintRect.minX
        let w = end - Metric.gap - x
        return NSRect(x: x, y: 0, width: max(0, w), height: bounds.height)
    }

    static let hintFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // MARK: - Drawing

    /// Resizable rounded-rect mask giving the highlight its native pill shape.
    private static let highlightMask: NSImage = {
        let corner = Metric.corner
        let edge = corner * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        img.resizingMode = .stretch
        return img
    }()

    /// Renders into `content`'s context, which shares the row's origin and flip.
    private func drawContent() {
        let fg: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor

        if let icon = icon {
            let img = tinted(icon, fg)
            let maxSide: CGFloat = 16
            let scale = min(1, maxSide / max(img.size.width, img.size.height, 1))
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            img.draw(in: NSRect(x: iconRect.midX - size.width / 2,
                                y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height))
        }

        let font = isCurrent ? NSFont.boldSystemFont(ofSize: Metric.font)
                             : NSFont.systemFont(ofSize: Metric.font)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
        let textHeight = (titleText as NSString).size(withAttributes: [.font: font]).height
        (titleText as NSString).draw(
            in: NSRect(x: textRect.minX, y: (bounds.height - textHeight) / 2,
                       width: textRect.width, height: textHeight),
            withAttributes: attrs)

        if let hint {
            let hintColor: NSColor = isHovered ? fg : .secondaryLabelColor
            let hintAttrs: [NSAttributedString.Key: Any] = [.font: Self.hintFont,
                                                            .foregroundColor: hintColor]
            let h = (hint as NSString).size(withAttributes: hintAttrs).height
            (hint as NSString).draw(
                in: NSRect(x: hintRect.minX, y: (bounds.height - h) / 2,
                           width: hintRect.width, height: h),
                withAttributes: hintAttrs)
        }

        if let pencil = SpaceMenuRowView.pencilImage {
            let color: NSColor = isHovered ? fg : .secondaryLabelColor
            let img = tinted(pencil, color)
            img.draw(in: NSRect(x: pencilRect.midX - img.size.width / 2,
                                y: bounds.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }

    /// Hosts the row's drawing above the highlight; input events fall through to the row.
    private final class ContentView: NSView {
        weak var row: SpaceMenuRowView?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { row?.drawContent() }
    }

    /// Tint a template image to `color`; color (emoji) images are returned unchanged.
    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let out = image.copy() as! NSImage
        out.lockFocus()
        color.set()
        NSRect(origin: .zero, size: out.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    private static let pencilImage: NSImage? = {
        let img = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit")
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let out = img?.withSymbolConfiguration(config) ?? img
        out?.isTemplate = true
        return out
    }()

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        // `.inVisibleRect` keeps the tracking region matched to the view as it stretches
        // to the menu width, so hover stays correct without recomputing the rect.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { handleEnter() }
    override func mouseExited(with event: NSEvent) { handleExit() }

    /// The row currently showing the emphasized hover pill, shared across all rows in the menu.
    /// NSMenu's tracking loop frequently drops a row's `mouseExited`, so we can't rely on paired
    /// enter/exit per row. Instead, entering any row clears whichever row was hovered before —
    /// keeping at most one emphasized pill even when exits go missing.
    private static weak var hoveredRow: SpaceMenuRowView?

    private func handleEnter() {
        if let prev = SpaceMenuRowView.hoveredRow, prev !== self { prev.setHovered(false) }
        SpaceMenuRowView.hoveredRow = self
        setHovered(true)
    }

    private func handleExit() {
        setHovered(false)
        if SpaceMenuRowView.hoveredRow === self { SpaceMenuRowView.hoveredRow = nil }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        highlight.isEmphasized = hovered
        highlight.isHidden = !(hovered || isCurrent)
        content.needsDisplay = true
    }

    /// Keyboard-driven selection highlight, driven by the jump field's arrow navigation.
    /// Uses the same emphasized pill as hover so the selected row reads identically.
    func setKeyboardSelected(_ selected: Bool) { setHovered(selected) }

    // MARK: - Clicks

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let editHit = pencilRect.insetBy(dx: -4, dy: -4).contains(point)
        // Close the menu first, then act on the next runloop turn so the switch keystrokes
        // (or the editor window) land after the menu's tracking loop has fully torn down.
        enclosingMenuItem?.menu?.cancelTracking()
        let action = editHit ? onEdit : onSelect
        DispatchQueue.main.async(execute: action)
    }

    // MARK: - Self-tests

    /// A dropped `mouseExited` (common inside NSMenu's tracking loop) must not leave two rows
    /// highlighted: entering a second row has to clear the first. Verifies the single-hover
    /// invariant enforced by `handleEnter`/`handleExit`.
    static func selfChecks(_ check: SelfTest.Check) {
        _ = NSApplication.shared   // ensure AppKit is initialized before building views
        func makeRow() -> SpaceMenuRowView {
            SpaceMenuRowView(icon: nil, title: "Row", isCurrent: false, width: 200, onSelect: {}, onEdit: {})
        }
        let a = makeRow(), b = makeRow()
        a.handleEnter()
        check(a.isHovered && !b.isHovered, "menu hover: first row highlights on enter")
        b.handleEnter()   // simulate a dropped exit on `a`: enter `b` with no mouseExited for `a`
        check(b.isHovered, "menu hover: second row highlights on enter")
        check(!a.isHovered, "menu hover: entering a second row clears the first (dropped-exit safe)")
        b.handleExit()
        check(!b.isHovered, "menu hover: exit clears the row")

        let narrow = preferredWidth(forTitles: ["A"])
        let wide = preferredWidth(forTitles: [String(repeating: "W", count: 20)])
        check(wide > narrow, "preferredWidth: longer titles widen the menu")
        check(narrow >= 200, "preferredWidth: sane minimum")
        check(preferredWidth(forTitles: [String(repeating: "W", count: 20)], hints: ["⌃⌥⇧1"]) > wide,
              "preferredWidth: shortcut hint adds width (above the 200 pt floor)")
        check(preferredWidth(forTitles: [String(repeating: "W", count: 200)])
                == preferredWidth(forTitles: [String(repeating: "W", count: 300)]),
              "preferredWidth: over-long titles cap (ellipsis, not a wider menu)")
    }
}
