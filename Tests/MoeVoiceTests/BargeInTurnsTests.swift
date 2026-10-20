import Foundation
import Testing
@testable import MoeVoice

/// Step 1.2 of the conversation-mode plan: barge-in decided before the
/// pause, not after it (research-interruptions.md §0 #1, §5).
struct BargeInTurnsTests {

    typealias M = VoiceMachine

    private func speaking() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { return m }
        _ = m.handle(.transcribed(turn: turn, "tell me about rome"))
        _ = m.handle(.speechQueued)
        return m
    }

    // MARK: Two words over Moe's voice, or one that means stop

    /// A lone word is the likeliest thing the recogniser makes of the TV or of
    /// Moe's own residue; Pipecat's shape is two while the bot speaks.
    @Test func oneWordOverTheReplyIsNotEnough() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        let one = m.handle(.wordsHeard(1))
        #expect(!one.contains(.judgeBargeIn))
        #expect(m.state == .speaking(.hotkey))
        let two = m.handle(.wordsHeard(2))
        #expect(two.contains(.judgeBargeIn))
    }

    @Test func aStopWordIsEnoughOnItsOwn() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        let stop = m.handle(.wordsHeard(1, urgent: true))
        #expect(stop.contains(.judgeBargeIn))
    }

    /// Nothing is playing while Moe thinks: one word still takes it there,
    /// as before.
    @Test func overThinkingOneWordStillTakesIt() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "what's the weather"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.ttsDrained)                    // parked: the brain is still writing
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        #expect(m.state == .capturing(.followUp))
    }

    @Test func stopWordsAreTheOnesThatStopASpeaker() {
        #expect(TurnPolicy.hasStopWord(in: "stop"))
        #expect(TurnPolicy.hasStopWord(in: "wait a second"))
        #expect(TurnPolicy.hasStopWord(in: "no no no"))
        #expect(TurnPolicy.hasStopWord(in: "hold on"))
        #expect(TurnPolicy.hasStopWord(in: "Moe"))
        #expect(!TurnPolicy.hasStopWord(in: "tell me more"))
        // Only the words after the baseline: "stop" earlier in the turn is not new.
        #expect(!TurnPolicy.hasStopWord(in: "please stop the timer then", after: 3))
    }

    // MARK: The judge, before the pause

    /// Moe's own voice scored 0.17 against the owner's enrolment; the owner
    /// 0.60–0.69 in the same minute (VoiceEngine's echo check, 2026-09-04).
    @Test func theOwnersVoiceDecidesFirst() {
        var moeSignals = BargeInJudge.Signals(window: "speaking", words: 2, ownerScore: 0.17, ownerSeconds: 1.2,
                                              levelRatio: 0.9)
        moeSignals.enforceOwner = true
        let moe = BargeInJudge.decide(moeSignals)
        #expect(!moe.taken && moe.check == .ownerVoice)
        // The owner is taken even when the words look like the reply.
        let owner = BargeInJudge.decide(.init(window: "speaking", words: 2, ownerScore: 0.64, ownerSeconds: 1.2,
                                              echoSimilarity: 0.95, heard: "the meeting is on", levelRatio: 0.2))
        #expect(owner.taken && owner.check == .ownerVoice)
    }

    @Test func withoutAClearOwnerScoreTheEchoThenTheLevelDecide() {
        let echo = BargeInJudge.decide(.init(window: "speaking", words: 4, ownerScore: 0.42, ownerSeconds: 1.2,
                                             echoSimilarity: 0.85, heard: "the meeting is on", levelRatio: 0.9))
        #expect(!echo.taken && echo.check == .echoText)
        let far = BargeInJudge.decide(.init(window: "speaking", words: 2, echoSimilarity: 0.4, levelRatio: 0.2))
        #expect(!far.taken && far.check == .loudness)
        let near = BargeInJudge.decide(.init(window: "speaking", words: 2, echoSimilarity: 0.4, levelRatio: 0.9))
        #expect(near.taken && near.check == .loudness)
        let blind = BargeInJudge.decide(.init(window: "speaking", words: 2))
        #expect(blind.taken && blind.check == .noSignal)
    }

    /// A second person can join by asking for Moe, and "Moe, stop" is never
    /// refused on a noisy score.
    @Test func theNameAlwaysGetsThrough() {
        let named = BargeInJudge.decide(.init(window: "speaking", words: 1, named: true,
                                              ownerScore: 0.2, echoSimilarity: 0.9, levelRatio: 0.1))
        #expect(named.taken)
    }

    /// The fragments that arrive before a pause are one or two words — the
    /// size `EchoFilter.isEcho`'s windowed check skipped (12 characters).
    /// Measured: Moe said "Sure, take your time." and the recogniser heard
    /// "Sugar take me".
    @Test func aShortFragmentOfTheSentencePlayingIsEcho() {
        let playing = "Sure, take your time. I'll wait."
        #expect(EchoFilter.windowSimilarity("take your", playing) >= 0.8)
        #expect(EchoFilter.windowSimilarity("your time", playing) >= 0.8)
        #expect(EchoFilter.windowSimilarity("stop now", playing) < 0.8)
        #expect(EchoFilter.windowSimilarity("what about tuesday", playing) < 0.8)
    }

    // MARK: After a false stop

    @Test func aShortHoldResumesInPlaceALongOneRestartsTheSentence() {
        #expect(ReplyResume.after(pausedFor: 0.4) == .inPlace)
        #expect(ReplyResume.after(pausedFor: 2.99) == .inPlace)
        #expect(ReplyResume.after(pausedFor: 3.0) == .restartSentence)
        #expect(ReplyResume.after(pausedFor: 6) == .restartSentence)
    }

    // MARK: The duck

    @Test func theDuckFallsFastAndComesBackSlowly() {
        let down = DuckRamp.steps(from: 1, to: DuckRamp.duckedGain, duration: DuckRamp.downSeconds)
        #expect(abs(20 * log10(Double(down.last!.gain)) - -13.98) < 0.01)   // −14 dB
        #expect(down.last!.t <= 0.05 && down.last!.t >= 0.03)
        #expect(zip(down, down.dropFirst()).allSatisfy { $0.gain > $1.gain })
        let up = DuckRamp.steps(from: DuckRamp.duckedGain, to: 1, duration: DuckRamp.upSeconds)
        #expect(abs(up.last!.t - 0.2) < 1e-9 && up.last!.gain == 1)
        #expect(zip(up, up.dropFirst()).allSatisfy { $0.gain < $1.gain })
        // Linear in decibels: halfway through, halfway in dB (−7 dB), not
        // halfway in gain (0.6, which is −4.4 dB and sounds like no duck yet).
        let mid = DuckRamp.gain(from: 1, to: DuckRamp.duckedGain, duration: 0.04, at: 0.02)
        #expect(abs(20 * log10(Double(mid)) - -6.99) < 0.05)
    }
}
