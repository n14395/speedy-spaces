import AppKit

// Headless self-test: `SpeedySpaces --dump` prints the enumerated spaces and exits.
// Useful to verify the private window-server API works on this OS build.
if CommandLine.arguments.contains("--dump") {
    let manager = SpacesManager()
    let spaces = manager.spaces
    print("Found \(spaces.count) space(s):")
    for s in spaces {
        let tag = s.isCurrent ? " *CURRENT*" : ""
        let kind = s.isFullscreen ? "fullscreen" : "desktop"
        print("  [display \(s.displayIndex)] #\(s.ordinalOnDisplay + 1) \(kind) id=\(s.managedSpaceID) uuid=\(s.uuid)\(tag)")
    }
    exit(spaces.isEmpty ? 1 : 0)
}

// Headless: dump the RAW managed-display space dictionaries from the window server —
// every key, not just what SpacesManager parses. Used to discover per-space metadata
// (e.g. the owning pid of a fullscreen space).
if CommandLine.arguments.contains("--dump-raw-spaces") {
    guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID()) as? [[String: Any]] else { exit(1) }
    for display in displays {
        print("Display \((display["Display Identifier"] as? String) ?? "?"):")
        for s in (display["Spaces"] as? [[String: Any]]) ?? [] {
            print("  space keys=\(s.keys.sorted())")
            for (k, v) in s.sorted(by: { $0.key < $1.key }) where !(v is [Any]) {
                print("    \(k) = \(v)")
            }
        }
    }
    exit(0)
}

// Headless: dump all on-screen windows (owner / layer / name / size). Used to inspect where our
// overlay window sits relative to the Mission Control bar for a given launch method.
if CommandLine.arguments.contains("--dump-windows") {
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
    for w in infos {
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
        guard owner.localizedCaseInsensitiveContains("SpeedySpaces") || owner.localizedCaseInsensitiveContains("WindowManager") || owner.localizedCaseInsensitiveContains("Dock") else { continue }
        let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
        let name = (w[kCGWindowName as String] as? String) ?? ""
        var b = CGRect.zero
        if let d = w[kCGWindowBounds as String] as? [String: Any] { b = CGRect(dictionaryRepresentation: d as CFDictionary) ?? .zero }
        print("L\(layer) \(owner) '\(name)' \(Int(b.width))x\(Int(b.height)) @\(Int(b.minX)),\(Int(b.minY))")
    }
    exit(0)
}

// Headless feasibility probe: which private space-management symbols resolve on this OS?
// READ-ONLY — only dlsym resolution, never calls them (calling could mutate live Spaces).
if CommandLine.arguments.contains("--probe-space-apis") {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    let candidates = [
        // Currently used
        "CGSMainConnectionID", "CGSCopyManagedDisplaySpaces", "CGSManagedDisplaySetCurrentSpace",
        // Create / destroy desktops
        "CGSSpaceCreate", "CGSSpaceDestroy", "SLSSpaceCreate", "SLSSpaceDestroy",
        "CGSSpaceSetType", "CGSSpaceGetType", "CGSSpaceGetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel",
        // Show / hide / current
        "CGSShowSpaces", "CGSHideSpaces", "CGSManagedDisplayGetCurrentSpace",
        "SLSShowSpaces", "SLSHideSpaces",
        // Move windows between spaces (needed to populate a new desktop)
        "CGSAddWindowsToSpaces", "CGSRemoveWindowsFromSpaces", "CGSMoveWindowsToManagedSpace",
        "SLSMoveWindowsToManagedSpace",
        // Reorder / arrangement
        "CGSSetManagedDisplaySpaces", "CGSCopySpaces", "CGSCopySpacesForWindows",
        // Dock IPC
        "CoreDockSendNotification",
    ]
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for name in candidates {
        print("\(dlsym(rtldDefault, name) != nil ? "✓" : "·") \(name)")
    }
    exit(0)
}

// `SpeedySpaces --probe-space-mutation`: create a space via CGSSpaceCreate, check whether it
// lands in the Dock-managed enumeration (i.e. would appear in Mission Control's bar), then
// destroy it. Decides whether desktop add/remove can be direct CGS calls or must drive the
// Dock's own Mission Control UI via AX. Safe: only the space this probe creates is touched.
if CommandLine.arguments.contains("--probe-space-mutation") {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    typealias DestroyFn = @convention(c) (Int32, UInt64) -> Void
    guard let cSym = dlsym(rtldDefault, "CGSSpaceCreate") ?? dlsym(rtldDefault, "SLSSpaceCreate"),
          let dSym = dlsym(rtldDefault, "CGSSpaceDestroy") ?? dlsym(rtldDefault, "SLSSpaceDestroy")
    else { print("FAIL: create/destroy symbols missing"); exit(1) }
    let create = unsafeBitCast(cSym, to: CreateFn.self)
    let destroy = unsafeBitCast(dSym, to: DestroyFn.self)
    let cid = sm_mainConnectionID()
    func managedIDs() -> Set<UInt64> {
        var out = Set<UInt64>()
        guard let displays = sm_copyManagedDisplaySpaces(cid) as? [[String: Any]] else { return out }
        for d in displays {
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                if let n = s["ManagedSpaceID"] as? UInt64 { out.insert(n) }
                else if let n = s["ManagedSpaceID"] as? Int { out.insert(UInt64(n)) }
            }
        }
        return out
    }
    let before = managedIDs()
    let sid = create(cid, 1, nil)
    print("CGSSpaceCreate -> sid \(sid)")
    guard sid != 0 else { print("FAIL: create returned 0"); exit(1) }
    usleep(300_000)   // give the Dock a beat to notice, if it ever would
    let after = managedIDs()
    let appeared = after.contains(sid) || after.subtracting(before).count > 0
    print("managed spaces before=\(before.count) after=\(after.count)")
    print(appeared ? "MANAGED: new space visible to the Dock (direct add/remove viable)"
                   : "UNMANAGED: Dock ignores CGS-created spaces (add/remove needs the Dock's own UI)")
    destroy(cid, sid)
    usleep(200_000)
    print("destroyed; final managed count=\(managedIDs().count) (expected \(before.count))")
    exit(0)
}

