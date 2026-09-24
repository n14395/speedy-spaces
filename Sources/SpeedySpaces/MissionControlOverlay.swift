// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore

/// Draws each space's custom name onto the macOS Mission Control spaces bar while Mission
/// Control is open. One shield-level, click-through overlay window per display. No SIP, no
/// injection, no Accessibility.
///
/// Pipeline (macOS 27 "replay" architecture — see fix-workspace-lag.md, probe/mcprobe.m):
/// WindowManager animates Mission Control inside its own Core Animation — tile WINDOW
/// bounds never interpolate at the window-server level; they snap once per layout commit,
/// and each commit announces itself as an SLS 806/807 notification burst carrying the
/// FINAL bounds a few hundred ms before the visible glide completes. So chasing sampled
/// bounds per frame can only trail; instead the engine listens for those events (811
/// births arm discovery, 806/807 commits retarget) and REPLAYS the native glide open-loop
/// on a matched critically damped spring, moving in sync with the tiles by construction.
/// A slow idle poll (`CGWindowListCopyWindowInfo`) still detects the spaces bar by LAYER +
/// GEOMETRY and caches the bar/tile window IDs ("discovery"); it doubles as the fallback
/// cadence — if the private notification surface ever vanishes, the engine degrades to
/// the old per-frame sampling chase instead of breaking. The CADisplayLink runs only
/// while label springs are in motion. Tile index → space is left-to-right = ordinal
/// order per display.
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
    /// Tracking backstop cadence, and the link-silence a backstop tick has to see before it
    /// drives a frame itself. The gap is deliberately just over one 120 Hz interval, so on a
    /// healthy link every backstop tick returns immediately and costs nothing.
    private let backstopInterval: TimeInterval = 1.0 / 60
    private let linkStallGap: TimeInterval = 1.0 / 90

    // MARK: - Discovery / sampling state

    private var barIDs: [CGWindowID] = []
    private var tileIDs: [CGWindowID] = []
    private var needsRediscovery = false
    private var discoveryInFlight = false
    private let scanQueue = DispatchQueue(label: "mco.scan", qos: .userInteractive)
    private var lastDiscovery: CFTimeInterval = 0
    private var lastSpacesRefresh: CFTimeInterval = 0
    private var lastMismatchSig = ""
    private var lastTileRects: [NSRect] = []
    private var lastBarRects: [NSRect] = []
    /// Cached geometry between polls (see frame()'s `mustSample`).
    private var lastSampleResult: (bars: [NSRect], tiles: [(wid: CGWindowID, rect: NSRect)],
                                   missing: Bool, barsOnScreen: Int) = ([], [], false, 0)
    private var haveSample = false
    private var lastSample: CFTimeInterval = 0
    /// Set by an SLS event or a phase change: take a fresh sample on the next frame no
    /// matter where the poll cadence sits.
    private var sampleNow = false
    /// The sampler's own queue. Sampling is one synchronous window-server round-trip per
    /// tracked window, and those round-trips BLOCK for as long as WindowManager takes to
    /// composite a relayout — 130 ms typically, 567 ms once, on an add/remove
    /// (fix-workspace-lag.md). An add or remove is the one interaction that lands SEVERAL
    /// commits 60–130 ms apart (probe/captures/final.log: 806 bursts at +0, +129 and
    /// +189 ms), so the second and third commit samples ran while the first glide was
    /// compositing and froze the main thread — and with it every label — mid-glide.
    /// Off-main, the frames keep stepping the springs against the last targets and the
    /// fresh ones are applied the moment the round-trip returns (`applySample`).
    /// MCO_SYNC_SAMPLE=1 restores the in-frame synchronous sample for A/B measurement.
    private let sampleQueue = DispatchQueue(label: "mco.sample", qos: .userInteractive)
    /// Serial queue for the fire-and-forget window-server calls that used to run on main
    /// (the per-window notification subscription). Serial so a later subscription can
    /// never be overtaken by an earlier one.
    private let slsQueue = DispatchQueue(label: "mco.sls", qos: .userInteractive)
    private let asyncSampling = ProcessInfo.processInfo.environment["MCO_SYNC_SAMPLE"] == nil
    private var sampleInFlight = false
    /// A commit demanded a sample while one was in flight: run one more straight after,
    /// so the newest commit's targets are never skipped — and whether that follow-up
    /// answers a replay commit.
    private var sampleWanted = false
    private var wantedReplay = false
    /// A queued urgent request inherits the slow-server verdict of the one that raised it.
    private var wantedAtomic = false
    private var wantedReplayAt: CFTimeInterval = 0
    /// Replay marking of the sample the current `retargetOnly` frame applies (see frame()),
    /// and WHICH commit that sample answers. The timestamp has to travel with the sample:
    /// bursts arrive while a round-trip is out, so by the time the answer lands
    /// `lastCommitAt` may already name a LATER commit, and measuring the glide's head start
    /// against that one puts the labels a burst out of phase with the tiles.
    private var appliedReplay = false
    private var appliedReplayAt: CFTimeInterval = 0
    /// Bumped on close so a round-trip from a dead session is dropped on arrival.
    private var sessionGen = 0
    /// Monotonic counts of adopted scans and samples, used to tell when a confirm cycle
    /// (below) has actually come back rather than merely been asked for.
    private var scansApplied = 0
    private var samplesApplied = 0
    /// A sample looked wrong (a tracked window had no bounds, the bar is gone, every tile
    /// vanished). Rather than concluding — which used to mean a synchronous window-list
    /// scan AND a synchronous re-sample on the frame path, a latent 200 ms + 350 ms
    /// main-thread block — a rescan and resample are ordered off-main and the verdict
    /// waits for them. These hold the counts at the moment the cycle started; -1 = none.
    private var confirmAtScan = -1
    private var confirmAtSample = -1
    /// When the bar first went missing, so a confirm that never lands can't hold a closed
    /// Mission Control open forever.
    private var barsGoneSince: CFTimeInterval = 0
    /// Safety poll while nothing is being chased — commits announce real changes.
    private let samplePollInterval: TimeInterval = 1.0 / 15
    /// Last mapping result, reused on frames that only need a spring step (see frame()).
    private var lastByScreen: [(screen: NSScreen, labels: [BarLabel], complete: Bool)] = []
    private var wasSuppressed = false
    private var wasTilesStill = false
    private var mappedOnce = false
    /// Whether any caption spring was still in flight at the end of the last frame (see
    /// frame()'s `mustSample`).
    private var springsFlying = false
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
    // far too late for the exit fade. So while MC is open a LISTEN-ONLY event tap watches
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
    /// When the tile count last changed, and recent tracked-tile deaths. Together these
    /// separate "the Dock rebuilt its Mission Control element because a desktop was added
    /// or removed" from "Mission Control is closing" — see axTeardownFired.
    private var tileCountChangedAt: CFTimeInterval = 0
    private var lastTileCount = -1
    /// An add is in progress until this time: exactly one tile more than a moment ago.
    /// Only the ADD gets the faster curve (see OverlayWindow.addOmega).
    private var addBoostUntil: CFTimeInterval = 0
    private var wasAddBoosting = false
    /// When we started refusing provisional layouts (see rowIsCoherent); 0 = not refusing.
    /// Bounded so a run of them can never freeze the labels.
    private var provisionalSince: CFTimeInterval = 0
    /// The commit that BEGAN a relayout we refused — the instant the OS's own tiles
    /// started moving. Carried onto the corrected commit so the labels enter the curve at
    /// the phase the tiles have already reached, rather than ~90 ms behind them.
    private var provisionalCommitAt: CFTimeInterval = 0
    private var tileDeaths: [CFTimeInterval] = []
    private var dismissDownLocation = CGPoint.zero   // tap-thread-confined (down/up pairing)
    // Vertical dock-swipe watcher (the three-finger swipe-down close) — tap-thread-confined.
    private var vswipeActive = false                 // a vertical gesture is being tracked
    private var vswipeLow = 0.0                      // lowest progress seen this gesture
    private var vswipeFired = false                  // exit fade already launched for this gesture
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

    // MARK: - SLS event path (primary geometry trigger on macOS 27)

    /// True once the SLS per-window notification surface is registered. Events arrive on
    /// the main thread via the app's event loop (delivery rides the CGS event stream).
    private var eventsArmed = false
    /// Set by an 806/807 arrival; consumed by the next frame(), which retargets the
    /// labels with the native REPLAY spring instead of the fallback pursuit/layout ones.
    private var replayCommit = false
    /// When the most recent 806/807 arrived. The tiles start their glide at that instant,
    /// so the labels' replay is begun that far in the past (see OverlayWindow.caGlide) —
    /// whatever the sample and the commit cost us, the curve is entered at the phase the
    /// tiles are already at rather than restarted from zero.
    private var lastCommitAt: CFTimeInterval = 0
    /// Final bounds read INSIDE the 806/807 callback, for the very window each event names.
    /// A relayout delivers one event per tile within ~1.6 ms and the window server already
    /// has that window's committed rect, so one query per event hands us the whole new
    /// layout by the end of the burst — without waiting for the sampler's round-trip,
    /// which measured 15-45 ms (and much worse under load). That wait was the labels
    /// sitting still and then jumping to catch up: the curve was started at the right
    /// PHASE, but only once the answer arrived. Consumed by the next frame().
    private var eventBounds: [CGWindowID: NSRect] = [:]
    /// Main-thread time already spent on those queries in the current burst. They are
    /// window-server round-trips on the main thread — the thing this whole exercise moved
    /// off it — so they are strictly budgeted, and the async sampler covers whatever the
    /// budget refuses.
    private var eventBoundsSpent: CFTimeInterval = 0
    /// Enough for a full row: an add/remove relayout announces every tile, and covering
    /// only SOME of them is the worst outcome available — the covered labels leave on the
    /// native curve while the rest wait for the sampler, so the row visibly splits. At 6 ms
    /// that happened repeatedly (measured: bursts covered 2, 3, 4, 6 and 9 of 11-12 tiles).
    /// The budget is a guard against a pathologically slow window server, not a tuning
    /// knob, so it is set well above the real cost and partial coverage is handled
    /// properly besides: the burst asks the sampler for the rest, carrying this commit's
    /// marking, so whatever the callbacks miss still enters the curve at the right phase.
    private let eventBoundsBudget: CFTimeInterval = 0.008
    /// A SINGLE query this slow means the window server is stalled; the whole point of
    /// reading bounds here is that it is cheap, so stop for this burst and let the
    /// off-main sampler answer. Without this the path meant to REMOVE latency becomes the
    /// main-thread blocker that delays installing the animation — measured 25 ms burned by
    /// one query under screen-recording load.
    private let eventQueryCap: CFTimeInterval = 0.002
    /// The budget cut a burst short, so the sampler still owes us some tiles.
    private var eventBudgetHit = false
    /// One geometry request per commit burst, fired from the burst itself.
    private var burstSampleAsked = false
    /// Coalesces an event burst (one event per tile within ~1 ms at a relayout commit)
    /// into a single frame() on the next run-loop turn.
    private var framePending = false
    /// Wids from 811 births awaiting classification, coalesced per run-loop turn.
    private var pendingBirths: Set<CGWindowID> = []
    private var birthsPending = false
    /// Rate limit for 811-triggered probes while closed (811 fires for EVERY window
    /// born in the session, not just Mission Control's).
    private var lastEventProbe: CFTimeInterval = 0

    /// MCO_NO_GLIDE_POLL=1 restores the old behaviour of suppressing the steady geometry
    /// poll while a glide is in flight. See the reasoning at its use in frame().
    private static let pollWhileGliding = ProcessInfo.processInfo.environment["MCO_NO_GLIDE_POLL"] == nil

    /// Geometry sampler. Default: `SLSGetWindowBounds` — one direct window-server query
    /// per window, allocation-free, reporting the rect WindowManager actually committed.
    ///
    /// The public description path used to be the default because it also carries
    /// kCGWindowIsOnscreen, which was the earliest dismissal signal available (tiles went
    /// !onscreen ~30 ms into the exit, ahead of the bar). That measurement INVERTED on
    /// 26A5425a: the flag now outlives the close by ~470 ms, while the Dock's "mc" AX
    /// element dies at +0 ms and drives the exit instead (fix-workspace-lag.md). With its
    /// one advantage gone, the cheaper path wins on merit.
    ///
    /// HOW MUCH cheaper depends entirely on how busy the window server is, and the old
    /// "280 µs vs 508 µs over 19 windows" note here was wrong by orders of magnitude.
    /// Measured directly 2026-09-19 (scratchpad/scaling.swift, 11 windows, 300 trials):
    ///
    ///   server idle     11 x SLSGetWindowBounds  0.016 ms   |  1 description call  1.277 ms
    ///   in-app, normal  the same sample           5-11 ms   |  (a 1-wid describe)   7-14 ms
    ///   in-app, recording                       80-280 ms   |  (a 1-wid describe)  20-57 ms
    ///
    /// A bounds query is essentially FREE when the server is free: all of the in-app cost
    /// is waiting on a busy server. So the per-window path waits eleven times where the
    /// description path waits once, and which one wins flips with server load — the
    /// per-window path by ~80x when idle, the single call by 3-5x under a screen
    /// recording. Hence the default here (fast case) and `atomic` in requestSample (slow
    /// case). Freshness does NOT differ: the description path was measured to report the
    /// same rect as SLS with zero lag (scratchpad/freshness.swift), so choosing by load
    /// costs no accuracy.
    /// MCO_CGDESC=1 forces the description path back for everything.
    private let useSLS = sm_getWindowBoundsAvailable()
        && ProcessInfo.processInfo.environment["MCO_CGDESC"] == nil

    // MARK: - Screen / spaces caches (invalidated on screen or space-list change)

    private var primaryH: CGFloat = 0
    private var displayUUIDs: [CGDirectDisplayID: [String]] = [:]
    private var screenCacheDirty = true
    private var spacesByDisplay: [CGDirectDisplayID: [Space]] = [:]
    private var cachedSpaces: [Space] = []

    // Rendered label content per space uuid. Resolving an SF Symbol is real CoreUI work
    // and every Prefs getter is a CFPreferences read; doing both per space per frame
    // measured ~40% of the tracking frame and ~70% of the settled tick. Content only
    // changes with metadata or prefs, so it is cached until either bumps `contentGen`.
    // The outer Optional is the cache probe; the inner one caches "renders nothing".
    private var labelContentCache: [String: (name: String?, icon: NSImage?, key: String)?] = [:]
    private var iconOverlayCache: [String: (icon: NSImage, key: String)?] = [:]
    /// Bumped whenever the caches are invalidated; mapLabels re-runs when it changes.
    private var contentGen = 0
    private var mappedContentGen = -1

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

    /// Debug-only main-run-loop stall attribution. A `frame gap` says the labels stood
    /// still; this says WHY — "busy" means the main thread was inside a call (a
    /// window-server round-trip, a CoreAnimation commit), "idle" means it had nothing
    /// scheduled and neither the display link nor the backstop woke it. Installed for the
    /// duration of a Mission Control session.
    private var loopObserver: CFRunLoopObserver?
    /// Second observer, ordered AFTER CoreAnimation's commit (which runs at order
    /// 2_000_000 on `beforeWaiting`). The pair splits a main-thread stall into the part
    /// spent in our own source handling and the part spent inside the CA commit waiting on
    /// the window server — two very different bugs, and the first observer alone cannot
    /// tell them apart because it fires BEFORE the commit.
    private var loopPostObserver: CFRunLoopObserver?
    private var loopAwakeAt: CFTimeInterval = 0
    private var loopSleptAt: CFTimeInterval = 0
    private var loopPreCommitAt: CFTimeInterval = 0

    // Per-frame cost accounting, reported every 120 frames while logging is on.
    private var noLayerGlides = 0
    private var statN = 0
    private var statSum = 0.0
    private var statMin = Double.infinity
    private var statMax = 0.0
    private var statSampleSum = 0.0
    private var statApplySum = 0.0
    private var statDiscovers = 0
    private var statRefreshes = 0
    private var statSamples = 0
    private var statSampleMaxUs = 0        // slowest round-trip in the window
    private var statSampleLatMaxUs = 0     // longest request→apply latency in the window

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
        // Rendered-content cache invalidation: metadata edits and any prefs write.
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentSourcesChanged),
            name: .speedySpacesMetadataChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentSourcesChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        OverlayWindow.onReveal = { [weak self] count, ms in
            self?.dbg("reveal: \(count) labels after \(ms) ms")
        }
        if debugLog {
            OverlayWindow.onAlpha = { [weak self] whence, report in
                self?.logLine("alpha \(whence): \(report)")
            }
            OverlayWindow.onTrace = { [weak self] line in self?.logLine(line) }
            OverlayWindow.onNoLayer = { [weak self] in
                guard let self else { return }
                self.noLayerGlides += 1
                if self.noLayerGlides <= 3 || self.noLayerGlides % 20 == 0 {
                    self.dbg("glide fell back to the main-thread spring — the label had no"
                             + " layer yet (\(self.noLayerGlides) so far this session)")
                }
            }
        }
    }

    @objc private func contentSourcesChanged() {
        labelContentCache.removeAll()
        iconOverlayCache.removeAll()
        contentGen += 1
        if phase != .closed { kickFrame() }
    }

    @objc private func spaceChanged() {
        guard phase != .closed else { return }
        // A space switch normally means a switch-and-dismiss — but switching WHILE Mission
        // Control stays open (⌃-arrow / number key) must not launch the exit fade: the labels
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
        if !eventsArmed, sm_slsWindowEventsAvailable() {
            MCOEventBridge.overlay = self
            eventsArmed = sm_slsWindowEventsStart(mcoSLSEventTrampoline)
        }
        dbg("engine started (policy=\(NSApp.activationPolicy().rawValue), sampler=\(useSLS ? "SLS" : "CGDescription"), events=\(eventsArmed))")
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
    /// the labels' exit fade now so it lands with the native fade instead of trailing it. The
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
        case .settled:
            sampleNow = true            // this watch exists to spot the bar going away
            frame(now: CACurrentMediaTime(), dt: 0, stepSprings: false)
        case .tracking: driveFrame(minInterval: linkStallGap)
        }
    }

    /// See `loopObserver`. Debug builds only, and only while Mission Control is open.
    private func startLoopWatch() {
        guard debugLog, loopObserver == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                self.loopAwakeAt = now
                let idle = now - self.loopSleptAt
                if self.loopSleptAt > 0, idle >= 0.04, self.phase == .tracking {
                    self.dbg("main idle \(Int(idle * 1000)) ms — run loop slept, nothing woke it")
                }
            } else {
                self.loopPreCommitAt = now
                let busy = now - self.loopAwakeAt
                if self.loopAwakeAt > 0, busy >= 0.04 {
                    self.dbg("main busy \(Int(busy * 1000)) ms in SOURCES — our own handlers")
                }
            }
        }
        guard let obs else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        loopObserver = obs
        loopAwakeAt = 0; loopSleptAt = 0; loopPreCommitAt = 0

        // Ordered after CoreAnimation's commit observer (2_000_000).
        let post = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001
        ) { [weak self] _, _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.loopSleptAt = now
            let commit = now - self.loopPreCommitAt
            if self.loopPreCommitAt > 0, commit >= 0.04 {
                self.dbg("main busy \(Int(commit * 1000)) ms in CA COMMIT — window server flush")
            }
        }
        if let post {
            CFRunLoopAddObserver(CFRunLoopGetMain(), post, .commonModes)
            loopPostObserver = post
        }
    }

    private func stopLoopWatch() {
        if let obs = loopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
            loopObserver = nil
        }
        if let post = loopPostObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), post, .commonModes)
            loopPostObserver = nil
        }
    }

    private func enterTracking() {
        phase = .tracking
        stableFrames = 0
        sampleNow = true
        if let link {
            link.isPaused = false
        } else if let screen = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) {
            let l = screen.displayLink(target: self, selector: #selector(frameTick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        // Backstop for the display link, which STOPS being called while WindowManager
        // composites a Mission Control relayout — measured 567 ms without a single
        // callback across an add-desktop animation, so the captions sat still through the
        // whole glide and then landed in one step. The run loop itself keeps turning, so
        // an ordinary timer carries the springs through the gap. It only fires frames the
        // link failed to deliver (see `linkStallGap`), and is the sole driver on a
        // headless/no-screen build, where `link` stays nil.
        scheduleTimer(backstopInterval, tolerance: 0.002)
        lastFrame = CACurrentMediaTime()
    }

    private func enterSettled() {
        phase = .settled
        link?.isPaused = true
        // The tight watch stays even with the event path armed: geometry changes
        // announce themselves (806/807/811/804/816), but DISMISSALS often don't — a
        // keyboard close on an un-AX-trusted build has no tap signal and its first
        // event (804) arrives ~0.5 s in, which left labels floating over the restored
        // desktop (measured from the 2026-08-14 screen recording, when this watch
        // briefly ran at 1 s). 20 Hz × describeWindows on ~14 wids is cheap.
        scheduleTimer(settledInterval, tolerance: 0.01)
        dbg("settled (link paused)")
    }

    private func close(dismissing: Bool) {
        guard phase != .closed else { return }
        phase = .closed
        // Listeners outside the overlay (the switcher HUD) key off MC visibility too.
        NotificationCenter.default.post(name: .speedySpacesMissionControlClosed, object: nil)
        removeDismissTap()
        stopAXWatch()
        stopLoopWatch()
        link?.invalidate(); link = nil
        stableFrames = 0
        barIDs = []; tileIDs = []; lastTileRects = []
        lastBarRects = []; lastByScreen = []; mappedOnce = false
        haveSample = false; sampleNow = false; lastSample = 0; discoveryInFlight = false
        sessionGen += 1; sampleInFlight = false; sampleWanted = false
        wantedReplay = false; appliedReplay = false; wantedAtomic = false
        confirmAtScan = -1; confirmAtSample = -1; barsGoneSince = 0
        wantedReplayAt = 0; appliedReplayAt = 0; lastCommitAt = 0
        eventBounds.removeAll(); eventBoundsSpent = 0; eventBudgetHit = false
        burstSampleAsked = false
        pendingBirths = []
        lastSampleResult = ([], [], false, 0)
        wasSuppressed = false; wasTilesStill = false; mappedContentGen = -1
        springsFlying = false
        clickGates.set((barMaxY: 300, tileRects: []))
        labelAreas.withLock { $0.areas = [] }
        lastMismatchSig = ""
        awaitingTiles = false
        tileSpace = [:]; mouseHeld.set(false)
        tileDeaths = []; tileCountChangedAt = 0; lastTileCount = -1
        addBoostUntil = 0; wasAddBoosting = false
        provisionalSince = 0; provisionalCommitAt = 0
        // A reorder drag inside this session changed the space order; the commit is
        // reliably readable once MC is gone. Harmless no-op otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.spaces.refresh()
        }
        let now = CACurrentMediaTime()
        for w in overlays.values {
            if dismissing { w.exitDismiss() } else { w.update(labels: nil, now: now) }
        }
        scheduleTimer(idleInterval, tolerance: 0.03)
        if statN > 0 {
            dbg("frame µs min=\(Int(statMin)) avg=\(Int(statSum / Double(statN))) max=\(Int(statMax))"
                + " sampleAvg=\(Int(statSampleSum / Double(statN))) applyAvg=\(Int(statApplySum / Double(statN)))"
                + " discovers=\(statDiscovers) refreshes=\(statRefreshes)"
                + " samples=\(statSamples) rtMax=\(statSampleMaxUs)µs latMax=\(statSampleLatMaxUs)µs n=\(statN)")
            statN = 0; statSum = 0; statMin = .infinity; statMax = 0
            statSampleSum = 0; statApplySum = 0; statDiscovers = 0; statRefreshes = 0
            statSamples = 0; statSampleMaxUs = 0; statSampleLatMaxUs = 0
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
            startLoopWatch()
            enterTracking()
            frame(now: now, dt: 0, stepSprings: false)
        } else if burstUntil > 0, now >= burstUntil {
            burstUntil = 0
            scheduleTimer(idleInterval, tolerance: 0.03)
        }
    }

    // MARK: - SLS event arrivals (main thread, via the app's event loop)

    /// 811 create · 806 moved · 807 resized · 804 destroyed. 806/807 fire once per
    /// layout commit with the FINAL bounds already readable — that's the replay trigger.
    /// Tiles are BORN at final bounds on hover-expand (811 with no follow-up move), so
    /// births prompt rediscovery rather than waiting for a move that never comes.
    fileprivate func handleSLSEvent(type: UInt32, wid: UInt32) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        switch type {
        case 811 where phase == .closed:
            // Some window was born session-wide — cheap rate-limited probe, so external
            // MC opens (F3 / hot corner / swipe) are caught near-instantly instead of at
            // the idle poll's cadence.
            if now - lastEventProbe >= 0.12 { lastEventProbe = now; probe() }
        case 811:
            // A window was born somewhere in the session. On this build 811 is NOISY — it
            // fires for unrelated window churn every few hundred ms, open or not — so
            // treating each one as "rescan everything" pinned discovery at its 100 ms
            // cadence for whole sessions. Classify the single new wid instead; only one
            // too fresh to describe falls back to a scan (the expand case, where tiles are
            // born at 0x0 and materialise later).
            pendingBirths.insert(wid)
            kickBirths()
        case 806, 807:
            guard phase != .closed, tileIDs.contains(wid) || barIDs.contains(wid) else { return }
            if !replayCommit { lastCommitAt = now; eventBoundsSpent = 0; burstSampleAsked = false }
            replayCommit = true
            // Read this window's committed rect while we are already here. Budgeted: if
            // the window server is making these slow (it is compositing the very relayout
            // being announced), stop and let the off-main sampler answer instead.
            if eventBoundsSpent < eventBoundsBudget, primaryH > 0 {
                let t0 = CACurrentMediaTime()
                var r = CGRect.zero
                if sm_getWindowBounds(wid, &r), Self.tileBand(r.size) || Self.barBand(r.size) {
                    eventBounds[wid] = NSRect(x: r.minX, y: primaryH - r.minY - r.height,
                                              width: r.width, height: r.height)
                }
                let cost = CACurrentMediaTime() - t0
                eventBoundsSpent += cost
                if cost > eventQueryCap { eventBoundsSpent = eventBoundsBudget; eventBudgetHit = true }
            } else if primaryH > 0 {
                eventBudgetHit = true
            }
            // Ask for the geometry HERE, not from the frame kickFrame is about to schedule.
            // That frame cannot run until the main thread is free, and the reason the labels
            // still started late on a big relayout was that the request waited behind it
            // (measured 30 ms, far worse under load). The request only hands work to the
            // sampler queue, so firing it from the callback overlaps the round-trip with
            // whatever is occupying the main thread. Once per burst, and it carries this
            // commit's marking so whatever the cheap in-callback reads miss still enters
            // the curve at the phase it has actually reached.
            if !burstSampleAsked {
                burstSampleAsked = true
                // `eventBudgetHit` is this burst's own evidence, gathered microseconds ago:
                // a single bounds query took longer than `eventQueryCap` on the main
                // thread, so the window server is stalled right now (it is compositing the
                // relayout being announced). That is precisely when one call for the whole
                // row beats a query per window, and it is why this cannot fire in a normal
                // session, where the same burst covers every tile in well under a
                // millisecond.
                requestSample(now: now, urgent: true, replay: true, replayAt: lastCommitAt,
                              atomic: eventBudgetHit)
            }
            kickFrame()
        case 804, 816:
            // A tracked window died (804) or committed its teardown (816, observed only
            // at window death on this OS) — usually the dismissal. Confirm through the
            // ordinary frame path now rather than at the settled watch's cadence.
            // The event already says which wid went, so drop it directly: a full rescan
            // adds nothing, and leaving the dead wid in the list makes the next sample()
            // report `missing` and force a synchronous rescan on the frame path anyway.
            guard phase != .closed, tileIDs.contains(wid) || barIDs.contains(wid) else { return }
            if tileIDs.contains(wid) {
                tileDeaths.append(now)
                tileDeaths.removeAll { now - $0 > 0.5 }
            }
            barIDs.removeAll { $0 == wid }
            tileIDs.removeAll { $0 == wid }
            unchangedDiscoveries = 0
            kickFrame()
        default:
            break
        }
    }

    /// Classify a burst of freshly born wids with ONE window-server describe call,
    /// adopting any that are Mission Control's bar/tile windows. Coalesced per run-loop
    /// turn like kickFrame. A wid that cannot be described yet (born at 0x0, bounds not
    /// materialised) falls back to the ordinary rediscovery path.
    private func kickBirths() {
        guard !birthsPending else { return }
        birthsPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.birthsPending = false
            let wids = self.pendingBirths
            self.pendingBirths = []
            guard self.phase != .closed, !wids.isEmpty else { return }
            // The describe is a window-server round-trip, and on an add the births land
            // ~13 ms after a relayout commit (probe/captures/final.log) — inside the
            // compositing window where such round-trips block (see `sampleQueue`).
            // Off-main; the adoption itself happens on main.
            let gen = self.sessionGen
            self.scanQueue.async { [weak self] in
                let t0 = CACurrentMediaTime()
                let described = Self.describeForDiscovery(Array(wids))
                let us = Int((CACurrentMediaTime() - t0) * 1_000_000)
                DispatchQueue.main.async { [weak self] in
                    self?.adoptBirths(described, gen: gen, roundTripUs: us)
                }
            }
        }
    }

    /// Main thread: classify a described burst of births, adopting any that are Mission
    /// Control's bar/tile windows.
    private func adoptBirths(_ described: [CGWindowID: (layer: Int, owner: String, onscreen: Bool)?],
                             gen: Int, roundTripUs: Int) {
        guard gen == sessionGen, phase != .closed else { return }
        if debugLog, roundTripUs >= 2_000 {
            dbg("births: describe of \(described.count) wids took \(roundTripUs) µs off-main")
        }
        var adopted = false
        var unresolved = false
        for (wid, info) in described {
            guard let info else { unresolved = true; continue }
            guard info.owner.isEmpty || info.owner.localizedCaseInsensitiveContains("WindowManager")
            else { continue }
            // Adopt only what the full scan would also return. The scan is
            // on-screen-only; the describe is not, so adopting an off-screen window
            // here would leave the id lists permanently disagreeing with every
            // subsequent scan — pinning rediscovery at 100 ms for the whole session.
            guard info.onscreen else { unresolved = true; continue }
            switch info.layer {
            case 14 where !barIDs.contains(wid): barIDs.append(wid); adopted = true
            case 15 where !tileIDs.contains(wid): tileIDs.append(wid); adopted = true
            default: break
            }
        }
        if adopted {
            unchangedDiscoveries = 0
            subscribeWindowNotifications()
            sampleNow = true
        }
        // Unresolvable births are the expand case (tiles born at 0x0): keep the
        // rediscovery path armed so they're picked up when their bounds appear.
        if unresolved {
            unchangedDiscoveries = 0
            needsRediscovery = true
        }
        if adopted || unresolved { kickFrame() }
    }

    /// Layer, owner and on-screen flag for specific wids in one call. `nil` value = the
    /// window server has no description for that wid yet.
    private static func describeForDiscovery(_ wids: [CGWindowID])
        -> [CGWindowID: (layer: Int, owner: String, onscreen: Bool)?] {
        var out: [CGWindowID: (layer: Int, owner: String, onscreen: Bool)?] = [:]
        for w in wids { out[w] = .some(nil) }
        var ptrs: [UnsafeRawPointer?] = wids.compactMap { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !ptrs.isEmpty,
              let arr = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil),
              let descs = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return out }
        for d in descs {
            guard let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            out[wid] = .some((layer: (d[kCGWindowLayer as String] as? Int) ?? 0,
                              owner: (d[kCGWindowOwnerName as String] as? String) ?? "",
                              onscreen: (d[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        return out
    }

    /// One frame() per run-loop turn, no matter how many events land in a burst.
    private func kickFrame() {
        sampleNow = true
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framePending = false
            guard self.phase != .closed else { return }
            self.frame(now: CACurrentMediaTime(), dt: 0, stepSprings: false)
        }
    }

    /// (Re)request per-window notifications for the current bar+tile set. Stale wids in
    /// an earlier request are inert, so the fresh list goes out whenever the set changes
    /// (wids are new every Mission Control session).
    ///
    /// Off-main, and that matters: `SLSRequestNotificationsForWindows` is a window-server
    /// round-trip, and the moment it is called is precisely the worst one — adopting the
    /// new tile on a desktop add lands it inside WindowManager's relayout compositing,
    /// where it blocked the main thread for 40–80 ms (measured 2026-09-18: a `frame gap`
    /// immediately after every `births:` line, in stat windows whose slowest frame was
    /// under 3 ms, so the stall was outside frame() entirely). Fire-and-forget on a
    /// serial queue: requests go out in order and a later, fuller list supersedes an
    /// earlier one.
    private func subscribeWindowNotifications() {
        guard eventsArmed else { return }
        let wids = barIDs + tileIDs
        guard !wids.isEmpty else { return }
        slsQueue.async { [weak self] in
            var w = wids
            let t0 = CACurrentMediaTime()
            let ok = sm_slsSubscribeWindowNotifications(&w, Int32(w.count))
            let us = Int((CACurrentMediaTime() - t0) * 1_000_000)
            guard !ok || us >= 5_000 else { return }
            DispatchQueue.main.async {
                self?.dbg("SLS subscribe \(w.count) wids: \(ok ? "ok" : "FAILED") in \(us) µs off-main")
            }
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
            // A drag may follow — wake the frame-rate chase so shifting tiles are
            // followed live instead of at the settled watch's cadence.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .settled else { return }
                self.enterTracking()
            }
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
                // so a click near ANY tile's top-left corner must not launch the exit fade.
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
    /// launch the exit fade the moment one pulls meaningfully downward (see vswipeStep). A
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
            self.close(dismissing: true)
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

    /// Start the labels' exit fade right away (the native exit is an in-place fade that
    /// completes within ~70 ms of the trigger); sampling stays live and either confirms
    /// the close (which finds nothing left to animate) or, if MC didn't actually
    /// dismiss, rebuilds the labels after the suppression window and fades them back in.
    @discardableResult
    private func dismissalInitiated(_ how: String) -> Bool {
        guard phase != .closed else { return false }
        let now = CACurrentMediaTime()
        guard now - dismissalAt > 1.0 else { return false }
        dismissalAt = now
        dbg("dismissal initiated (\(how)) — labels fade out")
        for w in overlays.values { w.exitDismiss() }
        // Don't wait out the window-state confirmation (measured 0.7–1 s, occasionally
        // longer — long enough for the 1 s update-suppression to lapse and REBUILD the
        // labels over an empty desktop, which then die by the old in-place fade). The
        // trigger already said MC is closing: force the close shortly after. If it was a
        // false trigger, the 0.15 s idle probe re-detects MC open and labels re-reveal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.phase != .closed, self.dismissalAt == now else { return }
            self.dbg("dismissal close-confirm timeout — forcing closed")
            self.close(dismissing: true)   // labels already faded; nothing left to animate
        }
        return true
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
        // The element's destruction is the EARLIEST dismissal signal on this OS: measured
        // at +0 ms after the close trigger on 26A5425a, against ~470 ms for the tiles'
        // kCGWindowIsOnscreen flag and ~480 ms for the first SLS event
        // (fix-workspace-lag.md). It used to be gated behind a tiles-still-on-screen
        // check, on the premise that tiles vanish ~30 ms into a real dismissal and stay
        // put through the Dock's in-place re-render. That premise INVERTED: the onscreen
        // flag now outlives the close by half a second, so the check matched at every
        // close and misfiled all of them as re-renders — which is precisely why the
        // labels hung over the restored desktop.
        //
        // So act now and verify after. A re-render leaves a live "mc" element behind; a
        // real close does not, immediately. If one turns up, the dismissal is cancelled
        // and the labels re-reveal before the fade has finished.
        // ...but NOT when a desktop was just added or removed. The Dock destroys and
        // recreates this element on an add/remove while Mission Control stays open, which
        // is indistinguishable from a close at this instant — and acting on it fades the
        // labels out and re-reveals them a few hundred ms later, which is exactly what a
        // desktop add looked like. Discriminator: at a real close the tiles are all still
        // alive and their count has not changed (they die ~470 ms later), whereas an
        // add/remove has just changed it. Three or more tile deaths in half a second means
        // the row is being torn down, so a close is never mistaken for a re-render.
        let now = CACurrentMediaTime()
        tileDeaths.removeAll { now - $0 > 0.5 }
        if tileDeaths.count < 3, now - tileCountChangedAt < 0.8 {
            dbg("mc AX teardown during a relayout — Dock re-render, labels stay put")
            stopAXWatch()
            startAXWatch()          // observe the element the Dock just rebuilt
            return
        }
        stopAXWatch()
        if dismissalInitiated("mc AX teardown") { verifyTeardown(dismissalAt) }
    }

    /// Fresh existence scan for the Dock's "mc" element — the whole child list, not the
    /// element we were observing (that one is destroyed either way). Runs OFF-MAIN: the
    /// tree query can block on a Dock that is mid-teardown.
    private func mcAXElementPresent() -> Bool {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return false }
        return kids.contains { el in
            var idv: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, "AXIdentifier" as CFString, &idv) == .success
                && (idv as? String) == "mc"
        }
    }

    /// Second half of the teardown decision: the labels are already fading, so this only
    /// has to catch the false positive. A live "mc" element this soon after the teardown
    /// means Mission Control never closed (an in-place re-render) — cancel the pending
    /// force-close, drop the update suppression so the labels rebuild, and re-arm.
    private func verifyTeardown(_ firedAt: CFTimeInterval) {
        axQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let present = self.mcAXElementPresent()
            DispatchQueue.main.async { [weak self] in
                guard let self, present, self.phase != .closed,
                      self.dismissalAt == firedAt else { return }
                self.dbg("mc AX element back \(Int((CACurrentMediaTime() - firedAt) * 1000)) ms after teardown"
                    + " — in-place re-render, re-revealing")
                self.dismissalAt = 0
                self.startAXWatch()
                self.kickFrame()
            }
        }
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
    /// The window-list scan itself. PURE and thread-safe (touches no engine state), so it
    /// can run off-main — the scan costs ~7 ms normally and was measured at up to 204 ms
    /// while Mission Control composites, which is a dropped frame every time it lands on
    /// the main thread mid-animation.
    private static func scanWindows() -> (bars: [CGWindowID], tiles: [CGWindowID], sawBar: Bool) {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [], false)
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
        return (bars, tiles, sawBar)
    }

    /// Adopt a scan result. Main thread only.
    @discardableResult
    private func applyScan(_ r: (bars: [CGWindowID], tiles: [CGWindowID], sawBar: Bool)) -> Bool {
        scansApplied += 1
        if r.bars == barIDs && r.tiles == tileIDs {
            unchangedDiscoveries += 1
        } else {
            unchangedDiscoveries = 0
            barIDs = r.bars
            tileIDs = r.tiles
            subscribeWindowNotifications()
            sampleNow = true
        }
        return r.sawBar
    }

    /// Synchronous discovery — kept for the paths that must have an answer right now: the
    /// closed-phase probe (cheap, nothing is compositing) and the dismissal confirm.
    @discardableResult
    private func discover(now: CFTimeInterval) -> Bool {
        lastDiscovery = now
        needsRediscovery = false
        return applyScan(Self.scanWindows())
    }

    /// Background discovery for the open phase, so the scan never blocks a frame. One in
    /// flight at a time; the result is adopted on main.
    private func discoverAsync(now: CFTimeInterval) {
        guard !discoveryInFlight else { return }
        discoveryInFlight = true
        statDiscovers += 1
        lastDiscovery = now
        needsRediscovery = false
        scanQueue.async { [weak self] in
            let r = Self.scanWindows()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.discoveryInFlight = false
                guard self.phase != .closed else { return }
                self.applyScan(r)
                self.kickFrame()
            }
        }
    }

    /// A Mission Control row is ALWAYS evenly spaced. During a desktop add the window
    /// server briefly commits a provisional layout that flings a tile to the far right —
    /// observed live: a target of midX 2055.5 on a 2056 pt display, superseded 93 ms later
    /// by the real 1712.5. WindowManager's own animation ignores that layout, so replaying
    /// it faithfully is what sent the captions sprinting past their thumbnails and back
    /// (the user's frames 5-8). It always leaves a gap far wider than the pitch, which is
    /// something a settled row never has, so reject the layout and wait: a coherent commit
    /// always follows within ~90 ms, and the safety poll is there if one somehow does not.
    ///
    /// Deliberately NOT a model of the row's geometry — it predicts nothing and computes
    /// no positions. It only asks whether what the window server just reported could be a
    /// real row, and the cost of a false reject is one commit's delay.
    /// A real row's gaps are IDENTICAL to within rounding. Measured with MCO_CHAR=1 across
    /// one add and one remove (2026-09-20), every genuine layout read
    /// `[172, 171, 171, 171, 172, 171, 171, 171, 171]` — a spread of 1 pt — while every
    /// straddled sample was wild:
    ///
    ///     [172, 171, 171, 171, 172, 171, 342, 171,  72]     spread 270
    ///     [243,  99, 243, 343, 171,  99,  72, 171, 343]     spread 271
    ///     [171, 171, 172, 171, 171, 171, 171, 172, 343]     spread 172
    ///     [342,   0, 343, 171,   0, 171, 171, 343,   0]     spread 343
    ///     [171, 171, 172, 171, 171, 171, 257,  86, 171, 171] spread 171   <- ACCEPTED before
    ///
    /// The old rule ("no gap wider than 1.8x the median") let that last one through at 1.50,
    /// and a row with a tile 86 pt out of place is a row that never existed on screen: the
    /// labels were mapped onto it and sat 50-80 pt off their thumbnails until a later commit
    /// rescued them. That is the whole of the "still buggy while screen recording" report.
    /// A gap of 0 in there is two tiles reported at the same x — equally impossible.
    ///
    /// So the test is UNIFORMITY, not outlier-hunting. But uniformity of WHAT: the rule was
    /// "every gap within `rowGapTolerance` of every other", and that rejects a second kind
    /// of row it should not — one that is missing a tile.
    ///
    /// **Measured 2026-09-23, from the user's third screen-recording report** ("fails to
    /// finish animations, opening Mission Control and adding/removing workspaces"). Under a
    /// recording every add and remove logged `ignoring a provisional relayout`, one to three
    /// times each, including on commits whose own callbacks had supplied FRESH bounds for
    /// every tracked tile (`commit geometry from 10/10 event callbacks` immediately above
    /// the rejection). A fully-fresh row cannot be straddled — so the gap was not stale
    /// geometry, it was a tile MISSING from the sample: on an add the eleventh tile exists
    /// on screen but has not been adopted yet (it is adopted ~170 ms later, where the log
    /// then says `desktop added`), so our row of ten has a hole exactly one pitch wide.
    ///
    /// A hole leaves gaps that are integer MULTIPLES of the pitch; a straddled sample leaves
    /// fractions of it. That is the discriminator, and it separates every row shape ever
    /// recorded here (the table above, all of which stay rejected, plus the hole row which
    /// no longer is). So: take the pitch from the median gap and require every gap to be a
    /// near-integer multiple of it, 1x to 4x.
    ///
    /// This matters because a refused row does not merely delay a retarget — `mustMap` is
    /// false for that whole frame, so the labels are not told anything at all, and they
    /// coast to wherever the PREVIOUS layout put them and stop there. Refusing one to three
    /// commits of a 0.42 s native animation is exactly "the animation doesn't finish": the
    /// captions land short, pause, and only catch up when a commit finally passes. The cost
    /// of a false reject was never "one commit's delay" while a recording stretches the gap
    /// between commits to ~1 s.
    static func rowIsCoherent(_ midXs: [CGFloat]) -> Bool {
        guard midXs.count >= 4 else { return true }
        let xs = midXs.sorted()
        var gaps: [CGFloat] = []
        for i in 1..<xs.count { gaps.append(xs[i] - xs[i - 1]) }
        let sorted = gaps.sorted()
        let pitch = sorted[sorted.count / 2]
        // Every tile reported at the same x: degenerate rather than wrong, and judged
        // elsewhere. A row with SOME zero gaps is two tiles at one position — impossible.
        guard pitch > 1 else { return sorted.last! <= 1 }
        for g in gaps {
            let k = (g / pitch).rounded()
            guard k >= 1, k <= 4, abs(g - k * pitch) <= rowGapTolerance else { return false }
        }
        return true
    }

    /// How far a Mission Control row's tile gaps may differ from one another and still be a
    /// real layout. Measured spread of a genuine row is 1 pt (rounding); the smallest
    /// straddled row observed is out by 86 pt. 8 pt sits far from both.
    static let rowGapTolerance: CGFloat = 8

    /// Which screen's bar a sampled tile belongs to, as an index into `frames`
    /// (nil when no screen shares its row).
    ///
    /// NOT "the screen whose frame contains the tile's centre". When Mission Control opens
    /// with the cursor right of centre, the spaces bar opens with its row shifted the
    /// other way, and with enough desktops the far tile sits partly or wholly past the
    /// screen edge — its centre is on no screen at all. The old containment test dropped
    /// that tile, and the positional pairing in mapLabels then shifted every label one
    /// space over ("Home" over Desktop 2, 2026-09-23) until a mouse move slid the row
    /// back and the counts agreed again. The window server still lists and samples a
    /// tile pushed off the edge (verified: a window at x=-5000 is in the on-screen list
    /// with kCGWindowIsOnscreen set), so nothing is missing but the grouping. A tile is
    /// its row's wherever it slides, so one whose centre no screen contains goes to the
    /// nearest screen that shares its vertical band; the overlay window is screen-sized,
    /// so its label is simply clipped until the row scrolls it into view.
    ///
    /// Known limit: side-by-side displays whose bars share a band cannot be told apart by
    /// geometry, so a tile scrolled off one display INTO its neighbour is grouped with the
    /// neighbour — the same as before this rule; both displays then read as mismatched.
    static func screenIndex(forTile r: NSRect, frames: [NSRect]) -> Int? {
        let c = NSPoint(x: r.midX, y: r.midY)
        if let i = frames.firstIndex(where: { $0.contains(c) }) { return i }
        var best: (index: Int, distance: CGFloat)?
        for (i, f) in frames.enumerated() where c.y >= f.minY && c.y < f.maxY {
            let d = c.x < f.minX ? f.minX - c.x : (c.x > f.maxX ? c.x - f.maxX : 0)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// The sampled tiles grouped per screen (parallel to `NSScreen.screens`), each group
    /// in x order. See `screenIndex(forTile:frames:)` for why a tile past the screen edge
    /// still belongs to its row.
    static func tilesByScreen(_ tiles: [(wid: CGWindowID, rect: NSRect)], frames: [NSRect])
        -> [[(wid: CGWindowID, rect: NSRect)]] {
        var out = [[(wid: CGWindowID, rect: NSRect)]](repeating: [], count: frames.count)
        for t in tiles {
            if let i = screenIndex(forTile: t.rect, frames: frames) { out[i].append(t) }
        }
        for i in out.indices { out[i].sort { $0.rect.minX < $1.rect.minX } }
        return out
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
        // Replay spring: τ=0.12 reproduces the measured native relayout glide
        // (CASpringAnimation mass 1, stiffness 278, damping 33.3 — critically damped,
        // ω≈16.7/s): a 765 pt hop from rest lands within ~4 pt at the measured 459 ms
        // settle point (fix-workspace-lag.md).
        var rpos: CGFloat = 765, rvel: CGFloat = 0
        for _ in 0..<55 {   // 55 × 1/120 s ≈ 458 ms
            (rpos, rvel) = OverlayWindow.springStep(pos: rpos, vel: rvel, target: 0, tau: 0.12, dt: 1.0 / 120)
        }
        check(abs(rpos) < 4.5, "native curve: 765 pt lands within ~4 pt at the OS settle time")
        // Adding a desktop — and ONLY that — runs a stiffer curve (see `addOmega`): same
        // critically damped shape, ~1.5x faster, so the labels spend the glide catching up
        // the start-up latency instead of carrying it to the end. Every other relayout,
        // the remove included, stays on the native curve checked just above.
        var fpos: CGFloat = 765, fvel: CGFloat = 0
        var fovershot = false
        for _ in 0..<36 {   // 36 x 1/120 s = 300 ms
            (fpos, fvel) = OverlayWindow.springStep(pos: fpos, vel: fvel, target: 0,
                                                    tau: 2 / 25, dt: 1.0 / 120)
            if fpos < -0.001 { fovershot = true }
        }
        check(abs(fpos) < 5, "add-boost curve: 765 pt is home in 300 ms")
        check(!fovershot, "add-boost curve: still critically damped — no overshoot")
        // Provisional-layout rejection. A settled Mission Control row is evenly spaced;
        // during an add the window server briefly commits one with a tile flung to the far
        // right, which is what made the captions overshoot their thumbnails and come back.
        check(rowIsCoherent([100, 260, 420, 580, 740]), "row: even spacing accepted")
        check(rowIsCoherent([100, 262, 419, 581, 738]), "row: jitter still accepted")
        check(!rowIsCoherent([100, 260, 420, 580, 1100]),
              "row: a tile flung past the row is rejected")
        // Straight from MCO_CHAR=1 during a real remove: gaps 171,171,172,171,171,171,257,86,171,171.
        // The old 1.8x-of-median rule scored this 1.50 and ACCEPTED it, which is how labels
        // ended up 50-80 pt off their thumbnails.
        check(!rowIsCoherent([0, 171, 342, 514, 685, 856, 1027, 1284, 1370, 1541, 1712]),
              "row: a straddled sample with one tile 86 pt out of place is rejected")
        // A whole row shifted by the same amount is still a real row — uniformity, not position.
        check(rowIsCoherent([600, 771, 942, 1113, 1284]), "row: a uniformly shifted row is accepted")
        check(rowIsCoherent([100, 900]), "row: too few tiles to judge — accepted")
        check(rowIsCoherent([]), "row: empty — accepted")
        check(rowIsCoherent([500, 500, 500, 500]), "row: degenerate — accepted")
        // A tile MISSING from the sample (an add's new tile before it is adopted) leaves one
        // gap of exactly two pitches and nothing else wrong. That is a real row, and
        // refusing it is what stopped the labels part-way through add/remove animations
        // under a screen recording (2026-09-23). Gaps 171 x8 then 343.
        check(rowIsCoherent([0, 171, 342, 514, 685, 856, 1027, 1198, 1369, 1712]),
              "row: a real row with one tile missing from the sample is accepted")
        check(rowIsCoherent([0, 171, 342, 855, 1026, 1197, 1368, 1539]),
              "row: two adjacent tiles missing is still accepted")
        // ...but a hole does NOT excuse a fractional gap elsewhere: same row, one tile also
        // 86 pt out of place (the straddled shape change 7 was built to reject).
        check(!rowIsCoherent([0, 171, 342, 514, 685, 856, 1027, 1113, 1370, 1713]),
              "row: a hole plus a half-pitch outlier is still rejected")
        // Two tiles reported at the same x, mixed with real gaps — impossible, still rejected.
        check(!rowIsCoherent([0, 0, 171, 342, 342, 513, 684, 855]),
              "row: duplicate positions rejected")
        // Tile -> screen grouping. A bar that opened scrolled pushes its far tile past the
        // screen edge; that tile is still the row's, or every label lands one space over.
        let one = [NSRect(x: 0, y: 0, width: 2056, height: 1329)]
        check(screenIndex(forTile: NSRect(x: 64, y: 65, width: 159, height: 121), frames: one) == 0,
              "tile group: a tile inside the screen is the screen's")
        check(screenIndex(forTile: NSRect(x: -120, y: 65, width: 159, height: 121), frames: one) == 0,
              "tile group: a tile mostly past the left edge (centre off-screen) still counts")
        check(screenIndex(forTile: NSRect(x: -400, y: 65, width: 159, height: 121), frames: one) == 0,
              "tile group: a tile wholly past the left edge still counts")
        check(screenIndex(forTile: NSRect(x: 2100, y: 65, width: 159, height: 121), frames: one) == 0,
              "tile group: a tile wholly past the right edge still counts")
        check(screenIndex(forTile: NSRect(x: 64, y: 2000, width: 159, height: 121), frames: one) == nil,
              "tile group: a tile outside every row belongs to no screen")
        let two = [NSRect(x: 0, y: 0, width: 2056, height: 1329),
                   NSRect(x: 2056, y: 0, width: 1920, height: 1080)]
        check(screenIndex(forTile: NSRect(x: 2100, y: 900, width: 159, height: 121), frames: two) == 1,
              "tile group: two displays — a tile inside the second is the second's")
        check(screenIndex(forTile: NSRect(x: 4000, y: 900, width: 159, height: 121), frames: two) == 1,
              "tile group: two displays — past the far right edge goes to the nearest row")
        check(screenIndex(forTile: NSRect(x: -400, y: 1200, width: 159, height: 121), frames: two) == 0,
              "tile group: two displays — a band only the first display has stays with it")
        let scrolled: [(wid: CGWindowID, rect: NSRect)] = [
            (3, NSRect(x: 258, y: 65, width: 159, height: 121)),
            (1, NSRect(x: -64, y: 65, width: 159, height: 121)),
            (2, NSRect(x: 97, y: 65, width: 159, height: 121))]
        let rows = tilesByScreen(scrolled, frames: one)
        check(rows.count == 1 && rows[0].map(\.wid) == [1, 2, 3],
              "tile group: a scrolled row keeps its off-edge tile, in x order")
        // Label centre <-> layer position. These two spaces differ by half the label
        // (an AppKit layer-backed view anchors at its frame origin), and confusing them
        // put the caption half a label off whenever a glide handed back to the spring.
        let sz = NSSize(width: 120, height: 20)
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5)] {
            let centre = CGPoint(x: 600, y: 120)
            let lp = OverlayWindow.layerPos(center: centre, size: sz, anchor: anchor)
            let back = OverlayWindow.center(layerPos: lp, size: sz, anchor: anchor)
            check(abs(back.x - centre.x) < 0.001 && abs(back.y - centre.y) < 0.001,
                  "layer/centre round-trip at anchor \(anchor.x),\(anchor.y)")
        }
        let originAnchor = CGPoint(x: 0, y: 0)
        let lp0 = OverlayWindow.layerPos(center: CGPoint(x: 600, y: 120), size: sz, anchor: originAnchor)
        check(abs(lp0.x - 540) < 0.001 && abs(lp0.y - 110) < 0.001,
              "layerPos: origin-anchored layer sits at the label's bottom-left")
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
    /// zero means Mission Control itself is going (exit fade); non-zero with `bars` empty means
    /// the bar merely collapsed/left its band (fade). Judged from live sampling, never from
    /// the discovery ID cache, which can lag the screen by a scan.
    private typealias Sample = (bars: [NSRect], tiles: [(wid: CGWindowID, rect: NSRect)],
                                missing: Bool, barsOnScreen: Int)

    /// The window-server round-trips themselves, one per tracked window. PURE (touches no
    /// engine state) so it can run on `sampleQueue`. `missingWids` are the tracked wids
    /// the server had nothing for — reported by id so the main thread can discount any
    /// that an 804 pruned while the round-trip was out.
    private static func sampleWindows(bars barIDs: [CGWindowID], tiles tileIDs: [CGWindowID],
                                      useSLS: Bool, primaryH: CGFloat)
        -> (sample: Sample, missingWids: [CGWindowID]) {
        func toNS(_ cg: CGRect) -> NSRect {
            NSRect(x: cg.minX, y: primaryH - cg.minY - cg.height, width: cg.width, height: cg.height)
        }
        var bars: [NSRect] = []
        var tiles: [(wid: CGWindowID, rect: NSRect)] = []
        var missingWids: [CGWindowID] = []
        var barsOnScreen = 0
        if useSLS {
            for wid in barIDs {
                var r = CGRect.zero
                if sm_getWindowBounds(wid, &r) {
                    barsOnScreen += 1
                    if Self.barBand(r.size) { bars.append(toNS(r)) }
                } else { missingWids.append(wid) }
            }
            for wid in tileIDs {
                var r = CGRect.zero
                if sm_getWindowBounds(wid, &r) {
                    if Self.tileBand(r.size) { tiles.append((wid, toNS(r))) }
                } else { missingWids.append(wid) }
            }
        } else {
            // kCGWindowIsOnscreen is deliberately IGNORED here so that this path and the
            // per-window one differ only in HOW the bounds are fetched, never in what a
            // sample MEANS — `atomic` now picks between them by server load, and a sample
            // must not change meaning with it. The flag used to gate both loops, back when
            // it led a dismissal by ~30 ms; on 26A5425a it does the opposite and outlives
            // the close by ~470 ms (see `useSLS`). Left in, it would quietly change what
            // `barsOnScreen == 0` decides — whether the labels fly out or merely fade.
            // Existence of a description is the same test the per-window path applies (a
            // successful bounds query), so the two agree.
            let map = Self.describeWindows(barIDs + tileIDs)
            for wid in barIDs {
                if let (r, _) = map[wid] {
                    barsOnScreen += 1
                    if Self.barBand(r.size) { bars.append(toNS(r)) }
                } else { missingWids.append(wid) }
            }
            for wid in tileIDs {
                if let (r, _) = map[wid] {
                    if Self.tileBand(r.size) { tiles.append((wid, toNS(r))) }
                } else { missingWids.append(wid) }
            }
        }
        // Deterministic order: discovery returns z-order, which can shuffle between scans;
        // the stability comparison and tile→ordinal mapping both need positional order.
        tiles.sort { $0.rect.minX < $1.rect.minX }
        return ((bars, tiles, !missingWids.isEmpty, barsOnScreen), missingWids)
    }

    /// Ask for fresh geometry. Off-main by default (see `sampleQueue`): the round-trip
    /// runs on the sampler queue and `applySample` retargets on main the moment it
    /// returns, so a blocked round-trip costs the labels nothing but the wait for the new
    /// targets — the springs keep stepping meanwhile. One round-trip in flight at a
    /// time; an `urgent` demand (a commit) that lands mid-flight queues exactly one more,
    /// a steady one (drag / poll) is simply absorbed. `replay` is the commit's replay
    /// marking, carried to the frame that applies the answer.
    /// `atomic`: fetch this one sample with a single description call instead of a query
    /// per window. Used ONLY when the window server has just proved itself slow — the
    /// commit callback's own bounds read blew its 2 ms cap — because that is the one
    /// moment the difference is worth having (80-280 ms of serial waits against 20-57 ms
    /// for one, measured under a screen recording). When the server is fast the per-window
    /// path is ~80x cheaper and nothing here fires. See `useSLS` for the numbers.
    private func requestSample(now: CFTimeInterval, urgent: Bool, replay: Bool,
                               replayAt: CFTimeInterval = 0, atomic: Bool = false) {
        guard asyncSampling else {
            // A/B path (MCO_SYNC_SAMPLE=1): block this frame, as the engine always did.
            let t0 = CACurrentMediaTime()
            let r = Self.sampleWindows(bars: barIDs, tiles: tileIDs, useSLS: useSLS, primaryH: primaryH)
            noteSample(r, now: now, roundTripUs: Int((CACurrentMediaTime() - t0) * 1_000_000), latencyUs: 0)
            return
        }
        if sampleInFlight {
            if urgent {
                sampleWanted = true
                wantedAtomic = wantedAtomic || atomic
                if replay { wantedReplay = true; wantedReplayAt = replayAt }
            }
            return
        }
        sampleInFlight = true
        let gen = sessionGen, bars = barIDs, tiles = tileIDs, ph = primaryH
        let sls = useSLS && !atomic
        if atomic { dbg("window server is slow — answering this commit with one call for all"
                        + " \(bars.count + tiles.count) windows instead of a query each") }
        sampleQueue.async { [weak self] in
            let t0 = CACurrentMediaTime()
            let r = Self.sampleWindows(bars: bars, tiles: tiles, useSLS: sls, primaryH: ph)
            let us = Int((CACurrentMediaTime() - t0) * 1_000_000)
            DispatchQueue.main.async { [weak self] in
                self?.applySample(r, gen: gen, requestedAt: now, roundTripUs: us,
                                  replay: replay, replayAt: replayAt)
            }
        }
    }

    /// Main thread: a round-trip came back. Adopt it, issue the follow-up a mid-flight
    /// commit asked for, and retarget NOW rather than on the next link tick.
    private func applySample(_ r: (sample: Sample, missingWids: [CGWindowID]), gen: Int,
                             requestedAt: CFTimeInterval, roundTripUs: Int, replay: Bool,
                             replayAt: CFTimeInterval) {
        guard gen == sessionGen else { return }   // a dead session's round-trip
        sampleInFlight = false
        guard phase != .closed else { return }
        let now = CACurrentMediaTime()
        noteSample(r, now: now, roundTripUs: roundTripUs,
                   latencyUs: Int((now - requestedAt) * 1_000_000))
        if sampleWanted {
            sampleWanted = false
            let again = wantedReplay
            let againAt = wantedReplayAt
            let againAtomic = wantedAtomic
            wantedReplay = false; wantedReplayAt = 0; wantedAtomic = false
            requestSample(now: now, urgent: true, replay: again, replayAt: againAt,
                          atomic: againAtomic)
        }
        appliedReplay = replay
        appliedReplayAt = replayAt
        frame(now: now, dt: 0, stepSprings: false, retargetOnly: true)
    }

    /// Adopt a sample as the current geometry. A wid the event path pruned (804) while
    /// the round-trip was out is not `missing` — it is simply gone.
    private func noteSample(_ r: (sample: Sample, missingWids: [CGWindowID]), now: CFTimeInterval,
                            roundTripUs: Int, latencyUs: Int) {
        var s = r.sample
        let tracked = Set(barIDs + tileIDs)
        s.missing = r.missingWids.contains { tracked.contains($0) }
        s.tiles.removeAll { !tracked.contains($0.wid) }
        lastSampleResult = s
        haveSample = true
        lastSample = now
        samplesApplied += 1
        statSamples += 1
        statSampleMaxUs = max(statSampleMaxUs, roundTripUs)
        statSampleLatMaxUs = max(statSampleLatMaxUs, latencyUs)
        if debugLog, roundTripUs >= 2_000 || latencyUs >= 8_000 {
            dbg("sample: \(s.bars.count) bars \(s.tiles.count) tiles, round-trip \(roundTripUs) µs"
                + (asyncSampling ? " off-main, applied \(latencyUs / 1000) ms after request"
                                 : " ON MAIN (MCO_SYNC_SAMPLE)"))
        }
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

    // MARK: - Per-frame drive

    @objc private func frameTick(_ link: CADisplayLink) { driveFrame() }

    /// One animation frame, from whichever driver reached it first — the display link, or
    /// the tracking backstop timer when the link has stalled for `minInterval`.
    private func driveFrame(minInterval: CFTimeInterval = 0) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= minInterval else { return }
        // REAL elapsed time, not a per-frame budget. The springs replay the native curve
        // against the same wall clock the tiles animate on, and springStep is the exact
        // closed-form solution of a critically damped spring — so a big dt lands exactly
        // where the curve is now, and can never overshoot. Clamping it (this was 1/30)
        // instead made a stalled frame advance the label by only 33 ms of curve, and the
        // sampler DOES stall: sm_getWindowBounds blocks while WindowManager composites,
        // measured up to 233 ms on an add/remove relayout. Every stall then leaked
        // simulated time and the captions ran in slow motion, trailing the tiles by up to
        // two seconds on an add or remove. The cap is only a sanity bound — anything past
        // it (app suspended, display sleep) should snap to the settled layout anyway.
        let dt = min(max(now - lastFrame, 0), 0.5)
        lastFrame = now
        // Neither the link nor the 60 Hz backstop got a frame in for ≥40 ms: the main
        // thread was blocked, and the labels stood still for exactly this long.
        if debugLog, dt >= 0.04 { dbg("frame gap \(Int(dt * 1000)) ms") }
        frame(now: now, dt: dt, stepSprings: true)
    }

    /// `retargetOnly`: this frame applies inputs that just arrived (a sample, a space
    /// list) and must not START anything — no steady-state sample request, so a drag keeps
    /// sampling at the link's rate rather than chaining at the round-trip's.
    private func frame(now: CFTimeInterval, dt: CFTimeInterval, stepSprings: Bool,
                       retargetOnly: Bool = false) {
        guard phase != .closed else { return }
        let t0 = CACurrentMediaTime()

        if needsRediscovery || now - lastDiscovery >= safetyRescanInterval {
            if now - lastDiscovery >= effectiveRediscoveryInterval { discoverAsync(now: now) }
        }
        // Sampling is one synchronous window-server round-trip per tracked window, and
        // they BLOCK while WindowManager composites — i.e. during exactly the animations
        // the labels ride (54% of the tracking frame in the profile). Geometry only
        // changes at layout commits, which push to us as 806/807 and force a sample via
        // `sampleNow`. So poll at frame rate ONLY where no event is coming: a drag in
        // progress (measured: emits no reliable commits) or a bar still materialising its
        // tiles. Otherwise a slow safety cadence is enough and the frames in between are
        // pure spring stepping.
        // The glide used to suppress the steady poll entirely, on two premises that have
        // both since been falsified, so it no longer does (MCO_NO_GLIDE_POLL=1 restores it):
        //
        //  1. "While the captions are mid-flight there is nothing to poll FOR — the sampled
        //     tiles already sit at their final rects." Not when the layout we are gliding
        //     TO gets superseded, which is exactly what an add or a remove does (section 6:
        //     the window server commits a provisional layout and replaces it ~90 ms later,
        //     and under a screen recording ~1 s later). With the poll suppressed we could
        //     not notice until the glide ENDED, so the labels sat 50-80 pt off their
        //     thumbnails for the whole glide and only snapped into place afterwards —
        //     measured off the 11:27 recording, and the whole of what "still buggy while
        //     screen recording" looks like.
        //  2. "Polling anyway blocks the main thread for as long as WindowManager needs to
        //     composite the relayout — measured 130 ms, and 567 ms in one add." That was
        //     the SYNCHRONOUS sampler. Sampling has run off-main since this work began: a
        //     poll now costs a request on the sampler queue, the springs keep stepping
        //     while it is out, and `requestSample` coalesces so at most one is ever in
        //     flight.
        //
        // A poll that comes back with different rects retargets mid-flight, which is a
        // re-aim on the render server rather than a restart (see OverlayWindow.update).
        // `needsRediscovery` deliberately does NOT force a sample: discovery runs off-main
        // and republishes `sampleNow` itself if the scan actually changed the wid set, so
        // keeping it here only meant a permanent tile/space disagreement (exactly what an
        // add or remove creates) pinned the blocking sampler at frame rate.
        let gliding = springsFlying && wasTilesStill
        let demand = sampleNow
        sampleNow = false
        let steady = !retargetOnly && (mouseHeld.get() || awaitingTiles
            || ((!gliding || Self.pollWhileGliding) && now - lastSample >= samplePollInterval))
        // Bounds the commit's own callbacks already read (see `eventBounds`).
        let eventTiles = eventBounds
        eventBounds.removeAll()
        let budgetHit = eventBudgetHit
        let spent = eventBoundsSpent
        eventBudgetHit = false
        var replay = false
        var replayAt: CFTimeInterval = 0
        if asyncSampling {
            // The replay marking travels WITH the geometry that answers the commit. When
            // the callbacks supplied it, that is THIS frame and the glide starts now; the
            // sample still goes out, but only to confirm. Otherwise the marking rides the
            // request and comes back with the answer (`appliedReplay`) — consuming it on
            // the frame that merely issued the request would spend it on stale targets.
            if demand {
                if !eventTiles.isEmpty, replayCommit {
                    // The callbacks already supplied geometry, and the burst already asked
                    // the sampler for whatever they could not cover (see handleSLSEvent),
                    // carrying this commit's marking with it. So glide now and queue
                    // nothing: a second request here would only duplicate that one.
                    replay = true
                    replayAt = lastCommitAt
                } else {
                    // NB: deliberately NOT gated on `burstSampleAsked`. That flag scopes a
                    // request to its own commit burst and is only cleared when the NEXT
                    // burst starts, so testing it here silently swallowed every unrelated
                    // demand in between — including the one raised when tiles are adopted
                    // at open. The labels then had no geometry and stayed invisible until
                    // some interaction produced a fresh burst. requestSample already
                    // coalesces, so a duplicate costs at most one round-trip.
                    requestSample(now: now, urgent: true, replay: replayCommit, replayAt: lastCommitAt)
                }
                replayCommit = false
            } else if steady || (!haveSample && !sampleInFlight) {
                requestSample(now: now, urgent: false, replay: false)
            }
            if !replay { replay = appliedReplay; replayAt = appliedReplayAt }
            appliedReplay = false
        } else {
            if demand || steady || !haveSample { requestSample(now: now, urgent: demand, replay: false) }
            replay = replayCommit
            replayAt = lastCommitAt
            replayCommit = false
        }
        // Nothing to act on until the session's first round-trip returns — the empty
        // placeholder must not read as "bar gone".
        guard haveSample else { return }
        var s = lastSampleResult
        if !eventTiles.isEmpty {
            // ALL OR NOTHING. Applying only the tiles the callbacks reached would leave the
            // rest of the row at the positions of the PREVIOUS layout, and a row that is
            // half new and half old is not a layout that was ever on screen — it is a
            // straddle, and one we manufacture ourselves rather than one the window server
            // handed us. `rowIsCoherent` then refuses it (correctly), `mustMap` goes false,
            // and the labels are told nothing at all for that frame. Measured in the user's
            // 2026-09-23 09:53 session: of four refused relayouts, THREE came from partial
            // merges — `3/10`, `1/10` and `10/11` coverage produced
            // `[171, 343, 87, 84, 342, 88, 83, 172, 430]`, `[171, 0, 343, …]` and
            // `[171 x9, 85]`, all impossible rows. The half-pitch and zero gaps are the
            // signature: two layouts interleaved.
            //
            // Discarding costs nothing, because the burst that delivered these callbacks
            // ALSO asked the sampler for the whole row, carrying this commit's replay
            // marking (see handleSLSEvent) and using the single-call `atomic` path when the
            // server has just proved itself slow. That answer is internally consistent and
            // landed 15-20 ms later in the same session. So the choice is not "fresh partial
            // now vs complete later", it is "an impossible row now, which gets refused
            // anyway, vs a real one in 15 ms".
            //
            // Complete coverage is the norm whenever the window server is healthy — every
            // relayout in a normal session logs `10/10` — so this cannot fire outside the
            // regime it was written for.
            let covered = s.tiles.reduce(into: 0) { n, t in if eventTiles[t.wid] != nil { n += 1 } }
            if covered == s.tiles.count, covered > 0 {
                for i in s.tiles.indices { s.tiles[i].rect = eventTiles[s.tiles[i].wid]! }
                s.tiles.sort { $0.rect.minX < $1.rect.minX }
                lastSampleResult = s
                if debugLog, replay {
                    dbg("commit geometry from \(covered)/\(s.tiles.count) event callbacks"
                        + " in \(Int(spent * 1_000_000)) µs — no round-trip wait")
                }
            } else if debugLog, replay, covered > 0 {
                dbg("commit geometry from only \(covered)/\(s.tiles.count) event callbacks"
                    + " in \(Int(spent * 1_000_000)) µs\(budgetHit ? " (budget)" : "")"
                    + " — DISCARDED, waiting for the sampler's whole-row answer")
            }
        }
        // Dismissal shows up as windows dying or leaving the on-screen list. Both now lag
        // the visible exit by ~0.5 s (the onscreen flag no longer leads it — see `useSLS`),
        // so this is the BACKSTOP; the AX teardown at +0 ms is the real exit trigger.
        // Confirm any of these with a fresh scan and sample before concluding anything —
        // ordered here, judged when they land (see `confirmAtScan`). The discovery's
        // completion republishes `sampleNow`, so the sample always follows the scan.
        if s.missing || s.bars.isEmpty || (s.tiles.isEmpty && !lastTileRects.isEmpty) {
            if confirmAtScan < 0 {
                confirmAtScan = scansApplied
                confirmAtSample = samplesApplied
                needsRediscovery = true
                discoverAsync(now: now)
            }
        } else {
            confirmAtScan = -1
        }
        let confirmed = confirmAtScan >= 0
            && scansApplied > confirmAtScan && samplesApplied > confirmAtSample
        if confirmed { confirmAtScan = -1 }
        let t1 = CACurrentMediaTime()
        if s.bars.isEmpty {
            // No bar windows on screen at all => Mission Control itself is dismissing and
            // the tiles are flying up — ride with them. A bar window that's still on screen
            // but collapsed/out of band is not a dismissal — plain fade.
            // Hold the verdict until the confirm cycle agrees the bar is really gone; the
            // 0.5 s bound keeps a confirm that never lands from pinning the session open.
            if barsGoneSince == 0 { barsGoneSince = now }
            if confirmed || now - barsGoneSince >= 0.5 {
                close(dismissing: s.barsOnScreen == 0)
            }
            return
        }
        barsGoneSince = 0
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
        let rectsChanged = !tilesStill || s.bars != lastBarRects
        if s.tiles.count != lastTileCount {
            // Exactly one MORE tile than before, and we were already showing some: a
            // desktop was added. Not the expand (0 -> N), not a remove, not the "+" peek
            // (which resizes tiles without creating one).
            if lastTileCount > 0, s.tiles.count == lastTileCount + 1 {
                addBoostUntil = now + 0.8
                dbg("desktop added — labels take the faster curve for this relayout")
            }
            lastTileCount = s.tiles.count
            tileCountChangedAt = now
        }
        let addBoost = now < addBoostUntil
        let boostJustStarted = addBoost && !wasAddBoosting
        wasAddBoosting = addBoost
        lastTileRects = s.tiles.map(\.rect)
        lastBarRects = s.bars

        // This frame applies an 806/807 commit's sample: the targets are the FINAL bounds
        // of a native relayout whose visible glide is just starting — retarget with the
        // matched replay spring so the labels play the same curve from the same instant.
        // Is this a layout worth replaying, or the window server's provisional one?
        var provisional = false
        var rejectedRow: [CGFloat] = []
        if replay {
            // Same per-row grouping as the mapper, so a tile scrolled past the screen edge
            // is judged with its row rather than vanishing from it.
            for row in Self.tilesByScreen(s.tiles, frames: NSScreen.screens.map(\.frame)) {
                let xs = row.map(\.rect.midX)
                if !Self.rowIsCoherent(xs) { provisional = true; rejectedRow = xs; break }
            }
        }
        if provisional {
            if provisionalSince == 0 { provisionalSince = now }
            // Remember when the OS began this relayout. Its tiles started moving at the
            // PROVISIONAL commit even though it would not tell us where to until the
            // corrected one ~90 ms later, so that first commit is the clock the labels
            // must be measured against. Without this the labels enter the curve ~90 ms
            // late and stay exactly that far behind for the rest of the glide.
            if provisionalCommitAt == 0 { provisionalCommitAt = replayAt > 0 ? replayAt : now }
            if now - provisionalSince >= 0.3 {
                provisional = false          // give up refusing; something is unusual
                provisionalSince = 0
                dbg("provisional layouts persisted — accepting one rather than stalling")
            } else {
                // Log the refused SHAPE, not just the fact: half-pitch gaps mean a row
                // built from two layouts (the 2026-09-23 partial-callback bug), while
                // integer multiples of the pitch mean a tile is merely missing.
                let xs = rejectedRow.sorted()
                var gaps: [Int] = []
                for i in 1..<max(xs.count, 1) where xs.count >= 2 {
                    gaps.append(Int((xs[i] - xs[i - 1]).rounded()))
                }
                dbg("ignoring a provisional relayout — the row is not evenly spaced:"
                    + " \(xs.count) tiles, gaps \(gaps)")
            }
        } else {
            provisionalSince = 0
            if replay, provisionalCommitAt > 0 {
                replayAt = provisionalCommitAt
                provisionalCommitAt = 0
            }
        }

        // How far into the native glide the tiles already are. Everything between the
        // window server's commit and this frame — the event hop, the sample round-trip,
        // a blocked main thread, and any provisional layout we refused — is time the tiles
        // have been moving and the labels have not, so the replay is entered at that phase
        // instead of from the start.
        let commitAge = replay && replayAt > 0 ? min(max(now - replayAt, 0), 0.3) : 0
        if replay { dbg("replay commit — retargeting on the native curve, \(Int(commitAge * 1000)) ms in") }

        var anyMoving = false
        // After an input-side dismissal the labels have already flown; don't rebuild them
        // while the (slow) window-state close confirmation is pending. If MC turns out to
        // still be open once the window lapses, updates resume and labels re-reveal.
        let suppressed = now - dismissalAt < 1.0
        // Mapping walks every space, resolves its content and diffs the label set. Between
        // layout commits NONE of its inputs move — targets snap once per commit and the
        // glide in between is played by the springs alone — so re-deriving it every frame
        // was pure waste. Re-map only when something it reads actually changed; otherwise
        // this frame is just a spring step.
        let mustMap = !provisional
            && (rectsChanged || replay || boostJustStarted || suppressed != wasSuppressed
            || contentGen != mappedContentGen || cachedSpaces != spaces.spaces
            || tilesStill != wasTilesStill || !mappedOnce
            || overlays.values.contains { $0.isVisible && !$0.hasRevealed })
        wasSuppressed = suppressed
        wasTilesStill = tilesStill
        if !suppressed, mustMap {
            mappedOnce = true
            mappedContentGen = contentGen
            lastByScreen = mapLabels(bars: s.bars, tiles: s.tiles, now: now, tilesAtRest: tilesStill)
        }
        if !suppressed {
            var active = Set<CGDirectDisplayID>()
            for (screen, labels, complete) in lastByScreen {
                guard let did = screen.displayID else { continue }
                active.insert(did)
                let w = overlay(for: screen, did: did)
                if !w.isVisible {
                    w.orderFrontRegardless()
                    // Park on a private sticky space so the labels hold still through a
                    // managed-space slide (see MCLabelStickySpace) instead of riding it.
                    MCLabelStickySpace.park(w)
                }
                if mustMap {
                    let o = screen.frame.origin
                    w.update(labels: labels.map {
                        BarLabel(id: $0.id, center: NSPoint(x: $0.center.x - o.x, y: $0.center.y - o.y),
                                 name: $0.name, icon: $0.icon, contentKey: $0.contentKey,
                                 placeholderWidth: $0.placeholderWidth)
                    }, now: now, replay: replay, nativeReveal: complete && eventsArmed,
                       commitAge: commitAge, addBoost: addBoost, reglide: boostJustStarted,
                       dragging: mouseHeld.get())
                }
                if stepSprings {
                    if w.step(dt: dt, now: now) { anyMoving = true }
                } else if w.needsMotion {
                    anyMoving = true
                }
                // While anything is in flight, commit a heartbeat so the window server
                // re-rasterises this window — under Mission Control it does not do so on
                // its own for a render-server animation, and a screen recording shows the
                // stale image (see OverlayWindow.heartbeat).
                if w.heartbeat(now: now) { anyMoving = true }
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
        springsFlying = anyMoving
        if phase == .tracking {
            // Never settle while the left button is down: a tile reorder or window drag
            // moves the bar's geometry continuously without reliable commit events (the
            // tile shift under a window drag trailed by half a tile in the 2026-08-14
            // recording once the engine had settled) — keep chasing at frame rate.
            stableFrames = tilesStill && !anyMoving && !mouseHeld.get() ? stableFrames + 1 : 0
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
                    + " discovers=\(statDiscovers) refreshes=\(statRefreshes)"
                    + " samples=\(statSamples) rtMax=\(statSampleMaxUs)µs latMax=\(statSampleLatMaxUs)µs phase=\(phase)")
                statN = 0; statSum = 0; statMin = .infinity; statMax = 0
                statSampleSum = 0; statApplySum = 0; statDiscovers = 0; statRefreshes = 0
                statSamples = 0; statSampleMaxUs = 0; statSampleLatMaxUs = 0
            }
            if charMode {
                logLine("char t=\(now) tiles=\(s.tiles.map { (Int($0.rect.minX), Int($0.rect.width)) })")
            }
        }
    }

    // MARK: - Tile → space mapping

    private func mapLabels(bars: [NSRect], tiles: [(wid: CGWindowID, rect: NSRect)],
                           now: CFTimeInterval, tilesAtRest: Bool)
        -> [(screen: NSScreen, labels: [BarLabel], complete: Bool)] {
        rebuildScreenCacheIfNeeded()
        rebuildSpacesCacheIfNeeded()
        var out: [(screen: NSScreen, labels: [BarLabel], complete: Bool)] = []
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
        // Prefs getters are CFPreferences reads (lock contention showed in the profile) —
        // read once per mapping, not once per tile.
        let namesVisible = Prefs.thumbnailNamesVisible
        let screens = NSScreen.screens
        // Grouped by row, not by which screen contains the tile: a tile the bar opened
        // scrolled past the screen edge still counts for its display, or the positional
        // pairing below is off by one (see `screenIndex(forTile:frames:)`).
        let grouped = Self.tilesByScreen(tiles, frames: screens.map(\.frame))
        for (si, screen) in screens.enumerated() {
            guard let did = screen.displayID else { continue }
            let sf = screen.frame
            guard bars.contains(where: { sf.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { continue }
            let scr = spacesByDisplay[did] ?? []
            guard !scr.isEmpty else { out.append((screen, [], false)); continue }
            let t = grouped[si]
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
                } else if namesVisible {
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
            // Every tile this display's space list expects is on screen at its committed
            // rect: the geometry is final, so the labels can reveal on the native curve
            // instead of waiting out the stillness gate (see OverlayWindow.update).
            out.append((screen, labels, t.count == scr.count))
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
                // Off-main: the enumeration is a window-server round-trip issued at the
                // very moment the commit behind the mismatch starts compositing — on main
                // it blocked the labels for the duration (see `sampleQueue`).
                spaces.refreshAsync { [weak self] enumerateUs, applyUs in
                    guard let self, self.phase != .closed else { return }
                    if self.debugLog, enumerateUs >= 2_000 || applyUs >= 2_000 {
                        self.dbg("spaces: enumerate \(enumerateUs) µs off-main, apply \(applyUs) µs on main")
                    }
                    // Re-map against the new list now, not at the next link tick.
                    self.frame(now: CACurrentMediaTime(), dt: 0, stepSprings: false, retargetOnly: true)
                }
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
        if let cached = labelContentCache[space.uuid] { return cached }
        let computed = computeLabelContent(space)
        labelContentCache[space.uuid] = computed
        return computed
    }

    private func computeLabelContent(_ space: Space) -> (name: String?, icon: NSImage?, key: String)? {
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
        if let cached = iconOverlayCache[space.uuid] { return cached }
        let computed = computeIconOverlayContent(space)
        iconOverlayCache[space.uuid] = computed
        return computed
    }

    private func computeIconOverlayContent(_ space: Space) -> (icon: NSImage, key: String)? {
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

/// Static bridge for the C event callback (a @convention(c) function can't capture
/// context). One overlay engine exists per app; `start()` points this at it.
private enum MCOEventBridge {
    static weak var overlay: MissionControlOverlay?
}

/// C-convention trampoline handed to sm_slsWindowEventsStart. Arrives on the main
/// thread (delivery rides the CGS event stream through the app's event loop).
private func mcoSLSEventTrampoline(type: UInt32, wid: UInt32) {
    MCOEventBridge.overlay?.handleSLSEvent(type: type, wid: wid)
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
    /// `spaceID` and `failed` are confined to this queue; `park` is the only entry point.
    private static let queue = DispatchQueue(label: "mco.sticky", qos: .userInteractive)
    private static var spaceID: UInt64 = 0
    private static var failed = false

    /// Move `window` onto the sticky space exclusively. Idempotent; call after each orderFront
    /// (an orderOut/orderFront cycle re-attaches the window to the active managed space). If the
    /// private symbols are gone the labels just ride the slide as before — no worse than not
    /// parking.
    ///
    /// The CGS calls run OFF the main thread: they are window-server round-trips made at
    /// the instant the overlay first becomes visible, which is inside Mission Control's
    /// expand compositing — measured blocking main for 280–480 ms there (2026-09-18, the
    /// `frame gap` following every `reveal:` line). The window number is read on main;
    /// everything after it is queue-confined.
    static func park(_ window: NSWindow) {
        let wid = UInt32(max(0, window.windowNumber))
        guard wid > 0 else { return }
        let askedAt = CACurrentMediaTime()
        queue.async { attach(wid, askedAt: askedAt) }
    }

    private static func attach(_ wid: UInt32, askedAt: CFTimeInterval) {
        guard !failed else { return }
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
        let t0 = CACurrentMediaTime()
        if !sm_stickySpaceAttachWindow(wid, spaceID) {
            failed = true; HotkeyDiag.log("MC label sticky: attach symbol missing"); return
        }
        let t1 = CACurrentMediaTime()
        HotkeyDiag.log("MC label sticky attach wid=\(wid) -> space \(spaceID):"
            + " queued \(Int((t0 - askedAt) * 1000)) ms, call \(Int((t1 - t0) * 1000)) ms")
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
/// get stuck). On exit they always fade in place — gently when the bar merely collapses,
/// and near-instantly when Mission Control itself dismisses (`exitDismiss`), matching the
/// native exit on macOS 27, which fades without moving the tiles.
private final class OverlayWindow: NSPanel {
    /// Diagnostics hook: (labelCount, msSinceExpand) at reveal, wired to the engine's dbg log.
    static var onReveal: ((Int, Int) -> Void)?
    /// Diagnostics hook: (where, alphaReport). Set only while debug logging is on.
    static var onAlpha: ((String, String) -> Void)?
    /// Diagnostics hook: one line per sampled moment of a relayout glide. This is how to
    /// tell "the labels are animating but behind" from "the labels are not animating at
    /// all" WITHOUT a screen recording — recording lowers the animation's frame rate and
    /// introduces artefacts, so it cannot answer the question it appears to answer.
    static var onTrace: ((String) -> Void)?
    /// Raised when a glide had to fall back because the label had no layer yet.
    static var onNoLayer: (() -> Void)?
    private var lastTraceAt: CFTimeInterval = 0

    private let container = NSView()

    private final class Item {
        let field: NSTextField
        var text: String
        var pos: CGPoint          // animated center (window-local)
        var vel: CGPoint = .zero
        var target: CGPoint
        var tau: CGFloat
        var settled = true
        // Launch entrance: while `entering`, the caption descends from `launchStartY` to its
        // target and its opacity ramps 0→1 in step with how far down it has travelled.
        var entering = false
        var launchStartY: CGFloat = 0
        /// A CASpringAnimation is playing this label's relayout glide in the RENDER server
        /// (see `caGlide`). The render server draws it; `pos`/`vel` keep running the SAME
        /// curve on the main thread as a shadow, drawn by nobody, purely so a retarget
        /// knows how fast the label is already travelling. Without that, every commit in a
        /// burst restarted the spring from rest and the labels fell behind the tiles —
        /// which is exactly what "the labels don't make it all the way" looked like.
        var caDriven = false
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
    private var fadeGen = 0

    // Motion tuning. τ is the critically damped spring's characteristic time (ω = 2/τ in
    // springStep's parameterization).
    //
    // THE REPLAY CURVE — one source of truth. `replayOmega` sets it, and both the shadow
    // spring (τ = 2/ω) and the render-server CASpringAnimation (stiffness = ω², damping =
    // 2ω at mass 1) are DERIVED from it, so the two can never drift apart. Raise it to
    // make relayout glides snappier; lower it to make them softer. Settling time scales
    // as 1/ω, so ω = 25 lands a hop in ~0.28 s where ω = 16.7 took ~0.42 s.
    //
    // WindowManager's own relayout measured ω ≈ 16.7/s (stiffness 278, damping 33.3 —
    // re-confirmed 2026-09-18 against a 120 fps capture, fix-workspace-lag.md). We
    // deliberately run FASTER than that. Matching the OS exactly is only "in sync" if
    // everything upstream is free; in practice the labels can only start once the commit
    // has been announced and a frame has run, so an exactly-matched curve can lose that
    // head start but never win it back, and the error is always in the same direction —
    // late. A stiffer spring spends the glide catching up instead, and because it stays
    // critically damped it still cannot overshoot or wobble.
    /// Past this much lateness the phase fast-forward stops being a glide — it jumps more
    /// than four fifths of the distance in one frame — so caGlide switches to a catch-up
    /// curve instead. Reached only when the window server is slow; a normal session's
    /// commit ages are single-digit ms (measured: median 2 ms, p90 19 ms).
    static let lateGeometry: CFTimeInterval = 0.10
    /// How long the OS's own relayout takes to settle, measured off a 120 fps capture
    /// (fix-workspace-lag.md): ~0.42 s.
    static let nativeSettle: CFTimeInterval = 0.42
    /// Settling time of a critically damped spring in units of 1/omega, fitted to the two
    /// curves this engine already uses: omega 16.7 settles in ~0.42 s, omega 25 in ~0.28 s.
    static let settleConstant: Double = 7.0
    /// Never compress a catch-up into less than this — below it the motion is a jump again.
    static let minCatchUp: CFTimeInterval = 0.12
    /// And never stiffer than this, so a pathologically late commit still shows movement.
    static let maxCatchUpOmega: CGFloat = 60

    private let replayOmega: CGFloat = 2 / 0.12      // ≈16.7, the measured OS curve
    private var tauReplay: CGFloat { 2 / replayOmega }
    /// The ADD case only. Adding a desktop is the one relayout where the labels were
    /// still reading as late, so it — and nothing else — runs a stiffer spring with a
    /// slightly longer head start. Everything else (removing a desktop, the row
    /// re-centring, the "+" peek) stays on the measured native curve above, where it
    /// already looked right; a global speed-up regressed the remove.
    private let addOmega: CGFloat = 25
    private let addLead: CFTimeInterval = 0.02
    /// A small deliberate head start on top of the measured commit age, for the same
    /// reason: the remaining latency between the window server committing and our
    /// animation being installed is time the tiles have been moving, and it is never
    /// negative. Entering the curve this much further along makes the labels arrive with
    /// the tiles rather than just behind them. Keep it small — overdone, the captions
    /// visibly lead the thumbnails.
    private let replayLead: CFTimeInterval = 0
    private let tauPursuit: CGFloat = 0.08
    /// Launch entrance: a much tighter τ than pursuit so the half-screen drop-in arrives
    /// snappily rather than floating down on the spring's slow tail.
    private let tauLaunch: CGFloat = 0.045
    private let layoutJump: CGFloat = 30

    // Reveal gating (time-based, measured on sampled targets — never on animated positions).
    // Small non-zero: hold the reveal until the bar has stopped moving, so the drop-in
    // entrance (below) always plays over STATIONARY tiles. Mouse opens are detected late
    // (bar already settled), so this is a no-op for them; hotkey opens are detected the
    // instant the bar starts expanding (WillOpen burst), and revealing mid-morph made the
    // entrance fight the still-moving bar — out of sync. maxWait is the can't-get-stuck cap.
    private let revealStableFor: CFTimeInterval = 0.05
    private let revealMaxWait: CFTimeInterval = 0.50
    private let stabilityEps: CGFloat = 1.0
    /// Duration of the native expand fade the in-place reveal replays (measured ~120 ms).
    private let nativeExpandFade: CFTimeInterval = 0.12

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
    var needsMotion: Bool { items.values.contains { !$0.settled || $0.caDriven } }

    // MARK: - Heartbeat

    /// While Mission Control is open the window server re-rasterises this window ONLY
    /// when we commit a transaction. A render-server animation — the relayout glides,
    /// the reveal fade — keeps playing in the render server, and the display shows it
    /// live, but the window's stored image stays at whatever the LAST commit rasterised.
    /// Nothing else reads that image, until the screen is recorded: a recording (and a
    /// screenshot) is composited from the stored images, so it shows the labels frozen
    /// at the glide's first frame, or not at all after a reveal (the store was rasterised
    /// at presentation alpha 0). That is the whole of the 2026-09-22/23 "labels freeze
    /// under screen recording" report. Measured with probe/wincap + probe/layerprobe:
    /// a bare window in this exact level/space configuration is re-rasterised live
    /// until Mission Control opens, then not at all (27 changes in 747 captures) — with
    /// a trivial commit every 16 ms it tracks throughout (697 of 744).
    ///
    /// So while anything is in flight, commit a real but invisible model change every
    /// frame: the render server then rasterises the CURRENT presentation state, motion
    /// included. Cheap (one 1×1 layer, ≤60 commits/s, only during motion), regime-blind
    /// (no need to detect the recording), and it leaves the glides where they are.
    private let pulse = CALayer()
    private var pulseOn = false
    private var pulseAt: CFTimeInterval = 0
    /// Keep pulsing until here — covers fades whose progress is not ours to step.
    private var pulseUntil: CFTimeInterval = 0
    /// Cap the heartbeat well under a 120 Hz link: 60 commits/s is plenty for a capture.
    private static let pulseSpacing: CFTimeInterval = 1.0 / 62

    /// Pulse the render server if anything is moving or fading. Returns true while the
    /// caller should keep the display link alive for it.
    private var pulseCount = 0
    private var pulseReportAt: CFTimeInterval = 0
    private var pulseFlushMax: Double = 0

    @discardableResult
    func heartbeat(now: CFTimeInterval) -> Bool {
        guard isVisible, needsMotion || now < pulseUntil else { return false }
        if now - pulseAt >= Self.pulseSpacing {
            pulseAt = now
            pulseCount += 1
            if pulse.superlayer == nil, let host = container.layer {
                pulse.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                pulse.opacity = 0
                host.addSublayer(pulse)
            }
            pulseOn.toggle()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pulse.opacity = pulseOn ? 0.001 : 0   // a real model change, nothing to draw
            CATransaction.commit()
            // Nested inside AppKit's implicit transaction this would only decrement the
            // nesting level; flush so the commit actually leaves for the render server.
            let f0 = CACurrentMediaTime()
            CATransaction.flush()
            let flushMs = (CACurrentMediaTime() - f0) * 1000
            pulseFlushMax = max(pulseFlushMax, flushMs)
            // Debug trace: the flush is the one main-thread window-server round-trip this
            // adds, so its cost is what to read if `frame gap` lines start following it.
            if let trace = Self.onTrace, now - pulseReportAt >= 0.25 || flushMs > 20 {
                pulseReportAt = now
                trace("heartbeat: \(pulseCount) pulses, moving=\(needsMotion), fade \(max(0, Int((pulseUntil - now) * 1000))) ms left, flush \(Int(flushMs)) ms (max \(Int(pulseFlushMax)))")
            }
        }
        return true
    }

    /// A fade of `duration` has just been committed: pulse through it and one beat past
    /// its end, so the stored image ends on the settled state.
    private func pulseThrough(_ duration: CFTimeInterval) {
        pulseUntil = max(pulseUntil, CACurrentMediaTime() + duration + 0.1)
    }

    /// Debug: every opacity in the chain that can make the labels render dim — the window,
    /// the container view and its layer (model vs what the render server is showing), and
    /// one representative label field. Chasing a "labels never reach full brightness"
    /// report by eye is hopeless; this says which of them is not 1.
    var alphaReport: String {
        func f2(_ v: Double) -> String { String(format: "%.2f", v) }
        let cl = container.layer
        var s = "win=\(f2(Double(alphaValue))) cont=\(f2(Double(container.alphaValue)))"
            + " contLayer=\(f2(Double(cl?.opacity ?? -1)))"
            + " contPres=\(f2(Double(cl?.presentation()?.opacity ?? -1)))"
            + " anims=\(cl?.animationKeys()?.joined(separator: ",") ?? "-")"
        if let it = items.values.first {
            let l = it.field.layer
            s += " | field=\(f2(Double(it.field.alphaValue)))"
                + " fLayer=\(f2(Double(l?.opacity ?? -1)))"
                + " fPres=\(f2(Double(l?.presentation()?.opacity ?? -1)))"
                + " fAnims=\(l?.animationKeys()?.joined(separator: ",") ?? "-")"
                + " hidden=\(it.field.isHidden)"
        }
        return s + " items=\(items.count) revealed=\(revealed)"
    }

    /// Whether the reveal has already fired. The engine keeps re-mapping while a visible
    /// overlay is unrevealed, so the fallback reveal gate still gets the repeated updates
    /// it needs to time out (see frame()'s `mustMap`).
    var hasRevealed: Bool { revealed }

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
    /// diff against the shown labels by space uuid and retarget the springs. `replay`
    /// marks targets that came from an 806/807 relayout commit — those launch the
    /// native-matched replay spring rather than the fallback pursuit/layout ones.
    func update(labels: [BarLabel]?, now: CFTimeInterval, replay: Bool = false,
                nativeReveal: Bool = false, commitAge: CFTimeInterval = 0,
                addBoost: Bool = false, reglide: Bool = false, dragging: Bool = false) {
        guard let labels, !labels.isEmpty else {
            guard expandedSince != nil || !items.isEmpty else { emptySince = nil; return }
            // Grace period: every tile vanishing at once is how MC dismissal BEGINS (the
            // bar follows ~30 ms later, and the AX-teardown trigger can take ~150 ms) —
            // hold long enough for the dismissal exit fade to win over this slower one.
            if let since = emptySince {
                if now - since >= 0.25 { emptySince = nil; fadeOutAndClear() }
            } else {
                emptySince = now
            }
            return
        }
        emptySince = nil
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
                if reglide, it.caDriven || !it.settled,
                   abs(it.pos.x - it.target.x) + abs(it.pos.y - it.target.y) > 0.5, d <= 0.5 {
                    // The add was only recognised once the new tile appeared, a beat after
                    // the relayout that started the motion. Put the labels already in
                    // flight onto the faster curve too, so one add is one continuous
                    // acceleration rather than a slow half and a quick half. Same target,
                    // velocity carried, so this is a re-aim and not a restart.
                    caGlide(it, to: it.target, commitAge: 0, fast: true)
                } else if (replay && d > 0.5) || d >= layoutJump {
                    // The tile itself starts gliding here on the native spring right
                    // about now — play the same curve, in the render server so a blocked
                    // main thread can't stall it (see caGlide). Retargeting mid-flight is
                    // safe: the replacement starts from the presentation position.
                    caGlide(it, to: l.center, commitAge: commitAge, fast: addBoost)
                } else if d > 0.01 {
                    // Something moved this label that isn't a relayout commit — a reorder
                    // drag, a re-centre the sampler found on its own. That is continuous
                    // pursuit, which the render server can't play open-loop: take the
                    // glide back and chase on the main thread.
                    //
                    // ...but NOT while a glide is mid-flight and no button is down. The
                    // main-thread spring only advances when a frame runs, and under a
                    // screen recording the main thread stalls for 40-135 ms at a stretch
                    // — stalls measured to be in AppKit or another source, not in this
                    // engine, so we cannot shorten them. A label landed mid-glide
                    // therefore stops dead for the length of the stall while its tile
                    // keeps moving: "stuck part-way through the animation". Left on the
                    // render server it rides the stall out, because the render server
                    // evaluates the spring whatever the main thread is doing.
                    //
                    // What gets landed is unchanged for the case the hand-back exists
                    // for: a drag (continuous, needs frame-rate pursuit) and a label
                    // sitting still (nothing to interrupt). What changes is only the
                    // mid-flight case, where the sampler's small corrections used to
                    // cancel a glide that was already going to the right place.
                    // Sub-0.5 pt noise re-aims nothing at all — installing an animation
                    // to travel half a point is pure churn, and the shadow spring closes
                    // the gap when it retires the glide.
                    if !Self.landOnDrift, it.caDriven, !dragging {
                        if d > 0.5 { caGlide(it, to: l.center, commitAge: 0, fast: addBoost) }
                    } else {
                        landCA(it)
                        it.settled = false
                    }
                }
                if it.text != l.contentKey { landCA(it); retext(it, l) }
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
        // NOTE: a changed label set does NOT force a τ change onto items already in
        // motion — a mid-flight add/remove just retargets whatever spring is playing.

        if maxDrift >= stabilityEps || changedSet { unstableAt = now }
        if !revealed, let since = expandedSince {
            // `nativeReveal` says every tile this display expects is on screen at its
            // committed rect, so there is nothing left to wait for. The stillness gate
            // below is the fallback for the sampling path: it re-arms on every label the
            // incremental discovery adds, which is what pushed the reveal out to its
            // 500 ms cap (measured: "reveal: 22 labels after 502 ms") and made the labels
            // pop in long after the tiles had finished fading.
            if nativeReveal {
                revealed = true
                OverlayWindow.onReveal?(items.count, Int((now - since) * 1000))
                revealInPlace()
            } else if now - unstableAt >= revealStableFor || now - since >= revealMaxWait {
                revealed = true
                OverlayWindow.onReveal?(items.count, Int((now - since) * 1000))
                beginEntrance()
                fadeIn()
            }
        }
    }

    /// Native expand on macOS 27 (26A5425a): the tiles are BORN at their final rects and
    /// fade in place over ~120 ms — the flight up from the collapsed pill slots is gone
    /// from the OS animation (measured off a 240 fps capture, fix-workspace-lag.md). Match
    /// it exactly: plant every caption on its final target and ramp the whole container's
    /// alpha on the same curve, so the labels materialize WITH their tiles rather than
    /// arriving after them.
    private func revealInPlace() {
        for it in items.values {
            cancelCA(it)
            it.pos = it.target
            it.vel = .zero
            it.settled = true
            it.entering = false
            it.field.alphaValue = 1
            place(it, aligned: true)
        }
        container.alphaValue = 0
        fadeGen += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = nativeExpandFade
            ctx.timingFunction = Self.fadeInCurve
            container.animator().alphaValue = 1
        }
        pulseThrough(nativeExpandFade)
        if let report = Self.onAlpha {
            report("revealInPlace +0", alphaReport)
            for delay in [0.05, 0.2, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    report("revealInPlace +\(Int(delay * 1000))", self.alphaReport)
                }
            }
        }
    }

    /// Seed the drop-in entrance for every currently-shown label AT REVEAL, so the descent
    /// starts from the labels' resting tiles (now settled) rather than from wherever the bar
    /// happened to be when the labels were first added mid-expansion.
    private func beginEntrance() {
        let top = container.bounds.height
        for it in items.values {
            cancelCA(it)
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

    /// MCO_LAND_ON_DRIFT=1 restores the unconditional hand-back to the main-thread
    /// spring on any non-commit drift — the behaviour before the mid-flight exemption
    /// above. The A/B switch for that change.
    private static let landOnDrift = ProcessInfo.processInfo.environment["MCO_LAND_ON_DRIFT"] != nil

    /// Key under which the relayout glide is attached to a label's layer.
    private static let caKey = "mcoGlide"

    // Coordinate spaces. `Item.pos`/`target` are label CENTRES in container coordinates.
    // A CALayer's `position` is its frame origin displaced by its anchor point, which for
    // an AppKit layer-backed view is (0, 0) — so the two spaces differ by half the label.
    // And critically, AppKit does NOT sync the backing layer when a view's frame is set:
    // `layer.position` still reads the PREVIOUS value until a layout pass runs (verified
    // directly — set the origin to 400,50 and the layer still reports 0,0). Reading the
    // destination back from the layer therefore produced an animation from the old spot to
    // the old spot: a no-op that held the label still for its whole settling duration and
    // then snapped it into place. That was the "labels lag on add". Convert explicitly
    // instead, and never read geometry back from a layer we just moved.

    static func layerPos(center: CGPoint, size: NSSize, anchor: CGPoint) -> CGPoint {
        CGPoint(x: center.x - size.width / 2 + anchor.x * size.width,
                y: center.y - size.height / 2 + anchor.y * size.height)
    }

    static func center(layerPos p: CGPoint, size: NSSize, anchor: CGPoint) -> CGPoint {
        CGPoint(x: p.x + size.width / 2 - anchor.x * size.width,
                y: p.y + size.height / 2 - anchor.y * size.height)
    }

    /// MCO_NO_CA=1 falls back to stepping every glide on the main thread (the behaviour
    /// before this change) — the A/B switch, and the instant revert if the render-server
    /// path ever misbehaves.
    private static let useCA = ProcessInfo.processInfo.environment["MCO_NO_CA"] == nil

    /// Hand one label's relayout glide to the render server.
    ///
    /// WHY: the tiles' own motion is played by WindowManager's Core Animation, and the
    /// window server is saturated compositing it. Our main thread's CoreAnimation commit
    /// has to queue behind that work — measured 2026-09-18 at up to 719 ms, with one
    /// sample round-trip of 13 ms taking 684 ms to be delivered to main. A glide stepped
    /// on the main thread simply stops for that long while the tiles keep moving, which
    /// is the whole of the remaining add/remove lag. A CASpringAnimation is evaluated by
    /// the render server every refresh once committed, so it rides out a blocked main
    /// thread — and `commitAge` enters the curve at the phase the tiles have already
    /// reached, so a late commit lands in step rather than restarting the motion.
    ///
    /// The animation is NON-ADDITIVE and always replaces any predecessor from its
    /// on-screen (presentation) position: an additive stack composes the old offset with
    /// the new one, which is what made sweeping the pointer along the bar throw the
    /// captions around in an earlier attempt at this.
    private func caGlide(_ it: Item, to target: CGPoint, commitAge: CFTimeInterval,
                         fast: Bool) {
        // Entering the curve at the phase the tiles have reached keeps the label ALIGNED
        // with its tile, and that is why it is done — but it only looks like motion while
        // the phase is small. The jump it produces is e^(-omega * commitAge) of the whole
        // distance, covered in a single frame:
        //
        //     commitAge   20 ms   50 ms   100 ms   200 ms   300 ms
        //     jumped       28%     57%      81%      96%      99%
        //
        // and the log really does reach the 300 ms clamp ("retargeting on the native
        // curve, 300 ms in") when the window server is slow. At that end it is not a glide
        // at all, it is the teleport the user reports.
        //
        // So: keep the phase fast-forward where it works, and past `lateGeometry` switch to
        // a CATCH-UP curve instead — start from rest at the label's real position and
        // compress the whole distance into what is left of the tiles' own animation. The
        // label then still lands with its tile, but visibly travels to get there. The
        // threshold is set where the jump becomes most of the distance; below it nothing
        // about the tuned add/remove feel changes.
        let base = fast ? addOmega : replayOmega
        let late = commitAge > Self.lateGeometry
        let omega: CGFloat
        if late {
            let remaining = max(Self.minCatchUp, Self.nativeSettle - commitAge)
            omega = min(Self.maxCatchUpOmega, max(base, CGFloat(Self.settleConstant / remaining)))
        } else {
            omega = base
        }
        let phase = late ? 0 : commitAge
        let lead = fast ? addLead : replayLead
        guard Self.useCA, let layer = it.field.layer else {
            // No layer yet (a label created in this very run-loop pass), or CA disabled.
            // Hand the move to the main-thread spring rather than returning silently:
            // `settled` was left TRUE here, so step() skipped the item, and because
            // update() had already written the new `target` the next frame measured zero
            // distance and never rescued it. The label stayed at its old position until
            // some later change happened to move it — arriving as a jump. That is the
            // "labels freeze part-way and then snap" report.
            it.tau = tauReplay
            it.target = target
            it.settled = false
            Self.onNoLayer?()
            return
        }
        // Where the label actually IS right now — mid-flight if a glide is already playing.
        // Presentation is the truth on screen; the shadow spring supplies the velocity,
        // which presentation cannot give without sampling it twice.
        let size = it.field.frame.size
        let anchor = layer.anchorPoint
        // Where the label is on screen. The presentation layer is truth while something is
        // animating; otherwise fall back to the VIEW's frame, which is authoritative on the
        // main thread, never the layer's (see above).
        let from = layer.presentation()?.position
            ?? Self.layerPos(center: it.pos, size: size, anchor: anchor)
        let v = it.caDriven || !it.settled ? it.vel : .zero
        layer.removeAnimation(forKey: Self.caKey)
        // An interrupted entrance must not be left half-faded (its alpha is driven by the
        // main-thread spring's vertical progress, which is about to stop running).
        if it.entering { it.entering = false; it.field.alphaValue = 1 }
        // Re-anchor the shadow to what is actually on screen, keeping its velocity.
        it.pos = Self.center(layerPos: from, size: size, anchor: anchor)
        it.vel = v
        it.tau = 2 / omega
        it.target = target
        it.settled = false
        // Model value = the final position, and the animation's destination COMPUTED from
        // it — the layer cannot be asked, it has not caught up yet.
        let rect = NSRect(x: target.x - size.width / 2, y: target.y - size.height / 2,
                          width: size.width, height: size.height)
        let alignedOrigin = container.backingAlignedRect(rect, options: .alignAllEdgesNearest).origin
        it.field.setFrameOrigin(alignedOrigin)
        let to = CGPoint(x: alignedOrigin.x + anchor.x * size.width,
                         y: alignedOrigin.y + anchor.y * size.height)
        let a = CASpringAnimation(keyPath: "position")
        // The measured native relayout curve — re-confirmed 2026-09-18 against the user's
        // 120 fps capture by tracking the last tile's edge through a remove: 20% complete
        // at 42 ms, 53% at 108 ms, 86% at 200 ms, 99% at 420 ms, which is this spring to
        // within the measurement's own precision.
        // Derived from `replayOmega` so the render-server curve and the shadow spring are
        // by construction the same motion: critically damped, ω = sqrt(k/m) = k/(2·sqrt(k)).
        a.mass = 1
        a.stiffness = omega * omega
        a.damping = 2 * omega
        // Carry the momentum across the retarget. initialVelocity is expressed as a
        // fraction of the remaining distance covered per second, along the travel
        // direction, so project the shadow's velocity onto it.
        let dx = to.x - from.x, dy = to.y - from.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist > 0.5 {
            a.initialVelocity = (v.x * dx + v.y * dy) / dist / dist
        }
        a.fromValue = NSValue(point: from)
        a.toValue = NSValue(point: to)
        a.duration = a.settlingDuration
        a.isRemovedOnCompletion = true
        a.fillMode = .backwards
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - (phase + lead)
        layer.add(a, forKey: Self.caKey)
        it.caDriven = true
        // Fast-forward the shadow by the same head start, so it stays in step with what
        // the render server is drawing.
        let head = phase + lead
        if head > 0 {
            let sx = Self.springStep(pos: it.pos.x, vel: it.vel.x, target: target.x,
                                     tau: it.tau, dt: head)
            let sy = Self.springStep(pos: it.pos.y, vel: it.vel.y, target: target.y,
                                     tau: it.tau, dt: head)
            it.pos = CGPoint(x: sx.pos, y: sy.pos)
            it.vel = CGPoint(x: sx.vel, y: sy.vel)
        }
    }

    /// Take a render-server glide back onto the main-thread spring, seeded from where the
    /// label is ON SCREEN. Used when something the render server can't know about starts
    /// moving the label — a reorder drag, a content change, a teardown.
    private func landCA(_ it: Item) {
        guard it.caDriven else { return }
        it.caDriven = false
        guard let layer = it.field.layer else { return }
        let size = it.field.frame.size
        let anchor = layer.anchorPoint
        let p = layer.presentation()?.position
            ?? Self.layerPos(center: it.pos, size: size, anchor: anchor)
        layer.removeAnimation(forKey: Self.caKey)
        it.pos = Self.center(layerPos: p, size: size, anchor: anchor)
        // Velocity is deliberately KEPT: the shadow has been tracking the same curve, so
        // handing back to the main-thread spring mid-flight continues the motion instead
        // of stalling it.
        it.settled = false
        if it.entering { it.entering = false; it.field.alphaValue = 1 }
        place(it, aligned: false)
    }

    /// Drop a glide without adopting its position (teardown paths).
    private func cancelCA(_ it: Item) {
        it.caDriven = false
        it.field.layer?.removeAnimation(forKey: Self.caKey)
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
    func step(dt: CFTimeInterval, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        if let trace = Self.onTrace, now - lastTraceAt >= 0.05,
           let it = items.values.filter({ $0.caDriven }).max(by: {
               abs($0.pos.x - $0.target.x) < abs($1.pos.x - $1.target.x)
           }), let layer = it.field.layer {
            lastTraceAt = now
            let anchor = layer.anchorPoint
            let size = it.field.frame.size
            let shown = layer.presentation().map {
                Self.center(layerPos: $0.position, size: size, anchor: anchor)
            }
            trace(String(format: "glide %@: onscreen=%.1f shadow=%.1f target=%.1f remaining=%.1f",
                         it.text.prefix(14) as NSString,
                         shown?.x ?? .nan, it.pos.x, it.target.x,
                         (shown?.x ?? it.pos.x) - it.target.x))
        }
        guard dt > 0 else { return needsMotion }
        var moving = false
        for it in items.values where !it.settled {
            if it.caDriven {
                // Advance the SHADOW only — the render server is drawing this label, and
                // touching its frame here would fight the animation. Stepping the same
                // closed-form spring keeps pos/vel truthful for the next retarget, and
                // retires the glide when the curve has run out.
                let sx = Self.springStep(pos: it.pos.x, vel: it.vel.x, target: it.target.x,
                                         tau: it.tau, dt: dt)
                let sy = Self.springStep(pos: it.pos.y, vel: it.vel.y, target: it.target.y,
                                         tau: it.tau, dt: dt)
                it.pos = CGPoint(x: sx.pos, y: sy.pos)
                it.vel = CGPoint(x: sx.vel, y: sy.vel)
                let rx = it.pos.x - it.target.x, ry = it.pos.y - it.target.y
                if (rx * rx + ry * ry).squareRoot() < 0.05,
                   (it.vel.x * it.vel.x + it.vel.y * it.vel.y).squareRoot() < 0.5 {
                    it.caDriven = false
                    it.field.layer?.removeAnimation(forKey: Self.caKey)
                    it.pos = it.target
                    it.vel = .zero
                    it.settled = true
                    it.tau = tauPursuit
                    place(it, aligned: true)
                } else {
                    moving = true
                }
                continue
            }
            let sx = Self.springStep(pos: it.pos.x, vel: it.vel.x, target: it.target.x, tau: it.tau, dt: dt)
            let sy = Self.springStep(pos: it.pos.y, vel: it.vel.y, target: it.target.y, tau: it.tau, dt: dt)
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
        for it in items.values { cancelCA(it) }
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
        cancelCA(it)
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
        pulseThrough(0.12)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.fadeGen else { return }
            self.container.subviews.forEach { $0.removeFromSuperview() }
            self.orderOut(nil)
        })
    }

    /// Mission Control is dismissing. The native exit on macOS 27 is an in-place fade
    /// completing in ≤67 ms — the tiles do not move (measured; the old fly-up exit no
    /// longer exists on this OS, see fix-workspace-lag.md). Match it: a fast fade with
    /// zero motion. Erring early reads as native; a late fade lingers over the desktop.
    func exitDismiss() {
        emptySince = nil
        guard !items.isEmpty || expandedSince != nil || revealed else { return }
        revealed = false
        expandedSince = nil
        items.removeAll()
        fadeGen += 1
        let gen = fadeGen
        pulseThrough(0.07)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.07
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        // Layer-backed EXPLICITLY. A subview of a layer-backed container does not get its
        // own layer until a full run-loop pass has gone by — measured directly
        // (scratchpad/layerprobe.swift): 0 of 5 fields have layers after addSubview,
        // after layoutSubtreeIfNeeded, after orderFront and after display(); all 5 have
        // them one pass later. Until then `field.layer` is nil, and caGlide's guard turns
        // into a silent no-op that strands the label (see there).
        field.wantsLayer = true
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
            var image = icon.isTemplate ? tinted(icon, color: .white) : icon
            // The centered-on-thumbnail icon (`.largeOver`) rides on a translucent dark
            // circle so it reads against any wallpaper thumbnail instead of blending in.
            // The other styles sit above the tile on the dimmed backdrop and stay bare.
            // Badge size is occlusion-safe: 11 filled 40 pt circles over the tiles did
            // NOT trip WindowManager's compositing abort (mission-control-labels.md
            // addendum) — keep the badge in this size class if it ever grows.
            if l.id.hasSuffix(mcIconLabelSuffix) { image = IconRendering.circleBadged(image) }
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
