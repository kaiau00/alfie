import AVFoundation
import FluidAudio
import MoeAudio
import Foundation

/// The speech engines Moe can talk with.
///
/// All of them return raw samples rather than playing audio themselves, which
/// is deliberate: playback has to go through the one shared `AVAudioEngine` so
/// macOS's echo canceller has Moe's voice in its reference path. An engine that
/// plays its own audio would be heard by the microphone, and "Hey Moe" would
/// start triggering on Moe.
/// Supertonic was here and is gone, deliberately: it is OpenRAIL-M with
/// use-based restrictions, which is a licence obligation on every person who
/// installs Moe, and Izzy chose PocketTTS by ear. Carrying a restricted model
/// for a voice nobody picked is 161 MB and a legal footnote for nothing. The
/// backend and its benchmarks stay in git history; `TtsCatalogue` and
/// `Models.bundled` no longer name it.
enum TtsEngineKind: String, CaseIterable, Identifiable {
    case kokoro
    /// Downloaded on request, never bundled. See `PocketBackend`.
    case pocket
    /// Rendered in the cloud, nothing bundled and nothing downloaded. See
    /// `InworldBackend`. Offered only when `CloudVoice.mayUse(.tts)`, and
    /// never the default: it needs an entitlement and a network, and a
    /// fresh Mac must speak offline.
    case inworld

    var id: String { rawValue }

    /// Needs a network and a credential rather than a model on disk. The
    /// build's model guards have nothing to check for such an engine, and
    /// `loadVoiceBackend` falls back to `shipped` when the cloud is not
    /// available rather than failing to speak.
    var isCloud: Bool { self == .inworld }

    /// What Settings offers: every engine, the cloud one included on a Mac
    /// that may not use it yet — picking it there is how a person finds the
    /// plan that has it (VoicePane sends them to Upgrade). It used to be
    /// filtered by `CloudVoice.mayUse`, so the one voice worth paying for
    /// was invisible to exactly the people who had not paid.
    static var offered: [TtsEngineKind] { allCases }

    /// The engine a fresh install speaks with — and the one whose model
    /// `scripts/fetch-models.sh` must therefore stage into the app.
    ///
    /// These two drifted apart and shipped once: `Config.ttsEngine` defaulted
    /// to an engine `fetch-models.sh` did not stage, so a new Mac's first
    /// spoken word was a 770 MB download — or, offline, silence. One constant
    /// both halves read, and `TtsShippedDefaultTests` compares it against the
    /// staged set. Changing this means changing `fetch-models.sh` in the same
    /// commit.
    ///
    /// Kokoro, and it is now the only engine that renders. PocketTTS was the
    /// default for part of a day and was dropped for one reason that turned
    /// out to settle everything: **a Kokoro voice pack is 522 KB.** Its
    /// `af_heart.bin` is exactly 510 × 256 × 4 — the raw tensor — so the 28
    /// English packs upstream drop straight in (see
    /// `scripts/fetch-kokoro-voices.sh`).
    ///
    ///     PocketTTS   19 voices   776 MB
    ///     Kokoro      28 voices    14 MB
    ///
    /// 55× cheaper per voice, nine more of them, Apache-2.0 with no use
    /// restrictions instead of CC-BY with an acceptable-use clause, and one
    /// engine to test rather than three. The app goes from ~1.74 GB to
    /// ~970 MB, and what remains is mostly the three speech *recognisers* —
    /// 774 MB that Moe hears with and cannot shed.
    ///
    /// What is given up, honestly: PocketTTS was the only backend that
    /// streamed (39 ms to first frame against Kokoro's 171–282 ms), so every
    /// reply now waits for its sentence to render. Still far inside the
    /// 700 ms where a pause reads as broken, and the sentence-at-a-time
    /// chunking already in `Conductor` covers long replies.
    static let shipped: TtsEngineKind = .kokoro