// `--probe-space-reorder [swap|cross|persist|all] [--hold N]`: feasibility gate for
// drag-to-reorder HUD tiles. With no sub-mode: READ-ONLY dlsym discovery report.
// swap    — move the second-to-last non-current desktop one slot right via
//           CGSMoveManagedSpaceToDisplayIndex (the Dock's own MC tile-drag commit),
//           verify enumeration + stability, then restore. `--hold N` keeps the
//           swapped state N seconds before restoring so a harness can screenshot
//           native Mission Control mid-swap.
// persist — CGSPersistenceSaveSpaceConfiguration against restored state first, then a
//           swap→persist→restore→persist cycle, diffing com.apple.spaces throughout.
// cross   — move the last non-current desktop of display 1 to the end of display 2
//           and back (needs ≥2 displays).
// Safety: only the last two non-current, non-fullscreen desktops are ever moved; no
// space is created or destroyed; uuid-set/count/current-space tripwires abort with an
// immediate restore. Worst case is two rightmost desktops transposed (drag to fix in MC).
if let reorderArgIdx = CommandLine.arguments.firstIndex(of: "--probe-space-reorder") {
    let mode = reorderArgIdx + 1 < CommandLine.arguments.count
        && !CommandLine.arguments[reorderArgIdx + 1].hasPrefix("--")
        ? CommandLine.arguments[reorderArgIdx + 1] : "discover"
    var holdSeconds = 0.0
    if let h = CommandLine.arguments.firstIndex(of: "--hold"),
       h + 1 < CommandLine.arguments.count { holdSeconds = Double(CommandLine.arguments[h + 1]) ?? 0 }

    // -- Discovery (always) --
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    for name in ["CGSMoveManagedSpaceToDisplayIndex", "SLSMoveManagedSpaceToDisplayIndex",
                 "SLSTransactionCreate", "SLSTransactionCommit",
                 "SLSTransactionMoveManagedSpaceToDisplayAfterSpace",
                 "SLSSpaceSetOrderingWeight", "SLSTransactionSetSpaceOrderingWeight",
                 "CGSPersistenceSaveSpaceConfiguration", "SLSPersistenceSaveSpaceConfiguration",
                 "CGSSetManagedDisplaySpaces"] {
        print("\(dlsym(rtldDefault, name) != nil ? "✓" : "·") \(name)")
    }
    if mode == "discover" { exit(0) }

    struct SnapSpace { let uuid: String; let sid: UInt64; let type: Int }
    struct SnapDisplay { let ident: String; let spaces: [SnapSpace]; let currentUUID: String }
    func snapshot() -> [SnapDisplay] {
        guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID()) as? [[String: Any]] else { return [] }
        return displays.compactMap { d in
            guard let ident = d["Display Identifier"] as? String else { return nil }
            let spaces = ((d["Spaces"] as? [[String: Any]]) ?? []).compactMap { s -> SnapSpace? in
                guard let uuid = s["uuid"] as? String else { return nil }
                let sid = (s["ManagedSpaceID"] as? UInt64) ?? UInt64(s["ManagedSpaceID"] as? Int ?? 0)
                return SnapSpace(uuid: uuid, sid: sid, type: (s["type"] as? Int) ?? -1)
            }
            let cur = ((d["Current Space"] as? [String: Any])?["uuid"] as? String) ?? ""
            return SnapDisplay(ident: ident, spaces: spaces, currentUUID: cur)
        }
    }
    func describe(_ snap: [SnapDisplay]) -> String {
        snap.map { d in "\(d.ident.prefix(8)): [\(d.spaces.map { String($0.uuid.prefix(6)) + ($0.uuid == d.currentUUID ? "*" : "") }.joined(separator: " "))]" }
            .joined(separator: "  |  ")
    }
    // Invariants vs baseline: same uuid SET and count per display id (order free), same current.
    func tripwire(_ base: [SnapDisplay], _ now: [SnapDisplay], crossOK: Bool) -> String? {
        let baseAll = Set(base.flatMap { $0.spaces.map(\.uuid) })
        let nowAll = Set(now.flatMap { $0.spaces.map(\.uuid) })
        if baseAll != nowAll { return "global uuid set changed" }
        for b in base {
            guard let n = now.first(where: { $0.ident == b.ident }) else { return "display \(b.ident) vanished" }
            if n.currentUUID != b.currentUUID { return "current space changed on \(b.ident)" }
            if !crossOK, Set(n.spaces.map(\.uuid)) != Set(b.spaces.map(\.uuid)) {
                return "per-display uuid set changed on \(b.ident)"
            }
        }
        return nil
    }
    func move(_ sid: UInt64, _ ident: String, _ index: Int) -> Int32 {
        sm_moveManagedSpaceToDisplayIndex(sid, ident as CFString, UInt32(index))
    }
    func waitForOrder(_ ident: String, _ expected: [String], timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot().first(where: { $0.ident == ident })?.spaces.map(\.uuid) == expected { return true }
            usleep(100_000)
        }
        return false
    }
    func restoreAndAbort(_ base: [SnapDisplay], sid: UInt64, ident: String, index: Int, reason: String) -> Never {
        print("ALERT: \(reason) — restoring")
        _ = move(sid, ident, index)
        usleep(400_000)
        let ok = tripwire(base, snapshot(), crossOK: false) == nil
            && snapshot().first(where: { $0.ident == ident })?.spaces.map(\.uuid)
                == base.first(where: { $0.ident == ident })?.spaces.map(\.uuid)
        print(ok ? "restore OK" : "RESTORE FAILED — original order was:\n\(describe(base))\nFix manually: open Mission Control and drag the transposed desktop back.")
        exit(1)
    }

    guard sm_spaceReorderSymbolAvailable() else { print("FAIL: move symbol unresolvable"); exit(1) }
    let base = snapshot()
    print("baseline: \(describe(base))")

    // Target selection: display with the most desktops; need an adjacent pair of
    // non-current desktops at the tail of the desktop run, neither at index 0.
    func pickSwapTargets() -> (d: SnapDisplay, a: Int, b: Int)? {
        for d in base.sorted(by: { $0.spaces.filter { $0.type == 0 }.count > $1.spaces.filter { $0.type == 0 }.count }) {
            let desktops = d.spaces.enumerated().filter { $0.element.type == 0 && $0.element.uuid != d.currentUUID }
            guard d.spaces.filter({ $0.type == 0 }).count >= 3, desktops.count >= 2 else { continue }
            let tail = desktops.suffix(2).map(\.offset)
            if tail[1] == tail[0] + 1, tail[0] > 0 { return (d, tail[0], tail[1]) }
        }
        return nil
    }

    func runSwap() -> Bool {
        guard let (d, ai, bi) = pickSwapTargets() else {
            print("SKIP swap: need a display with ≥3 desktops whose last two are adjacent, non-current, not index 0")
            exit(2)
        }
        let a = d.spaces[ai]
        var expected = d.spaces.map(\.uuid)
        expected.swapAt(ai, bi)
        print("swap: moving \(a.uuid.prefix(6)) (sid \(a.sid)) index \(ai) -> \(bi) on \(d.ident.prefix(8))")
        let err = move(a.sid, d.ident, bi)
        print("CGSMoveManagedSpaceToDisplayIndex -> CGError \(err)")
        if err != 0 { print("FAIL: call rejected"); return false }
        guard waitForOrder(d.ident, expected, timeout: 1.0) else {
            let now = snapshot()
            if let trip = tripwire(base, now, crossOK: false) {
                restoreAndAbort(base, sid: a.sid, ident: d.ident, index: ai, reason: trip)
            }
            print("FAIL: call returned 0 but enumeration never showed the new order (cosmetic/no-op)")
            print("now: \(describe(now))")
            _ = move(a.sid, d.ident, ai)
            return false
        }
        print("PASS: enumeration shows new order ≤1s")
        if let trip = tripwire(base, snapshot(), crossOK: false) {
            restoreAndAbort(base, sid: a.sid, ident: d.ident, index: ai, reason: trip)
        }
        Thread.sleep(forTimeInterval: max(3.0, holdSeconds))
        let stable = snapshot().first(where: { $0.ident == d.ident })?.spaces.map(\.uuid) == expected
        print(stable ? "PASS: order stable after \(max(3.0, holdSeconds))s" : "FAIL: order reverted on its own")
        _ = move(a.sid, d.ident, ai)
        usleep(400_000)
        let restored = snapshot().first(where: { $0.ident == d.ident })?.spaces.map(\.uuid) == d.spaces.map(\.uuid)
        print(restored ? "restore OK" : "RESTORE FAILED — original: \(describe(base)) — fix manually in Mission Control")
        return stable && restored
    }

    func plistOrder() -> [String] {
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        guard let v = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString,
                                                "com.apple.spaces" as CFString) else { return [] }
        var out: [String] = []
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                if let spaces = dict["Spaces"] as? [[String: Any]] {
                    out.append(contentsOf: spaces.compactMap { $0["uuid"] as? String })
                }
                for (_, v) in dict.sorted(by: { $0.key < $1.key }) { walk(v) }
            } else if let arr = any as? [Any] { arr.forEach(walk) }
        }
        walk(v)
        return out
    }

    func runPersist() -> Bool {
        guard sm_persistenceSymbolAvailable() else { print("SKIP persist: symbol unresolvable"); return false }
        // 1: persist the CURRENT (restored/original) state — harmless whatever it does.
        let before = plistOrder()
        let err = sm_persistenceSaveSpaceConfiguration()
        print("CGSPersistenceSaveSpaceConfiguration -> CGError \(err)")
        if err != 0 { return false }
        usleep(500_000)
        let after = plistOrder()
        print("com.apple.spaces uuid order \(before == after ? "unchanged (already in sync)" : "CHANGED — write went through")")
        // 2: swap → persist → check plist shows swap → restore → persist.
        guard let (d, ai, bi) = pickSwapTargets() else { print("SKIP persist cycle: no safe targets"); return false }
        let a = d.spaces[ai].uuid, b = d.spaces[bi].uuid
        guard move(d.spaces[ai].sid, d.ident, bi) == 0 else { print("FAIL: swap for persist cycle rejected"); return false }
        usleep(400_000)
        _ = sm_persistenceSaveSpaceConfiguration()
        usleep(500_000)
        let mid = plistOrder()
        let swappedPersisted = zip(mid, mid.dropFirst()).contains { $0 == b && $1 == a }
        print(swappedPersisted ? "PASS: plist shows swapped order" : "FAIL: plist does not reflect the swap")
        _ = move(d.spaces[ai].sid, d.ident, ai)
        usleep(400_000)
        _ = sm_persistenceSaveSpaceConfiguration()
        usleep(500_000)
        let final = plistOrder()
        let restoredPersisted = zip(final, final.dropFirst()).contains { $0 == a && $1 == b }
        print(restoredPersisted ? "restore persisted OK" : "WARNING: plist may not show restored order — verify com.apple.spaces manually")
        return swappedPersisted && restoredPersisted
    }

    func runCross() -> Bool {
        guard base.count >= 2 else { print("SKIP cross: needs ≥2 displays"); return false }
        let sorted = base.sorted { $0.spaces.filter { $0.type == 0 }.count > $1.spaces.filter { $0.type == 0 }.count }
        let src = sorted[0], dst = sorted[1]
        guard src.spaces.filter({ $0.type == 0 }).count >= 3, dst.spaces.filter({ $0.type == 0 }).count >= 2 else {
            print("SKIP cross: need ≥3 desktops on source and ≥2 on destination"); return false
        }
        // lastIndex(where:) rather than enumerated().last(where:): EnumeratedSequence only
        // conforms to BidirectionalCollection on macOS 26+, and the deployment target is
        // 14.0 (it is an error outright in the Swift 6 language mode). `spaces` is an
        // Array, so the index IS the offset and this is an exact equivalent.
        guard let idx = src.spaces.lastIndex(where: { $0.type == 0 && $0.uuid != src.currentUUID }),
              idx > 0 else { print("SKIP cross: no safe source desktop"); return false }
        let sp = src.spaces[idx]
        print("cross: moving \(sp.uuid.prefix(6)) from \(src.ident.prefix(8))[\(idx)] to end of \(dst.ident.prefix(8))")
        let err = move(sp.sid, dst.ident, dst.spaces.count)
        print("CGSMoveManagedSpaceToDisplayIndex(cross) -> CGError \(err)")
        if err != 0 { return false }
        usleep(600_000)
        let now = snapshot()
        if let trip = tripwire(base, now, crossOK: true) {
            restoreAndAbort(base, sid: sp.sid, ident: src.ident, index: idx, reason: trip)
        }
        let arrived = now.first(where: { $0.ident == dst.ident })?.spaces.map(\.uuid).contains(sp.uuid) ?? false
        let departed = !(now.first(where: { $0.ident == src.ident })?.spaces.map(\.uuid).contains(sp.uuid) ?? true)
        print("arrived on dst: \(arrived), departed src: \(departed)")
        if holdSeconds > 0 { Thread.sleep(forTimeInterval: holdSeconds) }
        _ = move(sp.sid, src.ident, idx)
        usleep(600_000)
        let restored = snapshot().first(where: { $0.ident == src.ident })?.spaces.map(\.uuid) == src.spaces.map(\.uuid)
        print(restored ? "restore OK" : "RESTORE FAILED — original: \(describe(base)) — fix manually in Mission Control")
        return arrived && departed && restored
    }

    var verdicts: [String: Bool] = [:]
    if mode == "swap" || mode == "all" { verdicts["swap"] = runSwap() }
    if mode == "persist" || mode == "all" { verdicts["persist"] = runPersist() }
    if mode == "cross" || mode == "all" { verdicts["cross"] = runCross() }
    print("final: \(describe(snapshot()))")
    for (k, v) in verdicts.sorted(by: { $0.key < $1.key }) { print("\(v ? "PASS" : "FAIL") \(k)") }
    exit(verdicts.values.allSatisfy { $0 } ? 0 : 1)
}

