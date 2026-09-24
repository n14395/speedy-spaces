// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Switches spaces by posting synthetic dock-swipe CGEvents — the default engine.
/// On macOS 27+, standard gesture events are silently ignored unless augmented with
/// a serialized IOHID queue payload (see `SystemEventPoster` below).
final class GestureSwitcher {
    let method: SwitchMethod = .gesture

    // MARK: - Pure computation

    /// Steps/direction/velocity for a same-display switch, or nil if not same-display
    /// or already there. Dock swipes move between adjacent spaces (incl. fullscreen),
    /// so distance is the difference of `ordinalOnDisplay`.
    static func calculate(target: Space, current: Space,
                          animation: GestureAnimation) -> (steps: Int, goRight: Bool, velocity: Double)? {
        guard target.displayIndex == current.displayIndex else { return nil }
        let steps = abs(target.ordinalOnDisplay - current.ordinalOnDisplay)
        guard steps > 0 else { return nil }
        let goRight = target.ordinalOnDisplay > current.ordinalOnDisplay
        let velocity: Double
        switch animation {
        case .instant:
            velocity = min(2000.0 * Double(steps), 32000.0)   // 16.16 fixed-point overflow guard
        case .natural:
            velocity = flickVelocity
        }
        return (steps, goRight, velocity)
    }

    /// Release velocity of a natural-mode flick (see SystemEventPoster.postFlick).
    /// Measured on macOS 27 by timing the raw current-space flip: ≤30 gives the Dock's
    /// smooth full slide (~0.85 s flip delta, both directions); ≥60 collapses to a hard
    /// cut, as does ANY velocity when progress is posted pre-completed at ±1.0 (the
    /// instant path). Do not "round up" — the animated regime ends between 30 and 60.
    static let flickVelocity = 30.0

    /// Double -> 16.16 fixed-point, clamped to Int32 range, never truncating a small
    /// non-zero value to 0.
    static func toFixedPoint(_ value: Double) -> Int32 {
        let scaled = value * 65536.0
        if scaled >= Double(Int32.max) { return Int32.max }
        if scaled <= Double(Int32.min) { return Int32.min }
        let fixed = Int32(scaled)
        if fixed == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    static func selfChecks(_ check: SelfTest.Check) {
        func space(_ ordinal: Int, display: Int) -> Space {
            Space(uuid: "u\(display)-\(ordinal)", managedSpaceID: ordinal, type: 0,
                  displayIndex: display, displayIdentifier: "d\(display)",
                  ordinalOnDisplay: ordinal, isCurrent: false)
        }
        let r = calculate(target: space(5, display: 0), current: space(2, display: 0), animation: .instant)
        check(r?.steps == 3 && r?.goRight == true, "gesture: 2->5 = 3 steps right")
        let l = calculate(target: space(1, display: 0), current: space(4, display: 0), animation: .natural)
        check(l?.steps == 3 && l?.goRight == false, "gesture: 4->1 = 3 steps left")
        check(l?.velocity == flickVelocity, "gesture: natural uses flick velocity")
        check(calculate(target: space(3, display: 0), current: space(3, display: 0), animation: .instant) == nil,
              "gesture: same space -> nil")
        check(calculate(target: space(1, display: 1), current: space(0, display: 0), animation: .instant) == nil,
              "gesture: cross-display -> nil (same-display calc)")
        check(r?.velocity == 6000, "gesture: instant velocity 3*2000")
        check(toFixedPoint(50000) == Int32.max, "gesture: fixed-point clamps overflow")
        check(toFixedPoint(0.00001) == 1, "gesture: tiny positive -> 1")
    }

    // MARK: - Undocumented CGEvent field constants
    //
    // CGEventField(rawValue:) is optional due to RawRepresentable, but it wraps
    // any UInt32 without validation — these will never return nil.

    static let eventTypeField = CGEventField(rawValue: 55)!
    static let gestureHIDType = CGEventField(rawValue: 110)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let swipeVelocityX = CGEventField(rawValue: 129)!
    static let swipeVelocityY = CGEventField(rawValue: 130)!
    static let gesturePhase = CGEventField(rawValue: 132)!
    // Additional fields for macOS 27 (from joshuarli/iss)
    static let swipePositionX = CGEventField(rawValue: 125)!
    static let swipePositionY = CGEventField(rawValue: 126)!
    static let gesturePhase2 = CGEventField(rawValue: 134)!
    static let gestureFlavor = CGEventField(rawValue: 138)!
    static let eventTimestamp = CGEventField(rawValue: 169)!

    // Event type / HID type constants
    static let dockControl: Int64 = 30
    static let hidDockSwipe: Int64 = 23
    static let motionHorizontal: Int64 = 1
    static let motionVertical: Int64 = 2   // the Mission Control open/close swipe axis
}

// MARK: - SpaceSwitcher conformance

extension GestureSwitcher: SpaceSwitcher {
    func availability(for target: Space, _ ctx: SwitchContext) -> SwitchAvailability {
        guard ctx.current != nil else { return .unavailable("current space unknown on that display") }
        // Posting CGEvents requires Accessibility in practice.
        guard ctx.isTrusted else { return .unavailable("Accessibility required to post gestures") }
        return .available
    }

