import CoreGraphics
import Foundation
import Testing
import MoeVoice
@testable import Moe

/// docs/DEFAULTS.md row 8: the key you hold to talk is right ⌥ to start
/// with, and a picker offers right ⌘, right ⌃ and fn instead.
///
/// The press checks go through `PushToTalk.isCleanPress(_:of:)`, which is the
/// one test `handleAgent` makes on every flag change — so a PushToTalk that
/// went back to a hard-coded right-option bit fails the right ⌘, right ⌃ and
/// fn cases below.
///
/// The flags are built from Apple's numbers, never from `TalkKey`'s: a test
/// that builds its input from the same `flagBit`/`genericFlag` the code reads
/// agrees with a wrong constant (CLAUDE.md, "a closed loop of invented
/// constants agrees with itself").
struct TalkKeyTests {

    /// IOKit's modifier masks, quoted from IOKit/hidsystem/IOLLEvent.h
    /// (MacOSX.sdk, read 2026-09-15). CGEventTypes.h defines each
    /// `kCGEventFlagMask…` as the NX_ mask of the same name, so
    /// `CGEventFlags.maskSecondaryFn.rawValue` is NX_SECONDARYFNMASK.
    private enum IOLLEvent {
        static let NX_SHIFTMASK: UInt64         = 0x0002_0000
        static let NX_CONTROLMASK: UInt64       = 0x0004_0000
        static let NX_ALTERNATEMASK: UInt64     = 0x0008_0000
        static let NX_COMMANDMASK: UInt64       = 0x0010_0000
        static let NX_SECONDARYFNMASK: UInt64   = 0x0080_0000
        static let NX_DEVICERCMDKEYMASK: UInt64 = 0x0000_0010
        static let NX_DEVICERALTKEYMASK: UInt64 = 0x0000_0040
        static let NX_DEVICERCTLKEYMASK: UInt64 = 0x0000_2000
    }

    /// The side-agnostic mask each key sets, from the header.
    private func generic(_ key: TalkKey) -> UInt64 {
        switch key {
        case .rightOption:  return IOLLEvent.NX_ALTERNATEMASK
        case .rightCommand: return IOLLEvent.NX_COMMANDMASK
        case .rightControl: return IOLLEvent.NX_CONTROLMASK
        case .fn:           return IOLLEvent.NX_SECONDARYFNMASK
        }
    }

    /// What the tap sees when `key` alone goes down: its side-agnostic mask
    /// plus its device-dependent bit (fn has none), plus anything else held.
    private func press(_ key: TalkKey, plus extra: UInt64 = 0) -> CGEventFlags {
        let side: UInt64
        switch key {
        case .rightOption:  side = IOLLEvent.NX_DEVICERALTKEYMASK
        case .rightCommand: side = IOLLEvent.NX_DEVICERCMDKEYMASK
        case .rightControl: side = IOLLEvent.NX_DEVICERCTLKEYMASK
        case .fn:           side = 0
        }
        return CGEventFlags(rawValue: generic(key) | side | extra)
    }

    @Test("a fresh config holds right ⌥ to talk")
    func defaultIsRightOption() {
        #expect(Config().talkKey == .rightOption)
    }

    @MainActor
    @Test("push-to-talk starts on right ⌥ until it is told otherwise")
    func pushToTalkDefault() {
        #expect(PushToTalk().talkKey == .rightOption)
    }

