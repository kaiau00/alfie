import Foundation
import Testing
@testable import MoeVoice

/// The turn bench's scorer and barge-in replay against hand-built cases whose
/// answer is known before the code runs (scripts/turnbench/README.md). Each
/// number asserted here is worked out in the comment above it, not read off
/// the code — a scorer that agrees with itself proves nothing.
struct CorpusScoreTests {

    typealias E = TurnTape.Event
    typealias W = TurnCorpus.Word

    // MARK: - Fixtures

    /// A reply from 1.0 s to 11.0 s: two sentences of five words, 1 s a word.
    private let reply = TurnCorpus.Reply(start: 1.0, end: 11.0, words: [
        W("the", 1.0, 1.9), W("weather", 2.0, 2.9), W("is", 3.0, 3.9), W("mostly", 4.0, 4.9),
        W("sunny", 5.0, 5.9, sentenceEnd: true),
        W("sunday", 6.0, 6.9), W("looks", 7.0, 7.9), W("cooler", 8.0, 8.9), W("and", 9.0, 9.9),
        W("cloudier", 10.0, 10.9, sentenceEnd: true),
    ])

    private func scenario(_ category: String, at start: Double? = nil, until end: Double? = nil,
                          reply r: TurnCorpus.Reply? = nil) -> TurnCorpus.Scenario {
        let inter = start.map { TurnCorpus.Interjection(kind: category, text: "", start: $0, end: end ?? $0 + 0.5) }
        return TurnCorpus.Scenario(id: category, kind: "reply", category: category, duration: 12,
                                   reply: r ?? reply, interjection: inter)
    }

    private func result(pauses: [Double] = [], ducks: [Double] = []) -> BargeReplay.Result {
        var r = BargeReplay.Result()
        r.pauses = pauses; r.ducks = ducks
        return r
    }

    // MARK: - Replies: false and missed barge-ins, stop latency

    /// Nobody spoke; the reply paused at 4.0 s. A false barge-in, over the 3 s
    /// of reply (1.0 → 4.0) that played before it.
    @Test func aPauseWithNobodySpeakingIsAFalseBargeIn() {
        let s = CorpusScore.score(scenario("none"), result(pauses: [4.0], ducks: [3.5]))
        #expect(s.falseStop)
        #expect(abs(s.exposure - 3.0) < 1e-9)
        #expect(s.falseDucks == 1)
        #expect(s.missed == nil)
    }

    /// "Stop" at 5.0 s, paused at 5.6: taken, 0.6 s late; the duck at 5.3
    /// was 0.3 s late. Exposure is the reply before the word: 4.0 s.
    @Test func aStopTakenInTimeHasItsLatency() throws {
        let s = CorpusScore.score(scenario("stop", at: 5.0), result(pauses: [5.6], ducks: [5.3]))
        #expect(!s.falseStop)
        #expect(s.missed == false)
        #expect(abs(try #require(s.stopLatency) - 0.6) < 1e-9)
        #expect(abs(try #require(s.duckLatency) - 0.3) < 1e-9)
        #expect(abs(s.exposure - 4.0) < 1e-9)
        #expect(s.falseDucks == 0)
    }

    /// A real interruption at 3.0 and no pause at all, with 8 s of reply
    /// still to go: missed. Paused 2.5 s after it: missed too (the window is 2 s).
    @Test func aRealInterruptionNotPausedWithinTwoSecondsIsMissed() {
        #expect(CorpusScore.score(scenario("interrupt", at: 3.0), result()).missed == true)
        let late = CorpusScore.score(scenario("interrupt", at: 3.0), result(pauses: [5.5]))
        #expect(late.missed == true)
        #expect(late.stopLatency == nil)
        #expect(!late.falseStop)
    }

    /// Paused at 2.0 by the room before the person said "stop" at 3.0: a
    /// false barge-in, and their stop cannot be scored either way.
    @Test func aPauseBeforeThePersonSpokeIsFalseAndTheirStopIsUnscored() {
        let s = CorpusScore.score(scenario("stop", at: 3.0), result(pauses: [2.0]))
        #expect(s.falseStop)
        #expect(s.missed == nil)
        #expect(abs(s.exposure - 1.0) < 1e-9)
    }

