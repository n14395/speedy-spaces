import AppKit
import Carbon.HIToolbox

/// A recorded global-hotkey chord: virtual key code + sanitized modifier mask.
///
/// Canonical modifier storage is NSEvent's device-independent bits — shift (1<<17),
/// control (1<<18), option (1<<19), command (1<<20) — which happen to coincide with both
/// the com.apple.symbolichotkeys mod-mask bits (see SystemShortcuts.parseShortcut) and
/// the low CGEventFlags mask bits. Explicit converters are provided anyway so nothing
/// relies on that coincidence silently.
struct ShortcutSpec: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt        // sanitized NSEvent.ModifierFlags rawValue (only the 4 bits above)

    /// Sentinel keyCode for a chord that is modifiers alone (e.g. bare ⌃, or ⌃⌥⇧⌘) —
    /// no real virtual key code is ever 0xFFFF. Such chords can't go through Carbon
    /// RegisterEventHotKey; HotkeyManager watches flagsChanged for them instead.
    static let noKeyCode: UInt16 = .max

    var isModifierOnly: Bool { keyCode == ShortcutSpec.noKeyCode }

    static let allowedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Strip caps-lock, fn, numeric-pad, and device-dependent bits.
    static func sanitize(_ flags: NSEvent.ModifierFlags) -> UInt {
        flags.intersection(allowedModifiers).rawValue
    }
    static func sanitizeRaw(_ raw: UInt) -> UInt {
        sanitize(NSEvent.ModifierFlags(rawValue: raw))
    }

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = ShortcutSpec.sanitizeRaw(modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Carbon RegisterEventHotKey modifier mask (cmdKey 0x100, shiftKey 0x200,
    /// optionKey 0x800, controlKey 0x1000).
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// The same four modifiers as CGEventFlags, for comparison against symbolichotkeys
    /// bindings parsed by SystemShortcuts.
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        let ns = modifierFlags
        if ns.contains(.shift)   { flags.insert(.maskShift) }
        if ns.contains(.control) { flags.insert(.maskControl) }
        if ns.contains(.option)  { flags.insert(.maskAlternate) }
        if ns.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    // MARK: - Display formatting

    /// "⌃⌥⇧⌘X" — Apple's canonical modifier glyph order, then the key.
    var displayString: String {
        var out = ""
        let flags = modifierFlags
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        if isModifierOnly { return out }
        return out + ShortcutSpec.keyName(for: keyCode)
    }

    /// Special (layout-independent) keys first; then the current keyboard layout via
    /// UCKeyTranslate; then a static ANSI fallback.
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let translated = layoutKeyName(for: keyCode), !translated.isEmpty { return translated }
        return ansiFallbackNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Layout-independent keys, rendered the way menu items do.
    static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        71: "Clear",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
        87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
        65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /", 78: "Num -", 81: "Num =",
    ]

    /// Translate through the user's current keyboard layout (uppercased single character).
    private static func layoutKeyName(for keyCode: UInt16) -> String? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> String? in
            guard let layoutPtr = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let err = UCKeyTranslate(layoutPtr, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                     UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                     &deadKeyState, chars.count, &length, &chars)
            guard err == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).uppercased()
            // Control characters (e.g. for keys we should have caught in the special table)
            // are not displayable — treat as untranslatable.
            return s.unicodeScalars.allSatisfy { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 } ? s : nil
        }
    }

    /// US-ANSI names for when layout translation fails (pure — exercised by self-tests).
    static let ansiFallbackNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
}

/// Every app-wide action a global shortcut can trigger. `rawValue` is the stable
/// persistence id (Prefs keys derive from it) — never rename a case.
enum HotkeyAction: String, CaseIterable {
    case switchToSpace1, switchToSpace2, switchToSpace3, switchToSpace4, switchToSpace5
    case switchToSpace6, switchToSpace7, switchToSpace8, switchToSpace9, switchToSpace10
    case nextSpace, previousSpace
    case backAndForth
    case moveFollowToSpace1, moveFollowToSpace2, moveFollowToSpace3, moveFollowToSpace4
    case moveFollowToSpace5, moveFollowToSpace6, moveFollowToSpace7, moveFollowToSpace8
    case moveFollowToSpace9, moveFollowToSpace10
    case moveFollowToSpace11, moveFollowToSpace12
    case moveFollowNext, moveFollowPrev
    case moveDisplayNext, moveDisplayPrev
    case openMenu, openMissionControl, openSettings, renameCurrentSpace
    case holdSwitcher

