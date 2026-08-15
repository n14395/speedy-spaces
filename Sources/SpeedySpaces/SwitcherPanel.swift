import AppKit

/// One tile in the floating switcher bar: identity plus everything the view needs to draw it.
/// `caption` is the system-style text under the tile ("Desktop N" / fullscreen app);
/// `name`/`icon` are the user's custom label shown above the tile, mirroring what the
/// Mission Control overlay draws over the real bar.
struct SwitcherTile: Equatable {
    let uuid: String
    let caption: String
    let name: String?
    let icon: NSImage?
    let wallpaper: NSImage?
    /// Fullscreen spaces: the owning app's icon, drawn centered on the tile (the
    /// Exposé badge look — we can't snapshot other spaces' windows without Screen
    /// Recording, which Mission Control's private SPI doesn't need).
    var appBadge: NSImage? = nil
    let isCurrent: Bool
    let isFullscreen: Bool

    static func == (lhs: SwitcherTile, rhs: SwitcherTile) -> Bool {
        lhs.uuid == rhs.uuid && lhs.caption == rhs.caption && lhs.name == rhs.name
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isFullscreen == rhs.isFullscreen && lhs.icon === rhs.icon
            && lhs.wallpaper === rhs.wallpaper && lhs.appBadge === rhs.appBadge
    }
}

/// Pure layout math for the switcher bar, kept AppKit-free so it is self-testable.
/// Frames are in bottom-left-origin coordinates of a full-screen content view.
/// Geometry matches the real Mission Control spaces bar, pixel-measured on macOS 27:
/// fixed tile width ≈ screen/14.7 (aspect uses screen height minus the ~45 pt bar chrome),
/// 32 pt gaps, "Desktop N" caption 5 pt below each tile, custom name row above the tiles,
/// and a full-width backdrop band from the top of the screen to just under the captions.
enum SwitcherLayout {
    static let gap: CGFloat = 32
    static let idealWidthFraction: CGFloat = 139.5 / 2056
    static let maxRowFraction: CGFloat = 0.92
    static let minTileWidth: CGFloat = 60
    static let aspectHeightInset: CGFloat = 45
    static let defaultTopInset: CGFloat = 39
    static let labelGap: CGFloat = 5
    static let labelHeight: CGFloat = 16
    static let nameGap: CGFloat = 6
    static let nameHeight: CGFloat = 20
    static let bandBottomPadding: CGFloat = 7
    /// Classic Popover mode: the band hugs the content instead of spanning edge to edge,
    /// vertically centered. The tile ROW is capped at 80% of the screen width minus the
    /// row inset (tiles shrink past that); the frosted card then wraps the row with its
    /// own, more generous padding. `popoverRowInset` deliberately stays at the original
    /// band padding so enlarging the card never changes the thumbnail sizes.
    static let popoverMaxRowFraction: CGFloat = 0.80
    static let popoverRowInset: CGFloat = 24
    static let popoverPadding: CGFloat = 48
    static let popoverVerticalPadding: CGFloat = 26
    static let popoverCornerRadius: CGFloat = 20

    struct Result {
        let tileSize: CGSize
        let tileFrames: [CGRect]
        let labelFrames: [CGRect]
        let nameFrames: [CGRect]
        let barRect: CGRect
        static let empty = Result(tileSize: .zero, tileFrames: [], labelFrames: [],
                                  nameFrames: [], barRect: .zero)
    }

    /// Tiles hold Mission Control's fixed width, shrinking only when the row would
    /// overflow the max-row band, flooring at `minTileWidth` (a very long row simply
    /// overflows the band and stays centered — no scrolling in v1).
    ///
    /// `popover: false` (Mimic Mission Control) pins the row under `topInset` with a
    /// full-width band up to the top edge. `popover: true` (Classic Popover) centers the
    /// content vertically and the band hugs the row (padding on all sides, ≤80% of the
    /// screen width before the tiles start shrinking); `topInset` is ignored.
    static func tiles(count: Int, screenSize: CGSize,
                      topInset: CGFloat = defaultTopInset, popover: Bool = false) -> Result {
        guard count > 0, screenSize.width > 0, screenSize.height > aspectHeightInset
        else { return .empty }
        let n = CGFloat(count)
        let maxRow = popover
            ? screenSize.width * popoverMaxRowFraction - 2 * popoverRowInset
            : screenSize.width * maxRowFraction
        var width = screenSize.width * idealWidthFraction
        if n * width + (n - 1) * gap > maxRow {
            width = (maxRow - (n - 1) * gap) / n
        }
        width = max(width, minTileWidth)
        let height = width * (screenSize.height - aspectHeightInset) / screenSize.width
        let rowWidth = n * width + (n - 1) * gap
        let startX = (screenSize.width - rowWidth) / 2
        // Popover: center the whole content stack (name row + tile + caption) vertically.
        let contentAbove = nameGap + nameHeight               // above the tile top
        let contentBelow = labelGap + labelHeight             // below the tile bottom
        let tileTop = popover
            ? (screenSize.height + height + contentBelow - contentAbove) / 2
            : screenSize.height - topInset
        var tileFrames: [CGRect] = []
        var labelFrames: [CGRect] = []
        var nameFrames: [CGRect] = []
        for i in 0..<count {
            let x = startX + CGFloat(i) * (width + gap)
            let tile = CGRect(x: x, y: tileTop - height, width: width, height: height)
            tileFrames.append(tile)
            labelFrames.append(CGRect(x: x, y: tile.minY - labelGap - labelHeight,
                                      width: width, height: labelHeight))
            // Names may run wider than their tile (MC's overlay labels do); centered on
            // the tile with the gap as breathing room on both sides.
            nameFrames.append(CGRect(x: x - gap / 2, y: tile.maxY + nameGap,
                                     width: width + gap, height: nameHeight))
        }
        let barRect: CGRect
        if popover {
            let bottom = labelFrames[0].minY - popoverVerticalPadding
            barRect = CGRect(x: startX - popoverPadding, y: bottom,
                             width: rowWidth + 2 * popoverPadding,
                             height: nameFrames[0].maxY + popoverVerticalPadding - bottom)
        } else {
            let bandBottom = labelFrames[0].minY - bandBottomPadding
            barRect = CGRect(x: 0, y: bandBottom,
                             width: screenSize.width, height: screenSize.height - bandBottom)
        }
        return Result(tileSize: CGSize(width: width, height: height),
                      tileFrames: tileFrames, labelFrames: labelFrames,
                      nameFrames: nameFrames, barRect: barRect)
    }

