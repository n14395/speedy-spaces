import AppKit

/// Serialises the "Move window to next/previous workspace" hotkeys.
///
/// The move holds the window in a server-side drag and taps ⌃+fn+arrow; each grab must run to completion
/// (grab → tap → release) uninterrupted. If a second press fired its own grab while the first was
/// still mid-flight, the first walk's mouse-up would drop the drag the second still needed, so the
/// later press only switched the space and left the window behind. We prevent that: the FIRST
/// press moves immediately (no added latency), and any presses that arrive while a walk is in
/// flight accumulate and fire as ONE fluid multi-step walk the instant it finishes — so a burst
/// of "next, next, next" lands the window the full distance instead of just the first hop.
///
/// Main-thread only (driven from the hotkey dispatch); `busy`/`pendingSteps` are never touched off
/// the main thread — the walk's completion hops back to main before calling `walkDidFinish`.
final class RelativeWindowMover {
    static let shared = RelativeWindowMover()

    private var wrap = false
    private weak var spaces: SpacesManager?
    private var busy = false          // a walk is currently playing out
    private var pendingSteps = 0      // net presses that arrived during the current walk

    /// A relative move keypress. `forward` = next workspace; else previous.
    func press(forward: Bool, wrap: Bool, spaces: SpacesManager) {
        self.wrap = wrap
        self.spaces = spaces
        let dir = forward ? 1 : -1
        if busy { pendingSteps += dir; return }   // fold into the batch the running walk will drain
        start(steps: dir, spaces: spaces)
    }

    /// Anchor on the focused window's current space, resolve `steps` away (wrapping per pref), and
    /// run one server-drag walk. Silently no-ops when there's no focused window or nowhere to go.
    private func start(steps: Int, spaces: SpacesManager) {
        guard let wid = try? WindowMover.focusedWindow().wid else { NSSound.beep(); return }
        spaces.refresh()
        let ids = WindowMover.spaceIDs(for: wid)
        guard let origin = spaces.spaces.first(where: {
            ids.contains(UInt64($0.managedSpaceID)) && !$0.isFullscreen }) else { NSSound.beep(); return }
        let list = spaces.spaces
            .filter { $0.displayIndex == origin.displayIndex && !$0.isFullscreen }
            .sorted { $0.ordinalOnDisplay < $1.ordinalOnDisplay }
        guard let i = list.firstIndex(where: { $0.uuid == origin.uuid }), !list.isEmpty else { return }
        let raw = i + steps
        var j = raw
        if wrap { j = ((j % list.count) + list.count) % list.count }
        else { j = max(0, min(list.count - 1, j)) }
        guard j != i else { return }   // net zero (or clamped at an end) → nothing to do
        let target = list[j]
        // A wrap (stepping past an end to the far side) would walk the whole list the long way with
        // ⌃-arrows — jump straight there with the native "Switch to Desktop N" chord instead.
        let jumpDesktop = (wrap && (raw < 0 || raw >= list.count)) ? target.ordinalOnDisplay + 1 : nil

        busy = true
        HotkeyDiag.log("relativeMove: wid=\(wid) \(steps) step(s) -> space \(target.managedSpaceID)"
            + (jumpDesktop != nil ? " (wrap → jump)" : ""))
        do {
            try WindowMover.moveViaServerDrag(wid: wid, target: target, spaces: spaces,
                                              jumpDesktop: jumpDesktop) {
                [weak self] in self?.walkDidFinish()
            }
        } catch WindowMover.MoveError.screenRecordingRequired {
            busy = false
            pendingSteps = 0   // every queued press would hit the same wall
            ScreenRecordingPermission.reportBlockedMove()
        } catch {
            busy = false
            HotkeyDiag.log("relativeMove failed: \(error)")
            drainPending()   // this batch produced no move; still honour queued presses
        }
    }

    /// The walk landed; if presses queued meanwhile, run them now as one batch from the new spot.
    private func walkDidFinish() {
        busy = false
        drainPending()
    }

    private func drainPending() {
        guard pendingSteps != 0, let spaces else { return }
        let carry = pendingSteps
        pendingSteps = 0
        start(steps: carry, spaces: spaces)
    }
}
