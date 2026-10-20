import AVFoundation
import FluidAudio
import Foundation
import MoeDictation
import MoeMeeting
import MoeVoice
import WhisperKit

/// The speech recognisers Moe can hear with, and the rule for choosing one.
///
/// Two engines, one seam. Parakeet (FluidAudio, CoreML on the Neural Engine)
/// is quick and covers English and the European languages; Whisper (WhisperKit)
/// is slower to load but covers everything else, and reads long recordings
/// better. Users choose a *language* in Settings, never an engine — the
/// routing here is the only place the two are told apart. UI strings must use
/// `displayName`, which deliberately never says "Parakeet" or "Whisper".
///
/// Same shape as `TtsBackend`: engines return text, never touch the audio
/// graph, and load lazily so an engine the user's language doesn't need is
/// never downloaded.
protocol SttBackend: Sendable {
    /// Neutral name for the UI — describes what it is good at, not what it is.
    var displayName: String { get }
    /// ISO 639-1 language code ("he", "en").
    func supportsLanguage(_ code: String) -> Bool
    /// True once the model is loaded and a transcription would not block on
    /// a download or a cold load.
    var isReady: Bool { get async }
    /// Download (first time) and load. `progress` gets short status text.
    func warmUp(progress: (@Sendable (String) -> Void)?) async throws
    /// 16 kHz mono float samples in, text out. `language` is an ISO 639-1
    /// hint; nil lets an engine that can detect language do so.
    func transcribe(samples16k: [Float], language: String?) async throws -> String
    /// Drop the model from memory. Reloaded on the next transcription.
    func unload() async
}

extension SttBackend {
    func transcribe(samples16k: [Float]) async throws -> String {
        try await transcribe(samples16k: samples16k, language: nil)
    }
    func warmUp() async throws { try await warmUp(progress: nil) }
}

// MARK: - Languages

/// One language the user can pick. `locale` is what goes into `Config.locale`
/// ("he-IL"); `code` is the ISO 639-1 part both engines are keyed on.
struct SpeechLanguage: Identifiable, Hashable {
    let locale: String
    let nativeName: String
    let englishName: String
    var id: String { locale }
    var code: String { String(locale.prefix(2)).lowercased() }
    /// "עברית (Hebrew)", or just "English" when the two are the same.
    var label: String {
        nativeName == englishName ? englishName : "\(nativeName) (\(englishName))"
    }
}

