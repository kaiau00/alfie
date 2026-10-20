import Foundation

/// How long a turn waits for its accurate re-read before giving up on it.
///
/// ## The bug this is
///
/// On **2026-09-09 01:29:28Z** the owner held the key and dictated an
/// email for 59.6 seconds. The live recogniser heard it and the words
/// appeared on the island as he spoke, exactly as they should. Then the
/// turn vanished: no reply, nothing in the transcript, nothing anywhere.
///
/// The log has the whole thing:
///
/// ```text
/// 01:28:58  hold ended
/// 01:28:59  stt: assemblyai session 34d08869 open, model universal-3-5-pro
/// 01:29:28  accurate transcription: gave up after 30 s
/// 01:29:28  turn: re-read 59.6 s in 30.2 s, confidence -, level 0.078
/// 01:29:28  heard: ""
/// 01:29:42  stt: assemblyai 59.6 s in 43636 ms (batch)   ← the answer, 14 s late
/// ```
///
/// Two independent deadlines were running, and the wrong one was tighter.
/// `AssemblyAIStream` gives a batch read `finalGraceSeconds + seconds /
/// processingRate` — 51.7 s for that audio, and it answered inside it, at
/// 43.6 s. The turn's own deadline was a flat 30 s, chosen when the
/// accurate read was the local model (where a 90 s turn costs a few
/// seconds) and never revisited when a cloud batch path appeared. **A flat
/// 30 is the tighter of the two for every utterance longer than 32.5
/// seconds**, so the outer deadline — the one meant only as a backstop
/// against a wedged model — became the thing that decided the turn.
///
/// ## The rule
///
/// A backstop must be looser than everything it backs. So the deadline
/// grows with the audio, at a rate deliberately *slower* than any
/// backend's, plus a floor for a local model still coming up cold.
///
/// `deadlineIsLooserThanTheBackendsOwn` in the tests holds this against
/// `AssemblyAIStream`'s real numbers rather than against a repeated
/// literal: if either side moves, that test is what notices.
public enum TurnReadDeadline {

    /// Enough for the local model to load and read a short turn.
    public static let floorSeconds: Double = 30

    /// Added on top of the per-second allowance, for connecting, the
    /// force-end round trip, and the final settling.
    public static let graceSeconds: Double = 8

    /// Seconds of patience per second of speech. One is slower than the
    /// slowest backend on record (AssemblyAI's burst throughput is 1.25×
    /// real time), which is what keeps this deadline the backstop rather
    /// than the one that fires.
    public static let secondsPerSecondOfAudio: Double = 1

    public static func seconds(forAudioSeconds audio: Double) -> TimeInterval {
        max(floorSeconds, graceSeconds + max(0, audio) * secondsPerSecondOfAudio)
    }
}
