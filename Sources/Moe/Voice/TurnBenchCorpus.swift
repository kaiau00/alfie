import FluidAudio
import Foundation
import MoeVoice

/// `Moe --turn-bench --corpus <dir>`: Tier 1 of the turn-taking harness over
/// the noisy conversation corpus (scripts/turnbench/mix.py;
/// research-eval-harness.md §3.3–3.6).
///
/// Every scenario's file goes through the real pipeline — Silero and the
/// noise-floor gate in `AudioPipeline`, Parakeet's streaming recogniser —
/// faster than real time, with Smart Turn asked wherever the engine would ask
/// it. That is written down as a tape (`<dir>/tapes.json`, resumable, reused
/// by later runs), and the tapes go through the real `VoiceMachine`:
/// `PolicyReplay` for a turn Moe is listening to, `BargeReplay` for a reply
/// somebody talks over. `CorpusScore` scores both against the corpus's own
/// word timings, overall and per SNR, category and echo level.
///
/// No microphone, nothing played, nothing installed.
extension TurnBench {

    struct CorpusTapes: Codable {
        var tapes: [String: TurnTape] = [:]
        /// RMS per 20 ms of each reply scenario's file: the loudness check.
        var levels: [String: [Double]] = [:]
        var inferenceMs: [Double] = []
        var keep = TurnAudio.pauseTheModelWasTrainedOn
        /// Reply tapes recorded live, the recogniser switched by the machine
        /// (`listenReply`). A reply tape not in here ran its recogniser
        /// throughout and is recorded again. Optional so older files load.
        var machineAsr: Set<String>?
        /// The live run's pauses per reply scenario: a replay of the tape
        /// under the same tuning must land on them exactly (the self-check).
        var livePauses: [String: [Double]]?
    }

    struct CorpusRow: Codable {
        let id: String, base: String, kind: String, category: String, snr: String, echo: String
        // turn
        var cutHolds: Int?, holds: Int?, latency: Double?, missed: Bool?, endReason: String?
        // reply
        var falseStop: Bool?, missedBargeIn: Bool?, stopLatency: Double?, duckLatency: Double?,
            exposure: Double?, judged: [String]?, refused: [String]?
    }

    static func corpus(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let dirPath = value("--corpus") else {
            print("""
            usage: Alfie --turn-bench --corpus <dir> [--tapes <file>] [--out <file>] [--rerecord]
                   [--limit n] [--shard k/n] [--first-voices n] [--snr clean,20,…] [--kind turn|reply] [--category c]
                   [--set key=value]… [--before] [--brain s] [--inference-ms n] [--label text] [--self-check]
                   (--set riseMarginDb=n is the pipeline's rise margin: record it to its own --tapes)
            """)
            return 2
        }
        let dir = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath)
        // `--tapes a.json,b.json`: all are read, new tapes go to the first —
        // so shards can record side by side and one run scores them together.
        let tapeURLs = (value("--tapes") ?? dir.appendingPathComponent("tapes.json").path)
            .split(separator: ",").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
        let tapesURL = tapeURLs[0]
        let outURL = value("--out").map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("results.json")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(TurnCorpus.self, from: data) else {
            print("no manifest at \(dir.path)/manifest.json — run scripts/turnbench/mix.py first")
            return 2
        }
        var scenarios = manifest.scenarios
        if let snrs = value("--snr")?.split(separator: ",").map(String.init) {
            scenarios = scenarios.filter { snrs.contains($0.snrLabel) }
        }
        if let kind = value("--kind") { scenarios = scenarios.filter { $0.kind == kind } }
        if let cat = value("--category") { scenarios = scenarios.filter { $0.category == cat } }
        if let shard = value("--shard")?.split(separator: "/").compactMap({ Int($0) }), shard.count == 2, shard[1] > 0 {
            // Whole voices per shard, so a partial run is still every
            // category and SNR for the voices it has.
            let voices = Array(Set(scenarios.map(\.voice))).sorted()
            let mine = Set(voices.enumerated().filter { $0.offset % shard[1] == shard[0] }.map(\.element))
            scenarios = scenarios.filter { mine.contains($0.voice) }
        }
        if let first = value("--first-voices").flatMap(Int.init) {
            // The first n voices in sorted order: a partial run that is still
            // every category and SNR for the voices it has.
            let keep = Set(Array(Set(scenarios.map(\.voice))).sorted().prefix(first))
            scenarios = scenarios.filter { keep.contains($0.voice) }
        }
        if let n = value("--limit").flatMap(Int.init) { scenarios = Array(scenarios.prefix(n)) }