enum SpeechLanguages {
    /// The 25 languages Parakeet TDT 0.6B v3 was trained on, from the model
    /// card: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
    /// ("bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl,
    /// pt, ro, ru, sk, sl, es, sv, uk"). Hard-coded rather than read from
    /// FluidAudio's `Language` enum, which lists a few more scripts than the
    /// model was trained on.
    static let parakeetCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
    ]

    /// Everything offered in Settings: Parakeet's 25 plus the languages that
    /// need Whisper. Whisper speaks ~99, but a picker of 99 rows is a worse
    /// product than a picker of the ones people actually ask for; add a row
    /// when someone asks. Sorted by English name.
    static let all: [SpeechLanguage] = [
        // Parakeet v3
        .init(locale: "bg-BG", nativeName: "Български", englishName: "Bulgarian"),
        .init(locale: "hr-HR", nativeName: "Hrvatski", englishName: "Croatian"),
        .init(locale: "cs-CZ", nativeName: "Čeština", englishName: "Czech"),
        .init(locale: "da-DK", nativeName: "Dansk", englishName: "Danish"),
        .init(locale: "nl-NL", nativeName: "Nederlands", englishName: "Dutch"),
        .init(locale: "en-US", nativeName: "English", englishName: "English"),
        .init(locale: "et-EE", nativeName: "Eesti", englishName: "Estonian"),
        .init(locale: "fi-FI", nativeName: "Suomi", englishName: "Finnish"),
        .init(locale: "fr-FR", nativeName: "Français", englishName: "French"),
        .init(locale: "de-DE", nativeName: "Deutsch", englishName: "German"),
        .init(locale: "el-GR", nativeName: "Ελληνικά", englishName: "Greek"),
        .init(locale: "hu-HU", nativeName: "Magyar", englishName: "Hungarian"),
        .init(locale: "it-IT", nativeName: "Italiano", englishName: "Italian"),
        .init(locale: "lv-LV", nativeName: "Latviešu", englishName: "Latvian"),
        .init(locale: "lt-LT", nativeName: "Lietuvių", englishName: "Lithuanian"),
        .init(locale: "mt-MT", nativeName: "Malti", englishName: "Maltese"),
        .init(locale: "pl-PL", nativeName: "Polski", englishName: "Polish"),
        .init(locale: "pt-BR", nativeName: "Português", englishName: "Portuguese"),
        .init(locale: "ro-RO", nativeName: "Română", englishName: "Romanian"),
        .init(locale: "ru-RU", nativeName: "Русский", englishName: "Russian"),
        .init(locale: "sk-SK", nativeName: "Slovenčina", englishName: "Slovak"),
        .init(locale: "sl-SI", nativeName: "Slovenščina", englishName: "Slovenian"),
        .init(locale: "es-ES", nativeName: "Español", englishName: "Spanish"),
        .init(locale: "sv-SE", nativeName: "Svenska", englishName: "Swedish"),
        .init(locale: "uk-UA", nativeName: "Українська", englishName: "Ukrainian"),
        // Whisper only
        .init(locale: "ar-SA", nativeName: "العربية", englishName: "Arabic"),
        .init(locale: "zh-CN", nativeName: "中文", englishName: "Chinese"),
        .init(locale: "he-IL", nativeName: "עברית", englishName: "Hebrew"),
        .init(locale: "hi-IN", nativeName: "हिन्दी", englishName: "Hindi"),
        .init(locale: "id-ID", nativeName: "Bahasa Indonesia", englishName: "Indonesian"),
        .init(locale: "ja-JP", nativeName: "日本語", englishName: "Japanese"),
        .init(locale: "ko-KR", nativeName: "한국어", englishName: "Korean"),
        .init(locale: "fa-IR", nativeName: "فارسی", englishName: "Persian"),
        .init(locale: "th-TH", nativeName: "ไทย", englishName: "Thai"),
        .init(locale: "tr-TR", nativeName: "Türkçe", englishName: "Turkish"),
        .init(locale: "ur-PK", nativeName: "اردو", englishName: "Urdu"),
        .init(locale: "vi-VN", nativeName: "Tiếng Việt", englishName: "Vietnamese"),
    ].sorted { $0.englishName < $1.englishName }

    /// ISO 639-1 code from a locale tag, lowercased ("zh-Hans-CN" → "zh").
    static func code(of locale: String) -> String {
        let head = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? locale
        return head.lowercased()
    }

    /// The row matching a `Config.locale`, by language when the region differs.
    static func entry(for locale: String) -> SpeechLanguage? {
        all.first { $0.locale == locale } ?? all.first { $0.code == code(of: locale) }
    }

    /// What a fresh install starts in: the first of the Mac's preferred
    /// languages that Moe can hear, else English. The Mac's list is what
    /// System Settings › Language & Region shows, most preferred first;
    /// a language Moe has no row for (Afrikaans, say) falls through to the
    /// next one the person listed, and only then to en-US.
    static var systemDefault: String { systemDefault(preferring: Locale.preferredLanguages) }

    static func systemDefault(preferring languages: [String]) -> String {
        for tag in languages {
            if let row = entry(for: tag) { return row.locale }
        }
        return "en-US"
    }

    static func usesWhisper(_ locale: String) -> Bool {
        !parakeetCodes.contains(code(of: locale))
    }

    /// Whether turn-taking works as designed in this language.
    ///
    /// The endpointer that ends a turn on a finished sentence (Parakeet
    /// Realtime EOU) and the turn model that tells a pause from an ending
    /// are English-only; in every other language Moe falls back to
    /// silence alone, and the wake word is an English phrase. Settings
    /// says so rather than letting it feel broken (VOICE-PLAN.md §8).
    static func usesEnglishTurnTaking(_ locale: String) -> Bool {
        code(of: locale) == "en"
    }
}

// MARK: - Router

