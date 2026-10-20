import Foundation
import Testing
@testable import MoeVoice

struct AddresseeTests {

    /// The signals a follow-up turn actually carries in production: the
    /// window is open, the person is at the same distance as when they
    /// opened it, and there is no owner enrolment yet.
    private func signals(_ text: String, named: Bool = false, since: Double? = 3,
                         question: Bool = false, level: Float? = 0.8, owner: Float? = nil,
                         seconds: Double = 1.5) -> Addressee.Signals {
        Addressee.Signals(text: text, namedMoe: named, secondsSinceReply: since,
                          moeAskedQuestion: question, levelRatio: level, ownerScore: owner,
                          speechSeconds: seconds)
    }

    // MARK: A long answer straight after the reply

    /// 32 words, begun a second after Moe finished, at the same loudness,
    /// the owner's voice: the turn dropped on 2026-09-07 once the loudness
    /// was read correctly. Length alone must not sink an answer that
    /// continues the reply.
    @Test func aLongAnswerThatContinuesTheReplyIsForMoe() {
        let long = "I also wanted it to be like you could dress it up a little bit you know like a nice pair of pants and a nice button down you know nice and clean but also good for the trail"
        let v = Addressee.verdict(signals(long, since: 1, level: 0.93, owner: 0.85, seconds: 10.5))
        #expect(v == .directed)
    }

    /// The same words six seconds later, no owner match: still a lean
    /// away — the original reason for the length rule stands.
    @Test func aLongPassageLongAfterTheReplyStillLeansAway() {
        let long = "I also wanted it to be like you could dress it up a little bit you know like a nice pair of pants and a nice button down you know nice and clean but also good for the trail"
        let v = Addressee.verdict(signals(long, since: 8, level: 0.5, owner: nil, seconds: 10.5))
        #expect(v != .directed)
    }

    // MARK: Certain, on the words alone

    @Test func theNameIsEnoughOnItsOwn() {
        #expect(Addressee.verdict(signals("I think so, moe, but check", since: 9)) == .directed)
        // Stripped off the front by the host, which says so instead.
        #expect(Addressee.verdict(signals("the second one", named: true, since: 9)) == .directed)
        // Even against a voice that does not match the enrolment.
        #expect(Addressee.verdict(signals("moe, open the calendar", owner: 0.2)) == .directed)
    }

    @Test func shortCommandsAreForMoe() {
        // No opener and no name; without this rule they would be ambiguous,
        // and "stop" said to Moe has to work the first time.
        for command in ["stop", "louder", "next", "repeat", "go back", "never mind"] {
            #expect(Addressee.verdict(signals(command, seconds: 0.6)) == .directed, "\(command)")
        }
    }

    @Test func anAnswerToMoesQuestionIsForMoe() {
        #expect(Addressee.verdict(signals("the second one", since: 1.5, question: true)) == .directed)
    }

    // MARK: Certain the other way

    @Test func roomTalkIsNotForMoe() {
        for talk in ["he said the meeting moved to thursday",
                     "hang on, let me just finish this",
                     "I'll be right there",
                     "sorry what did you say"] {
            #expect(Addressee.verdict(signals(talk, since: 5)) == .notDirected, "\(talk)")
        }
    }

    @Test func aQuietTurnFromAcrossTheRoomLeansAway() {
        let near = Addressee.score(signals("did you see this", level: 1.0))
        let far = Addressee.score(signals("did you see this", level: 0.2))
        #expect(near > far)
        // Quiet enough is not proof, but it is enough that the turn is
        // never taken without the judge.
        #expect(Addressee.verdict(signals("did you see this", since: 5, level: 0.2)) != .directed)
        #expect(!Addressee.leansDirected(signals("did you see this", since: 5, level: 0.2)))
    }

    @Test func nothingIsNotForMoe() {
        #expect(Addressee.verdict(signals("")) == .notDirected)
    }

    // MARK: The band in between — a request is a request, whoever it is for

    @Test func aPlainRequestIsUnsureAndLeansTowardsMoe() {
        // "can you send that to Sam" is the same sentence said to Moe and
        // said to a colleague. The rules do not pretend to know; the judge
        // decides where there is one, and the fallback takes it where
        // there is not.
        for request in ["send that to Sam", "read it again", "what about tomorrow?",
                        "okay, what about the other one", "can you pass me the charger"] {
            #expect(Addressee.verdict(signals(request)) == .unsure, "\(request)")
            #expect(Addressee.leansDirected(signals(request)), "\(request)")
        }
    }

