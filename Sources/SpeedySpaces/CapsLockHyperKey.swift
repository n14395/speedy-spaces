import AppKit
import Carbon.HIToolbox

/// Caps Lock → a configurable modifier set while held (Settings: "Map Caps Lock to:",
/// default ⌘⌥⌃ — the "hyper key"), like Karabiner-Elements' classic
/// caps_lock-to-modifiers complex modification. Any modifier left OUT of the mapping
/// layers on top physically — with the default, Caps Lock+K and Caps Lock+⇧+K are two
/// distinct shortcuts. Karabiner does its version by seizing the
/// physical keyboard and re-posting every event through a DriverKit virtual HID
/// device (a system extension plus Input Monitoring). Two much lighter pieces give
/// the same result for this one key:
///
///  1. A HID-driver-level remap of Caps Lock onto F18 (`hidutil` UserKeyMapping).
///     Rewriting at the driver kills caps-lock behaviour at the source — no toggle,
///     no LED, no press-and-hold engage delay — and no physical keyboard has an F18
///     key to collide with.
///  2. An active session event tap (same permission model as the HUD's native-switch
///     tap) that swallows F18 down/up and, while it is held, ORs the mapping into the flags
///     of every other key event. Only key events are rewritten — never flagsChanged —
///     so the tap can't wedge the session's sticky modifier STATE: if the tap dies
///     mid-hold, the next keypress simply arrives unmodified.
///
/// Ordering matters: the remap is applied only once the modifying tap is actually
/// installed (needs Accessibility) — remapped without the tap, Caps Lock would just be
/// a dead F18 key. The mapping is removed on disable and on normal quit, and does not
/// survive reboots; the launch-time apply() restores it. Existing UserKeyMapping
/// entries from other tools are preserved on both paths.
final class CapsLockHyper {

