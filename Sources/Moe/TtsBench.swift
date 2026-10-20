import FluidAudio
import Foundation

/// `Moe --tts-bench [engine…]` — how long until you hear something.
///
/// The one number that decides how a spoken reply feels is **time to first
/// audio**: not how fast the whole sentence renders, but how long the person
/// sits in silence after the model's first words arrive. Moe's own log has
/// only ever reported the backend's own timing, and for three of the four
/// backends that is the *whole render*, because only PocketTTS is wired to
/// yield frames as it synthesises (`TtsBackend.stream`; everything else takes
/// the protocol's default extension, which renders and yields once).
///
/// So this measures both, separately, on the machine the person is actually
/// using — FluidAudio publishes its table on an M5 Pro, and the choice of
/// what to bundle should not rest on somebody else's laptop:
///
///   - `first audio` — the wall time until the first sample is in hand,
///     through `stream`. Honest TTFA for a streaming backend; equal to the
///     full render for the rest, which is the point.
///   - `render` — the whole utterance.
///   - `rtfx` — seconds of speech produced per second of work. Above 1× the
///     synthesiser keeps ahead of the speaker; below it, it stutters.
///   - `cold` — `warmUp()`, paid once per launch.
///
/// The corpus is Moe's own replies, not a TTS test set: short spoken
/// sentences with the shape the delivery rules ask for, plus the awkward
/// ones — a number, a name, a clause break — because the first chunk out of
/// the speaker is usually a clause and that is the case that matters.
///
/// Nothing here plays audio. It cannot: playback goes through the shared
/// graph so the echo canceller has Moe's voice, and a bench has no graph.
enum TtsBench {

    /// Sentences in the shape Moe actually speaks. The first four are the
    /// openers — short, and the ones whose latency the person feels — and
    /// the rest are ordinary replies.
    static let corpus = [
        "Yeah, setting that up.",
        "One sec, checking.",
        "On it.",
        "Let me check your calendar.",
        "Three Teams meetings back to back this morning.",
        "Nothing from the bank, but there's one from Eli about Friday.",
        "It's twenty past nine, and you've got about forty minutes.",
        "I've put it in for half two on Thursday.",
        "That's done — anything else?",
        "The build finished, and all the tests passed.",
    ]

    /// The two sentences a voice is chosen by ear on.
    ///
    /// A clock cannot answer "which of these sounds like someone you would
    /// talk to", and the numbers in this file do not try to. The second line
    /// carries a name, a number and a clause break on purpose: that is where
    /// a fast, neutral voice gives itself away — flattening a name, reading
    /// "half two" as digits, or running the clause together.
    static let auditionLines = [
        "opener": "Let me check that.",
        "reply":  "Eli moved the Pulse call to half two on Thursday, so you've got the morning back.",
    ]

