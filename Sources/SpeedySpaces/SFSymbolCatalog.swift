// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The full SF Symbols collection for the pickers. There is no public API to enumerate
/// SF Symbols, but macOS ships its complete symbol database in the CoreGlyphs bundle
/// (the same data the system's own pickers use): canonical ordering, category
/// assignments, and search keywords. We read that at first use — every name in it
/// resolves on the running OS by construction. If the bundle ever moves or fails to
/// parse, we fall back to the curated subset below (validated name-by-name).
enum SFSymbolCatalog {

    static let allCategory = "All"

    private static let coreGlyphsResources = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Locale-specific variants (e.g. "character.book.closed.ar") are auto-substituted
    /// by the system per language — noise in a picker, so they're filtered out. These
    /// exact name components only ever appear as locale markers.
    private static let localeComponents: Set<Substring> = [
        "ar", "el", "he", "hi", "ja", "km", "ko", "my", "th", "zh", "rtl", "traditional",
    ]
    private static func isLocaleVariant(_ name: String) -> Bool {
        name.split(separator: ".").contains { localeComponents.contains($0) }
    }

    static func selfChecks(_ check: SelfTest.Check) {
        check(isLocaleVariant("character.book.closed.ar"), "symbols: locale suffix filtered")
        check(isLocaleVariant("list.bullet.rtl"), "symbols: rtl variant filtered")
        check(!isLocaleVariant("star.fill"), "symbols: plain name kept")
        check(!isLocaleVariant("theatermasks"), "symbols: single-component name kept")
        check(!isLocaleVariant("archivebox"), "symbols: locale string inside a component kept")
    }

    /// Meta-categories that aren't thematic groupings ("all" is added by us; the rest
    /// describe rendering capabilities or recency, not subject matter).
    private static let skippedCategoryKeys: Set<String> = ["all", "whatsnew", "variable", "multicolor"]

    /// Display labels for CoreGlyphs category keys; unknown future keys fall back to
    /// a capitalized key so new OS categories appear rather than vanish.
    private static let categoryLabels: [String: String] = [
        "communication": "Communication", "weather": "Weather", "maps": "Maps",
        "objectsandtools": "Objects & Tools", "devices": "Devices",
        "cameraandphotos": "Camera & Photos", "gaming": "Gaming",
        "connectivity": "Connectivity", "transportation": "Transportation",
        "automotive": "Automotive", "accessibility": "Accessibility",
        "privacyandsecurity": "Privacy & Security", "human": "People", "home": "Home",
        "fitness": "Fitness", "nature": "Nature", "editing": "Editing",
        "textformatting": "Text Formatting", "media": "Media", "keyboard": "Keyboard",
        "commerce": "Commerce", "time": "Time", "health": "Health", "shapes": "Shapes",
        "arrows": "Arrows", "indices": "Indices", "math": "Math", "draw": "Draw",
    ]

    /// (every symbol in canonical order, categories in system order). nil if the
    /// CoreGlyphs data can't be read.
    private static let systemCatalog: (all: [String], categorized: [(String, [String])])? = {
        guard let order = NSArray(contentsOf:
                coreGlyphsResources.appendingPathComponent("symbol_order.plist")) as? [String],
              let cats = NSArray(contentsOf:
                coreGlyphsResources.appendingPathComponent("categories.plist")) as? [[String: String]],
              let symCats = NSDictionary(contentsOf:
                coreGlyphsResources.appendingPathComponent("symbol_categories.plist")) as? [String: [String]]
        else { return nil }
        let names = order.filter { !isLocaleVariant($0) }
        var byKey: [String: [String]] = [:]
        for name in names {
            for key in symCats[name] ?? [] { byKey[key, default: []].append(name) }
        }
        var categorized: [(String, [String])] = []
        for cat in cats {
            guard let key = cat["key"], !skippedCategoryKeys.contains(key),
                  let symbols = byKey[key], !symbols.isEmpty else { continue }
            categorized.append((categoryLabels[key] ?? key.capitalized, symbols))
        }
        guard !names.isEmpty, !categorized.isEmpty else { return nil }
        return (names, categorized)
    }()

    /// Categories in system order (or the curated fallback's order). A symbol may
    /// appear in several categories, matching the system SF Symbols browser.
    static let categorized: [(name: String, symbols: [String])] = {
        if let sys = systemCatalog { return sys.categorized.map { (name: $0.0, symbols: $0.1) } }
        // Fallback: curated subset, validated against the running OS, de-duplicated.
        var seen = Set<String>()
        var out: [(String, [String])] = []
        for (name, symbols) in raw {
            let valid = symbols.filter { s in
                guard !seen.contains(s),
                      NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil
                else { return false }
                seen.insert(s)
                return true
            }
            if !valid.isEmpty { out.append((name, valid)) }
        }
        return out
    }()

    /// Every symbol, in the system's canonical browsing order.
    static let all: [String] = systemCatalog?.all ?? categorized.flatMap { $0.symbols }

    /// Ordered category names, prefixed with "All".
    static var categoryNames: [String] { [allCategory] + categorized.map { $0.name } }

    /// System search keywords per symbol (e.g. "dog" → pawprint), empty on fallback.
    private static let searchTerms: [String: [String]] = {
        (NSDictionary(contentsOf:
            coreGlyphsResources.appendingPathComponent("symbol_search.plist"))
            as? [String: [String]]) ?? [:]
    }()

    /// Case-insensitive search over names and the system's search keywords,
    /// optionally scoped to a category.
    static func search(_ query: String, category: String = allCategory) -> [String] {
        let pool: [String] = (category == allCategory)
            ? all
            : (categorized.first { $0.name == category }?.symbols ?? [])
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        return pool.filter { name in
            name.contains(q) || (searchTerms[name]?.contains { $0.contains(q) } ?? false)
        }
    }