/// Picks the engine for a language, owns both, and does the resampling the
/// callers would otherwise all repeat.
///
/// Rule: Parakeet if it was trained on the language, otherwise Whisper. A
/// language neither table knows still goes to Whisper, with no hint, so its
/// detector decides — that is what makes a voice note in an unexpected
/// language come out as something rather than nothing.
final class SpeechRouter: Sendable {
    let parakeet: ParakeetBackend
    let whisper: WhisperBackend
    /// The cloud engine, when this Mac may use one (`CloudVoice`). Tried
    /// first for the languages it steers to; every failure falls back to
    /// the local engine below for that utterance and rests the cloud for a
    /// minute (`CloudSttHealth`). nil in the bare `init`, so a router built
    /// by a test or the CLI never opens a socket.
    let cloud: AssemblyAIBackend?
    /// Moe's last spoken reply, handed to the cloud engine as
    /// `agent_context` — the question the person is about to answer. Set
    /// by `VoiceEngine` just before each re-read, on its own thread, so
    /// nothing here reads `SpeechOut` from the wrong one.
    private let agentContext = AgentContextBox()
    /// Acoustic boosting for the Parakeet path. Idle — no model, no
    /// download — until `terms` returns something.
    let boost = VocabularyBoost()
    /// The user's vocabulary, read per utterance so an edit to
    /// vocabulary.txt reaches the next one without a restart. Empty by
    /// default so a router built by a test or the CLI costs nothing.
    private let terms: @Sendable () -> [String]
    /// The words visible on screen for *this* utterance (`LiveVocabulary`).
    ///
    /// Kept apart from `terms` on purpose, and it is the most important line
    /// in this file to get right. The Parakeet path boosts by building a CTC
    /// spotter *from the term list*, and `VocabularyBoost` rebuilds that
    /// session whenever the list changes — 0.4 s warm, 15 s cold, measured.
    /// A list that changes every single utterance would therefore put a model
    /// build on every single dictation. So the ephemeral terms go only where
    /// they are free: Whisper's prompt, which is prefilled tokens either way,
    /// and the polish prompt, which is a request that was already happening.
    /// The standing vocabulary, which changes about never, keeps the spotter.
    private let contextTerms: @Sendable () -> [String]