    /// `Moe --tts-samples <dir> [engine…]` — the audition lines, rendered to
    /// WAVs, one per engine per line. Nothing is played: playback belongs to
    /// the shared audio graph and a bench has none.
    static func writeSamples(to directory: String, engines requested: [String]) async -> Int32 {
        let config = Config.load()
        let kinds: [TtsEngineKind] = requested.isEmpty
            ? [.kokoro]
            : requested.compactMap { TtsEngineKind(rawValue: $0) }
        guard !kinds.isEmpty else {
            print("unknown engine. one of: \(TtsEngineKind.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("cannot write to \(directory): \(error.localizedDescription)")
            return 1
        }

        print("Rendering \(auditionLines.count) lines × \(kinds.count) engines into \(dir.path)\n")
        var written = 0
        for kind in kinds {
            let voice = TtsCatalogue.defaultVoice(for: kind, locale: config.locale)
            let backend = makeBackend(kind, config: config)
            do { try await backend.warmUp() } catch {
                print("\(kind.rawValue): unavailable — \(error.localizedDescription)")
                continue
            }
            for (label, line) in auditionLines.sorted(by: { $0.key < $1.key }) {
                guard let samples = try? await collectSamples(backend, line, voice: voice),
                      !samples.isEmpty else {
                    print("\(kind.rawValue) \(label): no audio")
                    continue
                }
                let file = dir.appendingPathComponent("\(kind.rawValue)-\(label).wav")
                do {
                    try writeWav(samples, sampleRate: backend.sampleRate, to: file)
                    let seconds = Double(samples.count) / backend.sampleRate
                    print("  " + pad(file.lastPathComponent, 28)
                          + lpad(String(format: "%.1f", seconds), 4) + " s  ("
                          + kind.displayName + ", voice " + voice + ")")
                    written += 1
                } catch {
                    print("\(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        print("\n\(written) file(s) written. Listen before choosing — none of the")
        print("numbers in --tts-bench say anything about how a voice sounds.")
        return written > 0 ? 0 : 1
    }

    /// `Moe --tts-say "<sentence>" [engine…]` — hear your own words, in every
    /// engine, out loud, now.
    ///
    /// The bench and the ladder answer "how fast" and "how paced". Neither
    /// answers the only question that decides which voice ships, which is
    /// whether you want to listen to it. So this takes a sentence, renders it
    /// with each engine at the tuning Moe would actually use, and plays them
    /// back announced — no files to find, no player to open.
    ///
    /// Playback is `/usr/bin/afplay` on a temporary file rather than Moe's own
    /// audio graph, deliberately: the graph exists so the echo canceller has
    /// Moe's voice in its reference path, and standing one up here would put
    /// an audition through the microphone gate.
    /// - Parameter requested: engine names, and optionally one bare number —
    ///   a speed for the rate-controlled engines, a temperature for
    ///   PocketTTS. That is how a setting gets dialled in by ear without a
    ///   rebuild: `Moe --tts-say "..." kokoro 0.72`.
    static func sayAloud(_ text: String, engines requested: [String]) async -> Int32 {
        let config = Config.load()
        let override = requested.compactMap(Float.init).first
        let names = requested.filter { Float($0) == nil }
        let engineNames = names.filter { TtsEngineKind(rawValue: $0) != nil }
        // Anything left that is neither a number nor an engine is a voice id,
        // so `--tts-say "…" kokoro am_michael` auditions one voice by name
        // without editing the catalogue first.
        let voiceOverride = names.first { TtsEngineKind(rawValue: $0) == nil }
        let kinds: [TtsEngineKind] = engineNames.isEmpty
            ? [.kokoro]
            : engineNames.compactMap { TtsEngineKind(rawValue: $0) }
        guard !kinds.isEmpty else {
            print("unknown engine. one of: \(TtsEngineKind.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { print("nothing to say"); return 2 }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-audition", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let words = spoken.split(whereSeparator: { $0 == " " }).count
        print("\"\(spoken)\"\n")

        for kind in kinds {
            var tuning = TtsTuning.base(for: kind)
            if let override {
                tuning = TtsTuning(speed: override, steps: tuning.steps, temperature: 0)
            }
            let voice = voiceOverride
                ?? (config.ttsEngine == kind.rawValue && !config.ttsVoice.isEmpty
                    ? config.ttsVoice
                    : TtsCatalogue.defaultVoice(for: kind, locale: config.locale))
            let backend = makeBackend(kind, config: config, tuning: tuning)
            do { try await backend.warmUp() } catch {
                print("  \(kind.displayName): unavailable — \(error.localizedDescription)")
                continue
            }
            _ = try? await collectSamples(backend, "Warming up.", voice: voice)
            guard let samples = try? await collectSamples(backend, spoken, voice: voice),
                  !samples.isEmpty else {
                print("  \(kind.displayName): no audio")
                continue
            }
            let speech = speakingSeconds(samples, sampleRate: backend.sampleRate)
            let wpm = speech > 0 ? Double(words) / speech * 60 : 0
            let setting: String
            setting = String(format: "speed %.2f", tuning.speed)
            print("  " + pad(kind.displayName, 14) + pad(setting, 22)
                  + lpad(String(format: "%.0f", wpm), 4) + " wpm")

            let file = dir.appendingPathComponent("\(kind.rawValue).wav")
            guard (try? writeWav(samples, sampleRate: backend.sampleRate, to: file)) != nil else { continue }
            announce(kind.displayName)
            play(file)
        }
        print("\nDifferent words:  Moe --tts-say \"…\"")
        print("One engine:       Moe --tts-say \"…\" kokoro")
        print("Dial in a speed:  Moe --tts-say \"…\" kokoro 0.72")
        print("One voice:        Moe --tts-say \"…\" kokoro am_michael")
        return 0
    }

    /// Say the engine's name in a voice that is none of the candidates, so an
    /// announcement is never mistaken for the thing being auditioned.
    private static func announce(_ name: String) {
        run("/usr/bin/say", ["-v", "Daniel", "-r", "185", name])
    }

    private static func play(_ file: URL) {
        run("/usr/bin/afplay", [file.path])
    }

    private static func run(_ tool: String, _ args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
    }

    private static func collectSamples(_ backend: TtsBackend, _ text: String,
                                       voice: String) async throws -> [Float] {
        var all: [Float] = []
        for try await frame in try await backend.stream(text, voice: voice) {
            all.append(contentsOf: frame)
        }
        return all
    }

    /// A 16-bit PCM WAV, written by hand — `AVAudioFile` would pull the audio
    /// frameworks into a process that is deliberately not building a graph.
    /// The same writer, for `TtsAudition` — one encoder, so an audition and
    /// a bench cannot differ by how the file was written.
    static func writeAuditionWav(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try writeWav(samples, sampleRate: sampleRate, to: url)
    }

    private static func writeWav(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let rate = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = rate * UInt32(channels) * UInt32(bits / 8)
        let dataBytes = UInt32(samples.count * 2)

        var out = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8));  le(UInt32(36 + dataBytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8));  le(UInt32(16))
        le(UInt16(1))                 // PCM
        le(channels); le(rate); le(byteRate)
        le(UInt16(channels * bits / 8)); le(bits)
        out.append(contentsOf: Array("data".utf8)); le(dataBytes)
        for s in samples {
            le(Int16(max(-1, min(1, s)) * 32767))
        }
        try out.write(to: url, options: .atomic)
    }

    static func run(engines requested: [String]) async -> Int32 {
        let config = Config.load()
        let kinds: [TtsEngineKind] = requested.isEmpty
            ? [.kokoro]
            : requested.compactMap { TtsEngineKind(rawValue: $0) }
        guard !kinds.isEmpty else {
            print("unknown engine. one of: \(TtsEngineKind.allCases.map(\.rawValue).joined(separator: ", "))")
            return 2
        }

        print("TTS bench — \(corpus.count) phrases, \(hardware())")
        print("Engines that do not stream report the whole render as first audio,")
        print("because that is exactly what the person waits through.\n")

        var rows: [String] = []
        for kind in kinds {
            guard let row = await measure(kind, config: config) else { continue }
            rows.append(row)
        }

        print("")
        print("| engine     | voice      | cold    | first audio p50 / p95 | render p50 | rtfx  | streams |")
        print("|------------|------------|---------|-----------------------|------------|-------|---------|")
        for row in rows { print(row) }
        return 0
    }

    private static func measure(_ kind: TtsEngineKind, config: Config) async -> String? {
        let voice = config.ttsEngine == kind.rawValue && !config.ttsVoice.isEmpty
            ? config.ttsVoice
            : TtsCatalogue.defaultVoice(for: kind, locale: config.locale)
        let backend = makeBackend(kind, config: config)

        print("\(kind.displayName) — loading (\(kind.downloadSize))…")
        let coldStart = Date()
        do {
            try await backend.warmUp()
        } catch {
            print("  unavailable: \(error.localizedDescription)\n")
            return nil
        }
        let cold = Date().timeIntervalSince(coldStart)

        // One throwaway render: the first call after a load still pays for
        // ANE compilation and lazy graph setup, and reporting that as a
        // typical sentence would libel every engine equally.
        _ = try? await collect(backend, "Warming up.", voice: voice)

        var firsts: [Double] = []
        var renders: [Double] = []
        var audio = 0.0
        var work = 0.0
        for phrase in corpus {
            guard let m = try? await collect(backend, phrase, voice: voice) else {
                print("  failed on: \(phrase)")
                continue
            }
            guard m.samples > 0 else {
                print("  no audio for: \(phrase)")
                continue
            }
            firsts.append(m.first)
            renders.append(m.total)
            audio += Double(m.samples) / backend.sampleRate
            work += m.total
        }
        guard !firsts.isEmpty else { print("  nothing rendered\n"); return nil }

        let rtfx = work > 0 ? audio / work : 0
        print(String(format: "  cold %.1f s · first audio p50 %.0f ms · render p50 %.0f ms · %.1f× realtime\n",
                     cold, ms(percentile(firsts, 0.5)), ms(percentile(renders, 0.5)), rtfx))

        return "| " + pad(kind.displayName, 10) + " | " + pad(String(voice.prefix(10)), 10)
             + " | " + lpad(String(format: "%.1f", cold), 5) + " s | "
             + lpad(String(format: "%.0f", ms(percentile(firsts, 0.5))), 8) + " / "
             + pad(String(format: "%.0f", ms(percentile(firsts, 0.95))), 8) + " ms | "
             + lpad(String(format: "%.0f", ms(percentile(renders, 0.5))), 7) + " ms | "
             + lpad(String(format: "%.1f", rtfx), 4) + "× | "
             + pad(streams(kind) ? "yes" : "no", 7) + " |"
    }

    private struct Measured {
        let first: TimeInterval
        let total: TimeInterval
        let samples: Int
    }

    /// Render one phrase through `stream`, timing the first frame and the last.
    private static func collect(_ backend: TtsBackend, _ text: String,
                                voice: String) async throws -> Measured {
        let began = Date()
        var first: TimeInterval?
        var samples = 0
        for try await frame in try await backend.stream(text, voice: voice) {
            if frame.isEmpty { continue }
            if first == nil { first = Date().timeIntervalSince(began) }
            samples += frame.count
        }
        let total = Date().timeIntervalSince(began)
        return Measured(first: first ?? total, total: total, samples: samples)
    }

    private static func makeBackend(_ kind: TtsEngineKind, config: Config,
                                    tuning: TtsTuning? = nil) -> TtsBackend {
        let t = tuning ?? .base(for: kind)
        switch kind {
        case .kokoro:     return KokoroBackend(tuning: t)
        case .pocket:     return PocketBackend()
        case .inworld:    return InworldBackend()
        }
    }

    // MARK: - The pace ladder

    /// `Moe --tts-ladder <dir> [engine…]` — one engine, several settings,
    /// same sentence, so the tuning can be chosen by ear.
    ///
    /// Pace is measurable and every engine failed the measurement (see
    /// `TtsTuning`), but *how slow is too slow* is not a number. This renders
    /// the range around each engine's measured default and reports the pace it
    /// actually achieved, so a listening test and a word-rate agree on what
    /// they are talking about.
    static func writeLadder(to directory: String, engines requested: [String]) async -> Int32 {
        let config = Config.load()
        let kinds: [TtsEngineKind] = requested.isEmpty
            ? [.kokoro]
            : requested.compactMap { TtsEngineKind(rawValue: $0) }
        guard !kinds.isEmpty else { print("unknown engine"); return 2 }

        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let line = auditionLines["reply"]!
        let words = line.split(whereSeparator: { $0 == " " }).count

        print("Pace ladder — \(words) words, one file per setting\n")
        print("| engine     | setting                | speech | pace     |")
        print("|------------|------------------------|--------|----------|")

        var written = 0
        for kind in kinds {
            for step in ladder(for: kind) {
                let backend = makeBackend(kind, config: config, tuning: step.tuning)
                do { try await backend.warmUp() } catch {
                    // `continue`, not `break`: one setting failing to load says
                    // nothing about the next one, and a `break` here hid the
                    // rest of PocketTTS's ladder behind an unavailable
                    // placement.
                    print("| " + pad(kind.displayName, 10) + " | " + pad(step.label, 22)
                          + " |  unavailable — \(error.localizedDescription)")
                    continue
                }
                _ = try? await collectSamples(backend, "Warming up.",
                                              voice: TtsCatalogue.defaultVoice(for: kind, locale: config.locale))
                guard let samples = try? await collectSamples(
                        backend, line,
                        voice: TtsCatalogue.defaultVoice(for: kind, locale: config.locale)),
                      !samples.isEmpty else {
                    print("| \(kind.rawValue) | \(step.label) | — | failed |")
                    continue
                }
                let speech = speakingSeconds(samples, sampleRate: backend.sampleRate)
                let wpm = speech > 0 ? Double(words) / speech * 60 : 0
                let file = dir.appendingPathComponent("\(kind.rawValue)-\(step.slug).wav")
                try? writeWav(samples, sampleRate: backend.sampleRate, to: file)
                written += 1
                print("| " + pad(kind.displayName, 10) + " | " + pad(step.label, 22)
                      + " | " + lpad(String(format: "%.1f", speech), 4) + " s | "
                      + lpad(String(format: "%.0f", wpm), 4) + " wpm |")
            }
        }
        print("\n\(written) file(s) in \(dir.path). 150–170 wpm is conversational English.")
        return written > 0 ? 0 : 1
    }

    private struct LadderStep {
        let slug: String
        let label: String
        let tuning: TtsTuning
    }

    /// The range worth hearing for each engine, centred on its measured
    /// default. Kokoro and Supertonic ladder on pace, because they have a
    /// rate control; PocketTTS ladders on temperature, because it does not.
    private static func ladder(for kind: TtsEngineKind) -> [LadderStep] {
        switch kind {
        // No rate control and no steps, so there is nothing to sweep: one
        // step, its own default. The comment above says PocketTTS ladders on
        // temperature — it did when Moe carried a temperature dial for it;
        // `TtsTuning.base(for: .pocket)` is 0 now, which is its steadiest.
        case .pocket:
            return [LadderStep(slug: "default", label: "as shipped",
                               tuning: TtsTuning.base(for: .pocket))]
        case .kokoro:
            return [1.00, 0.88, 0.78, 0.70, 0.64].map {
                LadderStep(slug: "speed\(Int($0 * 100))",
                           label: "speed \(String(format: "%.2f", $0))",
                           tuning: TtsTuning(speed: Float($0), steps: 0, temperature: 0))
            }
        case .inworld:
            return []
        }
    }

    /// Seconds of actual speech: the span from the first to the last 20 ms
    /// window above 2% of peak level, so leading and trailing silence do not
    /// flatter a pace figure while internal pauses still count against it.
    static func speakingSeconds(_ samples: [Float], sampleRate: Double) -> Double {
        let win = max(1, Int(sampleRate * 0.02))
        var rms: [Float] = []
        var i = 0
        while i + win <= samples.count {
            var sum: Float = 0
            for j in i..<(i + win) { sum += samples[j] * samples[j] }
            rms.append((sum / Float(win)).squareRoot())
            i += win
        }
        guard let peak = rms.max(), peak > 0 else { return 0 }
        let gate = peak * 0.02
        guard let first = rms.firstIndex(where: { $0 > gate }),
              let last = rms.lastIndex(where: { $0 > gate }) else { return 0 }
        return Double(last - first + 1) * 0.02
    }

    /// Which engines yield audio as it is made rather than once at the end.
    /// PocketTTS and the cloud voice do; Kokoro and Apple inherit the
    /// default `stream` that renders first and yields once.
    private static func streams(_ kind: TtsEngineKind) -> Bool {
        kind == .pocket || kind == .inworld
    }

    // MARK: - Numbers


    /// `String(format: "%-12@", …)` silently does not pad on Swift's
    /// Foundation, so every table here came out ragged. Pad by hand.
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    private static func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    private static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[i]
    }

    private static func ms(_ seconds: Double) -> Double { seconds * 1000 }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let chip = String(cString: chars)
        return chip.isEmpty ? "this Mac" : chip
    }
}
