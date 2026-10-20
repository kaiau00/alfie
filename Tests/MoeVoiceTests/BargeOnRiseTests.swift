import Foundation
import Testing
@testable import MoeVoice

/// The turn bench, 2026-09-24: 337 of 601 real interruptions (56%) were
/// missed over a playing reply, and 258 of those 337 had **no VAD onset at
/// all** for the person's words. The tapes showed why: Silero called the
/// canceller's residue of Moe's own voice speech from the reply's first word
/// (≈ 0.3 s in) to its last, the machine judged that one onset ("you have",
/// refused by loudness or as echo) and let it go, and the person talking a
/// few seconds later rose out of speech the VAD was already in — no edge,
/// no recogniser, no stop. The gate now reports a voice that rises well
/// over what it has been hearing (`.rose`), and over a reply that opens an
/// onset like any other: words, then the judge.
struct BargeOnRiseTests {

    typealias M = VoiceMachine

    // MARK: - The gate

    /// Echo the VAD calls speech: in speech from the first chunk, level
    /// wandering a few dB. A person 15 dB over it is a rise; the echo's own
    /// wander is not.
    @Test func aVoiceOverTheEchoRisesAndTheEchoDoesNot() {
        var g = NoiseFloorGate()
        #expect(g.observe(chunkDb: -40, peakDb: -35, vad: .start) == .started)
        for peak: Float in [-37, -33, -36, -38, -34, -79, -35] {
            #expect(g.observe(chunkDb: peak - 5, peakDb: peak, vad: nil) == nil)
        }
        #expect(g.observe(chunkDb: -28, peakDb: -21, vad: nil) == .rose)
        #expect(g.inSpeech)
    }

    /// The bed is the recent sound, not the room: a chunk of digital silence
    /// between two sentences does not make the next sentence a rise.
    @Test func aGapBetweenSentencesIsNotTheBed() {
        var g = NoiseFloorGate()
        _ = g.observe(chunkDb: -40, peakDb: -34, vad: .start)
        _ = g.observe(chunkDb: -40, peakDb: -35, vad: nil)
        for _ in 0..<3 { _ = g.observe(chunkDb: -79, peakDb: -79, vad: nil) }
        #expect(g.observe(chunkDb: -39, peakDb: -33, vad: nil) == nil)
    }

    @Test func noRiseOutsideSpeechOrWhenTurnedOff() {
        var g = NoiseFloorGate()
        _ = g.observe(chunkDb: -40, peakDb: -35, vad: nil)
        _ = g.observe(chunkDb: -40, peakDb: -35, vad: nil)
        // Not in speech: a loud chunk with no VAD start is nothing to report.
        #expect(g.observe(chunkDb: -25, peakDb: -20, vad: nil) == nil)
        var off = NoiseFloorGate()
        off.tuning.riseMarginDb = 0
        _ = off.observe(chunkDb: -40, peakDb: -35, vad: .start)
        _ = off.observe(chunkDb: -40, peakDb: -35, vad: nil)
        #expect(off.observe(chunkDb: -25, peakDb: -20, vad: nil) == nil)
    }

    // MARK: - The machine