    var displayName: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .pocket: return "PocketTTS"
        // Not "Cloud": that names where it runs, which nobody choosing a
        // voice cares about. It is the upgrade — the most natural voice —
        // and the name says so (owner, 2026-09-10).
        case .inworld: return "Premium"
        }
    }

    var blurb: String {
        switch self {
        case .kokoro:
            return "Moe's voice. Twenty-eight to choose from, male and female, British and American."
        case .pocket:
            return "Twenty-six voices, and the only one that starts speaking before it has finished thinking. A 939 MB download, kept after the first time."
        case .inworld:
            return "The best voice Moe has, rendered in the cloud and streamed back as it is spoken — the quickest to the first word. Part of the Away plans; when it is out of reach Moe speaks with Kokoro instead."
        }
    }

    /// What picking this costs, from the person's side of the screen.
    ///
    /// It used to name a download size for every engine including the two the
    /// app carries, which reads as a warning about something that will not
    /// happen: Kokoro and Supertonic ship inside Moe (`Models.bundled`) and
    /// are ready offline the moment they are chosen.
    var downloadSize: String {
        switch self {
        case .kokoro: return "Included — ready now"
        case .pocket:
            return PocketBackend.isDownloaded
                ? "Downloaded — ready now"
                : "939 MB to download, once"
        case .inworld:
            return "Nothing to download — rendered in the cloud"
        }
    }
}

/// A voice offered by an engine.
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let label: String
}

/// How each engine is asked to speak.
///
/// **Both engines ship on their library defaults, and that is the finding.**
/// Not the starting point — the conclusion, after a measured ladder proposed
/// otherwise and a listening test overruled it.
///
/// The measurement was real. On the audition line, speech duration with
/// leading and trailing silence trimmed:
///
///     engine        default pace     conversational English
///     Kokoro         234 wpm         150–170 wpm
///     PocketTTS      247 wpm
///
/// Both rush by that standard, and pace is the one naturalness axis that can
/// be measured rather than argued about. So Kokoro went to 0.78 (~170 wpm on
/// the ladder) and PocketTTS to temperature 0.5. Izzy heard the result as
/// "scratchy and slow", picked Kokoro's own default and PocketTTS at 0.7 —
/// the library values for both — and he was right on every count.
///
/// Two lessons worth more than the settings.
///
/// **A word rate is not a judgement of pace.** 0.78 measured 170 wpm on a
/// 16-word ladder line and 145 wpm on the audition line: same setting,
/// different sentence, and the second is below the band the first was chosen
/// to hit. I treated one measurement as the property it was standing in for.
///
/// **"Conversational English is 150–170 wpm" is a fact about people, not a
/// target for a voice.** A synthesiser slowed into that band by stretching
/// its duration predictor is not speaking more naturally; it is speaking the
/// same way, longer. The number was true and the inference from it was not.
///
/// What remains here earns its place by being about the engine rather than
/// about taste: which PocketTTS model set to load (`pocketPlacement` — one of
/// the three does not load at all on this Mac), and how much of a sentence it
/// reads with one acoustic context (`pocketMaxTokensPerChunk`). Speed and
/// temperature stay because a future engine may need them, and because
/// `--tts-ladder` still measures what they do.

struct TtsTuning {
    /// Speech-rate multiplier in the engine's own terms. Below 1 is slower.
    /// Ignored by engines with no rate control (PocketTTS, whose pace is
    /// fixed by the model, and Apple, which has its own `speechRate`).
    let speed: Float
    /// Supertonic's denoising step count. Higher is better and slower; the
    /// library default is 8 and at 48 ms a render there is room to spend.
    let steps: Int
    /// Unused by the engines that ship; kept as a seam.
    let temperature: Float

