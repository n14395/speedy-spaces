import AppKit
import QuartzCore

/// Draws each space's custom name onto the macOS Mission Control spaces bar while Mission
/// Control is open. One shield-level, click-through overlay window per display. No SIP, no
/// injection, no Accessibility.
///
/// Pipeline: a slow idle poll (`CGWindowListCopyWindowInfo`) detects the spaces bar by
/// LAYER + GEOMETRY and caches the bar/tile window IDs ("discovery"); while the bar is up, a
/// CADisplayLink samples just those windows' bounds each frame (cheap) and feeds per-label
/// spring animators, so labels glide at display refresh rate instead of snapping at the poll
/// rate. When geometry has been still for a while the link pauses and a 10 Hz timer watches
/// for change ("settled"). Tile index → space is left-to-right = ordinal order per display.
///
/// Names show only while the thumbnails are revealed (the expanded bar). Each label is bold
/// text on a transparent background, placed ABOVE its thumbnail; Apple's "Desktop N" number
/// stays below it, uncovered. Labels reveal once the tile geometry stops moving (with a hard
/// max-wait so they can never get stuck hidden) and fade out when the bar collapses or
/// Mission Control closes.
final class MissionControlOverlay: NSObject {
    private let spaces: SpacesManager
    private let store: MetadataStore

    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]

    // MARK: - Cadence

    /// closed: MC not visible — slow poll, each probe is a full discovery scan.
    /// tracking: bar visible, geometry possibly moving — display-link sampling + springs.
    /// settled: bar visible, geometry still — link paused, light 10 Hz watch.
    private enum Phase { case closed, tracking, settled }
    private var phase: Phase = .closed
    private var timer: Timer?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var stableFrames = 0

    // Poll while Mission Control is closed. This is the entry-latency floor for externally
    // triggered opens (F3 / hot corner / swipe) — labels can't start until a probe notices
    // the bar. The closed-state scan costs ~250 µs, so 0.15 s is ~0.2% of a core.
    private let idleInterval: TimeInterval = 0.15
    private let settledInterval: TimeInterval = 0.05   // watch while open but still — tight
                                                       // enough to catch dismissal near its start
    private let burstInterval: TimeInterval = 1.0 / 30 // probe burst after a self-initiated MC open
    private let settleAfterFrames = 45                 // still frames before pausing the link
    private var burstUntil: CFTimeInterval = 0

    // MARK: - Discovery / sampling state

    private var barIDs: [CGWindowID] = []
    private var tileIDs: [CGWindowID] = []
    private var needsRediscovery = false
    private var lastDiscovery: CFTimeInterval = 0
    private var lastSpacesRefresh: CFTimeInterval = 0
    private var lastMismatchSig = ""
    private var lastTileRects: [NSRect] = []
    /// Tile window -> space uuid, committed while tiles are at rest and ridden while they
    /// move, so labels stay with their spaces through reorder drags (see mapLabels).
    private var tileSpace: [CGWindowID: String] = [:]
    private var lastPinSig: [CGDirectDisplayID: String] = [:]
    /// Left button physically down (from the dismiss tap) — a reorder drag may be in
    /// progress, so mapLabels must not commit tile→space pairings. Written on the tap
    /// thread, read on main — lock-guarded.
    private let mouseHeld = Locked(false)

    // MARK: Input-side dismissal detection
    //
    // Window-server state is only an early dismissal signal for Dock-notification
    // dismissals; for user input (Esc, ⌃↑, clicks, the three-finger swipe down) the
    // bar/tile windows stay "onscreen" until well AFTER the exit animation (measured),
    // far too late for the fly-off. So while MC is open a LISTEN-ONLY event tap watches
    // for inputs that begin a dismissal and launches the label exit immediately; the
    // sampling path remains the truth for actually closing (and quietly rebuilds the
    // labels if MC turns out to still be open).
    private var dismissTap: CFMachPort?
    private var dismissTapSource: CFRunLoopSource?
    /// The live tap, mirrored for the tap-thread callback (which must not race the
    /// main-thread install/remove paths on the plain `dismissTap` property).
    private let dismissTapRef = Locked<CFMachPort?>(nil)
    private let dismissReviver = TapReviver("mcoDismiss")
    /// True from installDismissTap to removeDismissTap — the tap-thread callback's
    /// cheap stand-in for `phase != .closed`.
    private let dismissArmed = Locked(false)
    /// Click-dismissal gates for the tap thread: bar bottom + live tile rects (both CG
    /// coords), refreshed by frame() on main.
    private let clickGates = Locked<(barMaxY: CGFloat, tileRects: [CGRect])>((barMaxY: 300, tileRects: []))
    /// Revealed-label hit areas for the tap thread, in GLOBAL AppKit coords, plus the
    /// primary display height used to flip incoming CG click points. Published by
    /// frame() on main; consumed by the tap-thread hit test (label-click swallowing).
    private let labelAreas = Locked<(primaryH: CGFloat, areas: [(uuid: String, did: CGDirectDisplayID, rect: NSRect)])>((primaryH: 0, areas: []))
    // Universal dismissal net: vendor-driven MC buttons (Logitech etc.) synthesize their
    // trigger, which is INVISIBLE to event taps — but every dismissal path makes the Dock
    // tear down its "mc" accessibility group near the exit's start (measured ~150-280 ms
    // after Esc vs ~700 ms for the window signals). Resolve the element once per MC session
    // (off-main: the tree scan costs ~100 ms) then poll its liveness cheaply at 20 Hz.
    private var axWatchTimer: DispatchSourceTimer?
    private var axObserver: AXObserver?
    private var axWatchGen = 0
    private let axQueue = DispatchQueue(label: "mco.axwatch", qos: .userInteractive)
    private var dismissalAt: CFTimeInterval = 0
    private var dismissDownLocation = CGPoint.zero   // tap-thread-confined (down/up pairing)
    // Vertical dock-swipe watcher (the three-finger swipe-down close) — tap-thread-confined.
    private var vswipeActive = false                 // a vertical gesture is being tracked
    private var vswipeLow = 0.0                      // lowest progress seen this gesture
    private var vswipeFired = false                  // fly-off already launched for this gesture
    private var vswipeLastBump: CFTimeInterval = 0   // keepalive throttle
    private var vswipeLogged = 0                     // debug shape-capture budget per session
    private var unchangedDiscoveries = 0
    private var awaitingTiles = false
    private let rediscoveryInterval: TimeInterval = 0.1
    private let safetyRescanInterval: TimeInterval = 1.0
    /// The full-list scan costs ~7 ms while MC is compositing, so a *stable* trigger (e.g. a
    /// permanent tile/space count disagreement) must not keep it running at 10 Hz: after two
    /// scans that changed nothing, rediscovery drops to the 1 s safety cadence until the
    /// window set actually changes again. EXCEPT while a bar shows zero tiles (collapsed,
    /// pre-expansion): the tile windows the labels need don't exist yet and must be picked
    /// up the moment hovering creates them — never back off there, or labels trail the
    /// expand by up to a second.
    private var effectiveRediscoveryInterval: TimeInterval {
        if awaitingTiles { return rediscoveryInterval }
        return unchangedDiscoveries >= 2 ? safetyRescanInterval : rediscoveryInterval
    }

    /// Geometry sampler. Default: the public description path — besides bounds it carries
    /// kCGWindowIsOnscreen, which is the ONLY early Mission-Control-dismissal signal
    /// (measured: tiles go !onscreen ~30 ms into the exit and the bar follows, while
    /// SLSGetWindowBounds keeps answering with stale bounds until well after the exit
    /// animation finishes). MCO_SLS=1 opts into the allocation-free private sampler for
    /// benchmarking; it costs late dismissal detection (the fly-off exit degrades to an
    /// after-the-fact fade).
    private let useSLS = sm_getWindowBoundsAvailable()
        && ProcessInfo.processInfo.environment["MCO_SLS"] != nil

    // MARK: - Screen / spaces caches (invalidated on screen or space-list change)

    private var primaryH: CGFloat = 0
    private var displayUUIDs: [CGDirectDisplayID: [String]] = [:]
    private var screenCacheDirty = true
    private var spacesByDisplay: [CGDirectDisplayID: [Space]] = [:]
    private var cachedSpaces: [Space] = []

    // MARK: - Logging

    // File-based logging (env var OR /tmp/speedyspaces-debug present) so we capture the trace
    // even for LaunchServices-launched instances, whose stderr isn't redirectable.
    private let debugLog = ProcessInfo.processInfo.environment["MCO_DEBUG"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/speedyspaces-debug")
    /// MCO_CHAR=1: log every sampled tile rect while the bar is up, for characterizing how
    /// the window server reports tile bounds during Mission Control's own animations.
    private let charMode = ProcessInfo.processInfo.environment["MCO_CHAR"] != nil

    private lazy var logHandle: FileHandle? = {
        // O_APPEND so an external truncate of the log can't leave a NUL hole.
        let fd = Darwin.open("/tmp/speedyspaces-mco.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }()

    private func logLine(_ s: String) {
        // Monotonic stamp (CACurrentMediaTime, shared clock with any measuring process)
        // gives millisecond-resolution latency analysis; Date() alone has 1 s granularity.
        guard let data = "\(Date()) [MCO @\(String(format: "%.3f", CACurrentMediaTime()))] \(s)\n".data(using: .utf8) else { return }
        logHandle?.write(data)
    }

    private func dbg(_ s: @autoclosure () -> String) {
        guard debugLog else { return }
        logLine(s())
    }

    // Per-frame cost accounting, reported every 120 frames while logging is on.
    private var statN = 0
    private var statSum = 0.0
    private var statMin = Double.infinity
    private var statMax = 0.0
    private var statSampleSum = 0.0
    private var statApplySum = 0.0
    private var statDiscovers = 0
    private var statRefreshes = 0

    /// Offset (points) between the label's bottom and the TILE WINDOW's top edge. The tile
    /// window extends ~13 pt above the visible wallpaper thumbnail, so this is negative to
    /// seat the label ~6 pt above the visible thumbnail — mirroring the gap of Apple's
    /// "Desktop N" caption below it (and still clear of the MacBook notch).
    private let labelGapAboveTile: CGFloat = -8
    /// Blank rename-target width for an unnamed space, as a fraction of the tile width. Kept
    /// well under 1 so the strip stays clear of the delete-"×" in the tile's top-left corner.
    private let placeholderWidthFraction: CGFloat = 0.6

    var enabled: Bool = true {
        didSet { guard enabled != oldValue else { return }; enabled ? start() : stop() }
    }

    /// A revealed label was clicked in Mission Control: open the name/icon editor for that
    /// space uuid (wired to the status controller's editor by AppDelegate). Fired after the
    /// overlay has already dismissed Mission Control, so the editor lands on the desktop.
    var onLabelClick: ((String, NSScreen?) -> Void)?

    init(spaces: SpacesManager, store: MetadataStore) {
        self.spaces = spaces
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(mcWillOpen),
            name: .speedySpacesMissionControlWillOpen, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(mcWillClose),
            name: .speedySpacesMissionControlWillClose, object: nil)
        // Selecting another workspace in MC dismisses it; the space-change notification
        // fires right at the switch commit — a tap-independent early dismissal signal.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        OverlayWindow.onReveal = { [weak self] count, ms in
            self?.dbg("reveal: \(count) labels after \(ms) ms")
        }
    }

    @objc private func spaceChanged() {
        guard phase != .closed else { return }
        // A space switch normally means a switch-and-dismiss — but switching WHILE Mission
        // Control stays open (⌃-arrow / number key) must not launch the fly-off: the labels
        // stay put (parked on their sticky space) and just restyle in place. The bar is still on
        // screen in that case, so treat a switch as a dismissal only once the bar is gone. The
        // AX teardown watch is the primary detector when live; this is the no-Accessibility
        // fallback.
        guard axObserver == nil && axWatchTimer == nil else { return }
        if !NativeBarWindows.tilesOnScreen() { dismissalInitiated("space switch") }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeDismissTap()
        timer?.invalidate()
        link?.invalidate()
    }

    func start() {
        guard enabled, timer == nil, link == nil else { return }
        phase = .closed
        dbg("engine started (policy=\(NSApp.activationPolicy().rawValue), sampler=\(useSLS ? "SLS" : "CGDescription"))")
        scheduleTimer(idleInterval, tolerance: 0.03)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil
        removeDismissTap()
        stopAXWatch()
        phase = .closed
        barIDs = []; tileIDs = []; lastTileRects = []
        labelAreas.withLock { $0.areas = [] }
        for w in overlays.values { w.clearImmediately() }
    }

    /// One-shot probe (no-op while the bar is already being tracked).
    func refresh() { if phase == .closed { probe() } }

    @objc private func screensChanged() {
        screenCacheDirty = true
        if link != nil {
            link?.invalidate(); link = nil
            if phase != .closed { enterTracking() }
        }
    }

    /// The app itself is about to open Mission Control — probe fast instead of waiting out
    /// the idle interval.
    @objc private func mcWillOpen() {
        guard enabled, phase == .closed else { return }
        burstUntil = CACurrentMediaTime() + 1.5
        scheduleTimer(burstInterval, tolerance: 0.005)
        probe()
    }

    /// The app itself is closing Mission Control (e.g. the native hold chord released) — start
    /// the labels' fly-off now so it rides the close animation instead of trailing it. The
    /// window-state/AX teardown that would otherwise trigger this fires only once the close
    /// animation has finished; this beats it to the start.
    @objc private func mcWillClose() {
        guard phase != .closed else { return }
        dismissalInitiated("mc will close")
    }

    // MARK: - Scheduling

    private func scheduleTimer(_ interval: TimeInterval, tolerance: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.timerTick() }
        t.tolerance = tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func timerTick() {
        switch phase {
        case .closed: probe()
        case .settled: frame(now: CACurrentMediaTime(), dt: 0, stepSprings: false)
        case .tracking: break
        }
    }

    private func enterTracking() {
        phase = .tracking
        stableFrames = 0
        timer?.invalidate(); timer = nil
        if let link {
            link.isPaused = false
        } else if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let l = screen.displayLink(target: self, selector: #selector(frameTick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            scheduleTimer(burstInterval, tolerance: 0.005)   // headless fallback: 30 Hz timer
        }
        lastFrame = CACurrentMediaTime()
    }

    private func enterSettled() {
        phase = .settled
        link?.isPaused = true
        scheduleTimer(settledInterval, tolerance: 0.01)
        dbg("settled (link paused)")
    }

    private func close(flyOff: Bool) {
        guard phase != .closed else { return }
        phase = .closed
        // Listeners outside the overlay (the switcher HUD) key off MC visibility too.
        NotificationCenter.default.post(name: .speedySpacesMissionControlClosed, object: nil)
        removeDismissTap()
        stopAXWatch()
        link?.invalidate(); link = nil
        stableFrames = 0
        barIDs = []; tileIDs = []; lastTileRects = []
        clickGates.set((barMaxY: 300, tileRects: []))
        labelAreas.withLock { $0.areas = [] }
        lastMismatchSig = ""
        awaitingTiles = false
        tileSpace = [:]; mouseHeld.set(false)
        // A reorder drag inside this session changed the space order; the commit is
        // reliably readable once MC is gone. Harmless no-op otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.spaces.refresh()
        }
        let now = CACurrentMediaTime()
        for w in overlays.values {
            if flyOff { w.exitUpward() } else { w.update(labels: nil, now: now) }
        }
        scheduleTimer(idleInterval, tolerance: 0.03)
        if statN > 0 {
            dbg("frame µs min=\(Int(statMin)) avg=\(Int(statSum / Double(statN))) max=\(Int(statMax))"
                + " sampleAvg=\(Int(statSampleSum / Double(statN))) applyAvg=\(Int(statApplySum / Double(statN)))"
                + " discovers=\(statDiscovers) refreshes=\(statRefreshes) n=\(statN)")
            statN = 0; statSum = 0; statMin = .infinity; statMax = 0
            statSampleSum = 0; statApplySum = 0; statDiscovers = 0; statRefreshes = 0
        }
        dbg("MC closed")
    }

    // MARK: - Closed-phase probe

    private func probe() {
        let now = CACurrentMediaTime()
        if discover(now: now) {
            NotificationCenter.default.post(name: .speedySpacesMissionControlOpened, object: nil)
            spaces.refresh()
            lastSpacesRefresh = now
            dismissalAt = 0
            dbg("MC open: barWindows=\(barIDs.count) tileWindows=\(tileIDs.count)")
            installDismissTap()
            startAXWatch()
            enterTracking()
            frame(now: now, dt: 0, stepSprings: false)
        } else if burstUntil > 0, now >= burstUntil {
            burstUntil = 0
            scheduleTimer(idleInterval, tolerance: 0.03)
        }
    }

    // MARK: - Input-side dismissal watch

    private func installDismissTap() {
        guard dismissTap == nil else { return }
        // Safe to reset here: the callback can't run until the source joins the tap thread.
        vswipeActive = false; vswipeLow = 0; vswipeFired = false
        vswipeLastBump = 0; vswipeLogged = 0
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)   // extra mouse buttons (MC bindings)
            | (1 << 14)                                    // NX_SYSDEFINED: media/special keys
            | (1 << 29) | (1 << 30)                        // gesture / dock-swipe events: the
                                                           // three-finger close swipe (below)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<MissionControlOverlay>.fromOpaque(info!).takeUnretainedValue()
            // Swallowing (label clicks) only works on the active tap; a listen-only
            // tap ignores the return value and MC also sees the click — best effort.
            return me.classifyDismissEvent(type: type, event: event)
                ? nil : Unmanaged.passUnretained(event)
        }
        // A LISTEN-ONLY tap can be created under Accessibility alone, but then only mouse
        // events are delivered — KEYBOARD delivery to listen-only taps is gated behind
        // Input Monitoring. An ACTIVE tap that passes every event through unmodified is
        // fully served under Accessibility (which the switch engines already hold), so
        // prefer it when trusted; listen-only is the mouse-only best effort otherwise.
        var made: CFMachPort?
        if AXIsProcessTrusted() {
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .defaultTap, eventsOfInterest: mask,
                                     callback: callback, userInfo: info)
        }
        if made == nil {
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask,
                                     callback: callback, userInfo: info)
        }
        guard let tap = made else {
            dbg("dismiss tap unavailable (needs Accessibility) — late window-state detection only")
            return
        }
        if !AXIsProcessTrusted() {
            // A listen-only tap receives NO dock-swipe gesture events on this OS (measured),
            // so the swipe-close watcher is blind until the tap is ACTIVE. Trust can lag at
            // login — re-check shortly and upgrade in place if it arrived.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.phase != .closed, self.dismissTap != nil,
                      AXIsProcessTrusted() else { return }
                self.dbg("AX trust arrived — reinstalling dismiss tap as active")
                self.removeDismissTap()
                self.installDismissTap()
            }
        }
        dbg("dismiss tap installed (AXTrusted=\(AXIsProcessTrusted()), enabled=\(CGEvent.tapIsEnabled(tap: tap)))")
        dismissTap = tap
        dismissTapRef.set(tap)
        dismissArmed.set(true)
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Serviced on the dedicated tap thread — a busy main thread must never gate
        // session-wide click/keyboard delivery through this tap.
        TapThread.add(src)
        dismissTapSource = src
    }

    private func removeDismissTap() {
        dismissArmed.set(false)
        dismissTapRef.set(nil)
        TapTeardown.tearDown(tap: dismissTap, source: dismissTapSource)
        dismissTapSource = nil
        dismissTap = nil
    }

    /// Runs on the TAP THREAD. Returns true when the event should be swallowed (a click
    /// that landed on one of our labels). Decides swallow-or-pass from lock-guarded
    /// snapshots only — never AppKit, AX, or Dock IPC — and posts all real handling to
    /// the main thread, so a busy main thread can delay our *reaction* but never the
    /// session's event delivery.
    private func classifyDismissEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = dismissTapRef.get() { dismissReviver.tapWasDisabled(tap) }
            return false
        }
        guard dismissArmed.get() else { return false }
        switch type {
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // 53 Esc · 160 Mission Control/F3 · 131/130 MC on other keyboards · ⌃↑ toggle.
            if code == 53 || code == 160 || code == 131 || code == 130
                || (code == 126 && event.flags.contains(.maskControl)) {
                DispatchQueue.main.async { [weak self] in self?.dismissalInitiated("key \(code)") }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase != .closed else { return }
                    self.dbg("tap: unmatched keyDown \(code) while MC open")
                }
            }
        case .otherMouseDown:
            // Extra mouse buttons are commonly bound to Mission Control — pressing one while
            // MC is open toggles it closed. A button bound to something else does nothing in
            // MC; worst case the labels blink off and quietly re-reveal.
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            DispatchQueue.main.async { [weak self] in self?.dismissalInitiated("mouse button \(button)") }
        case .leftMouseDown:
            dismissDownLocation = event.location
            mouseHeld.set(true)
        case .leftMouseUp:
            mouseHeld.set(false)
            // A CLICK (not a drag — tile drags reorder without dismissing) dismisses when it
            // lands in the desktop/exposé region below the bar, or on a workspace tile
            // (switch-and-dismiss). Clicks on "+" or empty bar chrome don't dismiss.
            let loc = event.location
            let dx = loc.x - dismissDownLocation.x, dy = loc.y - dismissDownLocation.y
            guard dx * dx + dy * dy < 36 else {
                // A drag released while MC is open is most likely a tile reorder. The Dock
                // commits the new space order on drop without notifying anyone — re-enumerate
                // once the drop settles so ordinals (menubar strip, positional pairing)
                // match the new order. Pinned labels are already correct visually.
                DispatchQueue.main.async { [weak self] in
                    self?.dbg("drag release (\(Int(dx)),\(Int(dy))) — scheduling spaces refresh")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.spaces.refresh()
                }
                break
            }
            // A click on one of our labels edits that space instead of anything MC would
            // do with it (the label's lower half can overlap the tile window's top strip,
            // where MC would switch-and-dismiss) — checked before the dismissal gates.
            if let hit = labelHit(atCG: loc) {
                DispatchQueue.main.async { [weak self] in self?.labelClicked(hit.uuid, did: hit.did) }
                return true
            }
            let gates = clickGates.get()
            if loc.y > gates.barMaxY + 40 {
                DispatchQueue.main.async { [weak self] in self?.dismissalInitiated("desktop click") }
            } else if gates.tileRects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(loc) }) {
                // The delete "×" sits at a tile's top-left corner — clicking it REMOVES
                // that desktop (MC stays open, tiles rearrange) rather than dismissing,
                // so a click near ANY tile's top-left corner must not launch the fly-off.
                // A genuine switch-click landing in that corner still dismisses via the
                // AX teardown a few frames later.
                let nearDeleteButton = gates.tileRects.contains {
                    loc.x > $0.minX - 14 && loc.x < $0.minX + 28
                        && loc.y > $0.minY - 8 && loc.y < $0.minY + 30
                }
                if !nearDeleteButton {
                    DispatchQueue.main.async { [weak self] in self?.dismissalInitiated("tile click") }
                }
            }
        default:
            // Dock-swipe gesture events (raw 30, with 29 tapped as insurance against the
            // gesture family being re-typed) — the three-finger swipe-down close.
            if type.rawValue == 29 || type.rawValue == 30 {
                classifyGestureEvent(event)
            }
            // NX_SYSDEFINED (raw 14): dedicated media/special keys (keyboard MC buttons on
            // many keyboards) arrive here rather than as keyDown. The NSEvent bridging that
            // unpacks data1 happens on main, off the tap thread's critical path.
            else if type.rawValue == 14, let copy = event.copy() {
                DispatchQueue.main.async { [weak self] in self?.handleSysDefined(copy) }
            }
        }
        return false
    }

    // MARK: Trackpad-swipe dismissal (three-finger swipe down)

    /// Fire thresholds: how far progress must RISE above the gesture's low-water mark
    /// (confirmed on real events: positive = swipe down = close; real closes release at
    /// +0.35…+0.77, real opens at −0.17…−0.26). Mid-drag needs a meaningful rise; at
    /// release a smaller rise still counts (a flick releases early and the Dock finishes
    /// the close from velocity), while a reversed, abandoned drag releases back at its
    /// low point.
    static let vswipeFireDelta = 0.10
    static let vswipeReleaseDelta = 0.04

    /// Pure per-event decision for the vertical dock-swipe watcher. Phases are IOHID:
    /// 1 began, 2 changed, 4 ended, 8 cancelled. The rule: track the LOWEST progress
    /// seen this gesture and fire once progress climbs `vswipeFireDelta` above it — a
    /// sustained downward pull. Keying on rise-above-low rather than a began-gated
    /// absolute threshold covers the continuous open-hold-pull-down super-gesture and a
    /// dropped began event (a changed event with no gesture being tracked ADOPTS the
    /// gesture at its current progress), while the opening up-swipe's tail can never
    /// fire: its progress only descends, so it rides the low-water mark itself.
    static func vswipeStep(phase: Int64, progress: Double, active: Bool, low: Double,
                           fired: Bool) -> (active: Bool, low: Double, fired: Bool, fire: Bool) {
        switch phase {
        case 1:   // began: a fresh vertical dock gesture
            return (true, progress, false, false)
        case 2:   // changed: adopt if untracked, then fire on a sustained rise
            let lo = active ? min(low, progress) : progress
            if !fired, progress >= lo + vswipeFireDelta { return (true, lo, true, true) }
            return (true, lo, fired, false)
        case 4:   // ended: a released flick can commit the close below the mid-drag rise
            return (false, 0, false, active && !fired && progress >= low + vswipeReleaseDelta)
        case 8:   // cancelled: the system stole the gesture — MC stays open
            return (false, 0, false, false)
        default:
            return (active, low, fired, false)
        }
    }

    /// Runs on the TAP THREAD. The three-finger swipe DOWN that closes Mission Control is
    /// invisible to every other dismissal signal until the exit has already finished: the
    /// interactive exit tracks the fingers, and the window state / Dock AX teardown stay
    /// quiet until the fingers commit — so the labels used to stay planted on the desktop
    /// while the bar slid up. Real dock-swipe gestures ARE delivered to this tap (type-30
    /// events with the classic gesture fields populated — but ONLY to an ACTIVE tap;
    /// listen-only taps get none of them on this OS), so watch vertical dock swipes and
    /// launch the fly-off the moment one pulls meaningfully downward (see vswipeStep). A
    /// false fire self-heals: forced close → the 0.15 s idle probe re-detects MC → labels
    /// re-reveal.
    private func classifyGestureEvent(_ event: CGEvent) {
        guard event.getIntegerValueField(GestureSwitcher.gestureHIDType) == GestureSwitcher.hidDockSwipe
        else { return }
        let motion = event.getIntegerValueField(GestureSwitcher.swipeMotion)
        var phase = event.getIntegerValueField(GestureSwitcher.gesturePhase)
        if phase == 0 { phase = event.getIntegerValueField(GestureSwitcher.gesturePhase2) }
        let progress = event.getDoubleValueField(GestureSwitcher.swipeProgress)
        if debugLog, vswipeLogged < 80 {
            vswipeLogged += 1
            let line = "tap: dock-swipe motion=\(motion) phase=\(phase)"
                + " progress=\(String(format: "%.3f", progress))"
            DispatchQueue.main.async { [weak self] in self?.dbg(line) }
        }
        guard motion == GestureSwitcher.motionVertical else { return }
        let wasFired = vswipeFired
        let r = Self.vswipeStep(phase: phase, progress: progress,
                                active: vswipeActive, low: vswipeLow, fired: vswipeFired)
        vswipeActive = r.active
        vswipeLow = r.low
        vswipeFired = r.fired
        if r.fire {
            DispatchQueue.main.async { [weak self] in self?.dismissalInitiated("vertical swipe") }
        } else if wasFired, phase == 2 || phase == 4 {
            // The fired gesture is still tracking (or just released) — keep the dismissal
            // riding the live fingers.
            let now = CACurrentMediaTime()
            if phase == 4 || now - vswipeLastBump > 0.1 {
                vswipeLastBump = now
                DispatchQueue.main.async { [weak self] in self?.gestureDismissalContinues() }
            }
        }
    }

    /// Main-thread keepalive for a fired swipe dismissal whose fingers are still down:
    /// each bump slides the update-suppression window along and re-arms the forced close
    /// to land 0.6 s after the LAST gesture event. Without this, a slow tracked exit
    /// outlives both the 1 s suppression and the 0.5 s close-confirm, and the labels
    /// rebuild over a half-dismissed Mission Control mid-gesture.
    private func gestureDismissalContinues() {
        guard phase != .closed else { return }
        let now = CACurrentMediaTime()
        dismissalAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.phase != .closed, self.dismissalAt == now else { return }
            self.dbg("swipe close-confirm timeout — forcing closed")
            self.close(flyOff: true)
        }
    }

    /// Main-thread tail of the sysdefined branch. Subtype 8 = media key; data1 packs
    /// keytype (high 16 bits) and press state (0x0A = down).
    private func handleSysDefined(_ event: CGEvent) {
        guard phase != .closed, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return }
        let keyType = (ns.data1 & 0xFFFF0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        guard isDown else { return }
        if keyType == 13 {   // NX_KEYTYPE_LAUNCH_PANEL family (MC/exposé keys)
            dismissalInitiated("media key \(keyType)")
        } else {
            dbg("tap: unmatched media key \(keyType) while MC open")
        }
    }

    /// Space uuid of the revealed label under a CG-coordinate click location, plus the
    /// display whose overlay was hit (the editor opens on that display), if any. Pure
    /// lookup over the snapshot published by frame() — safe from the tap thread.
    private func labelHit(atCG loc: CGPoint) -> (uuid: String, did: CGDirectDisplayID)? {
        let snap = labelAreas.get()
        guard snap.primaryH > 0 else { return nil }
        let global = NSPoint(x: loc.x, y: snap.primaryH - loc.y)
        return snap.areas.first { $0.rect.contains(global) }.map { ($0.uuid, $0.did) }
    }

    private func labelClicked(_ uuid: String, did: CGDirectDisplayID) {
        dbg("label click on \(uuid) — dismissing MC to open the editor")
        // Fly the labels off with the exit we're about to cause, then close MC ourselves
        // (the swallowed click never reaches it). Editor presentation waits out the exit
        // animation so the window doesn't appear under the Mission Control shield.
        dismissalInitiated("label click")
        _ = sm_coreDockSendNotification("com.apple.expose.awake" as CFString)
        let callback = onLabelClick
        let screen = NSScreen.screens.first { $0.displayID == did }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { callback?(uuid, screen) }
    }

    /// Fly the labels off right away; sampling stays live and either confirms the close
    /// (which finds nothing left to animate) or, if MC didn't actually dismiss, rebuilds
    /// the labels after the suppression window and fades them back in.
    private func dismissalInitiated(_ how: String) {
        guard phase != .closed else { return }
        let now = CACurrentMediaTime()
        guard now - dismissalAt > 1.0 else { return }
        dismissalAt = now
        dbg("dismissal initiated (\(how)) — labels fly off")
        for w in overlays.values { w.exitUpward() }
        // Don't wait out the window-state confirmation (measured 0.7–1 s, occasionally
        // longer — long enough for the 1 s update-suppression to lapse and REBUILD the
        // labels over an empty desktop, which then die by the old in-place fade). The
        // trigger already said MC is closing: force the close shortly after. If it was a
        // false trigger, the 0.15 s idle probe re-detects MC open and labels re-reveal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.phase != .closed, self.dismissalAt == now else { return }
            self.dbg("dismissal close-confirm timeout — forcing closed")
            self.close(flyOff: true)   // labels already flew; nothing left to animate
        }
    }

    // MARK: - Dock AX teardown watch (catches dismissals no event tap can see)

    private func startAXWatch() {
        guard AXIsProcessTrusted() else { return }
        axWatchGen += 1
        let gen = axWatchGen
        axQueue.async { [weak self] in
            guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
            var mc: AXUIElement?
            for _ in 0..<15 {   // the AX tree can lag MC's appearance slightly
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(dockAX, kAXChildrenAttribute as CFString, &v) == .success,
                   let kids = v as? [AXUIElement] {
                    mc = kids.first { el in
                        var idv: CFTypeRef?
                        return AXUIElementCopyAttributeValue(el, "AXIdentifier" as CFString, &idv) == .success
                            && (idv as? String) == "mc"
                    }
                }
                if mc != nil { break }
                usleep(100_000)
            }
            guard let mc else { return }
            // Never let a poll block on a busy/tearing-down Dock — that's exactly the
            // moment we need a fast answer (default AX messaging timeout is seconds).
            AXUIElementSetMessagingTimeout(mc, 0.03)
            let dockPID = dock.processIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.axWatchGen, self.phase != .closed else { return }

                // Push path: the Dock announces the element's destruction — zero poll latency.
                var obs: AXObserver?
                if AXObserverCreate(dockPID, { _, _, _, refcon in
                    guard let refcon else { return }
                    Unmanaged<MissionControlOverlay>.fromOpaque(refcon)
                        .takeUnretainedValue().axTeardownFired()
                }, &obs) == .success, let obs {
                    AXObserverAddNotification(obs, mc, kAXUIElementDestroyedNotification as CFString,
                                              Unmanaged.passUnretained(self).toOpaque())
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
                    self.axObserver = obs
                }

                // Poll fallback: liveness at 33 Hz. "Invalid element" fires immediately;
                // "Dock not responding" (mid-teardown it stops servicing AX) fires on the
                // second consecutive miss so a transient stall while open can't false-fire.
                var consecutiveFailures = 0
                let t = DispatchSource.makeTimerSource(queue: self.axQueue)
                t.schedule(deadline: .now() + 0.03, repeating: 0.03, leeway: .milliseconds(5))
                t.setEventHandler { [weak self] in
                    var v: CFTypeRef?
                    let err = AXUIElementCopyAttributeValue(mc, kAXRoleAttribute as CFString, &v)
                    if err == .success { consecutiveFailures = 0; return }
                    consecutiveFailures += 1
                    guard err == .invalidUIElement || consecutiveFailures >= 2 else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, gen == self.axWatchGen else { return }
                        self.axTeardownFired()
                    }
                }
                t.resume()
                self.axWatchTimer?.cancel()
                self.axWatchTimer = t
            }
        }
    }

    private func axTeardownFired() {
        guard phase != .closed else { return }
        // The Dock recreates its "mc" AX element when the bar re-renders for an in-place
        // space switch, destroying the element we were observing WITHOUT Mission Control
        // closing. The tiles STAY put through that re-render but vanish first on a genuine
        // dismissal (~30 ms before the bar), so they're the discriminator: tiles still on
        // screen ⇒ re-render ⇒ re-attach and leave the labels standing; tiles gone ⇒ real
        // teardown ⇒ fly off now (no waiting for the bar, which lingers).
        stopAXWatch()
        if NativeBarWindows.tilesOnScreen() {
            dbg("AX element destroyed but tiles still on screen — re-arming (in-place switch)")
            startAXWatch()
            return
        }
        dismissalInitiated("mc AX teardown")
    }

    private func stopAXWatch() {
        axWatchGen += 1          // invalidates any in-flight resolution
        axWatchTimer?.cancel()
        axWatchTimer = nil
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            axObserver = nil
        }
    }

    // MARK: - Discovery (full window-list scan; rare)

    /// Snapshot the on-screen window list and cache the IDs of bar (layer 14) and tile
    /// (layer 15) candidate windows. Detection is by LAYER + GEOMETRY: window/owner NAMES
    /// require Screen Recording permission, which a LaunchServices-launched menu-bar agent
    /// does NOT have — so we must not depend on them. Owner name, when present (i.e.
    /// permission granted), is used only to reject non-WindowManager windows.
    /// Candidates are cached regardless of current size; the per-frame sampler applies the
    /// size bands to live bounds, so tiles mid-morph are found the moment they reach shape.
    /// Returns whether a band-matching bar exists right now (the "Mission Control open" test).
    @discardableResult
    private func discover(now: CFTimeInterval) -> Bool {
        lastDiscovery = now
        needsRediscovery = false
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            barIDs = []; tileIDs = []
            return false
        }
        var bars: [CGWindowID] = []
        var tiles: [CGWindowID] = []
        var sawBar = false
        for w in infos {
            guard let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wid != 0,
                  let d = w[kCGWindowBounds as String] as? [String: Any],
                  let cg = CGRect(dictionaryRepresentation: d as CFDictionary) else { continue }
            if let owner = w[kCGWindowOwnerName as String] as? String,
               !owner.isEmpty, !owner.localizedCaseInsensitiveContains("WindowManager") { continue }
            switch (w[kCGWindowLayer as String] as? Int) ?? 0 {
            case 14:
                bars.append(wid)
                if Self.barBand(cg.size) { sawBar = true }
            case 15:
                tiles.append(wid)
            default:
                break
            }
        }
        if bars == barIDs && tiles == tileIDs {
            unchangedDiscoveries += 1
        } else {
            unchangedDiscoveries = 0
        }
        barIDs = bars
        tileIDs = tiles
        return sawBar
    }

    private static func barBand(_ s: CGSize) -> Bool { s.width > 600 && s.height > 80 && s.height < 280 }
    private static func tileBand(_ s: CGSize) -> Bool { s.width > 100 && s.width < 320 && s.height > 90 && s.height < 200 }

    static func selfChecks(_ check: SelfTest.Check) {
        // Band predicates — the geometry that identifies MC's bar and tile windows.
        check(barBand(CGSize(width: 1200, height: 150)), "MCO barBand: typical bar accepted")
        check(!barBand(CGSize(width: 500, height: 150)), "MCO barBand: too-narrow rejected")
        check(!barBand(CGSize(width: 1200, height: 60)), "MCO barBand: too-short rejected")
        check(!barBand(CGSize(width: 1200, height: 300)), "MCO barBand: too-tall rejected")
        check(tileBand(CGSize(width: 200, height: 140)), "MCO tileBand: typical tile accepted")
        check(!tileBand(CGSize(width: 90, height: 140)), "MCO tileBand: too-narrow rejected")
        check(!tileBand(CGSize(width: 340, height: 140)), "MCO tileBand: too-wide rejected")
        check(!tileBand(CGSize(width: 200, height: 80)), "MCO tileBand: too-short rejected")
        // Critically damped label spring: settles, never overshoots from rest, dt=0 identity.
        var pos: CGFloat = 100, vel: CGFloat = 0
        var overshot = false
        for _ in 0..<180 {
            (pos, vel) = OverlayWindow.springStep(pos: pos, vel: vel, target: 0, tau: 0.08, dt: 1.0 / 60.0)
            if pos < -0.001 { overshot = true }
        }
        check(abs(pos) < 0.05 && abs(vel) < 0.5, "spring: settles at target within 3 s")
        check(!overshot, "spring: critically damped — no overshoot from rest")
        check(pos.isFinite && vel.isFinite, "spring: no NaN/Inf")
        let idle = OverlayWindow.springStep(pos: 42, vel: -3, target: 0, tau: 0.08, dt: 0)
        check(idle.pos == 42 && idle.vel == -3, "spring: dt=0 is identity")
        // Vertical dock-swipe (three-finger close) watcher decisions.
        var v = vswipeStep(phase: 1, progress: 0.004, active: false, low: 9, fired: false)
        check(v.active && !v.fired && !v.fire && v.low == 0.004, "vswipe: began arms and seeds the low-water mark")
        v = vswipeStep(phase: 2, progress: 0.05, active: true, low: 0, fired: false)
        check(v.active && !v.fire, "vswipe: small rise doesn't fire")
        v = vswipeStep(phase: 2, progress: 0.12, active: true, low: 0, fired: false)
        check(v.fire && v.fired, "vswipe: sustained downward pull fires")
        v = vswipeStep(phase: 2, progress: 0.9, active: true, low: 0, fired: true)
        check(!v.fire && v.fired, "vswipe: fires only once per gesture")
        v = vswipeStep(phase: 2, progress: -0.5, active: false, low: 0, fired: false)
        check(v.active && !v.fire && v.low == -0.5, "vswipe: began-less changed event adopts the gesture")
        v = vswipeStep(phase: 2, progress: -0.38, active: true, low: -0.5, fired: false)
        check(v.fire, "vswipe: continuous open-hold-pull-down fires on the rise from its low")
        v = vswipeStep(phase: 2, progress: -0.6, active: true, low: -0.5, fired: false)
        check(!v.fire && v.low == -0.6, "vswipe: opening swipe descends with its low — never fires")
        v = vswipeStep(phase: 2, progress: -0.44, active: true, low: -0.5, fired: false)
        check(!v.fire, "vswipe: small overshoot rebound stays below the fire delta")
        v = vswipeStep(phase: 4, progress: 0.06, active: true, low: 0, fired: false)
        check(v.fire, "vswipe: released flick with a small rise fires")
        v = vswipeStep(phase: 4, progress: 0.01, active: true, low: 0, fired: false)
        check(!v.fire && !v.active, "vswipe: abandoned drag releasing at its low doesn't fire")
        v = vswipeStep(phase: 4, progress: 0.9, active: true, low: 0, fired: true)
        check(!v.fire && !v.active && !v.fired, "vswipe: end resets state")
        v = vswipeStep(phase: 4, progress: -0.26, active: false, low: 0, fired: false)
        check(!v.fire, "vswipe: stray ended event with no tracked gesture doesn't fire")
        v = vswipeStep(phase: 8, progress: 0.9, active: true, low: 0, fired: false)
        check(!v.fire && !v.active, "vswipe: cancelled gesture never fires")
    }

    // MARK: - Sampling (bounds of the cached windows only; every frame)

    /// `barsOnScreen` counts bar windows still alive and on-screen REGARDLESS of size band —
    /// zero means Mission Control itself is going (fly-off); non-zero with `bars` empty means
    /// the bar merely collapsed/left its band (fade). Judged from live sampling, never from
    /// the discovery ID cache, which can lag the screen by a scan.
    private func sample() -> (bars: [NSRect], tiles: [(wid: CGWindowID, rect: NSRect)],
                              missing: Bool, barsOnScreen: Int) {
        var bars: [NSRect] = []
        var tiles: [(wid: CGWindowID, rect: NSRect)] = []
        var missing = false
        var barsOnScreen = 0
        if useSLS {
            for wid in barIDs {
                var r = CGRect.zero
                if sm_getWindowBounds(wid, &r) {
                    barsOnScreen += 1
                    if Self.barBand(r.size) { bars.append(toNS(r)) }
                } else { missing = true }
            }
            for wid in tileIDs {
                var r = CGRect.zero
                if sm_getWindowBounds(wid, &r) {
                    if Self.tileBand(r.size) { tiles.append((wid, toNS(r))) }
                } else { missing = true }
            }
        } else {
            let map = Self.describeWindows(barIDs + tileIDs)
            for wid in barIDs {
                if let (r, on) = map[wid] {
                    if on {
                        barsOnScreen += 1
                        if Self.barBand(r.size) { bars.append(toNS(r)) }
                    }
                } else { missing = true }
            }
            for wid in tileIDs {
                if let (r, on) = map[wid] {
                    if on, Self.tileBand(r.size) { tiles.append((wid, toNS(r))) }
                } else { missing = true }
            }
        }
        // Deterministic order: discovery returns z-order, which can shuffle between scans;
        // the stability comparison and tile→ordinal mapping both need positional order.
        tiles.sort { $0.rect.minX < $1.rect.minX }
        return (bars, tiles, missing, barsOnScreen)
    }

    /// Bounds + onscreen flag for a specific set of windows — one small window-server query,
    /// no full-list snapshot. Windows that no longer exist are simply absent from the result.
    private static func describeWindows(_ wids: [CGWindowID]) -> [CGWindowID: (CGRect, Bool)] {
        var out: [CGWindowID: (CGRect, Bool)] = [:]
        guard !wids.isEmpty else { return out }
        // CGWindowListCreateDescriptionFromArray wants the IDs themselves as pointer-sized
        // array values (not CFNumbers).
        var ptrs: [UnsafeRawPointer?] = wids.compactMap { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let arr = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil),
              let descs = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return out }
        for d in descs {
            guard let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bd = d[kCGWindowBounds as String] as? [String: Any],
                  let cg = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            out[wid] = (cg, (d[kCGWindowIsOnscreen as String] as? Bool) ?? true)
        }
        return out
    }

    private func toNS(_ cg: CGRect) -> NSRect {
        NSRect(x: cg.minX, y: primaryH - cg.minY - cg.height, width: cg.width, height: cg.height)
    }

    // MARK: - Per-frame drive

    @objc private func frameTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 0), 1.0 / 30)   // clamp: no teleport after a stall
        lastFrame = now
        frame(now: now, dt: dt, stepSprings: true)
    }

    private func frame(now: CFTimeInterval, dt: CFTimeInterval, stepSprings: Bool) {
        guard phase != .closed else { return }
        let t0 = CACurrentMediaTime()

        if needsRediscovery || now - lastDiscovery >= safetyRescanInterval {
            if now - lastDiscovery >= effectiveRediscoveryInterval { discover(now: now); statDiscovers += 1 }
        }
        var s = sample()
        // Dismissal shows up as windows dying, leaving the on-screen list, or — earliest of
        // all — every tile going !onscreen at once (~30 ms before the bar follows). Confirm
        // any of those with a fresh discovery scan before concluding anything.
        if s.missing || s.bars.isEmpty || (s.tiles.isEmpty && !lastTileRects.isEmpty) {
            discover(now: now)
            statDiscovers += 1
            s = sample()
        }
        let t1 = CACurrentMediaTime()
        guard !s.bars.isEmpty else {
            // No bar windows on screen at all => Mission Control itself is dismissing and
            // the tiles are flying up — ride with them. A bar window that's still on screen
            // but collapsed/out of band is not a dismissal — plain fade.
            close(flyOff: s.barsOnScreen == 0)
            return
        }
        // Bar bottom + tile rects in CG coords (undo the NS flip) for the tap thread's
        // click-dismissal gates.
        let tileRectsCG = s.tiles.map {
            CGRect(x: $0.rect.minX, y: primaryH - $0.rect.maxY,
                   width: $0.rect.width, height: $0.rect.height)
        }
        clickGates.withLock { g in
            if let low = s.bars.map({ primaryH - $0.minY }).max() { g.barMaxY = low }
            g.tileRects = tileRectsCG
        }

        // Stillness first: the label mapper only commits tile→space pairings while the
        // tiles are at rest (mid-motion x-order is meaningless during a reorder drag).
        let tilesStill = s.tiles.count == lastTileRects.count
            && zip(s.tiles, lastTileRects).allSatisfy {
                abs($0.rect.minX - $1.minX) < 0.5 && abs($0.rect.minY - $1.minY) < 0.5
                    && abs($0.rect.width - $1.width) < 0.5 && abs($0.rect.height - $1.height) < 0.5
            }
        lastTileRects = s.tiles.map(\.rect)

        let byScreen = mapLabels(bars: s.bars, tiles: s.tiles, now: now, tilesAtRest: tilesStill)

        var anyMoving = false
        // After an input-side dismissal the labels have already flown; don't rebuild them
        // while the (slow) window-state close confirmation is pending. If MC turns out to
        // still be open once the window lapses, updates resume and labels re-reveal.
        let suppressed = now - dismissalAt < 1.0
        if !suppressed {
            var active = Set<CGDirectDisplayID>()
            for (screen, labels) in byScreen {
                guard let did = screen.displayID else { continue }
                active.insert(did)
                let w = overlay(for: screen, did: did)
                if !w.isVisible {
                    w.orderFrontRegardless()
                    // Park on a private sticky space so the labels hold still through a
                    // managed-space slide (see MCLabelStickySpace) instead of riding it.
                    MCLabelStickySpace.park(w)
                }
                let o = screen.frame.origin
                w.update(labels: labels.map {
                    BarLabel(id: $0.id, center: NSPoint(x: $0.center.x - o.x, y: $0.center.y - o.y),
                             name: $0.name, icon: $0.icon, contentKey: $0.contentKey,
                             placeholderWidth: $0.placeholderWidth)
                }, now: now)
                if stepSprings {
                    if w.step(dt: dt) { anyMoving = true }
                } else if w.needsMotion {
                    anyMoving = true
                }
            }
            for (did, w) in overlays where !active.contains(did) { w.update(labels: nil, now: now) }
        }

        // Publish the tap thread's label hit-test snapshot (global AppKit coords, click
        // slop already applied by labelHitAreas).
        var hitAreas: [(uuid: String, did: CGDirectDisplayID, rect: NSRect)] = []
        for (did, w) in overlays where w.isVisible {
            for area in w.labelHitAreas() {
                hitAreas.append((area.uuid, did,
                                 area.rect.offsetBy(dx: w.frame.minX, dy: w.frame.minY)))
            }
        }
        labelAreas.set((primaryH: primaryH, areas: hitAreas))

        // Phase transitions: pause the link once tiles and springs have been still for a
        // while; wake it the moment anything stirs.
        // Tiles in motion mid-session = a layout change (add/remove rearrange) is in
        // progress, so the WINDOW SET is likely changing too (a tile born or destroyed)
        // — rediscover promptly instead of waiting out the 1 s safety rescan, or the
        // new tile and the spaces re-enumeration trail the rearrange by up to a second.
        if !tilesStill, now - lastDiscovery >= 0.2 {
            unchangedDiscoveries = 0
            needsRediscovery = true
        }
        if phase == .tracking {
            stableFrames = tilesStill && !anyMoving ? stableFrames + 1 : 0
            if stableFrames >= settleAfterFrames { enterSettled() }
        } else if phase == .settled, !tilesStill || anyMoving {
            enterTracking()
        }

        if debugLog || charMode {
            let t2 = CACurrentMediaTime()
            let us = (t2 - t0) * 1_000_000
            statN += 1; statSum += us; statMin = min(statMin, us); statMax = max(statMax, us)
            statSampleSum += (t1 - t0) * 1_000_000
            statApplySum += (t2 - t1) * 1_000_000
            if statN >= 120 {
                logLine("frame µs min=\(Int(statMin)) avg=\(Int(statSum / Double(statN))) max=\(Int(statMax))"
                    + " sampleAvg=\(Int(statSampleSum / Double(statN))) applyAvg=\(Int(statApplySum / Double(statN)))"
                    + " discovers=\(statDiscovers) refreshes=\(statRefreshes) phase=\(phase)")
                statN = 0; statSum = 0; statMin = .infinity; statMax = 0
                statSampleSum = 0; statApplySum = 0; statDiscovers = 0; statRefreshes = 0
            }
            if charMode {
                logLine("char t=\(now) tiles=\(s.tiles.map { (Int($0.rect.minX), Int($0.rect.width)) })")
            }
        }
    }

    // MARK: - Tile → space mapping

    private func mapLabels(bars: [NSRect], tiles: [(wid: CGWindowID, rect: NSRect)],
                           now: CFTimeInterval, tilesAtRest: Bool) -> [(NSScreen, [BarLabel])] {
        rebuildScreenCacheIfNeeded()
        rebuildSpacesCacheIfNeeded()
        var out: [(NSScreen, [BarLabel])] = []
        var mismatchSig = ""
        var mismatchWithTiles = false
        var zeroTileBar = false
        // Labels are PINNED to tile windows: a pairing is committed only while the tiles
        // are at rest (x-order is the true space order then), and while tiles move — a
        // reorder drag — each label rides its tile window. Re-pairing by x-position every
        // frame instead would swap labels the moment a dragged tile crosses a neighbor.
        // Assignments are never pruned mid-session: a grabbed tile leaves the size band
        // AND the discovery layer for the whole drag, and must get its assignment back
        // on the drop. The dictionary resets when Mission Control closes; dead-wid
        // entries in between are inert (lookups go through the sampled wids only).
        // ≈ half the rendered label height at the current size (line height ≈ 1.2 × point
        // size), so the label's bottom stays seated at the gap and the larger icon-only
        // rendering only grows upward (still clear of the MacBook notch).
        let labelH2: CGFloat = mcLabelPointSize * 0.6
        for screen in NSScreen.screens {
            guard let did = screen.displayID else { continue }
            let sf = screen.frame
            guard bars.contains(where: { sf.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { continue }
            let scr = spacesByDisplay[did] ?? []
            guard !scr.isEmpty else { out.append((screen, [])); continue }
            let t = tiles.filter { sf.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                .sorted { $0.rect.minX < $1.rect.minX }
            if t.count != scr.count {
                mismatchSig += "\(did):\(t.count)/\(scr.count) "
                if t.isEmpty { zeroTileBar = true } else { mismatchWithTiles = true }
            }
            // The spaces aligned with t: the stored pinning when it exactly covers this
            // screen's tiles (one distinct known space per tile), else positional pairing.
            // A valid pinning survives the model reordering underneath it (the post-drop
            // spaces re-enumeration): membership is checked, order deliberately isn't.
            let byUuid = Dictionary(uniqueKeysWithValues: scr.map { ($0.uuid, $0) })
            let pinned = t.compactMap { tileSpace[$0.wid].flatMap { byUuid[$0] } }
            // Ride the pinning whenever every SAMPLED tile has a distinct known space —
            // deliberately not requiring t.count == scr.count: mid-drag the grabbed tile
            // is out of the size band (its label vanishes with it), and the remaining
            // tiles must keep riding rather than fall back to positional pairing.
            let pinnedOK = pinned.count == t.count
                && Set(pinned.map(\.uuid)).count == pinned.count
            let aligned: [Space]
            if pinnedOK {
                aligned = pinned
            } else {
                aligned = Array(scr.prefix(t.count))
                // Commit a fresh pairing only in a trustworthy moment: full tile set, at
                // rest, and NO button held — mid-drag the visual order has already
                // diverged from the (stale until drop-commit) model order, and a pairing
                // stored then would carry wrong labels for the rest of the session.
                if tilesAtRest, t.count == scr.count, !mouseHeld.get() {
                    for (i, tile) in t.enumerated() { tileSpace[tile.wid] = scr[i].uuid }
                }
            }
            if debugLog {
                let sig = "\(pinnedOK) \(t.map(\.wid)) \(scr.map { $0.uuid.prefix(4) })"
                if sig != lastPinSig[did] {
                    lastPinSig[did] = sig
                    logLine("pin \(pinnedOK ? "RIDE" : "derive") did=\(did) rest=\(tilesAtRest) "
                        + "tiles=\(t.map(\.wid)) spaces=\(scr.map { String($0.uuid.prefix(4)) }) "
                        + "stored=\(t.map { tileSpace[$0.wid].map { String($0.prefix(4)) } ?? "-" })")
                }
            }
            var labels: [BarLabel] = []
            for (i, tile) in t.enumerated() where i < aligned.count {
                let center = NSPoint(x: tile.rect.midX, y: tile.rect.maxY + labelGapAboveTile + labelH2)
                if let content = labelContent(aligned[i]) {
                    labels.append(BarLabel(
                        id: aligned[i].uuid, center: center,
                        name: content.name, icon: content.icon, contentKey: content.key))
                } else if Prefs.thumbnailNamesVisible {
                    // Unnamed space, names enabled: a blank caption occupying the click target
                    // so the user can click where a name would be to open the rename editor.
                    let w = tile.rect.width * placeholderWidthFraction
                    labels.append(BarLabel(
                        id: aligned[i].uuid, center: center,
                        name: nil, icon: nil, contentKey: "placeholder|\(Int(w / 16))",
                        placeholderWidth: w))
                }
                if let over = iconOverlayContent(aligned[i]) {
                    // "Large icons over the thumbnail": a second label per space, centered
                    // ON the tile, riding the same springs. Suffixed id keeps it distinct
                    // from the name row's and out of the rename hit-test.
                    labels.append(BarLabel(
                        id: aligned[i].uuid + mcIconLabelSuffix,
                        center: NSPoint(x: tile.rect.midX, y: tile.rect.midY),
                        name: nil, icon: over.icon, contentKey: over.key))
                }
            }
            out.append((screen, labels))
        }
        // Tile count disagreeing with the space list either means the bar is collapsed
        // (0 tiles — keep re-scanning so the expand is caught fast, but the space list is
        // fine) or a space was just added/removed while Mission Control is open — then
        // re-enumerate, but only ONCE per distinct disagreement: a persistent mismatch must
        // not spam refresh() (it rebuilds the menubar strip).
        if !mismatchSig.isEmpty {
            needsRediscovery = true
            if mismatchWithTiles, mismatchSig != lastMismatchSig, now - lastSpacesRefresh >= 0.3 {
                lastSpacesRefresh = now
                statRefreshes += 1
                dbg("tile/space mismatch \(mismatchSig)— re-enumerating spaces")
                spaces.refresh()
            }
        }
        lastMismatchSig = mismatchSig
        awaitingTiles = zeroTileBar
        return out
    }

    /// What the space's ABOVE-the-thumbnail label shows under the current prefs: custom name
    /// and/or custom icon. nil when there's nothing to show (no metadata, or toggled off). The
    /// key folds in size/weight so a settings change mid-session re-renders live labels. The
    /// `.largeOver` style's icon is a separate centered label (`iconOverlayContent`), not here.
    private func labelContent(_ space: Space) -> (name: String?, icon: NSImage?, key: String)? {
        let meta = store.metadata(for: space.uuid)
        var name: String?
        if Prefs.thumbnailNamesVisible, let n = meta.name, !n.isEmpty { name = n }
        var icon: NSImage?
        var iconKey = ""
        let style = Prefs.thumbnailIconStyle
        if style == .beforeName || style == .largeAbove,
           let image = IconRendering.image(for: meta, pointSize: mcIconPointSize) {
            icon = image
            iconKey = "\(meta.iconType.rawValue):\(meta.iconValue ?? "")"
        }
        guard name != nil || icon != nil else { return nil }
        let key = "\(name ?? "")|\(iconKey)|\(mcLabelPointSize)|\(mcIconPointSize)|\(Prefs.missionControlLabelsBold)"
        return (name, icon, key)
    }

    /// The `.largeOver` style's icon, centered on the thumbnail as its own label.
    private func iconOverlayContent(_ space: Space) -> (icon: NSImage, key: String)? {
        guard Prefs.thumbnailIconStyle == .largeOver else { return nil }
        let meta = store.metadata(for: space.uuid)
        guard let image = IconRendering.image(for: meta, pointSize: mcIconPointSize) else { return nil }
        return (image, "over|\(meta.iconType.rawValue):\(meta.iconValue ?? "")|\(mcIconPointSize)")
    }

    private func overlay(for screen: NSScreen, did: CGDirectDisplayID) -> OverlayWindow {
        if let w = overlays[did] {
            if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
            return w
        }
        let w = OverlayWindow(contentRect: screen.frame)
        overlays[did] = w
        return w
    }

    // MARK: - Caches

    private func rebuildScreenCacheIfNeeded() {
        guard screenCacheDirty else { return }
        screenCacheDirty = false
        primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        displayUUIDs = [:]
        for screen in NSScreen.screens {
            guard let did = screen.displayID else { continue }
            var ids: [String] = []
            if let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(),
               let s = CFUUIDCreateString(nil, u) as String? { ids.append(s) }
            if did == CGMainDisplayID() { ids.append("Main") }
            displayUUIDs[did] = ids
        }
    }

    private func rebuildSpacesCacheIfNeeded() {
        guard spaces.spaces != cachedSpaces else { return }
        cachedSpaces = spaces.spaces
        spacesByDisplay = [:]
        for screen in NSScreen.screens {
            guard let did = screen.displayID, let ids = displayUUIDs[did] else { continue }
            spacesByDisplay[did] = cachedSpaces
                .filter { ids.contains($0.displayIdentifier) }
                .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Parks the label overlay windows in a private always-shown WindowServer space so they hold
/// STILL during the managed-space slide, instead of riding out with the leaving space and back
/// in with the arriving one (the system-bezel technique — same recipe as `SwitcherStickySpace`,
/// but at the SHIELD level so the labels stay ABOVE the live Mission Control bar; the switcher
/// uses level 0 because it only shows when MC is closed). A window whose only space is unmanaged
/// doesn't participate in the managed-space viewport animation. Best-effort: if the private
/// symbols are gone or the space can't be made, the caller falls back to hiding for the slide.
private enum MCLabelStickySpace {
    private static var spaceID: UInt64 = 0
    private static var failed = false

    /// Move `window` onto the sticky space exclusively. Idempotent; call after each orderFront
    /// (an orderOut/orderFront cycle re-attaches the window to the active managed space). If the
    /// private symbols are gone the labels just ride the slide as before — no worse than not
    /// parking.
    static func park(_ window: NSWindow) {
        guard !failed, window.windowNumber > 0 else { return }
        if spaceID == 0 {
            guard sm_stickySpaceSymbolsAvailable() else {
                failed = true; HotkeyDiag.log("MC label sticky: symbols missing"); return
            }
            spaceID = sm_stickySpaceCreate(CGShieldingWindowLevel())
            guard spaceID != 0 else {
                failed = true; HotkeyDiag.log("MC label sticky: create failed"); return
            }
            HotkeyDiag.log("MC label sticky space \(spaceID) @level \(CGShieldingWindowLevel())")
        }
        if !sm_stickySpaceAttachWindow(UInt32(window.windowNumber), spaceID) {
            failed = true; HotkeyDiag.log("MC label sticky: attach symbol missing")
        }
    }
}

/// Label point size. 14 with names on — Apple's "Desktop N" caption but a touch larger.
/// Icon-only mode renders at 24: with no text the icon is the whole label, and 24 is the
/// largest size whose label top still clears the MacBook notch (labels grow upward from a
/// fixed bottom just above the thumbnail).
fileprivate var mcLabelPointSize: CGFloat { Prefs.thumbnailNamesVisible ? 14 : 24 }

/// Icon point size follows the chosen style: small (14) inline beside a name, large (24)
/// when the icon stands alone above or sits centered on the thumbnail.
fileprivate var mcIconPointSize: CGFloat { Prefs.thumbnailIconStyle == .beforeName ? 14 : 24 }

/// Id suffix for the `.largeOver` style's centered icon labels: keeps them distinct from the
/// name label of the same space and excludes them from the rename click hit-test (a click on
/// the tile should switch to the space, as Mission Control's own tiles do).
fileprivate let mcIconLabelSuffix = "#icon"

/// One label to place over the bar: `id` is the space uuid (stable diff key), `center` is the
/// label's center point. Content is the optional `name` and/or leading `icon`; `contentKey`
/// is the cheap equality key for the rendered content (re-render only when it changes).
fileprivate struct BarLabel {
    let id: String
    let center: NSPoint
    let name: String?
    let icon: NSImage?
    let contentKey: String
    /// When set, this is a blank placeholder caption for an unnamed space: it renders nothing
    /// but occupies this hit width (centered where a name would sit) so a click opens the
    /// rename editor. nil for real name/icon captions.
    var placeholderWidth: CGFloat? = nil
}

// MARK: - Overlay window

/// Borderless, click-through, all-spaces window pinned above Mission Control (shield level).
/// Owns one animated label per named space, keyed by space uuid. Targets stream in via
/// `update`; `step` advances a critically damped spring per label each display-link frame, so
/// motion is refresh-rate smooth no matter how the sampled geometry moves. Labels reveal with
/// a fade once their targets have held still briefly (hard max-wait so the reveal can never
/// get stuck). On exit they fade in place when the bar merely collapses, but ride up
/// off-screen with the departing tiles when Mission Control itself dismisses (`exitUpward`).
private final class OverlayWindow: NSPanel {
    /// Diagnostics hook: (labelCount, msSinceExpand) at reveal, wired to the engine's dbg log.
    static var onReveal: ((Int, Int) -> Void)?

    private let container = NSView()

    private final class Item {
        let field: NSTextField
        var text: String
        var pos: CGPoint          // animated center (window-local)
        var vel: CGPoint = .zero
        var sv: CGPoint = .zero   // smoothed sample velocity, for optional pursuit lead
        var target: CGPoint
        var tau: CGFloat
        var settled = true
        // Launch entrance: while `entering`, the caption descends from `launchStartY` to its
        // target and its opacity ramps 0→1 in step with how far down it has travelled.
        var entering = false
        var launchStartY: CGFloat = 0
        init(field: NSTextField, text: String, center: CGPoint, tau: CGFloat) {
            self.field = field
            self.text = text
            self.pos = center
            self.target = center
            self.tau = tau
        }
    }

    private var items: [String: Item] = [:]
    private var revealed = false
    private var expandedSince: CFTimeInterval?
    private var emptySince: CFTimeInterval?
    private var unstableAt: CFTimeInterval = 0
    private var lastUpdate: CFTimeInterval = 0
    private var fadeGen = 0

    // Motion tuning. τ (smoothTime) is the spring's characteristic time: ~0.08 s for pursuit
    // of continuously-moving geometry, ~0.20 s for one-shot layout jumps (space add/remove),
    // which reads like Mission Control's own glide. A one-sample target jump ≥ `layoutJump`
    // points is treated as a layout change even when the label set didn't change (adding an
    // UNNAMED space shifts every named neighbor without changing the set).
    private let tauPursuit: CGFloat = 0.08
    private let tauLayout: CGFloat = 0.20
    /// Launch entrance: a much tighter τ than pursuit so the half-screen drop-in arrives
    /// snappily rather than floating down on the spring's slow tail.
    private let tauLaunch: CGFloat = 0.045
    private let layoutJump: CGFloat = 30
    /// Pursuit lead in multiples of τ: a critically damped spring lags a ramp by τ·v, visible
    /// against Apple's own caption below. Measured (add/delete-desktop rearranges): the window
    /// server DOES report live interpolated tile bounds — ~570 pt/s glides, which at τ=0.08
    /// means ~45 pt of trail without lead. 1 cancels ramp lag exactly. Lead applies only in
    /// pursuit mode: a layout JUMP spikes the one-sample velocity estimate and would overshoot.
    private let leadFactor: CGFloat = 1
    private let leadClamp: CGFloat = 60

    // Reveal gating (time-based, measured on sampled targets — never on animated positions).
    // Small non-zero: hold the reveal until the bar has stopped moving, so the drop-in
    // entrance (below) always plays over STATIONARY tiles. Mouse opens are detected late
    // (bar already settled), so this is a no-op for them; hotkey opens are detected the
    // instant the bar starts expanding (WillOpen burst), and revealing mid-morph made the
    // entrance fight the still-moving bar — out of sync. maxWait is the can't-get-stuck cap.
    private let revealStableFor: CFTimeInterval = 0.05
    private let revealMaxWait: CFTimeInterval = 0.50
    private let stabilityEps: CGFloat = 1.0

    /// Launch entrance: the initial batch of captions originates halfway between its resting
    /// spot and the top of the screen, then descends into place while its opacity ramps 0→100%
    /// with the descent — so the captions fade in as they slide down onto the tiles.
    private let launchStartFraction: CGFloat = 0.5

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        container.frame = NSRect(origin: .zero, size: contentRect.size)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.alphaValue = 0
        contentView = container
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Whether any label still has distance to cover (drives the engine's settle logic).
    var needsMotion: Bool { items.values.contains { !$0.settled } }

    /// Window-local hit rects of the revealed labels, keyed by space uuid, with a small
    /// slop so the thin text row is a comfortable click target. Main thread only — the
    /// engine publishes these into a locked snapshot for the tap thread's hit test.
    func labelHitAreas() -> [(uuid: String, rect: NSRect)] {
        guard revealed else { return [] }
        // Centered-on-thumbnail icon labels are not rename targets — a click there should
        // fall through to the tile (switching to the space) like anywhere else on it.
        return items.filter { !$0.key.hasSuffix(mcIconLabelSuffix) }
            .map { ($0.key, $0.value.field.frame.insetBy(dx: -6, dy: -4)) }
    }

    /// `nil` or empty => collapsed / MC closed: fade out and clear. Non-empty => expanded:
    /// diff against the shown labels by space uuid and retarget the springs.
    func update(labels: [BarLabel]?, now: CFTimeInterval) {
        guard let labels, !labels.isEmpty else {
            guard expandedSince != nil || !items.isEmpty else { emptySince = nil; return }
            // Grace period: every tile vanishing at once is how MC dismissal BEGINS (the
            // bar follows ~30 ms later, and the AX-teardown trigger can take ~150 ms) —
            // hold long enough for the fly-off exit to win over this in-place fade.
            if let since = emptySince {
                if now - since >= 0.25 { emptySince = nil; fadeOutAndClear() }
            } else {
                emptySince = now
            }
            return
        }
        emptySince = nil
        let sdt = min(max(now - lastUpdate, 1.0 / 240), 0.25)
        lastUpdate = now
        if expandedSince == nil {
            // Fresh expand: cancel any in-flight fade-out teardown and start clean.
            fadeGen += 1
            container.subviews.forEach { $0.removeFromSuperview() }
            items.removeAll()
            expandedSince = now
            unstableAt = now
        }

        var changedSet = false
        var maxDrift: CGFloat = 0
        var seen = Set<String>()
        for l in labels {
            seen.insert(l.id)
            if let it = items[l.id] {
                let dx = l.center.x - it.target.x, dy = l.center.y - it.target.y
                let d = (dx * dx + dy * dy).squareRoot()
                maxDrift = max(maxDrift, d)
                it.target = l.center
                let raw = CGPoint(x: dx / sdt, y: dy / sdt)
                it.sv = CGPoint(x: it.sv.x * 0.7 + raw.x * 0.3, y: it.sv.y * 0.7 + raw.y * 0.3)
                if d >= layoutJump { it.tau = tauLayout }
                if d > 0.01 { it.settled = false }
                if it.text != l.contentKey { retext(it, l) }
            } else {
                changedSet = true
                addItem(l)
            }
        }
        let gone = items.keys.filter { !seen.contains($0) }
        for id in gone {
            changedSet = true
            removeItem(items.removeValue(forKey: id)!)
        }
        // NOTE: a changed label set does NOT force layout-mode τ onto items in motion:
        // add/delete rearranges stream live interpolated bounds (measured), and the tight
        // pursuit τ + lead is what keeps labels riding their thumbnails through them.
        // Layout-mode τ is reserved for genuine one-sample jumps (d ≥ layoutJump).

        if maxDrift >= stabilityEps || changedSet { unstableAt = now }
        if !revealed, let since = expandedSince,
           now - unstableAt >= revealStableFor || now - since >= revealMaxWait {
            revealed = true
            OverlayWindow.onReveal?(items.count, Int((now - since) * 1000))
            beginEntrance()
            fadeIn()
        }
    }

    /// Seed the drop-in entrance for every currently-shown label AT REVEAL, so the descent
    /// starts from the labels' resting tiles (now settled) rather than from wherever the bar
    /// happened to be when the labels were first added mid-expansion.
    private func beginEntrance() {
        let top = container.bounds.height
        for it in items.values {
            it.launchStartY = it.target.y + (top - it.target.y) * launchStartFraction
            it.pos = CGPoint(x: it.target.x, y: it.launchStartY)
            it.vel = .zero
            it.tau = tauLaunch
            it.entering = true
            it.settled = false
            it.field.alphaValue = 0
            place(it, aligned: false)
        }
    }

    /// Exact critically damped spring step for one axis:  x'' = ω²(target−x) − 2ωx'.
    /// Pure — kept separate so the self-test can pin the math.
    static func springStep(pos: CGFloat, vel: CGFloat, target: CGFloat,
                           tau: CGFloat, dt: CFTimeInterval) -> (pos: CGFloat, vel: CGFloat) {
        let omega = 2 / tau
        let e = CGFloat(exp(-Double(omega) * dt))
        let dx = pos - target
        let tmp = (vel + omega * dx) * CGFloat(dt)
        return (target + (dx + tmp) * e, (vel - omega * tmp) * e)
    }

    /// Advance all springs by `dt`. Returns true while anything is still moving.
    func step(dt: CFTimeInterval) -> Bool {
        guard dt > 0 else { return needsMotion }
        var moving = false
        for it in items.values where !it.settled {
            var tx = it.target.x, ty = it.target.y
            if leadFactor > 0, it.tau == tauPursuit {
                let lead = it.tau * leadFactor
                var lx = it.sv.x * lead, ly = it.sv.y * lead
                let mag = (lx * lx + ly * ly).squareRoot()
                if mag > leadClamp { lx *= leadClamp / mag; ly *= leadClamp / mag }
                tx += lx; ty += ly
            }
            let sx = Self.springStep(pos: it.pos.x, vel: it.vel.x, target: tx, tau: it.tau, dt: dt)
            let sy = Self.springStep(pos: it.pos.y, vel: it.vel.y, target: ty, tau: it.tau, dt: dt)
            it.pos.x = sx.pos; it.vel.x = sx.vel
            it.pos.y = sy.pos; it.vel.y = sy.vel

            if it.entering {
                // Opacity tracks vertical progress from the launch origin down to the target.
                let span = it.launchStartY - it.target.y
                let frac = span > 0.5 ? (it.launchStartY - it.pos.y) / span : 1
                it.field.alphaValue = max(0, min(1, frac))
            }

            let rx = it.pos.x - it.target.x, ry = it.pos.y - it.target.y
            if (rx * rx + ry * ry).squareRoot() < 0.05, (it.vel.x * it.vel.x + it.vel.y * it.vel.y).squareRoot() < 0.5 {
                it.pos = it.target
                it.vel = .zero
                it.settled = true
                it.tau = tauPursuit
                if it.entering { it.entering = false; it.field.alphaValue = 1 }
                place(it, aligned: true)
            } else {
                moving = true
                place(it, aligned: false)
            }
        }
        return moving
    }

    /// Immediate teardown (engine disabled) — no fades.
    func clearImmediately() {
        fadeGen += 1
        container.subviews.forEach { $0.removeFromSuperview() }
        items.removeAll()
        revealed = false
        expandedSince = nil
        emptySince = nil
        container.alphaValue = 0
        orderOut(nil)
    }

    // MARK: - Item management

    private func addItem(_ l: BarLabel) {
        let field = Self.makeLabel(l)
        let it = Item(field: field, text: l.contentKey, center: l.center, tau: tauPursuit)
        container.addSubview(field)
        if revealed {
            // Mid-session appearance (space added / renamed from empty): fade like MC's own
            // captions — alpha only, no scale.
            place(it, aligned: true)
            field.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = Self.fadeInCurve
                field.animator().alphaValue = 1
            }
        } else {
            // Launch batch, pre-reveal: stay invisible and track the tile silently. The
            // drop-in entrance for the whole batch is seeded together once the bar settles
            // and reveal fires (see beginEntrance()).
            field.alphaValue = 0
            place(it, aligned: false)
        }
        items[l.id] = it
    }

    private func removeItem(_ it: Item) {
        let field = it.field
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            field.animator().alphaValue = 0
        }, completionHandler: {
            field.removeFromSuperview()
        })
    }

    private func retext(_ it: Item, _ l: BarLabel) {
        it.text = l.contentKey
        Self.applyContent(l, to: it.field)
        place(it, aligned: it.settled)
    }

    /// Frames derive from the animated CENTER. Sub-pixel origins while moving (native-feeling
    /// motion softness); backing-pixel alignment at rest so glyphs stay crisp on Retina.
    private func place(_ it: Item, aligned: Bool) {
        let size = it.field.frame.size
        var rect = NSRect(x: it.pos.x - size.width / 2, y: it.pos.y - size.height / 2,
                          width: size.width, height: size.height)
        if aligned { rect = container.backingAlignedRect(rect, options: .alignAllEdgesNearest) }
        it.field.setFrameOrigin(rect.origin)
    }

    // MARK: - Container fades

    /// Quadratic ease-in (α ≈ t²): only ~1/4 opacity at the halfway point, then accelerating
    /// to full — the label materializes rather than popping.
    private static let fadeInCurve = CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53)

    /// Launch reveal: the container is shown at full opacity immediately — each caption then
    /// fades itself in via its per-item entrance alpha as it descends (see `step`).
    private func fadeIn() {
        container.alphaValue = 1
    }

    private func fadeOutAndClear() {
        revealed = false
        expandedSince = nil
        items.removeAll()
        fadeGen += 1
        let gen = fadeGen
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGen else { return }
            self.container.subviews.forEach { $0.removeFromSuperview() }
            self.orderOut(nil)
        })
    }

    /// Mission Control is dismissing: the tiles fly up off the top edge, and their windows
    /// are already destroyed (no bounds to track), so the labels ride a synthesized version
    /// of that motion — an ease-in launch off the top of the screen plus a fade. Close is
    /// detected within a frame or two, so the launch starts from where the tiles were.
    func exitUpward() {
        emptySince = nil
        guard !items.isEmpty else {
            if expandedSince != nil || revealed { fadeOutAndClear() }
            return
        }
        revealed = false
        expandedSince = nil
        let fields = items.values.map(\.field)
        items.removeAll()
        fadeGen += 1
        let gen = fadeGen
        let lowest = fields.map { $0.frame.minY }.min() ?? frame.height
        let travel = frame.height - lowest + 12   // clears the top edge with a small margin
        NSAnimationContext.runAnimationGroup({ ctx in
            // MC's own exit clears the screen in ~0.2 s (measured from a mid-exit frame
            // capture) — matching it keeps the labels from trailing the departed tiles.
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            for f in fields {
                f.animator().setFrameOrigin(NSPoint(x: f.frame.origin.x, y: f.frame.origin.y + travel))
            }
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGen else { return }
            self.container.subviews.forEach { $0.removeFromSuperview() }
            self.orderOut(nil)
        })
    }

    /// Icon and/or text on a transparent background — sized per the label-size pref (default
    /// matches Apple's "Desktop N" caption font but bold and a touch larger). Always WHITE,
    /// regardless of light/dark mode, matching Mission Control's own captions and the app's
    /// switcher bar (both draw light over the dimmed backdrop); the shadow keeps it readable.
    private static func makeLabel(_ l: BarLabel) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        field.shadow = shadow
        applyContent(l, to: field)
        return field
    }

    /// Render the label's icon and/or name into the field at the configured size. The icon
    /// rides in an NSTextAttachment so icon+text stay a single animatable view; SF Symbol
    /// (template) images are pre-flattened to labelColor because attachment cells draw
    /// images verbatim, without the text-color tinting template images get elsewhere.
    private static func applyContent(_ l: BarLabel, to field: NSTextField) {
        let size = mcLabelPointSize
        let font = NSFont.systemFont(ofSize: size,
                                     weight: Prefs.missionControlLabelsBold ? .bold : .regular)
        if let w = l.placeholderWidth {
            // Blank rename target: no glyphs, but a real one-line caption's footprint so the
            // hit area sits exactly where a name would (centered by `place` on its frame).
            field.attributedStringValue = NSAttributedString(string: "")
            field.frame.size = NSSize(width: w, height: (size * 1.2).rounded())
            return
        }
        let out = NSMutableAttributedString()
        if let icon = l.icon {
            let image = icon.isTemplate ? tinted(icon, color: .white) : icon
            let attachment = NSTextAttachment()
            attachment.image = image
            // Center the icon on the text's cap-height midline.
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(attachment: attachment))
            if l.name != nil { out.append(NSAttributedString(string: " ")) }
        }
        if let name = l.name { out.append(NSAttributedString(string: name)) }
        // The attributed string's paragraph style trumps the field's own alignment and
        // line-break settings — without an explicit one the defaults (natural alignment,
        // word wrap) silently replace the centered tail-truncating layout.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        out.addAttributes([.font: font, .foregroundColor: NSColor.white,
                           .paragraphStyle: style],
                          range: NSRange(location: 0, length: out.length))
        field.attributedStringValue = out
        field.sizeToFit()
        let maxWidth = size * 12.5   // 175 pt at the default 14 pt — scales with the slider
        if field.frame.width > maxWidth { field.frame.size.width = maxWidth }
    }

    /// Flatten a template image to a concrete color rendering (attachment cells draw
    /// images verbatim, without the text-color tinting template images get elsewhere).
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
