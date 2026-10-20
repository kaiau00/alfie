import Foundation
import Testing

@testable import MoeMeeting

// The rule that would have saved 2026-09-08's 16:10 meeting: 61 minutes of
// call recorded with a system stream of exact zeros, every voice in the
// room written down as "you".
//
// Every test here asserts the *action taken*, never "did observe return
// something". A watch that never fires and a watch that judges the stream
// healthy are indistinguishable from a boolean.

@Suite("Tap watch")
struct TapWatchTests {

    /// Drive the watch a second at a time and collect what it asked for.
    /// `everSounded` defaults to false — the hard grade, 59 million exact
    /// zeros — because that is the case the type exists for.
    private func run(seconds: Int, quiet: Bool, everSounded: Bool = false, playing: Bool = true,
                     echoCancelling: Bool = true, micHasSpeech: Bool = true,
                     watch: inout TapWatch) -> [TapWatch.Action] {
        var out: [TapWatch.Action] = []
        var cancelling = echoCancelling
        for t in 0..<seconds {
            let a = watch.observe(systemQuiet: quiet, systemEverSounded: everSounded,
                                  somethingIsPlaying: playing, echoCancelling: cancelling,
                                  micHasSpeech: micHasSpeech, at: Double(t))
            if a != .none { out.append(a) }
            // The caller really does drop it, so the watch must not be able
            // to ask twice by seeing it still on.
            if a == .dropEchoCancellation { cancelling = false }
        }
        return out
    }

    @Test("a stream that is carrying sound is never touched")
    func healthy() {
        var w = TapWatch()
        #expect(run(seconds: 600, quiet: false, everSounded: true, watch: &w).isEmpty)
        #expect(w.everHeardSomething)
        #expect(w.rebuildCount == 0)
    }

    @Test("nothing playing is not evidence of anything — the in-person meeting")
    func nothingPlaying() {
        var w = TapWatch()
        #expect(run(seconds: 600, quiet: true, playing: false, watch: &w).isEmpty)
        #expect(w.rebuildCount == 0)
        #expect(!w.hasReported)
    }

    @Test("silence under 15 s is a pause, not a fault")
    func shortSilence() {
        var w = TapWatch()
        #expect(run(seconds: 15, quiet: true, watch: &w).isEmpty)
    }

    @Test("echo cancellation goes first — cheap, reversible, and the one thing that differed")
    func dropsEchoCancellationFirst() {
        var w = TapWatch()
        #expect(run(seconds: 20, quiet: true, watch: &w) == [.dropEchoCancellation])
    }

    @Test("with echo cancellation already off it goes straight to a rebuild")
    func rebuildsWhenNotCancelling() {
        var w = TapWatch()
        #expect(run(seconds: 20, quiet: true, echoCancelling: false, watch: &w) == [.rebuildTap])
        #expect(w.rebuildCount == 1)
    }

    /// The 16:10 meeting on 2026-09-08: 59,153,310 frames of exact zeros.
    @Test("the full ladder: drop, rebuild, rebuild, then tell the user, once")
    func fullLadder() {
        var w = TapWatch()
        let actions = run(seconds: 300, quiet: true, watch: &w)
        #expect(actions == [.dropEchoCancellation, .rebuildTap, .rebuildTap, .reportDead])
        #expect(w.rebuildCount == 2)
        #expect(w.hasReported)
    }

    /// The 10:20 meeting: 1.2 s of sound in 2,126, so the stream *did*
    /// carry something. Repair it — and never claim to the user that their
    /// call is not being recorded, because a webinar where the far end says
    /// nothing for a minute looks exactly like this.
    @Test("a stream that has sounded gets the repairs and never the notice")
    func soundedOnceIsRepairedButNeverReported() {
        var w = TapWatch()
        let actions = run(seconds: 600, quiet: true, everSounded: true, watch: &w)
        #expect(actions == [.dropEchoCancellation, .rebuildTap, .rebuildTap])
        #expect(!w.hasReported)
    }

