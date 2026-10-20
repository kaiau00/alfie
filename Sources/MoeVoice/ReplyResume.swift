import Foundation

/// What happens to a paused reply when the voice that paused it turns out
/// to be nothing (research-interruptions.md §5, LiveKit's
/// `resume_false_interruption`): a short hold carries on from the very
/// sample, because the person barely noticed; a long one starts the
/// sentence again, because nobody picks up a sentence mid-word after a
/// second and a half of silence.
public enum ReplyResume: Equatable, Sendable {
    case inPlace
    case restartSentence

    /// Held for less than this, carry on in place.
    ///
    /// Not 1.5 s (review M7): a false interruption is only known to be false
    /// once the person has stopped, the VAD has said so (0.25–0.5 s), the
    /// turn has been decided and read back (150 ms p50, 392 ms p90, measured
    /// 2026-09-06), and the echo/owner/addressee checks have run — rarely
    /// under 1.5 s after the pause, so a 1.5 s line restarted every
    /// sentence. 3 s covers that path for a two-or-three-word false alarm;
    /// past it the person has waited long enough that picking up mid-word
    /// sounds like a skip.
    public static let inPlaceUnder = 3.0

    public static func after(pausedFor seconds: Double) -> ReplyResume {
        seconds < inPlaceUnder ? .inPlace : .restartSentence
    }
}

/// The duck's shape: how Moe gets quieter when a voice starts over it, and
/// how it comes back. An instant cut and an instant restore both sound like
/// a glitch; −14 dB over 30–50 ms down and ~200 ms back up is what reads as
/// yielding (research-interruptions.md §5).
public enum DuckRamp {

    /// −14 dB: 20·log10(0.2) = −13.98.
    public static let duckedGain: Float = 0.2
    public static let downSeconds = 0.04
    public static let upSeconds = 0.2
    /// How often the gain is stepped.
    public static let stepSeconds = 0.005

    /// The gain `t` seconds into a ramp from `from` to `to` over `duration`,
    /// linear in decibels (a linear-gain ramp spends most of its time near
    /// the loud end, which the ear hears as a late duck).
    public static func gain(from: Float, to: Float, duration: Double, at t: Double) -> Float {
        guard duration > 0, t < duration else { return to }
        guard t > 0 else { return from }
        let floor: Float = 1e-4
        let a = 20 * log10(max(from, floor)), b = 20 * log10(max(to, floor))
        let db = a + (b - a) * Float(t / duration)
        return pow(10, db / 20)
    }

    /// The steps of one ramp: (seconds from its start, gain), ending on `to`.
    public static func steps(from: Float, to: Float, duration: Double,
                             step: Double = stepSeconds) -> [(t: Double, gain: Float)] {
        guard duration > 0 else { return [(0, to)] }
        var out: [(Double, Float)] = []
        var t = step
        while t < duration - 1e-9 {
            out.append((t, gain(from: from, to: to, duration: duration, at: t)))
            t += step
        }
        out.append((duration, to))
        return out
    }
}
