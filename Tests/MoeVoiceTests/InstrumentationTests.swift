import Foundation
import Testing
@testable import MoeVoice

/// Step 0 of the conversation-mode plan (~/moe-voice-notes/PLAN.md): the
/// numbers that were never written down. The first token of a reply, why
/// every barge-in was taken or let go, and a clip around every decision.
struct InstrumentationTests {

    typealias M = VoiceMachine
    typealias A = M.Action

    // MARK: First token

    /// 232 of 232 trace rows on the owner's Mac had no first token
    /// (research-eval-harness.md §2, measured 2026-09-23).
    @Test func theFirstTokenIsMarkedOnceAndOnlyForATurnThatAsked() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var t = TurnTrace(source: "wake", startedAt: t0)
        // An interruption's trace: nothing was asked, so a delta is not its answer.
        let early = t.noteFirstToken(at: t0.addingTimeInterval(1))
        #expect(!early)
        #expect(t.firstTokenMs == nil)
        t.submittedMs = 1200
        let first = t.noteFirstToken(at: t0.addingTimeInterval(3.5))
        #expect(first)
        #expect(t.firstTokenMs == 3500)
        // The next delta is not the first.
        let second = t.noteFirstToken(at: t0.addingTimeInterval(4))
        #expect(!second)
        #expect(t.firstTokenMs == 3500)
    }

    // MARK: Every onset ends in exactly one row

    private func speaking(bargeIn: Bool = true) -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = bargeIn
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { return m }
        _ = m.handle(.transcribed(turn: turn, "tell me about rome"))
        _ = m.handle(.speechQueued)
        return m
    }

    private func onsetRows(_ out: [A]) -> [A] {
        out.filter { if case .onsetRejected = $0 { return true }; if case .onsetTaken = $0 { return true }; return false }
    }

    @Test func aSoundThatNeverBecameWordsIsOneRefusedRow() {
        var m = speaking()
        let e145 = m.handle(.speechStarted)
        #expect(onsetRows(e145).isEmpty)
        let r646 = m.handle(.timer(.bargeInHold))
        #expect(onsetRows(r646) == [.onsetRejected(.noWords)])
    }

    @Test func wordsTheJudgeTookAreOneTakenRow() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        let e22 = m.handle(.wordsHeard(2))
        #expect(onsetRows(e22).isEmpty)          // judging, not decided
        let r938 = m.handle(.bargeInJudged(true))
        #expect(onsetRows(r938) == [.onsetTaken(.judged)])
    }

    @Test func wordsOverThinkingAreTakenByTheWords() {
        var parked = M()
        parked.tuning.conversation = true
        parked.tuning.bargeIn = true
        _ = parked.handle(.toggle); _ = parked.handle(.speechStarted); _ = parked.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = parked.state else { Issue.record("\(parked.state)"); return }
        _ = parked.handle(.transcribed(turn: turn, "what's the weather"))
        _ = parked.handle(.speechQueued)
        _ = parked.handle(.ttsDrained)                                // audio ran out, brain still writing
        #expect(parked.state == .thinking(.hotkey))
        _ = parked.handle(.speechStarted)
        let r350 = parked.handle(.wordsHeard(2))
        #expect(onsetRows(r350) == [.onsetTaken(.overThinking)])
    }

    @Test func goingOnBeforeTheReplyIsATakenContinuation() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.turnModel = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "remind me tomorrow"))
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechStarted)
        let r385 = m.handle(.wordsGrew)
        #expect(onsetRows(r385) == [.onsetTaken(.continuation)])
    }

    /// The key going down over a ducked reply: nothing decided the onset,
    /// and it still leaves a row saying so.
    @Test func anOnsetOvertakenByTheKeyIsStillARow() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        let r278 = m.handle(.holdDown)
        #expect(onsetRows(r278) == [.onsetRejected(.superseded)])
    }

    // MARK: Which check decided

    @Test func theJudgeSaysWhichCheckDecided() {
        let quiet = BargeInJudge.loudness(window: "speaking", words: 2, levelRatio: 0.2)
        #expect(!quiet.taken && quiet.check == .loudness)
        let loud = BargeInJudge.loudness(window: "speaking", words: 2, levelRatio: 0.9)
        #expect(loud.taken && loud.check == .loudness)
        let blind = BargeInJudge.loudness(window: "speaking", words: 1, levelRatio: nil)
        #expect(blind.taken && blind.check == .noSignal)
        #expect(quiet.logLine == "barge-in over speaking: refused by loudness (words 2, level 0.20)")
        var row = TurnTrace(source: "onset")
        quiet.stamp(&row)
        #expect(row.bargeInTaken == false)
        #expect(row.bargeInCheck == "loudness")
        #expect(row.bargeInLevel == 0.2)
    }

    // MARK: Clips around decisions

    @Test func aClipIsCutAroundItsDecision() {
        let before = [Float](repeating: 0.1, count: 16_000 * 12)     // 12 s of turn
        let after = [Float](repeating: 0.2, count: 16_000 * 3)
        let clip = VoiceDebug.decisionClip(before: before, after: after)
        #expect(clip.decidedAt == 8.0)
        #expect(clip.samples.count == 16_000 * (8 + 2) + 8_000)
        #expect(clip.samples[16_000 * 8 - 1] == 0.1)
        #expect(clip.samples[16_000 * 8] == 0.2)
        // A short turn keeps all of itself.
        let short = VoiceDebug.decisionClip(before: [Float](repeating: 0, count: 16_000), after: after)
        #expect(short.decidedAt == 1.0)
    }

    @Test func aClipAndItsSidecarArePrunedTogether() {
        let stored = [
            VoiceDebug.Stored(name: "20260923T100000.000Z-turn-stall.json", bytes: 1),
            VoiceDebug.Stored(name: "20260923T100000.000Z-turn-stall.wav", bytes: 60),
            VoiceDebug.Stored(name: "20260923T110000.000Z-turn-vad.wav", bytes: 60),
            VoiceDebug.Stored(name: "20260923T110000.000Z-turn-vad.json", bytes: 1),
        ]
        // One byte over: deleting the old sidecar alone would fit, and
        // would leave its clip behind unlabelled.
        let gone = VoiceDebug.prune(stored, incoming: 29, cap: 150)
        #expect(Set(gone) == ["20260923T100000.000Z-turn-stall.json", "20260923T100000.000Z-turn-stall.wav"])
    }

    @Test func aSidecarCarriesTheDecisionNotTheWords() throws {
        let d = BargeInDecision(window: "speaking", taken: false, check: .echoText, words: 1, echoSimilarity: 0.71)
        let side = VoiceDebug.Sidecar(kind: "barge-in", reason: "rejected-not-for-moe",
                                      decidedAtSeconds: 3.2, clipSeconds: 5.7, bargeIn: d)
        let json = String(decoding: side.json(), as: UTF8.self)
        #expect(json.contains("\"check\":\"echo-text\""))
        #expect(!json.contains("text\":"))
        let back = try JSONDecoder().decode(VoiceDebug.Sidecar.self, from: side.json())
        #expect(back == side)
    }

    // MARK: The reply floor is the machine's

    @Test func aTurnModelDecisionHoldsTheReplyAndNoOtherDoes() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.turnModel = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        let out = m.handle(.turnVerdict(complete: true))
        let decided = out.firstIndex(of: .decided(.turnModel))
        let held = out.firstIndex(of: .holdReply(seconds: 0.8))
        #expect(decided != nil && held != nil && held! == decided! + 1)

        var k = M()
        _ = k.handle(.holdDown)
        let up = k.handle(.holdUp)
        #expect(!up.contains { if case .holdReply = $0 { return true }; return false })
    }
}
