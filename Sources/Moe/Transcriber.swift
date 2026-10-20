import AVFoundation
import FluidAudio
import Foundation

/// One-shot transcription of an audio file with the accurate model for the
/// configured language — the same routing the microphone uses, so a Hebrew
/// voice note and a Hebrew push-to-talk go through the same engine. A locale
/// neither engine knows goes to Whisper with no hint and its language
/// detector decides.
///
/// WhatsApp voice notes arrive as Opus in an Ogg container, which AVFoundation
/// will not open directly, so anything it can't read is converted with the
/// system's own `afconvert` before decoding.
enum Transcriber {

    static func transcribe(path: String, locale: String = Config.load().locale) async -> String {
        guard let samples = await loadSamples(path: path), !samples.isEmpty else {
            return ""
        }
        do {
            return try await SpeechRouter.forUser().transcribe(samples16k: samples, locale: locale)
        } catch {
            FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
            return ""
        }
    }

    /// 16 kHz mono float samples, converting the file first if necessary.
    static func loadSamples(path: String) async -> [Float]? {
        if let direct = read(url: URL(fileURLWithPath: path)) { return direct }

        // Fall back to afconvert, which handles Opus/Ogg and anything else
        // CoreAudio knows about.
        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, converted.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: converted) }
        guard p.terminationStatus == 0 else { return nil }
        return read(url: converted)
    }

    private static func read(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0]
        else { return nil }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = data[i] }

        // Both engines want 16 kHz.
        return SpeechRouter.resample(mono, from: file.processingFormat.sampleRate)
    }
}