    private func speaking(_ tune: (inout M.Tuning) -> Void = { _ in }) -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        tune(&m.tuning)
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { return m }
        _ = m.handle(.transcribed(turn: turn, "how does that work"))
        _ = m.handle(.speechQueued)
        return m
    }

    /// The bench's shape: the echo's onset at the reply's start is judged
    /// and refused, the VAD never ends, and the person's words come as a
    /// rise. They are listened for, judged, and the reply pauses.
    @Test func aRiseOverTheEchoIsListenedToAndStopsTheReply() {
        var m = speaking()
        _ = m.handle(.speechStarted)                      // Moe's own echo
        _ = m.handle(.wordsHeard(2))                      // "you have"
        _ = m.handle(.bargeInJudged(false))               // refused: echo
        #expect(!m.awaitingWords)
        let rose = m.handle(.speechRose)                  // the person, over it
        #expect(m.awaitingWords)
        #expect(rose.contains(.resetAsr))
        #expect(rose.contains(.asr(true)))
        #expect(rose.contains(.capture(true)))
        #expect(!rose.contains(.duckSpeech(true)))
        #expect(m.handle(.wordsHeard(2)).contains(.judgeBargeIn))
        #expect(m.handle(.bargeInJudged(true)).contains(.pauseSpeech))
    }

    /// Echo rises the recogniser makes a word of must not pump the volume:
    /// a rise's onset goes from words to the judge without a duck.
    @Test func aRisesFirstWordDoesNotDuck() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        _ = m.handle(.timer(.bargeInHold))                // the echo onset, let go
        _ = m.handle(.speechRose)
        #expect(!m.handle(.wordsHeard(1)).contains(.duckSpeech(true)))
        // …while an edge's first word still ducks, as DuckPumpingTests says.
        var e = speaking()
        _ = e.handle(.speechStarted)
        #expect(e.handle(.wordsHeard(1)).contains(.duckSpeech(true)))
    }

    /// A rise with no words is let go like an edge with none: nothing
    /// ducked, nothing paused, one rejected row.
    @Test func aRiseWithNoWordsIsLetGo() {
        var m = speaking()
        var all = m.handle(.speechRose)
        all += m.handle(.timer(.bargeInHold))
        #expect(!all.contains(.duckSpeech(true)))
        #expect(!all.contains(.pauseSpeech))
        #expect(all.filter { $0 == .onsetRejected(.noWords) }.count == 1)
        #expect(!m.awaitingWords)
    }

    /// Only over a playing reply. While Moe listens a rise is somebody
    /// already talking getting louder, and the edges already said so.
    @Test func aRiseMeansNothingWhileMoeListens() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted)
        let before = m.state
        #expect(m.handle(.speechRose).isEmpty)
        #expect(m.state == before)
    }

    /// A rise inside an onset already waiting on words does not restart it.
    @Test func aRiseDoesNotExtendAPendingOnset() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        #expect(m.handle(.speechRose).isEmpty)
    }

    // MARK: - A bench case that was missed

    /// `dev-Anjali-interrupt-14@clean`, echo −25 dB: "Hang on, can you
    /// repeat the address?" from 1.00 s over "You have three things
    /// tomorrow…". On main's tape the VAD started on the echo at 0.78, the
    /// recogniser wrote "you have", the judge refused it as echo, and
    /// nothing else ever happened — missed. Recorded live on this branch,
    /// the gate reports a rise at 1.28, the recogniser writes "hang on",
    /// and the live run paused at 1.49. These are that tape's events.
    private let anjali = TurnCorpus.Scenario(
        id: "dev-Anjali-interrupt-14@clean", kind: "reply", category: "interrupt", duration: 7.8,
        reply: .init(start: 0.5, end: 7.3, words: [
            .init("You", 0.50, 0.59), .init("have", 0.59, 0.74), .init("three", 0.74, 0.97),
            .init("things", 0.97, 1.24), .init("tomorrow", 1.24, 1.66, sentenceEnd: true),
            .init("At", 2.07, 2.21), .init("nine", 2.21, 2.55), .init("there's", 2.55, 2.69),
            .init("the", 2.69, 2.78), .init("team", 2.78, 3.03), .init("stand-up", 3.03, 3.54),
            .init("at", 3.82, 3.99), .init("eleven", 3.99, 4.25), .init("thirty", 4.25, 4.65),
            .init("a", 4.65, 4.69), .init("call", 4.69, 4.94), .init("with", 4.94, 5.05),
            .init("the", 5.05, 5.14), .init("accountant", 5.14, 5.61), .init("about", 5.61, 5.79),
            .init("the", 5.79, 5.85), .init("quarterly", 5.85, 6.22), .init("numbers", 6.22, 6.68),
            .init("and", 6.99, 7.19), .init("at", 7.19, 7.25), .init("four", 7.25, 7.62),
        ]),
        interjection: .init(kind: "interrupt", text: "Hang on, can you repeat the address?", start: 1.0032, end: 3.2532))

    private let anjaliTape = TurnTape(id: "dev-Anjali-interrupt-14@clean", events: [
        .init(t: 0.78, .speechStarted),
        .init(t: 1.00, .partial, "you have"),
        .init(t: 1.28, .speechRose),
        .init(t: 1.44, .partial, "hang on"),
    ], duration: 7.8)

    /// The file's RMS per 20 ms, 0–1.52 s, as the bench recorded it (the
    /// loudness check reads it; the session opened on the person at 0.028).
    private let anjaliLevels: [Double] = Array(repeating: 0.0001, count: 27) + [
        0.0011, 0.0035, 0.0031, 0.0027, 0.0032, 0.0033, 0.0032, 0.0025, 0.0009, 0.0005, 0.0005, 0.0005,
        0.0002, 0.0003, 0.0004, 0.0002, 0.0007, 0.0022, 0.0026, 0.0020, 0.0019, 0.0020, 0.0017, 0.0008,
        0.0030, 0.0069, 0.0186, 0.0409, 0.0541, 0.0566, 0.0470, 0.0424, 0.0342, 0.0324, 0.0347, 0.0365,
        0.0313, 0.0363, 0.0331, 0.0365, 0.0355, 0.0286, 0.0262, 0.0173, 0.0102, 0.0075, 0.0079, 0.0061, 0.0068,
    ]

    private func replayAnjali(_ config: BargeReplay.Config) -> BargeReplay.Result {
        var config = config
        config.referenceRms = 0.028221
        return BargeReplay.run(anjaliTape, reply: anjali.reply!, levels: anjaliLevels, config)
    }

    @Test func theMissedBenchCaseIsCaughtNow() throws {
        let r = replayAnjali(BargeReplay.Config())
        // The echo's onset, judged and refused; then the rise, taken.
        #expect(r.judged.count == 2)
        #expect(r.judged.first?.decision.taken == false)
        let pause = try #require(r.pauses.first)
        #expect(abs(pause - 1.49) < 1e-6)                 // where the live run paused
        let score = CorpusScore.score(anjali, r)
        #expect(score.missed == false)
        #expect(!score.falseStop)
    }

    @Test func withoutRisesTheSameTapeIsMissed() {
        var config = BargeReplay.Config()
        config.tuning.onsetOnRise = false
        let r = replayAnjali(config)
        #expect(r.pauses.isEmpty)
        #expect(CorpusScore.score(anjali, r).missed == true)
    }

    @Test func offItIsTheOldRule() {
        var m = speaking { $0.onsetOnRise = false }
        #expect(m.handle(.speechRose).isEmpty)
        #expect(!m.awaitingWords)
    }
}