    /// "Stop" at 10.0 and the reply ends by itself at 11.0: nothing was left
    /// to pause inside the 2 s window, so it is not scored as missed.
    @Test func aStopTheReplyOutranIsUnscored() {
        #expect(CorpusScore.score(scenario("stop", at: 10.0), result()).missed == nil)
    }

    /// "Mm-hm" at 4.0 and the reply paused at 4.8: a false barge-in and a
    /// backchannel stop. Exposure runs to the pause (3.8 s): a backchannel
    /// is not a reason to be quiet.
    @Test func aBackchannelThatPausesTheReplyIsFalse() {
        let s = CorpusScore.score(scenario("backchannel", at: 4.0), result(pauses: [4.8]))
        #expect(s.falseStop)
        #expect(s.backchannelStopped)
        #expect(abs(s.exposure - 3.8) < 1e-9)
    }

    /// Four replies: two false stops over 3 + 4 + 10 + 3.8 = 20.8 s of Moe
    /// audio → 2 / 20.8 × 600 = 57.69 per 10 minutes. One of one scorable
    /// real interruption was taken, 0.6 s late.
    @Test func theSummaryRatesAreCountsOverExposure() {
        let turns = [
            CorpusScore.score(scenario("none"), result(pauses: [4.0])),
            CorpusScore.score(scenario("stop", at: 5.0), result(pauses: [5.6])),
            CorpusScore.score(scenario("none"), result()),
            CorpusScore.score(scenario("backchannel", at: 4.0), result(pauses: [4.8])),
        ]
        let s = CorpusScore.summarize(turns)
        #expect(s.falseStops == 2)
        #expect(abs(s.moeMinutes - 20.8 / 60) < 1e-9)
        #expect(abs(s.falseStopsPer10Min - 2 / 20.8 * 600) < 1e-9)
        #expect(s.real == 1 && s.missed == 0)
        #expect(abs(s.stopP50 - 0.6) < 1e-9)
        #expect(s.backchannels == 1 && s.backchannelStops == 1)
    }

    /// Wilson 95%: 0 of 10 → [0, 0.2775]; 5 of 10 → [0.2366, 0.7634]
    /// (the textbook values).
    @Test func wilsonIntervalsMatchTheTextbook() {
        let a = CorpusScore.wilson(0, 10)
        #expect(a.lo == 0 && abs(a.hi - 0.2775) < 1e-4)
        let b = CorpusScore.wilson(5, 10)
        #expect(abs(b.lo - 0.2366) < 1e-4 && abs(b.hi - 0.7634) < 1e-4)
    }

    // MARK: - Turns: missed turns and latency

    private func decision(_ t: Double) -> PolicyReplay.Decision {
        PolicyReplay.Decision(t: t, reason: .turnModel, replyHold: 0, p: 0.9, text: "x")
    }

    /// A turn whose true end is at 3.0: decided at 3.4 → 0.4 s, not missed.
    /// Never decided → missed, and left out of the latency; a decision at 1.5
    /// inside the pause 1.2–2.0 is a cut-off whether or not the turn was
    /// answered at the end.
    @Test func aTurnNeverDecidedIsMissedAndHasNoLatency() throws {
        let truth = TurnTape.Truth(holds: [.init(start: 1.2, end: 2.0)], end: .init(start: 3.0, end: 10))
        let tape = TurnTape(id: "t", events: [E(t: 2.1, .partial, "a b c")], truth: truth, duration: 10)
        var answered = PolicyReplay.Result(); answered.decisions = [decision(3.4)]
        var cutThenSilent = PolicyReplay.Result(); cutThenSilent.decisions = [decision(1.5)]
        let a = CorpusScore.score(tape, answered)
        let b = CorpusScore.score(tape, cutThenSilent)
        #expect(!a.missed)
        #expect(abs(try #require(a.eot.commitLatency) - 0.4) < 1e-9)
        #expect(b.missed)
        #expect(b.eot.commitCuts == 1)
        let s = CorpusScore.summarize([a, b])
        #expect(s.missed == 1)
        #expect(s.eot.turns == 2)
        #expect(s.eot.holds == 2)
        #expect(abs(s.eot.commitCutRate - 0.5) < 1e-9)          // 1 cut of 2 pauses
        #expect(abs(s.eot.p50CommitLatency - 0.4) < 1e-9)       // only the answered turn
    }