    init(parakeet: ParakeetBackend = ParakeetBackend(),
         whisper: WhisperBackend = WhisperBackend(),
         terms: @escaping @Sendable () -> [String] = { [] },
         contextTerms: @escaping @Sendable () -> [String] = { [] },
         cloud: Bool = false) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.terms = terms
        self.contextTerms = contextTerms
        let box = agentContext
        self.cloud = cloud
            ? AssemblyAIBackend(terms: terms, contextTerms: contextTerms, agentContext: { box.current() })
            : nil
    }

    /// What Moe last said, for the cloud engine's context. Cheap; call it
    /// before every re-read.
    func noteAgentContext(_ spoken: String) { agentContext.set(spoken) }

    // MARK: Live feed to the cloud
    //
    // The pipeline hands the cloud engine the turn's frames as they are
    // heard (`AudioPipeline.CloudFeed`), so the re-read at the end is a
    // force-end and a short wait rather than an upload. All four are cheap
    // and synchronous and do nothing when there is no cloud engine, it is
    // not entitled, the locale is not one it steers to, or it is resting
    // after a failure.

    /// A capture is starting: open the session (if it is not) and take
    /// frames from now on.
    func beginLiveTurn(locale: String) { cloud?.beginLiveTurn(locale: locale) }
    /// A frame the capture kept.
    func feedLive(_ samples16k: [Float]) { cloud?.feedLive(samples16k) }
    /// A re-read is about to be asked for: the turn fed so far must survive
    /// the capture switching off. Call it before `takeCapture`.
    func claimLiveTurn() { cloud?.claimLiveTurn() }
    /// The capture was taken for a re-read: what was fed is that turn.
    func markTurnBoundary() { cloud?.markTurnBoundary() }
    /// A turn is likely soon (the voice just became ready, a conversation
    /// just ended): open the session ahead of it.
    func warmCloud(locale: String) {
        guard let cloud else { return }
        Task { await cloud.warm(locale: locale) }
    }
    /// The capture stopped. A turn that was never taken is force-ended and
    /// its words dropped.
    func endLiveTurn() { cloud?.endLiveTurn() }

    final class AgentContextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ s: String) { lock.lock(); text = s; lock.unlock() }
        func current() -> String? { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// The vocabulary as the boost wants it. `SpeechModels` needs the same
    /// list the dictation path uses and has no business holding its own copy.
    func termsForBoost() -> [String] { VocabularyBoost.usable(terms()) }

    /// A router wired to the user's vocabulary — what every path that
    /// transcribes *for the user* should use. The bare `init` leaves the
    /// vocabulary empty, which is right for a test and wrong for the app:
    /// three call sites had quietly drifted into it before this existed.
    static func forUser() -> SpeechRouter {
        SpeechRouter(terms: { Vocabulary.shared.promptTerms(limit: VocabularyBoost.maxTerms) },
                     contextTerms: { LiveVocabulary.shared.current() },
                     cloud: true)
    }

    func backend(for locale: String) -> any SttBackend {
        SpeechLanguages.usesWhisper(locale) ? whisper : parakeet
    }

    /// Whether the accurate read for `locale` runs here, on Parakeet. The
    /// early read (`ProgressiveRead`, started on the VAD's edge) runs only
    /// for that path: Whisper is too slow to run twice on one turn, and a
    /// cloud recogniser reads the turn live on its own. **A router that puts
    /// a cloud engine first must answer false here**, so two recognisers
    /// never read one turn.
    func accurateReadIsLocal(locale: String) -> Bool {
        // Not when the cloud recogniser will do the read: it has been
        // hearing the turn live, and an early local read would be a second
        // recogniser running for nothing.
        if let cloud, cloud.shouldHandle(locale: locale) { return false }
        return !SpeechLanguages.usesWhisper(locale)
    }

    /// The language hint to hand the engine: nil when the locale is one we
    /// don't know, so Whisper detects rather than being told wrong.
    func hint(for locale: String) -> String? {
        let code = SpeechLanguages.code(of: locale)
        return backend(for: locale).supportsLanguage(code) ? code : nil
    }

    /// Transcribe, with the user's vocabulary given to whichever engine is
    /// used in the way that engine can take it.
    ///
    /// The two engines bias in opposite directions and both are used here:
    /// Parakeet is a *rescore* — decode first, then let a CTC pass look for
    /// the terms in the audio and correct what it finds (`VocabularyBoost`).
    /// Whisper is a *prompt* — the terms go in ahead of the audio as prior
    /// context, which is the only hook an autoregressive decoder gives you,
    /// and it costs nothing because the tokens are prefilled either way.
    ///
    /// Which is why only Whisper is given this utterance's on-screen words as
    /// well: a prompt absorbs a changing list for free, a spotter has to be
    /// rebuilt for it. See `contextTerms`.
    func transcribe(samples16k: [Float], locale: String) async throws -> String {
        if let heard = await cloudTranscribe(samples16k: samples16k, locale: locale) { return heard.text }
        let hint = hint(for: locale)
        if SpeechLanguages.usesWhisper(locale) {
            return try await whisper
                .transcribe(samples16k: samples16k, language: hint,
                            promptTerms: LiveVocabulary.merge(terms(), contextTerms()))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let (text, timings) = try await parakeet.transcribeWithTimings(samples16k: samples16k,
                                                                       language: hint)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return clean }
        let boosted = await boost.boost(text: clean, timings: timings,
                                        samples: samples16k, terms: terms())
        return (boosted ?? clean).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cloud engine's answer, or nil when it is not to be used or
    /// failed — in which case the local engine takes the utterance and one
    /// line says why. The engine has already marked itself unhealthy, so
    /// the next sixty seconds of utterances skip it without asking.
    private func cloudTranscribe(samples16k: [Float], locale: String) async -> (text: String, confidence: Float?)? {
        guard let cloud, cloud.shouldHandle(locale: locale) else { return nil }
        do {
            return try await cloud.transcribeScored(samples16k: samples16k, language: hint(cloud: locale))
        } catch AssemblyAIError.heardNothing {
            Log.write("stt: the cloud heard no words in that turn — reading it locally; the cloud stays on")
            return nil
        } catch {
            let why = cloud.lastFailure ?? AssemblyAIRedact.describe(error)
            Log.write("stt: cloud fell back to local — \(why); cloud off for \(Int(cloud.lastCooldown)) s")
            return nil
        }
    }

    /// The `language_codes` hint for the cloud: the locale's code when the
    /// model steers to it, else nil for native code-switching.
    private func hint(cloud locale: String) -> String? {
        let code = SpeechLanguages.code(of: locale)
        return AssemblyAILanguages.codes.contains(code) ? code : nil
    }

    /// The Whisper path on its own — what `transcribe` does after the cloud
    /// has declined, kept apart so `transcribeScored` does not ask twice.
    private func localTranscribe(samples16k: [Float], locale: String) async throws -> String {
        try await whisper
            .transcribe(samples16k: samples16k, language: hint(for: locale),
                        promptTerms: LiveVocabulary.merge(terms(), contextTerms()))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As `transcribe(samples16k:locale:)`, plus how sure the engine was.
    ///
    /// `nil` is a real answer, not a failure: Whisper reports nothing
    /// comparable, so a Whisper locale gets text and no number rather than a
    /// number that means nothing. Nothing gates on this yet — it is logged
    /// first, because a threshold picked before seeing the distribution is
    /// how the addressee anchor shipped a line that could never fire.
    func transcribeScored(samples16k: [Float], locale: String)
        async throws -> (text: String, confidence: Float?)
    {
        if let heard = await cloudTranscribe(samples16k: samples16k, locale: locale) { return heard }
        let hint = hint(for: locale)
        if SpeechLanguages.usesWhisper(locale) {
            return (try await localTranscribe(samples16k: samples16k, locale: locale), nil)
        }
        let (text, timings, confidence) = try await parakeet.transcribeScored(samples16k: samples16k,
                                                                              language: hint)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return (clean, confidence) }
        let boosted = await boost.boost(text: clean, timings: timings,
                                        samples: samples16k, terms: terms())
        return ((boosted ?? clean).trimmingCharacters(in: .whitespacesAndNewlines), confidence)
    }

    /// Microphone audio at whatever rate the graph runs at.
    func transcribe(samples: [Float], rate: Double, locale: String) async throws -> String {
        try await transcribe(samples16k: Self.resample(samples, from: rate), locale: locale)
    }

    /// One transcription taken apart, for `--stt-test`.
    ///
    /// Vocabulary boosting is the kind of feature that is invisible when it
    /// works and indistinguishable from a bad model when it does not, so
    /// there has to be a way to see both halves and what each cost. Never on
    /// the dictation path — it decodes twice.
    struct Diagnosis {
        let raw: String
        let boosted: String?
        let decodeSeconds: Double
        let boostSeconds: Double
        let terms: Int
    }

    func diagnose(samples16k: [Float], locale: String) async throws -> Diagnosis {
        let hint = hint(for: locale)
        let wanted = VocabularyBoost.usable(terms())
        if SpeechLanguages.usesWhisper(locale) {
            // Whisper biases in the prompt, so "before" and "after" are two
            // decodes rather than a decode and a rescore.
            let t0 = Date()
            let raw = try await whisper.transcribe(samples16k: samples16k, language: hint,
                                                   promptTerms: [])
            let decode = Date().timeIntervalSince(t0)
            guard !wanted.isEmpty else {
                return .init(raw: raw, boosted: nil, decodeSeconds: decode,
                             boostSeconds: 0, terms: 0)
            }
            let t1 = Date()
            let prompted = try await whisper.transcribe(samples16k: samples16k, language: hint,
                                                        promptTerms: wanted)
            return .init(raw: raw, boosted: prompted == raw ? nil : prompted,
                         decodeSeconds: decode,
                         boostSeconds: Date().timeIntervalSince(t1), terms: wanted.count)
        }
        // Load the CTC model before the clock starts. In the app this has
        // already happened at warm-up, so timing it here would report a cold
        // load as if it were the per-utterance cost — off by two orders of
        // magnitude, and in the flattering direction for whatever came next.
        await boost.warmUp(terms: wanted)
        let t0 = Date()
        let (raw, timings) = try await parakeet.transcribeWithTimings(samples16k: samples16k,
                                                                      language: hint)
        let decode = Date().timeIntervalSince(t0)
        let t1 = Date()
        let boosted = await boost.boost(text: raw, timings: timings,
                                        samples: samples16k, terms: wanted)
        return .init(raw: raw, boosted: boosted, decodeSeconds: decode,
                     boostSeconds: Date().timeIntervalSince(t1), terms: wanted.count)
    }

    /// Warm the engine the locale needs; the other is left cold.
    func warmUp(locale: String, progress: (@Sendable (String) -> Void)? = nil) async throws {
        try await backend(for: locale).warmUp(progress: progress)
        // The vocabulary model too, when there is a vocabulary — cold it
        // costs 15 s, and paying that on someone's first held key is the
        // difference between a feature and a fault. Detached and unawaited:
        // the speech model is what the caller is waiting on, and a boost
        // that is not ready yet simply does not happen for an utterance or
        // two. Only ever for the Parakeet path, which is the one that boosts.
        if !SpeechLanguages.usesWhisper(locale) {
            let terms = terms()
            guard !terms.isEmpty else { return }
            Task.detached(priority: .utility) { [boost] in await boost.warmUp(terms: terms) }
        }
    }

    /// Linear-interpolation resample to 16 kHz. Both engines want exactly
    /// that, and the microphone graph usually runs at 48 kHz.
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != 16_000, !samples.isEmpty else { return samples }
        let ratio = rate / 16_000
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        let last = samples.count - 1
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let lo = min(Int(pos), last)
            let hi = min(lo + 1, last)
            let t = Float(pos - Double(lo))
            out[i] = samples[lo] * (1 - t) + samples[hi] * t
        }
        return out
    }
}

