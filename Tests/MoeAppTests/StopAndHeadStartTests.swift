import Foundation
import Testing
@testable import Moe

/// The two fixes of 2026-10-06: a double-tap stop that cannot be undone by
/// the taps after it, and a PocketTTS head start sized from how fast the
/// engine is really rendering.
struct StopSettleTests {

    /// The window is exactly as long as "Stopped" is shown: a double-tap
    /// inside it stops again; one after it, from rest, is a real "listen".
    @Test func aDoubleTapWhileStoppedIsShownStopsAgain() {
        let stopped = Date(timeIntervalSince1970: 1_000)
        #expect(Conductor.stopSettleSeconds == Conductor.stoppedShownSeconds)
        #expect(Conductor.stopStillSettling(since: stopped, now: stopped.addingTimeInterval(0.5)))
        #expect(Conductor.stopStillSettling(since: stopped, now: stopped))
    }

    @Test func theWindowCloses() {
        let stopped = Date(timeIntervalSince1970: 1_000)
        #expect(!Conductor.stopStillSettling(
            since: stopped, now: stopped.addingTimeInterval(Conductor.stopSettleSeconds + 0.01)))
        // 2 s cut both ways: a real "listen to me" a second after a stop
        // stopped again. It is under a second now.
        #expect(!Conductor.stopStillSettling(since: stopped, now: stopped.addingTimeInterval(1.0)))
        #expect(!Conductor.stopStillSettling(since: nil, now: stopped))
        // A clock that went backwards is not a recent stop.
        #expect(!Conductor.stopStillSettling(since: stopped, now: stopped.addingTimeInterval(-1)))
    }
}

struct HeadStartTests {

    @Test func unmeasuredKeepsTheFloor() {
        #expect(SpeechOut.headStart(floor: 0.25, speechSeconds: 4, speed: nil) == 0.25)
    }

    /// 2.9× on an idle Mac: no extra wait.
    @Test func aFastEngineKeepsTheFloor() {
        #expect(SpeechOut.headStart(floor: 0.25, speechSeconds: 4, speed: 2.9) == 0.25)
    }

    /// At 0.9× a 4 s sentence falls 1 s behind: that much, and its margin,
    /// is held before the first word.
    @Test func aSlowEngineIsGivenEnoughToFinish() {
        let s = SpeechOut.headStart(floor: 0.25, speechSeconds: 4, speed: 0.9)
        #expect(s > 1.2 && s < 1.3)
    }

    @Test func neverMoreThanTwoSeconds() {
        #expect(SpeechOut.headStart(floor: 0.25, speechSeconds: 20, speed: 0.5) == 2.0)
    }

    /// A whole-utterance engine has a zero floor and must stay at zero.
    @Test func zeroFloorStaysOff() {
        #expect(SpeechOut.headStart(floor: 0, speechSeconds: 4, speed: 0.5) == 0)
    }

    @Test func pocketIsHandedKyutaisTemperature() {
        #expect(PocketBackend.temperature == 0.3)
        #expect(TtsTuning.base(for: .pocket).temperature == 0.3)
    }
}

/// The second half of "it doesn't fully cancel": a typed turn stopped by the
/// double-tap. Nothing was being spoken, so `voice.stopAll()` never marked
/// the reply abandoned, and whatever the brain had already sent arrived
/// after the stop and was treated as the answer: text on the island, a tool
/// row, the travelling light. Revert the `replyAbandoned = true` in
/// `stopEverything` and this goes red.
@MainActor
@Suite(.serialized)
struct StopEverythingStragglerTests {

    @Test func aStoppedTypedTurnStaysStopped() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("book me a table for two", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        moe.stopEverything()

        brain.emit(.textDelta("Sure, booking it now."))
        brain.emit(.toolStarted(name: "browser_navigate", id: "t1", emoji: nil,
                                detail: "opentable.com", spoken: nil))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!moe.acting, "a tool row came back after the stop")
        #expect(moe.mode == .idle)
        #expect(!moe.turns.contains { $0.text.contains("booking") },
                "the stopped turn's words reached the transcript")
    }
}
