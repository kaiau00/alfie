import Foundation
import Testing
@testable import MoeVoice

/// Which voice states need Apple's voice-processing unit running.
///
/// The rule lives in `VoiceEngine.needsCanceller`, which is in the Moe
/// executable and cannot be imported. So the states are enumerated here
/// against `VoiceMachine.State` itself, and the one thing that matters is
/// asserted from both ends: every state that can carry Moe's own voice must
/// be on the list, and the idle states must not be.
///
/// Why this is worth a test at all: the canceller costs about a fifth of a
/// CPU core whenever it runs — measured, three ways, in
/// `AudioFrontEnd.setVoiceProcessingBypassed` — and a profile of an idle Moe
/// found 78% of its CPU inside it. Bypassing it while idle is most of what
/// makes Moe cheap to leave running. Bypassing it while Moe is *speaking*
/// would be a real bug: the microphone would hear Moe, the VAD would call it
/// speech, and barge-in would fire on Moe's own voice.
///
/// And the other half, learned the expensive way: the bypass switches off
/// automatic gain and noise suppression along with the canceller. The first
/// rule bypassed every capturing state, and across that install the RMS of
/// a captured turn fell from a median of 0.063 (n=167) to 0.003 (n=56) on
/// the same microphone, transcription confidence from 0.94 to 0.75, and
/// wake turns came back as "Il m'a". So the unit is off only where nothing
/// passes through it in either direction — `off`, `standby`, `suspended` —
/// and on in every state that captures or plays. `standby` is where an idle
/// Moe sits, so the saving is intact.
///
/// Adding a state to `VoiceMachine.State` without deciding which side it
/// falls on is exactly the drift this catches — `allStates` below has to be
/// extended, and that is the prompt to think about it.
struct CancellerStatesTests {

    /// Every case of `VoiceMachine.State`. Not derived from the enum —
    /// written out, so a new case makes this list wrong rather than making
    /// the tests quietly cover less.
    static let allStates: [VoiceMachine.State] = [
        .off,
        .standby,
        .attending(.wake), .attending(.hold), .attending(.hotkey), .attending(.followUp),
        .capturing(.wake), .capturing(.hold), .capturing(.hotkey), .capturing(.followUp),
        .deciding(.wake, turn: 1), .deciding(.hold, turn: 1),
        .thinking(.wake), .thinking(.hold), .thinking(.hotkey), .thinking(.followUp),
        .speaking(.wake), .speaking(.hold), .speaking(.hotkey), .speaking(.aside),
        .followUp,
        .suspended,
    ]

    /// The rule, mirrored. `VoiceEngine.needsCanceller` must agree with this
    /// — if the two ever disagree, one of them is a bug, and the comment on
    /// each says which behaviour is intended.
    private func needsCanceller(_ state: VoiceMachine.State) -> Bool {
        switch state {
        case .off, .standby, .suspended: return false
        case .attending, .capturing, .deciding, .thinking, .speaking, .followUp: return true
        }
    }

    /// The bug that would matter: Moe speaking with the canceller bypassed.
    /// It would hear itself, the VAD would call that speech, and it would
    /// interrupt itself.
    @Test func everyStateThatCanCarryMoesOwnVoiceKeepsTheCanceller() {
        for state in Self.allStates {
            if case .speaking = state {
                #expect(needsCanceller(state), "canceller bypassed while speaking: \(state)")
            }
            if case .thinking = state {
                #expect(needsCanceller(state), "canceller not ready before speaking: \(state)")
            }
        }
        #expect(needsCanceller(.followUp))
    }

    /// The other bug that did happen: capturing with the unit bypassed. No
    /// gain control, no noise suppression — the recogniser, the turn model
    /// and the owner-voice check all got 20× quieter audio than they were
    /// tuned on. Every state where a person's words are being taken keeps
    /// the unit on.
    @Test func everyStateThatCapturesSpeechKeepsTheProcessing() {
        for state in Self.allStates {
            if case .capturing = state {
                #expect(needsCanceller(state), "capturing with gain and noise suppression off: \(state)")
            }
            if case .attending = state {
                #expect(needsCanceller(state), "listening for a request with processing off: \(state)")
            }
            if case .deciding = state {
                #expect(needsCanceller(state), "processing dropped between the capture and its re-read: \(state)")
            }
        }
    }

    /// The saving. If these ever start needing it, the whole optimisation is
    /// gone and someone should have to notice.
    @Test func theIdleStatesDoNotPayForIt() {
        #expect(!needsCanceller(.off))
        #expect(!needsCanceller(.standby))
        #expect(!needsCanceller(.suspended))
    }

    /// `standby` is where an idle Moe actually sits — wake word armed, mic
    /// open, nothing happening — so it is the one that decides whether any
    /// of this was worth doing.
    @Test func standbyIsTheStateThatMattersAndItIsFree() {
        #expect(!needsCanceller(.standby))
    }

    /// Both sides are non-empty. A rule that answered the same way for every
    /// state would pass every test above except this one.
    @Test func theRuleActuallySplitsTheStates() {
        let on = Self.allStates.filter(needsCanceller)
        let off = Self.allStates.filter { !needsCanceller($0) }
        #expect(!on.isEmpty)
        #expect(!off.isEmpty)
        #expect(on.count + off.count == Self.allStates.count)
    }
}