// `--post-mouse <x> <y> [click]`: post a synthetic mouse move (and optional click) at
// global CG (top-left-origin) coordinates — the mouse-side sibling of --fire-hotkey for
// headless testing of hover UI. Does NOT restore the pointer.
if let i = CommandLine.arguments.firstIndex(of: "--post-mouse") {
    guard i + 2 < CommandLine.arguments.count,
          let x = Double(CommandLine.arguments[i + 1]),
          let y = Double(CommandLine.arguments[i + 2]) else {
        print("usage: --post-mouse <x> <y> [click]")
        exit(2)
    }
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    if CommandLine.arguments.contains("click") {
        usleep(80_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    print("posted \(p)\(CommandLine.arguments.contains("click") ? " +click" : "")")
    exit(0)
}


// `--set-space-order <id1,id2,...>`: reorder the display holding those managed-space IDs
// into the given order via CGSMoveManagedSpaceToDisplayIndex (selection sort by target
// index). Test setup / cleanup helper — restores a known desktop order after drag testing.
if let i = CommandLine.arguments.firstIndex(of: "--set-space-order") {
    guard i + 1 < CommandLine.arguments.count else { print("usage: --set-space-order <id1,id2,...>"); exit(2) }
    let desired = CommandLine.arguments[i + 1].split(separator: ",").compactMap { UInt64($0) }
    guard !desired.isEmpty else { print("no ids"); exit(2) }
    func displayOf(_ sid: UInt64) -> String? {
        guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID()) as? [[String: Any]] else { return nil }
        for d in displays {
            let ident = d["Display Identifier"] as? String
            for s in (d["Spaces"] as? [[String: Any]]) ?? [] {
                let id = (s["ManagedSpaceID"] as? UInt64) ?? UInt64(s["ManagedSpaceID"] as? Int ?? -1)
                if id == sid { return ident }
            }
        }
        return nil
    }
    func liveOrder(_ ident: String) -> [UInt64] {
        guard let displays = sm_copyManagedDisplaySpaces(sm_mainConnectionID()) as? [[String: Any]],
              let d = displays.first(where: { ($0["Display Identifier"] as? String) == ident }) else { return [] }
        return ((d["Spaces"] as? [[String: Any]]) ?? []).map { (($0["ManagedSpaceID"] as? UInt64) ?? UInt64($0["ManagedSpaceID"] as? Int ?? -1)) }
    }
    guard let ident = displayOf(desired[0]) else { print("FAIL: space not found"); exit(1) }
    for (target, sid) in desired.enumerated() {
        let cur = liveOrder(ident)
        guard let at = cur.firstIndex(of: sid) else { continue }
        if at != target {
            _ = sm_moveManagedSpaceToDisplayIndex(sid, ident as CFString, UInt32(target))
            usleep(250_000)
        }
    }
    let final = liveOrder(ident)
    print("order: \(final.map(String.init).joined(separator: ","))")
    print(final.prefix(desired.count).elementsEqual(desired) ? "OK" : "PARTIAL")
    exit(0)
}

// `--post-drag <x1> <y1> <x2> <y2> [steps]`: synthesize a left-button drag from p1 to p2
// in global CG (top-left-origin) coords — mouseDown, interpolated mouseDragged, mouseUp —
// for headless testing of the switcher HUD's drag-to-reorder. Synthetic mouse is delivered
// on this macOS; synthetic keyboard is not.
if let i = CommandLine.arguments.firstIndex(of: "--post-drag") {
    let a = CommandLine.arguments
    guard i + 4 < a.count, let x1 = Double(a[i+1]), let y1 = Double(a[i+2]),
          let x2 = Double(a[i+3]), let y2 = Double(a[i+4]) else {
        print("usage: --post-drag <x1> <y1> <x2> <y2> [steps]"); exit(2)
    }
    let steps = (i + 5 < a.count ? Int(a[i+5]) : nil) ?? 24
    func post(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    let p1 = CGPoint(x: x1, y: y1), p2 = CGPoint(x: x2, y: y2)
    post(.mouseMoved, p1); usleep(60_000)
    post(.leftMouseDown, p1); usleep(60_000)
    for s in 1...max(1, steps) {
        let t = Double(s) / Double(max(1, steps))
        post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
        usleep(16_000)
    }
    usleep(120_000)   // let the reflow settle so a mid-drag screenshot is legible
    post(.leftMouseUp, p2)
    print("dragged \(p1) -> \(p2) in \(steps) steps")
    exit(0)
}

// `--dump-mc-ax`: open Mission Control, walk the Dock's `mc` accessibility subtree and
// print every element's identifier, role, actions, and (settable) attributes, then close
// MC and exit. Diagnostic for finding a programmatic bar-expansion hook.
if CommandLine.arguments.contains("--dump-mc-ax") {
    guard let dock = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        print("no Dock"); exit(1)
    }
    let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
    func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success
        else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
    func str(_ el: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return "" }
        return (v as? String) ?? String(describing: v)
    }
    func dump(_ el: AXUIElement, depth: Int) {
        var actions: CFArray?
        AXUIElementCopyActionNames(el, &actions)
        var attrs: CFArray?
        AXUIElementCopyAttributeNames(el, &attrs)
        var settable: [String] = []
        for a in (attrs as? [String]) ?? [] {
            var s = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(el, a as CFString, &s) == .success, s.boolValue {
                settable.append(a)
            }
        }
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)\(str(el, "AXRole")) id='\(str(el, "AXIdentifier"))'"
              + " actions=\((actions as? [String]) ?? [])"
              + " attrs=\((attrs as? [String]) ?? [])"
              + " settable=\(settable)")
        if depth < 4 {
            for c in children(el) { dump(c, depth: depth + 1) }
        }
    }
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    Thread.sleep(forTimeInterval: 1.0)
    guard let mc = children(dockAX).first(where: { str($0, "AXIdentifier") == "mc" }) else {
        print("no mc group")
        _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        exit(1)
    }
    for _ in 0..<20 where children(mc).isEmpty {   // the subtree lags the group itself
        Thread.sleep(forTimeInterval: 0.1)
    }
    dump(mc, depth: 0)
    // The bar's windows belong to WindowManager on this macOS — its AX tree may hold
    // the spaces list the Dock no longer publishes.
    for wm in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager.app")
        + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager") {
        print("WindowManager pid \(wm.processIdentifier):")
        dump(AXUIElementCreateApplication(wm.processIdentifier), depth: 1)
    }
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    exit(0)
}

