// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How SpeedySpaces switches to a clicked space. Each case maps to one SpaceSwitcher engine.
enum SwitchMethod: String, CaseIterable {
    case gesture          // synthetic dock-swipe CGEvents
    case missionControl   // press the space's button in Mission Control (Dock AX)

    var label: String {
        switch self {
        case .gesture:        return "Trackpad gesture (recommended)"
        case .missionControl: return "Mission Control button press"
        }
    }

    /// Map a stored preference string to a method, migrating removed/unknown values
    /// (the deleted `direct`, `keyboard`, and `windowFocus`) to the new default.
    static func migrating(fromStored raw: String?) -> SwitchMethod {
        guard let raw, let method = SwitchMethod(rawValue: raw) else { return .gesture }
        return method
    }
}

/// Animation feel for the gesture engine.
enum GestureAnimation: String, CaseIterable {
    case instant
    case natural
    var label: String { self == .instant ? "Instant" : "Natural" }
}

/// How the menubar workspace list renders each space (numbers or custom icons);
/// consumed by MenuBarStripView.
enum WorkspaceListStyle: String, CaseIterable {
    case numbers, icons

    /// Map a stored preference string to a style, defaulting unknown/nil to numbers.
    static func migrating(fromStored raw: String?) -> WorkspaceListStyle {
        guard let raw, let style = WorkspaceListStyle(rawValue: raw) else { return .numbers }
        return style
    }
}

/// Lightweight UserDefaults-backed preferences.
enum Prefs {
    private static let defaults = UserDefaults.standard

