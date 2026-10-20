import Foundation
import Testing
@testable import MoeVoice

/// Muting yourself mid-conversation — and it staying muted.
///
/// The owner, 2026-09-23: *"let's say you're in conversational mode in Moe
/// and it's in the middle of a task — if you say anything you will interrupt
/// it, so you should be able to mute yourself or something."*
///
/// The owner, 2026-09-24: mute is **sticky** until pressed again. That day
/// the log shows six mutes between 16:47 and 17:16, and each one switched
/// off under him at the end of the reply ("voice: unmuted — the reply is
/// done, listening again", 22285fa1).
///
/// | while muted | what happens |
/// |---|---|
/// | words over the work or the reply | nothing — they are not heard |
/// | "Hey Moe" over the reply | nothing |
/// | the reply ends and the window opens | **still muted**; the window waits, it does not time out |
/// | the owner talks in that window | nothing heard, and the window does not close under them |
/// | the muted window is left alone for 10 min | it closes, and says why |
/// | the mute button | unmutes: the window listens its full 8 s from now |
/// | the talk key held | talks *through* the mute; muted again when it comes up |
/// | a tap of the talk key (pause) | pauses the reply; still muted |
/// | the hotkey | unmutes (hands-free: nothing to talk through with) |
/// | the conversation ends | unmuted, so the wake word is not left dead |
struct MutingYourselfTests {

    typealias M = VoiceMachine

