import AppKit

/// Reader for the user's REAL Mission Control keyboard shortcuts, from the
/// com.apple.symbolichotkeys defaults domain. Consumed by the conflict checker
/// (warning when a recorded chord collides with a system one) and by the switcher
/// HUD's native-switch detection (recognizing ⌃N / ⌃-arrow presses as they happen).
///
/// This began life as the "Keyboard shortcut" switch engine, which REPLAYED these
/// chords as synthetic key events; macOS 27 drops synthetic keyboard events
/// system-wide, so the engine was removed and only the parsing survives.
enum SystemShortcuts {
    struct SpaceShortcut { let keyCode: CGKeyCode; let flags: CGEventFlags }

    // Symbolic-hotkey IDs (com.apple.symbolichotkeys): 118..133 = Switch to Desktop 1..16,
    // 79 = Move left a space, 81 = Move right a space, 32 = Mission Control.
    static let desktopBaseID = 118
    static let maxSwitchableDesktop = 16
    static let moveLeftID = 79
    static let moveRightID = 81
    static let missionControlID = 32

    static let domainName = "com.apple.symbolichotkeys"

    /// The raw AppleSymbolicHotKeys table (id-string -> entry dict).
    static func readHotkeys() -> [String: Any] {
        (UserDefaults.standard.persistentDomain(forName: domainName)?["AppleSymbolicHotKeys"]
            as? [String: Any]) ?? [:]
    }

    /// One raw entry, or nil when the domain has never customized this id (which means
    /// the OS's built-in default applies — distinct from an entry with enabled=false).
    static func domainEntry(id: Int) -> [String: Any]? {
        readHotkeys()[String(id)] as? [String: Any]
    }

    /// Read one of the user's real Mission Control bindings from the symbolichotkeys
    /// domain (nil if disabled or unset).
    static func systemBinding(id: Int) -> SpaceShortcut? {
        domainEntry(id: id).flatMap(parseShortcut)
    }

    /// Every enabled macOS Mission Control shortcut, labeled for conflict warnings.
    /// ⌃←/⌃→ fall back to their defaults only when the domain has NO entry (they ship
    /// enabled); an entry with enabled=false means the user (or our Disable Native
    /// Shortcuts button) turned them off, so they must not resurface as defaults.
    static func missionControlBindings() -> [(label: String, sc: SpaceShortcut)] {
        var out: [(String, SpaceShortcut)] = []
        for n in 1...maxSwitchableDesktop {
            if let sc = systemBinding(id: desktopBaseID + n - 1) {
                out.append(("Switch to Desktop \(n)", sc))
            }
        }
        for (label, id, defaultKeyCode) in [("Move left a space", moveLeftID, CGKeyCode(123)),
                                            ("Move right a space", moveRightID, CGKeyCode(124))] {
            if let entry = domainEntry(id: id) {
                if let sc = parseShortcut(entry) { out.append((label, sc)) }
            } else {
                out.append((label, SpaceShortcut(keyCode: defaultKeyCode, flags: .maskControl)))
            }
        }
        if let mc = systemBinding(id: missionControlID) {
            out.append(("Mission Control", mc))
        }
        return out
    }

    /// Parse one AppleSymbolicHotKeys entry into a shortcut, or nil if disabled
    /// or lacking a usable virtual key code. `parameters = [asciiChar, virtualKeyCode, modMask]`.
    static func parseShortcut(_ entry: [String: Any]) -> SpaceShortcut? {
        guard let enabled = entry["enabled"] as? Bool, enabled,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count >= 3 else { return nil }
        let vk = params[1]
        guard vk >= 0 && vk < 0xFFFF else { return nil }   // 65535 == "no key code"
        let modRaw = params[2]
        var flags: CGEventFlags = []
        if modRaw & (1 << 17) != 0 { flags.insert(.maskShift) }
        if modRaw & (1 << 18) != 0 { flags.insert(.maskControl) }
        if modRaw & (1 << 19) != 0 { flags.insert(.maskAlternate) }
        if modRaw & (1 << 20) != 0 { flags.insert(.maskCommand) }
        return SpaceShortcut(keyCode: CGKeyCode(vk), flags: flags)
    }

