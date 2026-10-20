import AVFoundation
import FluidAudio
import Foundation
import MoeVoice

/// `Moe --turn-bench` and `Moe --turn-replay`: the turn-taking harness's two
/// halves (research-eval-harness.md §3; ~/moe-voice-notes/PLAN.md Step 0).
///
/// **--turn-bench** makes tapes. Each file of a corpus goes through the real
/// pipeline — `AudioPipeline` with Silero and the noise-floor gate, Parakeet's
/// streaming recogniser with the app's own settings — and every edge,
/// partial and end-of-utterance token is written down with its audio time.
/// Then Smart Turn (the shipped ONNX) is asked at every moment the engine
/// would ask it, on the audio trimmed exactly as `VoiceEngine.askTurnModel`
/// trims it, once per tail length under test. No microphone; nothing is
/// played.
///
/// **--turn-replay** reads tapes and runs `PolicyReplay` + `EotScore` over
/// them, for one tuning or a sweep. Pure and fast: a sweep of a few thousand
/// settings over 400 turns takes seconds.
///
/// The corpus it was built for is LiveKit's eot-bench (English, 400 real
/// turns, CC-BY-4.0), unpacked by `scripts/turnbench/eot_prep.py`.
enum TurnBench {

    // MARK: - Making tapes

    struct Row: Decodable {
        let id: String
        let duration: Double
        let wav: String
        struct Word: Decodable { let start: Double; let end: Double; let word: String }
        struct Span: Decodable { let start: Double; let end: Double }
        let words: [Word]
        let silence_spans: [Span]
    }

    struct Output: Codable {
        var tapes: [TurnTape]
        /// Smart Turn on eot-bench's own input (the audio to 0.2 s into each
        /// pause, untrimmed): the parity check against the published run.
        var parity: [Parity]
        var inferenceMs: Double
        var keeps: [Double]
    }
    struct Parity: Codable { let id: String; let span: Int; let label: String; let p: Double }

    /// Silence after each file, so the VAD closes and every clock can fire.
    static let tailSeconds = 8.0

    static func record(dir: URL, out: URL, keeps: [Double], limit: Int?) async -> Int32 {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var rows = try? JSONDecoder().decode([Row].self, from: data) else {
            print("no manifest at \(manifestURL.path) — run scripts/turnbench/eot_prep.py first")
            return 2
        }
        if let limit { rows = Array(rows.prefix(limit)) }
        let detector = SmartTurnDetector()
        let vad: VadManager
        let asr = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 400)
        do {
            try await detector.load()
            vad = try await VadManager()
            try await asr.loadModels()
        } catch {
            print("model load failed: \(error)")
            return 2
        }
        print("turn model: \(await detector.modelName ?? "?")")
        print("turn bench: \(rows.count) files, tails \(keeps.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        var tapes: [TurnTape] = []
        var parity: [Parity] = []
        var inference: [Double] = []
        let began = Date()
        for (n, row) in rows.enumerated() {
            guard let (mono, rate) = WakeBench.decode(dir.appendingPathComponent(row.wav)), rate == AudioPipeline.rate else {
                print("  \(row.id): unreadable or not 16 kHz"); continue
            }
            let run = await listen(mono, vad: vad, asr: asr)
            var probes: [String: [TurnTape.Probe]] = [:]
            for keep in keeps {
                var list: [TurnTape.Probe] = []
                for ask in run.askTimes {
                    let t0 = Date()
                    guard let p = await probe(run, at: ask, keep: keep, detector: detector) else { continue }
                    inference.append(Date().timeIntervalSince(t0) * 1000)
                    list.append(.init(t: ask, p: p))
                }
                probes[TurnTape.key(tail: keep)] = list
            }
            let spans = row.silence_spans.map { TurnTape.Span(start: $0.start, end: $0.end) }
            let truth = spans.isEmpty ? nil : TurnTape.Truth(holds: Array(spans.dropLast()), end: spans.last!)
            tapes.append(TurnTape(id: row.id, events: run.events, probes: probes, truth: truth,
                                  duration: Double(mono.count) / rate + tailSeconds))
            // eot-bench's own input: everything to 0.2 s into the pause,
            // untrimmed, left-padded to 8 s (its SmartTurnAudioAdapter).
            for (i, span) in row.silence_spans.enumerated() where span.end - span.start >= 0.2 - 1e-9 {
                let end = min(mono.count, Int(((span.start + 0.2) * rate).rounded(.down)))
                let audio = Array(mono[max(0, end - WhisperFeatures.samples)..<end])
                if let p = (try? await detector.probabilityComplete(audio)) ?? nil {
                    parity.append(Parity(id: row.id, span: i, label: i == row.silence_spans.count - 1 ? "eot" : "hold",
                                         p: Double(p)))
                }
            }
            if (n + 1) % 25 == 0 { print("  \(n + 1)/\(rows.count) in \(VoiceEngine.ms(since: began))") }
        }
        let meanMs = inference.isEmpty ? 0 : inference.reduce(0, +) / Double(inference.count)
        let output = Output(tapes: tapes, parity: parity, inferenceMs: meanMs, keeps: keeps)
        do {
            let enc = JSONEncoder()
            try enc.encode(output).write(to: out)
        } catch {
            print("could not write \(out.path): \(error)"); return 1
        }
        print(String(format: "wrote %d tapes, %d parity scores → %@ (Smart Turn %.1f ms a call, %@)",
                     tapes.count, parity.count, out.path, meanMs, VoiceEngine.ms(since: began)))
        return 0
    }

