import Foundation

/// Getting the turn model the audio it can actually read.
///
/// Smart Turn is asked when the VAD reports the person has stopped, and the
/// VAD will not say so until it has heard `minSilenceDuration` of quiet —
/// 250 ms here. So the eight-second window handed to the model always ends
/// in a quarter-second of silence that the person did not put there, and the
/// model reads it as part of the utterance.
///
/// **Measured against the shipped model** (`smart-turn-v3.2-cpu.onnx`, 80
/// LibriSpeech test-clean clips, each scored whole — a speaker finishing —
/// and cut at 55% — a speaker still going), varying only how much silence
/// followed:
///
///     silence when asked   separates finished from mid-sentence by
///     0.00 s                                                  0.435
///     0.05 s                                                  0.416
///     0.10 s                                                  0.411
///     0.25 s  ← what Moe was doing                            0.285
///     0.80 s                                                  0.013
///     1.50 s                                                  0.004
///
/// Past about 0.8 s it cannot tell at all: it says "finished" to 42 of 60
/// clips that stop mid-phrase. The verdict stops being about the words and
/// becomes about the pause. At the 250 ms Moe was serving it, 38% of
/// mid-sentence clips came back "finished" — which is the owner's complaint,
/// in a number: he pauses to think and Moe takes the turn.
///
/// Trimming the pause off before asking takes that 38% to 20%.
public enum TurnAudio {

    /// How much of the pause to leave on when handing a turn to the model.
    ///
    /// Not zero, which is what this shipped as for an hour on 2026-09-05 and
    /// was the worst setting tested. Smart Turn's own contribution guide says
    /// what the training data looks like:
    ///
    /// > "Only once the speaker has been silent for **200ms** does Smart Turn
    /// > actually run. So ideally, each incomplete sample (and complete
    /// > sample) would end with around 200ms of silence. More silence than
    /// > this is also fine."
    ///
    /// Measured on 80 clips scored whole (a speaker finishing) and cut at 55%
    /// (a speaker still going), trimming each clip back to its own last voiced
    /// frame and then leaving this much of its own room tone:
    ///
    ///     kept    finished   mid-sentence   separation
    ///     0.00 s     0.376          0.210        0.166
    ///     0.10 s     0.467          0.209        0.258
    ///     0.20 s     0.543          0.215        0.328
    ///     0.30 s     0.645          0.223        0.422
    ///     0.50 s     0.640          0.219        0.421
    ///
    /// Trimming to nothing does not just lose separation — it drags
    /// *finished* down from 0.645 to 0.376, which is why the owner's genuinely
    /// finished turns were coming back 0.32 and 0.37 that evening, values the
    /// maintainer says should not exist in a healthy output. Past 0.3 s it
    /// flattens, so this is the knee.
    ///
    /// The job here is therefore **normalising the pause, not removing it**.
    /// `AudioPipeline`'s VAD reports a stop after 250 ms, and then the hop to
    /// read the buffer adds a variable tail on top; this caps that at a fixed
    /// 300 ms so every turn reaches the model looking like its training data.
    public static let pauseTheModelWasTrainedOn: Double = 0.30

    /// How far the streaming recogniser's partial lags the word it writes.
    /// Not measured, so taken as zero: the cut keeps the full trained pause
    /// after the partial's timestamp, which errs towards keeping a little
    /// more room than cutting into the last phoneme (review L1 — an
    /// invented 0.2 s could trim a quiet room's pause below what the model
    /// was trained on). Measure it before raising it.
    public static let recogniserLagSeconds: Double = 0