    func perform(_ target: Space, _ ctx: SwitchContext) throws {
        guard let current = ctx.current else { return }
        let plan = Self.calculate(target: target, current: current, animation: ctx.animation)
        guard let plan else { return }
        // Dock swipes act on the display under the pointer, so park it on the target's
        // display for the duration. The restore is DELAYED: the Dock consumes the posted
        // events asynchronously after perform() returns, so restoring synchronously (the
        // old `defer`) re-routed every cross-display switch to the pointer's display.
        let restorePointer = DisplayRouting.parkPointer(on: target)
        let poster = SystemEventPoster()
        for step in 0..<plan.steps {
            switch ctx.animation {
            case .natural:
                // A beat between successive flicks so the Dock treats each as its own
                // swipe instead of coalescing the extra steps away.
                if step > 0 { usleep(60_000) }
                poster.postFlick(goRight: plan.goRight, velocity: plan.velocity)
            case .instant:
                poster.postDockSwipe(phase: 1, goRight: plan.goRight, velocity: plan.velocity)
                poster.postDockSwipe(phase: 2, goRight: plan.goRight, velocity: plan.velocity)
                poster.postDockSwipe(phase: 4, goRight: plan.goRight, velocity: plan.velocity)
            }
        }
        if let restorePointer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: restorePointer)
        }
    }
}

// MARK: - macOS 27 IOHID Payload Structures
//
// macOS 27 validates synthetic dock-swipe CGEvents against a serialized IOHID
// queue payload attached to CGEvent field 4205. Without this payload, synthetic
// gesture events are silently ignored.
//
// The workaround:
// 1. Create CGEvent with standard gesture fields
// 2. Serialize via CGEventCreateData()
// 3. Append IOHIDSystemQueueElement payload with Field 4205 tag
// 4. Deserialize via CGEventCreateFromData()
// 5. Post the augmented event
//
// Struct layouts and field values derived from:
// - joshuarli/iss: https://github.com/joshuarli/iss (MIT License)
// - mgbowen/FasterSwiper: https://github.com/mgbowen/FasterSwiper
// - CGEvent serialization format: https://gist.github.com/mgbowen/5548f18ada2e37b23c9e86a8d80b71dc
//
// All values are little-endian. Position/velocity use 16.16 fixed-point format.

/// Base structure embedded in all IOHID event types (16 bytes).
private struct IOHIDEventBase {
    var size: UInt32         // Total size of this event structure
    var type: UInt32         // Event type: 23 = FluidTouchGesture, 9 = Velocity
    var options: UInt32      // Gesture phase encoded in high byte: (phase & 0xFF) << 24
    var depth: UInt8         // Nesting depth (1 for velocity as child of gesture)
    var reserved: (UInt8, UInt8, UInt8)  // Padding for alignment
}

/// Fluid touch gesture event data (40 bytes total).
/// Describes a dock swipe gesture with position and progress.
private struct IOHIDFluidTouchGestureData {
    var base: IOHIDEventBase      // 16 bytes - includes type=23 (FluidTouchGesture)
    var positionX: Int32          // 16.16 fixed-point X position
    var positionY: Int32          // 16.16 fixed-point Y position
    var positionZ: Int32          // 16.16 fixed-point Z position (usually 0)
    var swipeMask: UInt32         // Direction flags (not used for dock swipe)
    var gestureMotion: UInt16     // Motion axis: 1 = horizontal, 2 = vertical
    var gestureFlavor: UInt16     // Gesture type: 3 = kIOHIDGestureFlavorDockPrimary
    var swipeProgress: Int32      // 16.16 fixed-point swipe progress (-1.0 to 1.0)
}

