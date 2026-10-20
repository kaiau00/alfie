import Foundation
import Testing
@testable import MoeVoice

/// `VOICE-DEEP-DIVE-2026-10-06.md`, slice A: each case is a measured incident
/// from the owner's logs.
struct QuietTurnPolicyTests {

    // MARK: inventions out of silence

    @Test func silenceReadAsWordsIsDropped() {
        // 09-30 23:45:36: "jedna" at level 0.001 reached the brain.
        #expect(QuietTurnPolicy.isInvented(text: "jedna", confidence: 0.41, level: 0.001))
        #expect(QuietTurnPolicy.isInvented(text: "Thank you", confidence: 0.83, level: 0.004))
        #expect(QuietTurnPolicy.isInvented(text: "Yeah", confidence: nil, level: 0.002))
    }

    @Test func aQuietButSureReadStands() {
        #expect(!QuietTurnPolicy.isInvented(text: "what time is it", confidence: 0.92, level: 0.004))
        #expect(!QuietTurnPolicy.isInvented(text: "okay", confidence: 0.4, level: 0.03))
        #expect(!QuietTurnPolicy.isInvented(text: "", confidence: 0.1, level: 0.001))
    }

    // MARK: an empty, unsure re-read does not erase real live words

    @Test func theLiveSentenceSurvivesAnEmptyGuess() {
        // 09-24 17:15:22, replayed.
        #expect(QuietTurnPolicy.liveWordsOutrankEmptyRead(
            read: "", readConfidence: 0.10,
            live: "let's keep going and other things in the meantime", level: 0.05))
    }

    @Test func silenceStillBeatsTheLiveRecogniser() {
        // The rule an empty read stands exists for this: a door, at level 0.002.
        #expect(!QuietTurnPolicy.liveWordsOutrankEmptyRead(
            read: "", readConfidence: 0.10, live: "and then the other one", level: 0.002))
        // A confident empty read stands too, and so does a short live guess.
        #expect(!QuietTurnPolicy.liveWordsOutrankEmptyRead(
            read: "", readConfidence: 0.9, live: "let's keep going and other things", level: 0.05))
        #expect(!QuietTurnPolicy.liveWordsOutrankEmptyRead(
            read: "", readConfidence: 0.1, live: "yeah okay", level: 0.05))
        #expect(!QuietTurnPolicy.liveWordsOutrankEmptyRead(
            read: "keep going", readConfidence: 0.1, live: "let's keep going and other things", level: 0.05))
    }

    @Test func silenceIsTheRoomNotTheCloud() {
        #expect(QuietTurnPolicy.isSilent(rms: 0.004))
        #expect(!QuietTurnPolicy.isSilent(rms: 0.054))
    }

    // MARK: onsets

    @Test func anOnsetTheVoiceDetectorBarelyHeardIsTheRoom() {
        #expect(!QuietTurnPolicy.onsetSoundsLikeSpeech(meanVad: 0.51, chunks: 12))
        #expect(QuietTurnPolicy.onsetSoundsLikeSpeech(meanVad: 0.82, chunks: 12))
        // Too few chunks to judge: words decide, as before.
        #expect(QuietTurnPolicy.onsetSoundsLikeSpeech(meanVad: 0.3, chunks: 2))
        #expect(QuietTurnPolicy.onsetSoundsLikeSpeech(meanVad: nil, chunks: 0))
    }
}

struct WakeOwnerCheckTests {

    /// The owner, refused at 0.3 and let through on the retry seconds later:
    /// −0.14 … 0.29. None of them is refused now unless the head was unsure too.
    @Test func theOwnersOwnScoresNoLongerRefuse() {
        for voice: Float in [0.29, 0.26, 0.18, 0.10, 0.07, -0.08] {
            #expect(!WakeOwnerCheck.refuses(head: 0.56, voice: voice))
        }
        #expect(!WakeOwnerCheck.refuses(head: 0.56, voice: -0.14))
    }

    @Test func clearlySomeoneElseOnAWeakWakeIsStillRefused() {
        #expect(WakeOwnerCheck.refuses(head: 0.30, voice: -0.2))
    }

    @Test func noWordlessFinishRightAfterTheName() {
        #expect(!WakeOwnerCheck.mayFinishWordless(sinceWake: 0.9))
        #expect(WakeOwnerCheck.mayFinishWordless(sinceWake: 2.5))
        #expect(WakeOwnerCheck.mayFinishWordless(sinceWake: nil))
    }
}

/// The window after a reply that asked something.
struct FollowUpAfterQuestionTests {

    private func spokenReply(asked: Bool) -> [VoiceMachine.Action] {
        var m = VoiceMachine()
        m.tuning.conversation = true
        _ = m.handle(.setWake(false))
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return [] }
        _ = m.handle(.transcribed(turn: turn, "book a table"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.replyEndedWithQuestion(asked))
        return m.handle(.ttsDrained)
    }

    @Test func aQuestionGetsLongerToAnswer() {
        #expect(spokenReply(asked: true).contains(.armTimer(.followUp, seconds: 12)))
    }

    @Test func aStatementKeepsTheUsualWindow() {
        #expect(spokenReply(asked: false).contains(.armTimer(.followUp, seconds: 8)))
    }
}
