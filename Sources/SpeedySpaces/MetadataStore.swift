// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Persists per-space names/icons as JSON in Application Support, keyed by space `uuid`.
/// Location: ~/Library/Application Support/SpeedySpaces/spaces.json
final class MetadataStore {
    private(set) var entries: [String: SpaceMetadata]
    private let fileURL: URL

    init() {
        defer { MetadataStoreHolder.shared = self }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedySpaces", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("spaces.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: SpaceMetadata].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    func metadata(for uuid: String) -> SpaceMetadata {
        entries[uuid] ?? .empty
    }

    func set(_ metadata: SpaceMetadata, for uuid: String) {
        if metadata.isEmpty {
            entries.removeValue(forKey: uuid)
        } else {
            entries[uuid] = metadata
        }
        save()
        NotificationCenter.default.post(name: .speedySpacesMetadataChanged, object: nil)
    }

    /// Bulk-apply imported metadata (incoming overrides existing) in one save + one
    /// notification — used by config import so a restore doesn't fan out dozens of writes.
    func merge(_ incoming: [String: SpaceMetadata]) {
        for (uuid, meta) in incoming {
            if meta.isEmpty { entries.removeValue(forKey: uuid) }
            else { entries[uuid] = meta }
        }
        save()
        NotificationCenter.default.post(name: .speedySpacesMetadataChanged, object: nil)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Weak global handle so shortcut-conflict assembly (Settings rows, space editor) can
/// see per-space bindings without threading the store through every initializer.
enum MetadataStoreHolder { static weak var shared: MetadataStore? }