/// Velocity event data (28 bytes total).
/// Attached as child event when gesture has velocity or at phase Ended.
private struct IOHIDVelocityEventData {
    var base: IOHIDEventBase      // 16 bytes - includes type=9 (Velocity), depth=1
    var velocityX: Int32          // 16.16 fixed-point X velocity
    var velocityY: Int32          // 16.16 fixed-point Y velocity
    var velocityZ: Int32          // 16.16 fixed-point Z velocity (usually 0)
}

/// Queue element header prepended to IOHID event data (28 bytes).
/// Contains metadata about the event batch.
private struct IOHIDSystemQueueElementHeader {
    var timestamp: UInt64         // Mach absolute time
    var senderID: UInt64          // Sender identifier (can be 0)
    var options: UInt32           // Options flags (usually 0)
    var attributeLength: UInt32   // Length of attributes (usually 0)
    var eventCount: UInt32        // Number of events: 1 (gesture only) or 2 (gesture + velocity)
}

/// Posts real CGEvents to the system.
/// On macOS 27+, augments events with the required IOHID payload.
struct SystemEventPoster {

    // MARK: - IOHID Constants (from joshuarli/iss)

    private static let kIOHIDEventTypeVelocity: UInt32 = 9
    private static let kIOHIDEventTypeFluidTouchGesture: UInt32 = 23
    private static let kIOHIDGestureFlavorDockPrimary: UInt16 = 3

    // MARK: - macOS Version Detection

