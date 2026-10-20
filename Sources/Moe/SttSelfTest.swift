import AVFoundation
import FluidAudio
import Foundation
import MoeDictation

/// Proves the recognizer works without needing anyone to talk.
///
/// Kokoro synthesizes a known sentence, the samples are fed straight into
/// Parakeet, and the transcript is compared to what went in. If a microphone
/// test produces nothing, this is what tells you whether the problem is the
/// recognizer or the room. The same audio also goes through the universal
/// (Whisper) engine when its model has already been downloaded — the test
/// never triggers a 600 MB download on its own.
enum SttSelfTest {

    /// `Moe --stt-test <audio> <locale>`: transcribe one file the way a voice
    /// note or a held key would be for that language, and print the timings.
    /// Downloads the engine the locale routes to if it is missing.
    static func run(file path: String, locale: String) async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let router = SpeechRouter.forUser()
        let backend = router.backend(for: locale)
        print("\nMoe — speech test: \(path)")
        print("  locale \(locale) → \(backend.displayName)"
              + "  (hint: \(router.hint(for: locale) ?? "none, auto-detect"))")

        guard let samples = await Transcriber.loadSamples(path: path), !samples.isEmpty else {
            print("✗ could not read audio")
            return 1
        }
        print(String(format: "  audio: %.1f s at 16 kHz", Double(samples.count) / 16_000))

        let t0 = Date()
        do {
            try await backend.warmUp { print("  \($0)") }
        } catch {
            print("✗ could not load: \(error)")
            return 1
        }
        let loadSeconds = Date().timeIntervalSince(t0)
        print(String(format: "  loaded in %.2f s", loadSeconds))

        let seconds = Double(samples.count) / 16_000
        let d: SpeechRouter.Diagnosis
        do {
            d = try await router.diagnose(samples16k: samples, locale: locale)
        } catch {
            print("✗ transcription failed: \(error)")
            return 1
        }
        print(String(format: "  transcribed in %.2f s (%.0f× realtime)",
                     d.decodeSeconds, seconds / max(d.decodeSeconds, 0.001)))
        print("  text: \"\(d.raw)\"")

        let text = d.boosted ?? d.raw
        if d.terms == 0 {
            print("  vocabulary: none — boosting idle (add terms to \(Vocabulary.shared.url.path))")
        } else if let boosted = d.boosted {
            print(String(format: "  vocabulary: %d terms, boosted in %.2f s (%.0f× realtime)",
                         d.terms, d.boostSeconds, seconds / max(d.boostSeconds, 0.001)))
            print("  boosted: \"\(boosted)\"")
        } else {
            print(String(format: "  vocabulary: %d terms, nothing to correct (%.2f s)",
                         d.terms, d.boostSeconds))
        }