// `--expand-mc-ax <focusList|selectChildren|focusButton|dumpButtons>`: open Mission
// Control, apply one AX manipulation to WindowManager's mc.spaces.list, and report how
// long until the tile thumbnails appear. Experiment: can AX expand the bar without the
// pointer-hover dwell?
if let i = CommandLine.arguments.firstIndex(of: "--expand-mc-ax") {
    let method = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "focusList"
    func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success
        else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
    func axID(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXIdentifier" as CFString, &v) == .success
        else { return "" }
        return (v as? String) ?? ""
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    func ms() -> Int { Int((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
    NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen, object: nil)
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    while !NativeBarWindows.barOnScreen(), CFAbsoluteTimeGetCurrent() - t0 < 2 { usleep(10_000) }
    print("\(ms()) ms bar up")
    var lists: [AXUIElement] = []
    for wm in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager.app")
        + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager") {
        let app = AXUIElementCreateApplication(wm.processIdentifier)
        for display in axChildren(app) where axID(display) == "mc.display" {
            for spaces in axChildren(display) where axID(spaces) == "mc.spaces" {
                lists += axChildren(spaces).filter { axID($0) == "mc.spaces.list" }
            }
        }
    }
    print("\(ms()) ms found \(lists.count) spaces lists")
    for list in lists {
        switch method {
        case "focusList":
            let err = AXUIElementSetAttributeValue(list, kAXFocusedAttribute as CFString,
                                                   kCFBooleanTrue)
            print("\(ms()) ms set AXFocused(list) -> \(err.rawValue)")
        case "selectChildren":
            let kids = axChildren(list)
            guard !kids.isEmpty else { print("no children"); break }
            let err = AXUIElementSetAttributeValue(list, "AXSelectedChildren" as CFString,
                                                   [kids[0]] as CFArray)
            print("\(ms()) ms set AXSelectedChildren -> \(err.rawValue)")
        case "focusButton":
            let kids = axChildren(list)
            guard let first = kids.first else { print("no children"); break }
            let err = AXUIElementSetAttributeValue(first, kAXFocusedAttribute as CFString,
                                                   kCFBooleanTrue)
            print("\(ms()) ms set AXFocused(button) -> \(err.rawValue)")
        case "dumpButtons":
            for b in axChildren(list) {
                var actions: CFArray?
                AXUIElementCopyActionNames(b, &actions)
                var attrs: CFArray?
                AXUIElementCopyAttributeNames(b, &attrs)
                var settable: [String] = []
                for a in (attrs as? [String]) ?? [] {
                    var s = DarwinBoolean(false)
                    if AXUIElementIsAttributeSettable(b, a as CFString, &s) == .success, s.boolValue {
                        settable.append(a)
                    }
                }
                print("button id='\(axID(b))' actions=\((actions as? [String]) ?? [])"
                      + " settable=\(settable)")
            }
        default:
            print("unknown method \(method)")
        }
    }
    let tilesDeadline = CFAbsoluteTimeGetCurrent() + 2.5
    while !NativeBarWindows.tilesOnScreen(), CFAbsoluteTimeGetCurrent() < tilesDeadline { usleep(10_000) }
    print("\(ms()) ms tiles \(NativeBarWindows.tilesOnScreen() ? "UP" : "never appeared")")
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    exit(0)
}

// `--post-swipe <phase> <progress> [velocity]`: post one augmented dock-swipe event with
// arbitrary signed progress (+ = toward higher ordinal). Lets a script drive the system
// through a REAL partial space-drag (phases 1,2,...,4) — the Dock accepts these just
// like the gesture engine's full swipes. Gesture-engine debugging tool.
if let i = CommandLine.arguments.firstIndex(of: "--post-swipe") {
    guard i + 2 < CommandLine.arguments.count,
          let phase = Int64(CommandLine.arguments[i + 1]),
          let progress = Double(CommandLine.arguments[i + 2]) else {
        print("usage: --post-swipe <phase> <progress> [velocity]")
        exit(2)
    }
    let velocity = i + 3 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 3]) ?? 0) : 0
    SystemEventPoster().postDockSwipe(phase: phase, goRight: progress >= 0,
                                      velocity: velocity, progress: abs(progress))
    print("posted swipe phase=\(phase) progress=\(progress) velocity=\(velocity)")
    exit(0)
}