    @Test func theSameRequestFromTheWrongVoiceOrTooFarDoesNotLean() {
        #expect(!Addressee.leansDirected(signals("open the calendar", owner: 0.2)))
        #expect(!Addressee.leansDirected(signals("open the calendar", level: 0.3)))
        // A stranger's clear request is unsure, never refused outright.
        #expect(Addressee.verdict(signals("open the calendar", owner: 0.2)) == .unsure)
    }

    @Test func theOwnerVoiceIsASoftSignal() {
        let owner = Addressee.score(signals("open the calendar", owner: 0.8))
        let stranger = Addressee.score(signals("open the calendar", owner: 0.2))
        #expect(owner - stranger > 2)
    }

    // MARK: Other languages

    @Test func aFollowUpInAnotherScriptIsNotAnEmptyTurn() {
        // Hebrew, Russian, Greek: the English cues cannot apply, and
        // scoring against them used to return "nothing was said" — the
        // window swallowed every sentence in those languages.
        for text in ["מה עם מחר", "что насчёт завтра", "τι γίνεται αύριο"] {
            let s = Addressee.Signals(text: text, secondsSinceReply: 3, moeAskedQuestion: false,
                                      levelRatio: 0.8, speechSeconds: 1.5, english: false)
            #expect(Addressee.verdict(s) != .notDirected, "\(text)")
            #expect(Addressee.leansDirected(s), "\(text)")
        }
    }

    @Test func anotherLanguageStillHearsTheRoomAndTheClock() {
        func french(_ level: Float?, owner: Float?, since: Double) -> Addressee.Signals {
            Addressee.Signals(text: "et sinon, on mange où ce soir", secondsSinceReply: since,
                              moeAskedQuestion: false, levelRatio: level, ownerScore: owner,
                              speechSeconds: 2, english: false)
        }
        // Turned away from the Mac, or a voice Moe does not know: still
        // caught, because those signals are not English.
        #expect(!Addressee.leansDirected(french(0.2, owner: nil, since: 5)))
        #expect(!Addressee.leansDirected(french(0.8, owner: 0.2, since: 5)))
        #expect(Addressee.leansDirected(french(0.8, owner: 0.8, since: 1)))
    }

    @Test func theNameIsReadInEveryLanguage() {
        let s = Addressee.Signals(text: "moe, מה השעה", namedMoe: true, secondsSinceReply: 9,
                                  moeAskedQuestion: false, levelRatio: 0.8, speechSeconds: 1.5,
                                  english: false)
        #expect(Addressee.verdict(s) == .directed)
    }

    @Test func aDismissalIsNeverAQuestion() {
        for said in ["I'm not talking to you", "not talking to you, Moe", "stop",
                     "never mind", "sorry, not you", "that's enough", "I wasn't talking to you"] {
            #expect(Addressee.isDismissal(said), "\(said)")
        }
        for keep in ["what did you say", "stop the timer at five", "never mind that, what about friday",
                     "tell me about the not talking problem"] {
            #expect(!Addressee.isDismissal(keep), "\(keep)")
        }
    }

    @Test func aMonologueInTheWindowIsNotForMoe() {
        // Measured: 33 words of the user describing Moe to somebody else
        // scored 0.2 and was kept, and its continuation was answered.
        let long = String(repeating: "and then the thing about the other thing was ", count: 5)
        #expect(Addressee.verdict(signals(long, since: 5)) == .notDirected)
        #expect(!Addressee.leansDirected(signals(long, since: 5)))
        // A long request that names Moe still lands.
        #expect(Addressee.verdict(signals("moe " + long, since: 5)) != .notDirected)
    }

    // MARK: Closing and resolving

    @Test func closePhrases() {
        for goodbye in ["Thanks, Moe.", "okay thanks moe", "that's all, Moe", "thanks a lot Moe",
                        "That’s all for now, Moe", "moe, that's all", "bye moe", "cheers mo"] {
            #expect(Addressee.isClosePhrase(goodbye), "\(goodbye)")
        }
        for keep in ["thanks moe what about friday", "thanks", "no thanks", "moe", "thank you"] {
            #expect(!Addressee.isClosePhrase(keep), "\(keep)")
        }
    }

