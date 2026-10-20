import AVFoundation
import Foundation
import MoeObjC

// Go/no-go gate for Moe's audio layer.
//
// The whole always-on design rests on one thing: putting the microphone and
// the assistant's own speech on a single AVAudioEngine with voice processing
// enabled, so macOS's echo canceller has Moe's output in its reference path
// and the mic doesn't hear Moe talking. If that doesn't work here, "Hey Moe"
// will keep triggering itself and the design has to change.
//
// Two known failure modes this checks for:
//
//  1. The silent-mic trap. Enabling voice processing swaps the engine to a
//     duplex VoiceProcessingIO unit. If the graph is incomplete when you do
//     it, input silently comes back as 9-channel 48kHz at about -91 dB —
//     alive, correctly shaped, and carrying no audio at all.
//  2. Echo cancellation not actually engaging, which is only visible by
//     playing sound and measuring what leaks back into the mic.
//
// Run:  swift run AudioGate

// MARK: - Measurement

final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sum: Double = 0
    private var count: Int = 0
    private var peak: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var localSum: Double = 0
        var localPeak: Float = 0
        for i in 0..<n {
            let v = data[i]
            localSum += Double(v * v)
            localPeak = max(localPeak, abs(v))
        }
        lock.lock()
        sum += localSum
        count += n
        peak = max(peak, localPeak)
        lock.unlock()
    }

    /// Returns (rms dBFS, peak dBFS, frames)
    func drain() -> (Float, Float, Int) {
        lock.lock()
        let s = sum, c = count, p = peak
        sum = 0; count = 0; peak = 0
        lock.unlock()
        guard c > 0 else { return (-200, -200, 0) }
        let rms = (s / Double(c)).squareRoot()
        return (db(Float(rms)), db(p), c)
    }

    private func db(_ x: Float) -> Float {
        20 * log10(max(x, 1e-10))
    }
}

func line() { print(String(repeating: "─", count: 62)) }

// MARK: - Setup

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let meter = LevelMeter()

print("\nMoe — audio go/no-go gate")
line()
print("Machine: \(ProcessInfo.processInfo.operatingSystemVersionString)")

// Ask for the microphone before touching the engine.
let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
    AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
}
guard micGranted else {
    print("""

    ✗ Microphone access denied.

      Grant it to whatever is running this (your terminal) in
      System Settings › Privacy & Security › Microphone, then re-run.
    """)
    exit(2)
}
print("✓ microphone permission granted")

let input = engine.inputNode
let output = engine.outputNode

let formatBefore = input.outputFormat(forBus: 0)
print("  input format before VP: \(Int(formatBefore.sampleRate))Hz, \(formatBefore.channelCount)ch")

// Enable voice processing while the engine is stopped — this is the part that
// has to happen before the graph is built, not after.
do {
    try input.setVoiceProcessingEnabled(true)
    try output.setVoiceProcessingEnabled(true)
    print("✓ voice processing enabled (echo cancellation + noise suppression)")
} catch {
    print("""

    ✗ setVoiceProcessingEnabled failed: \(error.localizedDescription)

      This is the gate failing. Moe would hear its own voice.
    """)
    exit(1)
}

let formatAfter = input.outputFormat(forBus: 0)
let outputHW = output.inputFormat(forBus: 0)
print("  input format after VP:  \(Int(formatAfter.sampleRate))Hz, \(formatAfter.channelCount)ch")
print("  output expects:         \(Int(outputHW.sampleRate))Hz, \(outputHW.channelCount)ch")

// Voice processing hands back a multi-channel input bus (7ch here: the
// processed mic plus the canceller's reference channels). Two rules follow,
// and getting either wrong is what produces -10875 or a dead microphone:
//
//   * Tap with the bus's OWN format. Passing a mono format to installTap on a
//     7-channel bus is a format mismatch, not a downmix request. We take
//     channel 0 — the processed mic — inside the tap instead.
//   * Connect every edge with a format the destination actually accepts,
//     never nil, because nil re-derives from a bus that just changed shape.
let sampleRate = formatAfter.sampleRate
// `standardFormatWithSampleRate:channels:` returns **nil** above two
// channels (measured — ResamplerChannelTests). Force-unwrapping it here
// crashed the gate on any machine whose output device is wider than
// stereo: an HDMI display, spatial audio, an aggregate. A gate that
// crashes instead of reporting is the one thing it must never do.
let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: outputHW.channelCount) ?? outputHW

engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
engine.connect(engine.mainMixerNode, to: output, format: playbackFormat)