// `--post-flick <right|left> [velocity]`: post one complete animating flick (began → ramp →
// ended) with the gesture engine's exact anatomy and timing, in-process. The from-a-script
// equivalent of a real one-space swipe; --post-swipe's per-invocation process spawns stretch
// the anatomy too far to animate reliably.
if let i = CommandLine.arguments.firstIndex(of: "--post-flick") {
    let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "right"
    let velocity = i + 2 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 2]) ?? GestureSwitcher.flickVelocity)
        : GestureSwitcher.flickVelocity
    SystemEventPoster().postFlick(goRight: dir != "left", velocity: velocity)
    print("posted flick \(dir) velocity=\(velocity)")
    exit(0)
}

// `--post-vswipe <phase> <progress> [velocity]`: the VERTICAL sibling of --post-swipe —
// one augmented dock-swipe event on the Mission Control open/close axis (by Mac Mouse
// Fix's convention positive progress = swipe down). Exercises the overlay's swipe-close
// watcher from a script.
if let i = CommandLine.arguments.firstIndex(of: "--post-vswipe") {
    guard i + 2 < CommandLine.arguments.count,
          let phase = Int64(CommandLine.arguments[i + 1]),
          let progress = Double(CommandLine.arguments[i + 2]) else {
        print("usage: --post-vswipe <phase> <progress> [velocity]")
        exit(2)
    }
    let velocity = i + 3 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 3]) ?? 0) : 0
    SystemEventPoster().postDockSwipe(phase: phase, goRight: progress >= 0,
                                      velocity: velocity, progress: abs(progress),
                                      vertical: true)
    // Exiting immediately races the posted event's delivery — measured: the tail of a
    // per-process sequence silently vanishes without this beat.
    usleep(120_000)
    print("posted vswipe phase=\(phase) progress=\(progress) velocity=\(velocity)")
    exit(0)
}

// `--post-vflick <down|up> [velocity]`: one complete vertical flick (began → ramp → ended)
// with the flick anatomy of --post-flick, in-process. down = positive progress.
if let i = CommandLine.arguments.firstIndex(of: "--post-vflick") {
    let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "down"
    let velocity = i + 2 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 2]) ?? GestureSwitcher.flickVelocity)
        : GestureSwitcher.flickVelocity
    SystemEventPoster().postFlick(goRight: dir != "up", velocity: velocity, vertical: true)
    usleep(120_000)   // let the tail of the anatomy deliver before the process dies
    print("posted vflick \(dir) velocity=\(velocity)")
    exit(0)
}

// On macOS 27 REAL gesture events carry their data in a wrapped IOHID event, not in
// the legacy CGEvent fields (measured: type-29 events with fields 110/123/124/132 all
// zero during three-finger swipes). Decode it from the serialized event: the same
// field-4205 block the gesture engine APPENDS when posting is present on received
// events, so parse it with the same struct layout (queue-element header + a chain of
// IOHID events: type 23 FluidTouchGesture, 9 Velocity, phase in options>>24).
// Top level: the sniffer's C-function-pointer callback can only reference globals.
func sniffParseHIDPayload(_ bytes: Data) -> String {
        let n = bytes.count
        func u32(_ o: Int, _ d: Data) -> UInt32 {
            d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        }
        func u16(_ o: Int, _ d: Data) -> UInt16 {
            d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
        }
        var start = -1, psize = 0
        var i = n - 5
        while i >= 0 {
            if bytes[i + 2] == 0x10, bytes[i + 3] == 0x6D {
                let size = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                if size == n - i - 4 { start = i + 4; psize = size; break }
            }
            i -= 1
        }
        guard start >= 0 else { return "no4205(len=\(n))" }
        let p = bytes.subdata(in: start..<(start + psize))
        guard p.count >= 28 else { return "hid(short \(p.count)B)" }
        let count = Int(u32(24, p))
        var off = 28 + Int(u32(20, p))   // events start after header + attributes
        var out = "hid[n=\(count)"
        var k = 0
        while k < count, off + 16 <= p.count {
            let size = Int(u32(off, p)), type = u32(off + 4, p)
            let phase = (u32(off + 8, p) >> 24) & 0xFF
            if type == 23, off + 40 <= p.count {
                let motion = u16(off + 32, p), flavor = u16(off + 34, p)
                let prog = Double(Int32(bitPattern: u32(off + 36, p))) / 65536
                out += String(format: " g(ph=%d mo=%d fl=%d pr=%.3f)", phase, motion, flavor, prog)
            } else if type == 9, off + 24 <= p.count {
                let vx = Double(Int32(bitPattern: u32(off + 16, p))) / 65536
                let vy = Double(Int32(bitPattern: u32(off + 20, p))) / 65536
                out += String(format: " v(%.2f,%.2f)", vx, vy)
            } else {
                out += " e(t=\(type) ph=\(phase) sz=\(size))"
            }
            guard size > 0 else { break }
            off += size
            k += 1
        }
    return out + "]"
}