        // A reference beside the audio turns this from a demo into a bench:
        // run the clip set before and after a change and compare the numbers.
        if let reference = self.reference(besideAudioAt: path) {
            print("")
            report("raw    ", WordErrorRate.score(hypothesis: d.raw, reference: reference))
            if d.boosted != nil {
                report("boosted", WordErrorRate.score(hypothesis: text, reference: reference))
            }
        }
        print("")
        return text.isEmpty ? 1 : 0
    }

    private static func report(_ label: String, _ s: WordErrorRate.Score) {
        print(String(format: "  %@ WER %.1f%%  (%d sub, %d del, %d ins of %d words)",
                     label, s.rate * 100, s.substitutions, s.deletions, s.insertions,
                     s.referenceWords))
    }

    /// The expected transcript: a `.txt` beside the audio with the same
    /// basename. Absent is the normal case and says nothing — a self-test on
    /// a stray recording is still worth running.
    private static func reference(besideAudioAt path: String) -> String? {
        let url = URL(fileURLWithPath: path).deletingPathExtension()
            .appendingPathExtension("txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        print("  reference: \(url.lastPathComponent)")
        return trimmed
    }

    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        print("\nMoe — speech recognition self-test")
        print(String(repeating: "─", count: 62))

        let sentences = [
            "The quick brown fox jumps over the lazy dog.",
            "Remind me to pick up Naomi at four thirty tomorrow.",
            "What's on my calendar today?",
        ]

        let tts = KokoroAneManager(variant: .english)
        do {
            print("loading voice…")
            try await tts.initialize()
        } catch {
            print("✗ could not load TTS: \(error.localizedDescription)")
            return 1
        }

        let asr = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 900)
        do {
            print("loading recognizer…")
            try await asr.loadModels()
        } catch {
            print("✗ could not load ASR: \(error.localizedDescription)")
            return 1
        }

        // The accurate engines — the ones the app actually reads with.
        let router = SpeechRouter.forUser()
        print("loading accurate model (\(router.parakeet.displayName))…")
        do {
            try await router.parakeet.warmUp { print("  \($0)") }
            print("  ✓ accurate model loaded")
        } catch {
            print("  ✗ ACCURATE MODEL FAILED: \(error)")
            print("     \(String(describing: error))")
            return 1
        }
        var universal: WhisperBackend? = nil
        if WhisperBackend.modelIsPresent {
            print("loading \(router.whisper.displayName) model…")
            do {
                let t0 = Date()
                try await router.whisper.warmUp { print("  \($0)") }
                print(String(format: "  ✓ loaded in %.1f s", Date().timeIntervalSince(t0)))
                universal = router.whisper
            } catch {
                print("  ✗ universal model failed: \(error)")
            }
        } else {
            print("universal model not downloaded — skipping (pick a language that needs it in Settings)")
        }

        var passed = 0
        for sentence in sentences {
            print("\n  spoken:     \"\(sentence)\"")

            let samples: [Float]
            do {
                let result = try await tts.synthesizeDetailed(text: sentence)
                samples = result.samples
                print("  synthesized \(samples.count) samples at \(result.sampleRate)Hz")
            } catch {
                print("  ✗ synthesis failed: \(error.localizedDescription)")
                continue
            }

            await asr.reset()

            // Feed it in realistic chunks, the way the microphone tap would.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
            else { continue }
            let chunk = 2400   // 100ms
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunk, samples.count)
                let slice = Array(samples[offset..<end])
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(slice.count)) else { break }
                buffer.frameLength = AVAudioFrameCount(slice.count)
                slice.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress!, count: slice.count)
                }
                _ = try? await asr.process(audioBuffer: buffer)
                offset = end
            }

            let heard = ((try? await asr.finish()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("  small model:    \"\(heard)\"")

            // Same audio through the accurate engines, for comparison.
            let samples16k = SpeechRouter.resample(samples, from: 24_000)
            let t0 = Date()
            let accurateText = ((try? await router.parakeet.transcribe(samples16k: samples16k, language: "en")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print(String(format: "  accurate model: \"%@\"  (%.2f s)", accurateText, Date().timeIntervalSince(t0)))
            if let universal {
                let t1 = Date()
                let text = ((try? await universal.transcribe(samples16k: samples16k, language: "en")) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                print(String(format: "  universal:      \"%@\"  (%.2f s)", text, Date().timeIntervalSince(t1)))
            }

            let score = similarity(sentence, heard)
            if score >= 0.7 {
                passed += 1
                print(String(format: "  ✓ match %.0f%%", score * 100))
            } else {
                print(String(format: "  ✗ match %.0f%%", score * 100))
            }
        }

        print("\n" + String(repeating: "─", count: 62))
        if passed == sentences.count {
            print("✓ recognizer works — \(passed)/\(sentences.count) sentences transcribed.\n")
            return 0
        } else if passed > 0 {
            print("~ partial — \(passed)/\(sentences.count). Wiring is right, accuracy is the question.\n")
            return 0
        } else {
            print("""
            ✗ recognizer produced nothing.

              The audio path into Parakeet is wrong — this is not a microphone
              or room-noise problem.

            """)
            return 1
        }
    }

    /// Word-level overlap, lowercased and stripped of punctuation. Crude on
    /// purpose: we're checking the pipeline carries words end to end, not
    /// measuring word error rate.
    private static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let expected = words(a)
        let got = Set(words(b))
        guard !expected.isEmpty else { return 0 }
        let hits = expected.filter { got.contains($0) }.count
        return Double(hits) / Double(expected.count)
    }
}