    /// Each engine's setting, chosen off the measured ladder.
    ///
    /// `Moe --tts-ladder` renders the range and reports the pace each setting
    /// actually reached, which is how these were picked rather than guessed.
    /// The response is markedly sub-linear — Kokoro loses only 25 wpm over
    /// the first 12% of speed and then 39 over the next 10 — so the useful
    /// settings are much lower than a proportional guess suggests:
    ///
    ///     Kokoro       1.00 → 234 wpm   0.88 → 209   0.78 → 170   0.70 → 155
    ///
    /// Kokoro was set to 0.78 off that ladder and it was too far. Re-measured
    /// on the audition line it came out at **145 wpm**, below the band, and
    /// Izzy heard it as slow — a 16-word count on a different sentence is not
    /// the same measurement, which is the lesson. 0.95 is a light touch off
    /// the default rather than a target pace, because the default was never
    /// what he complained about.
    ///     Supertonic   1.05 → 201 wpm   0.92 → 185   0.82 → 168   0.74 → 150
    ///     PocketTTS    temp 0.5 → 227   temp 0.7 → 247   temp 0.9 → 257
    ///
    /// So both rate-controlled engines sit at the top of the conversational
    /// band (150–170 wpm) and neither is pushed past it: below about 0.7 the
    /// duration predictor is being stretched far enough that vowels start to
    /// drawl, and a slow voice is its own kind of unnatural.
    ///
    /// PocketTTS has no rate control, so 0.5 is simply its slowest — and
    /// usefully its steadiest, since temperature turns out to move pace as
    /// well as variation. It stays the quickest-talking of the three and
    /// nothing here can change that.
    static func base(for engine: TtsEngineKind) -> TtsTuning {
        switch engine {
        case .kokoro:     return TtsTuning(speed: 1.0,  steps: 0, temperature: 0)
        // PocketTTS has no rate control. Its temperature is
        // `PocketBackend.temperature`, which is what the engine is handed.
        case .pocket:     return TtsTuning(speed: 1.0,  steps: 0, temperature: PocketBackend.temperature)
        // The server's own defaults; nothing here reaches the cloud.
        case .inworld:    return TtsTuning(speed: 1.0,  steps: 0, temperature: 0)
        }
    }
}

enum TtsCatalogue {

    /// PocketTTS's voice prompts, as they exist on disk.
    ///
    /// Read off the downloaded pack rather than copied from a model card —
    /// `constants_bin/*.safetensors`, twenty-six of them. A name here that
    /// the pack does not carry is a voice Settings offers and the engine
    /// cannot load, which is the failure `loadVoiceBackend` already had to
    /// be taught to survive once.
    ///
    /// `peter_yearsley` is the default: chosen by ear on 2026-09-03 when
    /// PocketTTS was briefly the shipped engine, and recorded here so the
    /// judgement is not made again from scratch.
    static let pocketVoices: [VoiceOption] = [
        ("alba", "Alba"), ("anna", "Anna"), ("azelma", "Azelma"),
        ("bill_boerst", "Bill"), ("caro_davy", "Caro"), ("charles", "Charles"),
        ("cosette", "Cosette"), ("eponine", "Eponine"), ("estelle", "Estelle"),
        ("eve", "Eve"), ("fantine", "Fantine"), ("george", "George"),
        ("giovanni", "Giovanni"), ("jane", "Jane"), ("javert", "Javert"),
        ("jean", "Jean"), ("juergen", "Juergen"), ("lola", "Lola"),
        ("marius", "Marius"), ("mary", "Mary"), ("michael", "Michael"),
        ("paul", "Paul"), ("peter_yearsley", "Peter"), ("rafael", "Rafael"),
        ("stuart_bell", "Stuart"), ("vera", "Vera"),
    ].map { VoiceOption(id: $0.0, label: $0.1) }