    /// 1-based space number for the *ToSpaceN families; nil for the rest.
    var spaceNumber: Int? {
        for prefix in ["switchToSpace", "moveFollowToSpace"] {
            if rawValue.hasPrefix(prefix), let n = Int(rawValue.dropFirst(prefix.count)) {
                return n
            }
        }
        return nil
    }

    /// Settings-row title.
    var label: String {
        if let n = spaceNumber {
            if rawValue.hasPrefix("switchToSpace") { return "Switch to Space \(n)" }
            return "Move Window to Space \(n) and Follow"
        }
        switch self {
        case .nextSpace:          return "Next Space"
        case .previousSpace:      return "Previous Space"
        case .backAndForth:       return "Back and Forth (Last Space)"
        case .moveFollowNext:     return "Move Window to Next Space and Follow"
        case .moveFollowPrev:     return "Move Window to Previous Space and Follow"
        case .moveDisplayNext:    return "Move Window to Next Display"
        case .moveDisplayPrev:    return "Move Window to Previous Display"
        case .openMenu:           return "Open SpeedySpaces Menu"
        case .openMissionControl: return "Open Mission Control Workspace View"
        case .openSettings:       return "Open Settings"
        case .renameCurrentSpace: return "Rename Current Space"
        case .holdSwitcher:       return "Show Workspace Switcher When Holding"
        default:                  return rawValue
        }
    }

    /// The tiling-WM convention, shown as recorder placeholder text only — every
    /// binding ships unset.
    var placeholderSuggestion: String? {
        if let n = spaceNumber {
            // The digit row, continued onto - and = for Spaces 11 and 12.
            let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
            guard n >= 1, n <= keys.count else { return nil }
            let digit = keys[n - 1]
            if rawValue.hasPrefix("switchToSpace") { return "⌥\(digit)" }
            if rawValue.hasPrefix("moveFollowToSpace") { return "⌥⇧\(digit)" }
            return nil
        }
        switch self {
        case .backAndForth:    return "⌃⇥"
        case .moveDisplayNext: return "⌃⌥⇧→"
        case .moveDisplayPrev: return "⌃⌥⇧←"
        default: return nil
        }
    }
}

/// Record-time conflict detection: the app's own other bindings plus the user's enabled
/// macOS Mission Control shortcuts. Pure — assembled inputs, no domain reads.
enum ConflictChecker {
    struct Conflict: Equatable { let description: String }

    static func conflicts(_ spec: ShortcutSpec,
                          own: [(label: String, spec: ShortcutSpec)],
                          system: [(label: String, sc: SystemShortcuts.SpaceShortcut)]) -> [Conflict] {
        var found: [Conflict] = []
        for other in own where other.spec == spec {
            found.append(Conflict(description: "Also bound to “\(other.label)” in SpeedySpaces"))
        }
        for sys in system
        where CGKeyCode(spec.keyCode) == sys.sc.keyCode && spec.cgEventFlags == sys.sc.flags {
            found.append(Conflict(description: "macOS shortcut “\(sys.label)”"))
        }
        return found
    }

    // MARK: - Self-tests

