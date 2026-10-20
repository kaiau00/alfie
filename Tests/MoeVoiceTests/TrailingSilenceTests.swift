import Foundation
import Testing
@testable import MoeVoice

/// Inworld's trailing silence, taken off the end of a reply.
///
/// The fixtures are the last second of each `a_current` render in
/// `~/moe-voice-notes/inworld-ab/` (2026-09-23): exactly what Inworld sends
/// Moe today — `inworld-tts-2-flash`, Ashley, PCM16 at 24 kHz — cut with
/// nothing processed. Measured on them with numpy, the trailing run after the
/// last sample at or above −45 dBFS is:
///
///     r1_short 11482 samples (478 ms)   r2_meeting 12435 (518 ms)
///     r3_list  11482 (478 ms)           r4_status  12255 (511 ms)
///
/// and across all 57 generations of all 24 renders it is 432–558 ms, with
/// the last 150 ms of every generation at or below −50.5 dBFS.
struct TrailingSilenceTests {

    static let rate = 24_000.0
    static let measuredTrail = ["r1_short": 11482, "r2_meeting": 12435,
                                "r3_list": 11482, "r4_status": 12255]

    static func fixture(_ name: String) throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: "inworld-tail-\(name)", withExtension: "pcm",
                                                 subdirectory: "Fixtures"))
        return InworldWire.pcm16ToFloats(try Data(contentsOf: url))
    }

    /// Runs `audio` through a trimmer in frames the size Inworld sends.
    static func trim(_ audio: [Float], frame: Int = 2_400) -> (out: [Float], keep: [Float], held: [Float]) {
        var t = TrailingSilence(sampleRate: rate)
        var out: [Float] = []
        var i = 0
        while i < audio.count {
            out += t.push(Array(audio[i..<min(i + frame, audio.count)]))
            i += frame
        }
        let end = t.finish()
        return (out, end.keep, end.held)
    }

    /// The measured tails lose all but 120 ms: 358–398 ms off every reply's
    /// end, which is how much sooner "done speaking" fires.
    @Test func theMeasuredTailsAreCutTo120Milliseconds() throws {
        for (name, trail) in Self.measuredTrail {
            let audio = try Self.fixture(name)
            let (out, keep, held) = Self.trim(audio)
            #expect(out.count + keep.count + held.count == audio.count, "\(name): nothing invented or lost")
            #expect(keep.count == Int(Self.rate * 0.12), "\(name): a natural stop kept")
            #expect(held.count == trail - keep.count, "\(name): the measured \(trail)-sample tail, less 120 ms")
            let heldMs = Double(held.count) / Self.rate * 1000
            #expect(heldMs > 350 && heldMs < 400, "\(name): \(heldMs) ms taken off")
            // What is played is the start of the audio, in order, untouched.
            #expect(Array(audio[..<(out.count + keep.count)]) == out + keep)
        }
    }

    /// Nothing held is speech: the threshold sits above the loudest floor
    /// measured (−50.5 dBFS) and the held run never reaches −45 dBFS.
    @Test func nothingHeldIsSpeech() throws {
        let limit = pow(10, TrailingSilence.thresholdDBFS / 20)
        for name in Self.measuredTrail.keys {
            let (_, _, held) = Self.trim(try Self.fixture(name))
            #expect(held.allSatisfy { abs($0) < limit }, "\(name)")
        }
    }

    /// A pause inside a generation is held only until the next word and then
    /// played whole: the output is the input, in order.
    @Test func aPauseInsideAGenerationIsKeptWhole() {
        let word: [Float] = (0..<4_800).map { Float(sin(Double($0) * 0.1) * 0.3) }
        let pause = [Float](repeating: 0.0003, count: 9_600)    // 400 ms at about −70 dBFS
        let audio = word + pause + word
        let (out, keep, held) = Self.trim(audio, frame: 960)
        #expect(out == audio)
        #expect(keep.isEmpty && held.isEmpty)
    }

    // MARK: - The held tail between generations

    /// Another generation following while the player is still busy gets the
    /// whole pause back: sentence gaps stay what Inworld made them.
    @Test func aFollowingGenerationGetsTheWholePause() {
        let t0 = Date()
        let tail = HeldTail(samples: [Float](repeating: 0, count: 8_760), sampleRate: Self.rate,
                            startsAt: t0.addingTimeInterval(1))
        #expect(tail.remainder(now: t0, playerHasAudio: true).count == 8_760)
    }

    /// When the player has already run dry, the silence is happening in real
    /// time; only what is left of it is owed, so the gap is never longer
    /// than it would have been untrimmed.
    @Test func aPlayerThatRanDryIsOwedOnlyTheRest() {
        let t0 = Date()
        let tail = HeldTail(samples: [Float](repeating: 0, count: 8_760), sampleRate: Self.rate, startsAt: t0)
        #expect(tail.remainder(now: t0.addingTimeInterval(0.1), playerHasAudio: false).count == 8_760 - 2_400)
        #expect(tail.remainder(now: t0.addingTimeInterval(2), playerHasAudio: false).isEmpty)
        #expect(tail.milliseconds == 365)
    }
}