    @Test func theNameAloneResolvesAnUnsureTurn() {
        #expect(Addressee.isNameOnly("Moe?"))
        #expect(Addressee.isNameOnly("hey moe"))
        #expect(Addressee.isNameOnly("Mo?"))
        #expect(!Addressee.isNameOnly("moe what time is it"))
        #expect(!Addressee.isNameOnly("hey"))
    }
}

/// Every window verdict from 2026-09-16 to 09-29 that went against a turn,
/// with the numbers the log kept (it keeps no words for a turn it judged not
/// for Moe). Six were the owner, loud and close; the rest were the room.
/// With no on-device judge on that Mac, all six were dropped.
struct AddresseeLoggedVerdictTests {

    private func words(_ n: Int) -> String {
        Array(repeating: "and then the thing we talked about", count: n / 7 + 1)
            .joined(separator: " ").split(separator: " ").prefix(n).joined(separator: " ")
    }

    private func signals(_ n: Int, level: Float, owner: Float?, since: Double = 4,
                         question: Bool = false) -> Addressee.Signals {
        Addressee.Signals(text: words(n), secondsSinceReply: since, moeAskedQuestion: question,
                          levelRatio: level, ownerScore: owner, speechSeconds: Double(n) / 2.5)
    }

    /// Taken either by the verdict or, with no judge, by the lean.
    private func taken(_ s: Addressee.Signals) -> Bool {
        switch Addressee.verdict(s) {
        case .directed: return true
        case .unsure: return Addressee.leansDirected(s)
        default: return false
        }
    }

    @Test func theOwnersSixAreTaken() {
        #expect(taken(signals(30, level: 1.62, owner: 0.83)))                 // 09-23 14:31:09
        #expect(taken(signals(15, level: 0.72, owner: 0.54)))                 // 09-23 15:06:34
        // Scored 0.0 in the log: a request shape ("can you …?") under the
        // length penalty.
        var request = signals(65, level: 1.19, owner: nil)                   // 09-24 21:33:23
        request.text = "can you " + words(62) + "?"
        #expect(Addressee.score(request) == 0)
        #expect(taken(request))
        #expect(taken(signals(136, level: 0.83, owner: 0.92)))                // 09-25 13:53:22
        #expect(taken(signals(10, level: 0.93, owner: nil)))                  // 09-25 14:35:48
        #expect(taken(signals(77, level: 0.48, owner: 0.57, question: true))) // 09-29 20:45:06
    }

    @Test func theRoomIsStillLetGo() {
        let room: [(Int, Float, Float?)] = [
            (4, 0.18, 0.21), (18, 0.37, 0.20), (3, 0.08, nil), (3, 0.02, -0.02), (4, 0.02, 0.23),
            (25, 0.11, nil), (3, 0.23, nil), (5, 0.01, nil), (3, 0.01, nil), (6, 0.02, 0.09),
            (3, 0.03, nil), (3, 0.06, 0.16), (6, 0.13, 0.23), (4, 0.11, 0.19), (5, 0.04, nil),
            (3, 0.06, 0.22), (7, 0.04, 0.11),
        ]
        for (n, level, owner) in room {
            #expect(!Addressee.ownerAtTheMic(signals(n, level: level, owner: owner)),
                    "\(n) words at \(level)× with owner \(owner.map { "\($0)" } ?? "-")")
        }
    }
}

/// 2026-09-29 22:08: the owner's own 76 words, dropped as "another voice"
/// on one noisy embedding. The anchor may not overrule a turn that is loud
/// as the person is, or that matches their enrolled voice.
struct AnchorOverruleTests {

    private func signals(level: Float?, owner: Float?) -> Addressee.Signals {
        Addressee.Signals(text: "how much would that cost me and also someone like prolific",
                          secondsSinceReply: 5, moeAskedQuestion: false,
                          levelRatio: level, ownerScore: owner, speechSeconds: 20)
    }

    @Test func aLoudTurnOrTheEnrolledVoiceIsNotDroppedOnTheAnchor() {
        #expect(Addressee.anchorOverruled(signals(level: 1.1, owner: nil)))
        #expect(Addressee.anchorOverruled(signals(level: 0.3, owner: 0.7)))
    }

    @Test func aQuietUnknownVoiceStillIs() {
        #expect(!Addressee.anchorOverruled(signals(level: 0.3, owner: 0.2)))
        #expect(!Addressee.anchorOverruled(signals(level: nil, owner: nil)))
    }
}
