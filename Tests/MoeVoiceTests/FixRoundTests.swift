import Foundation
import Testing
@testable import MoeVoice

/// The fixes from the skeptical review of the voice-turns branch
/// (~/moe-voice-notes/voice-turns-review.md). Each test names its item.
struct FixRoundTests {

    typealias M = VoiceMachine
    typealias S = BargeInJudge.Signals

    // MARK: H1 — a one-word "no" is not Moe's echo

    /// Moe says "I don't know if the meeting is on Friday"; the owner says
    /// "No." A character match finds "no" inside "know" at 1.0.
    @Test func noWhileMoeSaysKnowIsTaken() {
        let playing = "I don't know if the meeting is on Friday"
        let echo = EchoFilter.windowSimilarity("no", playing)
        #expect(echo >= 0.8)            // the measurement that used to refuse it
        let d = BargeInJudge.decide(S(window: "speaking", words: 1, urgent: true,
                                      echoSimilarity: echo, heard: "no", levelRatio: 0.9))
        #expect(d.taken)
        // A quiet "no" (a person a step back): taken on the exemption alone —
        // this is the line that goes red if only the exemption is reverted.
        let quiet = BargeInJudge.decide(S(window: "speaking", words: 1, urgent: true,
                                          echoSimilarity: echo, heard: "no", levelRatio: 0.2))
        #expect(quiet.taken)
        // Even not counted as a stop word, two short words are too little to call echo.
        let two = BargeInJudge.decide(S(window: "speaking", words: 2,
                                        echoSimilarity: EchoFilter.windowSimilarity("the meet", playing),
                                        heard: "the meet", levelRatio: 0.9))
        #expect(two.taken)
    }

    @Test func aRealStretchOfMoesSentenceIsStillEcho() {
        let playing = "I don't know if the meeting is on Friday"
        let heard = "the meeting is on"
        let d = BargeInJudge.decide(S(window: "speaking", words: 4,
                                      echoSimilarity: EchoFilter.windowSimilarity(heard, playing),
                                      heard: heard, levelRatio: 0.9))
        #expect(!d.taken && d.check == .echoText)
    }

    // MARK: H2 — the owner check only refuses on enough of the person, decisively

    @Test func theOwnerScoreRefusesOnlyWhenDecisiveOnASecondOfTheirOwnAudio() {
        // Decisive, on enough audio, and enforcing: refused.
        var enforced = S(window: "speaking", words: 2, ownerScore: 0.12, ownerSeconds: 1.2, levelRatio: 0.9)
        enforced.enforceOwner = true
        #expect(!BargeInJudge.decide(enforced).taken)
        // Not enforcing (the default, review N4): written down, not acted on.
        let shadow = BargeInJudge.decide(S(window: "speaking", words: 2, ownerScore: 0.12, ownerSeconds: 1.2,
                                           levelRatio: 0.9))
        #expect(shadow.taken && shadow.ownerWouldRefuse == true)
        // A middling score (the mix of a second of speech and the room): the words and level decide.
        let middling = BargeInJudge.decide(S(window: "speaking", words: 2, ownerScore: 0.3, ownerSeconds: 1.2,
                                             levelRatio: 0.9))
        #expect(middling.taken && middling.check == .loudness)
        // Too little of the person: the score says nothing.
        let short = BargeInJudge.decide(S(window: "speaking", words: 2, ownerScore: 0.12, ownerSeconds: 0.7,
                                          levelRatio: 0.9))
        #expect(short.taken)
        // A stop word is taken before any score is read.
        var stop = S(window: "speaking", words: 1, urgent: true, ownerScore: 0.05, ownerSeconds: 1.5, levelRatio: 0.1)
        stop.enforceOwner = true
        #expect(BargeInJudge.decide(stop).taken)
    }

    // MARK: H3 — the owner gate records until it is told to act

    @Test func theOwnerGateOnlyRecordsUnlessEnforcing() {
        #expect(OwnerGate.outcome(.notOwner, enforce: false, continuation: false) == .shadow)
        #expect(OwnerGate.outcome(.notOwner, enforce: true, continuation: false) == .drop)
        // Never on the rest of a turn the session already accepted.
        #expect(OwnerGate.outcome(.notOwner, enforce: true, continuation: true) == .pass)
        #expect(OwnerGate.outcome(.letThrough, enforce: true, continuation: false) == .pass)
    }

