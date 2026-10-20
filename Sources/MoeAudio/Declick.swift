import Foundation

/// Removes the single-sample impulses some speech models emit — the faint
/// taps you hear between words.
///
/// Found by measurement, not by guessing. Rendering the same sentence with
/// every engine and counting *impulses* — a sample that jumps and comes
/// straight back, which is energy at Nyquist and something band-limited
/// speech cannot produce — separates them completely:
///
///     engine / voice            impulses   rate
///     Kokoro af_heart            222–262   40–51 per second
///     PocketTTS alba                  57   13 per second
///     PocketTTS peter_yearsley         4   0.5 per second
///     Supertonic F1                    0   none
///
/// That is why the artefact is audible as an occasional tap rather than as
/// noise, and why it survives every other kind of tuning: it is not a chunk
/// seam (single sentences have the same rate as multi-chunk passages), not
/// the frame stitching (the step across an 80 ms Mimi frame boundary has the
/// same median as any other sample), and not the speed setting (Kokoro's rate
/// is flat from 1.00 down to 0.64).
///
/// **What this touches and what it must not.** A plosive is a fast attack but
/// a band-limited one: its first difference is large while its *second* stays
/// bounded, and it does not reverse direction inside a single sample. An
/// impulse does all three. Requiring all three together is what keeps a /t/
/// or /k/ burst out of the filter — and that conservatism is the whole point,
/// because the first and looser detector flagged 1,185 "clicks" in a passage
/// that was mostly consonants.
///
/// A repaired sample becomes the average of its neighbours. Nothing else in
/// the buffer is altered.
///
/// **What it does not catch.** An impulse is judged against the level around
/// it, so one sitting on the waveform's own peak is a smaller second
/// difference in relative terms and may be left — measured at 31 of 47 on a
/// synthetic tone, against 262 → 16 on a real Kokoro render, because real
/// impulses tend to land in the quieter gaps between words, which is also
/// where they are audible. Two adjacent full-scale impulses in opposite
/// directions are only partly repaired. Both are deliberate: the alternative
/// is a looser predicate, and a looser predicate smooths consonants.
public enum Declick {

    /// A sample is repaired only when all three hold:
    ///
    ///   - its second difference is at least `floor` in absolute terms, so
    ///     quiet numerical wobble is left alone;
    ///   - the step into it and the step out of it point opposite ways —
    ///     the "jumps and comes straight back" shape;
    ///   - that second difference exceeds `ratio` times the local RMS, so a
    ///     loud passage is judged against itself rather than against silence.
    public static let floor: Float = 300.0 / 32767.0
    public static let ratio: Float = 8
    /// ±50 ms, the window the local RMS is taken over.
    public static let windowSeconds: Double = 0.05

    /// Repair `samples` in place. Returns how many samples were repaired.
    ///
    /// - Parameter previous: the tail of the buffer before this one, when the
    ///   caller is streaming. Without it the first sample of every frame
    ///   cannot be judged, and at 80 ms a frame that is 12 chances a second
    ///   to miss one.
    /// How many times to walk the buffer.
    ///
    /// Each pass marks against the untouched signal and only then bridges, so
    /// a sample that becomes visible *because* its neighbour was mended is
    /// only found on the next walk. Both halves earn their keep, measured on
    /// the same Kokoro render (262 impulses to start):
    ///
    ///     one pass, one sample at a time      46 left
    ///     three passes, one sample at a time  16 left
    ///     two passes, bridging runs           43 left
    ///     four passes, bridging runs          32 left  ← shipped
    ///
    /// Bounded, and the predicate never loosens between passes, so this
    /// cannot creep into real audio however many times it runs.
    /// `MOE_DECLICK=0` turns the pass off, and `MOE_DECLICK=<n>` sets the
    /// pass count. Diagnostic only: it exists because "is the de-click
    /// making this worse" cannot be answered by reading the code, and
    /// rebuilding per experiment is how you stop running experiments.
    /// **Off by default, because it was solving the wrong problem and doing
    /// real harm while it did.**
    ///
    /// The taps Izzy heard were a starved `AVAudioPlayerNode`, not a dirty
    /// render — fixed by the pre-roll in `SpeechOut`. This pass was aimed at
    /// impulses in the rendered audio, and measured against Kokoro at the
    /// same speed with the pass on and off:
    ///
    ///     samples changed          225 of 117,000 (0.19%)
    ///     repair size              median 5,830, max 11,357 of 32,767
    ///     high-frequency content   -8.95%
    ///
    /// A median repair of 5,830 is 18% of full scale, 225 times in five
    /// seconds, and nearly a tenth of the treble gone. Kokoro's 40–51
    /// "impulses" a second are not artefacts — they are what its vocoder
    /// sounds like, and the predicate here cannot tell the difference. Izzy's
    /// words on the result were "scratchy and slow"; the scratchy half was
    /// this.
    ///
    /// It stays in the tree with its twelve tests because the measurement is
    /// worth keeping and because PocketTTS *does* carry a handful of genuine
    /// impulses (4 in 7.5 s) — but 4 repairs is not worth a filter that can
    /// cost 9% of the treble when it is wrong. `MOE_DECLICK=4` turns it back
    /// on for anyone who wants to re-measure.
    public static let passes: Int = {
        guard let raw = ProcessInfo.processInfo.environment["MOE_DECLICK"],
              let n = Int(raw), n >= 0, n <= 16 else { return 0 }
        return n
    }()