    /// Where a dragged tile would insert given the pointer's x and the row of tiles it's
    /// hovering (drag-to-reorder). Midpoint rule: the number of tiles whose center is left
    /// of `x`, i.e. 0 (before the first) … count (after the last).
    static func insertionIndex(forX x: CGFloat, in tileFrames: [CGRect]) -> Int {
        tileFrames.reduce(0) { $0 + ($1.midX < x ? 1 : 0) }
    }

    /// The fixed Mission Control tile size for a screen (before overflow shrinking).
    static func fixedTileSize(screenSize: CGSize) -> CGSize {
        let width = screenSize.width * idealWidthFraction
        return CGSize(width: width,
                      height: width * (screenSize.height - aspectHeightInset) / screenSize.width)
    }

    static func selfChecks(_ check: SelfTest.Check) {
        let screen = CGSize(width: 1512, height: 982)
        for n in [1, 3, 9, 16] {
            let r = tiles(count: n, screenSize: screen)
            check(r.tileFrames.count == n, "switcher layout: \(n) tiles -> \(n) frames")
            let aspectOK = abs(r.tileSize.width / r.tileSize.height
                               - screen.width / (screen.height - aspectHeightInset)) < 0.01
            check(aspectOK, "switcher layout: \(n) tiles keep MC aspect")
            var overlaps = false
            for i in 1..<r.tileFrames.count where r.tileFrames[i - 1].maxX >= r.tileFrames[i].minX {
                overlaps = true
            }
            check(!overlaps, "switcher layout: \(n) tiles do not overlap")
            let rowCenter = (r.tileFrames[0].minX + r.tileFrames[n - 1].maxX) / 2
            check(abs(rowCenter - screen.width / 2) < 0.5, "switcher layout: \(n) tiles centered")
            check(abs(r.tileFrames[0].maxY - (screen.height - defaultTopInset)) < 0.5,
                  "switcher layout: \(n) tiles top edge at inset")
            check(r.barRect.contains(r.tileFrames[0]) && r.barRect.contains(r.labelFrames[n - 1]),
                  "switcher layout: \(n) tiles inside bar rect")
            check(r.barRect.minX == 0 && r.barRect.width == screen.width
                    && abs(r.barRect.maxY - screen.height) < 0.5,
                  "switcher layout: \(n) tiles band spans full width to top")
            check(r.nameFrames[0].minY >= r.tileFrames[0].maxY,
                  "switcher layout: \(n) tiles name row above tiles")
        }
        let two = tiles(count: 2, screenSize: screen)
        let nine = tiles(count: 9, screenSize: screen)
        check(abs(two.tileSize.width - screen.width * idealWidthFraction) < 0.5
                && two.tileSize.width == nine.tileSize.width,
              "switcher layout: tile width fixed while row fits")
        let many = tiles(count: 30, screenSize: CGSize(width: 1440, height: 900))
        check(many.tileSize.width >= minTileWidth, "switcher layout: width floors at minimum")
        check(many.tileSize.width < 1440 * idealWidthFraction,
              "switcher layout: overflowing row shrinks tiles")
        check(tiles(count: 0, screenSize: screen).tileFrames.isEmpty,
              "switcher layout: zero tiles -> empty")

        // Classic Popover mode: content-hugging band, centered, 80% width cap.
        let pFew = tiles(count: 2, screenSize: screen, popover: true)
        check(abs(pFew.tileSize.width - screen.width * idealWidthFraction) < 0.5,
              "popover layout: few tiles keep MC tile width")
        check(abs(pFew.barRect.midX - screen.width / 2) < 0.5
                && abs(pFew.barRect.midY - screen.height / 2) < 0.5,
              "popover layout: band centered on screen")
        check(pFew.barRect.width < screen.width,
              "popover layout: band hugs content, not edge to edge")
        let rowFew = pFew.tileFrames[1].maxX - pFew.tileFrames[0].minX
        check(abs(pFew.barRect.width - (rowFew + 2 * popoverPadding)) < 0.5,
              "popover layout: band width is row plus padding")
        check(pFew.barRect.contains(pFew.tileFrames[0]) && pFew.barRect.contains(pFew.labelFrames[1])
                && pFew.barRect.contains(pFew.nameFrames[0]),
              "popover layout: tiles, captions, and names inside the band")
        let pMany = tiles(count: 9, screenSize: screen, popover: true)
        let rowMany = pMany.tileFrames[8].maxX - pMany.tileFrames[0].minX
        check(rowMany <= screen.width * popoverMaxRowFraction - 2 * popoverRowInset + 0.5,
              "popover layout: row capped at 80% minus the row inset")
        check(pMany.tileSize.width < screen.width * idealWidthFraction,
              "popover layout: tiles shrink once the cap is hit")
        let expectedCapped = (screen.width * popoverMaxRowFraction - 2 * popoverRowInset
                                - 8 * gap) / 9
        check(abs(pMany.tileSize.width - expectedCapped) < 0.5,
              "popover layout: capped tile width tracks the row cap, not the card padding")
        let topMode = tiles(count: 9, screenSize: screen)
        check(pMany.tileSize.width < topMode.tileSize.width,
              "popover layout: 80% cap shrinks before the top band's 92% does")

        // insertionIndex — midpoint rule over a 3-tile row.
        let row = tiles(count: 3, screenSize: screen).tileFrames
        check(insertionIndex(forX: row[0].minX - 10, in: row) == 0, "insertionIndex: left of first -> 0")
        check(insertionIndex(forX: row[2].maxX + 10, in: row) == 3, "insertionIndex: right of last -> count")
        check(insertionIndex(forX: row[1].midX + 1, in: row) == 2, "insertionIndex: just past a midpoint -> next slot")
        check(insertionIndex(forX: row[1].midX - 1, in: row) == 1, "insertionIndex: just before a midpoint -> that slot")
        check(insertionIndex(forX: 0, in: []) == 0, "insertionIndex: empty row -> 0")
    }
}