    /// Kokoro's voice packs.
    ///
    /// FluidAudio's ANE build publishes exactly one — `af_heart.bin`, 522,240
    /// bytes, female — and its docs say "single per variant". But that size is
    /// exactly 510 × 256 × 4: the raw voice-pack tensor and nothing else. The
    /// 54 packs upstream (`hexgrad/Kokoro-82M/voices/*.pt`) are the same
    /// tensor in a thin PyTorch wrapper, so a `.pt` unzipped and its
    /// 522,240-byte blob written out *is* a `.bin` this engine loads.
    ///
    /// Which means a male Kokoro voice costs **522 KB**, not a different
    /// engine. `scripts/fetch-kokoro-voices.sh` converts them.
    /// All 28 English Kokoro packs, converted by
    /// `scripts/fetch-kokoro-voices.sh`. `af_heart` first because it is the
    /// default and upstream's highest-rated; the rest grouped by accent and
    /// sex, which is what a person actually chooses on.
    ///
    /// Quality varies and the list does not pretend otherwise — upstream
    /// grades these by how much audio each was trained on, and several had
    /// under an hour. They cost 522 KB each, so the long tail is carried
    /// because it is nearly free, not because every one is good.
    static let kokoroVoices: [VoiceOption] = [
        .init(id: "af_heart", label: "Heart — American female"),
        .init(id: "af_bella", label: "Bella — American female"),
        .init(id: "af_alloy", label: "Alloy — American female"),
        .init(id: "af_aoede", label: "Aoede — American female"),
        .init(id: "af_jessica", label: "Jessica — American female"),
        .init(id: "af_kore", label: "Kore — American female"),
        .init(id: "af_nicole", label: "Nicole — American female"),
        .init(id: "af_nova", label: "Nova — American female"),
        .init(id: "af_river", label: "River — American female"),
        .init(id: "af_sarah", label: "Sarah — American female"),
        .init(id: "af_sky", label: "Sky — American female"),
        .init(id: "bf_alice", label: "Alice — British female"),
        .init(id: "bf_emma", label: "Emma — British female"),
        .init(id: "bf_isabella", label: "Isabella — British female"),
        .init(id: "bf_lily", label: "Lily — British female"),
        .init(id: "am_michael", label: "Michael — American male"),
        .init(id: "am_adam", label: "Adam — American male"),
        .init(id: "am_echo", label: "Echo — American male"),
        .init(id: "am_eric", label: "Eric — American male"),
        .init(id: "am_fenrir", label: "Fenrir — American male"),
        .init(id: "am_liam", label: "Liam — American male"),
        .init(id: "am_onyx", label: "Onyx — American male"),
        .init(id: "am_puck", label: "Puck — American male"),
        .init(id: "am_santa", label: "Santa — American male"),
        .init(id: "bm_george", label: "George — British male"),
        .init(id: "bm_daniel", label: "Daniel — British male"),
        .init(id: "bm_fable", label: "Fable — British male"),
        .init(id: "bm_lewis", label: "Lewis — British male"),
    ]

    /// Inworld's stock voices — only the IDs seen accepted by the API.
    ///
    /// Inworld publishes no list of its built-in voices in the docs (they
    /// live in its Playground), and a name offered here that the server
    /// rejects is a render error and no voice at all — the same failure the
    /// PocketTTS list guards against. So: Ashley, verified against the
    /// socket on 2026-09-06; Clive and Hana, the voices in Inworld's own
    /// JavaScript and Python examples. Add a name when it has been heard.
    ///
    /// Clive is first because he is the default (see `defaultVoice`), and
    /// the two are kept next to each other so a reordering cannot quietly
    /// change what a person hears — `defaultVoice` is what decides, and
    /// `CloudEngineTests` requires it to name a voice on this list.
    static let inworldVoices: [VoiceOption] = [
        .init(id: "Clive", label: "Clive — British male"),
        .init(id: "Ashley", label: "Ashley"),
        .init(id: "Hana", label: "Hana"),
    ]

    static func voices(for engine: TtsEngineKind, locale: String) -> [VoiceOption] {
        switch engine {
        case .kokoro:  return kokoroVoices
        case .pocket:  return pocketVoices
        case .inworld: return inworldVoices
        }
    }