    // MARK: - Reading / writing the native Spaces bindings
    //
    // Two-way binding: the Settings switching rows read a symbolic hotkey (systemBinding)
    // and write it back with `setBinding`, which updates BOTH the live window-server table
    // (sm_symbolicHotKey*, immediate) and the com.apple.symbolichotkeys plist (persists
    // across login and keeps System Settings' checkboxes truthful).

    struct DefaultChord { let keyChar: Int; let keyCode: Int; let mods: Int }

    /// Factory-default chord for a Spaces hotkey (nil = no factory chord: desktops 11+).
    /// parameters layout matches the plist: [unicode char (65535 = none), virtual key, mods].
    static func defaultChord(id: Int) -> DefaultChord? {
        let ctrl = 1 << 18, shift = 1 << 17
        let fn = 1 << 23   // NX function-key bit — arrow-key chords carry it (0x840000 = ⌃←)
        switch id {
        case moveLeftID:      return DefaultChord(keyChar: 65535, keyCode: 123, mods: ctrl | fn)
        case moveLeftID + 1:  return DefaultChord(keyChar: 65535, keyCode: 123, mods: ctrl | shift | fn)
        case moveRightID:     return DefaultChord(keyChar: 65535, keyCode: 124, mods: ctrl | fn)
        case moveRightID + 1: return DefaultChord(keyChar: 65535, keyCode: 124, mods: ctrl | shift | fn)
        case desktopBaseID...(desktopBaseID + 11):
            // ⌃1..⌃9, ⌃0, then ⌃- and ⌃= for Desktops 11 and 12 — carrying macOS's own
            // digit-row run onto the two keys that continue that row past "0". macOS itself
            // assigns no chord beyond Desktop 10 (see seedExtraDesktopChordsIfNeeded).
            // (ascii char, ANSI virtual key).
            let keys: [(char: Int, vk: Int)] = [(49, 18), (50, 19), (51, 20), (52, 21), (53, 23),
                                                (54, 22), (55, 26), (56, 28), (57, 25), (48, 29),
                                                (45, 27), (61, 24)]
            let d = keys[id - desktopBaseID]
            return DefaultChord(keyChar: d.char, keyCode: d.vk, mods: ctrl)
        default: return nil
        }
    }

    private static func defaultEntry(id: Int) -> [String: Any]? {
        guard let d = defaultChord(id: id) else { return nil }
        return ["enabled": true,
                "value": ["type": "standard", "parameters": [d.keyChar, d.keyCode, d.mods]]]
    }

    private static func writeHotkeys(_ hotkeys: [String: Any]) {
        var domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        domain["AppleSymbolicHotKeys"] = hotkeys
        UserDefaults.standard.setPersistentDomain(domain, forName: domainName)
    }

    /// Push one id's plist entry (nil = factory default) into the live table.
    private static func applyLive(id: Int, entry: [String: Any]?) {
        guard let entry else {
            if let d = defaultChord(id: id) {
                _ = sm_symbolicHotKeySetValue(Int32(id), UInt16(truncatingIfNeeded: d.keyChar),
                                              UInt16(d.keyCode), UInt32(d.mods))
            }
            _ = sm_symbolicHotKeySetEnabled(Int32(id), true)
            return
        }
        let enabled = (entry["enabled"] as? Bool) ?? true
        if enabled,
           let value = entry["value"] as? [String: Any],
           let p = value["parameters"] as? [Int], p.count >= 3, p[1] >= 0, p[1] < 0xFFFF {
            _ = sm_symbolicHotKeySetValue(Int32(id), UInt16(truncatingIfNeeded: p[0]),
                                          UInt16(p[1]), UInt32(truncatingIfNeeded: p[2]))
        }
        _ = sm_symbolicHotKeySetEnabled(Int32(id), enabled)
    }