var sniffHexBudget = 3

// `--sniff-gestures [seconds]`: install a LISTEN-ONLY session tap over the gesture-ish
// event types (18-31) and print every event's undocumented fields plus the decoded
// wrapped-HID payload — the ground truth for what REAL trackpad gestures look like on
// this OS. Diagnostic for the Mission Control swipe-close watcher.
if let i = CommandLine.arguments.firstIndex(of: "--sniff-gestures") {
    let seconds = i + 1 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 1]) ?? 45) : 45
    var mask: CGEventMask = 0
    for t in 18...31 { mask |= (1 << t) }
    let callback: CGEventTapCallBack = { _, type, event, _ in
        let ints = [110, 123, 132, 134].map {
            "\($0):\(event.getIntegerValueField(CGEventField(rawValue: UInt32($0))!))"
        }
        var line = String(format: "%.3f", CACurrentMediaTime())
            + " type=\(type.rawValue) " + ints.joined(separator: " ")
        if let cf = event.data {
            let bytes = Data(referencing: cf)
            let parsed = sniffParseHIDPayload(bytes)
            line += " " + parsed
            if parsed.hasPrefix("no4205"), sniffHexBudget > 0 {
                sniffHexBudget -= 1
                line += " tail=" + bytes.suffix(120).map { String(format: "%02x", $0) }.joined()
            }
        }
        print(line)
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: callback, userInfo: nil) else {
        print("tap creation FAILED (Accessibility?)")
        exit(1)
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    print("sniffing gesture events for \(Int(seconds))s (types 18-31)…")
    setbuf(stdout, nil)   // unbuffered: lines must land even if the run is killed early
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    print("sniff done")
    exit(0)
}

// `--dock-note <name>`: send one CoreDock notification (com.apple.expose.awake toggles
// Mission Control; com.apple.expose.front.awake toggles App Exposé) — lets a script
// drive MC open/closed around the other probes.
if let i = CommandLine.arguments.firstIndex(of: "--dock-note") {
    guard i + 1 < CommandLine.arguments.count else {
        print("usage: --dock-note <name>")
        exit(2)
    }
    let ok = sm_coreDockSendNotification(CommandLine.arguments[i + 1] as CFString)
    print(ok ? "sent" : "CoreDockSendNotification unavailable")
    exit(ok ? 0 : 1)
}

// `SpeedySpaces --probe-mouse`: post a synthetic mouseMoved CGEvent and report whether the
// pointer actually moved (synthetic KEYBOARD events are dropped system-wide on this OS;
// this asks the same question for mouse events). Restores the pointer afterwards.
if CommandLine.arguments.contains("--probe-mouse") {
    let before = CGEvent(source: nil)?.location ?? .zero
    let target = CGPoint(x: max(10, before.x - 40), y: max(10, before.y - 40))
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: target, mouseButton: .left) {
        move.post(tap: .cghidEventTap)
    }
    usleep(150_000)
    let after = CGEvent(source: nil)?.location ?? .zero
    let moved = hypot(after.x - target.x, after.y - target.y) < 4
    print("before=\(before) target=\(target) after=\(after)")
    print(moved ? "MOUSE EVENTS DELIVERED" : "mouse events NOT delivered (dropped like keyboard)")
    // Put the pointer back where the user had it.
    CGWarpMouseCursorPosition(before)
    exit(moved ? 0 : 1)
}

// `--probe-add-desktop` / `--probe-remove-desktop <ordinal>`: run the Mission Control
// synthetic-mouse choreography headlessly against the primary display, print PASS/FAIL
// (judged by the managed-space count changing), and exit.
if CommandLine.arguments.contains("--probe-add-desktop") {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    else { print("FAIL: no screen"); exit(1) }
    SpaceMutator.addDesktop(on: screen) { ok in
        print(ok ? "PASS: desktop added" : "FAIL: count unchanged")
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--probe-remove-desktop") {
    guard i + 1 < CommandLine.arguments.count, let ordinal = Int(CommandLine.arguments[i + 1]) else {
        print("usage: --probe-remove-desktop <ordinal>")
        exit(2)
    }
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    else { print("FAIL: no screen"); exit(1) }
    let manager = SpacesManager()
    let ids = SwitcherHUD.displayIdentifiers(for: screen)
    let list = manager.spaces.filter { ids.contains($0.displayIdentifier) }
        .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
    SpaceMutator.removeDesktop(ordinal: ordinal, of: list.count, on: screen) { ok in
        print(ok ? "PASS: desktop removed" : "FAIL: count unchanged")
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}

// `SpeedySpaces --probe-mc-tree`: open Mission Control, dump the Dock's `mc` AX subtree
// (identifiers, roles, actions, frames), close MC, exit. Maps where the add-desktop
// button and per-thumbnail close buttons live so the switcher HUD can press them.
if CommandLine.arguments.contains("--probe-mc-tree") {
    guard AXIsProcessTrusted() else { print("FAIL: not AX-trusted"); exit(1) }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { print("FAIL: no Dock"); exit(1) }
    let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
    func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
    func frameString(_ el: AXUIElement) -> String {
        guard let posV = attr(el, kAXPositionAttribute), let sizeV = attr(el, kAXSizeAttribute)
        else { return "?" }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))"
    }
    func dump(_ el: AXUIElement, depth: Int) {
        let id = (attr(el, "AXIdentifier") as? String) ?? "-"
        let role = (attr(el, kAXRoleAttribute) as? String) ?? "?"
        let desc = (attr(el, kAXDescriptionAttribute) as? String) ?? ""
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)\(role) id=\(id) desc=\(desc) actions=\(actions(el)) \(frameString(el))")
        guard depth < 5 else { return }
        for c in children(el).prefix(40) { dump(c, depth: depth + 1) }
    }
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    let deadline = Date().addingTimeInterval(2.5)
    var mc: AXUIElement?
    while Date() < deadline, mc == nil {
        mc = children(dockAX).first { (attr($0, "AXIdentifier") as? String) == "mc" }
        if mc == nil { usleep(50_000) }
    }
    guard let mc else {
        print("FAIL: mc group never appeared")
        _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        exit(1)
    }
    // The subtree forms after the group: poll until it has children (≤3s).
    let childDeadline = Date().addingTimeInterval(3.0)
    while Date() < childDeadline, children(mc).isEmpty { usleep(100_000) }
    dump(mc, depth: 0)
    _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
    Thread.sleep(forTimeInterval: 0.4)
    exit(0)
}