/// Draws the row of space tiles the way Mission Control's spaces bar does: near-square
/// wallpaper thumbnails with no border, an accent-colored ring offset around the current
/// space, a plain "Desktop N" caption under each, and the custom name/icon row above
/// (mirroring the Mission Control overlay's labels).
/// Single flat `draw(_:)` over the full-screen view, matching the project's custom-draw style.
final class SwitcherBarView: NSView {
    var tiles: [SwitcherTile] = []
    var layout: SwitcherLayout.Result = .empty

    var onTileClick: ((Int) -> Void)?
    /// Click on a tile's name row (above) or "Desktop N" caption (below) — opens the
    /// name/icon editor, same as the pencil in the menu-bar list.
    var onNameClick: ((Int) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    // MARK: - Drag-to-reorder

    /// One non-ghost tile and the slot frame it is gliding toward during a drag.
    struct DragTarget: Equatable {
        let uuid: String
        let tile: SwitcherTile
        let frame: CGRect
    }
    /// What this panel should render mid-drag, pushed by the coordinator on every pointer
    /// move: the tiles that stay in the bar (gliding to make room) and, only on the panel
    /// under the pointer, the floating ghost of the dragged tile.
    struct DragPresentation: Equatable {
        var targets: [DragTarget]
        var ghostTile: SwitcherTile?
        var ghostFrame: CGRect
    }

    /// A tile drag began: (tile index in this panel, global pointer point).
    var onDragBegan: ((Int, NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    static let dragThreshold: CGFloat = 4

    /// A foreign window is being dragged over this tile for a window→workspace drop — the tile
    /// lights up so the target is obvious. nil = no drop hover. (Distinct from the reorder ghost.)
    var dropHoverIndex: Int? {
        didSet { if dropHoverIndex != oldValue { needsDisplay = true } }
    }

    private var pressIndex: Int?
    private var pressGlobal: NSPoint?
    private var isDraggingTile = false
    /// Per-uuid animated frames while dragging: each glides toward its target slot.
    private var displayedFrames: [String: CGRect] = [:]
    private var dragPresentation: DragPresentation? {
        didSet {
            guard dragPresentation != oldValue else { return }
            if let dp = dragPresentation {
                for t in dp.targets where displayedFrames[t.uuid] == nil {
                    displayedFrames[t.uuid] = normalFrame(forUUID: t.uuid) ?? t.frame
                }
                let live = Set(dp.targets.map(\.uuid))
                displayedFrames = displayedFrames.filter { live.contains($0.key) }
                startAnimTimerIfNeeded()
            } else {
                displayedFrames.removeAll()
            }
            needsDisplay = true
        }
    }

    func setDragPresentation(_ p: DragPresentation?) { dragPresentation = p }

    private func normalFrame(forUUID uuid: String) -> CGRect? {
        guard let i = tiles.firstIndex(where: { $0.uuid == uuid }),
              layout.tileFrames.indices.contains(i) else { return nil }
        return layout.tileFrames[i]
    }

    private var animTimer: Timer?

    /// Row-change animation (space added/removed): surviving tiles glide from their old
    /// frames to the new layout, a removed tile shrinks and fades in place, an added one
    /// slides in from the right edge — Mission Control's own add/remove motion.
    private struct RowTransition {
        let oldTiles: [SwitcherTile]
        let oldFrames: [CGRect]
        var progress: CGFloat = 0
    }
    private var rowTransition: RowTransition?
    private static let rowTransitionStep: CGFloat = 1.0 / (60 * 0.3)   // 0.3 s at 60 Hz

    /// Call after `tiles`/`layout` were updated to the NEW row, passing the previous
    /// values; no-op when the row is unchanged. Order-sensitive, so a pure permutation
    /// (drag-to-reorder) glides too — `drawRowTransition` keys old frames by uuid, so a
    /// reorder animates every tile from its old slot to its new one with no removals.
    func beginRowTransition(oldTiles: [SwitcherTile], oldLayout: SwitcherLayout.Result) {
        guard !oldTiles.isEmpty,
              oldTiles.map(\.uuid) != tiles.map(\.uuid) else { return }
        rowTransition = RowTransition(oldTiles: oldTiles, oldFrames: oldLayout.tileFrames)
        startAnimTimerIfNeeded()
        needsDisplay = true
    }

    static func easeInOut(_ p: CGFloat) -> CGFloat {
        p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    static func selfChecks(_ check: SelfTest.Check) {
        check(easeInOut(0) == 0 && easeInOut(1) == 1, "easeInOut: endpoints pinned")
        check(abs(easeInOut(0.5) - 0.5) < 0.0001, "easeInOut: midpoint is 0.5")
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { easeInOut(CGFloat($0)) }
        check(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "easeInOut: monotonic")
        let a = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = CGRect(x: 40, y: 20, width: 200, height: 150)
        check(approach(a, b, 0) == a && approach(a, b, 1) == b, "approach: endpoints")
        let mid = approach(a, b, 0.5)
        check(mid == CGRect(x: 20, y: 10, width: 150, height: 100), "approach: midpoint lerp")
        // SwitcherTile equality: identity-based on images, value-based on the rest.
        let img1 = NSImage(size: NSSize(width: 1, height: 1))
        let img2 = NSImage(size: NSSize(width: 1, height: 1))
        func tile(icon: NSImage?, current: Bool = false, caption: String = "Desktop 1") -> SwitcherTile {
            SwitcherTile(uuid: "u", caption: caption, name: nil, icon: icon, wallpaper: nil,
                         isCurrent: current, isFullscreen: false)
        }
        check(tile(icon: img1) == tile(icon: img1), "tile ==: same image identity equal")
        check(tile(icon: img1) != tile(icon: img2), "tile ==: images compare by identity, not value")
        check(tile(icon: nil) != tile(icon: nil, current: true), "tile ==: isCurrent participates")
        check(tile(icon: nil) != tile(icon: nil, caption: "Desktop 2"), "tile ==: caption participates")
    }

    /// MC's active ring, pixel-measured: 3 pt stroke whose outer edge sits 5 pt outside
    /// the tile (2 pt clear gap), outer corner radius ~3.5 pt.
    static let tileRadius: CGFloat = 2
    static let ringWidth: CGFloat = 3
    static let ringOutset: CGFloat = 5

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let dp = dragPresentation {
            drawDragScene(dp)
            return
        }
        guard tiles.count == layout.tileFrames.count else { return }
        if let transition = rowTransition {
            drawRowTransition(transition)
        } else {
            for (i, tile) in tiles.enumerated() {
                drawTile(tile, in: layout.tileFrames[i])
                if i == dropHoverIndex { drawDropHighlight(in: layout.tileFrames[i]) }
                drawCaption(tile, in: layout.labelFrames[i])
                drawName(tile, in: layout.nameFrames[i])
            }
        }
    }

    /// The drop-target highlight for a window→workspace drag: an accent tint + a bold accent ring,
    /// brighter than the current-space ring so the tile being dropped onto reads at a glance.
    private func drawDropHighlight(in rect: NSRect) {
        let fill = NSBezierPath(roundedRect: rect, xRadius: Self.tileRadius, yRadius: Self.tileRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.4).setFill()
        fill.fill()
        let inset = Self.ringOutset - Self.ringWidth / 2
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -inset, dy: -inset),
                                xRadius: Self.tileRadius + inset, yRadius: Self.tileRadius + inset)
        ring.lineWidth = Self.ringWidth + 1
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }

    /// Caption/name frames derived from a tile frame — so a tile's labels ride it while it
    /// glides (drag reflow, row transition, and the ghost all share this).
    private func captionRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: f.minY - SwitcherLayout.labelGap - SwitcherLayout.labelHeight,
               width: f.width, height: SwitcherLayout.labelHeight)
    }
    private func nameRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX - SwitcherLayout.gap / 2, y: f.maxY + SwitcherLayout.nameGap,
               width: f.width + SwitcherLayout.gap, height: SwitcherLayout.nameHeight)
    }

    private func drawDragScene(_ dp: DragPresentation) {
        for t in dp.targets {
            let f = displayedFrames[t.uuid] ?? t.frame
            drawTile(t.tile, in: f)
            drawCaption(t.tile, in: captionRect(f))
            drawName(t.tile, in: nameRect(f))
        }
        if let ghost = dp.ghostTile { drawGhost(ghost, in: dp.ghostFrame) }
    }

    /// The floating dragged tile: a hair larger, with a drop shadow, drawn above the row.
    private func drawGhost(_ tile: SwitcherTile, in frame: CGRect) {
        let scaled = frame.insetBy(dx: -frame.width * 0.025, dy: -frame.height * 0.025)
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.set()
            drawTile(tile, in: scaled)
            cg.restoreGState()
        } else {
            drawTile(tile, in: scaled)
        }
        drawCaption(tile, in: captionRect(scaled))
        drawName(tile, in: nameRect(scaled))
    }

    private static func approach(_ a: CGRect, _ b: CGRect, _ f: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f,
               width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
    }

    private func drawRowTransition(_ transition: RowTransition) {
        let p = Self.easeInOut(min(transition.progress, 1))
        func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                   width: a.width + (b.width - a.width) * t,
                   height: a.height + (b.height - a.height) * t)
        }
        func withAlpha(_ alpha: CGFloat, _ body: () -> Void) {
            guard let cg = NSGraphicsContext.current?.cgContext else { body(); return }
            cg.saveGState()
            cg.setAlpha(alpha)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        var oldFrameByUUID: [String: CGRect] = [:]
        for (i, old) in transition.oldTiles.enumerated()
        where transition.oldFrames.indices.contains(i) {
            oldFrameByUUID[old.uuid] = transition.oldFrames[i]
        }
        let newUUIDs = Set(tiles.map(\.uuid))
        // Removed tiles shrink and fade in place while the survivors close the gap.
        for (i, old) in transition.oldTiles.enumerated()
        where !newUUIDs.contains(old.uuid) && transition.oldFrames.indices.contains(i) {
            let f0 = transition.oldFrames[i]
            let s = 1 - p
            let rect = CGRect(x: f0.midX - f0.width * s / 2, y: f0.midY - f0.height * s / 2,
                              width: f0.width * s, height: f0.height * s)
            withAlpha(1 - p) { drawTile(old, in: rect) }
        }
        for (i, tile) in tiles.enumerated() {
            let to = layout.tileFrames[i]
            let from = oldFrameByUUID[tile.uuid]
                ?? CGRect(x: bounds.maxX + 8, y: to.minY, width: to.width, height: to.height)
            let f = lerp(from, to, p)
            let isNew = oldFrameByUUID[tile.uuid] == nil
            withAlpha(isNew ? p : 1) {
                drawTile(tile, in: f)
                // Caption/name ride their tile during the glide.
                drawCaption(tile, in: CGRect(x: f.minX,
                                             y: f.minY - SwitcherLayout.labelGap
                                                - SwitcherLayout.labelHeight,
                                             width: f.width,
                                             height: SwitcherLayout.labelHeight))
                drawName(tile, in: CGRect(x: f.minX - SwitcherLayout.gap / 2,
                                          y: f.maxY + SwitcherLayout.nameGap,
                                          width: f.width + SwitcherLayout.gap,
                                          height: SwitcherLayout.nameHeight))
            }
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard layout.barRect.width > 0 else { return }
        addTrackingArea(NSTrackingArea(rect: layout.barRect,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }

    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    /// A press records the tile under the pointer but commits to nothing — `mouseUp`
    /// decides click, and `mouseDragged` promotes to a drag past the threshold. AppKit
    /// keeps delivering drag/up to this window even once the pointer leaves it (or the
    /// screen), which is what lets a drag cross onto another display's panel.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressIndex = layout.tileFrames.firstIndex { $0.contains(p) }
        pressGlobal = NSEvent.mouseLocation
        isDraggingTile = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = pressIndex, let start = pressGlobal else { return }
        let g = NSEvent.mouseLocation
        if isDraggingTile {
            onDragMoved?(g)
        } else if hypot(g.x - start.x, g.y - start.y) > Self.dragThreshold {
            isDraggingTile = true
            onDragBegan?(idx, g)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingTile {
            isDraggingTile = false
            pressIndex = nil
            pressGlobal = nil
            onDragEnded?(NSEvent.mouseLocation)
            return
        }
        pressIndex = nil
        pressGlobal = nil
        let p = convert(event.locationInWindow, from: nil)
        for (i, frame) in layout.tileFrames.enumerated() {
            if frame.contains(p) {
                onTileClick?(i)
                return
            }
        }
        // The text rows around each tile edit that space's name/icon. The caption is a
        // target even when no custom name exists yet, so every space stays reachable.
        if let i = layout.nameFrames.firstIndex(where: { $0.insetBy(dx: 0, dy: -2).contains(p) })
            ?? layout.labelFrames.firstIndex(where: { $0.insetBy(dx: 0, dy: -2).contains(p) }) {
            onNameClick?(i)
        }
    }

    /// One 60 Hz timer drives the row-change glide (fixed 0.3 s, eased at draw time) and,
    /// while a drag is in flight, the continuous reflow of tiles toward their gap slots.
    private func startAnimTimerIfNeeded() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.rowTransition != nil {
                self.rowTransition!.progress += Self.rowTransitionStep
                if self.rowTransition!.progress >= 1 { self.rowTransition = nil }
            }
            if let dp = self.dragPresentation {
                for t in dp.targets {
                    let cur = self.displayedFrames[t.uuid] ?? t.frame
                    self.displayedFrames[t.uuid] = Self.approach(cur, t.frame, 0.35)
                }
            }
            if self.rowTransition == nil && self.dragPresentation == nil {
                self.animTimer?.invalidate()
                self.animTimer = nil
            }
            self.needsDisplay = true
        }
    }

    private func drawTile(_ tile: SwitcherTile, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.tileRadius,
                                yRadius: Self.tileRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image = tile.wallpaper {
            let src = Self.aspectFillRect(imageSize: image.size, tileSize: rect.size)
            image.draw(in: rect, from: src, operation: .sourceOver, fraction: 1)
        } else {
            let gradient = NSGradient(starting: NSColor(white: 0.15, alpha: 1),
                                      ending: NSColor(white: 0.25, alpha: 1))
            gradient?.draw(in: rect, angle: 90)
        }
        if tile.isFullscreen {
            NSColor.black.withAlphaComponent(0.35).setFill()
            rect.fill(using: .sourceOver)
        }
        if let badge = tile.appBadge {
            // Centered app icon at ~55% of the tile height — the Exposé badge look for
            // fullscreen spaces, whose windows we cannot snapshot.
            let side = rect.height * 0.55
            badge.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                  width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: 1)
        } else if Prefs.thumbnailIconStyle == .largeOver, let icon = tile.icon {
            // "Large icons over the thumbnail": the space's custom icon centered on the
            // wallpaper (fullscreen tiles keep their app badge instead), riding the same
            // circular badge as the Mission Control overlay so it reads on any wallpaper.
            let image = IconRendering.circleBadged(
                icon.isTemplate ? Self.tinted(icon, color: .white) : icon)
            NSGraphicsContext.saveGraphicsState()
            Self.labelShadow.set()
            image.draw(in: NSRect(x: rect.midX - image.size.width / 2,
                                  y: rect.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if tile.isCurrent {
            let inset = Self.ringOutset - Self.ringWidth / 2   // stroke centerline
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -inset, dy: -inset),
                                    xRadius: Self.tileRadius + inset,
                                    yRadius: Self.tileRadius + inset)
            ring.lineWidth = Self.ringWidth
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    /// "Desktop N" under the tile: system 13 regular, plain white like MC's own caption.
    private func drawCaption(_ tile: SwitcherTile, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: tile.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white,
            .shadow: Self.labelShadow,
            .paragraphStyle: style,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Custom name/icon above the tile — same recipe as the Mission Control overlay's
    /// labels (14 pt, bold per pref, icon riding in a text attachment).
    private func drawName(_ tile: SwitcherTile, in rect: NSRect) {
        // In the "over the thumbnail" style the icon is drawn ON the tile (drawTile), so
        // the row above carries the name alone.
        let inlineIcon = Prefs.thumbnailIconStyle == .largeOver ? nil : tile.icon
        guard tile.name != nil || inlineIcon != nil else { return }
        let font = NSFont.systemFont(ofSize: 14,
                                     weight: Prefs.missionControlLabelsBold ? .bold : .regular)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString()
        if let icon = inlineIcon {
            let image = icon.isTemplate ? Self.tinted(icon, color: .white) : icon
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(attachment: attachment))
            if tile.name != nil { out.append(NSAttributedString(string: " ")) }
        }
        if let name = tile.name { out.append(NSAttributedString(string: name)) }
        out.addAttributes([.font: font, .foregroundColor: NSColor.white,
                           .shadow: Self.labelShadow, .paragraphStyle: style],
                          range: NSRange(location: 0, length: out.length))
        // Seat the row's BOTTOM at the frame's bottom (a fixed gap above the tile) so a
        // taller rendering — the icon-only "large icons" mode — grows upward, like the
        // Mission Control overlay's labels, instead of spilling down onto the thumbnail.
        let content = out.boundingRect(with: NSSize(width: rect.width, height: 200),
                                       options: [.usesLineFragmentOrigin])
        out.draw(with: NSRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: ceil(content.height)),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static let labelShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    /// Source rect (in image coordinates) whose aspect matches the tile so drawing it into
    /// the tile fills without distortion — centered crop of the overflowing axis.
    static func aspectFillRect(imageSize: CGSize, tileSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              tileSize.width > 0, tileSize.height > 0 else { return .zero }
        let scale = max(tileSize.width / imageSize.width, tileSize.height / imageSize.height)
        let cropW = tileSize.width / scale
        let cropH = tileSize.height / scale
        return CGRect(x: (imageSize.width - cropW) / 2, y: (imageSize.height - cropH) / 2,
                      width: cropW, height: cropH)
    }

    /// Flatten a template image to a concrete color (attachment cells draw images verbatim,
    /// without the tinting template images get elsewhere).
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Parks HUD panels in a private always-shown WindowServer space so they hold still
/// during the space-switch slide instead of riding out with the outgoing space and
/// re-appearing on the incoming one. A window whose only space is unmanaged doesn't
/// participate in the managed-space viewport animation (the system-bezel technique).
/// Best-effort: if the private symbols are gone, the HUD just rides the slide as before.
enum SwitcherStickySpace {
    /// SketchyBar's recipe: the space sits at absolute level 0 (windows' own levels
    /// still order content within it) and windows are attached with the atomic
    /// add-and-remove-from-others call — the separate add/remove pair leaves the
    /// window uncomposited on this macOS. Mission Control still wins over the HUD
    /// because the panels order out under suppression.
    private static var spaceID: UInt64 = 0
    private static var unavailable = false

    /// Move the panel's window into the sticky space exclusively. Idempotent and cheap;
    /// called on every present because an orderOut/orderFront cycle re-attaches the
    /// window to the active managed space.
    static func park(_ window: NSWindow) {
        guard !unavailable, window.windowNumber > 0 else { return }
        if spaceID == 0 {
            guard sm_stickySpaceSymbolsAvailable() else {
                unavailable = true
                HotkeyDiag.log("sticky space symbols missing — HUD rides the slide")
                return
            }
            spaceID = sm_stickySpaceCreate(0)
            guard spaceID != 0 else {
                unavailable = true
                HotkeyDiag.log("sticky space create failed — HUD rides the slide")
                return
            }
            HotkeyDiag.log("sticky space \(spaceID) created")
        }
        if !sm_stickySpaceAttachWindow(UInt32(window.windowNumber), spaceID) {
            unavailable = true
            HotkeyDiag.log("sticky attach symbol missing — HUD rides the slide")
        }
    }
}

/// Borderless, click-through, all-spaces panel hosting the switcher bar on one display.
/// Same panel recipe as the Mission Control overlay's window, but at a HUD level below
/// the shield (Mission Control must win if suppression ever misses). The backdrop is a
/// full-width band across the top of the screen — the light blurred strip the real
/// Mission Control bar sits on — so it keeps a light appearance in both modes.
final class SwitcherPanel: NSPanel {
    /// Named so it can be tuned; .screenSaver clears fullscreen app windows.
    static let hudLevel = NSWindow.Level.screenSaver
    /// Code flag for the M5 A/B: translucent band behind the tiles vs bare tiles.
    static let showsBackdropPill = true

    private let container = NSView()
    private let backdrop = NSVisualEffectView()
    private let barView = SwitcherBarView()
    private var fadeGen = 0
    private(set) var isPresented = false
    /// While presented, a 10 Hz watch flips mouse acceptance on only when the pointer is
    /// inside the band — so a 1 s flash never eats clicks aimed at the menu bar or
    /// desktop, yet moving into the bar makes it fully interactive (window-server hit
    /// testing is all-or-nothing for a window; this is the per-region version).
    private var pointerWatch: Timer?
    /// Last polled global cursor location, for detecting MOVEMENT over the band (vs mere presence).
    private var lastPointerLoc: NSPoint?
    /// Fired from the pointer watch when the cursor actually moves over the band — lets the HUD pin
    /// a flash on active hover only, never under a cursor that merely rests where the flash appears.
    var onBandPointerMoved: (() -> Void)?

    var onTileClick: ((Int) -> Void)? {
        get { barView.onTileClick } set { barView.onTileClick = newValue }
    }
    var onNameClick: ((Int) -> Void)? {
        get { barView.onNameClick } set { barView.onNameClick = newValue }
    }
    var onHoverChanged: ((Bool) -> Void)? {
        get { barView.onHoverChanged } set { barView.onHoverChanged = newValue }
    }
    var onDragBegan: ((Int, NSPoint) -> Void)? {
        get { barView.onDragBegan } set { barView.onDragBegan = newValue }
    }
    var onDragMoved: ((NSPoint) -> Void)? {
        get { barView.onDragMoved } set { barView.onDragMoved = newValue }
    }
    var onDragEnded: ((NSPoint) -> Void)? {
        get { barView.onDragEnded } set { barView.onDragEnded = newValue }
    }
    /// True while a tile drag is in flight. Freezes `pointerWatch` (so the drag's event
    /// stream isn't cut when the pointer leaves the band/screen) and keeps the window
    /// accepting mouse throughout.
    var dragActive = false {
        didSet {
            guard dragActive != oldValue else { return }
            if dragActive {
                ignoresMouseEvents = false
            }
        }
    }
    func setDragPresentation(_ p: SwitcherBarView.DragPresentation?) {
        barView.setDragPresentation(p)
    }
    /// This panel's ordered tiles (as last applied) — the coordinator reads them to build
    /// drag presentations for foreign panels without re-deriving from the model.
    var currentTiles: [SwitcherTile] { barView.tiles }

    // MARK: - Window→workspace drop targeting (global point = AppKit bottom-left, like mouseLocation)

    private func toLocal(_ global: NSPoint) -> NSPoint {
        NSPoint(x: global.x - frame.origin.x, y: global.y - frame.origin.y)
    }
    /// Tile index under a global point, or nil if not over a tile on this panel.
    func tileIndex(atGlobal global: NSPoint) -> Int? {
        let p = toLocal(global)
        return barView.layout.tileFrames.firstIndex { $0.contains(p) }
    }
    /// Is a global point inside this panel's band (where a tile click / reorder drag lives)?
    func isInBand(global: NSPoint) -> Bool {
        barView.layout.barRect.contains(toLocal(global))
    }
    /// Light up (or clear) the drop-target tile.
    func setDropHover(_ index: Int?) { barView.dropHoverIndex = index }

    /// Force pass-through immediately for a window-drop move's synthetic grab (so it lands on the
    /// window under the band, not the panel). `pointerWatch` keeps it this way while the move runs.
    func suppressMouseForMove() {
        ignoresMouseEvents = true
        barView.needsDisplay = true
    }

    init(screenFrame: NSRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = Self.hudLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // MC's band is the same light gray in both modes; light appearance pins the
        // material (and the labels stay explicit white, readable on it either way).
        appearance = NSAppearance(named: .aqua)
        container.frame = NSRect(origin: .zero, size: screenFrame.size)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.alphaValue = 0
        // Semi-transparent frost of whatever is on screen behind the panel. The real
        // Mission Control band is a DARK tint over the blur regardless of system
        // appearance; dark hudWindow matches it closest — measured over the same
        // wallpaper (172,156,125): native band (151,132,95), dark hudWindow
        // (140,127,100), vs dark fullScreenUI (128,116,91, too dark) and light
        // fullScreenUI (flat light gray, the pre-match look users flagged).
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.isHidden = !Self.showsBackdropPill
        container.addSubview(backdrop)
        barView.frame = container.bounds
        barView.autoresizingMask = [.width, .height]
        barView.wantsLayer = true
        container.addSubview(barView)
        contentView = container
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show (or refresh) the bar. `animated` fades in from hidden; an already-presented
    /// panel just redraws in place.
    func present(tiles: [SwitcherTile], topInset: CGFloat, animated: Bool) {
        apply(tiles: tiles, topInset: topInset)
        fadeGen += 1
        orderFrontRegardless()
        SwitcherStickySpace.park(self)
        if isPresented || !animated {
            container.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53)
                container.animator().alphaValue = 1
            }
        }
        isPresented = true
        startPointerWatch()
    }

    private func startPointerWatch() {
        guard pointerWatch == nil else { return }
        lastPointerLoc = NSEvent.mouseLocation
        pointerWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.dragActive { return }   // never flip mouse acceptance mid-drag
            // A window→workspace drop move re-grabs the window under the band with a synthetic
            // mouse-down; stay pass-through so that grab reaches the window, not this panel. Self-
            // restores on the next tick once the move ends.
            if WindowMover.standDownForMove {
                if !self.ignoresMouseEvents {
                    self.ignoresMouseEvents = true
                    self.barView.needsDisplay = true
                }
                return
            }
            let loc = NSEvent.mouseLocation
            let local = NSPoint(x: loc.x - self.frame.origin.x, y: loc.y - self.frame.origin.y)
            let inBand = self.barView.layout.barRect.contains(local)
            // Real movement over the band — not a cursor that merely rests there — engages the pin.
            if inBand, let last = self.lastPointerLoc, hypot(loc.x - last.x, loc.y - last.y) > 2 {
                self.onBandPointerMoved?()
            }
            self.lastPointerLoc = loc
            if self.ignoresMouseEvents == inBand {
                self.ignoresMouseEvents = !inBand
                self.barView.needsDisplay = true
            }
        }
    }

    private func stopPointerWatch() {
        pointerWatch?.invalidate()
        pointerWatch = nil
        lastPointerLoc = nil
        ignoresMouseEvents = true
    }

    /// Refresh contents without changing visibility. A changed tile SET (space added or
    /// removed) glides the row like Mission Control; content-only changes (highlight,
    /// names, wallpapers) crossfade.
    func refresh(tiles: [SwitcherTile], topInset: CGFloat) {
        guard isPresented else { return }
        // Order-sensitive: a reorder (same uuid set, different order) glides via the row
        // transition rather than crossfading.
        let rowChanged = !barView.tiles.isEmpty
            && barView.tiles.map(\.uuid) != tiles.map(\.uuid)
        if rowChanged {
            let oldTiles = barView.tiles
            let oldLayout = barView.layout
            apply(tiles: tiles, topInset: topInset)
            barView.beginRowTransition(oldTiles: oldTiles, oldLayout: oldLayout)
            return
        }
        if barView.layer != nil, barView.tiles != tiles {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.15
            barView.layer?.add(transition, forKey: "switcherRefresh")
        }
        apply(tiles: tiles, topInset: topInset)
    }

    /// Settle after a drag drop: swap straight to the reordered tiles with NO row
    /// transition or crossfade. During the drag the tiles were already reflowed into these
    /// exact slots, so a transition here would replay the whole move from the start.
    func applySettled(tiles: [SwitcherTile], topInset: CGFloat) {
        dragActive = false
        barView.setDragPresentation(nil)
        guard isPresented else { return }
        apply(tiles: tiles, topInset: topInset)
    }

    func dismissPanel(animated: Bool) {
        guard isPresented else { return }
        isPresented = false
        stopPointerWatch()
        fadeGen += 1
        let gen = fadeGen
        guard animated else {
            container.alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGen else { return }
            self.orderOut(nil)
        })
    }

    private func apply(tiles: [SwitcherTile], topInset: CGFloat) {
        let popover = Prefs.switcherPosition == .classicPopover
        let layout = SwitcherLayout.tiles(count: tiles.count,
                                          screenSize: container.bounds.size,
                                          topInset: topInset, popover: popover)
        barView.tiles = tiles
        barView.layout = layout
        backdrop.frame = layout.barRect
        // The popover is a free-floating rounded card; the top band runs edge to edge
        // into the screen corners and stays square.
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = popover ? SwitcherLayout.popoverCornerRadius : 0
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = popover
        barView.updateTrackingAreas()
        barView.needsDisplay = true
    }
}
