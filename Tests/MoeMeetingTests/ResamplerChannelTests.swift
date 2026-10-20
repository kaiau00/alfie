import AVFoundation
import Foundation
import Testing
@testable import MoeMeeting

// What the microphone side of a meeting can be tested without a microphone.
//
// Nothing here opens a device, plays a sound or records anything: every
// buffer is synthesised. That is the point — the defects these cover were
// found in a recording after the fact, and the only way they stop coming
// back is if the claims in the comments are executable.

// MARK: - Helpers

/// A non-interleaved 48 kHz Float bus of `n` channels. Note the shape of
/// this helper: `AVAudioFormat(standardFormatWithSampleRate:channels:)`
/// returns **nil** for any count above two, which is why a layout is needed
/// at all and why nothing in the capture path may force-unwrap it.
func testBus(_ n: UInt32) -> AVAudioFormat? {
    if n <= 2 { return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(n)) }
    guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | n)
    else { return nil }
    return AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
}

/// 100 ms of silence with a 440 Hz tone at half amplitude (-9.0 dBFS rms) on
/// exactly one channel.
func testTone(on channel: Int, of format: AVAudioFormat,
                  frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<Int(format.channelCount) {
        let p = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) {
            p[i] = ch == channel ? Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) * 0.5 : 0
        }
    }
    return buffer
}

func testRms(_ buffer: AVAudioPCMBuffer?) -> Float {
    guard let buffer, let d = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -200 }
    var s: Double = 0
    for i in 0..<Int(buffer.frameLength) { s += Double(d[i]) * Double(d[i]) }
    return 20 * log10(max(Float((s / Double(buffer.frameLength)).squareRoot()), 1e-10))
}

// MARK: - What AVAudioConverter actually does with channels

struct ResamplerChannelTests {

    /// The claim this module used to make in a comment — "stereo is
    /// downmixed by the converter (L/R averaged)" — was false. Left alone,
    /// the converter takes channel 0 and throws channel 1 away. Every
    /// stereo source in this package went through that, the system tap
    /// (48 kHz stereo) included.
    @Test func theRightChannelOfAStereoSourceIsNotThrownAway() throws {
        let format = try #require(testBus(2))
        let resampler = try #require(Resampler(from: format))
        // Averaging two channels, one of which is silent, costs 6 dB: a
        // -9.0 dBFS tone comes out at -15.0. What must not happen is -200.
        #expect(abs(testRms(resampler.convert(testTone(on: 1, of: format))) - (-15)) < 1.5)
        #expect(abs(testRms(resampler.convert(testTone(on: 0, of: format))) - (-15)) < 1.5)
    }

    /// The failure this makes impossible. Handing a bus wider than stereo to
    /// AVAudioConverter and letting it "do the channel mapping" does not
    /// downmix and does not fail: it returns `.inputRanDry`, a nil error, a
    /// full-length output buffer, and every sample in it zero. An hour of a
    /// meeting would be written to disk as digital silence with nothing
    /// anywhere reporting a problem. `Resampler` refuses to be built that
    /// way instead.
    @Test func aBusWiderThanStereoMustNameItsChannel() throws {
        let format = try #require(testBus(7))
        #expect(Resampler(from: format) == nil)
        #expect(Resampler(from: format, channel: 7) == nil)
        #expect(Resampler(from: format, channel: -1) == nil)
        #expect(Resampler(from: format, channel: 6) != nil)
    }

    /// The one the task turns on: channel 0 silent, the tone on channel 6,
    /// seven channels wide — and the tone survives at full level.
    @Test func aToneOnTheLastChannelOfASevenChannelBusSurvives() throws {
        let format = try #require(testBus(7))
        let resampler = try #require(Resampler(from: format, channel: 6))
        #expect(abs(testRms(resampler.convert(testTone(on: 6, of: format))) - (-9)) < 1.5)
    }

    /// And the mirror image, which is the bug as it would look in a
    /// recording: ask for channel 0 when the microphone is on channel 6 and
    /// you get silence, quietly, with no error anywhere.
    @Test func askingForTheWrongChannelIsSilentAndSaysNothing() throws {
        let format = try #require(testBus(7))
        let resampler = try #require(Resampler(from: format, channel: 0))
        #expect(testRms(resampler.convert(testTone(on: 6, of: format))) < -100)
    }

    @Test func monoPassesThrough() throws {
        let format = try #require(testBus(1))
        let resampler = try #require(Resampler(from: format))
        #expect(abs(testRms(resampler.convert(testTone(on: 0, of: format))) - (-9)) < 1.5)
    }
}
