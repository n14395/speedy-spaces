import AppKit

/// The menubar status-item content: a horizontal strip of segments drawn to match the menu bar's
/// appearance, with per-segment click routing.
///
/// Composition (driven by Prefs, configured via `update`):
///  • switcher off → a single segment: the current space's icon and/or name (or a grid icon if
///    both are off) that opens the menu on click.
///  • switcher on  → one numbered square per space on the focused display; the current space's
///    square is replaced by its icon and/or name when those are enabled, otherwise a highlighted
///    number.
///
/// Click routing (per the agreed interaction): a left-click on a *non-current* square switches to
/// that space; anything else (left-click on the current segment, or any right/control-click) opens
/// the menu.
final class MenuBarStripView: NSView {
    /// Left-click on a non-current space's square. Argument is the space uuid.
    var onSelect: ((String) -> Void)?
    /// Open the full menu (right-click, or left-click on the current segment / fallback icon).
    var onOpenMenu: (() -> Void)?
    private var pieces: [Piece] = []
    private var totalWidth: CGFloat = 22

    private enum M {
        static let square: CGFloat = 15
        static let squareCorner: CGFloat = 3.5
        static let gap: CGFloat = 5
        static let hPad: CGFloat = 4
        static let iconSide: CGFloat = 15
        static let iconNameGap: CGFloat = 4
        static let numberFont: CGFloat = 10.5
        static let nameFont: CGFloat = 13
        static let maxNameWidth: CGFloat = 220
        static let tipShowDelay: TimeInterval = 0.0    // 0 = show immediately on hover
        static let tipHideGrace: TimeInterval = 0.08   // bridges the untracked inter-segment gaps
    }

    /// Numbered-square metrics for a requested side length: the side clamped to the
    /// supported range, with corner radius and digit font scaled proportionally from
    /// the 15 pt baseline (`M.square`/`M.squareCorner`/`M.numberFont`).
    static func numberMetrics(side raw: CGFloat) -> (side: CGFloat, corner: CGFloat, font: CGFloat) {
        let side = min(max(raw, 12), 22)
        return (side, M.squareCorner * side / M.square, M.numberFont * side / M.square)
    }
    private var numberM: (side: CGFloat, corner: CGFloat, font: CGFloat) {
        Self.numberMetrics(side: Prefs.menuBarSwitcherSquareSize)
    }

    /// Fallback image for icon tiles whose space has no custom icon (icons style only).
    /// Refreshed on every update() from Prefs.workspaceListDefaultIcon.
    private var defaultIconImage: NSImage?

    /// Placeholder for the current-space segment when the settings say icon-only but
    /// the space has no icon — without it the segment would render empty.
    static let placeholderIcon: NSImage? = {
        guard let img = NSImage(systemSymbolName: "rectangle.stack.fill",
                                accessibilityDescription: "Workspace") else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let configured = img.withSymbolConfiguration(config) ?? img
        configured.isTemplate = true
        return configured
    }()


    /// Glyph colour on the active square's labelColor fill: the appearance's opposite
    /// extreme, so a dark bar gets black-on-white and a light bar white-on-black. The
    /// active square inverts the inactive look (BG↔FG) instead of using the accent
    /// colour, which vanished against wallpapers of the accent hue.
    private var invertedGlyphColor: NSColor {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    }

