import AppKit

/// Per-space wallpaper source for the switcher HUD. Primary source is macOS's own
/// per-space wallpaper database (~/Library/Application Support/com.apple.wallpaper/Store/
/// Index.plist): its `Spaces` dict is keyed by space UUID, and each entry's
/// Choices[0].Configuration blob is a nested binary plist holding either an image file
/// URL or a catalog assetID whose still preview idleassetsd keeps on disk — so aerial
/// and built-in-catalog wallpapers resolve to a real image too.
///
/// Fallback is the older cache-on-visit strategy: `NSWorkspace.desktopImageURL` only
/// exposes the CURRENT space's wallpaper per display, so each visit records the mapping
/// (~/Library/Application Support/SpeedySpaces/wallpapers.json — a discardable cache,
/// deliberately separate from the user-intent data in spaces.json). Spaces neither in
/// the system store nor visited fall back to their display's current wallpaper, then a
/// flat gradient.
final class WallpaperStore {
    private(set) var paths: [String: String]
    private let fileURL: URL
    private let thumbnails = NSCache<NSString, NSImage>()
    private let loadQueue = DispatchQueue(label: "com.speedyspaces.wallpaper", qos: .utility)
    private var recordScheduled = false

    /// Redraw hook: fired on main after an async thumbnail load completes.
    var onThumbnailLoaded: (() -> Void)?

