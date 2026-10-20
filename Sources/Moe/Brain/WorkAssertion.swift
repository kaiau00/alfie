import Foundation

/// Keeps the Mac from idle-sleeping while Moe is working on an answer.
///
/// A lid closed is a lid closed — nothing here stops that, and
/// `TurnKeeper` is what handles it. This is for the other way a turn died:
/// the person asks for something that takes four minutes, walks off, and
/// the Mac's own idle timer puts it to sleep at two. Measured on this repo
/// on 2026-09-18: Moe held no assertion of any kind during a turn; the one
/// `beginActivity` in the app (`CloudSync`) deliberately allows idle sleep.
///
/// `.idleSystemSleepDisabled` is the narrow option: the display may still
/// sleep, the person's own energy settings are otherwise untouched, and
/// the assertion ends with the turn. `.userInitiated` says why to Activity
/// Monitor's Energy tab. Main thread, like the value it follows.
final class WorkAssertion {
    private var token: NSObjectProtocol?

    /// Hold while `held`; release otherwise. Idempotent either way.
    func set(held: Bool) {
        if held {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Moe is working on a question")
        } else if let t = token {
            ProcessInfo.processInfo.endActivity(t)
            token = nil
        }
    }

    var isHeld: Bool { token != nil }

    deinit { set(held: false) }
}