    /// Which treatment a piece wears. Pure — verifiable in selfChecks. The flipped
    /// (BG↔FG) look normally marks the current space; "Invert Colours" (offered only
    /// while backgrounds are on) swaps it onto the other spaces, leaving the current
    /// one with the grey look. With backgrounds off the current space keeps the
    /// flipped fill and the rest stay plain (invert is ignored).
    enum PieceLook { case flipped, grey, plain }
    static func pieceLook(current: Bool, background: Bool, inverted: Bool) -> PieceLook {
        let flippedIsCurrent = !(background && inverted)
        if current == flippedIsCurrent { return .flipped }
        return background ? .grey : .plain
    }
    private func look(current: Bool) -> PieceLook {
        Self.pieceLook(current: current, background: Prefs.menuBarSwitcherGreyBackground,
                       inverted: Prefs.menuBarSwitcherInvertColours)
    }
    private func fill(for look: PieceLook) -> NSColor? {
        switch look {
        case .flipped: return .labelColor
        case .grey: return NSColor.labelColor.withAlphaComponent(0.14)
        case .plain: return nil
        }
    }
    private func glyph(for look: PieceLook) -> NSColor {
        look == .flipped ? invertedGlyphColor : .labelColor
    }

    /// Which part of a segment reveals a hover tooltip (the space's name + icon).
    ///  • `.full` — the whole segment: numbered squares (current or not) and the grid fallback.
    ///  • `.icon` — just the icon glyph: an icon-only current space whose name is hidden.
    ///  • `.none` — no tooltip: a drawn name already identifies the space.
    private enum TooltipRegion: Equatable { case none, full, icon }

    private struct Piece {
        enum Kind {
            case number(Int, current: Bool)
            case iconTile(icon: NSImage?, current: Bool)
            case iconName(icon: NSImage?, name: String?)
            case grid
        }
        let kind: Kind
        var x: CGFloat = 0
        var width: CGFloat = 0
        let uuid: String?
        let isCurrent: Bool
        /// First piece of a new display's group (all-displays mode): drawn with a wider
        /// leading gap so the per-display runs read as separate clusters.
        var newDisplay: Bool = false
        /// The space's display name + icon for the hover tooltip. Resolved for every piece
        /// (numbered squares included, whose name/icon aren't drawn) so any tooltip-eligible
        /// segment can present them. `nil` only when there is no space to describe.
        var tipName: String? = nil
        var tipIcon: NSImage? = nil
    }

