import Foundation
import Testing
@testable import MoeVoice

/// The turn that vanished on 2026-09-09, and the two facts that let it.
///
/// The owner held the key and dictated an email for 59.6 seconds. The words
/// appeared on the island as he spoke. Then nothing: no reply, no
/// transcript, no trace. `TurnReadDeadlineTests` guards the first fact —
/// the turn gave up on its own re-read before the cloud's deadline was
/// anywhere near. These guard the second, which is the one that made it
/// silent: a re-read that *never answered* was handled as a re-read that
/// *answered with nothing*, and an answer of nothing correctly overrules
/// the live recogniser. So a minute of correctly heard speech was thrown
/// away by a rule written for silence.
struct LostTurnTests {

    // MARK: The rule that was missing

    @Test func aReadThatNeverCameBackFallsBackToWhatWasHeardLive() {
        let live = "can you send me the whole email about the meeting tomorrow"
        #expect(TurnPolicy.transcript(read: .neverAnswered, live: live) == live)
    }

    /// The distinction the old code could not make. Both of these were an
    /// empty string; only one of them may drop the turn.
    @Test func silenceAndAWedgedModelAreNotTheSameOutcome() {
        let live = "can you send me the whole email"
        #expect(TurnPolicy.transcript(read: .answered(""), live: live) == "",
                "a model that ran and heard nothing still overrules the live recogniser")
        #expect(TurnPolicy.transcript(read: .neverAnswered, live: live) == live,
                "a model that never ran must not overrule anything")
    }

    /// The rule the fallback must not break: when the accurate read *did*
    /// answer, its words are the turn's, live text or no live text. This is
    /// what keeps a door, a cough, or the tail of somebody else's sentence
    /// from reaching the brain.
    @Test func anAnswerAlwaysWins() {
        #expect(TurnPolicy.transcript(read: .answered("what time is it"),
                                      live: "wut time izzit") == "what time is it")
        #expect(TurnPolicy.transcript(read: .answered("what time is it"),
                                      live: "") == "what time is it")
    }

    /// A wedged read with nothing heard live is still a dropped turn —
    /// there is nothing to fall back to, and inventing something would be
    /// worse than silence.
    @Test func nothingHeardLiveStillMeansNothing() {
        #expect(TurnPolicy.transcript(read: .neverAnswered, live: "").isEmpty)
        #expect(TurnPolicy.transcript(read: .neverAnswered, live: "   \n ").isEmpty == false,
                "whitespace is passed through as-is; the emptiness test is the caller's")
        #expect(!TurnPolicy.fellBackToLiveWords(read: .neverAnswered, live: "   \n "))
    }

    // MARK: The log line

    /// The two cases have to be distinguishable in the log, because "the
    /// accurate read is failing and turns are quietly running on the
    /// rougher one" is a thing somebody has to be able to notice.
    @Test func theFallbackIsReportable() {
        #expect(TurnPolicy.fellBackToLiveWords(read: .neverAnswered, live: "send the email"))
        #expect(!TurnPolicy.fellBackToLiveWords(read: .neverAnswered, live: ""))
        #expect(!TurnPolicy.fellBackToLiveWords(read: .answered(""), live: "send the email"),
                "an answered read is not a fallback, however empty")
    }

    // MARK: The whole incident, end to end

    /// The turn as it actually happened, with the numbers from the log:
    /// 59.6 s of audio, the cloud answering at 43.636 s, the words already
    /// on the island. Under the shipped code this produced `heard: ""`.
    @Test func theEmailDictationWouldNowGoThrough() {
        let audioSeconds = 59.6
        let cloudAnsweredAt = 43.636
        let live = "can you send me the whole email"

        let deadline = TurnReadDeadline.seconds(forAudioSeconds: audioSeconds)
        // First line of defence: the turn is still waiting when the answer
        // arrives, so the real transcript is used and no fallback is needed.
        #expect(deadline > cloudAnsweredAt)

        // Second line: even if it had timed out, the turn is not lost.
        #expect(TurnPolicy.transcript(read: .neverAnswered, live: live) == live)
    }
}
