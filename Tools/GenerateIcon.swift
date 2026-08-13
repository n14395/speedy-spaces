// Renders SpeedySpaces's app icon programmatically and writes an .iconset of PNGs.
// Usage: swift GenerateIcon.swift <output-iconset-dir>
// Then: iconutil -c icns <output-iconset-dir> -o AppIcon.icns
import AppKit

func renderIcon(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Rounded-rect app-icon plate with a diagonal gradient.
    let inset = s * 0.08
    let plate = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = plate.width * 0.2237
    let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1), // indigo
        NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.92, alpha: 1), // violet
    ])!
    gradient.draw(in: platePath, angle: -60)

    // 2x2 grid of rounded "spaces"; the top-left one is highlighted (the active space).
    let gridInset = plate.width * 0.24
    let grid = plate.insetBy(dx: gridInset, dy: gridInset)
    let gap = grid.width * 0.10
    let cell = (grid.width - gap) / 2
    let cellRadius = cell * 0.26

    func cellRect(col: Int, row: Int) -> NSRect {
        NSRect(x: grid.minX + CGFloat(col) * (cell + gap),
               y: grid.minY + CGFloat(row) * (cell + gap),
               width: cell, height: cell)
    }

    for row in 0..<2 {
        for col in 0..<2 {
            let isActive = (col == 0 && row == 1) // top-left visually (flipped y)
            let r = cellRect(col: col, row: row)
            let p = NSBezierPath(roundedRect: r, xRadius: cellRadius, yRadius: cellRadius)
            NSColor(white: 1, alpha: isActive ? 1.0 : 0.45).setFill()
            p.fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let data = renderIcon(px: px)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
// Also drop a standalone preview for quick inspection.
try! renderIcon(px: 512).write(to: URL(fileURLWithPath: "\(outDir)/../icon-preview.png"))
print("Wrote \(variants.count) icon PNGs to \(outDir)")
