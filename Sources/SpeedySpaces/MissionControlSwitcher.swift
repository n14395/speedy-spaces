// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices

/// Switches by opening Mission Control and pressing the target space's button in the
/// Dock's accessibility tree (Hammerspoon's technique). May report .unavailable on
/// macOS versions where the Dock no longer publishes the `mc.*` AX identifiers.
final class MissionControlSwitcher: SpaceSwitcher {
    let method: SwitchMethod = .missionControl

    private var mcWaitTime: TimeInterval = 0.3

    func availability(for target: Space, _ ctx: SwitchContext) -> SwitchAvailability {
        guard sm_missionControlSymbolsAvailable() else { return .unavailable("CoreDock symbol unavailable") }
        guard ctx.isTrusted else { return .unavailable("Accessibility required for Mission Control") }
        return .available
    }

    func perform(_ target: Space, _ ctx: SwitchContext) throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            NSLog("[SpeedySpaces] MC: no Dock process"); return
        }
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)

        // Open Mission Control.
        NotificationCenter.default.post(name: .speedySpacesMissionControlWillOpen, object: nil)
        _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)

        // Poll for the `mc` group (≤2s).
        guard let mc = waitForChild(of: dockAX, identifier: "mc", timeout: 2.0) else {
            NSLog("[SpeedySpaces] MC: 'mc' group never appeared (Dock AX tree may have changed on this OS)")
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)   // toggle closed
            return
        }
        // Let the AX children fully form.
        Thread.sleep(forTimeInterval: mcWaitTime)

        // Descend mc.display (matching the target display) -> mc.spaces -> mc.spaces.list.
        guard let display = child(of: mc, where: { self.identifier($0) == "mc.display" && self.displayID($0) == self.cgDisplayID(for: target) })
                ?? firstChild(of: mc, identifier: "mc.display"),
              let spacesGroup = firstChild(of: display, identifier: "mc.spaces"),
              let list = firstChild(of: spacesGroup, identifier: "mc.spaces.list"),
              let children = axChildren(list), target.ordinalOnDisplay < children.count else {
            NSLog("[SpeedySpaces] MC: could not locate mc.spaces.list child for target")
            _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
            return
        }
        AXUIElementPerformAction(children[target.ordinalOnDisplay], kAXPressAction as CFString)
        // Pressing a space button auto-dismisses Mission Control.
    }

    // MARK: - AX helpers

    private func axChildren(_ el: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
    private func identifier(_ el: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXIdentifier" as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func displayID(_ el: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXDisplayID" as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }
    private func cgDisplayID(for target: Space) -> Int? {
        let screens = NSScreen.screens
        guard target.displayIndex < screens.count,
              let num = screens[target.displayIndex].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return num.intValue
    }
    private func child(of el: AXUIElement, where pred: (AXUIElement) -> Bool) -> AXUIElement? {
        axChildren(el)?.first(where: pred)
    }
    private func firstChild(of el: AXUIElement, identifier id: String) -> AXUIElement? {
        axChildren(el)?.first { self.identifier($0) == id }
    }
    private func waitForChild(of el: AXUIElement, identifier id: String, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = firstChild(of: el, identifier: id) { return hit }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }
}