    /// The plist mod-mask for a shortcut, preserving the fn bit for the arrow-key
    /// Move-a-space ids (their native chords carry it: ⌃← = 0x840000).
    static func plistModifiers(_ sc: SpaceShortcut, id: Int) -> Int {
        var m = 0
        if sc.flags.contains(.maskShift)     { m |= 1 << 17 }
        if sc.flags.contains(.maskControl)   { m |= 1 << 18 }
        if sc.flags.contains(.maskAlternate) { m |= 1 << 19 }
        if sc.flags.contains(.maskCommand)   { m |= 1 << 20 }
        if [moveLeftID, moveLeftID + 1, moveRightID, moveRightID + 1].contains(id) { m |= 1 << 23 }
        return m
    }

    /// The ASCII char macOS stores for a key (letters/digits), or 65535 for keys without
    /// one (arrows/function keys). Mirrors what System Settings writes into `parameters[0]`.
    static func plistKeyChar(_ keyCode: UInt16) -> Int {
        let name = ShortcutSpec.keyName(for: keyCode)
        guard name.count == 1, let scalar = name.lowercased().unicodeScalars.first, scalar.isASCII
        else { return 65535 }
        return Int(scalar.value)
    }

    /// Write one symbolic-hotkey id's binding, live + persisted. `nil` disables the id
    /// (keeping its chord, like unchecking it in System Settings). This is the two-way
    /// "write" path the Settings switching rows use to edit the user's real macOS shortcuts.
    static func setBinding(id: Int, _ sc: SpaceShortcut?) {
        var hotkeys = readHotkeys()
        let key = String(id)
        if let sc {
            let entry: [String: Any] = [
                "enabled": true,
                "value": ["type": "standard",
                          "parameters": [plistKeyChar(sc.keyCode), Int(sc.keyCode),
                                         plistModifiers(sc, id: id)]]]
            hotkeys[key] = entry
            writeHotkeys(hotkeys)
            applyLive(id: id, entry: entry)
        } else {
            var entry = (hotkeys[key] as? [String: Any]) ?? defaultEntry(id: id) ?? [:]
            entry["enabled"] = false
            hotkeys[key] = entry
            writeHotkeys(hotkeys)
            _ = sm_symbolicHotKeySetEnabled(Int32(id), false)
        }
    }

    /// The switching symbolic-hotkey ids the Global Modifier governs, each paired with the
    /// natural key its auto-assignment uses: Switch-to-Desktop 1…12 (digit row, then - and =)
    /// + Move-right/left (→ / ←). Order matches the Settings rows (Space 1…12, then Next,
    /// then Previous).
    static var switchingIDKeys: [(id: Int, keyCode: UInt16)] {
        var out: [(Int, UInt16)] = (0..<12).map {
            (desktopBaseID + $0, UInt16(defaultChord(id: desktopBaseID + $0)?.keyCode ?? 0))
        }
        out += [(moveRightID, 124), (moveLeftID, 123)]   // Next → , Previous ←
        return out
    }

    /// A displayable derived chord for a switching id under the Global Modifier (mods + its key).
    static func globalSwitchSpec(id: Int, modifiers: UInt) -> ShortcutSpec? {
        guard let kc = switchingIDKeys.first(where: { $0.id == id })?.keyCode else { return nil }
        return ShortcutSpec(keyCode: kc, modifiers: modifiers)
    }

    /// Write the Global Modifier assignment (modifiers + each switching id's natural key) into every
    /// switching symbolic hotkey, live + persisted. Used when the toggle turns on or the modifier changes.
    static func applyGlobalModifierToNative(_ modifiers: UInt) {
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        for (id, keyCode) in switchingIDKeys {
            setBinding(id: id, SpaceShortcut(keyCode: keyCode, flags: flags))
        }
    }

