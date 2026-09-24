// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Watches the user's REAL macOS Spaces shortcuts (com.apple.symbolichotkeys ids 79/81 =
/// Move left/right a space, 118+ = Switch to Desktop N) and posts
/// `.speedySpacesNativeShortcutsChanged` whenever any of them change — whether the change came
/// from System Settings, another tool, or our own `SystemShortcuts.setBinding`.
///
/// There's no reliable public notification for symbolichotkeys edits, so this polls the
/// defaults domain on a light timer (reading a small plist is cheap) and fires only when a
/// relevant entry actually differs from the last snapshot. Consumers: `HotkeyManager`
/// (re-derives the "native switch chord + extra modifier" move chords) and the Settings
/// switching rows (re-read their displayed chord).
final class NativeShortcutsWatcher {
    static let shared = NativeShortcutsWatcher()

    /// The ids we mirror: Move-left/right-a-space (+ their ⇧ variants) and Switch-to-Desktop 1…16.
    private static let watchedIDs: [Int] = [79, 80, 81, 82] + Array(118...133)
    private static let interval: TimeInterval = 2.0

    private var timer: Timer?
    private var lastFingerprint = ""

    func start() {
        guard timer == nil else { return }
        lastFingerprint = Self.fingerprint()
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.5   // this is a background poll; let the OS coalesce it
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Force a snapshot refresh WITHOUT posting — call right after our own `setBinding` so the
    /// self-write isn't re-reported as an external change on the next tick (harmless if it is,
    /// but this keeps the notification meaning "something actually changed relative to us").
    func resync() {
        lastFingerprint = Self.fingerprint()
    }

    private func tick() {
        let fp = Self.fingerprint()
        guard fp != lastFingerprint else { return }
        lastFingerprint = fp
        NotificationCenter.default.post(name: .speedySpacesNativeShortcutsChanged, object: nil)
    }

    /// A cheap order-stable digest of the watched entries' enabled+parameters. Reads through
    /// `SystemShortcuts.readHotkeys()` (the same domain the rest of the app uses).
    private static func fingerprint() -> String {
        let hotkeys = SystemShortcuts.readHotkeys()
        var parts: [String] = []
        for id in watchedIDs {
            guard let entry = hotkeys[String(id)] as? [String: Any] else { parts.append("\(id):-"); continue }
            let enabled = (entry["enabled"] as? Bool) ?? true
            let params = ((entry["value"] as? [String: Any])?["parameters"] as? [Int]) ?? []
            parts.append("\(id):\(enabled ? 1 : 0):\(params.map(String.init).joined(separator: ","))")
        }
        return parts.joined(separator: "|")
    }
}