// MARK: - Parakeet (FluidAudio)

/// Parakeet TDT 0.6B v3, CC-BY-4.0, ~600 MB int8. Downloaded by FluidAudio
/// into ~/Library/Application Support/FluidAudio/Models on first use, exactly
/// as the earlier English-only model was.
actor ParakeetBackend: SttBackend {
    nonisolated let displayName = "Fast (English & European)"

    private var manager: AsrManager?
    private var loading: Task<Void, Error>?

    nonisolated func supportsLanguage(_ code: String) -> Bool {
        SpeechLanguages.parakeetCodes.contains(code.lowercased())
    }

    var isReady: Bool { manager != nil }

    func warmUp(progress: (@Sendable (String) -> Void)?) async throws {
        if manager != nil { return }
        if let loading { try await loading.value; return }
        let task = Task<Void, Error> {
            // FluidAudio reports a "downloading" phase per file even when
            // every file is already on disk, so only show it when a download
            // is actually about to happen.
            let present = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
                switch p.phase {
                case .listing, .downloading:
                    if !present { progress?("downloading speech model… \(Int(p.fractionCompleted * 100))%") }
                case .compiling:
                    progress?("loading speech model…")
                }
            }
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    func transcribe(samples16k: [Float], language: String?) async throws -> String {
        try await transcribeWithTimings(samples16k: samples16k, language: language).text
    }

    /// The transcript and the token times from the *same* decode.
    ///
    /// Vocabulary boosting needs both, and asking for them separately would
    /// mean decoding twice; the TDT result carries the timings already, so
    /// this is the plain shape and `transcribe` is the one throwing half of
    /// it away.
    /// The whole result, including the engine's own confidence in it.
    ///
    /// That number was being dropped at the `return` — Parakeet reports one
    /// per result and Moe kept only the text, which left it unable to tell a
    /// sentence it heard clearly from one it assembled out of a cough. A
    /// fresh `TdtDecoderState` per call, so nothing carries between turns.
    func transcribeScored(samples16k: [Float], language: String?)
        async throws -> (text: String, timings: [TokenTiming], confidence: Float?)
    {
        try await warmUp(progress: nil)
        guard let manager else { return ("", [], nil) }
        var state = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples16k, decoderState: &state, language: hint)
        return (result.text, result.tokenTimings ?? [], result.confidence)
    }

    func transcribeWithTimings(samples16k: [Float],
                               language: String?) async throws -> (text: String, timings: [TokenTiming]) {
        let r = try await transcribeScored(samples16k: samples16k, language: language)
        return (r.text, r.timings)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// The same model, with token times — what a meeting timeline is
    /// built from. Loads on first use like `transcribe`, so a meeting that
    /// starts before the voice has warmed still works.
    func transcribeTimed(samples16k: [Float], language: String?) async throws -> [TimedToken] {
        try await transcribeDetailed(samples16k: samples16k, language: language)
            .timings.map(TimedToken.init)
    }

    /// Text *and* times from one decode. The meeting path needs both: the
    /// times build the timeline, and the text is what the vocabulary boost
    /// reads. Asking for them separately would decode the window twice.
    func transcribeDetailed(samples16k: [Float],
                            language: String?) async throws -> (text: String, timings: [TokenTiming]) {
        try await warmUp(progress: nil)
        guard let manager else { return ("", []) }
        var state = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples16k, decoderState: &state, language: hint)
        return (result.text, result.tokenTimings ?? [])
    }
}