    /// One file through the pipeline, with every edge and word on its clock.
    struct Run {
        var events: [TurnTape.Event] = []
        var audio: [Float] = []
        /// When the engine would ask Smart Turn: every VAD end and every
        /// end-of-utterance token (the machine asks at those), and 1.3 s after
        /// every time the words grew (the stall clock at its default).
        var askTimes: [Double] = []
        /// When the words last grew, and the last confident chunk well over
        /// the room — the two moments `askTurnModel` cuts the audio after.
        var wordsGrew: [Double] = []
        var voiced: [Double] = []
    }

    /// - Parameter tail: silence fed after the file (the corpus's files carry
    ///   their own tail, with the room's noise in it: 0).
    static func listen(_ mono: [Float], vad: VadManager, asr: StreamingEouAsrManager,
                       tail: Double = tailSeconds) async -> Run {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var run = Run()
            var fed = 0.0
            var lastText = ""
            func add(_ e: TurnTape.Event) { lock.lock(); run.events.append(e); lock.unlock() }
        }
        let box = Box()
        await asr.reset()
        await asr.setPartialCallback { text in
            box.lock.lock()
            if text.count > box.lastText.count { box.run.wordsGrew.append(box.fed) }
            box.lastText = text
            box.run.events.append(.init(t: box.fed, .partial, text))
            box.lock.unlock()
        }
        await asr.setEouCallback { text in box.add(.init(t: box.fed, .endOfUtterance, text)) }
        let pipeline = AudioPipeline { out in
            switch out {
            case .speechStarted: box.add(.init(t: box.fed, .speechStarted))
            case .speechEnded: box.add(.init(t: box.fed, .speechEnded))
            case .vad(let p, let peakDb, let floorDb, _):
                if p >= 0.85, floorDb.map({ peakDb >= $0 + 5 }) ?? true {
                    box.lock.lock(); box.run.voiced.append(box.fed); box.lock.unlock()
                }
            default: break
            }
        }
        await pipeline.attach(vad: vad)
        await pipeline.attach(asr: asr)
        await pipeline.setAsr(true)
        let rate = AudioPipeline.rate
        let all = mono + [Float](repeating: 0, count: Int(rate * tail))
        let piece = Int(rate * 0.02)
        var i = 0
        while i < all.count {
            let end = min(all.count, i + piece)
            box.fed = Double(end) / rate
            await pipeline.ingest(Array(all[i..<end]), rate: rate)
            i = end
        }
        var run = box.run
        run.audio = all
        run.events.sort { $0.t < $1.t }
        var asks = run.events.filter { $0.kind == .speechEnded || $0.kind == .endOfUtterance }.map(\.t)
        asks += run.wordsGrew.map { $0 + VoiceMachine.Tuning().wordStallSeconds }
        run.askTimes = Array(Set(asks.map { ($0 * 1000).rounded() / 1000 })).sorted()
        return run
    }

    /// What `VoiceEngine.askTurnModel` would hand Smart Turn at `t`, and its answer.
    static func probe(_ run: Run, at t: Double, keep: Double, detector: SmartTurnDetector) async -> Double? {
        let rate = AudioPipeline.rate
        let end = min(run.audio.count, Int(t * rate))
        var audio = Array(run.audio[max(0, end - WhisperFeatures.samples)..<end])
        let grew = run.wordsGrew.last { $0 <= t }
        if let grew {
            let voiced = run.voiced.last { $0 <= t } ?? -.infinity
            let lastWordAt = max(grew, voiced)
            audio = TurnAudio.trimAfterLastWord(audio, sampleRate: Int(rate),
                                                secondsSinceLastWord: t - lastWordAt, keep: keep)
        }
        let samples = TurnAudio.trimTrailingSilence(audio, sampleRate: Int(rate), keep: keep)
        guard samples.count > Int(rate * 0.3) else { return nil }
        guard let p = (try? await detector.probabilityComplete(samples)) ?? nil else { return nil }
        return Double(p)
    }

    // MARK: - Replaying tapes

    static func replay(_ args: [String]) -> Int32 {
        guard let path = args.first,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let output = try? JSONDecoder().decode(Output.self, from: data) else {
            print("usage: Moe --turn-replay <tapes.json> [--probe 0.30] [--brain s] [--split fit|val|test|fitval]")
            print("       [--set key=value]… [--sweep key=a,b,c]…")
            return 2
        }
        var tuning = VoiceMachine.Tuning()
        var probe = TurnTape.key(tail: TurnAudio.pauseTheModelWasTrainedOn)
        var options = EotScore.Options()
        var split: String?
        var sweeps: [(String, [Double])] = []
        var frontier = false
        var fragments = false
        var noEvidence = false
        var i = 1
        while i < args.count {
            let a = args[i], v = i + 1 < args.count ? args[i + 1] : ""
            switch a {
            case "--probe": probe = TurnTape.key(tail: Double(v) ?? 0.3); i += 2
            case "--brain": options.brainSeconds = Double(v) ?? 0; i += 2
            case "--split": split = v; i += 2
            case "--onset-holds-reply": options.resumeByOnset = v != "0"; i += 2
            case "--frontier": frontier = true; i += 1
            case "--fragments": fragments = true; i += 1
            case "--fitted": tuning.endpoint = .fitted; i += 1
            case "--shipped": tuning.endpoint = .shipped; i += 1
            case "--no-evidence": noEvidence = true; i += 1
            case "--set":
                let kv = v.split(separator: "=").map(String.init)
                if kv.count == 2, let d = Double(kv[1]), set(&tuning, kv[0], d) { i += 2 } else {
                    print("unknown setting \(v)"); return 2
                }
            case "--sweep":
                let kv = v.split(separator: "=").map(String.init)
                guard kv.count == 2 else { print("bad sweep \(v)"); return 2 }
                sweeps.append((kv[0], kv[1].split(separator: ",").compactMap { Double($0) })); i += 2
            default: print("unknown argument \(a)"); return 2
            }
        }
        var tapes = output.tapes
        if let split {
            // Every other turn, so a fitted setting is scored on turns it
            // never saw.
            // By conversation, never by turn: the same speaker's pause habits
            // must not sit on both sides (review H4). eot-bench ids are
            // `en__<conversation>__user_turn_N`; conversations in sorted order
            // go to fit / val / test in turn.
            let conv: (TurnTape) -> String = { t in
                let parts = t.id.components(separatedBy: "__")
                return parts.count >= 2 ? parts[1] : t.id
            }
            let order = Array(Set(tapes.map(conv))).sorted()
            let fold = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset % 3) })
            let want: Set<Int> = ["fit": [0], "val": [1], "test": [2], "fitval": [0, 1]][split] ?? []
            guard !want.isEmpty else { print("--split is fit, val, test or fitval"); return 2 }
            tapes = tapes.filter { want.contains(fold[conv($0)] ?? -1) }
        }
        let inference = max(0.001, output.inferenceMs / 1000)
        print(String(format: "turn replay: %d tapes, probe tail %@, Smart Turn %.0f ms, brain %.1f s, reply held on %@",
                     tapes.count, probe, output.inferenceMs, options.brainSeconds,
                     options.resumeByOnset ? "the onset" : "the first word"))
        let holds = tapes.reduce(0) { $0 + ($1.truth?.holds.filter { $0.duration >= 0.2 - 1e-9 && $0.duration <= 5 + 1e-9 }.count ?? 0) }
        print("  \(tapes.count) turns, \(holds) pauses the person went on after (0.2–5 s)")
        print("  setting                                  cut(dec) cut(commit) cont/turn  lat(dec) lat(commit) p50   p90   ceil")
        var grid: [[(String, Double)]] = [[]]
        for (key, values) in sweeps {
            grid = grid.flatMap { base in values.map { base + [(key, $0)] } }
        }
        func line(_ name: String, _ s: EotScore.Summary) -> String {
            String(format: "  %-40@ %6.1f%%    %6.1f%%    %5.2f    %6.0f ms  %6.0f ms %5.0f %5.0f  %3d",
                   name as NSString, s.decisionCutRate * 100, s.commitCutRate * 100, s.continuationsPerTurn,
                   s.meanDecisionLatency * 1000, s.meanCommitLatency * 1000,
                   s.p50CommitLatency * 1000, s.p90CommitLatency * 1000, s.ceilingEnds)
        }
        var results: [(String, EotScore.Summary)] = []
        for point in grid {
            var t = tuning
            for (k, v) in point { _ = set(&t, k, v) }
            var config = PolicyReplay.Config(tuning: t, probeSet: probe, inferenceSeconds: inference)
            config.withEvidence = !noEvidence
            let turns = tapes.map { EotScore.score($0, PolicyReplay.run($0, config), options) }
            let s = EotScore.summarize(turns)
            let name = point.isEmpty ? "current" : point.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            if frontier { results.append((name, s)) } else { print(line(name, s)) }
            if fragments {
                let runs = turns.flatMap(\.fragmentRuns).sorted()
                func share(_ x: Double) -> String { String(format: "%d", runs.filter { $0 >= x }.count) }
                print(String(format: "    fragments decided inside a pause: %d in %d turns (%.1f per 100); brain ran ≥1 s: %@, ≥2 s: %@, ≥3 s: %@; median %.2f s",
                             runs.count, turns.count, 100 * Double(runs.count) / Double(max(1, turns.count)),
                             share(1), share(2), share(3), runs.isEmpty ? 0 : runs[runs.count / 2]))
            }
        }
        if frontier {
            // The Pareto front of the reply's cut-offs against its latency, and
            // the cheapest setting under each budget (eot-bench's 2/5/10 %).
            var best = Double.infinity
            for (name, s) in results.sorted(by: { ($0.1.meanCommitLatency, $0.1.commitCutRate) < ($1.1.meanCommitLatency, $1.1.commitCutRate) })
            where s.commitCutRate < best - 1e-9 {
                best = s.commitCutRate
                print(line(name, s))
            }
            for budget in [0.02, 0.05, 0.10] {
                if let pick = results.filter({ $0.1.commitCutRate <= budget + 1e-9 })
                    .min(by: { $0.1.meanCommitLatency < $1.1.meanCommitLatency }) {
                    print(String(format: "  best at ≤%.0f%% cut-offs:", budget * 100))
                    print(line(pick.0, pick.1))
                }
            }
        }
        return 0
    }

    /// A tuning field by name, for `--set` and `--sweep`.
    static func set(_ t: inout VoiceMachine.Tuning, _ key: String, _ v: Double) -> Bool {
        switch key {
        case "wordStallSeconds": t.wordStallSeconds = v
        case "silenceFallbackSeconds": t.silenceFallbackSeconds = v
        case "verdictHoldSeconds": t.verdictHoldSeconds = v
        case "incompleteSilenceSeconds": t.incompleteSilenceSeconds = v
        case "midClauseSilenceSeconds": t.midClauseSilenceSeconds = v
        case "replyFloorSeconds": t.replyFloorSeconds = v
        case "onsetGraceSeconds": t.onsetGraceSeconds = v
        case "noWordsSeconds": t.noWordsSeconds = v
        default:
            // `ep.<name>`: a field of the evidence policy (`EndpointPolicy`),
            // starting from what shipped when none is set yet.
            guard key.hasPrefix("ep.") else { return false }
            var e = t.endpoint ?? EndpointPolicy.before
            switch String(key.dropFirst(3)) {
            case "decideAt": e.decideAt = v
            case "unsureAt": e.unsureAt = v
            case "unsureWait": e.unsureWait = v
            case "danglerWait": e.danglerWait = v
            case "midThoughtWait": e.midThoughtWait = v
            case "midClauseWait": e.midClauseWait = v
            case "holdBase": e.holdBase = v
            case "holdPerDoubt": e.holdPerDoubt = v
            case "shortWords": e.shortWords = Int(v)
            case "shortLess": e.shortLess = v
            case "counts": e.waitsCountThePause = v != 0
            case "maxHold": e.maxHold = v < 0 ? nil : v
            case "semanticDangles": e.semanticDangles = v != 0
            case "modelDangles": e.modelDangles = v != 0
            case "finishedLess": e.finishedLess = v
            case "modelFinishedLess": e.modelFinishedLess = v
            case "unknownMore": e.unknownMore = v
            case "ownerQuietFloor": e.ownerQuietFloor = v < 0 ? nil : v
            case "on": break
            default: return false
            }
            t.endpoint = e
        }
        return true
    }
}