    /// The tooltip region implied by what a segment draws. Pure — depends only on the drawn
    /// kind — so the rules stay verifiable in `selfChecks`. A drawn name already identifies the
    /// space, so a named segment shows nothing; otherwise the number/icon carries name + icon.
    private static func tooltipRegion(for kind: Piece.Kind) -> TooltipRegion {
        switch kind {
        case .number, .iconTile, .grid: return .full
        case let .iconName(_, name): return (name?.isEmpty == false) ? .none : .icon
        }
    }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth, height: NSStatusBar.system.thickness)
    }

    /// Diagnostic: a compact dump of the laid-out pieces (kind@x wWidth[tooltip:name]).
    var debugInfo: String {
        pieces.map { p in
            let base: String
            switch p.kind {
            case let .number(n, c): base = "num\(n)\(c ? "*" : "")@\(Int(p.x))w\(Int(p.width))"
            case let .iconTile(_, c): base = "icon\(c ? "*" : "")@\(Int(p.x))w\(Int(p.width))"
            case .iconName:         base = "iconName@\(Int(p.x))w\(Int(p.width))"
            case .grid:             base = "grid@\(Int(p.x))w\(Int(p.width))"
            }
            let region: String
            switch Self.tooltipRegion(for: p.kind) {
            case .none: region = "-"
            case .full: region = "tipFull"
            case .icon: region = "tipIcon"
            }
            return "\(base)[\(region):\(p.tipName ?? "nil")]"
        }.joined(separator: " ")
    }

    // MARK: - Configuration

    /// Rebuild the strip. `displaySpaces` must be ordered by display then
    /// `ordinalOnDisplay` — one display's list when the menu bar follows the focused
    /// display, every display's otherwise (a wider gap separates display groups, and
    /// each display's current space is marked). `currentUUIDs` holds the current space
    /// of every included display. `title`/`icon` resolve a space's display name and icon.
    func update(displaySpaces: [Space], currentUUIDs: Set<String>,
                showIcon: Bool, showName: Bool, showSwitcher: Bool,
                title: (Space) -> String, icon: (Space) -> NSImage?) {
        hideTooltip()   // pieces are about to change; drop any showing tooltip + its stale index.
        let iconsStyle = Prefs.workspaceListStyle == .icons
        defaultIconImage = iconsStyle
            ? IconRendering.image(for: Prefs.workspaceListDefaultIcon, pointSize: 15) : nil
        let currents = displaySpaces.filter { currentUUIDs.contains($0.uuid) }
        var built: [Piece] = []

        if showSwitcher, !displaySpaces.isEmpty {
            for (i, space) in displaySpaces.enumerated() {
                let isCur = currentUUIDs.contains(space.uuid)
                let name = title(space)
                let img = icon(space)
                // The iconName special-case exists to show the current space's NAME
                // (optionally with its icon). In the icons style an icon-only current
                // space would duplicate what a tile already draws — but unmarked, so
                // with backgrounds off nothing would distinguish it. Let it fall
                // through to a (flipped) icon tile instead.
                let kind: Piece.Kind
                if isCur && (showName || (showIcon && !iconsStyle)) {
                    // Icon-only with no icon set: fall back to the placeholder so the
                    // current segment never renders empty. With the name on, the name
                    // alone is enough — no placeholder.
                    let fallback = (showIcon && !showName) ? Self.placeholderIcon : nil
                    kind = .iconName(icon: showIcon ? (img ?? fallback) : nil, name: showName ? name : nil)
                } else if iconsStyle {
                    kind = .iconTile(icon: img, current: isCur)
                } else {
                    kind = .number(space.ordinalOnDisplay + 1, current: isCur)
                }
                built.append(Piece(kind: kind, uuid: space.uuid, isCurrent: isCur,
                                   newDisplay: i > 0 && space.displayIndex != displaySpaces[i - 1].displayIndex,
                                   tipName: name, tipIcon: img))
            }
        } else if showIcon || showName, !displaySpaces.isEmpty {
            // One segment per included display's current space (a single one when the
            // strip follows the focused display).
            let segments = currents.isEmpty ? Array(displaySpaces.prefix(1)) : currents
            for (i, current) in segments.enumerated() {
                let name = title(current)
                let img = icon(current)
                let fallback = (showIcon && !showName) ? Self.placeholderIcon : nil
                built.append(Piece(kind: .iconName(icon: showIcon ? (img ?? fallback) : nil,
                                                   name: showName ? name : nil),
                                   uuid: current.uuid, isCurrent: true, newDisplay: i > 0,
                                   tipName: name, tipIcon: img))
            }
        } else {
            // All elements off (or no current space): a plain grid icon that opens the menu. The
            // tooltip still reveals the current space here — nothing else on screen names it.
            let cur = currents.first
            built.append(Piece(kind: .grid, uuid: cur?.uuid, isCurrent: true,
                               tipName: cur.map(title), tipIcon: cur.flatMap(icon)))
        }

        // Measure + lay out left-to-right, inset by the leading/trailing edge padding.
        var x: CGFloat = edgePad
        for i in built.indices {
            // Adjacent icons touch (gap 0) and are separated by their margins; a new
            // display's first icon still gets a fixed clustering gap so per-display runs read
            // as separate groups in the all-displays menu bar.
            if i > 0 { x += built[i].newDisplay ? M.gap * 3 : 0 }
            let w = width(for: built[i].kind)
            built[i].x = x
            built[i].width = w
            x += w
        }
        pieces = built
        totalWidth = max(x + edgePad, M.iconSide)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        rebuildTooltipTracking()
    }

    private func width(for kind: Piece.Kind) -> CGFloat {
        switch kind {
        case .number, .iconTile: return numberM.side + iconMargin * 2
        case .grid:   return iconSide + hPad * 2
        case let .iconName(icon, name):
            var w: CGFloat = 0
            if icon != nil { w += iconSide }
            if let name, !name.isEmpty {
                if icon != nil { w += M.iconNameGap }
                w += min(M.maxNameWidth, ceil((name as NSString).size(withAttributes: [.font: nameFontObj]).width))
            }
            return w + hPad * 2
        }
    }

    // User-tunable layout metrics (Settings → Menu Bar). `iconMargin` is the "Spacing"
    // knob — padding added around every icon (squares/tiles included) on top of the
    // baselines; `hPad` is the icon/name and grid segments' internal padding (their
    // `M.hPad` baseline plus that margin); `edgePad` the leading/trailing padding of the
    // whole strip. The inter-segment gap is fixed at 0 (adjacent icons are separated by
    // their margins alone); only a new display's group still gets a fixed clustering gap.
    private var iconMargin: CGFloat { Prefs.menuBarSpacing }
    private var hPad: CGFloat { M.hPad + iconMargin }
    private var edgePad: CGFloat { Prefs.menuBarEdgePadding }

    private var numberFontObj: NSFont { .systemFont(ofSize: numberM.font, weight: .medium) }
    /// The size pref scales the WHOLE item, not just the squares: the current-space icon,
    /// name font, and grid fallback all follow the 15 pt baseline proportionally.
    private var stripScale: CGFloat { numberM.side / M.square }
    private var iconSide: CGFloat { M.iconSide * stripScale }
    private var nameFontObj: NSFont { .systemFont(ofSize: M.nameFont * stripScale, weight: .regular) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        for p in pieces {
            switch p.kind {
            case let .number(n, current):
                let m = numberM
                let rect = NSRect(x: p.x + (p.width - m.side) / 2, y: midY - m.side / 2,
                                  width: m.side, height: m.side)
                let lk = look(current: current)
                if let fillColor = fill(for: lk) {
                    let path = NSBezierPath(roundedRect: rect, xRadius: m.corner, yRadius: m.corner)
                    fillColor.setFill(); path.fill()
                }
                drawNumber(n, in: rect, color: glyph(for: lk))
            case let .iconTile(icon, current):
                let m = numberM
                let rect = NSRect(x: p.x + (p.width - m.side) / 2, y: midY - m.side / 2,
                                  width: m.side, height: m.side)
                let lk = look(current: current)
                if let fillColor = fill(for: lk) {
                    let path = NSBezierPath(roundedRect: rect, xRadius: m.corner, yRadius: m.corner)
                    fillColor.setFill(); path.fill()
                }
                if let img = icon ?? defaultIconImage {
                    // The inset keeps the glyph proportioned like the digits, and means a
                    // 15 pt render is never upscaled (inner side ≤ 15.4 across 12–22 pt).
                    let inner = rect.insetBy(dx: m.side * 0.15, dy: m.side * 0.15)
                    // Flipped look: inverted on the labelColor fill (emoji pass through untinted).
                    let tinted = lk == .flipped ? Self.tinted(img, invertedGlyphColor) : img
                    drawIcon(tinted, in: inner)
                }
            case let .iconName(icon, name):
                // "Show background" applies to the whole item: the current-space segment
                // wears its look's pill whether it sits in the workspace list or alone
                // (flipped normally, grey when colours are inverted).
                let lk = look(current: true)
                let pill = Prefs.menuBarSwitcherGreyBackground
                if pill, let fillColor = fill(for: lk) {
                    // Match the squares' treatment; never shorter than the content
                    // (scaled name/icon), so small sizes don't clip the pill.
                    let h = max(numberM.side, iconSide + 4)
                    let r = NSRect(x: p.x, y: midY - h / 2, width: p.width, height: h)
                    let radius = h * M.squareCorner / M.square
                    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                    fillColor.setFill(); path.fill()
                }
                var cx = p.x + hPad
                let hasName = (name?.isEmpty == false)
                if let icon {
                    drawIcon(pill && lk == .flipped ? Self.tinted(icon, invertedGlyphColor) : icon,
                             in: NSRect(x: cx, y: midY - iconSide / 2, width: iconSide, height: iconSide))
                    cx += iconSide + (hasName ? M.iconNameGap : 0)
                }
                if let name, hasName {
                    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                    let attrs: [NSAttributedString.Key: Any] =
                        [.font: nameFontObj,
                         .foregroundColor: pill ? glyph(for: lk) : NSColor.labelColor,
                         .paragraphStyle: para]
                    let sz = (name as NSString).size(withAttributes: [.font: nameFontObj])
                    let tw = min(M.maxNameWidth, ceil(sz.width))
                    (name as NSString).draw(in: NSRect(x: cx, y: midY - sz.height / 2, width: tw, height: sz.height),
                                            withAttributes: attrs)
                }
            case .grid:
                if let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
                    drawIcon(img, in: NSRect(x: p.x + hPad, y: midY - iconSide / 2, width: iconSide, height: iconSide))
                }
            }
        }
    }

    private func drawNumber(_ n: Int, in rect: NSRect, color: NSColor) {
        let s = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFontObj, .foregroundColor: color]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
    }

    private func drawIcon(_ image: NSImage, in rect: NSRect) {
        let img = image.isTemplate ? Self.tinted(image, .labelColor) : image
        let scale = min(rect.width / max(img.size.width, 1), rect.height / max(img.size.height, 1), 1)
        let w = img.size.width * scale, h = img.size.height * scale
        img.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// Tint a template image to `color` (color/emoji images pass through unchanged).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        let out = image.copy() as! NSImage
        out.lockFocus()
        color.set()
        NSRect(origin: .zero, size: out.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    // MARK: - Hover tooltips
    //
    // Each tooltip-eligible segment gets an NSTrackingArea; entering it shows a small floating
    // panel (`MenuBarTooltip`) with the space's name + icon after a short delay. Which segments
    // qualify — and the exact hover rect — follow `tooltipRegion(for:)`: the whole square for a
    // number and the grid fallback, the icon glyph for an icon-only current space, nothing for a
    // drawn name (the name already identifies the space).

    private lazy var tooltip = MenuBarTooltip()
    private var tipTracking: [NSTrackingArea] = []
    private var tipShowTimer: Timer?
    private var tipHideTimer: Timer?
    private var tipShownIndex: Int?

    /// The hover rect for a segment within a strip of the given `height`, or nil if it shows no
    /// tooltip. Pure (no view state) so full-menu-bar-height coverage stays verifiable in
    /// `selfChecks`. Every region spans the FULL height (y: 0 … height) so the target reaches the
    /// top and bottom of even a short, notch-less menu bar; the icon-only case stays icon-width
    /// horizontally, the rest spans the whole segment.
    private static func tooltipRect(kind: Piece.Kind, hasTip: Bool,
                                    x: CGFloat, width: CGFloat, height: CGFloat,
                                    iconSide: CGFloat = M.iconSide,
                                    hPad: CGFloat = M.hPad) -> NSRect? {
        guard hasTip else { return nil }
        switch tooltipRegion(for: kind) {
        case .none: return nil
        case .full: return NSRect(x: x, y: 0, width: width, height: height)
        case .icon: return NSRect(x: x + hPad, y: 0, width: iconSide, height: height)
        }
    }

    /// The hover rect (view coordinates) for `p`, or nil if it shows no tooltip.
    private func tooltipRect(for p: Piece) -> NSRect? {
        Self.tooltipRect(kind: p.kind, hasTip: p.tipName != nil || p.tipIcon != nil,
                         x: p.x, width: p.width, height: bounds.height,
                         iconSide: iconSide, hPad: hPad)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTooltipTracking()
    }

    /// Replace the per-segment tracking areas from the current `pieces`. Called after every
    /// `update()` and on every layout pass (via `updateTrackingAreas`), so hover regions track
    /// the strip as it is rebuilt or resized.
    private func rebuildTooltipTracking() {
        for a in tipTracking { removeTrackingArea(a) }
        tipTracking.removeAll()
        guard bounds.height > 0 else { return }
        for (i, p) in pieces.enumerated() {
            guard let rect = tooltipRect(for: p) else { continue }
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: ["i": i])
            addTrackingArea(area)
            tipTracking.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let i = event.trackingArea?.userInfo?["i"] as? Int else { return }
        tipHideTimer?.invalidate(); tipHideTimer = nil
        if tipShownIndex != nil {
            showTooltip(at: i)          // already visible → follow the pointer with no re-delay
        } else {
            tipShowTimer?.invalidate()
            tipShowTimer = Timer.scheduledTimer(withTimeInterval: M.tipShowDelay, repeats: false) { [weak self] _ in
                self?.showTooltip(at: i)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        tipShowTimer?.invalidate(); tipShowTimer = nil
        // A brief grace period bridges the untracked inter-segment gaps so sliding across the
        // strip doesn't flicker the tooltip; a real exit (into a window / bare menu bar) hides it.
        tipHideTimer?.invalidate()
        tipHideTimer = Timer.scheduledTimer(withTimeInterval: M.tipHideGrace, repeats: false) { [weak self] _ in
            self?.hideTooltip()
        }
    }

    private func showTooltip(at i: Int) {
        tipShowTimer?.invalidate(); tipShowTimer = nil
        guard i < pieces.count, let window, tooltipRect(for: pieces[i]) != nil else { hideTooltip(); return }
        let p = pieces[i]
        // Anchor to the full-height segment (not the icon sub-rect) so the tooltip sits at a
        // consistent depth below the menu bar whether triggered by a number or an icon.
        let anchor = NSRect(x: p.x, y: 0, width: p.width, height: bounds.height)
        let onScreen = window.convertToScreen(convert(anchor, to: nil))
        tipShownIndex = i
        tooltip.show(name: p.tipName, icon: p.tipIcon, below: onScreen)
    }

    private func hideTooltip() {
        tipShowTimer?.invalidate(); tipShowTimer = nil
        tipHideTimer?.invalidate(); tipHideTimer = nil
        tipShownIndex = nil
        tooltip.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideTooltip() }
    }

    // MARK: - Clicks

    /// The piece under `x`, or — for the small inter-segment gaps — the nearest one. Clicks always
    /// land within the strip, so this resolves every click to a segment (no dead zones).
    private func segment(atX x: CGFloat) -> Piece? {
        if let hit = pieces.first(where: { x >= $0.x && x <= $0.x + $0.width }) { return hit }
        return pieces.min { abs($0.x + $0.width / 2 - x) < abs($1.x + $1.width / 2 - x) }
    }

    override func mouseDown(with event: NSEvent) {
        hideTooltip()   // a click either switches or opens the menu — the tooltip has served its purpose
        if event.modifierFlags.contains(.control) { onOpenMenu?(); return }   // control-click = menu
        // Non-current workspaces are always numbers → switch. The current workspace (number, icon,
        // or icon+name) opens the menu, as does any right-click.
        if let seg = segment(atX: cursorLocalX(fallback: event)), !seg.isCurrent, let uuid = seg.uuid {
            onSelect?(uuid)
        } else {
            onOpenMenu?()
        }
    }

    /// The cursor's x within this view. `NSStatusBarButton` reports `mouseDown`'s `locationInWindow`
    /// at the button's center regardless of where you click, so it's useless for sub-segment
    /// hit-testing — derive the position from the global cursor location instead.
    private func cursorLocalX(fallback event: NSEvent) -> CGFloat {
        guard let window else { return convert(event.locationInWindow, from: nil).x }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil).x
    }

    override func rightMouseDown(with event: NSEvent) { hideTooltip(); onOpenMenu?() }

    // MARK: - Self-tests (pure trigger rules)

    /// Verifies the hover-tooltip trigger rules: a numbered square (current or not) and the grid
    /// fallback always get a tooltip; an icon-only current space gets one on its icon; a drawn
    /// name never does. Run by `SelfTest` (`SpeedySpaces --selftest`).
    static func selfChecks(_ check: SelfTest.Check) {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        check(tooltipRegion(for: .number(1, current: false)) == .full, "tooltip: non-current number -> full")
        check(tooltipRegion(for: .number(2, current: true))  == .full, "tooltip: current number -> full")
        check(tooltipRegion(for: .grid) == .full,                      "tooltip: grid fallback -> full")
        check(tooltipRegion(for: .iconName(icon: img, name: "Work")) == .none, "tooltip: icon+name -> none")
        check(tooltipRegion(for: .iconName(icon: nil, name: "Work")) == .none, "tooltip: name only -> none")
        check(tooltipRegion(for: .iconName(icon: img, name: nil))    == .icon, "tooltip: icon only -> icon")
        check(tooltipRegion(for: .iconName(icon: img, name: ""))     == .icon, "tooltip: icon + empty name -> icon")
        check(tooltipRegion(for: .iconTile(icon: img, current: false)) == .full, "tooltip: icon tile -> full")
        check(tooltipRegion(for: .iconTile(icon: nil, current: true))  == .full, "tooltip: current icon tile -> full")

        // Hover targets reach the top and bottom of the menu bar (full height, y: 0 … height) so
        // they stay easy to hit on a short, notch-less menu bar — including the icon-only case.
        let H: CGFloat = 24
        let numRect = tooltipRect(kind: .number(1, current: false), hasTip: true, x: 0, width: 15, height: H)
        check(numRect?.minY == 0 && numRect?.height == H, "tooltip target: number spans full height")
        let iconRect = tooltipRect(kind: .iconName(icon: img, name: nil), hasTip: true, x: 0, width: 23, height: H)
        check(iconRect?.minY == 0 && iconRect?.height == H, "tooltip target: icon-only spans full height")
        check(tooltipRect(kind: .iconName(icon: img, name: "X"), hasTip: true, x: 0, width: 90, height: H) == nil,
              "tooltip target: named segment has no hover rect")
        // Invert-colours look table: flipped marks the current space normally;
        // inverting (only meaningful with backgrounds on) swaps it onto the others.
        check(pieceLook(current: true,  background: true,  inverted: false) == .flipped, "look: bg, current -> flipped")
        check(pieceLook(current: false, background: true,  inverted: false) == .grey,    "look: bg, other -> grey")
        check(pieceLook(current: true,  background: true,  inverted: true)  == .grey,    "look: bg+invert, current -> grey")
        check(pieceLook(current: false, background: true,  inverted: true)  == .flipped, "look: bg+invert, other -> flipped")
        check(pieceLook(current: true,  background: false, inverted: true)  == .flipped, "look: no bg, invert ignored for current")
        check(pieceLook(current: false, background: false, inverted: true)  == .plain,   "look: no bg, other -> plain")

        check(placeholderIcon?.isTemplate == true, "placeholder: rectangle.stack.fill resolves as template")

        let base = numberMetrics(side: 15)
        check(base == (15, 3.5, 10.5),      "metrics: 15 pt reproduces the baseline look")
        check(numberMetrics(side: 5).side == 12 && numberMetrics(side: 99).side == 22,
                                             "metrics: out-of-range side clamps to 12…22")
        let big = numberMetrics(side: 22)
        check(abs(big.corner - 3.5 * 22 / 15) < 0.0001 && abs(big.font - 10.5 * 22 / 15) < 0.0001,
                                             "metrics: corner and font scale linearly with side")
    }
}