    /// The voice each engine starts on when a person switches to it.
    ///
    /// Every one of these is a judgement made by ear and recorded here so it
    /// is not made again from scratch, and each must be an id the engine's
    /// own list above carries — `CloudEngineTests` and `OptionalEngineTests`
    /// check that, because a default the engine cannot load is silence.
    ///
    ///   - Kokoro: `af_heart`, upstream's highest-rated pack and the one the
    ///     app bundles.
    ///   - PocketTTS: `peter_yearsley`, chosen on 2026-09-03 when PocketTTS
    ///     was briefly the shipped engine, and asked for again on
    ///     2026-09-07: "when a user uses Pocket TTS, if they download it,
    ///     the default voice over there should be Peter."
    ///   - Inworld: `Clive`, asked for on 2026-09-07 — "the Cloud voice
    ///     should default to Clive". It was `Ashley`, which is simply the
    ///     first name that had been verified against the socket; nobody
    ///     chose it.
    static func defaultVoice(for engine: TtsEngineKind, locale: String) -> String {
        switch engine {
        case .kokoro:  return "af_heart"
        case .pocket:  return "peter_yearsley"
        case .inworld: return "Clive"
        }
    }

    /// The local voice that stands in for a cloud voice when the cloud
    /// cannot speak — a sentence mid-reply, or a whole session with no
    /// network.
    ///
    /// It used to be `defaultVoice(for: .shipped)` whatever the person had
    /// chosen, so Clive — a British man — dropped mid-answer into Heart, an
    /// American woman: 14 of 284 replies from 09-23 to 09-29, seven of them
    /// changing voice mid-reply, and the owner's word for it was
    /// "confusing" (`~/moe-voice-notes/audit-2026-09-29/audit-cloud-local.md`).
    /// The same accent and sex is the closest thing Kokoro has to "the same
    /// person"; every pack named here ships in the app bundle.
    static func localTwin(ofCloudVoice voice: String) -> String {
        switch voice {
        case "Clive": return "bm_george"
        default: return defaultVoice(for: .shipped, locale: "")
        }
    }

    /// How Settings labels a voice id, for a sentence that has to name the
    /// voice a person is actually hearing. Falls back to the id, which is
    /// still more use than nothing.
    static func label(of voice: String, for engine: TtsEngineKind, locale: String) -> String {
        voices(for: engine, locale: locale).first { $0.id == voice }?.label ?? voice
    }

}

/// Renders text to 24kHz-ish mono samples. Implementations must not play audio.
protocol TtsBackend: Sendable {
    var sampleRate: Double { get }
    func warmUp() async throws
    func render(_ text: String, voice: String) async throws -> [Float]
    /// Audio as it is synthesised, for engines that can; the whole render
    /// as one element for those that cannot.
    func stream(_ text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error>
    /// Stop the render in flight, for engines where stopping is more than
    /// dropping the iterator — a cloud engine has to tell the server, or it
    /// keeps generating (and billing) into a stream nobody reads. Called
    /// from `SpeechOut.stop()`. A no-op by default.
    func cancel() async
    /// Renders somewhere other than this Mac. `VoiceEngine` keeps a local
    /// engine beside such a backend for the sentence-level fallback, and
    /// does not spend a warm-up render on it.
    var isCloudBackend: Bool { get }
    /// A voice turn has begun: be ready to speak its reply. The cloud voice
    /// re-opens a socket that has closed or idled out; PocketTTS, gone cold
    /// after a minute idle, renders one throwaway word; the others have
    /// nothing to do. Nothing it renders is ever played.
    func prepareForTurn() async
    /// A render on this backend stalled (`TtsStallGuard`): the connection
    /// under it is not to be trusted with the next one. The cloud voice
    /// drops its socket so the next render opens a fresh one; a local
    /// engine has none.
    func abandonConnection() async
}

extension TtsBackend {
    func cancel() async {}
    func prepareForTurn() async {}
    func abandonConnection() async {}
    var isCloudBackend: Bool { false }