// MARK: - Shared models

/// The loaded speech models, for parts of Moe that are not the voice —
/// meeting mode today. One Parakeet in memory, whoever asks
/// (VoiceEngine.stt is the router this wraps); never a second load.
struct SpeechModels: MeetingAsr {
    let router: SpeechRouter
    let locale: String

    func transcribeTimed(_ samples16k: [Float]) async throws -> [TimedToken] {
        // Meetings run on Parakeet regardless of the voice's language:
        // it is the engine with token times, and it is already loaded.
        // A Whisper-only language gets English-model output for now
        // (MEETING-MODE.md, Phase A status).
        let hint = router.hint(for: locale)
        let result = try await router.parakeet.transcribeDetailed(samples16k: samples16k, language: hint)
        let tokens = result.timings.map(TimedToken.init)

        // A meeting is where the vocabulary matters most — it is an hour of
        // people saying each other's names, their company's name and their
        // product's name, and getting those wrong is what makes a transcript
        // read as someone else's meeting. The dictation path has been boosted
        // since it was built; this window was not, purely because it returns
        // tokens rather than text.
        //
        // The boost still works in text, so it is asked for the *corrections*
        // and those are applied to the tokens, leaving every timestamp where
        // it was — the timeline, the speaker attribution and the
        // hallucination filter all key off those times.
        let terms = router.termsForBoost()
        guard !terms.isEmpty, !result.text.isEmpty, !result.timings.isEmpty else { return tokens }
        let fixes = await router.boost.corrections(text: result.text, timings: result.timings,
                                                   samples: samples16k, terms: terms)
        guard !fixes.isEmpty else { return tokens }
        return TokenRewrite.apply(fixes, to: tokens)
    }
}

