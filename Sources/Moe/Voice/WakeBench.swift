import AVFoundation
import FluidAudio
import Foundation
import MoeVoice

/// One clip through the real pipeline — VAD gating, stride-aligned
/// windows, the policy — with every head score kept.
///
/// This is the body of `Moe --wake-bench`, and it is also what Settings
/// runs over the person's own recordings to pick their threshold, so a
/// number the bench prints and a number the pane says are the same
/// measurement. Nothing here reads the microphone.
enum WakeBench {

    struct Replay {
        /// Every head score with its audio time, in order.
        var trace: [WakeCalibration.Sample] = []
        /// Where the policy fired, with the score.
        var hits: [(time: Double, score: Float)] = []
        var peak: Float = 0
    }

    /// Decode any file AVAudioFile reads to mono float at its own rate;
    /// the pipeline resamples.
    static func decode(_ file: URL) -> (mono: [Float], rate: Double)? {
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil, let ch = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels { for i in 0..<n { mono[i] += ch[c][i] / Float(channels) } }
        return (mono, audio.processingFormat.sampleRate)
    }

    /// Silence fed before every clip, so the pre-roll is full when it
    /// starts. Trace and hit times count from the start of the lead-in.
    static let leadSeconds = 2.2

    /// Feed one clip the way the bench always has: 2.2 s of lead-in
    /// silence so the pre-roll is full before the clip starts, the clip
    /// in 20 ms pieces, then a second of tail so the VAD closes.
    static func replay(_ mono: [Float], rate: Double, head: WakeHead, vad: VadManager,
                       policy: WakePolicy) async -> Replay {
        final class Box: @unchecked Sendable {
            var replay = Replay(); var fed = 0.0
        }
        let box = Box()
        let pipeline = AudioPipeline { out in
            if case .woke(let s) = out { box.replay.hits.append((box.fed, s)) }
        }
        await pipeline.attach(vad: vad)
        await pipeline.attach(wake: head, policy: policy)
        await pipeline.setWakeProbe { score, at in
            box.replay.peak = max(box.replay.peak, score)
            box.replay.trace.append(.init(time: at, score: score))
        }
        await pipeline.setWake(true)
        await head.forget()
        let n = mono.count
        await pipeline.ingest([Float](repeating: 0, count: Int(rate * leadSeconds)), rate: rate)
        let piece = Int(rate * 0.02)
        var i = 0
        while i < n {
            let end = min(n, i + piece)
            box.fed = Double(i) / rate
            await pipeline.ingest(Array(mono[i..<end]), rate: rate)
            i = end
        }
        box.fed = Double(n) / rate
        await pipeline.ingest([Float](repeating: 0, count: Int(rate * 1.0)), rate: rate)
        await pipeline.setWake(false)
        return box.replay
    }

    /// The hits the recogniser confirms (`WakeConfirm`): for each, the two
    /// seconds of the clip the head fired on, read by the local recogniser
    /// the app confirms with. Hit times are file times (`box.fed`).
    static func confirmed(_ hits: [(time: Double, score: Float)], mono: [Float], rate: Double,
                          asr: ParakeetBackend, spotter: WakeSpotter) async -> [(time: Double, score: Float)] {
        guard !hits.isEmpty else { return [] }
        // The replay's own lead-in of silence in front, as the app's pre-roll
        // ring always has audio before the phrase: a window cut at the start
        // of a file would be shorter than any the app ever reads.
        let lead = [Float](repeating: 0, count: Int(leadSeconds * AudioPipeline.rate))
        let audio = lead + (rate == AudioPipeline.rate ? mono : SpeechRouter.resample(mono, from: rate))
        var out: [(time: Double, score: Float)] = []
        for hit in hits {
            // The head fired during the 20 ms piece fed at `time` (file time).
            let end = min(audio.count, max(0, Int((hit.time + leadSeconds + 0.02) * AudioPipeline.rate)))
            let start = max(0, end - Int(VoiceEngine.wakeConfirmSeconds * AudioPipeline.rate))
            let window = Array(audio[start..<end])
            let text = (try? await asr.transcribe(samples16k: window, language: "en")) ?? ""
            let heard = WakeConfirm.heardTheName(text, spotter: spotter)
            if ProcessInfo.processInfo.environment["MOE_WAKE_CONFIRM_TRACE"] != nil {
                print(String(format: "        confirm %.2fs=%.2f %@ \"%@\"", hit.time, hit.score, heard ? "yes" : "no ", text))
            }
            if heard { out.append(hit) }
        }
        return out
    }

    static let audioExtensions: Set<String> = ["wav", "flac", "aiff", "aif", "m4a", "mp3"]

    /// Every audio file under `dir`, sorted.
    static func files(under dir: URL) -> [URL] {
        var out: [URL] = []
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let f as URL in e where audioExtensions.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
        return out.sorted { $0.path < $1.path }
    }
}