    /// One-time migration: an earlier version's "Disable Native Shortcuts" toggle turned the
    /// system Spaces shortcuts off (flipping `enabled` false, keeping the chord). That feature is
    /// gone and switching now BINDS to these shortcuts, so re-enable in place any of 79-82 /
    /// 118-133 that were left disabled — restoring the user's switching without touching chords
    /// or the entries they genuinely removed. Live + persisted.
    static func reenableSpacesSet() {
        let ids = [79, 80, 81, 82] + Array(118...133)
        var hotkeys = readHotkeys()
        var changed = false
        for id in ids {
            let key = String(id)
            guard var entry = hotkeys[key] as? [String: Any],
                  (entry["enabled"] as? Bool) == false else { continue }
            entry["enabled"] = true
            hotkeys[key] = entry
            applyLive(id: id, entry: entry)
            changed = true
        }
        if changed { writeHotkeys(hotkeys) }
    }

    /// macOS ships Desktops 11-16 as symbolic-hotkey entries that are *enabled but chordless*
    /// (only 1…10 get ⌃1…⌃0), so Space 11/12 would show an empty row and their keys would do
    /// nothing. Write the factory ⌃- / ⌃= once — and only where there is no chord at all, so a
    /// chord the user set themselves is never clobbered. One-time, like `reenableSpacesSet`.
    static func seedExtraDesktopChordsIfNeeded() {
        let flag = "didSeedDesktop11And12Chords"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        var hotkeys = readHotkeys()
        var changed = false
        for n in 11...12 {
            let id = desktopBaseID + n - 1
            // Test for `parameters` rather than parseShortcut: that returns nil for a *disabled*
            // entry too, and a disabled entry still carries a chord we must not overwrite.
            let value = domainEntry(id: id)?["value"] as? [String: Any]
            guard (value?["parameters"] as? [Int]) == nil, let entry = defaultEntry(id: id)
            else { continue }
            hotkeys[String(id)] = entry
            applyLive(id: id, entry: entry)
            changed = true
        }
        if changed { writeHotkeys(hotkeys) }
    }

    static func selfChecks(_ check: SelfTest.Check) {
        let enabled: [String: Any] = ["enabled": true, "value": ["parameters": [50, 19, 262144]]]
        let parsed = parseShortcut(enabled)
        check(parsed?.keyCode == 19 && parsed?.flags.contains(.maskControl) == true,
              "systemShortcuts: parse enabled ⌃-keycode19")
        check(parseShortcut(["enabled": false, "value": ["parameters": [50, 19, 262144]]]) == nil,
              "systemShortcuts: disabled -> nil")
        check(parseShortcut(["enabled": true, "value": ["parameters": [49, 65535, 262144]]]) == nil,
              "systemShortcuts: no-keycode (65535) -> nil")

        // Native-write helpers (pure).
        check(plistModifiers(SpaceShortcut(keyCode: 124, flags: .maskControl), id: moveRightID) == 0x840000,
              "systemShortcuts: arrow move-a-space chord carries ctrl + fn")
        check(plistModifiers(SpaceShortcut(keyCode: 18, flags: .maskControl), id: desktopBaseID) == 0x40000,
              "systemShortcuts: desktop-switch chord has no fn bit")
        check(plistKeyChar(123) == 65535, "systemShortcuts: arrow key has no ascii char")

        check(defaultChord(id: moveLeftID)?.keyCode == 123
                && defaultChord(id: moveLeftID)?.mods == 0x840000,
              "systemShortcuts: default ⌃← chord (ctrl + fn bit, matching the live table)")
        check(defaultChord(id: 80)?.mods == 0x860000,
              "systemShortcuts: ⇧-variant default carries shift")
        check(defaultChord(id: desktopBaseID)?.keyCode == 18
                && defaultChord(id: desktopBaseID + 9)?.keyCode == 29,
              "systemShortcuts: desktop 1/10 default key codes")
        check(defaultChord(id: desktopBaseID + 10) == nil,
              "systemShortcuts: desktops 11+ have no factory chord")
    }
}