    static func selfChecks(_ check: SelfTest.Check) {
        // ⌃3: symbolichotkeys mod mask for control is bit 18.
        let sysCtrl3 = SystemShortcuts.parseShortcut(
            ["enabled": true, "value": ["parameters": [51, 20, 1 << 18]]])!
        let ctrl3 = ShortcutSpec(keyCode: 20, modifiers: NSEvent.ModifierFlags.control.rawValue)
        let opt3 = ShortcutSpec(keyCode: 20, modifiers: NSEvent.ModifierFlags.option.rawValue)

        check(conflicts(ctrl3, own: [], system: [("Switch to Desktop 3", sysCtrl3)]).count == 1,
              "conflicts: ⌃3 collides with macOS ⌃3")
        check(conflicts(opt3, own: [], system: [("Switch to Desktop 3", sysCtrl3)]).isEmpty,
              "conflicts: ⌥3 clean against macOS ⌃3")
        check(conflicts(ctrl3, own: [("Next Space", ctrl3)], system: []).count == 1,
              "conflicts: own duplicate detected")
        check(conflicts(ctrl3, own: [("Previous Space", opt3)], system: []).isEmpty,
              "conflicts: different own binding is clean")
    }
}

// MARK: - ShortcutSpec self-tests

extension ShortcutSpec {
    static func selfChecks(_ check: SelfTest.Check) {
        let cmdShiftS = ShortcutSpec(
            keyCode: 1, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)

        // Codable round-trip, standalone and inside SpaceMetadata.
        if let data = try? JSONEncoder().encode(cmdShiftS),
           let back = try? JSONDecoder().decode(ShortcutSpec.self, from: data) {
            check(back == cmdShiftS, "shortcut: Codable round-trip")
        } else {
            check(false, "shortcut: Codable round-trip")
        }
        var meta = SpaceMetadata()
        meta.shortcut = cmdShiftS
        if let data = try? JSONEncoder().encode(meta),
           let back = try? JSONDecoder().decode(SpaceMetadata.self, from: data) {
            check(back.shortcut == cmdShiftS, "shortcut: survives SpaceMetadata round-trip")
        } else {
            check(false, "shortcut: survives SpaceMetadata round-trip")
        }
        let legacy = #"{"name":"Work","iconType":"none"}"#.data(using: .utf8)!
        check((try? JSONDecoder().decode(SpaceMetadata.self, from: legacy))?.shortcut == nil,
              "shortcut: legacy metadata JSON decodes with nil shortcut")
        check(meta.isEmpty == false && {
            var m = SpaceMetadata(); m.shortcut = cmdShiftS; return !m.isEmpty
        }(), "shortcut: shortcut-only metadata is not empty")

        // Modifier conversions.
        check(cmdShiftS.carbonModifiers == UInt32(cmdKey | shiftKey),
              "shortcut: ⌘⇧ -> Carbon cmdKey|shiftKey")
        check(ShortcutSpec(keyCode: 0, modifiers: NSEvent.ModifierFlags.control.rawValue)
                .carbonModifiers == UInt32(controlKey), "shortcut: ⌃ -> Carbon controlKey")
        check(ShortcutSpec(keyCode: 0, modifiers: NSEvent.ModifierFlags.option.rawValue)
                .carbonModifiers == UInt32(optionKey), "shortcut: ⌥ -> Carbon optionKey")
        let dirty = NSEvent.ModifierFlags([.command, .capsLock, .function, .numericPad]).rawValue
        check(ShortcutSpec(keyCode: 0, modifiers: dirty).modifierFlags == .command,
              "shortcut: sanitize strips capsLock/fn/numpad bits")

        // CGEventFlags parity with the symbolichotkeys parser for the same mask.
        let parsed = SystemShortcuts.parseShortcut(
            ["enabled": true, "value": ["parameters": [0, 5, (1 << 17) | (1 << 18)]]])!
        let spec = ShortcutSpec(keyCode: 5, modifiers: NSEvent.ModifierFlags([.shift, .control]).rawValue)
        check(spec.cgEventFlags == parsed.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]),
              "shortcut: CGEventFlags parity with parseShortcut")

        // Formatter.
        let all = ShortcutSpec(keyCode: 0, modifiers: ShortcutSpec.allowedModifiers.rawValue)
        check(all.displayString.hasPrefix("⌃⌥⇧⌘"), "shortcut: glyph order ⌃⌥⇧⌘")
        check(ShortcutSpec.specialKeyNames[96] == "F5", "shortcut: F5 name")
        check(ShortcutSpec(keyCode: 123, modifiers: NSEvent.ModifierFlags.control.rawValue)
                .displayString == "⌃←", "shortcut: ⌃← formats")
        check(ShortcutSpec(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue)
                .displayString == "⌥Space", "shortcut: ⌥Space formats")
        check(ShortcutSpec(keyCode: 48, modifiers: NSEvent.ModifierFlags.option.rawValue)
                .displayString == "⌥⇥", "shortcut: ⌥Tab formats")
        check(ShortcutSpec.ansiFallbackNames[0] == "A", "shortcut: ANSI fallback table")

        // Modifier-only chords (hold-to-show switcher).
        let ctrlOnly = ShortcutSpec(keyCode: ShortcutSpec.noKeyCode,
                                    modifiers: NSEvent.ModifierFlags.control.rawValue)
        check(ctrlOnly.isModifierOnly && ctrlOnly.displayString == "⌃",
              "shortcut: modifier-only ⌃ formats without a key name")
        let hyper = ShortcutSpec(keyCode: ShortcutSpec.noKeyCode,
                                 modifiers: ShortcutSpec.allowedModifiers.rawValue)
        check(hyper.displayString == "⌃⌥⇧⌘", "shortcut: modifier-only hyper formats")
        if let data = try? JSONEncoder().encode(ctrlOnly),
           let back = try? JSONDecoder().decode(ShortcutSpec.self, from: data) {
            check(back == ctrlOnly && back.isModifierOnly,
                  "shortcut: modifier-only Codable round-trip")
        } else {
            check(false, "shortcut: modifier-only Codable round-trip")
        }
        check(!cmdShiftS.isModifierOnly, "shortcut: keyed chord is not modifier-only")
    }
}