    // MARK: - The barge-in replay

    private func replay(_ events: [E], levels: [Double]? = nil, reference: Double? = nil,
                        continuous: Bool = false) -> BargeReplay.Result {
        let tape = TurnTape(id: "r", events: events, duration: 12)
        var cfg = BargeReplay.Config()
        cfg.referenceRms = reference
        cfg.continuousAsr = continuous
        return BargeReplay.run(tape, reply: reply, levels: levels, cfg)
    }

    /// The playhead at 6.5 s: the first sentence (27 characters) has been
    /// heard, the second is playing — under both tails (80 and 30), all of it.
    /// At 11.5 s everything is heard and nothing plays: the last 30
    /// characters, cut mid-word as `SpeechOut` cuts them. At 0.5 s nothing
    /// is heard and the first sentence is queued.
    @Test func thePlayheadIsTheSentencePlayingAndWhatWasHeard() {
        let p = BargeReplay.playhead(reply, at: 6.5)
        #expect(p.around == "the weather is mostly sunny sunday looks cooler and cloudier")
        #expect(p.at == p.around)
        let end = BargeReplay.playhead(reply, at: 11.5)
        #expect(end.at == "nday looks cooler and cloudier")
        #expect(BargeReplay.playhead(reply, at: 0.5).around == "the weather is mostly sunny")
    }

    /// A door at 3.0 s: an onset, no words. The word window (1.0 s) closes
    /// and the reply is never paused — nor even ducked, since ducking waits
    /// for a first word.
    @Test func aSoundWithNoWordsNeverPausesTheReply() {
        let r = replay([E(t: 3.0, .speechStarted), E(t: 3.3, .speechEnded)])
        #expect(r.pauses.isEmpty)
        #expect(r.ducks.isEmpty)
        #expect(r.onsets == [3.0])
        #expect(r.refused == [VoiceMachine.OnsetRejection.noWords.rawValue])
        #expect(r.until == 11.0)
    }

    /// "Stop" over the reply: onset at 4.0, the word at 4.4. A stop word is
    /// urgent — one word is enough — and the judge takes it at once (the
    /// name and stop words are exempt from every score). Paused 50 ms later.
    @Test func aStopWordPausesTheReply() throws {
        let r = replay([E(t: 4.0, .speechStarted), E(t: 4.4, .partial, "stop")])
        let p = try #require(r.pauses.first)
        #expect(abs(p - 4.45) < 1e-9)
        #expect(r.judged.first?.decision.check == .words)
        #expect(r.ducks == [4.4])
    }

    /// "Yeah, okay" over the reply: nods do not count as words while Moe
    /// talks, so two of them are still none — nothing is judged and nothing
    /// is paused. (Counted, they would be the two words it takes.)
    @Test func aBackchannelDoesNotPauseTheReply() {
        let r = replay([E(t: 4.0, .speechStarted), E(t: 4.4, .partial, "yeah"),
                        E(t: 4.6, .partial, "yeah okay"), E(t: 4.8, .speechEnded)])
        #expect(r.pauses.isEmpty)
        #expect(r.judged.isEmpty)
    }

    /// Two real words and no loudness reference: taken on the words
    /// (`no-signal`), paused after the judge.
    @Test func twoRealWordsPauseTheReply() throws {
        let r = replay([E(t: 4.0, .speechStarted), E(t: 4.4, .partial, "what about"),
                        E(t: 4.6, .partial, "what about tuesday")])
        #expect(abs(try #require(r.pauses.first) - 4.45) < 1e-9)
        #expect(r.judged.first?.decision.check == .noSignal)
    }

