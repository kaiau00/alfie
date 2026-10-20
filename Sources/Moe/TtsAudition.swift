import AVFoundation
import FluidAudio
import MoeAudio
import Foundation

/// `Moe --tts-audition <out-dir> [engine…]` — hear the engines Moe does not
/// ship, before deciding whether to ship one.
///
/// FluidAudio implements eight text-to-speech backends and Moe uses one of
/// them. Four of the others have **no row at all** in FluidAudio's own
/// benchmark table: no time-to-first-sound, no error rate, nothing. Picking
/// from that table would be choosing between three measured engines and
/// four blanks.
///
/// And the table could not answer the question anyway. Its quality column is
/// WER — text put through the voice, then back through a recogniser, and
/// compared. That measures whether a *machine* can read the audio back. A
/// flat, even, robotic voice scores extremely well on it. The thing being
/// chosen here is how human it sounds, and there is no number for that: it
/// has to be listened to. This is the same lesson `TtsBackends.swift`
/// already records about Kokoro's pace — *"a word rate is not a judgement of
/// pace"* — arriving one level up.
///
/// So this is deliberately not wired into `TtsEngineKind`. Adding cases
/// there would put engines in the Settings menu that cannot be selected
/// safely, need a paired refusal in `build.sh`, and change what
/// `TtsShippedDefaultTests` guards — all to audition something that may be
/// discarded. Nothing here can affect a running Moe.
///
/// **Nothing is bundled.** Each of these downloads on first use through
/// FluidAudio's `ModelHub` into its own cache, which is exactly the
/// mechanism an optional engine would ship on — so running this is also the
/// first real test of that path.
enum TtsAudition {

    enum AuditionError: LocalizedError {
        case needsReference
        var errorDescription: String? {
            "this engine clones a reference clip; audition kokoro first so there is one to clone"
        }
    }


    /// Lines chosen to expose the things that make a voice sound synthetic,
    /// rather than to be easy to say.
    ///
    /// A question needs rising intonation. A name and a number need the
    /// stress in the right place. A clause in the middle needs a real pause
    /// rather than a gap. The last one is what Moe actually says most, and
    /// it is where a voice that is fine in isolation starts to grate.
    static let lines: [(name: String, text: String)] = [
        ("question",  "Did you want me to send that to Sarah, or hold on to it?"),
        ("numbers",   "Your flight is at 6:45, gate 22, and it's boarding in about twenty minutes."),
        ("clause",    "I looked at the invoice — the one from March — and the total doesn't match."),
        ("everyday",  "Sure. Give me a second and I'll pull it up."),
        ("long",      "There were three messages while you were out. Two are from the bank, and one looks like it actually needs you today."),
    ]

    /// Every engine that can be auditioned, and what it costs to try.
    /// Sizes are the measured on-demand download, not the repo size.
    enum Engine: String, CaseIterable {
        case inflectNano = "inflect-nano"
        case inflectMicro = "inflect-micro"
        case pocket
        case kokoro
        case neu
        case neuHappy = "neu-happy"
        case lux
        case style

        var blurb: String {
            switch self {
            case .inflectNano:  return "Inflect v2 nano   ~54 MB   Apache-2.0   one voice"
            case .inflectMicro: return "Inflect v2 micro  ~128 MB  Apache-2.0   one voice"
            case .pocket:       return "PocketTTS v2.1    ~530 MB  research licence, 26 voices, streams"
            case .kokoro:       return "Kokoro (shipped)   bundled  Apache-2.0   28 voices"
            case .neu:          return "NeuTTS-2E         ~1.3 GB  other        4 speakers x 7 emotions (neutral)"
            case .neuHappy:     return "NeuTTS-2E happy   (cached) other        same speaker, asked to sound happy"
            case .lux:          return "LuxTTS            ~348 MB  Apache-2.0   clones a reference clip"
            case .style:        return "StyleTTS2         ~670 MB  research     clones a reference clip"
            }
        }
    }