    static var switchMethod: SwitchMethod {
        get { SwitchMethod.migrating(fromStored: defaults.string(forKey: "switchMethod")) }
        set {
            defaults.set(newValue.rawValue, forKey: "switchMethod")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    static var gestureAnimation: GestureAnimation {
        get { GestureAnimation(rawValue: defaults.string(forKey: "gestureAnimation") ?? "") ?? .natural }
        set {
            defaults.set(newValue.rawValue, forKey: "gestureAnimation")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// When true (default) and multiple displays are present, the menubar shows the
    /// current space of the display you're actively working on, rather than a single
    /// global current space.
    static var menuBarFollowsFocusedDisplay: Bool {
        get { defaults.object(forKey: "menuBarFollowsFocusedDisplay") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "menuBarFollowsFocusedDisplay")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// All-displays menu bar only (follows-focused off): collapse every display other
    /// than the focused one to just its current workspace.
    static var menuBarCollapseUnfocusedDisplays: Bool {
        get { defaults.object(forKey: "menuBarCollapseUnfocusedDisplays") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarCollapseUnfocusedDisplays")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// All-displays menu bar only: leave out displays that have exactly one workspace
    /// (nothing to switch to there).
    static var menuBarHideSingleSpaceDisplays: Bool {
        get { defaults.object(forKey: "menuBarHideSingleSpaceDisplays") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarHideSingleSpaceDisplays")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// When true (default), custom space names are drawn onto the Mission Control spaces bar
    /// while Mission Control is open (the shield-level overlay).
    static var missionControlLabels: Bool {
        get { defaults.object(forKey: "missionControlLabels") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "missionControlLabels")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Bold weight for the Mission Control thumbnail name labels (default true). When false the
    /// labels use the regular system weight.
    static var missionControlLabelsBold: Bool {
        get { defaults.object(forKey: "missionControlLabelsBold") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "missionControlLabelsBold")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Where each space's custom icon sits on its thumbnail — on the switcher's tiles and
    /// in the Mission Control overlay alike.
    enum ThumbnailIconStyle: String {
        case beforeName // small icon leading the name, in the row above the thumbnail
        case largeAbove // large icon standing in for the name above the thumbnail (names hidden)
        case largeOver  // large icon centered ON the thumbnail; the name row stays above
        case hidden     // no icons
    }

    /// Pure resolver for the stored style + the legacy bool pair from the radio-group era
    /// ((labels, icons): names-only / names+inline icons / large icons / off).
    static func thumbnailIconStyle(fromStored raw: String?, legacyIcons: Bool?,
                                   legacyLabels: Bool?) -> ThumbnailIconStyle {
        if let raw, let style = ThumbnailIconStyle(rawValue: raw) { return style }
        guard legacyIcons ?? true else { return .hidden }
        return (legacyLabels ?? true) ? .beforeName : .largeAbove
    }

    static var thumbnailIconStyle: ThumbnailIconStyle {
        get {
            thumbnailIconStyle(fromStored: defaults.string(forKey: "thumbnailIconStyle"),
                               legacyIcons: defaults.object(forKey: "missionControlShowIcons") as? Bool,
                               legacyLabels: defaults.object(forKey: "missionControlLabels") as? Bool)
        }
        set {
            defaults.set(newValue.rawValue, forKey: "thumbnailIconStyle")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Whether name rows actually render: the names toggle, minus the one icon style that
    /// takes the names row over ("large icons above" stands in for the name).
    static var thumbnailNamesVisible: Bool {
        missionControlLabels && thumbnailIconStyle != .largeAbove
    }

    // MARK: - Floating switcher HUD

    /// When true (default), the switcher flashes briefly whenever the active space changes.
    static var switcherFlashOnSpaceChange: Bool {
        get { defaults.object(forKey: "switcherFlashOnSpaceChange") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "switcherFlashOnSpaceChange")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Minimum time (seconds) the switcher stays on screen when the active workspace changes
    /// (default 1.0, clamped 0.5–5). A floor, not a cap — hover or a rapid burst of switches
    /// can keep it up longer. Raise it when a programmatic/quick switch flashes by too fast.
    static var switcherFlashDuration: TimeInterval {
        get {
            let raw = defaults.object(forKey: "switcherFlashDuration") as? Double ?? 1.0
            return min(max(raw, 0.5), 5.0)
        }
        set {
            defaults.set(min(max(newValue, 0.5), 5.0), forKey: "switcherFlashDuration")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// When true (default), the hold-to-show shortcut is registered; unchecking it disables
    /// the hold trigger without discarding the recorded chord.
    static var switcherHoldEnabled: Bool {
        get { defaults.object(forKey: "switcherHoldEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "switcherHoldEnabled")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// What the hold-to-show chord presents.
    enum SwitcherStyle: String {
        case hud            // the app's own floating bar
        case missionControl // RETIRED: real Mission Control, spaces bar auto-expanded
    }

    /// Pure resolver for the stored style + legacy bool from the two-style era.
    ///
    /// `.missionControl` was removed as a user-selectable type; the case remains only so
    /// stored configurations still decode. It always resolves to `.hud` now, so a machine
    /// that had it selected isn't stranded on a style with no control left to change it.
    static func switcherStyle(fromStored raw: String?, legacyBool: Bool?) -> SwitcherStyle {
        _ = legacyBool
        if let raw, let style = SwitcherStyle(rawValue: raw), style != .missionControl { return style }
        return .hud
    }

    static var switcherStyle: SwitcherStyle {
        get {
            switcherStyle(fromStored: defaults.string(forKey: "switcherStyle"),
                          legacyBool: defaults.object(forKey: "switcherUsesNativeMissionControl") as? Bool)
        }
        set {
            defaults.set(newValue.rawValue, forKey: "switcherStyle")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Where the floating bar (`SwitcherStyle.hud`) sits on screen.
    enum SwitcherPosition: String {
        case mimicMissionControl // top band, edge to edge — where MC's own bar lives
        case classicPopover      // vertically centered, hugging the tiles (≤80% width)
    }

    static var switcherPosition: SwitcherPosition {
        get { SwitcherPosition(rawValue: defaults.string(forKey: "switcherPosition") ?? "")
                ?? .classicPopover }
        set {
            defaults.set(newValue.rawValue, forKey: "switcherPosition")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }


    // MARK: - Menu bar item composition
    //
    // The menubar item is a strip of one or more segments. `showIcon`/`showName`/`showNumber`
    // control how the *current* space is drawn; `showSwitcher` adds a clickable numbered square
    // per space on the focused display (the current space's square is replaced by its
    // icon/name/number when those are on). If all are off the item falls back to a plain grid
    // icon that opens the menu.

    static var menuBarShowIcon: Bool {
        get { defaults.object(forKey: "menuBarShowIcon") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "menuBarShowIcon")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    static var menuBarShowName: Bool {
        get { defaults.object(forKey: "menuBarShowName") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "menuBarShowName")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Show the current space's number (1-based position on its display) in the menu bar
    /// segment, before the name when both are on ("3 · Media").
    static var menuBarShowNumber: Bool {
        get { defaults.object(forKey: "menuBarShowNumber") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarShowNumber")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    static var menuBarShowSwitcher: Bool {
        get { defaults.object(forKey: "menuBarShowSwitcher") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarShowSwitcher")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Size (pt) of the CURRENT workspace's menu bar contents (default 22, clamped 12–22):
    /// its square/icon tile, its icon + name segment and its name font, plus the grid
    /// fallback; see MenuBarStripView.numberMetrics/stripScale. The other workspaces'
    /// squares follow `menuBarInactiveSquareSize`.
    static var menuBarSwitcherSquareSize: CGFloat {
        get {
            let raw = defaults.object(forKey: "menuBarSwitcherSquareSize") as? Double ?? 22
            return CGFloat(min(max(raw, 12), 22))
        }
        set {
            defaults.set(Double(newValue), forKey: "menuBarSwitcherSquareSize")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Size (pt) of the NON-current workspaces' squares / icon tiles in the menu bar
    /// (default 18, clamped 12–22) — a notch below the current workspace's 22, so the
    /// focused space reads as the larger one without the others being hard to hit.
    static var menuBarInactiveSquareSize: CGFloat {
        get {
            let raw = defaults.object(forKey: "menuBarInactiveSquareSize") as? Double ?? 18
            return CGFloat(min(max(raw, 12), 22))
        }
        set {
            defaults.set(Double(newValue), forKey: "menuBarInactiveSquareSize")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Horizontal spacing (pt) added around every menu bar icon — the workspace
    /// squares/tiles, the current-space icon/name segment, and the grid fallback — on top
    /// of their built-in padding (default 4, clamped 0–16). The margin lands on both sides
    /// of each icon, so with the inter-segment gap fixed at 0 it is what separates adjacent
    /// icons; higher values give every icon more breathing room.
    static var menuBarSpacing: CGFloat {
        get {
            let raw = defaults.object(forKey: "menuBarSpacing") as? Double ?? 4
            return CGFloat(min(max(raw, 0), 16))
        }
        set {
            defaults.set(Double(newValue), forKey: "menuBarSpacing")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Padding (pt) at the leading and trailing extremities of the whole menu bar item's
    /// contents (default 6, clamped 0–20).
    static var menuBarEdgePadding: CGFloat {
        get {
            let raw = defaults.object(forKey: "menuBarEdgePadding") as? Double ?? 6
            return CGFloat(min(max(raw, 0), 20))
        }
        set {
            defaults.set(Double(newValue), forKey: "menuBarEdgePadding")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Background fills for the whole menu bar item (default true): grey behind
    /// non-current squares, and the flipped labelColor pill behind the current space's
    /// segment (in the workspace list or standalone). When false the inactive squares
    /// render as bare glyphs and only the current square keeps its flipped fill.
    static var menuBarSwitcherGreyBackground: Bool {
        get { defaults.object(forKey: "menuBarSwitcherGreyBackground") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "menuBarSwitcherGreyBackground")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// Swap BG↔FG across the menu bar item while backgrounds are on (default false):
    /// the other spaces wear the flipped labelColor fill and the current space the grey
    /// one. Ignored (and hidden in Settings) while backgrounds are off.
    static var menuBarSwitcherInvertColours: Bool {
        get { defaults.object(forKey: "menuBarSwitcherInvertColours") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarSwitcherInvertColours")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    // MARK: - Global keyboard shortcuts
    //
    // One decomposed key pair per action (absent keyCode = unset — all bindings are
    // opt-in). Per-space bindings live in SpaceMetadata, not here.

    /// The modifier set Caps Lock maps to while held. RETIRED with capsLockHyperKey —
    /// retained only so a stored value survives, and for the self-tests of flags(fromMapping:).
    /// Sanitized NSEvent bits; default ⌘⌥⌃. 0 = caps injects nothing while remapped.
    static var capsLockMapping: UInt {
        get {
            guard let raw = defaults.object(forKey: "capsLockMapping") as? Int else {
                return (1 << 20) | (1 << 19) | (1 << 18)   // ⌘⌥⌃ (NSEvent bits)
            }
            return ShortcutSpec.sanitizeRaw(UInt(bitPattern: raw))
        }
        set {
            defaults.set(Int(bitPattern: ShortcutSpec.sanitizeRaw(newValue)), forKey: "capsLockMapping")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// RETIRED: Caps Lock remapping was removed as a feature; the control is gone from
    /// Settings. This now always reads false, which matters for cleanup rather than
    /// behaviour: the remap is a SYSTEM-WIDE `hidutil` UserKeyMapping (Caps Lock → F18)
    /// that outlives the app, so `CapsLockHyper.apply()` must still run at launch and take
    /// the `deactivate()` branch to tear it down. Without that, a machine that had the
    /// feature on would be left with a dead Caps Lock and no control to fix it.
    static var capsLockHyperKey: Bool { false }

    // MARK: - Global modifier (Switching Workspaces)

    /// When on, every Switching Workspaces shortcut is auto-assigned as `globalModifier` + its
    /// natural key (digit for Switch-to-Space-N, ←/→ for Prev/Next) and written to the matching
    /// native macOS shortcut. When off, each switching row is an editable native binding. Default off.
    static var globalModifierEnabled: Bool {
        get { defaults.bool(forKey: "globalModifierEnabled") }
        set {
            defaults.set(newValue, forKey: "globalModifierEnabled")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// The shared modifier set the Switching shortcuts use while `globalModifierEnabled`.
    /// Sanitized NSEvent bits; default ⌃ (so the auto-assignment matches macOS's own ⌃1…⌃←/→).
    static var globalModifier: UInt {
        get {
            guard let raw = defaults.object(forKey: "globalModifier") as? Int else {
                return 1 << 18   // ⌃ (NSEvent bit)
            }
            return ShortcutSpec.sanitizeRaw(UInt(bitPattern: raw))
        }
        set {
            defaults.set(Int(bitPattern: ShortcutSpec.sanitizeRaw(newValue)), forKey: "globalModifier")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    // MARK: - Window-move shortcuts

    /// When on, the "move window to workspace" shortcuts are derived (native switch chord +
    /// `moveExtraModifier`, read-only). When off, they become ordinary reprogrammable chords
    /// stored per-action via `hotkey(for:)`. Default on (preserving the derived behavior).
    static var moveExtraModifierEnabled: Bool {
        get { defaults.object(forKey: "moveExtraModifierEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "moveExtraModifierEnabled")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// The extra modifier the "move window to workspace" shortcuts add on top of the
    /// native switch chord (Settings ▸ Shortcuts ▸ Moving Windows). So if "Next Space"
    /// is ⌃→, "Move & Follow Next" fires on ⌃+extra+→. Sanitized NSEvent bits; default ⇧.
    static var moveExtraModifier: UInt {
        get {
            guard let raw = defaults.object(forKey: "moveExtraModifier") as? Int else {
                return 1 << 17   // ⇧ (NSEvent bit)
            }
            return ShortcutSpec.sanitizeRaw(UInt(bitPattern: raw))
        }
        set {
            defaults.set(Int(bitPattern: ShortcutSpec.sanitizeRaw(newValue)), forKey: "moveExtraModifier")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    static func hotkeyKeyCodeKey(for action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue).keyCode"
    }
    static func hotkeyModifiersKey(for action: HotkeyAction) -> String {
        "hotkey.\(action.rawValue).modifiers"
    }

    static func hotkey(for action: HotkeyAction) -> ShortcutSpec? {
        guard let kc = defaults.object(forKey: hotkeyKeyCodeKey(for: action)) as? Int,
              kc >= 0, kc <= Int(UInt16.max) else { return nil }
        let mods = defaults.object(forKey: hotkeyModifiersKey(for: action)) as? Int ?? 0
        return ShortcutSpec(keyCode: UInt16(kc), modifiers: UInt(bitPattern: mods))
    }

    static func setHotkey(_ spec: ShortcutSpec?, for action: HotkeyAction) {
        if let spec {
            defaults.set(Int(spec.keyCode), forKey: hotkeyKeyCodeKey(for: action))
            defaults.set(Int(bitPattern: spec.modifiers), forKey: hotkeyModifiersKey(for: action))
        } else {
            defaults.removeObject(forKey: hotkeyKeyCodeKey(for: action))
            defaults.removeObject(forKey: hotkeyModifiersKey(for: action))
        }
        NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
    }

    /// Ship default chords for the app-owned actions once, only where the user hasn't set their
    /// own (so it's non-destructive and a cleared binding stays cleared). Runs at launch.
    static func seedDefaultShortcutsIfNeeded() {
        guard !defaults.bool(forKey: "didSeedDefaultShortcuts") else { return }
        defaults.set(true, forKey: "didSeedDefaultShortcuts")
        let ctrl: UInt = 1 << 18, opt: UInt = 1 << 19, shift: UInt = 1 << 17
        func seed(_ action: HotkeyAction, _ keyCode: UInt16, _ mods: UInt) {
            if hotkey(for: action) == nil {
                setHotkey(ShortcutSpec(keyCode: keyCode, modifiers: mods), for: action)
            }
        }
        seed(.backAndForth, 48, ctrl)                              // ⌃⇥
        seed(.moveDisplayNext, 124, ctrl | opt | shift)           // ⌃⌥⇧→
        seed(.moveDisplayPrev, 123, ctrl | opt | shift)           // ⌃⌥⇧←
        seed(.holdSwitcher, ShortcutSpec.noKeyCode, ctrl)         // hold ⌃ to show the switcher
    }

    /// Next/previous space (and the relative window moves) wrap past the ends. When on, the
    /// switcher's native-switch tap ALSO makes macOS's own Move-left/right-a-space shortcuts
    /// wrap (it swallows the edge press and switches to the opposite end). Default off: clamp,
    /// matching the stock system ⌃-arrow behavior.
    static var hotkeyWrapAround: Bool {
        get { defaults.object(forKey: "hotkeyWrapAround") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "hotkeyWrapAround")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    static var workspaceListStyle: WorkspaceListStyle {
        get { WorkspaceListStyle.migrating(fromStored: defaults.string(forKey: "workspaceListStyle")) }
        set {
            defaults.set(newValue.rawValue, forKey: "workspaceListStyle")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }

    /// The workspace list's fallback icon (used by the icons style for spaces without
    /// a custom icon). Reuses SpaceMetadata so
    /// IconRendering draws it directly; `name` stays nil. The getter always returns a
    /// renderable icon: unset/invalid storage falls back to sfsymbol "macwindow".
    static var workspaceListDefaultIcon: SpaceMetadata {
        get {
            var meta = SpaceMetadata()
            let storedType = IconType(rawValue: defaults.string(forKey: "workspaceListIconType") ?? "")
            let storedValue = defaults.string(forKey: "workspaceListIconValue")
            if let storedType, storedType != .none, let storedValue, !storedValue.isEmpty {
                meta.iconType = storedType
                meta.iconValue = storedValue
            } else {
                meta.iconType = .sfsymbol
                meta.iconValue = "macwindow"
            }
            return meta
        }
        set {
            defaults.set(newValue.iconType.rawValue, forKey: "workspaceListIconType")
            defaults.set(newValue.iconValue, forKey: "workspaceListIconValue")
            NotificationCenter.default.post(name: .speedySpacesPrefsChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let speedySpacesPrefsChanged = Notification.Name("speedySpacesPrefsChanged")
    /// Posted by CapsLockHyper when the caps-as-hyper layer engages/releases
    /// (userInfo["down"]: Bool) — recorders treat it as a modifier press.
    static let speedySpacesHyperKeyChanged = Notification.Name("speedySpacesHyperKeyChanged")
    static let speedySpacesSwitchOutcome = Notification.Name("speedySpacesSwitchOutcome")
    /// Posted just before the app itself asks the Dock to open Mission Control, so the
    /// overlay can start probing immediately instead of waiting for its idle poll.
    static let speedySpacesMissionControlWillOpen = Notification.Name("speedySpacesMissionControlWillOpen")
    /// Posted just before the app itself asks the Dock to CLOSE Mission Control (e.g. the
    /// native hold chord releasing), so the overlay can fly its labels off in sync with the
    /// close animation instead of waiting to detect the teardown after it finishes.
    static let speedySpacesMissionControlWillClose = Notification.Name("speedySpacesMissionControlWillClose")
    /// Posted by MetadataStore after any per-space metadata write (names, icons, and
    /// per-space shortcuts) so listeners like HotkeyManager can re-register.
    static let speedySpacesMetadataChanged = Notification.Name("speedySpacesMetadataChanged")
    /// Posted at the end of every SpacesManager.refresh(), after `spaces` (including the
    /// optimistic switch prediction) is updated — the multicast sibling of `onChange`.
    static let speedySpacesSpacesChanged = Notification.Name("speedySpacesSpacesChanged")
    /// Posted when a switch is requested but deferred behind a Show-Desktop dismiss — the HUD
    /// flashes immediately so the popover bridges the dismiss+settle delay and stays visible
    /// continuously until the space actually changes. userInfo["display"] = target display id.
    static let speedySpacesAnticipateSwitch = Notification.Name("speedySpacesAnticipateSwitch")
    /// Posted by MissionControlOverlay's detector when Mission Control's bar appears /
    /// disappears (only while that engine is enabled) — used to keep the switcher HUD
    /// from drawing over the real Mission Control.
    static let speedySpacesMissionControlOpened = Notification.Name("speedySpacesMissionControlOpened")
    static let speedySpacesMissionControlClosed = Notification.Name("speedySpacesMissionControlClosed")
    /// Posted after HotkeyManager finishes a registration pass, so settings UIs can refresh
    /// their per-shortcut "registered / in use" status indicators.
    static let speedySpacesHotkeysReloaded = Notification.Name("speedySpacesHotkeysReloaded")
    /// Posted by NativeShortcutsWatcher when the user's real macOS Spaces shortcuts
    /// (symbolic hotkeys 79/81/118…) change — externally (System Settings) or via our own
    /// SystemShortcuts.setBinding — so the switching rows and derived move chords re-track.
    static let speedySpacesNativeShortcutsChanged = Notification.Name("speedySpacesNativeShortcutsChanged")
}