    @Test("a config.json from before the picker still talks on right ⌥")
    func oldConfigDecodes() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"hotKeyModifiers": 6144}"#.utf8))
        #expect(old.talkKey == .rightOption)
    }

    @Test("a chosen key survives a save, and a name Alfie does not know falls back to right ⌥")
    func roundTripAndUnknown() throws {
        var c = Config()
        c.talkKey = .fn
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.talkKey == .fn)
        let junk = try JSONDecoder().decode(Config.self, from: Data(#"{"talkKey": "leftShift"}"#.utf8))
        #expect(junk.talkKey == .rightOption)
    }

    @Test("each key's bit is the device-dependent bit macOS sets for it")
    func bits() {
        #expect(TalkKey.rightOption.flagBit == IOLLEvent.NX_DEVICERALTKEYMASK)
        #expect(TalkKey.rightCommand.flagBit == IOLLEvent.NX_DEVICERCMDKEYMASK)
        #expect(TalkKey.rightControl.flagBit == IOLLEvent.NX_DEVICERCTLKEYMASK)
        #expect(TalkKey.fn.flagBit == IOLLEvent.NX_SECONDARYFNMASK)
        #expect(CGEventFlags.maskSecondaryFn.rawValue == 0x0080_0000)
        for key in TalkKey.allCases {
            #expect(key.genericFlag.rawValue == generic(key), "\(key)")
        }
        // The same bits the dictation key watches, so the two compare.
        #expect(TalkKey.rightCommand.flagBit == DictationKey.rightCommand.flagBit)
        #expect(TalkKey.rightControl.flagBit == DictationKey.rightControl.flagBit)
        #expect(TalkKey.fn.flagBit == DictationKey.fn.flagBit)
        #expect(TalkKey.allCases.count == 4)
        #expect(TalkKey.allCases.contains(.fn))
    }

    @Test("the configured key alone is a press")
    func aloneIsAPress() {
        for key in TalkKey.allCases {
            #expect(PushToTalk.isCleanPress(press(key), of: key), "\(key)")
        }
    }

    @Test("the same key with another modifier held is not a press")
    func anotherModifierIsNotAPress() {
        for key in TalkKey.allCases {
            let others = [IOLLEvent.NX_COMMANDMASK, IOLLEvent.NX_CONTROLMASK,
                          IOLLEvent.NX_SHIFTMASK, IOLLEvent.NX_ALTERNATEMASK]
                .filter { $0 != generic(key) }
            for other in others {
                #expect(!PushToTalk.isCleanPress(press(key, plus: other), of: key), "\(key) + \(other)")
            }
        }
        // Right ⌥ keeps exactly the rule it always had: ⌘, ⌃ and ⇧ spoil it.
        #expect(!PushToTalk.isCleanPress(press(.rightOption, plus: IOLLEvent.NX_COMMANDMASK), of: .rightOption))
    }

    @Test("a different key's bit is not a press of the configured key")
    func differentKeyIsNotAPress() {
        for configured in TalkKey.allCases {
            for pressed in TalkKey.allCases where pressed != configured {
                #expect(!PushToTalk.isCleanPress(press(pressed), of: configured), "\(pressed) pressed, \(configured) configured")
            }
        }
        // Left ⌥ sets ⌥ but not right ⌥'s bit.
        #expect(!PushToTalk.isCleanPress(CGEventFlags(rawValue: IOLLEvent.NX_ALTERNATEMASK), of: .rightOption))
        #expect(!PushToTalk.isCleanPress([], of: .rightOption))
    }

    @Test("a dictation key that is the talk key is off; hidden dictation never has a key")
    func collisionGivesDictationAway() {
        #expect(TalkKey.rightCommand.collides(with: .rightCommand))
        #expect(!TalkKey.rightOption.collides(with: .rightCommand))
        #expect(!TalkKey.fn.collides(with: .off))

        var c = Config()
        c.dictationEnabled = true
        c.dictationKey = .rightCommand
        c.talkKey = .rightCommand
        #expect(Conductor.effectiveDictationKey(c) == .off)
        c.talkKey = .rightOption
        #expect(Conductor.effectiveDictationKey(c) == (Features.dictation ? .rightCommand : .off))
    }

    // MARK: A key held as part of a shortcut is not a talk press

    typealias Chord = TalkChordMachine

    @Test("the key alone, held, is a press and a release")
    func keyAloneIsAPressAndRelease() {
        #expect(Chord.actions(for: [.down(0), .up(1.2)]) == [.press, .release])
    }

    @Test("the key with an arrow key going down is a cancel: no release, so no turn")
    func chordIsCancelled() {
        // A long chord (fn held, ← pressed a few times) and a quick one.
        #expect(Chord.actions(for: [.down(0), .otherKey, .otherKey, .up(1.5)]) == [.press, .cancel])
        #expect(Chord.actions(for: [.down(0), .otherKey, .up(0.1)]) == [.press, .cancel])
        // A real key while the talk key is up is nothing.
        #expect(Chord.actions(for: [.otherKey]) == [])
    }

    @Test("a cancelled chord earns no double-tap credit")
    func chordThenTapIsNoDoubleTap() {
        let a = Chord.actions(for: [.down(0), .otherKey, .up(0.10), .down(0.20), .up(0.25)])
        #expect(a == [.press, .cancel, .press, .armTapWindow])
        #expect(!a.contains(.doubleTap))
    }

    @Test("two chords in quick succession are two cancels, never a stop")
    func twoQuickChordsAreNoDoubleTap() {
        let a = Chord.actions(for: [.down(0), .otherKey, .up(0.10), .down(0.15), .otherKey, .up(0.25)])
        #expect(a == [.press, .cancel, .press, .cancel])
        #expect(!a.contains(.doubleTap))
        #expect(!a.contains(.release))
    }

    @Test("taps are unchanged: one is a tap when the window closes, two are a stop")
    func tapsStillWork() {
        // `.tap`, not `.release`: the receiver cannot time a release that
        // arrives a window late, and read every tap as a hold (2026-09-23).
        #expect(Chord.actions(for: [.down(0), .up(0.10), .tapWindowClosed]) == [.press, .armTapWindow, .tap])
        #expect(Chord.actions(for: [.down(0), .up(0.10), .down(0.20), .up(0.30)])
                == [.press, .armTapWindow, .disarmTapWindow, .doubleTap])
        // A tap, then a hold inside the window: one press, one release.
        #expect(Chord.actions(for: [.down(0), .up(0.10), .down(0.20), .up(1.0)])
                == [.press, .armTapWindow, .disarmTapWindow, .release])
    }

    @Test("a shortcut on the second press of a tap cancels the press that is still standing")
    func shortcutOnTheSecondPress() {
        #expect(Chord.actions(for: [.down(0), .up(0.10), .down(0.20), .otherKey, .up(0.30)])
                == [.press, .armTapWindow, .disarmTapWindow, .cancel])
    }

    // MARK: Hands-free: double-tap with Moe idle, tap to send

    /// A double-tap, then the owner's answer that it latched.
    static let doubleTapThenLatch: [Chord.Event] = [.down(0), .up(0.10), .down(0.20), .up(0.30), .latch]

    @Test("a double-tap the owner latches keeps the first press open: no release, no stop")
    func doubleTapLatches() {
        var m = Chord()
        let a = Self.doubleTapThenLatch.flatMap { m.handle($0) }
        #expect(a == [.press, .armTapWindow, .disarmTapWindow, .doubleTap, .latch])
        #expect(m.isLatched)
        #expect(!a.contains(.release) && !a.contains(.cancel))
    }

    @Test("latch is only taken straight after a double-tap")
    func latchNeedsADoubleTap() {
        #expect(Chord.actions(for: [.latch]) == [])
        #expect(Chord.actions(for: [.down(0), .up(1.0), .latch]) == [.press, .release])
        // Something in between: the double-tap was answered as a stop.
        #expect(Chord.actions(for: [.down(0), .up(0.10), .down(0.20), .up(0.30), .otherKey, .latch])
                == [.press, .armTapWindow, .disarmTapWindow, .doubleTap])
    }

    @Test("while latched the next tap — or hold — sends, exactly like letting go of a held press")
    func tapSends() {
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.down(20), .up(20.10)]).suffix(2)
                == [.unlatch(.tap), .release])
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.down(20), .up(22)]).suffix(2)
                == [.unlatch(.tap), .release])
        // The send's down is not a new press and arms no tap window.
        let a = Chord.actions(for: Self.doubleTapThenLatch + [.down(20)])
        #expect(a.last == .latch)
    }

    @Test("nothing but the key sends: silence, stray timers and typing leave it listening")
    func neverSendsOnItsOwn() {
        var m = Chord()
        _ = Self.doubleTapThenLatch.flatMap { m.handle($0) }
        #expect(m.handle(.tapWindowClosed) == [])
        #expect(m.handle(.otherKey) == [])
        #expect(m.handle(.otherKey) == [])
        #expect(m.isLatched)
        #expect(m.handle(.down(300)) == [])
        #expect(m.handle(.up(300.1)) == [.unlatch(.tap), .release])
        #expect(!m.isLatched)
    }

    @Test("Esc while latched drops the turn; the lock does too; neither sends")
    func escAndLockDrop() {
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.esc]).suffix(2) == [.unlatch(.esc), .cancel])
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.lock]).suffix(2) == [.unlatch(.lock), .cancel])
        // Esc with the key down: the release after it has nothing to finish.
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.down(5), .esc, .up(5.1)]).suffix(2)
                == [.unlatch(.esc), .cancel])
        // …and the next tap is a fresh press.
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.esc, .down(9), .up(9.1)]).suffix(2)
                == [.press, .armTapWindow])
        // Not latched: the lock is nothing, Esc during a hold is a shortcut as before.
        #expect(Chord.actions(for: [.lock]) == [])
        #expect(Chord.actions(for: [.down(0), .esc, .up(1)]) == [.press, .cancel])
    }

    @Test("the talk key down for a shortcut while latched does not send")
    func shortcutWhileLatched() {
        var m = Chord()
        _ = Self.doubleTapThenLatch.flatMap { m.handle($0) }
        #expect(m.handle(.down(5)) == [])
        #expect(m.handle(.otherKey) == [])
        #expect(m.handle(.up(5.3)) == [])
        #expect(m.isLatched)
        #expect(m.handle(.down(6)) == [])
        #expect(m.handle(.up(6.1)) == [.unlatch(.tap), .release])
    }

    @Test("double-tapping to send is one send: the second tap never opens a hold over the sent turn")
    func doubleTapToSendIsOneSend() {
        var m = Chord()
        _ = Self.doubleTapThenLatch.flatMap { m.handle($0) }
        let a = [Chord.Event.down(5), .up(5.10), .down(5.20), .up(5.30), .tapWindowClosed].flatMap { m.handle($0) }
        #expect(a == [.unlatch(.tap), .release])
        // Outside the window a press is a press again.
        #expect(m.handle(.down(8)) == [.press])
    }

    @Test("reset forgets a latch")
    func resetForgetsTheLatch() {
        var m = Chord()
        _ = Self.doubleTapThenLatch.flatMap { m.handle($0) }
        m.reset()
        #expect(!m.isLatched)
        #expect(m.handle(.down(1)) == [.press])
    }

    /// Every voice state, against every flag: the latch is taken from true
    /// rest only. Built from the machine's own list of states so a new state
    /// cannot slip in unexamined — and only `.off` and `.standby` may latch.
    static let everyVoiceState: [VoiceEngine.State] = {
        let sources: [VoiceMachine.Source] = [.hold, .hotkey, .wake, .followUp, .aside]
        var all: [VoiceEngine.State] = [.off, .standby, .followUp, .suspended]
        for s in sources {
            all += [.attending(s), .capturing(s), .deciding(s, turn: 1), .thinking(s), .speaking(s)]
        }
        return all
    }()

    @Test("a double-tap listens hands-free only from true rest — every state, every flag")
    func whatADoubleTapMeans() {
        let modes: [Conductor.Mode] = [.idle, .listening, .thinking, .speaking]
        var latched = 0
        for voice in Self.everyVoiceState {
            for mode in modes {
                for bits in 0..<16 {
                    let awaiting = bits & 1 != 0, acting = bits & 2 != 0
                    let held = bits & 4 != 0, dictating = bits & 8 != 0
                    let got = Conductor.doubleTapListensHandsFree(
                        voice: voice, mode: mode, awaitingReply: awaiting, acting: acting,
                        replyHeld: held, dictating: dictating)
                    let atRest = voice == .off || voice == .standby
                    let want = atRest && mode == .idle && bits == 0
                    #expect(got == want, "\(voice) \(mode) awaiting:\(awaiting) acting:\(acting) held:\(held) dictating:\(dictating)")
                    if got { latched += 1 }
                }
            }
        }
        #expect(latched == 2)       // off and standby, idle, nothing going on
        // The two states that latched 45 of 76 times on the owner's Mac.
        #expect(!Conductor.doubleTapListensHandsFree(voice: .capturing(.wake), mode: .idle,
                    awaitingReply: false, acting: false, replyHeld: false, dictating: false))
        #expect(!Conductor.doubleTapListensHandsFree(voice: .followUp, mode: .idle,
                    awaitingReply: false, acting: false, replyHeld: false, dictating: false))
    }

    // MARK: A tap straight after a latch undoes it

    @Test("latch, then a tap 0.5 s later: cancel, never send")
    func quickTapAfterALatchCancels() {
        // The 2026-10-13 shape: the double-tap latched, the third tap of the
        // burst came 0.6 s later and sent eight stray words.
        let a = Chord.actions(for: Self.doubleTapThenLatch + [.down(0.8), .up(0.88)])
        #expect(a.suffix(2) == [.unlatch(.undo), .cancel])
        #expect(!a.contains(.release))
    }

    @Test("past the undo window a tap sends; a hold always sends")
    func undoWindowCloses() {
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.down(1.2), .up(1.28)]).suffix(2)
                == [.unlatch(.tap), .release])
        // A deliberate hold straight after the latch is someone talking.
        #expect(Chord.actions(for: Self.doubleTapThenLatch + [.down(0.5), .up(2.5)]).suffix(2)
                == [.unlatch(.tap), .release])
    }

    @Test("the undo swallows the tail of the burst: no new hold opens over it")
    func undoSwallowsTheTail() {
        var m = Chord()
        _ = (Self.doubleTapThenLatch + [.down(0.6), .up(0.65)]).flatMap { m.handle($0) }
        #expect(m.handle(.down(0.8)) == [])
        #expect(m.handle(.up(0.85)) == [])
        #expect(m.handle(.down(3)) == [.press])
    }

    // MARK: A press from rest is shown only once it is a hold

    @Test("a press still down at the tap threshold is confirmed once; a tap never is")
    func holdConfirmation() {
        var m = Chord()
        _ = m.handle(.down(0))
        #expect(m.handle(.holdThreshold(0.22)) == [.holdConfirmed])
        #expect(m.handle(.holdThreshold(0.5)) == [])          // once per press
        // A tap: up before the timer, so the timer finds nothing.
        var t = Chord()
        _ = t.handle(.down(0)); _ = t.handle(.up(0.1))
        #expect(t.handle(.holdThreshold(0.22)) == [])
    }

    @Test("the first tap's timer cannot confirm the second press of a double-tap")
    func staleTimerRefused() {
        var m = Chord()
        _ = [Chord.Event.down(0), .up(0.10), .down(0.20)].flatMap { m.handle($0) }
        // The first press's timer, fired late, 0.02 s into the second press.
        #expect(m.handle(.holdThreshold(0.22)) == [])
        // The second press's own timer, if it is held: a hold after all.
        #expect(m.handle(.holdThreshold(0.42)) == [.holdConfirmed])
    }

    @Test("a shortcut or a latched run is never confirmed as a hold")
    func noConfirmForShortcutsOrLatch() {
        var m = Chord()
        _ = [Chord.Event.down(0), .otherKey].flatMap { m.handle($0) }
        #expect(m.handle(.holdThreshold(0.3)) == [])
        var l = Chord()
        _ = (Self.doubleTapThenLatch + [.down(5)]).flatMap { l.handle($0) }
        #expect(l.handle(.holdThreshold(5.3)) == [])
    }

    @Test("modifier key codes never count as the other key; real keys and Esc do")
    func modifierKeyCodes() {
        // Carbon HIToolbox Events.h, MacOSX.sdk: kVK_RightCommand 0x36,
        // kVK_RightOption 0x3D, kVK_RightControl 0x3E, kVK_Function 0x3F,
        // kVK_CapsLock 0x39.
        for code: Int64 in [0x36, 0x3D, 0x3E, 0x3F, 0x39] {
            #expect(PushToTalk.isModifierKeyCode(code), "\(code)")
        }
        // kVK_Delete 0x33, kVK_LeftArrow 0x7B, kVK_Tab 0x30, kVK_Escape 0x35.
        for code: Int64 in [0x33, 0x7B, 0x30, 0x35] {
            #expect(!PushToTalk.isModifierKeyCode(code), "\(code)")
        }
    }

    @MainActor
    @Test("the meeting hint names the key you hold")
    func meetingHintNamesTheKey() {
        #expect(Conductor.meetingHintText(.fn).contains("fn / 🌐"))
        #expect(Conductor.meetingHintText(.rightOption).contains("right ⌥"))
    }
}