    @Test("each step gets its own window before the next")
    func stepsAreSpaced() {
        var w = TapWatch()
        var fired: [(Double, TapWatch.Action)] = []
        var cancelling = true
        for t in 0..<200 {
            let a = w.observe(systemQuiet: true, systemEverSounded: false, somethingIsPlaying: true,
                              echoCancelling: cancelling, at: Double(t))
            if a != .none { fired.append((Double(t), a)); if a == .dropEchoCancellation { cancelling = false } }
        }
        #expect(fired.count == 4)
        // 15 s to the first, then 15 s between each.
        #expect(fired.map(\.0) == [15, 30, 45, 60])
    }

    @Test("a stream that recovers stops the ladder where it is")
    func recoveryResets() {
        var w = TapWatch()
        // Silent long enough to drop echo cancellation…
        _ = run(seconds: 20, quiet: true, watch: &w)
        // …then it comes back, and stays back.
        #expect(run(seconds: 600, quiet: false, everSounded: true, echoCancelling: false, watch: &w).isEmpty)
        #expect(w.rebuildCount == 0)
        #expect(!w.hasReported)
    }

    @Test("a mic that has heard nobody is not worth interrupting for")
    func silentRoomIsNotReported() {
        var w = TapWatch()
        let actions = run(seconds: 300, quiet: true, micHasSpeech: false, watch: &w)
        #expect(actions == [.dropEchoCancellation, .rebuildTap, .rebuildTap])
        #expect(!w.hasReported)
    }

    @Test("the notice says what it costs, and hedges the one thing it cannot know")
    func noticeWording() {
        // It fires on an in-person meeting too, where there is no call and
        // no bug, so it must not assert that a call is being missed.
        #expect(TapWatch.deadNotice.contains("If you are on a call"))
        #expect(TapWatch.deadNotice.contains("written down as you"))
        #expect(!TapWatch.deadNotice.lowercased().contains("aggregate"))
        #expect(!TapWatch.deadNotice.lowercased().contains("tap"))
    }
}

@Suite("Something is playing")
struct OutputActivityTests {

    private func sig(_ id: String, out: Bool) -> CallSignal {
        CallSignal(bundleID: id, input: false, output: out)
    }

    @Test("Moe's own playback does not count — the tap excludes it")
    func ignoresSelf() {
        let signals = [sig("com.memoe.app", out: true), sig("com.apple.Music", out: false)]
        #expect(!OutputActivity.othersPlaying(signals, mine: "com.memoe.app"))
    }

    @Test("only exactly itself: the tap excludes one process, so this excludes one id")
    func ignoresOnlyItself() {
        // A helper of Moe's playing audio *is* in the tap's capture, so its
        // silence is evidence like anyone else's.
        let signals = [sig("com.memoe.app.helper", out: true)]
        #expect(OutputActivity.othersPlaying(signals, mine: "com.memoe.app"))
    }

    @Test("a call app playing counts")
    func callAppCounts() {
        let signals = [sig("com.memoe.app", out: true), sig("com.tdesktop.Telegram", out: true)]
        #expect(OutputActivity.othersPlaying(signals, mine: "com.memoe.app"))
    }

    @Test("Moe Dev excludes itself, not the real Moe")
    func devIsItsOwnApp() {
        let signals = [sig("com.memoe.app.dev", out: true)]
        #expect(!OutputActivity.othersPlaying(signals, mine: "com.memoe.app.dev"))
        #expect(OutputActivity.othersPlaying(signals, mine: "com.memoe.app"))
    }

    @Test("nothing playing is nothing playing")
    func quiet() {
        #expect(!OutputActivity.othersPlaying([sig("com.google.Chrome", out: false)], mine: "com.memoe.app"))
        #expect(!OutputActivity.othersPlaying([], mine: "com.memoe.app"))
    }
}