    static func run(outDir: String, engines requested: [String]) async -> Int32 {
        let chosen: [Engine] = requested.isEmpty
            ? Engine.allCases
            : requested.compactMap { Engine(rawValue: $0) }
        guard !chosen.isEmpty else {
            print("unknown engine. one of: \(Engine.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }

        let dir = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("cannot write to \(dir.path): \(error.localizedDescription)")
            return 2
        }

        print("auditioning \(chosen.count) engine(s) into \(dir.path)")
        print("models that are not already cached download on first use.\n")

        for engine in chosen {
            print("── \(engine.blurb)")
            let began = Date()
            do {
                try await audition(engine, into: dir)
            } catch {
                // Say which engine and why, and carry on: one unavailable
                // model must not cost the whole comparison.
                print("   unavailable — \(error.localizedDescription)\n")
                continue
            }
            print(String(format: "   done in %.1f s\n", Date().timeIntervalSince(began)))
        }

        print("open \(dir.path) and listen. The filenames are engine-line.wav,")
        print("so the same sentence across engines sorts together with:")
        print("  ls \(dir.path) | sort -t- -k2")
        return 0
    }

    private static func audition(_ engine: Engine, into dir: URL) async throws {
        switch engine {
        case .inflectNano, .inflectMicro:
            let variant: InflectVariant = engine == .inflectNano ? .nano : .micro
            // LuxTts' own notes warn its graphs corrupt audio on the ANE;
            // Inflect's default is already .cpuAndGPU, and it is left alone.
            let manager = InflectManager(variant: variant)
            try await manager.initialize()
            for line in lines {
                let t = Date()
                let samples = try await manager.synthesize(text: line.text)
                try write(samples, rate: Double(InflectConstants.sampleRate),
                          to: dir, engine: engine, line: line.name, took: t)
            }
            await manager.cleanup()

        case .pocket:
            let manager = PocketTtsManager()
            try await manager.initialize()
            for line in lines {
                let t = Date()
                // PocketTTS hands back a finished 24 kHz WAV, so it is
                // written as it comes rather than re-encoded.
                let wav = try await manager.synthesize(text: line.text)
                let url = dir.appendingPathComponent("\(engine.rawValue)-\(line.name).wav")
                try wav.write(to: url)
                report(line.name, bytes: wav.count, took: t)
            }

        case .neu, .neuHappy:
            // The one thing in the library that can be asked for a mood
            // rather than a voice: four speakers, seven emotions. Both are
            // rendered so the difference is audible — a voice that cannot
            // vary cannot sound human for long.
            let manager = NeuTtsManager()
            try await manager.initialize()
            let emotion = engine == .neuHappy ? "happy" : "neutral"
            for line in lines {
                let t = Date()
                let audio = try await manager.synthesize(
                    text: line.text, speaker: "paul", emotion: emotion, seed: 7)
                try write(audio.samples, rate: Double(audio.sampleRate),
                          to: dir, engine: engine, line: line.name, took: t)
            }

        case .lux, .style:
            // Both clone rather than choose. They need a reference clip and
            // the words spoken in it, and the reference decides most of how
            // the result sounds — so hand them the SAME one, and make it
            // Kokoro's own rendering of a line already in this set. The
            // comparison is then "same target voice, different engine",
            // which is the only way the engine itself is what is heard. A
            // human clip would be a better product demo and a worse
            // experiment.
            // StyleTTS2's reference encoder takes a FIXED mel length — it
            // refused a 6.5 s clip with "shape (1 x 1 x 80 x 521) does not
            // match (1 x 1 x 80 x 231)". 231 frames is about 2.5 s, so the
            // short line is the reference for both engines rather than the
            // long one, and LuxTTS is re-run on it so the two are still
            // cloning the same voice saying the same words.
            let reference = dir.appendingPathComponent("styleref.wav")
            guard FileManager.default.fileExists(atPath: reference.path) else {
                throw AuditionError.needsReference
            }
            let referenceText = lines.first { $0.name == "everyday" }?.text ?? ""
            if engine == .lux {
                let manager = LuxTtsManager()
                try await manager.initialize()
                for line in lines {
                    let t = Date()
                    let result = try await manager.synthesize(
                        text: line.text, promptAudio: reference, promptText: referenceText)
                    try write(result.samples, rate: Double(result.sampleRate),
                              to: dir, engine: engine, line: line.name, took: t)
                }
            } else {
                let manager = StyleTTS2Manager()
                try await manager.initialize()
                for line in lines {
                    let t = Date()
                    let samples = try await manager.synthesize(
                        text: line.text, referenceAudioURL: reference)
                    try write(samples, rate: 24_000, to: dir, engine: engine, line: line.name, took: t)
                }
            }

        case .kokoro:
            // The one already in the app, rendered the same way through the
            // same file, so the comparison is like for like rather than
            // Kokoro-as-you-remember-it.
            let manager = KokoroAneManager(variant: .english)
            try await manager.initialize()
            let tuning = TtsTuning.base(for: .kokoro)
            for line in lines {
                let t = Date()
                // `synthesizeDetailed` with the shipped speed, and the
                // declick — Kokoro emits 40–51 single-sample impulses a
                // second and ticks between words without it. Auditioning it
                // raw would be comparing the others against a Kokoro nobody
                // ships.
                let result = try await manager.synthesizeDetailed(
                    text: line.text, voice: "af_heart", speed: tuning.speed)
                var samples = result.samples
                _ = Declick.repair(&samples, sampleRate: 24_000)
                try write(samples, rate: 24_000, to: dir, engine: engine, line: line.name, took: t)
            }
        }
    }

    private static func write(_ samples: [Float], rate: Double, to dir: URL,
                              engine: Engine, line: String, took from: Date) throws {
        let url = dir.appendingPathComponent("\(engine.rawValue)-\(line).wav")
        try TtsBench.writeAuditionWav(samples, sampleRate: rate, to: url)
        report(line, bytes: samples.count * 2, took: from,
               seconds: Double(samples.count) / rate)
    }

    private static func report(_ line: String, bytes: Int, took from: Date, seconds: Double? = nil) {
        let ms = Date().timeIntervalSince(from) * 1000
        if let seconds {
            print(String(format: "   %-9s %5.1f s of audio in %6.0f ms  (%.1f× real time)",
                         (line as NSString).utf8String!, seconds, ms, seconds / (ms / 1000)))
        } else {
            print(String(format: "   %-9s %6.0f ms  (%d KB)",
                         (line as NSString).utf8String!, ms, bytes / 1024))
        }
    }
}