// MARK: - HotkeyAction self-tests

extension HotkeyAction {
    static func selfChecks(_ check: SelfTest.Check) {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        check(Set(ids).count == ids.count, "actions: rawValues unique")
        check(HotkeyAction.allCases.count == 34, "actions: case count stable (34)")
        // Persistence-id pin: renaming any case must fail this test.
        let pinned = [
            "switchToSpace1", "switchToSpace2", "switchToSpace3", "switchToSpace4",
            "switchToSpace5", "switchToSpace6", "switchToSpace7", "switchToSpace8",
            "switchToSpace9", "switchToSpace10",
            "nextSpace", "previousSpace", "backAndForth",
            "moveFollowToSpace1", "moveFollowToSpace2", "moveFollowToSpace3",
            "moveFollowToSpace4", "moveFollowToSpace5", "moveFollowToSpace6",
            "moveFollowToSpace7", "moveFollowToSpace8", "moveFollowToSpace9",
            "moveFollowToSpace10", "moveFollowToSpace11", "moveFollowToSpace12",
            "moveFollowNext", "moveFollowPrev",
            "moveDisplayNext", "moveDisplayPrev",
            "openMenu", "openMissionControl", "openSettings", "renameCurrentSpace",
            "holdSwitcher",
        ]
        check(ids == pinned, "actions: persistence ids pinned")
        check(HotkeyAction.switchToSpace7.spaceNumber == 7
                && HotkeyAction.moveFollowToSpace10.spaceNumber == 10
                && HotkeyAction.nextSpace.spaceNumber == nil,
              "actions: spaceNumber extraction")
        check(Prefs.hotkeyKeyCodeKey(for: .nextSpace) == "hotkey.nextSpace.keyCode",
              "actions: prefs key derivation")
        let labels = HotkeyAction.allCases.map(\.label)
        check(labels.allSatisfy { !$0.isEmpty }, "actions: labels non-empty")
        check(Set(labels).count == labels.count, "actions: labels unique")
        check(HotkeyAction.backAndForth.placeholderSuggestion == "⌃⇥",
              "actions: backAndForth placeholder is ⌃⇥")
        check(HotkeyAction.moveDisplayNext.placeholderSuggestion == "⌃⌥⇧→"
                && HotkeyAction.moveDisplayPrev.placeholderSuggestion == "⌃⌥⇧←",
              "actions: display-move placeholders are ⌃⌥⇧arrows")
        check(HotkeyAction.nextSpace.placeholderSuggestion == nil,
              "actions: unsuggested cases have no placeholder")
    }
}
