import Foundation

/// What the acoustic self-test measures, and what it means.
/// VOICE-PLAN.md §7.
///
/// Barge-in and "Hey Moe" both need the microphone to stay open while
/// Moe speaks, which only works if the canceller actually removes Moe's
/// voice from what the microphone hears. Whether it does is a property of
/// the *device pair* — built-in mic and built-in speakers is the case
/// Apple's voice processing is built for; a USB microphone beside a
/// Bluetooth speaker is the case it cannot help with, and there the open
/// microphone hears Moe and answers itself.
///
/// The test: measure the room while Moe is quiet, then measure it while
/// Moe speaks a sentence. The difference is the leak.
public enum EchoTest {

    public enum Verdict: Equatable, Sendable {
        /// The canceller is doing its job: talking over Moe works.
        case clean
        /// Some of Moe comes back. Barge-in will work, and may trip on a
        /// loud passage.
        case workable
        /// Moe hears itself. Barge-in would cut Moe off constantly.
        case leaky
        /// Nothing came out at all (muted, wrong output device).
        case silent
        /// The test could not run (no microphone, no voice processing).
        case unavailable(String)
    }

    /// Decibels of level added while Moe spoke, over the quiet room.
    ///
    /// - Parameters:
    ///   - floorRms: RMS of the capture while nothing was played.
    ///   - spokenRms: RMS of the capture while Moe spoke.
    public static func leakDb(floorRms: Float, spokenRms: Float) -> Float {
        let floor = max(floorRms, 1e-6)
        let spoken = max(spokenRms, 1e-9)
        return 20 * log10(spoken / floor)
    }

    /// - Parameters:
    ///   - leakDb: from `leakDb(floorRms:spokenRms:)`.
    ///   - heardOwnWords: the recogniser read Moe's own sentence back out
    ///     of the microphone — proof the leak is intelligible, not just
    ///     loud.
    ///   - playedAnything: audio actually reached the speakers.
    public static func verdict(leakDb: Float, heardOwnWords: Bool, playedAnything: Bool = true) -> Verdict {
        guard playedAnything else { return .silent }
        if heardOwnWords { return .leaky }
        if leakDb < 6 { return .clean }
        if leakDb < 14 { return .workable }
        return .leaky
    }

    /// One line for Settings, in the second person.
    public static func summary(_ v: Verdict) -> (good: Bool, text: String) {
        switch v {
        case .clean:
            return (true, "Moe can hear you while it speaks. Interrupting works on this microphone and these speakers.")
        case .workable:
            return (true, "Moe can hear you while it speaks, with some of its own voice coming back. Interrupting works; in a loud passage it may stop for itself.")
        case .leaky:
            return (false, "Moe hears itself through this microphone, so interrupting would stop it constantly. Headphones, or the built-in microphone and speakers together, fix this.")
        case .silent:
            return (false, "Nothing came out of the speakers, so there was nothing to measure. Check the output device and the volume.")
        case .unavailable(let why):
            return (false, why)
        }
    }
}
