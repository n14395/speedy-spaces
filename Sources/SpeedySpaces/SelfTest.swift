// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Lightweight self-test harness. `SpeedySpaces --selftest` runs pure-logic checks
/// and exits non-zero if any fail. Engines append their own checks here as they
/// are implemented. There is no XCTest target (custom swiftc build), so this is
/// the project's runnable unit-test surface for pure functions.
enum SelfTest {
    typealias Check = (_ condition: Bool, _ label: String) -> Void

    static func run() -> Int {
        var failures = 0
        let check: Check = { condition, label in
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        prefsChecks(check)
        symbolChecks(check)
        GestureSwitcher.selfChecks(check)
        SystemShortcuts.selfChecks(check)
        ShortcutSpec.selfChecks(check)
        HotkeyAction.selfChecks(check)
        ConflictChecker.selfChecks(check)
        SpacesManager.selfChecks(check)
        MenuBarStripView.selfChecks(check)
        SwitcherLayout.selfChecks(check)
        SwitcherHUD.selfChecks(check)
        WallpaperStore.selfChecks(check)
        SpaceMenuRowView.selfChecks(check)
        MenuHeaderRowView.selfChecks(check)
        SwitchOutcome.selfChecks(check)
        HotkeyManager.selfChecks(check)
        CapsLockHyper.selfChecks(check)
        WindowMover.selfChecks(check)
        SwitcherBarView.selfChecks(check)
        MissionControlOverlay.selfChecks(check)
        SettingsController.selfChecks(check)
        SFSymbolCatalog.selfChecks(check)
        AppDelegate.selfChecks(check)
        SpaceNameRanker.selfChecks(check)
        SpaceJumpFieldView.selfChecks(check)
        StatusItemController.selfChecks(check)
        SystemEventPoster.selfChecks(check)
        IconRendering.selfChecks(check)
        return failures
    }

    private static func prefsChecks(_ check: Check) {
        check(SwitchMethod.migrating(fromStored: "direct") == .gesture, "migrate direct -> gesture")
        check(SwitchMethod.migrating(fromStored: nil) == .gesture, "migrate nil -> gesture")
        check(SwitchMethod.migrating(fromStored: "bogus") == .gesture, "migrate unknown -> gesture")
        check(SwitchMethod.migrating(fromStored: "keyboard") == .gesture, "migrate removed keyboard -> gesture")
        check(SwitchMethod.migrating(fromStored: "windowFocus") == .gesture, "migrate removed windowFocus -> gesture")
        check(SwitchMethod.migrating(fromStored: "gesture") == .gesture, "keep gesture")
        check(SwitchMethod.migrating(fromStored: "missionControl") == .missionControl, "keep missionControl")
        check(WorkspaceListStyle.migrating(fromStored: nil) == .numbers, "workspace list: nil -> numbers")
        check(WorkspaceListStyle.migrating(fromStored: "bogus") == .numbers, "workspace list: unknown -> numbers")
        check(WorkspaceListStyle.migrating(fromStored: "icons") == .icons, "workspace list: keep icons")
        check(Prefs.switcherStyle(fromStored: nil, legacyBool: nil) == .hud,
              "switcher style: default hud")
        check(Prefs.switcherStyle(fromStored: nil, legacyBool: true) == .hud,
              "switcher style: legacy bool true -> hud (missionControl retired)")
        check(Prefs.switcherStyle(fromStored: nil, legacyBool: false) == .hud,
              "switcher style: legacy bool false -> hud")
        check(Prefs.switcherStyle(fromStored: "hud", legacyBool: true) == .hud,
              "switcher style: stored string outranks legacy bool")
        check(Prefs.switcherStyle(fromStored: "missionControl", legacyBool: nil) == .hud,
              "switcher style: stored missionControl -> hud (retired)")
        check(Prefs.switcherStyle(fromStored: "bogus", legacyBool: nil) == .hud,
              "switcher style: unknown stored -> default")
        check(Prefs.thumbnailIconStyle(fromStored: nil, legacyIcons: nil, legacyLabels: nil) == .beforeName,
              "icon style: default beforeName")
        check(Prefs.thumbnailIconStyle(fromStored: nil, legacyIcons: false, legacyLabels: true) == .hidden,
              "icon style: legacy icons-off -> hidden")
        check(Prefs.thumbnailIconStyle(fromStored: nil, legacyIcons: true, legacyLabels: true) == .beforeName,
              "icon style: legacy names+icons -> beforeName")
        check(Prefs.thumbnailIconStyle(fromStored: nil, legacyIcons: true, legacyLabels: false) == .largeAbove,
              "icon style: legacy large-icons -> largeAbove")
        check(Prefs.thumbnailIconStyle(fromStored: "largeOver", legacyIcons: false, legacyLabels: nil) == .largeOver,
              "icon style: stored string outranks legacy bools")
        check(Prefs.thumbnailIconStyle(fromStored: "bogus", legacyIcons: nil, legacyLabels: nil) == .beforeName,
              "icon style: unknown stored -> default")
    }

    private static func symbolChecks(_ check: Check) {
        // These are informational: resolution depends on the OS. We only assert the
        // probes are callable (do not crash) and log what resolved.
        let missionControl = sm_missionControlSymbolsAvailable()
        print("INFO: mission-control symbols resolved: \(missionControl)")
        print("INFO: AX window-id symbol resolved: \(sm_axWindowIDSymbolAvailable())")
        check(true, "symbol resolution probes callable")
    }
}