    init() {
        defer { WallpaperStoreHolder.shared = self }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedySpaces", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("wallpapers.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.paths = decoded
        } else {
            self.paths = [:]
        }
    }

    // MARK: - Recording (cache-on-visit)

    /// Record the current wallpaper of every display against that display's current space.
    /// Debounced 0.3 s: `refresh()` fires on every app activation, and right after a switch
    /// `desktopImageURL` can still report the outgoing space's image while the wallpaper
    /// agent settles.
    func scheduleRecord(spaces: @escaping () -> [Space]) {
        guard !recordScheduled else { return }
        recordScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.recordScheduled = false
            self.recordNow(spaces: spaces())
        }
    }

    func recordNow(spaces: [Space]) {
        let screens = NSScreen.screens.map { screen in
            (displayIDs: SwitcherHUD.displayIdentifiers(for: screen),
             wallpaperPath: NSWorkspace.shared.desktopImageURL(for: screen)?.path)
        }
        let new = Self.assignments(screens: screens, spaces: spaces)
        var changed = false
        for (uuid, path) in new where paths[uuid] != path {
            paths[uuid] = path
            changed = true
        }
        // Spaces that no longer exist keep stale entries out of the file.
        let live = Set(spaces.map(\.uuid))
        let dead = paths.keys.filter { !live.contains($0) }
        for key in dead {
            paths.removeValue(forKey: key)
            changed = true
        }
        if changed { save() }
    }

    /// Pure mapping decision: each display's current space gets that display's wallpaper path.
    static func assignments(screens: [(displayIDs: [String], wallpaperPath: String?)],
                            spaces: [Space]) -> [String: String] {
        var out: [String: String] = [:]
        for screen in screens {
            guard let path = screen.wallpaperPath else { continue }
            for space in spaces
            where space.isCurrent && screen.displayIDs.contains(space.displayIdentifier) {
                out[space.uuid] = path
            }
        }
        return out
    }

    // MARK: - System wallpaper store (per-space truth)

    private var systemPaths: [String: String] = [:]
    private var systemStoreMTime: Date?
    private static let systemStoreURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    static let snapshotsDir = "/Library/Application Support/com.apple.idleassetsd/snapshots"
    static let aerialThumbsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper/aerials/thumbnails").path

    /// Wallpaper image path for a space from the system store; reparses when the plist's
    /// mtime changes (wallpaper edits, new spaces), so queries between changes are a dict hit.
    private func systemPath(for uuid: String) -> String? {
        let mtime = (try? FileManager.default.attributesOfItem(
            atPath: Self.systemStoreURL.path)[.modificationDate]) as? Date
        if mtime != systemStoreMTime {
            systemStoreMTime = mtime
            systemPaths = Self.parseSystemStore(data: try? Data(contentsOf: Self.systemStoreURL))
        }
        return systemPaths[uuid]
    }

    /// uuid -> image path for every space entry that resolves to a file present on disk.
    static func parseSystemStore(data: Data?) -> [String: String] {
        guard let data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let spaces = root["Spaces"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (uuid, entry) in spaces {
            guard !uuid.isEmpty, let entry = entry as? [String: Any],
                  let path = resolveCandidates(spaceEntry: entry)
                    .first(where: { FileManager.default.fileExists(atPath: $0) })
            else { continue }
            out[uuid] = path
        }
        return out
    }

    /// Candidate image paths from one space's store entry, best first: the desktop
    /// (never Idle — that's the screensaver) choice, preferring the Default section over
    /// per-display overrides. "Linked" is the section name when desktop and screensaver
    /// are set as a pair. Existence is the caller's concern (keeps this pure for tests).
    static func resolveCandidates(spaceEntry: [String: Any]) -> [String] {
        var sections: [[String: Any]] = []
        if let d = spaceEntry["Default"] as? [String: Any] { sections.append(d) }
        if let displays = spaceEntry["Displays"] as? [String: Any] {
            sections.append(contentsOf: displays.values.compactMap { $0 as? [String: Any] })
        }
        var out: [String] = []
        for section in sections {
            for kind in ["Desktop", "Linked"] {
                guard let content = (section[kind] as? [String: Any])?["Content"]
                        as? [String: Any],
                      let choice = (content["Choices"] as? [Any])?.first as? [String: Any],
                      let blob = choice["Configuration"] as? Data,
                      let config = try? PropertyListSerialization.propertyList(
                        from: blob, format: nil) as? [String: Any]
                else { continue }
                out.append(contentsOf: candidatePaths(fromConfiguration: config))
            }
        }
        return out
    }

    /// Decoded Configuration blob -> candidate image paths, best first. Two known shapes:
    /// a direct image-file URL ({type: imageFile, url: {relative: file://...}}) and a
    /// catalog {assetID} (aerials, built-in stills) whose still preview lives in
    /// idleassetsd's snapshots dir or, for aerials it hasn't snapshotted, in
    /// com.apple.wallpaper's own per-user thumbnail cache.
    static func candidatePaths(fromConfiguration config: [String: Any]) -> [String] {
        if let urlDict = config["url"] as? [String: Any],
           let relative = urlDict["relative"] as? String,
           let url = URL(string: relative), url.isFileURL {
            return [url.path]
        }
        if let assetID = config["assetID"] as? String {
            return [snapshotsDir + "/asset-preview-\(assetID).jpg",
                    aerialThumbsDir + "/\(assetID).png"]
        }
        return []
    }

    // MARK: - Thumbnails

    /// Cached thumbnail for a space if already decoded; otherwise kicks off an async decode
    /// (`onThumbnailLoaded` fires when it lands) and returns nil for this pass.
    /// `fallbackPath` is the display's current wallpaper, used for spaces the system store
    /// doesn't cover and cache-on-visit hasn't seen.
    func thumbnail(for uuid: String, fallbackPath: String?, pixelSize: CGSize) -> NSImage? {
        var path = systemPath(for: uuid) ?? paths[uuid] ?? fallbackPath
        if let p = path, !FileManager.default.fileExists(atPath: p) {
            // Stale entry (user changed or removed the wallpaper file): self-heal.
            paths.removeValue(forKey: uuid)
            save()
            path = fallbackPath
        }
        guard let path else { return nil }
        let key = Self.cacheKey(path: path, pixelSize: pixelSize) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        loadQueue.async { [weak self] in
            guard let self, self.thumbnails.object(forKey: key) == nil else { return }
            guard let image = Self.decodeThumbnail(path: path, pixelSize: pixelSize) else { return }
            self.thumbnails.setObject(image, forKey: key)
            DispatchQueue.main.async { self.onThumbnailLoaded?() }
        }
        return nil
    }

    /// Downsampled decode via ImageIO — handles .heic (dynamic wallpapers: first
    /// representation wins) without loading full-resolution bitmaps.
    private static func decodeThumbnail(path: String, pixelSize: CGSize) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(pixelSize.width, pixelSize.height) * 2),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Bucket the size (64 px steps) so tiny layout jitter doesn't fragment the cache.
    static func cacheKey(path: String, pixelSize: CGSize) -> String {
        let bucket = Int((max(pixelSize.width, pixelSize.height) / 64).rounded(.up)) * 64
        return "\(path)|\(bucket)"
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(paths) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Self-tests

    static func selfChecks(_ check: SelfTest.Check) {
        func space(_ uuid: String, display: String, current: Bool, ordinal: Int = 0) -> Space {
            Space(uuid: uuid, managedSpaceID: 1, type: 0, displayIndex: 0,
                  displayIdentifier: display, ordinalOnDisplay: ordinal, isCurrent: current)
        }
        let spaces = [space("a", display: "D1", current: true),
                      space("b", display: "D1", current: false, ordinal: 1),
                      space("c", display: "Main", current: true)]
        let screens: [(displayIDs: [String], wallpaperPath: String?)] = [
            (["D1"], "/w/one.heic"),
            (["D2-uuid", "Main"], "/w/two.heic"),
        ]
        let map = assignments(screens: screens, spaces: spaces)
        check(map["a"] == "/w/one.heic", "wallpaper: current space gets display wallpaper")
        check(map["b"] == nil, "wallpaper: non-current space not recorded")
        check(map["c"] == "/w/two.heic", "wallpaper: Main identifier matches")
        check(assignments(screens: [(["D1"], nil)], spaces: spaces).isEmpty,
              "wallpaper: nil path records nothing")
        check(cacheKey(path: "/w/x", pixelSize: CGSize(width: 300, height: 200))
                == cacheKey(path: "/w/x", pixelSize: CGSize(width: 310, height: 200)),
              "wallpaper: cache key buckets nearby sizes")
        check(cacheKey(path: "/w/x", pixelSize: CGSize(width: 300, height: 200))
                != cacheKey(path: "/w/x", pixelSize: CGSize(width: 700, height: 500)),
              "wallpaper: cache key separates distant sizes")
        let crop = SwitcherBarView.aspectFillRect(imageSize: CGSize(width: 4000, height: 1000),
                                                  tileSize: CGSize(width: 160, height: 100))
        check(abs(crop.width / crop.height - 1.6) < 0.01, "wallpaper: crop rect matches tile aspect")
        check(crop.height == 1000 && crop.minY == 0, "wallpaper: crop uses full short axis")
        check(abs(crop.midX - 2000) < 0.5, "wallpaper: crop centered on long axis")
        check(SwitcherBarView.aspectFillRect(imageSize: .zero,
                                             tileSize: CGSize(width: 1, height: 1)) == .zero,
              "wallpaper: degenerate image -> zero rect")

        // System store parsing: entries mirror com.apple.wallpaper's Index.plist shape.
        func blob(_ config: [String: Any]) -> Data {
            (try? PropertyListSerialization.data(fromPropertyList: config,
                                                 format: .binary, options: 0)) ?? Data()
        }
        func entry(section: String, config: [String: Any]) -> [String: Any] {
            ["Default": [section: ["Content": ["Choices": [["Configuration": blob(config)]]]]]]
        }
        let imageEntry = entry(section: "Desktop",
                               config: ["type": "imageFile",
                                        "url": ["relative": "file:///w/pic%20one.png"]])
        check(resolveCandidates(spaceEntry: imageEntry) == ["/w/pic one.png"],
              "wallpaper: system store imageFile -> decoded file path")
        let aerialEntry = entry(section: "Linked", config: ["assetID": "ABC-123"])
        check(resolveCandidates(spaceEntry: aerialEntry)
                == [snapshotsDir + "/asset-preview-ABC-123.jpg",
                    aerialThumbsDir + "/ABC-123.png"],
              "wallpaper: system store assetID -> preview candidates, Linked section")
        check(resolveCandidates(spaceEntry: entry(section: "Idle",
                                                  config: ["assetID": "X"])).isEmpty,
              "wallpaper: Idle (screensaver) section ignored")
        check(resolveCandidates(spaceEntry: [:]).isEmpty, "wallpaper: empty entry -> none")
        check(candidatePaths(fromConfiguration: ["url": ["relative": "https://x/y.png"]])
                .isEmpty,
              "wallpaper: non-file URL rejected")
        let displaysOnly: [String: Any] =
            ["Displays": ["D-UUID": ["Desktop": ["Content":
                ["Choices": [["Configuration":
                    blob(["url": ["relative": "file:///w/two.png"]])]]]]]]]
        check(resolveCandidates(spaceEntry: displaysOnly) == ["/w/two.png"],
              "wallpaper: per-display section used when Default absent")
    }
}

enum WallpaperStoreHolder { static weak var shared: WallpaperStore? }