    // MARK: H5 — the mid-clause ceiling stays six seconds from the verdict

    /// "…let me think about this a second. Yeah, can you um" — p=0.01 and cut
    /// by a timer; the 6 s ceiling was set for exactly that.
    @Test func theMidClauseCeilingIsStillSixSeconds() {
        let e = EndpointPolicy.Evidence(p: 0.01, text: "yeah can you um", pauseSoFar: 0.6)
        let plan = EndpointPolicy.fitted.plan(e, onStall: false)
        #expect(plan.decideIn >= 6.0)
        #expect(plan.reason == .ceiling)
    }

    // MARK: M1 — the brain never runs long ahead of the reply

    @Test func theReplyIsNeverHeldLongerThanTheBrainHadBefore() {
        for p in [0.2, 0.3, 0.45, 0.6, 0.97] {
            let plan = EndpointPolicy.fitted.plan(.init(p: p, text: "book a table for two", pauseSoFar: 0.35),
                                                  onStall: false)
            #expect(plan.hold <= 0.8 + 1e-9, "p=\(p) hold \(plan.hold)")
        }
    }

    // MARK: M2 — a stop word by revision

    @Test func aStopWordTheRecogniserRevisedToIsReported() {
        var r = WordReport()
        let first = r.update(text: "know", baseline: 0, countNods: false)
        #expect(first?.words == 1 && first?.urgent == false)
        let revised = r.update(text: "no", baseline: 0, countNods: false)
        #expect(revised?.words == 1 && revised?.urgent == true)
        #expect(r.update(text: "no", baseline: 0, countNods: false) == nil)
    }

    // MARK: M3 — a beat between the two words

    @Test func aFirstWordOverTheReplyBuysTheSecondOneTime() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "tell me about rome"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        let one = m.handle(.wordsHeard(1))                           // "Actually…"
        #expect(one.contains(.armTimer(.bargeInHold, seconds: 1.0)))
        let again = m.handle(.wordsHeard(1))                         // the same word, re-sent
        #expect(!again.contains(.armTimer(.bargeInHold, seconds: 1.0)))
        let beat = m.handle(.timer(.bargeInHold))
        #expect(beat.contains(.onsetRejected(.noWords)))              // once, not forever
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        let two = m.handle(.wordsHeard(2))                            // "…what about"
        #expect(two.contains(.judgeBargeIn))
    }

    // MARK: M4 — the name, as the recogniser writes it

    @Test func theNameInTheWaysItIsWritten() {
        for said in ["alfie stop", "Alfie, stop.", "Alfie's wrong", "Alpha, wait", "hey alpha stop", "elfie hold on",
                     "heyalfie stop", "alfie"] {
            #expect(NameMatch.namesMoe(said), "\(said)")
        }
        for said in ["the alpha version is out", "more please", "tomorrow", "stop", ""] {
            #expect(!NameMatch.namesMoe(said), "\(said)")
        }
    }

    // MARK: M5 — only a continuation onset holds the reply

    @Test func aSoundOverAHeldKeyTurnsWaitDoesNotHoldTheReply() {
        var m = M()
        m.tuning.bargeIn = true
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "what's the weather"))
        #expect(m.state == .thinking(.hold))
        _ = m.handle(.speechStarted)
        #expect(m.awaitingWords)
        #expect(!m.awaitingContinuationWords)

        var c = M()
        c.tuning.conversation = true
        c.tuning.turnModel = true
        _ = c.handle(.toggle); _ = c.handle(.speechStarted); _ = c.handle(.wordsHeard(3))
        _ = c.handle(.speechEnded); _ = c.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let t2) = c.state else { Issue.record("\(c.state)"); return }
        _ = c.handle(.transcribed(turn: t2, "remind me tomorrow"))
        _ = c.handle(.speechStarted)
        #expect(c.awaitingContinuationWords)
    }

    // MARK: M7 — resume in place can actually happen

    @Test func aFalseAlarmResolvedWithinThreeSecondsResumesInPlace() {
        // pause → the person stops → VAD end (≤0.5 s) → decision → read (0.4 s p90) → checks
        #expect(ReplyResume.after(pausedFor: 2.2) == .inPlace)
        #expect(ReplyResume.after(pausedFor: 3.0) == .restartSentence)
    }
}
