import Foundation
import Testing
@testable import MoeVoice

/// The key as a pause button.
///
/// The owner, 2026-09-08: *"when you're in the middle of talking and you
/// press the option key, it does a pausing thing — I don't know what it
/// does with it. When you press the option key, that should just be a
/// straight pause when it talks. Then you press it again, and it can
/// resume its talking."*
///
/// The "pausing thing" was real and half-finished. A press has always
/// stopped the sound at once, before anything can know whether it is a
/// brush, a tap or a hold; a tap's release then resumed it half a second
/// later. So the gesture existed, made a stutter, and there was no way to
/// make it stick.
///
/// The grammar now:
///
/// | gesture | over a reply |
/// |---|---|
/// | tap | hold it where it is |
/// | tap again | let it go on, from the same sample |
/// | hold, then words | the reply is over, the words are the new turn |
/// | hold, then nothing | let it go on |
/// | double tap | stop everything |
///
/// Everything the tap already protected it must still protect: a 29 ms
/// brush cost a reply 139 characters in on 2026-09-04, and no gesture here
/// may ever destroy an answer that was not replaced.
struct PausingTheReplyTests {

    typealias M = VoiceMachine
    typealias A = M.Action

    private func machine() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.setWake(true))
        return m
    }

    /// A machine mid-reply, with the brain finished and audio still to play.
    private func speaking() -> M {
        var m = machine()
        var out = m.handle(.toggle)
        out += m.handle(.speechStarted)
        out += m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("not deciding: \(m.state)"); return m
        }
        _ = m.handle(.transcribed(turn: turn, "what time is it"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        #expect(m.state == .speaking(.hotkey))
        return m
    }

    /// One tap: the sound stops and stays stopped.
    private func tap(_ m: inout M) -> [A] {
        var out = m.handle(.holdDown)
        out += m.handle(.holdCancelled)
        return out
    }

    // MARK: A shortcut is not a tap

    /// fn+Delete, right ⌘+Tab: the key went down, so the sound stopped, and
    /// then another key said it was a shortcut (`.holdAborted`). That is not
    /// the pause button — the reply plays on as if the key had never moved.
    @Test func aShortcutOverAReplyLetsItPlayOn() {
        var m = speaking()
        var out = m.handle(.holdDown)
        out += m.handle(.holdAborted)
        #expect(out.contains(.resumeReply), "a chord must not leave the reply paused")
        #expect(!out.contains(.abandonReply))
        #expect(!out.contains(.replyHeld(true)))
        #expect(m.state == .speaking(.hotkey))
    }

    /// A reply a tap already paused stays paused: the shortcut changes
    /// nothing the person did before it.
    @Test func aShortcutOverAPausedReplyKeepsItPaused() {
        var m = speaking()
        _ = tap(&m)
        var out = m.handle(.holdDown)
        out += m.handle(.holdAborted)
        #expect(!out.contains(.resumeReply))
        #expect(m.state == .speaking(.hotkey))
        // …and the next real tap still lets it go.
        #expect(tap(&m).contains(.resumeReply))
    }

    @Test func aShortcutWithNothingPlayingRecordsNothing() {
        var m = machine()
        _ = m.handle(.holdDown)
        let out = m.handle(.holdAborted)
        #expect(!out.contains { if case .transcribe = $0 { return true } else { return false } })
        #expect(m.state == .standby)
    }

    // MARK: The thing that was asked for

    @Test func aTapHoldsTheReplyWhereItIs() {
        var m = speaking()
        let out = tap(&m)
        #expect(out.contains(.stopSpeaking), "the sound stops the instant the key goes down")
        #expect(!out.contains(.resumeReply), "and it must not start again on its own — that is the complaint")
        #expect(!out.contains(.abandonReply), "nor is the reply thrown away")
        #expect(m.state == .speaking(.hotkey), "still the reply; it is only held")
    }

    @Test func theNextTapLetsItGoOn() {
        var m = speaking()
        _ = tap(&m)
        let again = tap(&m)
        #expect(again.contains(.resumeReply))
        #expect(m.state == .speaking(.hotkey))
    }

    /// `.resumeReply` over a paused reply carries on from the very sample
    /// it stopped at (`VoiceEngine`), so nothing is re-said and nothing is
    /// skipped. What matters here is that the reply is still the machine's,
    /// which is what makes that possible.
    @Test func itIsStillTheSameReplyAfterwards() {
        var m = speaking()
        _ = tap(&m)
        _ = tap(&m)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp, "the reply finished normally and opened the window")
    }

    /// Pause, carry on, pause again. Not once per reply — a pause button
    /// that works twice and then stops being a pause button is worse than
    /// none, because there is nothing on screen to say which one you have.
    @Test func itPausesAsOftenAsYouLike() {
        var m = speaking()
        for round in 1...5 {
            let held = tap(&m)
            #expect(!held.contains(.resumeReply), "round \(round): the tap must hold it")
            #expect(m.state == .speaking(.hotkey), "round \(round)")
            let freed = tap(&m)
            #expect(freed.contains(.resumeReply), "round \(round): the next tap must free it")
        }
    }

    /// The reply is held, so the machine must not be listening: the person
    /// pressed pause and walked off. An open microphone there is the whole
    /// class of "Moe answered the room".
    @Test func aHeldReplyDoesNotListen() {
        var m = speaking()
        let out = tap(&m)
        #expect(out.last(where: { if case .capture = $0 { return true }; return false }) == .capture(false))
        #expect(out.last(where: { if case .asr = $0 { return true }; return false }) == .asr(false))
    }

    // MARK: Saying so

    /// The audio stops either way, so the only thing separating "paused"
    /// from "broken" is being told. `.replyHeld` is that, and it comes off
    /// the derived diff, so a route into the hold that forgot to announce
    /// it cannot exist.
    @Test func theHoldIsAnnounced() {
        var m = speaking()
        let held = tap(&m)
        #expect(held.contains(.replyHeld(true)))

        let freed = tap(&m)
        #expect(freed.contains(.replyHeld(false)))
    }

    /// It is announced once, not on every event while it stands: the
    /// island's line must not be rewritten under the person's cursor.
    @Test func theHoldIsAnnouncedOnceEachWay() {
        var m = speaking()
        #expect(tap(&m).filter { $0 == .replyHeld(true) }.count == 1)
        // Anything harmless while held: no second announcement.
        #expect(!m.handle(.speechQueued).contains(.replyHeld(true)))
    }

    /// Every way out of the hold says so, not just the tap. A stop, a
    /// goodbye, a hold that became a turn — each leaves the island with a
    /// stale "paused" line if it does not.
    @Test func everyWayOutOfTheHoldSaysSo() {
        var stopped = speaking()
        _ = tap(&stopped)
        #expect(stopped.handle(.stopAll).contains(.replyHeld(false)),
                "stopping everything")

        // Pressing the key again opens the microphone, so the reply is no
        // longer merely paused and the line must go at once — before the
        // person has said anything into it.
        var spoken = speaking()
        _ = tap(&spoken)
        #expect(spoken.handle(.holdDown).contains(.replyHeld(false)),
                "the microphone is open now; \"paused\" is no longer true")
        _ = spoken.handle(.holdUp)
        guard case .deciding(_, let turn) = spoken.state else {
            Issue.record("expected .deciding, got \(spoken.state)"); return
        }
        let out = spoken.handle(.transcribed(turn: turn, "no, something else"))
        #expect(out.contains(.abandonReply))
        #expect(!out.contains(.replyHeld(true)), "and it must not come back")
    }

    /// A goodbye over a held reply clears the line too.
    @Test func aGoodbyeClearsTheHeldLine() {
        var m = speaking()
        _ = tap(&m)
        #expect(m.handle(.stopAll).contains(.replyHeld(false)))
    }

    // MARK: What must not change

    /// A hold is somebody speaking. Their words replace the reply, exactly
    /// as before the pause existed.
    @Test func aHoldWithWordsStillEndsTheReply() {
        var m = speaking()
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        let out = m.handle(.transcribed(turn: turn, "no, the other one"))
        #expect(out.contains(.abandonReply), "the old reply is over")
    }

    /// A hold with nothing in it lets the reply go on — the person held the
    /// key and said nothing.
    @Test func aHoldWithNoWordsResumesTheReply() {
        var m = speaking()
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        let out = m.handle(.transcribed(turn: turn, ""))
        #expect(out.contains(.resumeReply))
    }

    /// And the same, from a held reply: the pause does not turn a real hold
    /// into a no-op. Somebody who paused Moe and then decided to say
    /// something must be heard.
    @Test func aHoldOverAHeldReplyIsStillATurn() {
        var m = speaking()
        _ = tap(&m)
        #expect(m.state == .speaking(.hotkey))

        _ = m.handle(.holdDown)
        #expect(m.state == .capturing(.hold), "the microphone opens for the hold")
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        let out = m.handle(.transcribed(turn: turn, "actually, forget it"))
        #expect(out.contains(.abandonReply), "the held reply is replaced by the new turn")
        #expect(!out.contains(.resumeReply))
    }

    /// Stop is still stop. A held reply must not survive it and come back.
    @Test func stoppingEverythingEndsAHeldReply() {
        var m = speaking()
        _ = tap(&m)
        let out = m.handle(.stopAll)
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.abandonReply))
        #expect(m.state == .standby)

        // And the latch went with it: a stray tap now must not resurrect
        // anything.
        let after = tap(&m)
        #expect(!after.contains(.resumeReply))
    }

    /// A goodbye over a held reply ends it too, rather than leaving audio
    /// to come back after "thanks Moe".
    @Test func aGoodbyeEndsAHeldReply() {
        var m = speaking()
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        _ = m.handle(.transcribed(turn: turn, ""))
        let out = m.handle(.dismiss)
        #expect(m.state == .standby)
        #expect(!out.contains(.resumeReply))
    }

    /// The reply that is still being written pauses the same way: a tap
    /// while Moe is between sentences must not lose the rest of it.
    @Test func aReplyStillBeingWrittenPausesToo() {
        var m = machine()
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("not deciding: \(m.state)"); return
        }
        _ = m.handle(.transcribed(turn: turn, "tell me a long story"))
        _ = m.handle(.speechQueued)          // audio playing, brain still writing
        #expect(m.state == .speaking(.hotkey))

        let held = tap(&m)
        #expect(!held.contains(.abandonReply))
        #expect(!held.contains(.resumeReply))
        let freed = tap(&m)
        #expect(freed.contains(.resumeReply))
    }

    // MARK: A reply read out from rest

    /// A typed turn's answer, or a reply played again from its ▶, is spoken
    /// as an aside — from rest, back to rest. It pauses the same way.
    /// Before 2026-09-23 a tap over one simply ended it.
    private func readingOut() -> M {
        var m = machine()
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.aside))
        return m
    }

    @Test func aTapHoldsAReplyReadOutFromRest() {
        var m = readingOut()
        let held = tap(&m)
        #expect(held.contains(.stopSpeaking))
        #expect(!held.contains(.resumeReply))
        #expect(held.contains(.replyHeld(true)))
        #expect(m.state == .speaking(.aside), "held, not over")

        let freed = tap(&m)
        #expect(freed.contains(.resumeReply))
        #expect(freed.contains(.replyHeld(false)))
        _ = m.handle(.ttsDrained)
        #expect(m.state == .standby, "and when it is done, back to rest")
    }

    @Test func aHoldWithWordsOverAReadOutIsAnOrdinaryHoldTurn() {
        var m = readingOut()
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        guard case .deciding(let s, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        #expect(s == .hold)
        let out = m.handle(.transcribed(turn: turn, "what about Thursday"))
        #expect(!out.contains(.resumeReply))
        #expect(m.state == .thinking(.hold), "the key's own rules, as before")
    }

    @Test func stoppingEverythingEndsAHeldReadOut() {
        var m = readingOut()
        _ = tap(&m)
        let out = m.handle(.stopAll)
        #expect(out.contains(.replyHeld(false)))
        #expect(!tap(&m).contains(.resumeReply), "nothing left to resurrect")
    }

    // MARK: The pause button

    /// ⏸ in the chat or on the island. A button knows it is a pause from the
    /// start, so the sound is held at the sample (`.holdSpeech`), not stopped.
    @Test func thePauseButtonHoldsAtTheSample() {
        var m = speaking()
        let out = m.handle(.pauseReply(true))
        #expect(out.contains(.holdSpeech))
        #expect(!out.contains(.stopSpeaking), "stopped would lose the place mid-sentence")
        #expect(out.contains(.replyHeld(true)))
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func resumeCarriesOnRatherThanStartingOver() {
        var m = speaking()
        _ = m.handle(.pauseReply(true))
        let out = m.handle(.pauseReply(false))
        #expect(out.contains(.resumeReply))
        #expect(out.contains(.replyHeld(false)))
        #expect(!out.contains(.abandonReply))
        #expect(m.state == .speaking(.hotkey))
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp, "and it finishes as the reply it always was")
    }

    /// A reply read out from rest (▶ in the chat) pauses the same way.
    @Test func thePauseButtonWorksOnAReplayToo() {
        var m = machine()
        _ = m.handle(.speechQueued)
        #expect(m.handle(.pauseReply(true)).contains(.holdSpeech))
        #expect(m.handle(.pauseReply(false)).contains(.resumeReply))
        _ = m.handle(.ttsDrained)
        #expect(m.state == .standby)
    }

    /// Paused by the button, let go by the key — or the other way round.
    @Test func theButtonAndTheKeyAreOnePause() {
        var m = speaking()
        _ = m.handle(.pauseReply(true))
        #expect(tap(&m).contains(.resumeReply), "a tap lets a button-paused reply go")
        _ = tap(&m)
        #expect(m.handle(.pauseReply(false)).contains(.resumeReply), "the button lets a tap-held one go")
    }

    @Test func pausingWithNothingSaidDoesNothing() {
        var m = machine()
        #expect(m.handle(.pauseReply(true)).isEmpty)
        #expect(m.handle(.pauseReply(false)).isEmpty)
    }
}