    static let capsLockUsage: UInt64 = 0x7_0000_0039
    static let f18Usage: UInt64 = 0x7_0000_006D
    static let f18KeyCode: Int64 = Int64(kVK_F18)
    /// The configured mapping as event flags (pure; NSEvent and CGEventFlags bits
    /// coincide for ⌘⌥⌃⇧, and the mapping is sanitized to those four).
    static func flags(fromMapping mapping: UInt) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(ShortcutSpec.sanitizeRaw(mapping)))
    }
    /// The mapping as NSEvent/ShortcutSpec modifier bits (recorders fold this in when
    /// the caps layer engages).
    static var hyperNSModifiers: UInt { ShortcutSpec.sanitizeRaw(Prefs.capsLockMapping) }

    /// Live hyper-hold state, readable by chord matchers: the caps layer contributes
    /// modifiers without ever emitting a flagsChanged, so anything that evaluates
    /// modifier state from events (hold-to-show chord, HUD safety poll) must OR
    /// `hyperNSModifiers` in while this is true. Written on the tap thread, read
    /// from anywhere — lock-guarded.
    private static let hyperState = Locked(false)
    static var isHyperDown: Bool { hyperState.get() }

    private var tap: CFMachPort?
    /// The live tap, mirrored for the tap-thread callback (which must not race the
    /// main-thread install/remove paths on the plain `tap` property).
    private let tapRef = Locked<CFMachPort?>(nil)
    private let reviver = TapReviver("capsHyper")
    /// Flags injected while caps is held — refreshed from Prefs in apply(), read on
    /// the tap thread.
    private let mappingFlags = Locked<CGEventFlags>([])
    private var tapSource: CFRunLoopSource?
    /// Direction of the last UserKeyMapping sync, so repeated prefs notifications
    /// (sliders tick per pixel) don't re-run hidutil.
    private var syncedEnabled: Bool?
    private var warnedNoAX = false
    /// Serial: keeps an enable-then-disable toggle burst ordered.
    private let hidQueue = DispatchQueue(label: "com.speedyspaces.capshyper.hidutil")

    /// Converge on the pref. Called at launch and on every prefs change; idempotent.
    func apply() {
        mappingFlags.set(Self.flags(fromMapping: Prefs.capsLockMapping))
        if Prefs.capsLockHyperKey { activate() } else { deactivate() }
    }

    private func activate() {
        installTap()
        guard tap != nil else {
            if !warnedNoAX {
                warnedNoAX = true
                HotkeyDiag.log("capsHyper: no Accessibility — Caps Lock left untouched")
            }
            return
        }
        guard syncedEnabled != true else { return }
        syncedEnabled = true
        hidQueue.async { Self.syncMapping(enabled: true) }
    }

    /// Also the quit path (applicationWillTerminate) — synchronous so the mapping is
    /// gone before the process (and with it the F18 tap) is. A force-killed instance
    /// skips this; the next launch's apply() re-converges either way.
    func deactivate() {
        removeTap()
        guard syncedEnabled != false else { return }
        syncedEnabled = false
        hidQueue.sync { Self.syncMapping(enabled: false) }
    }

    // MARK: - Event tap

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }  // must modify; listen-only is useless here
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        // Runs on the TAP THREAD: pure event math against lock-guarded state, nothing
        // that can block — the verdict gates keyboard delivery for the whole session.
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<CapsLockHyper>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                CapsLockHyper.hyperState.set(false)  // never leave hyper latched across a tap reset
                if let tap = me.tapRef.get() { me.reviver.tapWasDisabled(tap) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventKeycode) == CapsLockHyper.f18KeyCode {
                let down = (type == .keyDown)
                let changed = CapsLockHyper.hyperState.withLock { state -> Bool in
                    guard state != down else { return false }   // keyDown repeats while held
                    state = down
                    return true
                }
                if changed {
                    // Caps-as-hyper never emits a flagsChanged (it rewrites key events
                    // only), so shortcut recorders can't observe it as a modifier —
                    // tell them in-process instead, on main where they live.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .speedySpacesHyperKeyChanged,
                                                        object: nil, userInfo: ["down": down])
                    }
                }
                return nil  // the remapped Caps Lock never reaches apps as F18
            }
            if CapsLockHyper.hyperState.get() {
                event.flags = event.flags.union(me.mappingFlags.get())
            }
            return Unmanaged.passUnretained(event)
        }
        guard let made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: info) else {
            HotkeyDiag.log("capsHyper: tap creation failed")
            return
        }
        tap = made
        tapRef.set(made)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, made, 0)
        TapThread.add(src)
        tapSource = src
        HotkeyDiag.log("capsHyper: tap installed")
    }

    private func removeTap() {
        Self.hyperState.set(false)
        tapRef.set(nil)
        TapTeardown.tearDown(tap: tap, source: tapSource)
        tapSource = nil
        tap = nil
    }

    // MARK: - hidutil UserKeyMapping

    struct Mapping: Equatable {
        var src: UInt64
        var dst: UInt64
    }

    /// Read-merge-write of the system UserKeyMapping. Skips the write when the current
    /// mapping already matches, so launches are quiet when nothing changed.
    private static func syncMapping(enabled: Bool) {
        let current = parseMappings(hidutil(["property", "--get", "UserKeyMapping"]) ?? "")
        let wanted = enabled ? mappings(enablingIn: current) : mappings(disablingIn: current)
        guard wanted != current else { return }
        _ = hidutil(["property", "--set", mappingJSON(wanted)])
        HotkeyDiag.log("capsHyper: UserKeyMapping -> \(wanted.count) entrie(s), hyper \(enabled ? "on" : "off")")
    }

    private static func hidutil(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// `hidutil property --get UserKeyMapping` prints an old-style plist —
    /// `( { HIDKeyboardModifierMappingDst = N; HIDKeyboardModifierMappingSrc = N; }, … )`
    /// — or `(null)` when unset. Pull the Src/Dst decimal pairs out of each `{…}` block.
    static func parseMappings(_ text: String) -> [Mapping] {
        var out: [Mapping] = []
        for block in text.components(separatedBy: "}") {
            func value(_ key: String) -> UInt64? {
                guard let r = block.range(of: key) else { return nil }
                let digits = block[r.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
                return UInt64(digits)
            }
            if let src = value("HIDKeyboardModifierMappingSrc"),
               let dst = value("HIDKeyboardModifierMappingDst") {
                out.append(Mapping(src: src, dst: dst))
            }
        }
        return out
    }

    /// Stable when our mapping is already the only Caps Lock entry; otherwise replaces
    /// any stale Caps Lock mapping and keeps everything else.
    static func mappings(enablingIn current: [Mapping]) -> [Mapping] {
        let ours = Mapping(src: capsLockUsage, dst: f18Usage)
        if current.filter({ $0.src == capsLockUsage }) == [ours] { return current }
        return current.filter { $0.src != capsLockUsage } + [ours]
    }

    /// Removes exactly our Caps Lock→F18 entry; a foreign Caps Lock mapping (some other
    /// tool's) is not ours to delete.
    static func mappings(disablingIn current: [Mapping]) -> [Mapping] {
        current.filter { $0 != Mapping(src: capsLockUsage, dst: f18Usage) }
    }

    static func mappingJSON(_ maps: [Mapping]) -> String {
        let entries = maps.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    // MARK: - Self-checks

    static func selfChecks(_ check: SelfTest.Check) {
        let ours = Mapping(src: capsLockUsage, dst: f18Usage)
        let sample = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771114;
            }
        )
        """
        check(parseMappings(sample) == [ours, Mapping(src: 30064771114, dst: 30064771113)],
              "capsHyper: parses hidutil --get output")
        check(parseMappings("(null)\n").isEmpty, "capsHyper: (null) -> no mappings")
        check(parseMappings("").isEmpty, "capsHyper: empty -> no mappings")

        let other = Mapping(src: 1, dst: 2)
        check(mappings(enablingIn: []) == [ours], "capsHyper: enable from empty")
        check(mappings(enablingIn: [other, ours]) == [other, ours],
              "capsHyper: enable is stable when already mapped")
        check(mappings(enablingIn: [other, Mapping(src: capsLockUsage, dst: 999)]) == [other, ours],
              "capsHyper: enable replaces a stale caps mapping, keeps others")
        check(mappings(disablingIn: [other, ours]) == [other],
              "capsHyper: disable removes only our mapping")
        check(mappings(disablingIn: [Mapping(src: capsLockUsage, dst: 999)])
                == [Mapping(src: capsLockUsage, dst: 999)],
              "capsHyper: disable leaves a foreign caps mapping alone")

        check(mappingJSON([Mapping(src: 3, dst: 4)])
                == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":3,\"HIDKeyboardModifierMappingDst\":4}]}",
              "capsHyper: mapping JSON shape")
        check(mappingJSON([]) == "{\"UserKeyMapping\":[]}", "capsHyper: empty mapping JSON clears")

        let hyper = flags(fromMapping: (1 << 20) | (1 << 19) | (1 << 18))
        check(hyper == [.maskCommand, .maskAlternate, .maskControl],
              "capsHyper: default mapping is ⌘⌥⌃")
        check(CGEventFlags.maskShift.union(hyper)
                == [.maskCommand, .maskAlternate, .maskControl, .maskShift],
              "capsHyper: physical shift layers on top as ⌘⌥⌃⇧")
        check(flags(fromMapping: (1 << 17) | (1 << 23)) == [.maskShift],
              "capsHyper: mapping sanitized to the four real modifiers")
    }
}
