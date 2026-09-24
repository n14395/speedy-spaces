// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreGraphics

// MARK: - Event-tap plumbing shared by every CGEventTap in the app
//
// Every tap here used to run its callback on the MAIN run loop. An ACTIVE tap's
// verdict gates delivery of the tapped events to the whole login session, so any
// main-thread stall (menu tracking, synchronous IPC, heavy layout) stalled clicks
// and keys system-wide; the window server's tap table recorded multi-minute
// service latencies against this process, experienced as "the menubar is frozen
// and my buffered clicks all fire when I switch Spaces". These pieces fix the
// pattern app-wide:
//
//  * TapThread — a dedicated, always-responsive thread whose run loop services
//    every tap source. Callbacks must stay cheap: decide swallow-or-pass from
//    `Locked` snapshots and hand real work to the main thread. Never call AX,
//    CoreDock, or any other blocking IPC inside a callback.
//  * TapReviver — rate-limited re-enable after tapDisabledByTimeout. A blind
//    immediate re-enable defeats the OS watchdog that cuts a wedged tap out of
//    the event path, extending a 1 s hiccup into an indefinite input stall.
//  * TapTeardown — every removal path must invalidate the mach port;
//    tapEnable(false) alone leaks a dead-but-registered tap in the window
//    server's table (dozens had accumulated from repeated Mission Control opens).
//  * Locked — the small mutable snapshots callbacks read (label hit rects, click
//    gates, modifier state) shared between the tap thread and main.

/// Minimal mutex box for state shared between the tap thread and the main thread.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// The dedicated thread whose run loop services every CGEventTap source in the app
/// (started on first use). CFRunLoop's C API is one of the few thread-safe corners
/// of Core Foundation, so sources are added/removed from any thread directly.
enum TapThread {
    static let runLoop: CFRunLoop = {
        var captured: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            captured = CFRunLoopGetCurrent()
            ready.signal()
            // Keep the loop alive across periods with no tap installed.
            RunLoop.current.add(Timer(fire: .distantFuture, interval: 0, repeats: false) { _ in },
                                forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "SpeedySpaces.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return captured!
    }()

    static func add(_ source: CFRunLoopSource?) {
        guard let source else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    static func remove(_ source: CFRunLoopSource?) {
        guard let source else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Handles tapDisabledByTimeout / tapDisabledByUserInput for one tap. Isolated
/// disables re-enable promptly; a storm of them means the pipeline is wedged, so
/// the re-enable is deferred long enough for the OS watchdog's bypass to actually
/// relieve the session instead of being immediately re-blocked.
final class TapReviver {
    private let label: String
    private let stamps = Locked<[Date]>([])
    init(_ label: String) { self.label = label }

    func tapWasDisabled(_ tap: CFMachPort) {
        let now = Date()
        let storm = stamps.withLock { s -> Bool in
            s.append(now)
            s.removeAll { now.timeIntervalSince($0) > 10 }
            return s.count > 3
        }
        guard storm else {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        HotkeyDiag.log("tap[\(label)]: disable storm — deferring re-enable 5 s")
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 5) {
            guard CFMachPortIsValid(tap) else { return }   // torn down in the meantime
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

enum TapTeardown {
    /// Disable, detach from the tap thread, and INVALIDATE the port so the window
    /// server actually forgets the tap.
    static func tearDown(tap: CFMachPort?, source: CFRunLoopSource?) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { TapThread.remove(source) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

enum MainThreadDispatch {
    /// Run `body` on the main run loop, including while a menu-tracking modal loop
    /// is running (GCD main-queue blocks can sit out menu tracking; performed
    /// blocks in the tracking mode do not).
    static func performIncludingTracking(_ body: @escaping () -> Void) {
        let modes = [CFRunLoopMode.commonModes.rawValue,
                     "NSEventTrackingRunLoopMode" as CFString] as CFArray
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes, body)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