// MARK: - Whisper (WhisperKit)

/// Whisper large-v3-turbo via WhisperKit, MIT code and MIT weights, ~626 MB.
///
/// Slow to load (seconds) and heavy to keep (over a gigabyte resident), so it
/// loads on the first transcription that needs it and lets go of the model
/// after ten idle minutes. The next use pays the load again, which is the
/// right trade for a model most users never need at all.
actor WhisperBackend: SttBackend {
    nonisolated let displayName = "Universal"

    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let idleUnloadSeconds: Double = 600

    /// Where the model lives. WhisperKit's own default is ~/Documents/huggingface,
    /// which is not a place an app should leave 600 MB; ours is under Moe's
    /// home so it goes away with everything else. `MOE_WHISPER_DIR` (debug
    /// builds) points a test at a scratch copy.
    static var directory: URL {
        if let env = TestHooks.env("MOE_WHISPER_DIR") { return URL(fileURLWithPath: env, isDirectory: true) }
        return Config.homeDir.appendingPathComponent("models/whisper", isDirectory: true)
    }

    /// True once the model has been downloaded, so a self-test can decide
    /// whether to run it without triggering a download.
    static var modelIsPresent: Bool {
        // All of it, not just one bundle: an interrupted download that left
        // TextDecoder behind must be finished, not loaded and failed on.
        ["config.json", "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
            .allSatisfy { FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }
    }

    /// WhisperKit lays out `<base>/models/<repo>/<variant>/`.
    static var modelFolder: URL {
        directory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(defaultModel)", isDirectory: true)
    }

    private let model: String
    private var kit: WhisperKit?
    private var loading: Task<Void, Error>?
    private var idleTimer: Task<Void, Never>?

    init(model: String = WhisperBackend.defaultModel) {
        self.model = model
    }

    nonisolated func supportsLanguage(_ code: String) -> Bool {
        // Whisper's own 99-language list; anything we offer is on it.
        Constants.languageCodes.contains(code.lowercased())
    }

    var isReady: Bool { kit != nil }

    func warmUp(progress: (@Sendable (String) -> Void)?) async throws {
        if kit != nil { touch(); return }
        if let loading { try await loading.value; return }
        let task = Task<Void, Error> {
            let folder: URL
            if Self.modelIsPresent {
                folder = Self.modelFolder
            } else {
                progress?("downloading universal speech model… 0%")
                folder = try await WhisperKit.download(
                    variant: model, downloadBase: Self.directory,
                    progressCallback: { p in
                        progress?("downloading universal speech model… \(Int(p.fractionCompleted * 100))%")
                    })
            }
            progress?("loading universal speech model…")
            let config = WhisperKitConfig(model: model, downloadBase: Self.directory,
                                          modelFolder: folder.path,
                                          verbose: false, logLevel: .none,
                                          prewarm: false, load: true, download: false)
            kit = try await WhisperKit(config)
        }
        loading = task
        defer { loading = nil }
        try await task.value
        touch()
    }

    func transcribe(samples16k: [Float], language: String?) async throws -> String {
        try await transcribe(samples16k: samples16k, language: language, promptTerms: [])
    }

    /// `promptTerms` are the user's vocabulary, handed to the decoder as
    /// prior context (`<|startofprev|> …`) — the same hook Whisper's own
    /// `initial_prompt` uses. It makes the spellings *likelier*, not certain,
    /// which is the honest ceiling for a prompt on an autoregressive model;
    /// the string-level `Vocabulary` pass afterwards is what makes them sure.
    ///
    /// Kept short deliberately. WhisperKit trims the prompt to half the token
    /// context, and a prompt that fills the window pushes the model toward
    /// continuing the *prompt* rather than transcribing the audio — the
    /// classic initial-prompt failure, where a long word list comes back as
    /// the transcript.
    func transcribe(samples16k: [Float], language: String?,
                    promptTerms: [String]) async throws -> String {
        try await warmUp(progress: nil)
        guard let kit else { return "" }
        // No idle unload while a long recording is being read.
        idleTimer?.cancel(); idleTimer = nil
        defer { touch() }
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = language == nil
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.promptTokens = Self.promptTokens(for: promptTerms, tokenizer: kit.tokenizer)
        // Long recordings (voice notes, meetings) are split on silence and
        // decoded in parallel; a push-to-talk utterance is one window anyway.
        options.chunkingStrategy = .vad
        let results = try await kit.transcribe(audioArray: samples16k, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    /// How many tokens of vocabulary the prompt may spend. WhisperKit itself
    /// allows half the token context (~111); a third of that is plenty for a
    /// word list and leaves the decoder's attention on the audio.
    static let promptTokenBudget = 48

    /// The vocabulary as prompt tokens, or nil when there is nothing to say.
    ///
    /// Terms are added whole — half a name is worse than no name — until the
    /// budget is gone, so a long vocabulary contributes its first terms
    /// rather than a truncated tail. `Vocabulary.promptTerms` already orders
    /// them by source priority: what the user typed comes before what was
    /// learned or synced from Contacts.
    static func promptTokens(for terms: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer, !terms.isEmpty else { return nil }
        var out: [Int] = []
        for term in terms {
            let piece = tokenizer.encode(text: out.isEmpty ? term : ", \(term)")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !piece.isEmpty else { continue }
            if out.count + piece.count > promptTokenBudget { break }
            out.append(contentsOf: piece)
        }
        return out.isEmpty ? nil : out
    }

    func unload() async {
        idleTimer?.cancel(); idleTimer = nil
        await kit?.unloadModels()
        kit = nil
    }

    /// Restart the idle clock. Whisper is dropped after ten quiet minutes.
    private func touch() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleUnloadSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