// Headless render probe: build the menubar strip with the real spaces and write it to a PNG so
// the drawing can be inspected in isolation (independent of menu-bar visibility / managers).
if CommandLine.arguments.contains("--probe-strip") {
    _ = NSApplication.shared
    let manager = SpacesManager()
    let store = MetadataStore()
    func title(_ s: Space) -> String {
        let m = store.metadata(for: s.uuid)
        if let n = m.name, !n.isEmpty { return n }
        return s.isFullscreen ? "Full-Screen App" : "Desktop \(s.ordinalOnDisplay + 1)"
    }
    func icon(_ s: Space) -> NSImage? { IconRendering.image(for: store.metadata(for: s.uuid), pointSize: 15) }
    let current = manager.currentSpace
    let displaySpaces = current.map { cur in
        manager.spaces.filter { $0.displayIndex == cur.displayIndex }.sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
    } ?? manager.spaces
    let currentUUIDs = Set(displaySpaces.filter(\.isCurrent).map(\.uuid))
    // Optional trailing flags: --probe-strip [icon] [name] [switcher] [number]  (1/0, default 1 1 1 0)
    // `noicons` pretends no space has an icon, to exercise the placeholder fallback.
    let a = CommandLine.arguments
    let pi = a.firstIndex(of: "--probe-strip") ?? 0
    func flag(_ off: Int, _ def: Bool) -> Bool { pi + off < a.count ? (a[pi + off] == "1") : def }
    let noIcons = a.contains("noicons")
    let view = MenuBarStripView()
    view.update(displaySpaces: displaySpaces, currentUUIDs: currentUUIDs,
                showIcon: flag(1, true), showName: flag(2, true), showNumber: flag(4, false),
                showSwitcher: flag(3, true),
                title: title, icon: noIcons ? { _ in nil } : icon)
    let size = view.intrinsicContentSize
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    // dataWithPDF reliably invokes draw(_:) for a windowless view; rasterize it 3x on a gray bg.
    let pdf = view.dataWithPDF(inside: view.bounds)
    let scale: CGFloat = 3
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    let out = NSImage(size: px)
    out.lockFocus()
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(origin: .zero, size: px).fill()
    NSImage(data: pdf)?.draw(in: NSRect(origin: .zero, size: px))
    out.unlockFocus()
    if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "/tmp/strip-probe.png"))
    }
    print("strip size=\(size) spaces=\(displaySpaces.count) current=\(current?.uuid ?? "nil")")
    print("pieces: \(view.debugInfo)")
    exit(0)
}

// Headless render probe: build the switcher bar for the primary display with the real
// spaces/metadata/wallpapers and write it to a PNG (like --probe-strip for the menubar).
// Verifies tile content — captions, badges, wallpapers — without window captures.
if CommandLine.arguments.contains("--probe-switcher") {
    _ = NSApplication.shared
    let manager = SpacesManager()
    let store = MetadataStore()
    let wallpapers = WallpaperStore()
    let hud = SwitcherHUD(spaces: manager, store: store, wallpapers: wallpapers)
    guard let screen = NSScreen.screens.first else { exit(1) }
    let firstPass = hud.tiles(for: screen)
    Thread.sleep(forTimeInterval: 0.6)   // let async wallpaper decodes land
    let tiles = hud.tiles(for: screen)   // second pass picks up decoded thumbnails
    let size = screen.frame.size
    let view = SwitcherBarView()
    view.frame = NSRect(origin: .zero, size: size)
    view.tiles = tiles
    view.layout = SwitcherLayout.tiles(count: tiles.count, screenSize: size,
                                       popover: Prefs.switcherPosition == .classicPopover)
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor(white: 0.35, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/switcher-probe.png"))
        }
    }
    print("switcher probe: \(tiles.count) tiles (first pass \(firstPass.count)) "
          + "barRect=\(view.layout.barRect) tileSize=\(view.layout.tileSize)")
    for tile in tiles {
        print("  \(tile.isCurrent ? "*" : " ") caption=\(tile.caption) name=\(tile.name ?? "-") "
              + "fullscreen=\(tile.isFullscreen) badge=\(tile.appBadge != nil) "
              + "wallpaper=\(tile.wallpaper != nil)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--symbols") {
    print("SF Symbol catalog: \(SFSymbolCatalog.all.count) valid symbols on this OS")
    print("Categories (\(SFSymbolCatalog.categorized.count)): "
        + SFSymbolCatalog.categorized.map { "\($0.name)=\($0.symbols.count)" }.joined(separator: " "))
    print("Sample search 'star': \(SFSymbolCatalog.search("star").count) matches")
    print("Keyword search 'dog': \(SFSymbolCatalog.search("dog").prefix(6))")
    print("Login item enabled: \(LoginItem.isEnabled)")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    let failures = SelfTest.run()
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// `SpeedySpaces --post-chord <keyCode> <nsModifierRaw>`: post one synthetic keyboard chord
// (down+up) and exit. NOTE: on macOS 26+ the system drops synthetic keyboard events
// entirely (IOHID provenance enforcement) — even the stock ⌃→ switch is ignored when
// posted this way — so this flag cannot exercise hotkeys there; use --fire-hotkey to
// drive the dispatch layer instead, and a physical keypress for the Carbon path.
if let i = CommandLine.arguments.firstIndex(of: "--post-chord") {
    let args = CommandLine.arguments
    guard i + 2 < args.count, let kc = UInt16(args[i + 1]), let mods = UInt(args[i + 2]) else {
        print("usage: --post-chord <keyCode> <nsModifierFlagsRaw>")
        exit(2)
    }
    let spec = ShortcutSpec(keyCode: kc, modifiers: mods)
    HotkeyDiag.log("post-chord: AX=\(AXIsProcessTrusted()) preflight=\(CGPreflightPostEventAccess()) posting \(spec.displayString)")
    let src = CGEventSource(stateID: .combinedSessionState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: true) {
        down.flags = spec.cgEventFlags
        down.post(tap: .cghidEventTap)
    }
    usleep(30_000)
    if let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: false) {
        up.flags = spec.cgEventFlags
        up.post(tap: .cghidEventTap)
    }
    print("posted \(spec.displayString) (keyCode \(kc), modifiers \(spec.modifiers))")
    exit(0)
}

// `SpeedySpaces --window-spaces <wid>`: print the managed-space ids containing a window.
if let i = CommandLine.arguments.firstIndex(of: "--window-spaces") {
    guard i + 1 < CommandLine.arguments.count, let wid = UInt32(CommandLine.arguments[i + 1]) else {
        print("usage: --window-spaces <windowID>")
        exit(2)
    }
    print("window \(wid) on space ids: \(WindowMover.spaceIDs(for: wid))")
    exit(0)
}

// `--test-move <wid> <spaceIndex>`: drive WindowMover.move (the native title-bar drag) on a
// specific window, then wait for the async walk to finish and print the window's resulting space.
// Test hook for the move mechanism (real keypresses move the FOCUSED window through the same path).
if let i = CommandLine.arguments.firstIndex(of: "--test-move") {
    let a = CommandLine.arguments
    guard i + 2 < a.count, let wid = UInt32(a[i + 1]), let idx = Int(a[i + 2]) else {
        print("usage: --test-move <wid> <spaceIndex>"); exit(2)
    }
    let sm = SpacesManager(); sm.refresh()
    guard idx >= 0 && idx < sm.spaces.count else { print("bad space index (0..\(sm.spaces.count - 1))"); exit(2) }
    let target = sm.spaces[idx]
    print("before: window \(wid) on \(WindowMover.spaceIDs(for: wid)); target space=\(target.managedSpaceID)")
    do { try WindowMover.move(wid: wid, to: target, spaces: sm); print("dispatched") }
    catch { print("move failed: \(error)"); exit(1) }
    RunLoop.current.run(until: Date().addingTimeInterval(11))   // let the async walk complete
    print("after: window \(wid) on \(WindowMover.spaceIDs(for: wid))")
    exit(0)
}

// `SpeedySpaces --fire-hotkey <actionId|space:uuid>`: ask the RUNNING instance to dispatch
// a hotkey action through the same path a Carbon hotkey callback takes. Exists because
// synthetic keyboard events are dropped system-wide on this macOS, so chords can't be
// posted for headless testing.
if let i = CommandLine.arguments.firstIndex(of: "--fire-hotkey") {
    guard i + 1 < CommandLine.arguments.count else {
        print("usage: --fire-hotkey <actionId|space:uuid>")
        exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.speedyspaces.debug.hotkey"),
        object: CommandLine.arguments[i + 1], userInfo: nil, deliverImmediately: true)
    print("fired \(CommandLine.arguments[i + 1])")
    exit(0)
}

// Scriptability: drive the RUNNING instance from the shell. These mirror the
// `speedyspaces://` URL scheme and feed the same command router (HotkeyManager.runCommand).
// Each is a throwaway process that posts `com.speedyspaces.command` and exits before
// NSApplication is created, so it never trips terminateOtherInstances.
func sm_postCommand(_ command: String) -> Never {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.speedyspaces.command"),
        object: command, userInfo: nil, deliverImmediately: true)
    print("sent \(command)")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--switch") {
    guard i + 1 < CommandLine.arguments.count else {
        print("usage: --switch <name | #index | uuid>")
        exit(2)
    }
    let arg = CommandLine.arguments[i + 1]
    if arg.hasPrefix("#"), let n = Int(arg.dropFirst()) {
        sm_postCommand("switch:index:\(n)")
    } else if UUID(uuidString: arg) != nil {
        sm_postCommand("switch:uuid:\(arg)")
    } else {
        sm_postCommand("switch:name:\(arg)")
    }
}
if CommandLine.arguments.contains("--next") { sm_postCommand("next") }
if CommandLine.arguments.contains("--prev") || CommandLine.arguments.contains("--previous") {
    sm_postCommand("prev")
}
if CommandLine.arguments.contains("--back") { sm_postCommand("back") }
if CommandLine.arguments.contains("--switcher") { sm_postCommand("switcher") }