    func stream(_ text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let samples = try await render(text, voice: voice)
        return AsyncThrowingStream { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
    }
}

// MARK: - PocketTTS

/// The optional voice: twenty-six of them, and the only engine here that
/// makes sound before it has finished thinking.
///
/// **Nothing about this ships in the app.** It is absent from
/// `Models.bundled` and from `fetch-models.sh`'s lists, which means
/// `scripts/check-bundled-models.sh` actively refuses a build that carries
/// it — the "zero bytes in the bundle" claim is enforced by a guard that
/// already existed, not by intention. The first time someone chooses this
/// voice, FluidAudio's `ModelHub` fetches 939 MB into its own cache and
/// keeps it.
///
/// It was the shipped engine for part of a day and was dropped on
/// 2026-09-03 for size (e9a8a0c). Two things bring it back as a download
/// rather than as the default. Its licence is a research licence carrying a
/// no-impersonation clause, and `LICENSES.md` is explicit that an
/// obligation like that passes through to everyone Moe is redistributed to
/// — the same class of thing Supertonic was removed for. And 939 MB is not
/// a first-run experience: `TtsEngineKind.shipped` stays Kokoro so a fresh
/// Mac can speak before it can download.
///
/// The measured size is 939 MB, not the 776 MB the old comment recorded and
/// not the 530 MB a file listing suggests — `du` against the cache after
/// fetching it.
actor PocketBackend: TtsBackend {

    let sampleRate: Double = 24_000

    /// The one pack Moe loads, named once so the download, the on-disk check
    /// and the manager cannot ask for three different variants. FluidAudio
    /// filters the fetch to exactly this precision and placement, so a check
    /// against any other set would call a complete pack incomplete — or a
    /// half-fetched one complete.
    static let language: PocketTtsLanguage = .english
    static let precision: PocketTtsPrecision = .fp16
    static let placement: PocketTtsModelPlacement = .gpu

    /// Kyutai's own value for the English model, not FluidAudio's.
    ///
    /// FluidAudio defaults to 0.7, the value for Pocket's first English
    /// release, and Moe never passed one, so every reply was rendered at 0.7.
    /// Kyutai's pocket-tts 3.1.0 ships `default_temperature: 0.3` for English
    /// ("Human evals preferred this model at 0.3", config/english.yaml), and
    /// that is what the Pulse voice server runs. The owner compared both on
    /// 2026-10-06, peter_yearsley, same sentence: 0.3 was the one that
    /// sounded right.
    static let temperature: Float = 0.3

    /// Where the pack lives: `pocket-tts/v2.1/english` under
    /// `Models.Root.cache`. The root is Moe's; the two names under it are
    /// read from FluidAudio, so this cannot drift from where `ensureModels`
    /// writes. `base` stands in for the real root in tests.
    static func packRoot(under base: URL? = nil) -> URL {
        Models.Root.cache.url(under: base)
            .appendingPathComponent(Repo.pocketTts.folderName, isDirectory: true)
            .appendingPathComponent(language.repoSubdirectory, isDirectory: true)
    }

    /// Every file `warmUp()` will load is on disk — FluidAudio's own list for
    /// this variant, file by file. It used to be "the folder is not empty",
    /// which a download stopped half-way also satisfies: the downloader
    /// writes one file at a time, so that folder is not empty and the engine
    /// cannot speak. Checked rather than assumed, because the alternative is
    /// `warmUp()` blocking Moe's first spoken word on a 939 MB download.
    static func isDownloaded(under base: URL? = nil) -> Bool {
        let root = packRoot(under: base)
        let required = ModelNames.PocketTTS.requiredModels(precision: precision, placement: placement)
        guard !required.isEmpty else { return false }
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    static var isDownloaded: Bool { isDownloaded(under: nil) }

    /// One step of the download, in the person's words: how far, and what
    /// it is doing. FluidAudio's phases are for a log; these are for a row
    /// in Settings.
    struct DownloadStep: Sendable {
        let fraction: Double
        let text: String

        init(_ progress: DownloadProgress) {
            fraction = min(max(progress.fractionCompleted, 0), 1)
            switch progress.phase {
            case .listing:
                text = "Finding the files…"
            case .downloading(let done, let total):
                text = total > 0 ? "Downloading — \(done) of \(total) files so far." : "Downloading…"
            case .compiling:
                text = "Nearly there — preparing the voice."
            }
        }
    }

    struct DownloadError: LocalizedError {
        let errorDescription: String?
    }

    /// Fetch the pack without loading it — the Download row in Settings ›
    /// Voice. FluidAudio's own downloader, which resumes and retries by
    /// itself; `warmUp()` afterwards finds the files and touches no network.
    /// Finishes only when `isDownloaded` says yes; stopping the consumer
    /// stops the fetch.
    static func download() -> AsyncThrowingStream<DownloadStep, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await PocketTtsResourceDownloader.ensureModels(
                        language: language, precision: precision, placement: placement
                    ) { continuation.yield(DownloadStep($0)) }
                    guard isDownloaded else {
                        throw DownloadError(errorDescription: "the download finished, but the voice is not all there")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private let manager = PocketTtsManager(language: PocketBackend.language,
                                           precision: PocketBackend.precision,
                                           placement: PocketBackend.placement)
    private var ready = false
    /// The start of the last render, real or throwaway.
    private var lastUsed: Date?
    /// The voice the last real render used, for the throwaway one.
    private var lastVoice = ""
    /// A throwaway render in flight; a real one waits for it rather than
    /// running beside it on the same model.
    private var rewarming: Task<Void, Never>?

    /// Idle past this, the first frame of the next sentence is slow: 610 ms
    /// at the median against 126 ms warm (10-02 → 10-15, 604 sentences;
    /// 19 of the 26 first frames over a second came after such an idle).
    static let coldAfterSeconds: Double = 60

    static func isCold(lastUsed: Date?, now: Date) -> Bool {
        guard let lastUsed else { return false }   // never rendered: warmUp's job
        return now.timeIntervalSince(lastUsed) > coldAfterSeconds
    }

    func warmUp() async throws {
        guard !ready else { return }
        try await manager.initialize()
        ready = true
    }

    /// A turn is being captured, and its reply will want this engine. Gone
    /// cold, it renders one word nobody hears now, while the person is still
    /// talking, instead of paying for it on the reply's first sentence.
    func prepareForTurn() async {
        guard ready, rewarming == nil, Self.isCold(lastUsed: lastUsed, now: Date()) else { return }
        lastUsed = Date()
        let began = Date()
        let voice: String? = lastVoice.isEmpty ? nil : lastVoice
        let task = Task(priority: .userInitiated) { [manager] in
            do {
                let frames = try await manager.synthesizeStreaming(text: "Okay.", voice: voice,
                                                                   temperature: Self.temperature)
                for try await _ in frames {}
            } catch {}
        }
        rewarming = task
        await task.value
        rewarming = nil
        Log.write("tts: PocketTTS was idle — re-warmed for the turn in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
    }

    func render(_ text: String, voice: String) async throws -> [Float] {
        // Collected from the streaming path rather than `synthesize`, which
        // hands back an encoded WAV that would have to be parsed straight
        // back into the samples the stream already yields.
        var all: [Float] = []
        for try await frame in try await stream(text, voice: voice) {
            all.append(contentsOf: frame)
        }
        return all
    }

    /// The first engine in Moe for which this is not the default wrapper
    /// around `render`.
    ///
    /// `TtsBackend.stream`'s default implementation renders everything and
    /// yields once, so until now every engine's "first audio" was its whole
    /// utterance — which is why `SpeechOut`'s `tts: N chars synthesised in
    /// M ms` line has always read as a complete render. With this one it
    /// becomes what it says: time to the first sound. Expect that number to
    /// fall sharply for this engine and not move for the others.
    func stream(_ text: String, voice: String) async throws -> AsyncThrowingStream<[Float], Error> {
        try await warmUp()
        if let rewarming { await rewarming.value }
        lastUsed = Date()
        lastVoice = voice
        let chosen = voice.isEmpty ? nil : voice
        // Started from a high-priority task so the synthesiser's own tasks
        // inherit it: during a turn the renderer shares the Mac with the
        // brain, the recogniser and the wake word, and a render that falls
        // behind is a gap mid-word (`SpeechOut.preRollSeconds`).
        let frames = try await Task(priority: .userInitiated) { [manager] in
            try await manager.synthesizeStreaming(text: text, voice: chosen, temperature: Self.temperature)
        }.value
        return AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    for try await frame in frames {
                        if Task.isCancelled { break }
                        continuation.yield(frame.samples)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer must stop the synthesiser, not leave
            // it producing into a stream nobody reads. This is not the
            // bounded cancel barge-in needs — nothing here promises to stop
            // within any particular time — it only stops the work.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Kokoro

actor KokoroBackend: TtsBackend {
    nonisolated let sampleRate: Double = 24_000
    private let manager = KokoroAneManager(variant: .english)
    private var ready = false
    private let tuning: TtsTuning

    init(tuning: TtsTuning = .base(for: .kokoro)) { self.tuning = tuning }

    func warmUp() async throws {
        guard !ready else { return }
        // Pronunciation overrides go in before the phonemizer is built; the
        // manager checks them ahead of its Misaki lexicon and G2P fallback.
        await manager.setEnglishCustomLexicon(Pronunciations.load())
        try await manager.initialize()
        ready = true
    }

    func render(_ text: String, voice: String) async throws -> [Float] {
        try await warmUp()
        // `speed` was never passed and the library default is 1.0, which
        // measured 220 wpm on the audition line — a third faster than a
        // person. It divides the predicted duration vector, so it stretches
        // the pauses along with the phonemes rather than just drawling.
        let result = try await manager.synthesizeDetailed(
            text: text, voice: voice.isEmpty ? nil : voice, speed: tuning.speed)
        // Kokoro emits 40–51 single-sample impulses a second — by far the
        // worst of the three, and the reason it ticks between words. See
        // `Declick`.
        var samples = result.samples
        let mended = Declick.repair(&samples, sampleRate: sampleRate)
        if mended > 0 { Log.write("tts: declicked \(mended) sample(s) (kokoro)") }
        return samples
    }
}

// MARK: - Pronunciations

/// Words Kokoro gets wrong, mapped to how they should sound.
///
/// Values are Misaki-flavoured IPA (the notation Kokoro was trained on):
/// stress with ˈ / ˌ, and the diphthongs written as single capitals —
/// A = eɪ, I = aɪ, O = oʊ, W = aʊ, Y = ɔɪ. Users add their own in
/// ~/.moe/pronunciations.json as `{"word": "ipa"}`; those win over the
/// built-in list. Lookup is exact spelling first, then lower-cased.
enum Pronunciations {
    static let fileURL = Config.homeDir.appendingPathComponent("pronunciations.json")

    static let builtIn: [String: String] = [
        "Moe":        "mˈO",
        "nginx":      "ˈɛnʤɪnˌɛks",
        "Nguyen":     "wˈɪn",
        "Kubernetes": "kˌubɚnˈɛɾiz",
        "kubectl":    "kˈubkənɚˌɔl",
        "Postgres":   "pˈOstɡɹɛs",
        "PostgreSQL": "pˈOstɡɹɛs kˈju ˈɛl",
        "SQL":        "sˈikwəl",
        "JSON":       "ʤˈAsən",
        "YAML":       "jˈæməl",
        "GIF":        "ɡˈɪf",
        "OAuth":      "ˈOˌɔθ",
        "Xcode":      "ˈɛkskˌOd",
        "macOS":      "mˈæk ˌO ˈɛs",
        "iOS":        "ˈI ˌO ˈɛs",
        "npm":        "ˈɛn pˈi ˈɛm",
        "Claude":     "klˈɔd",
    ]

    static func load() -> [String: String] {
        var table = builtIn
        if let data = try? Data(contentsOf: fileURL),
           let user = try? JSONDecoder().decode([String: String].self, from: data) {
            table.merge(user) { _, mine in mine }
        }
        return table
    }
}

