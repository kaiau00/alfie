import Foundation
import Testing
@testable import MoeVoice

/// The one thing that must never happen: Moe stops answering to its name
/// after an unlock, and nobody notices for a day.
///
/// Letting the microphone go while the Mac is locked is worth about a ninth
/// of a CPU core. Getting it back is worth the whole feature, and it would
/// fail silently — you say "Hey Moe", nothing happens, you assume you
/// mumbled. So these do not check one lock and one unlock; they run every
/// ordering of the four notifications, up to five deep, and require the
/// wake word to be on at the end of every sequence where the user could be
/// back.
///
/// The orderings are not tidy in real life: locking a Mac that then sleeps
/// sends both, waking a sleeping Mac that is still locked sends `didWake`
/// before `screenIsUnlocked`, and a closed lid can send `willSleep` with no
/// lock at all.
struct AwayMicTests {

    /// Replays a sequence and returns what the wake word ended up as, and
    /// what the remembered flag ended up as, exactly as Conductor drives it.
    private func run(_ events: [AwayMic.Event],
                     alwaysListening: Bool = true,
                     meetingHasMic: Bool = false,
                     wakeWordStartsOn: Bool = true) -> (wake: Bool, released: Bool) {
        var wake = wakeWordStartsOn
        var released = false
        for e in events {
            let d = AwayMic.decide(e, released: released,
                                   alwaysListening: alwaysListening,
                                   meetingHasMic: meetingHasMic)
            if let w = d.wakeWord { wake = w }
            released = d.released
        }
        return (wake, released)
    }

    /// Every sequence up to `depth` long.
    private func sequences(depth: Int) -> [[AwayMic.Event]] {
        var out: [[AwayMic.Event]] = [[]]
        var frontier: [[AwayMic.Event]] = [[]]
        for _ in 0..<depth {
            var next: [[AwayMic.Event]] = []
            for s in frontier {
                for e in AwayMic.Event.allCases { next.append(s + [e]) }
            }
            out += next
            frontier = next
        }
        return out
    }

    /// The whole point. Whatever happened before it, an event that means
    /// the user could be back leaves the wake word on.
    @Test func afterAnyReturnTheWakeWordIsOn() {
        for s in sequences(depth: 5) where !s.isEmpty && AwayMic.isReturn(s.last!) {
            let r = run(s)
            #expect(r.wake, "wake word left OFF after \(s.map(String.init(describing:)).joined(separator: " → "))")
            #expect(!r.released, "still marked released after a return: \(s)")
        }
    }

    /// …including when it starts from off, which is what a sequence that
    /// locked twice then unlocked actually looks like.
    @Test func aReturnTurnsItOnEvenIfSomethingElseTurnedItOff() {
        for s in sequences(depth: 4) where !s.isEmpty && AwayMic.isReturn(s.last!) {
            #expect(run(s, wakeWordStartsOn: false).wake, "not restored from off after \(s)")
        }
    }

    /// And the saving is real: going away switches it off.
    @Test func goingAwayLetsTheMicrophoneGo() {
        #expect(!run([.locked]).wake)
        #expect(!run([.willSleep]).wake)
        #expect(run([.locked]).released)
    }

    /// Twice in a row is one release, not two — the second is a no-op, so
    /// nothing is asked of the audio graph that it is already doing.
    @Test func lockingTwiceOnlyReleasesOnce() {
        let first = AwayMic.decide(.locked, released: false, alwaysListening: true, meetingHasMic: false)
        #expect(first.wakeWord == false)
        let second = AwayMic.decide(.locked, released: true, alwaysListening: true, meetingHasMic: false)
        #expect(second.wakeWord == nil, "a second lock asked the audio graph to do it again")
        #expect(second.released)
    }

    /// A meeting keeps the microphone. People lock their screen and keep
    /// talking, and the recording is the whole point of that state.
    @Test func aMeetingKeepsTheMicrophoneThroughALock() {
        for s in sequences(depth: 4) {
            let r = run(s, meetingHasMic: true, wakeWordStartsOn: true)
            #expect(r.wake, "a meeting lost the microphone after \(s)")
        }
    }

    /// Nothing here switches the wake word on for someone who never turned
    /// it on. Unlocking a Mac whose owner uses the hotkey only must not
    /// start open-mic listening.
    @Test func itNeverTurnsTheWakeWordOnForSomeoneWhoDidNotAskForIt() {
        for s in sequences(depth: 4) {
            let r = run(s, alwaysListening: false, wakeWordStartsOn: false)
            #expect(!r.wake, "wake word switched itself on after \(s)")
        }
    }

    /// The sequence that would have caught the obvious bug: a lid closed on
    /// a locked Mac sends both, and waking sends `didWake` while still
    /// locked. If restore were guarded on the released flag, the flag would
    /// already be false by the time the unlock arrived.
    @Test func lockThenSleepThenWakeThenUnlockEndsListening() {
        let r = run([.locked, .willSleep, .didWake, .unlocked])
        #expect(r.wake)
        #expect(!r.released)
    }
}
