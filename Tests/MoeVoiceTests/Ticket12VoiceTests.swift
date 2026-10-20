import Foundation
import Testing
@testable import MoeVoice

/// Ticket #12: "your speech is getting mumbled", from the owner's Moe on
/// 2026-09-24. Two things in its log that each degrade what is heard, and
/// neither was ever said out loud.
struct CallMicDebounceTests {

    private static let chrome = CallMicDebounce.Holder(name: "Chrome", isBrowser: true)
    private static let telegram = CallMicDebounce.Holder(name: "Telegram", isBrowser: false)

    /// Chrome on the microphone, as the log measured it from 15:20:37:
    /// on at +0, gone by +3, on +10, gone +12, on +19, gone +26, on +29,
    /// gone +32 — the "echo cancellation off / on" pairs 3–9 s apart.
    private static func chromeFromTheLog(_ t: Double) -> [CallMicDebounce.Holder] {
        let on: [(Double, Double)] = [(0, 3), (10, 12), (19, 26), (29, 32)]
        return on.contains { t >= $0.0 && t < $0.1 } ? [chrome] : []
    }

    /// Drive the watchdog the way `AudioFrontEnd` does: a poll every 2 s,
    /// and a restart (the canceller changing state) on every decision.
    private static func run(_ debounce: inout CallMicDebounce, until end: Double,
                            speaking: (Double) -> Bool = { _ in false },
                            holders: (Double) -> [CallMicDebounce.Holder]) -> [(Double, CallMicDebounce.Decision)] {
        var on = true
        var restarts: [(Double, CallMicDebounce.Decision)] = []
        var t = 0.0
        while t <= end {
            let d = debounce.observe(holders: holders(t), cancellerOn: on, speaking: speaking(t), now: t)
            switch d {
            case .keep: break
            case .giveUp: on = false; restarts.append((t, d))
            case .takeBack: on = true; restarts.append((t, d))
            }
            t += 2
        }
        return restarts
    }

    /// The ticket's thirty seconds: the old rule — whoever holds the mic this
    /// poll — restarted the graph at every change. None of those grabs held
    /// long enough to be a call, so nothing restarts now.
    @Test func theTicketsChromeGrabsRestartNothing() {
        // The old rule, for the record of what it did to the same timeline.
        var old = 0
        var wasHeld = false
        for t in stride(from: 0.0, through: 40, by: 2) {
            let held = !Self.chromeFromTheLog(t).isEmpty
            if held != wasHeld { old += 1; wasHeld = held }
        }
        #expect(old >= 6, "the timeline no longer reproduces the flapping")

        var debounce = CallMicDebounce()
        let restarts = Self.run(&debounce, until: 40, holders: Self.chromeFromTheLog)
        #expect(restarts.isEmpty, "a browser's short grabs restarted the graph: \(restarts)")
    }

    /// A browser that really is on a call — held the whole time — gets the
    /// microphone once it has held for `browserHoldSeconds`.
    @Test func aBrowserThatHoldsIsACall() {
        var debounce = CallMicDebounce()
        let restarts = Self.run(&debounce, until: 30) { _ in [Self.chrome] }
        #expect(restarts.count == 1)
        #expect(restarts.first?.1 == .giveUp("Chrome"))
        #expect((restarts.first?.0 ?? 0) >= debounce.browserHoldSeconds)
    }

    /// A dedicated call app is believed on the first poll, as before: its far
    /// end hears nothing until the canceller is off — even mid-sentence.
    @Test func aCallAppIsBelievedAtOnceEvenWhileMoeTalks() {
        var debounce = CallMicDebounce()
        let d = debounce.observe(holders: [Self.telegram], cancellerOn: true, speaking: true, now: 0)
        #expect(d == .giveUp("Telegram"))
    }

    /// Taking the microphone back waits for it to stay free, so a call that
    /// drops the mic for a moment (a device switch, a mute) does not flap.
    @Test func theCancellerComesBackOnlyAfterTheMicStaysFree() {
        var debounce = CallMicDebounce()
        #expect(debounce.observe(holders: [], cancellerOn: false, speaking: false, now: 0) == .keep)
        #expect(debounce.observe(holders: [], cancellerOn: false, speaking: false, now: 6) == .keep)
        // Back for a poll: the clock starts again.
        #expect(debounce.observe(holders: [Self.chrome], cancellerOn: false, speaking: false, now: 8) == .keep)
        #expect(debounce.observe(holders: [], cancellerOn: false, speaking: false, now: 10) == .keep)
        #expect(debounce.observe(holders: [], cancellerOn: false, speaking: false, now: 18) == .keep)
        #expect(debounce.observe(holders: [], cancellerOn: false, speaking: false, now: 20) == .takeBack)
    }

    /// A restart stops the player, so neither a browser nor the canceller's
    /// return may cut Moe off; both wait for the reply to finish.
    @Test func nothingButACallAppRestartsTheGraphMidReply() {
        var debounce = CallMicDebounce()
        let talking: (Double) -> Bool = { $0 < 30 }
        let restarts = Self.run(&debounce, until: 40, speaking: talking) { _ in [Self.chrome] }
        #expect(restarts.first.map { $0.0 >= 30 } ?? false, "a browser restarted the graph mid-reply: \(restarts)")

        var back = CallMicDebounce()
        #expect(back.observe(holders: [], cancellerOn: false, speaking: true, now: 0) == .keep)
        #expect(back.observe(holders: [], cancellerOn: false, speaking: true, now: 20) == .keep)
        #expect(back.observe(holders: [], cancellerOn: false, speaking: false, now: 22) == .takeBack)
    }
}

struct PremiumVoiceSpentTests {

    /// The exact words Inworld sent back on 2026-09-24, from moe.log.
    @Test func inworldsOutOfCreditsRefusalIsRecognised() {
        let refusal = InworldError.rejected(
            "You have no credits remaining. Please add credits to continue using the service.")
        #expect(PremiumVoiceSpent.matches(refusal))
    }

    /// A socket that dropped, or any other refusal, is worth another try —
    /// it must not switch the voice off for good.
    @Test func otherFailuresAreNotSpent() {
        #expect(!PremiumVoiceSpent.matches(InworldError.connectionLost("socket closed")))
        #expect(!PremiumVoiceSpent.matches(InworldError.unreachable("timed out")))
        #expect(!PremiumVoiceSpent.matches(InworldError.rejected("Unknown voice id")))
        #expect(!PremiumVoiceSpent.matches(CancellationError()))
    }

    /// Plain words for the person: which voice, and that Moe carries on.
    @Test func theNoticeIsPlain() {
        let n = PremiumVoiceSpent.notice
        #expect(n.contains("premium voice"))
        #expect(n.contains("credits"))
        for jargon in ["402", "Inworld", "TTS", "backend", "HTTP"] {
            #expect(!n.contains(jargon), "the notice says \(jargon)")
        }
    }
}