// `SpeedySpaces --switcher-debug <payload>`: forward a raw payload to the running
// instance's switcher debug side door (see SwitcherHUD.debugCommand) — e.g.
// "gesture:2:0.3" to drive the finger-tracked band slide headlessly.
if let i = CommandLine.arguments.firstIndex(of: "--switcher-debug") {
    guard i + 1 < CommandLine.arguments.count else {
        print("usage: --switcher-debug <payload>")
        exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.speedyspaces.debug.switcher"),
        object: CommandLine.arguments[i + 1], userInfo: nil, deliverImmediately: true)
    print("sent \(CommandLine.arguments[i + 1])")
    exit(0)
}

// `SpeedySpaces --show-switcher [seconds]`: ask the RUNNING instance to flash the floating
// switcher HUD (default 3 s) — headless visual verification without a hotkey chord.
if let i = CommandLine.arguments.firstIndex(of: "--show-switcher") {
    let seconds = i + 1 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[i + 1]) ?? 3) : 3
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.speedyspaces.debug.switcher"),
        object: "show:\(seconds)", userInfo: nil, deliverImmediately: true)
    print("switcher shown for \(seconds)s")
    exit(0)
}

// `SpeedySpaces --probe-switch <method> <index>`: switch to spaces[index] using the named
// engine, wait for verification, print PASS/FAIL + timing, and exit. Run from a logged-in
// GUI session (switching needs the WindowServer session and, for most engines, Accessibility).
if let i = CommandLine.arguments.firstIndex(of: "--probe-switch") {
    let args = CommandLine.arguments
    guard i + 2 < args.count, let method = SwitchMethod(rawValue: args[i + 1]), let index = Int(args[i + 2]) else {
        print("usage: --probe-switch <gesture|missionControl> <index>")
        exit(2)
    }
    let manager = SpacesManager()
    exit(manager.probeSwitch(method: method, index: index))
}

// Diagnostic: `SpeedySpaces --drive-mc [holdSeconds] [collapsed]` opens/holds Mission Control so
// the running app's overlay can be observed unattended. See MissionControlDriver.
if let i = CommandLine.arguments.firstIndex(of: "--drive-mc") {
    let hold = (i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) : nil) ?? 8
    MissionControlDriver.run(holdSeconds: hold, collapsed: CommandLine.arguments.contains("collapsed"))
}

// `SpeedySpaces --export-config <path>` / `--import-config <path>`: scriptable backup and
// restore of per-space names/icons/shortcuts + preferences. Self-contained (build our own
// store), so they run without the agent. Export is safe to run anytime; a CLI import takes
// full effect on the next launch (a running agent keeps its own in-memory copy until then —
// use Settings ▸ General ▸ Import for a live restore).
if let i = CommandLine.arguments.firstIndex(of: "--export-config") {
    guard i + 1 < CommandLine.arguments.count else { print("usage: --export-config <path>"); exit(2) }
    guard let data = ConfigBackup.export(spaces: SpacesManager(), store: MetadataStore()) else {
        print("export failed"); exit(1)
    }
    do {
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic)
        print("exported \(data.count) bytes")
        exit(0)
    } catch { print("write failed: \(error)"); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--import-config") {
    guard i + 1 < CommandLine.arguments.count else { print("usage: --import-config <path>"); exit(2) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])) else {
        print("read failed"); exit(1)
    }
    guard let s = ConfigBackup.importConfig(from: data, spaces: SpacesManager(), store: MetadataStore()) else {
        print("not a valid SpeedySpaces backup"); exit(1)
    }
    print("imported: \(s.applied) applied, \(s.remapped) remapped, \(s.unmatched) unmatched")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menubar-only agent app: no Dock icon, no main menu bar.
app.setActivationPolicy(.accessory)
app.run()