        // The tuning under test: conversation mode as main ships it, unless told.
        var tuning = BargeReplay.shippedTuning()
        if args.contains("--before") { tuning.endpoint = nil }
        // The pipeline's rise margin (`NoiseFloorGate`): it changes what is
        // recorded, so a tape file holds one margin — pass `--tapes` apart.
        var riseMarginDb: Float?
        var i = 0
        while i < args.count {
            if args[i] == "--set", i + 1 < args.count {
                let kv = args[i + 1].split(separator: "=").map(String.init)
                if kv.count == 2, kv[0] == "riseMarginDb", let d = Float(kv[1]) {
                    riseMarginDb = d
                } else if kv.count == 2, let d = Double(kv[1]) {
                    if !set(&tuning, kv[0], d) && !setBarge(&tuning, kv[0], d) {
                        print("unknown setting \(args[i + 1])"); return 2
                    }
                } else { print("bad --set \(args[i + 1])"); return 2 }
                i += 2
            } else { i += 1 }
        }
        var eotOptions = EotScore.Options()
        if let b = value("--brain").flatMap(Double.init) { eotOptions.brainSeconds = b }

        // Tapes: reuse what is on disk, record the rest.
        func load(_ u: URL) -> CorpusTapes? { try? JSONDecoder().decode(CorpusTapes.self, from: Data(contentsOf: u)) }
        var own = load(tapesURL) ?? CorpusTapes()
        if args.contains("--rerecord") { own = CorpusTapes() }
        var store = own
        for u in tapeURLs.dropFirst() {
            guard let other = load(u) else { print("  (no tapes at \(u.path))"); continue }
            store.tapes.merge(other.tapes) { a, _ in a }
            store.levels.merge(other.levels) { a, _ in a }
            store.inferenceMs += other.inferenceMs
            store.machineAsr = (store.machineAsr ?? []).union(other.machineAsr ?? [])
            store.livePauses = (store.livePauses ?? [:]).merging(other.livePauses ?? [:]) { a, _ in a }
        }
        // The on-device model's measured answers (`Moe --turn-semantics`).
        var modelTable: [String: PolicyReplay.ModelAnswer]?
        if let path = value("--model-table") {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
                  let t = try? JSONDecoder().decode([String: PolicyReplay.ModelAnswer].self, from: d) else {
                print("no model table at \(path)"); return 2
            }
            modelTable = t
        }
        let modelBudget = (value("--model-budget").flatMap(Double.init) ?? 300) / 1000
        if let out = value("--dump-asked") {
            return dumpAsked(scenarios, store: store, tuning: tuning, to: out)
        }
        let sweeps: [(String, [Double])] = args.indices.compactMap { i in
            guard args[i] == "--sweep", i + 1 < args.count else { return nil }
            let kv = args[i + 1].split(separator: "=").map(String.init)
            guard kv.count == 2 else { return nil }
            return (kv[0], kv[1].split(separator: ",").compactMap { Double($0) })
        }
        if !sweeps.isEmpty {
            return sweep(scenarios, store: store, tuning: tuning, sweeps: sweeps, model: modelTable,
                         modelBudget: modelBudget, brain: eotOptions,
                         inference: max(0.001, (value("--inference-ms").flatMap(Double.init) ?? 60) / 1000),
                         out: value("--out"))
        }
        if let out = value("--reprobe") {
            return await reprobe(scenarios, dir: dir, store: store,
                                 to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
        }
        let live = store.machineAsr ?? []
        let missing = scenarios.filter { store.tapes[$0.id] == nil || ($0.isReply && !live.contains($0.id)) }
        if !missing.isEmpty {
            let code = await recordCorpus(missing, dir: dir, store: &own, to: tapesURL, tuning: tuning,
                                          riseMarginDb: riseMarginDb)
            if code != 0 { return code }
            store.tapes.merge(own.tapes) { _, b in b }
            store.levels.merge(own.levels) { _, b in b }
            store.inferenceMs += own.inferenceMs
            store.machineAsr = (store.machineAsr ?? []).union(own.machineAsr ?? [])
            store.livePauses = (store.livePauses ?? [:]).merging(own.livePauses ?? [:]) { _, b in b }
        }

        // Replay and score.
        // Smart Turn's answer time in the replay: a fixed 60 ms (the eot-bench
        // run measured 66 ms a call on a loaded Mac; ~12 ms unloaded), so a
        // result depends on the tapes and the tuning, never on how busy the
        // Mac was while recording. `--inference-ms` to change it; the
        // measured median is printed beside it.
        let measured = store.inferenceMs.sorted()
        let medianMs = measured.isEmpty ? 0 : measured[measured.count / 2]
        let inference = max(0.001, (value("--inference-ms").flatMap(Double.init) ?? 60) / 1000)
        print(String(format: "replaying with Smart Turn at %.0f ms a call (measured while recording: median %.0f ms over %d calls)",
                     inference * 1000, medianMs, measured.count))
        let probeSet = TurnTape.key(tail: store.keep)
        var rows: [CorpusRow] = []
        var turnScores: [(TurnCorpus.Scenario, CorpusScore.Turn)] = []
        var replyScores: [(TurnCorpus.Scenario, CorpusScore.ReplyTurn)] = []
        // The tapes were recorded live under the tuning given then; a replay
        // under the same one must pause exactly where the live run did.
        // `--self-check`: these tapes were recorded under this very `--set`.
        let tuned = (args.contains("--set") || args.contains("--before")) && !args.contains("--self-check")
        var liveChecked = 0
        var liveMismatch: [String] = []
        for s in scenarios {
            guard let tape = store.tapes[s.id] else { continue }
            let snr = s.snrLabel, echo = s.echoLabel
            if s.isTurn {
                var config = PolicyReplay.Config(tuning: tuning, probeSet: probeSet, inferenceSeconds: inference)
                config.withEvidence = tuning.endpoint != nil
                config.model = modelTable
                config.modelBudget = modelBudget
                let r = PolicyReplay.run(tape, config)
                let t = CorpusScore.score(tape, r, eotOptions)
                turnScores.append((s, t))
                var row = CorpusRow(id: s.id, base: s.base, kind: s.kind, category: s.category, snr: snr, echo: echo)
                row.cutHolds = t.eot.commitCuts; row.holds = t.eot.holds
                row.latency = t.missed ? nil : t.eot.commitLatency
                row.missed = t.missed; row.endReason = t.eot.endReason?.rawValue
                rows.append(row)
            } else if let reply = s.reply {
                var config = BargeReplay.Config(tuning: tuning)
                config.referenceRms = s.referenceRms
                let r = BargeReplay.run(tape, reply: reply, levels: store.levels[s.id], config)
                if let live = store.livePauses?[s.id], !tuned {
                    liveChecked += 1
                    if live.first.map({ String(format: "%.3f", $0) }) != r.pauses.first.map({ String(format: "%.3f", $0) }) {
                        liveMismatch.append(s.id)
                    }
                }
                let t = CorpusScore.score(s, r)
                replyScores.append((s, t))
                var row = CorpusRow(id: s.id, base: s.base, kind: s.kind, category: s.category, snr: snr, echo: echo)
                row.falseStop = t.falseStop; row.missedBargeIn = t.missed
                row.stopLatency = t.stopLatency; row.duckLatency = t.duckLatency; row.exposure = t.exposure
                row.judged = r.judged.map { String(format: "%.2f ", $0.t) + $0.decision.logLine }
                row.refused = r.refused
                rows.append(row)
            }
        }

        if liveChecked > 0 {
            print("self-check: replay vs live run on \(liveChecked) reply tapes — \(liveMismatch.isEmpty ? "identical" : "\(liveMismatch.count) differ: \(liveMismatch.prefix(5).joined(separator: ", "))")")
        }
        if tuned {
            print("note: --set/--before replays reply tapes recorded live under the shipped tuning; the recogniser was switched as that tuning switched it (Tier 0 — confirm live).")
        }
        let label = value("--label") ?? "main (shipped tuning)"
        let report = corpusReport(turns: turnScores, replies: replyScores, label: label,
                                  inferenceMs: inference * 1000)
        print(report)
        struct Output: Encodable {
            let label: String; let corpus: String; let scenarios: Int; let smartTurnMs: Double
            let report: String; let rows: [CorpusRow]
        }
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            try enc.encode(Output(label: label, corpus: dir.path, scenarios: rows.count,
                                  smartTurnMs: inference * 1000, report: report, rows: rows)).write(to: outURL)
            print("results → \(outURL.path)")
        } catch {
            print("could not write \(outURL.path): \(error)"); return 1
        }
        return 0
    }

    /// `--dump-asked <file>`: every distinct text the turn model is asked
    /// about over these turn tapes that the rules have no opinion on, one per
    /// line — what the on-device model would be shown, for
    /// `Moe --turn-semantics` to measure once.
    static func dumpAsked(_ scenarios: [TurnCorpus.Scenario], store: CorpusTapes,
                          tuning: VoiceMachine.Tuning, to path: String) -> Int32 {
        var seen = Set<String>(), lines: [String] = []
        let probeSet = TurnTape.key(tail: store.keep)
        for s in scenarios where s.isTurn {
            guard let tape = store.tapes[s.id] else { continue }
            var config = PolicyReplay.Config(tuning: tuning, probeSet: probeSet, inferenceSeconds: 0.06)
            config.withEvidence = tuning.endpoint != nil
            for text in PolicyReplay.run(tape, config).askedTexts {
                let key = TurnSemantics.key(text)
                guard !key.isEmpty, TurnSemantics.read(text) == .unknown, seen.insert(key).inserted else { continue }
                lines.append(key)
            }
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(toFile: (path as NSString).expandingTildeInPath,
                                                            atomically: true, encoding: .utf8)
        } catch { print("could not write \(path): \(error)"); return 1 }
        print("\(lines.count) distinct texts the rules have no opinion on → \(path)")
        return 0
    }

    /// `--sweep key=a,b,c` (repeatable) over the turn tapes: one line per
    /// setting — cut-offs overall and per category, latency, missed turns.
    /// For fitting on the dev split; the test split is scored once, by the
    /// plain report.
    static func sweep(_ scenarios: [TurnCorpus.Scenario], store: CorpusTapes, tuning: VoiceMachine.Tuning,
                      sweeps: [(String, [Double])], model: [String: PolicyReplay.ModelAnswer]?,
                      modelBudget: Double, brain: EotScore.Options, inference: Double, out: String?) -> Int32 {
        var grid: [[(String, Double)]] = [[]]
        for (key, values) in sweeps { grid = grid.flatMap { base in values.map { base + [(key, $0)] } } }
        let probeSet = TurnTape.key(tail: store.keep)
        let turns = scenarios.filter(\.isTurn).compactMap { s in store.tapes[s.id].map { (s, $0) } }
        let cats = ["pause", "correction", "filler", "and", "short", "single"]
        let modelNote = model.map { ", model table \($0.count) texts, budget \(Int(modelBudget * 1000)) ms" } ?? ""
        print("sweep: \(grid.count) settings over \(turns.count) turn tapes\(modelNote)")
        print("  cut%  " + cats.map { String($0.prefix(5)).padding(toLength: 6, withPad: " ", startingAt: 0) }.joined()
              + " p50   p90   mean  miss  setting")
        var lines: [String] = []
        for point in grid {
            var t = tuning
            for (k, v) in point { guard set(&t, k, v) else { print("unknown setting \(k)"); return 2 } }
            var byCat: [String: [CorpusScore.Turn]] = [:]
            var all: [CorpusScore.Turn] = []
            var missing = 0
            for (s, tape) in turns {
                var config = PolicyReplay.Config(tuning: t, probeSet: probeSet, inferenceSeconds: inference)
                config.withEvidence = t.endpoint != nil
                config.model = model
                config.modelBudget = modelBudget
                let r = PolicyReplay.run(tape, config)
                missing += r.modelMissing
                let sc = CorpusScore.score(tape, r, brain)
                all.append(sc); byCat[s.category, default: []].append(sc)
            }
            let s = CorpusScore.summarize(all)
            let per = cats.map { c -> String in
                String(format: "%5.1f ", CorpusScore.summarize(byCat[c] ?? []).eot.commitCutRate * 100)
            }.joined()
            let name = point.isEmpty ? "as given" : point.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            let line = String(format: "  %5.1f %@%5.0f %5.0f %5.0f %4d  %@%@", s.eot.commitCutRate * 100, per,
                              s.eot.p50CommitLatency * 1000, s.eot.p90CommitLatency * 1000,
                              s.eot.meanCommitLatency * 1000, s.missed, name,
                              missing > 0 ? " (model table missing \(missing))" : "")
            print(line); lines.append(line)
        }
        if let out {
            try? lines.joined(separator: "\n").write(toFile: (out as NSString).expandingTildeInPath,
                                                    atomically: true, encoding: .utf8)
        }
        return 0
    }

    /// Barge-in fields by name, for `--set`.
    static func setBarge(_ t: inout VoiceMachine.Tuning, _ key: String, _ v: Double) -> Bool {
        switch key {
        case "bargeInHoldSeconds": t.bargeInHoldSeconds = v
        case "interruptionWords": t.interruptionWords = Int(v)
        case "interruptionWordsWhileSpeaking": t.interruptionWordsWhileSpeaking = Int(v)
        case "onsetOnRise": t.onsetOnRise = v != 0
        case "duckOnRise": t.duckOnRise = v != 0
        default: return false
        }
        return true
    }

    /// `--reprobe <out.json>`: the same tapes with only Smart Turn asked again —
    /// by whichever model loads (`MOE_TURN_MODEL` pins one). Everything else a
    /// turn tape holds (VAD edges, the recogniser's words) does not depend on
    /// the turn model, so it is kept; only the voiced-frame times the audio
    /// trim needs are measured again, by the pipeline's VAD alone. Each probe
    /// is asked at the time the tape already asks it, on the audio
    /// `askTurnModel` would cut. Run with v3.2 it must reproduce the tape's
    /// own scores (printed): the falsifier that this is the same measurement.
    static func reprobe(_ scenarios: [TurnCorpus.Scenario], dir: URL, store: CorpusTapes, to url: URL) async -> Int32 {
        let detector = SmartTurnDetector()
        let vad: VadManager
        do {
            try await detector.load()
            vad = try await VadManager()
        } catch {
            print("model load failed: \(error)"); return 2
        }
        print("reprobe: model \(await detector.modelName ?? "?") → \(url.path)")
        var out = store
        var diffs: [Double] = []
        var n = 0
        for s in scenarios where s.isTurn {
            guard let tape = store.tapes[s.id], let old = tape.probes[TurnTape.key(tail: store.keep)] else { continue }
            guard let (mono, rate) = WakeBench.decode(dir.appendingPathComponent(s.wav)), rate == AudioPipeline.rate else {
                print("  \(s.id): unreadable or not 16 kHz"); continue
            }
            var run = Run()
            run.audio = mono
            run.voiced = await voicedTimes(mono, vad: vad)
            var last = ""
            for e in tape.events where e.kind == .partial {
                let text = e.text ?? ""
                if text.count > last.count { run.wordsGrew.append(e.t) }
                last = text
            }
            var list: [TurnTape.Probe] = []
            for p in old {
                guard let q = await probe(run, at: p.t, keep: store.keep, detector: detector) else { continue }
                list.append(.init(t: p.t, p: q))
                diffs.append(abs(q - p.p))
            }
            var probes = tape.probes
            probes[TurnTape.key(tail: store.keep)] = list
            out.tapes[s.id] = TurnTape(id: tape.id, events: tape.events, probes: probes, truth: tape.truth,
                                       duration: tape.duration)
            n += 1
            if n % 200 == 0 { print("  \(n) turn tapes") }
        }
        let sorted = diffs.sorted()
        print(String(format: "reprobe: %d turn tapes, %d probes; |Δp| vs the tapes: median %.4f, p99 %.4f, max %.4f",
                     n, diffs.count, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                     sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)], sorted.last ?? 0))
        do { try JSONEncoder().encode(out).write(to: url) } catch {
            print("could not write \(url.path): \(error)"); return 1
        }
        return 0
    }

    /// The times `listen` records as voiced (a confident VAD chunk well over
    /// the room), from the pipeline's VAD alone.
    static func voicedTimes(_ mono: [Float], vad: VadManager) async -> [Double] {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var fed = 0.0; var voiced: [Double] = []
        }
        let box = Box()
        let pipeline = AudioPipeline { out in
            if case .vad(let p, let peakDb, let floorDb, _) = out, p >= 0.85, floorDb.map({ peakDb >= $0 + 5 }) ?? true {
                box.lock.lock(); box.voiced.append(box.fed); box.lock.unlock()
            }
        }
        await pipeline.attach(vad: vad)
        let rate = AudioPipeline.rate
        let piece = Int(rate * 0.02)
        var i = 0
        while i < mono.count {
            let end = min(mono.count, i + piece)
            box.fed = Double(end) / rate
            await pipeline.ingest(Array(mono[i..<end]), rate: rate)
            i = end
        }
        return box.voiced
    }

    static func recordCorpus(_ scenarios: [TurnCorpus.Scenario], dir: URL, store: inout CorpusTapes,
                             to url: URL, tuning: VoiceMachine.Tuning, riseMarginDb: Float? = nil) async -> Int32 {
        let detector = SmartTurnDetector()
        let vad: VadManager
        let asr = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 400)
        do {
            try await detector.load()
            vad = try await VadManager()
            try await asr.loadModels()
        } catch {
            print("model load failed: \(error)"); return 2
        }
        let began = Date()
        var audioSeconds = 0.0
        print("turn bench: recording \(scenarios.count) scenario tapes")
        for (n, s) in scenarios.enumerated() {
            guard let (mono, rate) = WakeBench.decode(dir.appendingPathComponent(s.wav)), rate == AudioPipeline.rate else {
                print("  \(s.id): unreadable or not 16 kHz"); continue
            }
            audioSeconds += Double(mono.count) / rate
            if s.isReply, let reply = s.reply {
                let levels = rmsTrack(mono, hop: Int(rate * 0.02))
                var config = BargeReplay.Config(tuning: tuning)
                config.referenceRms = s.referenceRms
                let (events, result) = await listenReply(mono, reply: reply, levels: levels, config: config,
                                                         vad: vad, asr: asr, riseMarginDb: riseMarginDb)
                store.levels[s.id] = levels
                store.tapes[s.id] = TurnTape(id: s.id, events: events, duration: Double(mono.count) / rate)
                store.machineAsr = (store.machineAsr ?? []).union([s.id])
                store.livePauses = (store.livePauses ?? [:]).merging([s.id: result.pauses]) { _, b in b }
                if (n + 1) % 50 == 0 || n + 1 == scenarios.count {
                    let wall = Date().timeIntervalSince(began)
                    print(String(format: "  %d/%d, %.0f s of audio in %.0f s (%.1f× real time)",
                                 n + 1, scenarios.count, audioSeconds, wall, audioSeconds / max(wall, 0.001)))
                    if let data = try? JSONEncoder().encode(store) { try? data.write(to: url) }
                }
                continue
            }
            let run = await listen(mono, vad: vad, asr: asr, tail: 0)
            var probes: [String: [TurnTape.Probe]] = [:]
            if s.isTurn {
                var list: [TurnTape.Probe] = []
                for ask in run.askTimes {
                    let t0 = Date()
                    guard let p = await probe(run, at: ask, keep: store.keep, detector: detector) else { continue }
                    if store.inferenceMs.count < 2000 { store.inferenceMs.append(Date().timeIntervalSince(t0) * 1000) }
                    list.append(.init(t: ask, p: p))
                }
                probes[TurnTape.key(tail: store.keep)] = list
            }
            store.tapes[s.id] = TurnTape(id: s.id, events: run.events, probes: probes, truth: s.truth,
                                         duration: Double(mono.count) / rate)
            if (n + 1) % 50 == 0 || n + 1 == scenarios.count {
                let wall = Date().timeIntervalSince(began)
                print(String(format: "  %d/%d, %.0f s of audio in %.0f s (%.1f× real time)",
                             n + 1, scenarios.count, audioSeconds, wall, audioSeconds / max(wall, 0.001)))
                if let data = try? JSONEncoder().encode(store) { try? data.write(to: url) }
            }
        }
        do { try JSONEncoder().encode(store).write(to: url) } catch {
            print("could not write \(url.path): \(error)"); return 1
        }
        return 0
    }

    /// A reply scenario, live: the file through the real pipeline with the
    /// real recogniser switched and reset by the machine as the engine does
    /// it (`BargeReplay.Session`'s `AsrCommand`s, applied between 20 ms
    /// pieces), so the partials are what the engine would have read. Returns
    /// the tape and the live result under `config`.
    static func listenReply(_ mono: [Float], reply: TurnCorpus.Reply, levels: [Double],
                            config: BargeReplay.Config, vad: VadManager, asr: StreamingEouAsrManager,
                            riseMarginDb: Float? = nil) async -> (events: [TurnTape.Event], result: BargeReplay.Result) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var fresh: [TurnTape.Event] = []
            var fed = 0.0
            func add(_ e: TurnTape.Event) { lock.lock(); fresh.append(e); lock.unlock() }
            func take() -> [TurnTape.Event] { lock.lock(); defer { fresh.removeAll(); lock.unlock() }; return fresh }
        }
        let box = Box()
        await asr.reset()
        await asr.setPartialCallback { text in box.add(.init(t: box.fed, .partial, text)) }
        await asr.setEouCallback { text in box.add(.init(t: box.fed, .endOfUtterance, text)) }
        let pipeline = AudioPipeline { out in
            switch out {
            case .speechStarted: box.add(.init(t: box.fed, .speechStarted))
            case .speechEnded: box.add(.init(t: box.fed, .speechEnded))
            case .speechRose: box.add(.init(t: box.fed, .speechRose))
            default: break
            }
        }
        await pipeline.attach(vad: vad)
        await pipeline.attach(asr: asr)
        if let riseMarginDb { await pipeline.setRiseMargin(riseMarginDb) }
        await pipeline.setAsr(false)          // off while Moe talks, as the engine's is
        var session = BargeReplay.Session(reply: reply, levels: levels, config)
        var events: [TurnTape.Event] = []
        let rate = AudioPipeline.rate
        let piece = Int(rate * 0.02)
        var i = 0
        while i < mono.count {
            let end = min(mono.count, i + piece)
            box.fed = Double(end) / rate
            await pipeline.ingest(Array(mono[i..<end]), rate: rate)
            i = end
            for e in box.take().sorted(by: { $0.t < $1.t }) {
                events.append(e)
                session.handle(e)
            }
            session.advance(to: box.fed)
            for c in session.takeAsrCommands() {
                switch c {
                case .reset: await pipeline.resetAsr()
                case .on(let prime): await pipeline.setAsr(true, primeSeconds: prime)
                case .off: await pipeline.setAsr(false)
                }
            }
            // Paused, or the reply over: nothing after it is scored, and a
            // tape is only ever replayed that far.
            if session.done { break }
        }
        session.advance(to: reply.end)
        var r = session.result
        if r.until == 0 { r.until = min(session.now, reply.end) }
        return (events, r)
    }

    static func rmsTrack(_ x: [Float], hop: Int) -> [Double] {
        stride(from: 0, to: x.count, by: hop).map { a in
            let b = min(x.count, a + hop)
            var acc: Double = 0
            for i in a..<b { acc += Double(x[i]) * Double(x[i]) }
            return ((acc / Double(max(1, b - a))).squareRoot() * 1e6).rounded() / 1e6
        }
    }

    // MARK: - The report

    static func corpusReport(turns: [(TurnCorpus.Scenario, CorpusScore.Turn)],
                             replies: [(TurnCorpus.Scenario, CorpusScore.ReplyTurn)],
                             label: String, inferenceMs: Double) -> String {
        var out: [String] = []
        out.append("turn bench over the corpus — \(label); Smart Turn \(String(format: "%.0f", inferenceMs)) ms a call; instant brain")
        func pct(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }
        func pad(_ s: String) -> String { s.padding(toLength: 16, withPad: " ", startingAt: 0) }
        func ms(_ x: Double) -> String { String(format: "%5.0f", x * 1000) }

        let snrOrder = ["clean", "20", "10", "5", "0"]
        func groups<T>(_ items: [(TurnCorpus.Scenario, T)], by key: (TurnCorpus.Scenario) -> String,
                       order: [String]? = nil) -> [(String, [T])] {
            var d: [String: [T]] = [:]
            for (s, t) in items { d[key(s), default: []].append(t) }
            let keys = order.map { o in o.filter { d[$0] != nil } + d.keys.filter { !o.contains($0) }.sorted() }
                ?? d.keys.sorted()
            return keys.map { ($0, d[$0]!) }
        }

        if !turns.isEmpty {
            out.append("")
            out.append("TURNS (Alfie listening): cut-off = answered inside a pause the person went on after; latency = true end → reply audible")
            out.append("  group            turns  pauses  cut-off [95% CI]          p50 ms  p90 ms  missed  ceiling")
            func line(_ name: String, _ ts: [CorpusScore.Turn]) -> String {
                let s = CorpusScore.summarize(ts)
                let cuts = ts.reduce(0) { $0 + $1.eot.commitCuts }
                let ci = CorpusScore.wilson(cuts, s.eot.holds)
                return String(format: "  %@ %5d  %6d  %@ [%4.1f–%4.1f%%]   %@   %@   %5d  %5d",
                              pad(name), ts.count, s.eot.holds, pct(s.eot.commitCutRate),
                              ci.lo * 100, ci.hi * 100, ms(s.eot.p50CommitLatency), ms(s.eot.p90CommitLatency),
                              s.missed, s.eot.ceilingEnds)
            }
            out.append(line("all", turns.map(\.1)))
            for (k, v) in groups(turns, by: { "snr " + $0.snrLabel }, order: snrOrder.map { "snr " + $0 }) {
                out.append(line(k, v))
            }
            for (k, v) in groups(turns, by: \.category) { out.append(line(k, v)) }
        }
        if !replies.isEmpty {
            out.append("")
            out.append("REPLIES (Alfie talking): false = paused with no real interruption; missed = real one not paused within 2 s")
            out.append("  group            scen  Alfie min  false/10min  falseDuck/10min  missed [95% CI]           stop p50  p90   duck p50  bc stops")
            func line(_ name: String, _ ts: [CorpusScore.ReplyTurn]) -> String {
                let s = CorpusScore.summarize(ts)
                let ci = CorpusScore.wilson(s.missed, s.real)
                return String(format: "  %@ %4d  %7.1f  %5.2f (%3d)   %8.2f       %3d/%-3d %@ [%4.1f–%4.1f%%]  %@  %@   %@    %d/%d",
                              pad(name), ts.count, s.moeMinutes, s.falseStopsPer10Min, s.falseStops,
                              s.falseDucksPer10Min, s.missed, s.real, pct(s.missedRate), ci.lo * 100, ci.hi * 100,
                              ms(s.stopP50), ms(s.stopP90), ms(s.duckP50), s.backchannelStops, s.backchannels)
            }
            out.append(line("all", replies.map(\.1)))
            for (k, v) in groups(replies, by: { "snr " + $0.snrLabel }, order: snrOrder.map { "snr " + $0 }) {
                out.append(line(k, v))
            }
            for (k, v) in groups(replies, by: \.category) { out.append(line(k, v)) }
            for (k, v) in groups(replies, by: { "echo " + $0.echoLabel }) { out.append(line(k, v)) }
        }
        return out.joined(separator: "\n")
    }
}