    /// Cut a turn's audio a short way after its last word, whatever follows.
    ///
    /// `trimTrailingSilence` trims by energy, against the clip's own peak.
    /// That is right in a quiet room and useless in a noisy one: a fan, a TV
    /// or music sits well above a twentieth of the speech peak, so nothing is
    /// trimmed and Smart Turn is handed the sentence followed by seconds of
    /// noise — which it reads as the person still going (p 0.01–0.26 on the
    /// owner's 34.7 s noise capture, 2026-09-07). The model was trained on
    /// speech followed by ~200–300 ms of quiet; past 0.8 s it cannot tell
    /// finished from unfinished at all (see the table above).
    ///
    /// The recogniser knows where the words are even when the level does
    /// not: cut at the last word, keeping `keep` of pause (less the lag
    /// already in the timestamp). Returns the input unchanged when the cut
    /// would leave almost nothing, or when the last word is recent anyway.
    public static func trimAfterLastWord(_ audio: [Float],
                                         sampleRate: Int = 16_000,
                                         secondsSinceLastWord: Double,
                                         keep: Double = pauseTheModelWasTrainedOn,
                                         recogniserLag: Double = recogniserLagSeconds) -> [Float] {
        let tailToKeep = max(0, keep - recogniserLag)
        let drop = secondsSinceLastWord - tailToKeep
        guard drop > 0, secondsSinceLastWord.isFinite else { return audio }
        let n = Int(drop * Double(sampleRate))
        guard audio.count - n > Int(0.3 * Double(sampleRate)) else { return audio }
        return Array(audio.prefix(audio.count - n))
    }

    /// Drop the silence from the end of a turn's audio.
    ///
    /// Level is judged against the clip's own loudest moment, not an
    /// absolute figure, because the gain a microphone runs at is not ours to
    /// assume — the same sentence arrives ten times louder through a headset
    /// than across a room.
    ///
    /// Returns the input unchanged when there is no clear speech in it. A
    /// buffer with nothing above the floor is a buffer this cannot reason
    /// about, and handing the model an empty array would make it answer a
    /// question about nothing.
    public static func trimTrailingSilence(_ audio: [Float],
                                           sampleRate: Int = 16_000,
                                           keep: Double = 0) -> [Float] {
        let frame = sampleRate / 100                     // 10 ms
        guard audio.count > frame * 2 else { return audio }

        var levels: [Float] = []
        levels.reserveCapacity(audio.count / frame)
        var i = 0
        while i + frame <= audio.count {
            var sum: Float = 0
            for s in audio[i..<(i + frame)] { sum += s * s }
            levels.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        guard let peak = levels.max(), peak > 0 else { return audio }

        // A twentieth of the loudest frame. Below this is room tone, breath
        // and the noise floor; a spoken syllable's quietest frame sits well
        // above it.
        let floor = peak * 0.05
        guard let last = levels.lastIndex(where: { $0 > floor }) else { return audio }

        let end = min(audio.count, (last + 1) * frame + Int(keep * Double(sampleRate)))
        return Array(audio[0..<end])
    }

    /// How long the person spoke in this turn: the whole span from the
    /// turn's first speech to its last, not the last VAD segment.
    ///
    /// Everything the window weighs is read off this many seconds of the
    /// capture — the loudness against the session, the owner match, the
    /// anchor — so a turn measured by its last segment is measured by
    /// whatever trailing word followed the person's last pause. That was
    /// the 2026-09-07 fix, and it never ran: the engine cleared the span
    /// when it opened the turn's trace, one step before reading it here,
    /// so every turn fell through to `lastSegment`. 2026-10-07 21:48:40Z,
    /// a 35-word request in the follow-up window was measured by its last
    /// segment: level 0.16 (the next turn, the same person: 1.31), owner
    /// and anchor skipped as too short, scored -1.2 and dropped as "not
    /// for Moe".
    public static func speechSeconds(turnStarted: Date?, turnEnded: Date?, lastSegment: Double,
                                     segmentBegan: Date?, now: Date = Date()) -> Double {
        if let began = turnStarted {
            return max(lastSegment, (turnEnded ?? now).timeIntervalSince(began))
        }
        if lastSegment > 0 { return lastSegment }
        return segmentBegan.map { now.timeIntervalSince($0) } ?? .infinity
    }
}
