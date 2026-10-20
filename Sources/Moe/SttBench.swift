import Foundation
import MoeDictation

/// `Moe --stt-bench <dir> [locale]` — every clip in a directory, scored.
///
/// `--stt-test` answers "did this one clip work". This answers the question
/// that actually decides whether a change ships: **over a whole set, did the
/// numbers go up or down.** One process, so the models load once rather than
/// once per clip (they take 15–20 s cold, which a shell loop would pay every
/// time), and the totals are pooled rather than averaged.
///
/// A clip is any audio file with a `.txt` of the same basename beside it
/// holding what was actually said. Everything else in the directory is
/// ignored, so notes and scratch files can live there too.
///
/// **What this measures, and what it does not.** It scores the *engines* —
/// the recogniser plus the vocabulary boost. It does not run the rule cleaner
/// or the polish pass, so references must be literal: the words as spoken,
/// fillers and all, not what should end up typed. And a set built from
/// synthesised speech (`scripts/make-bench-clips.sh`) is far easier than a
/// person in a room: no accent, no disfluency, no background, perfect
/// microphone. Treat those numbers as a **regression guard** — they catch a
/// change making things worse — never as a claim about real-world accuracy.
/// For that, record yourself.
enum SttBench {

    struct Clip {
        let audio: URL
        let reference: String
    }

    static func run(directory path: String, locale: String) async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let clips = self.clips(in: dir)

        print("\nMoe — dictation bench: \(dir.path)")
        guard !clips.isEmpty else {
            print("""
              no clips found.

              A clip is an audio file with a .txt of the same basename beside it,
              holding the words as spoken. scripts/make-bench-clips.sh writes a
              synthetic starter set; add your own recordings to the same folder.
            """)
            return 1
        }

        let router = SpeechRouter.forUser()
        let terms = VocabularyBoost.usable(Vocabulary.shared.promptTerms(limit: VocabularyBoost.maxTerms))
        print("  locale \(locale) → \(router.backend(for: locale).displayName)")
        print("  vocabulary: \(terms.isEmpty ? "none" : "\(terms.count) terms")")
        print("  \(clips.count) clip\(clips.count == 1 ? "" : "s")\n")

        print("  loading models…")
        do {
            try await router.warmUp(locale: locale) { _ in }
        } catch {
            print("  ✗ could not load: \(error.localizedDescription)")
            return 1
        }
        // The vocabulary model too, and awaited — `warmUp` fires it detached
        // so it never delays a real dictation, but a bench that started
        // before it finished would score its first clips unboosted and
        // report a regression that is really a race.
        await router.boost.warmUp(terms: terms)

        var rawScores: [WordErrorRate.Score] = []
        var boostedScores: [WordErrorRate.Score] = []
        var decodeTotal = 0.0, boostTotal = 0.0, audioTotal = 0.0
        var failures = 0

        print("\n  \(pad("clip", 28))\(padLeft("words", 7))\(padLeft("raw", 9))\(padLeft("boosted", 10))")
        print("  " + String(repeating: "─", count: 54))

        for clip in clips {
            guard let samples = await Transcriber.loadSamples(path: clip.audio.path),
                  !samples.isEmpty else {
                print("  \(pad(clip.audio.lastPathComponent, 28))    could not read audio")
                failures += 1
                continue
            }
            let d: SpeechRouter.Diagnosis
            do {
                d = try await router.diagnose(samples16k: samples, locale: locale)
            } catch {
                print("  \(pad(clip.audio.lastPathComponent, 28))    failed: \(error.localizedDescription)")
                failures += 1
                continue
            }

            let raw = WordErrorRate.score(hypothesis: d.raw, reference: clip.reference)
            let boosted = WordErrorRate.score(hypothesis: d.boosted ?? d.raw, reference: clip.reference)
            rawScores.append(raw)
            boostedScores.append(boosted)
            decodeTotal += d.decodeSeconds
            boostTotal += d.boostSeconds
            audioTotal += Double(samples.count) / 16_000

            // An arrow only where boosting changed the score, so the eye goes
            // straight to what it did — in either direction.
            let mark = boosted.errors < raw.errors ? " ↓"
                     : boosted.errors > raw.errors ? " ↑ WORSE" : ""
            print("  \(pad(clip.audio.lastPathComponent, 28))"
                + "\(padLeft("\(raw.referenceWords)", 7))"
                + "\(padLeft(pct(raw.rate), 9))"
                + "\(padLeft(pct(boosted.rate), 10))\(mark)")
        }

        guard !rawScores.isEmpty else { return 1 }
        let raw = WordErrorRate.total(rawScores)
        let boosted = WordErrorRate.total(boostedScores)
        print("  " + String(repeating: "─", count: 54))
        print("  \(pad("total", 28))\(padLeft("\(raw.referenceWords)", 7))"
            + "\(padLeft(pct(raw.rate), 9))\(padLeft(pct(boosted.rate), 10))")

        let n = Double(rawScores.count)
        print(String(format: "\n  %.1f s of audio · decode %.2f s/clip (%.0f× realtime) · boost %.2f s/clip",
                     audioTotal, decodeTotal / n, audioTotal / max(decodeTotal, 0.001), boostTotal / n))
        if boosted.errors != raw.errors {
            let delta = raw.errors - boosted.errors
            print("  vocabulary boost: \(abs(delta)) \(delta > 0 ? "error(s) fixed" : "error(s) INTRODUCED")")
        }
        if failures > 0 { print("  \(failures) clip(s) could not be read") }
        print("")
        return failures > 0 ? 1 : 0
    }

    /// Audio files that have a reference beside them, in a stable order so
    /// two runs are diffable.
    static func clips(in directory: URL) -> [Clip] {
        let audioTypes: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { audioTypes.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let ref = audio.deletingPathExtension().appendingPathExtension("txt")
                guard let text = try? String(contentsOf: ref, encoding: .utf8) else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Clip(audio: audio, reference: trimmed)
            }
    }

    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
    }
    private static func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
}