    private func machine() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        m.tuning.wakeHead = true
        m.tuning.offerToCloseAfter = 5
        _ = m.handle(.setWake(true))
        return m
    }

    private func toThinking(_ m: inout M) {
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "book the flights"))
        #expect(m.state == .thinking(.hotkey))
    }

    /// Reply plays and is heard to its end. Returns the drain's actions.
    @discardableResult
    private func replyEnds(_ m: inout M) -> [M.Action] {
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        return m.handle(.ttsDrained)
    }

    private func causes(_ out: [M.Action]) -> [M.MuteCause] {
        out.compactMap { if case .muteCause(let c) = $0 { return c } else { return nil } }
    }

    private func armed(_ out: [M.Action], _ kind: M.TimerKind) -> Double? {
        for a in out { if case .armTimer(let k, let s) = a, k == kind { return s } }
        return nil
    }

    // MARK: - Nothing heard

    @Test func wordsOverTheWorkDoNotInterruptIt() {
        var m = machine()
        toThinking(&m)
        #expect(m.handle(.setMuted(true)).contains(.micMuted(true)))
        var out = m.handle(.speechStarted)
        out += m.handle(.wordsHeard(4))
        out += m.handle(.wordsGrew)
        out += m.handle(.endOfUtterance("hold on, who's at the door"))
        #expect(out.isEmpty, "nothing the room says gets in")
        #expect(m.state == .thinking(.hotkey), "the task carries on")
    }

    @Test func wordsAndTheNameOverTheReplyDoNotStopIt() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.setMuted(true))
        var out = m.handle(.speechStarted)
        out += m.handle(.wordsHeard(3))
        out += m.handle(.woke)
        #expect(!out.contains(.stopSpeaking))
        #expect(!out.contains(.duckSpeech(true)))
        #expect(!out.contains(.judgeBargeIn))
        #expect(m.state == .speaking(.hotkey))
    }

    /// Muted means the microphone's work stops too — no transcript of the
    /// room is kept, and the name is not listened for.
    @Test func mutingSwitchesListeningOff() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        let out = m.handle(.setMuted(true))
        #expect(!out.contains(.asr(true)))
        #expect(out.contains(.wake(false)), "the head listens for the name over a reply; not now")
    }

    /// Muting while an interruption is already being listened to: it was
    /// not one. The reply goes on as after any false alarm.
    @Test func mutingOverAnInterruptionPutsTheReplyBack() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))                 // ducked, waiting on the second word
        let out = m.handle(.setMuted(true))
        #expect(out.contains(.duckSpeech(false)))
        #expect(!out.contains(.abandonReply))
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func mutingOverAWordsAbandonCaptureKeepsTheWork() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(3))                 // real words over the wait
        guard case .capturing = m.state else { Issue.record("not capturing: \(m.state)"); return }
        let out = m.handle(.setMuted(true))
        #expect(!out.contains(.abandonReply))
        #expect(m.state == .thinking(.hotkey), "back to working on it")
    }

    /// Muted while Moe waits for the first words of a turn: the conversation
    /// stays open and waits. Closing it would end the mute with it — the
    /// mute switching itself off, by another road.
    @Test func mutingWhileMoeWaitsKeepsTheConversationAndTheMute() {
        var m = machine()
        _ = m.handle(.toggle)
        #expect(m.state == .attending(.hotkey))
        let out = m.handle(.setMuted(true))
        #expect(m.state == .followUp)
        #expect(m.muted)
        #expect(!out.contains(.conversationEnded))
        #expect(armed(out, .followUp) == m.tuning.mutedWindowSeconds)
    }

    // MARK: - Today's log, replayed (2026-09-24 16:47–16:58)

    /// Muted over the reply (16:47:04); the reply ends (16:47:32) — it used
    /// to unmute here. Now: still muted, the window waits, nothing the owner
    /// says is heard and nothing closes; a second answer through the talk
    /// key, and still muted after that one too; then the button, and Moe
    /// listens.
    @Test func todaysSequenceMuteStaysOnUntilPressedAgain() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        let mute = m.handle(.setMuted(true))                       // 16:47:04
        #expect(causes(mute) == [.button])

        let drained = replyEnds(&m)                                // 16:47:32
        #expect(m.state == .followUp)
        #expect(m.muted, "the end of the reply does not unmute")
        #expect(!drained.contains(.micMuted(false)))
        #expect(causes(drained).isEmpty, "mute did not change")
        #expect(!drained.contains(.asr(true)), "the window is not listened to")
        #expect(armed(drained, .followUp) == m.tuning.mutedWindowSeconds,
                "the window waits; it does not time out in 8 s")
        #expect(armed(drained, .offerToClose) == nil, "no offer they cannot answer")

        // The owner talks, muted (16:47:34 was heard only because of the
        // auto-unmute). Nothing reaches the machine; nothing closes.
        var said = m.handle(.speechStarted)
        said += m.handle(.wordsHeard(3))
        said += m.handle(.endOfUtterance("um yeah let's do that"))
        #expect(said.isEmpty)
        #expect(m.state == .followUp)
        #expect(m.handle(.timer(.offerToClose)).isEmpty)

        // A turn through the talk key (talks through the mute), answered —
        // and still muted after that answer too.
        _ = m.handle(.holdDown)
        #expect(m.state == .capturing(.hold))
        _ = m.handle(.speechStarted)
        _ = m.handle(.holdUp)
        guard case .deciding(.hold, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "move on to the next one"))
        let second = replyEnds(&m)
        #expect(m.state == .followUp)
        #expect(m.muted, "a second answer does not unmute either")
        #expect(armed(second, .followUp) == m.tuning.mutedWindowSeconds)

        // The button, again: listening, the full window from now.
        let unmute = m.handle(.setMuted(false))
        #expect(unmute.contains(.micMuted(false)))
        #expect(causes(unmute) == [.button])
        #expect(unmute.contains(.asr(true)))
        #expect(armed(unmute, .followUp) == m.tuning.followUpSeconds)
        _ = m.handle(.speechStarted)
        guard case .capturing(.followUp) = m.state else {
            Issue.record("no capture after unmuting: \(m.state)"); return
        }
    }

    // MARK: - The old bug stays fixed (2026-09-23 22:15–22:21)

    /// Muted for a five-minute browser task; the reply ended; they answered;
    /// the window timed out under them with nothing heard. Under sticky mute
    /// the window never times out while muted — the only clock is the
    /// 10-minute cap — and unmuting gives it its full length, listening.
    @Test func aMutedWindowNeverClosesUnderTheOwner() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.setMuted(true))            // 22:15:33
        let drained = replyEnds(&m)              // 22:21:27
        #expect(m.state == .followUp)
        #expect(armed(drained, .followUp) == m.tuning.mutedWindowSeconds)
        #expect(m.tuning.mutedWindowSeconds >= 300, "generous: minutes, not seconds")

        let unmute = m.handle(.setMuted(false))  // they press it, and answer
        #expect(armed(unmute, .followUp) == m.tuning.followUpSeconds)
        let onset = m.handle(.speechStarted)     // "Got it. Is there…"
        #expect(onset.contains(.cancelTimer(.followUp)), "the window cannot close under them")
        guard case .capturing(.followUp) = m.state else {
            Issue.record("no capture opened: \(m.state)"); return
        }
        #expect(m.handle(.timer(.followUp)).isEmpty)
        #expect(m.handle(.timer(.offerToClose)).isEmpty)
        guard case .capturing(.followUp) = m.state else {
            Issue.record("the window closed under them: \(m.state)"); return
        }
    }

    /// Muted inside an ordinary window: its 8 s clock is replaced by the
    /// cap, and unmuting puts the 8 s back.
    @Test func mutingInsideTheWindowStopsItsClock() {
        var m = machine()
        toThinking(&m)
        let opened = replyEnds(&m)
        #expect(armed(opened, .followUp) == m.tuning.followUpSeconds)
        let mute = m.handle(.setMuted(true))
        #expect(armed(mute, .followUp) == m.tuning.mutedWindowSeconds)
        #expect(mute.contains(.cancelTimer(.offerToClose)))
        #expect(m.handle(.speechStarted).isEmpty, "not heard")
        #expect(m.state == .followUp)
    }

    /// The safety cap: a forgotten muted window closes after 10 minutes,
    /// says why, and the conversation's end lifts the mute.
    @Test func aForgottenMutedWindowClosesAtTheCapAndSaysWhy() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.setMuted(true))
        _ = replyEnds(&m)
        let closed = m.handle(.timer(.followUp))
        #expect(closed.contains(.mutedWindowExpired))
        #expect(closed.contains(.conversationEnded))
        #expect(m.state == .standby)
        #expect(!m.muted)
        #expect(causes(closed) == [.conversationEnded])
    }

    // MARK: - Every way mute ends, one test each

    /// 1. The button.
    @Test func theButtonUnmutes() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.setMuted(true))
        let out = m.handle(.setMuted(false))
        #expect(out.contains(.micMuted(false)))
        #expect(causes(out) == [.button])
        #expect(!m.handle(.speechStarted).isEmpty, "heard again")
    }

    /// 2. The hotkey: hands-free, so "listen to me now" means unmuted.
    @Test func theHotkeyUnmutes() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.setMuted(true))
        let out = m.handle(.toggle)
        #expect(out.contains(.micMuted(false)))
        #expect(causes(out) == [.hotkey])
    }

    /// 3. The end of the conversation (×, Esc, "that's all", the cap).
    @Test func theEndOfTheConversationUnmutes() {
        var m = machine()
        toThinking(&m)
        _ = replyEnds(&m)
        _ = m.handle(.setMuted(true))
        let out = m.handle(.stopAll)
        #expect(out.contains(.micMuted(false)))
        #expect(causes(out) == [.conversationEnded])
        #expect(!m.muted)
        #expect(m.state == .standby)
    }

    // MARK: - The talk key does not unmute

    /// Held, it talks through the mute: heard while down, muted again
    /// when it comes up. It never switches mute off.
    @Test func theKeyTalksThroughAndLeavesTheMuteOn() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.setMuted(true))
        let down = m.handle(.holdDown)
        #expect(m.state == .capturing(.hold))
        #expect(m.muted, "still muted")
        #expect(!down.contains(.micMuted(false)))
        #expect(down.contains(.asr(true)), "but heard while the key is down")
        #expect(down.contains(.capture(true)), "and the turn's audio kept")
        _ = m.handle(.holdUp)
        guard case .deciding(.hold, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "and the return flight"))
        guard case .thinking = m.state else { Issue.record("the key's turn did not go through: \(m.state)"); return }
        #expect(m.muted, "and mute is still on")
    }

    /// A tap is the reply's pause button. Pausing must not open the room.
    @Test func aTapOfTheKeyPausesAndStaysMuted() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.setMuted(true))
        _ = m.handle(.holdDown)
        let tap = m.handle(.holdCancelled)
        #expect(m.muted)
        #expect(!tap.contains(.micMuted(false)))
        #expect(m.handle(.speechStarted).isEmpty)
    }

    /// Mute pressed while the key is down: it takes effect when it comes up.
    @Test func muteWithTheKeyDownHoldsFromTheRelease() {
        var m = machine()
        toThinking(&m)
        _ = replyEnds(&m)
        _ = m.handle(.holdDown)
        let out = m.handle(.setMuted(true))
        #expect(out.contains(.micMuted(true)))
        #expect(m.state == .capturing(.hold), "the turn in progress is kept")
        #expect(!out.contains(.asr(false)) && !out.contains(.capture(false)),
                "still heard while down")
        _ = m.handle(.holdUp)
        #expect(m.muted)
    }

    // MARK: - Every change says why

    @Test func everyMuteChangeCarriesACause() {
        var m = machine()
        toThinking(&m)
        var all: [M.Action] = []
        all += m.handle(.setMuted(true))
        all += replyEnds(&m)
        all += m.handle(.holdDown)
        all += m.handle(.holdCancelled)
        all += m.handle(.setMuted(false))
        all += m.handle(.setMuted(true))
        all += m.handle(.toggle)
        all += m.handle(.setMuted(true))
        all += m.handle(.stopAll)
        let changes = all.filter { if case .micMuted = $0 { return true } else { return false } }
        let why = causes(all)
        #expect(changes.count == why.count, "one cause per change")
        #expect(!why.contains(.unrecorded))
        #expect(why == [.button, .button, .button, .hotkey, .button, .conversationEnded])
    }

    @Test func theLogLineNamesTheCause() {
        #expect(M.MuteCause.button.logLine(muted: true, surface: "island")
                .hasPrefix("voice: muted — the mute button on the island"))
        #expect(M.MuteCause.button.logLine(muted: false).hasPrefix("voice: unmuted — the mute button"))
        #expect(M.MuteCause.hotkey.logLine(muted: false).contains("the hotkey"))
        #expect(M.MuteCause.conversationEnded.logLine(muted: false).contains("conversation ended"))
        #expect(M.MuteCause.unrecorded.logLine(muted: false).contains("NO CAUSE"))
        // 16:57:37's bare "voice: unmuted" cannot be written any more.
        for c in [M.MuteCause.button, .hotkey, .conversationEnded, .unrecorded] {
            #expect(c.logLine(muted: false) != "voice: unmuted")
        }
    }
}