    /// True if running macOS 27+, which requires IOHID payload augmentation.
    private static let requiresAugmentation: Bool = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }()

    // MARK: - Posting

    /// A short flick, matching the phase anatomy of a real three-finger swipe: began at
    /// progress 0, a brief ramp of changed events, then ended at a small progress with
    /// release velocity — the Dock then finishes the slide with its own smooth animation.
    /// This partial-progress shape is what makes the slide animate at all: a drag posted
    /// pre-completed at ±1.0 (the instant path) leaves the Dock nothing to animate and
    /// lands as a hard cut. The inter-event sleeps give the events genuinely increasing
    /// timestamps, like real fingers.
    func postFlick(goRight: Bool, velocity: Double, vertical: Bool = false) {
        postDockSwipe(phase: 1, goRight: goRight, velocity: 0, progress: 0, vertical: vertical)
        for ramp in [0.05, 0.10, 0.15] {
            usleep(8_000)
            postDockSwipe(phase: 2, goRight: goRight, velocity: velocity, progress: ramp,
                          vertical: vertical)
        }
        usleep(8_000)
        postDockSwipe(phase: 4, goRight: goRight, velocity: velocity, progress: 0.15,
                      vertical: vertical)
    }

    /// `progress` defaults to a fully-completed drag (±1.0), which is what the instant
    /// path posts; postFlick and `--post-swipe` pass partial values. `vertical` posts on
    /// the Mission Control open/close axis instead — `goRight` then means positive
    /// progress, which by Mac Mouse Fix's convention is swipe DOWN (unverified here).
    func postDockSwipe(
        phase: Int64, goRight: Bool, velocity: Double, progress: Double = 1.0,
        vertical: Bool = false
    ) {
        let progress = goRight ? progress : -progress
        let vel = goRight ? velocity : -velocity

        guard let event = CGEvent(source: nil) else { return }

        // Standard gesture fields (work on all macOS versions)
        event.setIntegerValueField(
            GestureSwitcher.eventTypeField,
            value: GestureSwitcher.dockControl)
        event.setIntegerValueField(
            GestureSwitcher.gestureHIDType,
            value: GestureSwitcher.hidDockSwipe)
        event.setIntegerValueField(
            GestureSwitcher.gesturePhase, value: phase)
        event.setDoubleValueField(
            GestureSwitcher.swipeProgress, value: progress)
        event.setIntegerValueField(
            GestureSwitcher.swipeMotion,
            value: vertical ? GestureSwitcher.motionVertical : GestureSwitcher.motionHorizontal)
        event.setDoubleValueField(
            GestureSwitcher.swipeVelocityX, value: vertical ? 0 : vel)
        event.setDoubleValueField(
            GestureSwitcher.swipeVelocityY, value: vertical ? vel : 0)

        // Additional fields for macOS 27 (from joshuarli/iss)
        event.setIntegerValueField(GestureSwitcher.gesturePhase2, value: phase)
        event.setDoubleValueField(GestureSwitcher.gestureFlavor, value: 3.0)
        event.setDoubleValueField(
            GestureSwitcher.eventTimestamp,
            value: Double(mach_absolute_time()))
        event.setDoubleValueField(GestureSwitcher.swipePositionX, value: 0.1)

        if Self.requiresAugmentation {
            postAugmentedEvent(event, phase: phase, velocity: vel, vertical: vertical)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - macOS 27 Event Augmentation

    /// Posts a CGEvent augmented with the IOHID payload required by macOS 27.
    ///
    /// macOS 27 validates synthetic dock-swipe events against a serialized IOHID
    /// queue element in CGEvent field 4205. This method:
    /// 1. Serializes the event to bytes via CGEventCreateData()
    /// 2. Builds an IOHIDSystemQueueElement with gesture/velocity data
    /// 3. Appends it with the Field 4205 tag format
    /// 4. Deserializes back via CGEventCreateFromData()
    ///
    /// Falls back to posting the original event if serialization fails.
    private func postAugmentedEvent(_ event: CGEvent, phase: Int64, velocity: Double,
                                    vertical: Bool = false) {
        // Step 1: Serialize the CGEvent to bytes
        guard let serializedData = event.data else {
            event.post(tap: .cgSessionEventTap)
            return
        }

        // Step 2: Build the IOHIDSystemQueueElement payload
        // Contains: header (28 bytes) + gesture data (40 bytes) + optional velocity (28 bytes)
        let payload = buildIOHIDPayload(event: event, phase: phase, velocity: velocity,
                                        vertical: vertical)

        // Step 3: Append Field 4205 tag + payload to serialized event
        // Tag format (big-endian): [size_hi][size_lo][0x10][0x6D][payload...]
        var bytes = Data(referencing: serializedData)
        appendField4205(to: &bytes, payload: payload)

        // Step 4: Deserialize back to CGEvent and post
        if let augmented = CGEvent(withDataAllocator: kCFAllocatorDefault, data: bytes as CFData) {
            augmented.post(tap: .cgSessionEventTap)
        } else {
            // Fallback: post original (won't work on macOS 27, but better than nothing)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Builds the IOHIDSystemQueueElement payload for field 4205.
    /// Structure: Header (28 bytes) + FluidTouchGestureData (40 bytes) + VelocityData (28 bytes)
    private func buildIOHIDPayload(event: CGEvent, phase: Int64, velocity: Double,
                                   vertical: Bool = false) -> Data {
        let timestamp = event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        let progress = event.getDoubleValueField(GestureSwitcher.swipeProgress)
        let posX = event.getDoubleValueField(GestureSwitcher.swipePositionX)
        let posY = event.getDoubleValueField(GestureSwitcher.swipePositionY)

        // Always include velocity event (required for reliable switching)
        let eventCount: UInt32 = 2

        var data = Data()

        // Header (28 bytes)
        var header = IOHIDSystemQueueElementHeader(
            timestamp: timestamp,
            senderID: 0,
            options: 0,
            attributeLength: 0,
            eventCount: eventCount
        )
        withUnsafeBytes(of: &header) { data.append(contentsOf: $0) }

        // FluidTouchGestureData (40 bytes)
        var gesture = IOHIDFluidTouchGestureData(
            base: IOHIDEventBase(
                size: UInt32(MemoryLayout<IOHIDFluidTouchGestureData>.size),
                type: Self.kIOHIDEventTypeFluidTouchGesture,
                options: UInt32((phase & 0xFF) << 24),
                depth: 0,
                reserved: (0, 0, 0)
            ),
            positionX: GestureSwitcher.toFixedPoint(posX),
            positionY: GestureSwitcher.toFixedPoint(posY),
            positionZ: 0,
            swipeMask: 0,
            gestureMotion: vertical ? 2 : 1,
            gestureFlavor: Self.kIOHIDGestureFlavorDockPrimary,
            // IOHID convention: negative progress = going right (opposite of CGEvent)
            swipeProgress: GestureSwitcher.toFixedPoint(-progress)
        )
        withUnsafeBytes(of: &gesture) { data.append(contentsOf: $0) }

        // VelocityEventData (28 bytes)
        var velocityEvent = IOHIDVelocityEventData(
            base: IOHIDEventBase(
                size: UInt32(MemoryLayout<IOHIDVelocityEventData>.size),
                type: Self.kIOHIDEventTypeVelocity,
                options: 0,
                depth: 1,  // child of gesture event
                reserved: (0, 0, 0)
            ),
            // IOHID convention: negative velocity = going right (opposite of CGEvent);
            // the vertical axis mirrors the same flip.
            velocityX: vertical ? 0 : GestureSwitcher.toFixedPoint(-velocity),
            velocityY: vertical ? GestureSwitcher.toFixedPoint(-velocity) : 0,
            velocityZ: 0
        )
        withUnsafeBytes(of: &velocityEvent) { data.append(contentsOf: $0) }

        return data
    }

    /// Appends payload to serialized CGEvent bytes with Field 4205 tag.
    /// Tag format (big-endian): [size_hi][size_lo][field_hi][field_lo][payload...]
    /// Field 4205 = 0x106D
    private func appendField4205(to bytes: inout Data, payload: Data) {
        let size = UInt16(payload.count)
        bytes.append(UInt8(size >> 8))        // size high byte
        bytes.append(UInt8(size & 0xFF))      // size low byte
        bytes.append(0x10)                    // 4205 >> 8
        bytes.append(0x6D)                    // 4205 & 0xFF
        bytes.append(payload)
    }

    // MARK: - Self-tests

    static func selfChecks(_ check: SelfTest.Check) {
        // The struct layouts ARE the wire format macOS 27 validates — pin them.
        check(MemoryLayout<IOHIDEventBase>.size == 16, "iohid: event base is 16 bytes")
        check(MemoryLayout<IOHIDFluidTouchGestureData>.size == 40, "iohid: gesture data is 40 bytes")
        check(MemoryLayout<IOHIDVelocityEventData>.size == 28, "iohid: velocity data is 28 bytes")
        check(MemoryLayout<IOHIDSystemQueueElementHeader>.size == 28, "iohid: queue header is 28 bytes")

        guard let event = CGEvent(source: nil) else {
            check(false, "iohid: CGEvent construction for payload test")
            return
        }
        // Type the event as a dock-swipe gesture first — a null CGEvent silently drops
        // the gesture double fields the payload builder reads back.
        event.setIntegerValueField(GestureSwitcher.eventTypeField, value: GestureSwitcher.dockControl)
        event.setIntegerValueField(GestureSwitcher.gestureHIDType, value: GestureSwitcher.hidDockSwipe)
        event.setDoubleValueField(GestureSwitcher.swipeProgress, value: 0.5)
        event.setDoubleValueField(GestureSwitcher.swipePositionX, value: 0.1)
        let poster = SystemEventPoster()
        let payload = poster.buildIOHIDPayload(event: event, phase: 2, velocity: 1.5)
        func u32(_ off: Int) -> UInt32 {
            payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
        }
        check(payload.count == 28 + 40 + 28, "iohid: payload = header + gesture + velocity")
        check(u32(24) == 2, "iohid: header eventCount is 2 (gesture + velocity)")
        check(u32(28) == 40 && u32(32) == 23, "iohid: gesture base size 40, type FluidTouchGesture")
        check(u32(36) == UInt32(2) << 24, "iohid: gesture options carry the phase in the high byte")
        check(Int32(bitPattern: u32(64)) == GestureSwitcher.toFixedPoint(-0.5),
              "iohid: progress 16.16 fixed-point with IOHID sign flip")
        check(u32(72) == 9 && payload[80] == 1, "iohid: velocity event type 9, depth 1 (child)")
        check(Int32(bitPattern: u32(84)) == GestureSwitcher.toFixedPoint(-1.5),
              "iohid: velocity 16.16 fixed-point with IOHID sign flip")

        // Vertical (Mission Control axis) payload: motion 2, velocity moves to the Y slot.
        let vpayload = poster.buildIOHIDPayload(event: event, phase: 2, velocity: 1.5,
                                                vertical: true)
        func vu32(_ off: Int) -> UInt32 {
            vpayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
        }
        let vmotion = vpayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 60, as: UInt16.self) }
        check(vmotion == 2, "iohid: vertical payload motion axis 2")
        check(vu32(84) == 0 && Int32(bitPattern: vu32(88)) == GestureSwitcher.toFixedPoint(-1.5),
              "iohid: vertical velocity rides the Y slot with the IOHID sign flip")

        // Field 4205 framing: big-endian [size][0x106D] then the payload verbatim.
        var frame = Data([0xAA])
        poster.appendField4205(to: &frame, payload: payload)
        check(frame.count == 1 + 4 + payload.count, "iohid: 4205 tag adds 4 framing bytes")
        check(frame[1] == UInt8(UInt16(payload.count) >> 8)
                && frame[2] == UInt8(UInt16(payload.count) & 0xFF),
              "iohid: 4205 size is big-endian")
        check(frame[3] == 0x10 && frame[4] == 0x6D, "iohid: field id 0x106D")
        check(frame.suffix(payload.count) == payload, "iohid: payload appended verbatim")
    }
}
