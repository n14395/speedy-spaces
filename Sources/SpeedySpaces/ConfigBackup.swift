import AppKit

/// Export/import of the user's full SpeedySpaces configuration:
///  - per-space names / icons / shortcuts (spaces.json), each annotated with display+ordinal
///    re-key hints so a restore can survive UUID churn across machines/reinstalls, and
///  - all preferences (the app's UserDefaults domain).
/// The wallpaper cache (wallpapers.json) is deliberately excluded — it's derived and
/// self-healing. A `schemaVersion` guards future format changes; none existed before.
enum ConfigBackup {
    static let schemaVersion = 1
    private static let defaultsDomain = "com.speedyspaces.SpeedySpaces"

    struct ImportSummary { var applied = 0; var remapped = 0; var unmatched = 0 }

    // MARK: - Export

    static func export(spaces: SpacesManager, store: MetadataStore) -> Data? {
        spaces.refresh()
        let live = spaces.spaces

        var spaceEntries: [[String: Any]] = []
        for (uuid, meta) in store.entries where !meta.isEmpty {
            var e: [String: Any] = ["uuid": uuid, "iconType": meta.iconType.rawValue]
            if let name = meta.name { e["name"] = name }
            if let v = meta.iconValue { e["iconValue"] = v }
            if let s = meta.shortcut {
                e["shortcut"] = ["keyCode": Int(s.keyCode), "modifiers": Int(bitPattern: s.modifiers)]
            }
            if let sp = live.first(where: { $0.uuid == uuid }) {
                e["displayIdentifier"] = sp.displayIdentifier
                e["ordinalOnDisplay"] = sp.ordinalOnDisplay
                e["title"] = sp.displayTitle(using: store)
            }
            spaceEntries.append(e)
        }

        // Only JSON-safe scalar prefs (strings/numbers/bools) — drops any framework-injected
        // blobs (e.g. saved window frames) so serialization can't fail, and skips the debug flag.
        var prefs: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
        where k != "hotkeyDebugLog" && (v is String || v is NSNumber) {
            prefs[k] = v
        }

        let root: [String: Any] = [
            "schemaVersion": schemaVersion,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "loginEnabled": LoginItem.isEnabled,
            "prefs": prefs,
            "spaces": spaceEntries,
        ]
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Import

    @discardableResult
    static func importConfig(from data: Data, spaces: SpacesManager, store: MetadataStore) -> ImportSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Preferences restore verbatim (keys are machine-independent). Same scalar filter as export.
        if let prefs = root["prefs"] as? [String: Any] {
            for (k, v) in prefs where k != "hotkeyDebugLog" && (v is String || v is NSNumber) {
                UserDefaults.standard.set(v, forKey: k)
            }
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
        if let login = root["loginEnabled"] as? Bool { _ = LoginItem.setEnabled(login) }

        // Per-space metadata: apply by uuid when the space still exists, else remap by
        // (displayIdentifier, ordinalOnDisplay), else keep under the original uuid.
        var summary = ImportSummary()
        var toApply: [String: SpaceMetadata] = [:]
        spaces.refresh()
        let live = spaces.spaces

        for e in (root["spaces"] as? [[String: Any]] ?? []) {
            guard let uuid = e["uuid"] as? String else { continue }
            var meta = SpaceMetadata()
            meta.name = e["name"] as? String
            meta.iconType = IconType(rawValue: e["iconType"] as? String ?? "none") ?? .none
            meta.iconValue = e["iconValue"] as? String
            if let s = e["shortcut"] as? [String: Any],
               let kc = s["keyCode"] as? Int, let mods = s["modifiers"] as? Int {
                meta.shortcut = ShortcutSpec(keyCode: UInt16(truncatingIfNeeded: kc),
                                             modifiers: UInt(bitPattern: mods))
            }
            if meta.isEmpty { continue }

            if live.contains(where: { $0.uuid == uuid }) {
                toApply[uuid] = meta; summary.applied += 1
            } else if let di = e["displayIdentifier"] as? String, let ord = e["ordinalOnDisplay"] as? Int,
                      let match = live.first(where: { $0.displayIdentifier == di && $0.ordinalOnDisplay == ord }) {
                toApply[match.uuid] = meta; summary.remapped += 1
            } else {
                toApply[uuid] = meta; summary.unmatched += 1
            }
        }
        store.merge(toApply)
        return summary
    }
}