    /// - Parameter passes: how many walks to make. Defaults to `Declick.passes`
    ///   — which is 0, so production calls are a no-op unless `MOE_DECLICK` is
    ///   set. Tests pass a count explicitly, because they are checking the
    ///   algorithm rather than whether it is switched on; conflating the two
    ///   is how turning it off broke eight of them.
    @discardableResult
    public static func repair(_ samples: inout [Float], sampleRate: Double,
                              previous: [Float] = [],
                              passes: Int = Declick.passes) -> Int {
        guard passes > 0 else { return 0 }
        var total = 0
        for _ in 0..<passes {
            let n = onePass(&samples, sampleRate: sampleRate, previous: previous)
            total += n
            if n == 0 { break }
        }
        return total
    }

    /// The longest run of consecutive bad samples that will be bridged.
    ///
    /// Mending one sample at a time uses its neighbour as the reference, and
    /// when that neighbour is itself an impulse the repair is dragged towards
    /// it — two adjacent full-scale spikes came out only 24% better. Bridging
    /// the whole run from the good samples on either side fixes that. Kept
    /// short on purpose: at four samples and up, 24 kHz audio can legitimately
    /// hold a transient, and bridging one would audibly blunt it.
    public static let maxRun = 3

    @discardableResult
    private static func onePass(_ samples: inout [Float], sampleRate: Double,
                                previous: [Float]) -> Int {
        guard samples.count > 2 else { return 0 }

        // Judge against the joined signal so a frame edge is not a blind
        // spot, but only ever write back into `samples`.
        let lead = Array(previous.suffix(1))
        let work = lead + samples
        let offset = lead.count

        let window = max(1, Int(sampleRate * windowSeconds))

        // A prefix sum of squares, so the local RMS is two lookups instead of
        // a 2,400-sample loop.
        //
        // The first version recomputed the window every 10 ms, which sounds
        // cheap and is not: ±50 ms at 24 kHz is 2,400 samples summed every
        // 240, so each pass touched every sample ten times, and there are
        // four passes. Measured on Kokoro, whose backend renders a whole
        // sentence in one buffer, it took first audio from 171 ms to 652 ms —
        // a de-click that cost more than the artefact. With prefix sums each
        // pass is one walk, and the window can be exact at every sample
        // rather than approximated every 240.
        var prefix = [Double](repeating: 0, count: work.count + 1)
        for k in 0..<work.count {
            prefix[k + 1] = prefix[k] + Double(work[k]) * Double(work[k])
        }
        func rmsAt(_ index: Int) -> Float {
            let lo = max(0, index - window)
            let hi = min(work.count, index + window)
            guard hi > lo else { return 0 }
            return Float(((prefix[hi] - prefix[lo]) / Double(hi - lo)).squareRoot())
        }

        // 1. Mark. Judged against the untouched signal, so one repair cannot
        //    change the verdict on the next sample within a pass.
        var bad = [Bool](repeating: false, count: work.count)
        var i = max(1, offset)
        while i < work.count - 1 {
            let rms = rmsAt(i)
            let prev = work[i - 1], here = work[i], next = work[i + 1]
            let second = abs(prev - 2 * here + next)
            if second >= floor,
               second > ratio * max(rms, 1e-6),
               (here - prev) * (next - here) < 0 {
                bad[i] = true
            }
            i += 1
        }

        // 2. Bridge each run from the good samples either side.
        var repaired = 0
        var k = max(1, offset)
        while k < work.count - 1 {
            guard bad[k] else { k += 1; continue }
            var end = k
            while end + 1 < work.count - 1, bad[end + 1] { end += 1 }
            let length = end - k + 1
            guard length <= maxRun else { k = end + 1; continue }
            let left = work[k - 1]
            let right = work[end + 1]
            for j in k...end {
                let t = Float(j - k + 1) / Float(length + 1)
                let mended = left + (right - left) * t
                let index = j - offset
                if index >= 0, index < samples.count {
                    samples[index] = mended
                    repaired += 1
                }
            }
            k = end + 1
        }
        return repaired
    }

    /// How many impulses are in `samples`, changing nothing. For the bench
    /// and the tests: the same predicate as `repair`, counted rather than
    /// applied.
    public static func count(in samples: [Float], sampleRate: Double) -> Int {
        var copy = samples
        return repair(&copy, sampleRate: sampleRate, passes: max(1, passes))
    }

    /// RMS of the samples within `window` either side of `index`.
    private static func localRMS(_ d: [Float], around index: Int, window: Int) -> Float {
        let lo = max(0, index - window)
        let hi = min(d.count, index + window)
        guard hi > lo else { return 0 }
        var sum: Float = 0
        for k in lo..<hi { sum += d[k] * d[k] }
        return (sum / Float(hi - lo)).squareRoot()
    }
}
