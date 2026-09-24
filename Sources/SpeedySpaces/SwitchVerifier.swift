// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Waits for the space to actually change after an engine fires, measures how long
/// it took, and reports whether the current space matches the target. An engine can
/// switch in multiple steps (natural-mode gesture settles per space), so `activeSpaceDidChange` can
/// fire more than once before the target is actually reached. The verifier stays
/// armed across those intermediate fires and only completes when the target space
/// becomes current, or when 2s pass with no further space change (idle timeout).
///
/// Cross-display caveat: a space change on a display WITHOUT key focus never posts
/// `activeSpaceDidChange`, so the notification path can't confirm those switches.
/// A 0.25 s state poll confirms them instead, and the idle timeout judges by the
/// actual final state rather than assuming failure.
final class SwitchVerifier {
    private var observer: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    private var poll: Timer?

    /// `refresh` re-queries spaces; `isCurrentTarget` checks the post-refresh state.
    func verify(method: SwitchMethod, target: Space, from: Space?,
                start: DispatchTime,
                refresh: @escaping () -> Void,
                isCurrentTarget: @escaping () -> Bool,
                completion: @escaping (SwitchOutcome) -> Void) {
        // Tear down any prior in-flight verification before installing a new one — last
        // switch wins. Without this, an earlier verify()'s timeout can fire after being
        // overwritten and cancel the *new* observer/timeout via cancel(), orphaning the
        // latest switch's completion.
        cancel()
        func finish(reason: String?) {
            cancel()
            refresh()
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            // The final state is the verdict — never the delivery of a notification.
            let confirmed = isCurrentTarget()
            completion(SwitchOutcome(
                method: method, fromOrdinal: from?.ordinalOnDisplay, toOrdinal: target.ordinalOnDisplay,
                displayIndex: target.displayIndex, ok: confirmed, milliseconds: ms,
                reason: confirmed ? nil : (reason ?? "space did not become current")))
        }
        // (Re)arm the idle-timeout: cancel any pending one and schedule a fresh 2s deadline.
        // Called once up front and again after every intermediate (non-target) space change,
        // so a multi-step chain that keeps making progress isn't cut off mid-flight — only
        // 2s of *no* further space change trips it.
        func armTimeout() {
            timeout?.cancel()
            let work = DispatchWorkItem { finish(reason: "timed out (no space change for 2s)") }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
        armTimeout()
        let p = Timer(timeInterval: 0.25, repeats: true) { _ in
            refresh()
            if isCurrentTarget() { finish(reason: nil) }
        }
        RunLoop.main.add(p, forMode: .common)
        poll = p
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            refresh()
            if isCurrentTarget() {
                finish(reason: nil)
            } else {
                // Intermediate hop of a multi-step switch — stay armed and push the idle
                // deadline out another 2s instead of failing on the first partial fire.
                armTimeout()
            }
        }
    }

    private func cancel() {
        timeout?.cancel(); timeout = nil
        poll?.invalidate(); poll = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}