// Through MoeObjC: a format mismatch raises an Objective-C exception that
// Swift cannot catch — and a gate that crashes instead of reporting is the
// one thing it must never do.
do {
    try MoeObjC.catchException {
        input.installTap(onBus: 0, bufferSize: 1024, format: formatAfter) { buffer, _ in
            meter.add(buffer)
        }
    }
} catch {
    print("✗ installTap refused: \(error.localizedDescription)")
    exit(1)
}

func start() throws { engine.prepare(); try engine.start() }

do {
    try start()
    print("✓ engine started")
} catch {
    print("  first attempt failed (\(error.localizedDescription)); retrying with the hardware format…")
    // Fallback: let the mixer sit at the hardware format on both sides.
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(engine.mainMixerNode)
    engine.connect(player, to: engine.mainMixerNode, format: outputHW)
    engine.connect(engine.mainMixerNode, to: output, format: outputHW)
    do {
        try start()
        print("✓ engine started (hardware format)")
    } catch {
        print("""

        ✗ GATE FAILED — the engine will not start with voice processing on.

          \(error.localizedDescription)

          input \(Int(formatAfter.sampleRate))Hz/\(formatAfter.channelCount)ch, \
        output \(Int(outputHW.sampleRate))Hz/\(outputHW.channelCount)ch

          Fall back to the Pipecat + LiveKit APM path.
        """)
        exit(1)
    }
}

// MARK: - Test tone

/// A loud, broadband, obviously-artificial sound. Broadband matters: echo
/// cancellers handle pure tones far better than speech-like noise, so a sine
/// wave here would flatter the result.
func makeNoise(seconds: Double, sampleRate: Double) -> AVAudioPCMBuffer {
    // format taken from the player as actually connected
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let fmt = player.outputFormat(forBus: 0)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    var phase: Double = 0
    for ch in 0..<Int(fmt.channelCount) {
        let ptr = buf.floatChannelData![ch]
        phase = 0
        for i in 0..<Int(frames) {
            // Broadband on purpose: echo cancellers flatter pure tones.
            let noise = Float.random(in: -1...1) * 0.35
            phase += 2 * Double.pi * (180 + 900 * Double(i) / Double(frames)) / sampleRate
            let tone = Float(sin(phase)) * 0.35
            ptr[i] = (noise + tone) * 0.9
        }
    }
    return buf
}

func measure(_ seconds: Double, label: String) async -> (rms: Float, peak: Float) {
    _ = meter.drain()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let (rms, peak, frames) = meter.drain()
    print(String(format: "  %-22s rms %7.1f dBFS   peak %7.1f dBFS   (%d frames)",
                 (label as NSString).utf8String!, rms, peak, frames))
    return (rms, peak)
}

line()
print("Measuring. Stay quiet for the first few seconds.\n")

// 1. Baseline — the room, with nothing playing.
let baseline = await measure(3.0, label: "silence (baseline)")

if baseline.peak < -80 {
    print("""

    ✗ GATE FAILED — the microphone is dead.

      Peak of \(String(format: "%.0f", baseline.peak)) dBFS over three seconds means no audio is
      arriving at all. This is the silent-mic trap: voice processing
      reconfigured the I/O unit and the graph came up wrong.

      Moe cannot use this audio path.
    """)
    engine.stop()
    exit(1)
}

// 2. Play the noise and measure what comes back in.
print("\n  playing test audio through the speakers…")
let noise = makeNoise(seconds: 4.0, sampleRate: formatAfter.sampleRate)
player.scheduleBuffer(noise, at: nil, options: [])
player.play()

// Skip the first moment: the canceller needs a beat to converge.
try? await Task.sleep(nanoseconds: 700_000_000)
let during = await measure(3.0, label: "during playback")

player.stop()
engine.stop()

// MARK: - Verdict

line()
let leak = during.rms - baseline.rms
print(String(format: "\nEcho leaking into the mic: %+.1f dB above the room\n", leak))

if leak < 6 {
    print("""
    ✓ GATE PASSED — echo cancellation is working.

      Moe's own voice is being removed from the microphone before it
      reaches speech recognition. Always-on listening is viable, and
      "Hey Moe" won't be triggered by Moe.
    """)
    exit(0)
} else if leak < 15 {
    print("""
    ~ PARTIAL — cancellation is engaging but leaving \(String(format: "%.0f", leak)) dB through.

      Workable, but the wake word must also be gated while Moe is
      speaking rather than relying on cancellation alone.
    """)
    exit(0)
} else {
    print("""
    ✗ GATE FAILED — the microphone is hearing the speakers at
      \(String(format: "%.0f", leak)) dB above room level.

      Echo cancellation is not doing its job on this machine. Moe would
      hear itself and interrupt itself. Fall back to the Pipecat +
      LiveKit APM path before building on this.
    """)
    exit(1)
}