    /// Moe's own sentence coming back through the microphone — "sunday looks
    /// cooler" while "sunday looks cooler and cloudier" plays — is refused by
    /// the echo check, and the reply carries on.
    @Test func mosOwnSentenceComingBackIsEcho() {
        let r = replay([E(t: 7.6, .speechStarted), E(t: 8.0, .partial, "sunday looks"),
                        E(t: 8.3, .partial, "sunday looks cooler")])
        #expect(r.pauses.isEmpty)
        #expect(r.judged.first?.decision.check == .echoText)
        #expect(r.refused == [VoiceMachine.OnsetRejection.notForMoe.rawValue])
    }

    /// Too quiet to be the person: the level of the last 0.3 s against the
    /// session's reference is 0.1 (under 0.35), so two words are refused on
    /// loudness. At the reference level they are taken.
    @Test func aVoiceFarQuieterThanThePersonIsRefusedOnLoudness() {
        let events = [E(t: 4.0, .speechStarted), E(t: 4.4, .partial, "what about"),
                      E(t: 4.6, .partial, "what about tuesday")]
        let quiet = replay(events, levels: [Double](repeating: 0.01, count: 600), reference: 0.1)
        #expect(quiet.pauses.isEmpty)
        #expect(quiet.judged.first?.decision.check == .loudness)
        let loud = replay(events, levels: [Double](repeating: 0.1, count: 600), reference: 0.1)
        #expect(loud.pauses.count == 1)
    }

    /// The pre-roll: the recogniser writes "stop" at 3.1, a moment *before*
    /// the VAD's onset at 3.25 (the onset is a chunk late). The engine's
    /// recogniser, switched on with 0.5 s of pre-roll, hears it; so must the
    /// replay — the word count is re-based on the transcript as it stood
    /// before the pre-roll, not at the onset.
    @Test func aWordFromThePrerollStillCounts() throws {
        let r = replay([E(t: 2.0, .partial, "the weather"), E(t: 3.1, .partial, "the weather stop"),
                        E(t: 3.25, .speechStarted), E(t: 3.6, .partial, "the weather stop")], continuous: true)
        #expect(!r.pauses.isEmpty)
    }

    /// Echo decoded well before the onset is not the person's: "the weather
    /// is" at 2.0 and an onset at 4.0 with nothing new is a sound, not words.
    @Test func echoBeforeTheOnsetIsNotCounted() {
        let r = replay([E(t: 2.0, .partial, "the weather is"), E(t: 4.0, .speechStarted),
                        E(t: 4.5, .partial, "the weather is"), E(t: 4.6, .speechEnded)], continuous: true)
        #expect(r.pauses.isEmpty)
        #expect(r.judged.isEmpty)
    }

    /// A live tape: the recogniser is reset at the onset, so what it writes
    /// next is fresh text. Before the onset it wrote a long stretch of Moe's
    /// own reply (echo), five words; after it, "stop". That is one word from
    /// zero — the engine's count — and it pauses the reply. (Read as a
    /// running transcript, "stop" would be one word against a baseline of
    /// five, and nothing.)
    @Test func aLiveTapeCountsFromZeroAfterTheReset() throws {
        let r = replay([E(t: 2.0, .partial, "i found three italian places"), E(t: 3.0, .speechStarted),
                        E(t: 3.4, .partial, "stop")])
        #expect(abs(try #require(r.pauses.first) - 3.45) < 1e-9)
    }

    /// What the host is told to do with the recogniser: nothing while the
    /// reply plays; at an onset, reset it and switch it on with 0.5 s of
    /// pre-roll; when the word window closes with no words, off again.
    @Test func theSessionSaysWhenTheRecogniserListens() {
        var session = BargeReplay.Session(reply: reply, BargeReplay.Config())
        session.advance(to: 2.0)
        #expect(!session.takeAsrCommands().contains(.on(primeSeconds: 0.5)))
        session.handle(E(t: 3.0, .speechStarted))
        #expect(session.takeAsrCommands() == [.reset, .on(primeSeconds: 0.5)])
        session.advance(to: 4.1)                                  // the 1 s window closed
        #expect(session.takeAsrCommands() == [.off])
        #expect(!session.done)
    }
}