    private static let raw: [(String, [String])] = [
        ("Favorites", [
            "star.fill", "star", "heart.fill", "heart", "bolt.fill", "bolt", "flame.fill",
            "sparkles", "crown.fill", "flag.fill", "flag", "bookmark.fill", "tag.fill",
            "pin.fill", "bell.fill", "sparkle", "seal.fill", "rosette", "medal.fill",
        ]),
        ("Work & Files", [
            "folder.fill", "folder", "folder.badge.plus", "doc.fill", "doc.text.fill",
            "doc.on.doc.fill", "tray.fill", "tray.2.fill", "archivebox.fill", "externaldrive.fill",
            "briefcase.fill", "case.fill", "book.fill", "books.vertical.fill", "text.book.closed.fill",
            "graduationcap.fill", "newspaper.fill", "list.bullet", "list.bullet.clipboard.fill",
            "checklist", "calendar", "clock.fill", "alarm.fill", "timer", "hourglass",
            "chart.bar.fill", "chart.pie.fill", "chart.line.uptrend.xyaxis", "printer.fill",
            "paperclip", "highlighter", "pencil", "pencil.and.ruler.fill", "ruler.fill",
        ]),
        ("Development", [
            "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
            "curlybraces.square.fill", "cpu.fill", "memorychip.fill", "internaldrive.fill",
            "server.rack", "network", "cloud.fill", "ladybug.fill", "hammer.fill",
            "wrench.and.screwdriver.fill", "gearshape.fill", "gearshape.2.fill", "gear",
            "keyboard.fill", "cursorarrow.rays", "command", "option", "cube.fill",
            "shippingbox.fill", "point.3.connected.trianglepath.dotted", "function",
        ]),
        ("Communication", [
            "envelope.fill", "envelope.open.fill", "paperplane.fill", "message.fill",
            "bubble.left.fill", "bubble.left.and.bubble.right.fill", "phone.fill",
            "phone.bubble.fill", "video.fill", "megaphone.fill", "at", "quote.bubble.fill",
        ]),
        ("Media", [
            "music.note", "music.note.list", "music.mic", "headphones", "mic.fill",
            "speaker.wave.2.fill", "play.fill", "pause.fill", "playpause.fill", "forward.fill",
            "film.fill", "photo.fill", "photo.stack.fill", "camera.fill", "tv.fill",
            "gamecontroller.fill", "guitars.fill", "pianokeys", "paintbrush.pointed.fill",
            "paintpalette.fill", "theatermasks.fill", "wand.and.stars",
        ]),
        ("Nature & Weather", [
            "sun.max.fill", "sun.horizon.fill", "moon.fill", "moon.stars.fill",
            "cloud.fill", "cloud.rain.fill", "cloud.bolt.fill", "snowflake", "wind",
            "leaf.fill", "tree.fill", "camera.macro", "drop.fill", "tortoise.fill",
            "hare.fill", "pawprint.fill", "fish.fill", "bird.fill", "ant.fill", "ladybug.fill",
        ]),
        ("People & Home", [
            "person.fill", "person.2.fill", "person.3.fill", "person.crop.circle.fill",
            "figure.walk", "figure.run", "figure.2.and.child.holdinghands",
            "house.fill", "building.2.fill", "building.columns.fill", "bed.double.fill",
            "sofa.fill", "lamp.desk.fill", "fork.knife", "cup.and.saucer.fill",
            "wineglass.fill", "cart.fill", "bag.fill", "creditcard.fill",
            "dollarsign.circle.fill", "gift.fill", "balloon.fill",
        ]),
        ("Travel", [
            "car.fill", "bus.fill", "tram.fill", "airplane", "airplane.departure",
            "bicycle", "scooter", "sailboat.fill", "map.fill", "location.fill",
            "globe", "globe.americas.fill", "beach.umbrella.fill", "mountain.2.fill",
            "tent.fill", "suitcase.fill", "fuelpump.fill", "signpost.right.fill",
        ]),
        ("Health & Objects", [
            "cross.case.fill", "pills.fill", "bandage.fill", "dumbbell.fill",
            "brain.head.profile", "lightbulb.fill", "key.fill", "lock.fill",
            "lock.open.fill", "shield.fill", "eye.fill", "hand.raised.fill",
            "trash.fill", "battery.100", "wifi", "bolt.horizontal.fill", "powerplug.fill",
            "scissors", "paintbrush.fill", "eyedropper.halffull",
        ]),
        ("Shapes & Symbols", [
            "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill",
            "pentagon.fill", "octagon.fill", "app.fill", "square.grid.2x2.fill",
            "square.grid.3x3.fill", "square.stack.3d.up.fill", "rectangle.3.group.fill",
            "number", "asterisk", "questionmark.circle.fill", "exclamationmark.triangle.fill",
            "checkmark.circle.fill", "xmark.circle.fill", "plus.circle.fill",
            "minus.circle.fill", "infinity", "circle.hexagongrid.fill", "atom",
        ]),
        ("Numbers", [
            "1.circle.fill", "2.circle.fill", "3.circle.fill", "4.circle.fill", "5.circle.fill",
            "6.circle.fill", "7.circle.fill", "8.circle.fill", "9.circle.fill", "0.circle.fill",
            "1.square.fill", "2.square.fill", "3.square.fill", "4.square.fill", "5.square.fill",
            "6.square.fill", "7.square.fill", "8.square.fill", "9.square.fill",
        ]),
    ]
}
