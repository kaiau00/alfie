import AppKit
import Combine

/// Whether macOS lets Moe see the talk key, kept current for every screen
/// that has to say so.
///
/// Before this, the answer was read once at launch and written to a log
/// line. A person whose right ⌥ did nothing had no way to learn why: the
/// island said nothing on hover, chat said nothing, and the only place that
/// knew was `~/.moe/logs/moe.log` — "accessibility: NOT granted" three times
/// on the owner's Mac on 2026-09-10 while System Settings showed Moe
/// switched on. A permission that is off has to be said where the person is
/// looking, and it has to stop being said the moment it is on, without a
/// relaunch — so this polls, cheaply, and publishes.
@MainActor
final class AccessibilityWatch: ObservableObject {
    static let shared = AccessibilityWatch()

    @Published private(set) var granted: Bool

    /// Asked in an earlier launch and still off. That is either a person who
    /// declined, or a stale grant — the toggle in System Settings belongs to
    /// an earlier copy of Memoe and macOS refuses this one while showing it on.
    /// Captured once, at launch: pressing Allow in this launch is not
    /// evidence of anything yet.
    let staleSuspected: Bool

    /// Runs when the grant arrives, so push-to-talk can arm without a relaunch.
    var onGranted: [() -> Void] = []

    private var timer: Timer?

    private init() {
        granted = PushToTalk.hasAccessibility
        staleSuspected = PushToTalk.askedButStillOff
        // AXIsProcessTrusted is one XPC round trip to tccd. Every two seconds
        // while it is off (someone may be in System Settings right now), every
        // ten once it is on (it can be revoked, rarely).
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: granted ? 10 : 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let now = PushToTalk.hasAccessibility
        guard now != granted else { return }
        granted = now
        Log.write("accessibility: \(now ? "granted" : "revoked") while running")
        if now { onGranted.forEach { $0() } }
        schedule()
    }

    /// The one button every surface offers: ask, or — when an earlier ask
    /// went nowhere — clear macOS's stale entries first and ask again.
    func fix() {
        if staleSuspected || PushToTalk.askedButStillOff {
            PushToTalk.resetAccessibilityAndAsk()
        } else {
            PushToTalk.requestAccessibility()
            if let url = PermissionGuide.accessibility.settingsURL { NSWorkspace.shared.open(url) }
        }
    }

    /// What the talk key needs, in one sentence, for the island and chat —
    /// naming the key as configured (`Config.talkKey`).
    func problem(for key: TalkKey) -> String {
        staleSuspected
            ? "\(key.label) can't start me yet. If Memoe is already switched on in Accessibility, macOS is holding on to an older copy — Fix clears it, then switch Memoe on again."
            : "\(key.label) can't start me until you allow Accessibility. The keyboard shortcut works meanwhile."
    }
}
