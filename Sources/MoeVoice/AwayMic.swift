import Foundation

/// Whether to hold the microphone open while nobody is at the Mac.
///
/// The audio graph is up around the clock because the wake word needs it,
/// and even with Apple's canceller bypassed that is about a ninth of a CPU
/// core — the voice-processing unit, the VAD, the resampling — spent
/// listening to an empty room. A laptop shut on a desk overnight is the
/// case that makes someone uninstall an app they otherwise like.
///
/// **The saving is not the hard part; coming back is.** A Moe that quietly
/// stops answering to its name after an unlock is far worse than the CPU it
/// saves, and it would be almost impossible to notice going wrong: you say
/// "Hey Moe", nothing happens, you assume you mumbled. So the rule is
/// written here, as data, and `AwayMicTests` runs every ordering of these
/// events through it and requires the wake word to be on at the end of any
/// sequence where the user could be back.
///
/// Four notifications can reach this and they do not arrive in a tidy
/// order: locking a Mac that then sleeps sends both, waking a sleeping Mac
/// that is still locked sends `didWake` before `screenIsUnlocked`, and a
/// closed lid can send `willSleep` with no lock at all.
public enum AwayMic {

    public enum Event: CaseIterable, Sendable {
        /// The screen locked.
        case locked
        /// The screen unlocked — the user is definitely back.
        case unlocked
        /// The Mac is going to sleep.
        case willSleep
        /// The Mac woke. The screen may still be locked, but something
        /// happened, so this counts as "might be back".
        case didWake
    }

    /// What the app should do about the wake word, and what to remember.
    public struct Decision: Equatable, Sendable {
        /// `true` to switch the wake word on, `false` off, `nil` to leave
        /// it alone.
        public var wakeWord: Bool?
        /// The new value of "we let the microphone go because nobody was
        /// here".
        public var released: Bool
    }

    /// - Parameters:
    ///   - released: whether this already let the microphone go.
    ///   - alwaysListening: the wake word is switched on at all. Nothing
    ///     here turns it on for someone who never asked for it.
    ///   - meetingHasMic: a meeting owns the microphone, or is recording.
    ///     A recording outlives a lock — people lock the screen and keep
    ///     talking — so this never takes the microphone from one.
    public static func decide(_ event: Event,
                              released: Bool,
                              alwaysListening: Bool,
                              meetingHasMic: Bool) -> Decision {
        switch event {
        case .locked, .willSleep:
            // Nobody is there. Let it go — once.
            guard alwaysListening, !meetingHasMic, !released else {
                return Decision(wakeWord: nil, released: released)
            }
            return Decision(wakeWord: false, released: true)

        case .unlocked, .didWake:
            // The user could be back. Ask for the wake word whatever the
            // remembered flag says.
            //
            // Deliberately not `guard !released`: if a lock and a sleep
            // both fired, or a meeting started while the screen was locked
            // and the release was skipped, that flag is not a reliable
            // account of what the wake word is actually doing. Switching it
            // on is idempotent, so the safe thing is to ask every time.
            guard alwaysListening, !meetingHasMic else {
                return Decision(wakeWord: nil, released: false)
            }
            return Decision(wakeWord: true, released: false)
        }
    }

    /// Does this event mean the user could be back at the Mac?
    public static func isReturn(_ event: Event) -> Bool {
        switch event {
        case .unlocked, .didWake: return true
        case .locked, .willSleep: return false
        }
    }
}
