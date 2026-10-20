import Foundation

/// The second cleanup pass for dictation: the rule-cleaned transcript goes to
/// the connected brain for a rewrite, with a hard time budget. Anything
/// short of a good answer inside the budget — a timeout, an error, Hermes
/// not up, a reply that fails the guard — means the caller pastes the
/// rule-cleaned text it already has. Dictation is never blocked on this.
///
/// It speaks to the same `POST /v1/chat/completions` as `HermesBrain`, but on
/// a session of its own: a dedicated, persisted UUID (`dictationSessionID`)
/// so the rewrites never land in the conversation's transcript, and so the
/// session stays warm — Hermes keeps one claude child per session, and a warm
/// one answers in about a second where a cold one takes several. The session
/// key `moe-dictation` keeps Hermes's memory scoped to the same person while
/// telling it apart from the conversation.
///
/// Nothing here logs the text. A transcript is whatever the user was typing.
final class DictationPolisher {

    static let sessionKey = "moe-dictation"

    private let endpoint: HermesEndpoint
    /// Provider + model for the rewrite: `dictationPolishModel`, else the
    /// conversation's model.
    private let brain: BrainSelection
    private let session: URLSession
    private let sessionID: String
    private let vocabulary: () -> [String]

    /// `vocabulary` is read per request, not at init, so an edit to
    /// vocabulary.txt reaches the next dictation without a restart.
    init(config: Config, vocabulary: @escaping () -> [String]) {
        endpoint = HermesEndpoint(config: config)
        brain = BrainSelection.forDictation(config: config)
        self.vocabulary = vocabulary
        let cfg = HermesEndpoint.sessionConfiguration()
        // The budget is enforced per call below; this only stops a socket
        // outliving a forgotten task.
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        if config.dictationSessionID.isEmpty {
            // Minted once and kept: the whole point is a session that is the
            // same tomorrow as today.
            let fresh = UUID().uuidString.lowercased()
            Config.update { $0.dictationSessionID = fresh }
            sessionID = fresh
        } else {
            sessionID = config.dictationSessionID
        }
    }

    /// A silent turn so the session's claude child is already up when the
    /// first real dictation arrives. Fire and forget.
    ///
    /// Same system prompt as a real polish, or the warm-up is worse than
    /// nothing: Hermes respawns the child when the prompt changes, so a
    /// warm-up on a different prompt only pays for a child the first
    /// dictation then has to replace (see PolishPrompt).
    func warmUp() {
        Task.detached(priority: .utility) { [self] in
            let req = endpoint.chatRequest(sessionID: sessionID, sessionKey: Self.sessionKey,
                                           system: PolishPrompt.system(vocabulary: vocabulary()),
                                           user: PolishPrompt.user(transcript: "ready", app: nil),
                                           stream: true, brain: brain,
                                           origin: nil)   // side session: never live
            _ = try? await session.data(for: req)
            Log.write("dictation: polish session warmed")
        }
    }

    /// The rewritten text, or nil when the rule-cleaned `text` should be used.
    ///
    /// `before` is what is already in the field ahead of the cursor, when it
    /// could be read; see `CursorContext`.
    func polish(_ text: String, app: PolishPrompt.FrontApp?, before: String? = nil,
                budget: TimeInterval) async -> String? {
        await polish(text, prompt: PolishPrompt.assemble(transcript: text, app: app,
                                                         before: before,
                                                         vocabulary: vocabulary()),
                     budget: budget)
    }

    /// The cloud tier of the ladder (`PolishTier.configuredBrain`).
    ///
    /// Takes an already-assembled prompt so every tier is asked exactly the
    /// same thing and they differ only in where they run — otherwise a
    /// difference in output between tiers could be the prompt rather than the
    /// model, and the comparison would mean nothing.
    func polish(_ text: String, prompt: PolishPrompt.Assembled,
                budget: TimeInterval, via override: BrainSelection? = nil) async -> String? {
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        // `override` is the local-server tier borrowing this transport: same
        // Hermes gateway, same session, a different provider and model. The
        // request shape is identical, so there is no second HTTP client to
        // keep in step — only a different `BrainSelection` in the body.
        let req = endpoint.chatRequest(sessionID: sessionID, sessionKey: Self.sessionKey,
                                       system: prompt.system,
                                       user: prompt.user,
                                       stream: true,
                                       brain: override ?? brain,
                                       origin: nil)   // side session: never live
        let outcome = await withTimeout(budget) { [session] in
            try await session.data(for: req)
        }
        switch outcome {
        case .timedOut:
            Log.write("dictation: polish timed out (\(Int(budget * 1000)) ms), rules used")
            return nil
        case .failed(let error):
            Log.write("dictation: polish failed (\(error.localizedDescription)), rules used")
            return nil
        case .finished(let (data, response)):
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.write("dictation: polish got HTTP \(status), rules used")
                return nil
            }
            guard let reply = Self.content(from: data) else {
                Log.write("dictation: polish reply unreadable, rules used")
                return nil
            }
            switch Self.accept(reply, input: text) {
            case .success(let polished):
                Log.write("dictation: polished in \(ms()) ms")
                return polished
            case .failure(let why):
                Log.write("dictation: polish rejected (\(why.rawValue)), rules used")
                return nil
            }
        }
    }

    // MARK: - Output guard

    enum Rejection: String, Error {
        case empty, tooLong, tooShort, meta
    }

    /// The model's reply as text to paste, or why it can't be trusted.
    ///
    /// The failure modes of a rewrite prompt are predictable: it answers the
    /// transcript instead of rewriting it, it wraps the result in quotes or a
    /// code fence, it prefaces it with "Here is", or it refuses. Length is
    /// the cheap tell for the first; the rest are looked for by name.
    static func accept(_ reply: String, input: String) -> Result<String, Rejection> {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // ```text … ``` — the fence comes off, and its language tag with it.
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6 {
            s = String(s.dropFirst(3).dropLast(3))
            if let nl = s.firstIndex(of: "\n"), !s[..<nl].contains(" ") { s = String(s[nl...]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Matching quotes the input didn't have.
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in pairs where s.count > 2 && s.first == open && s.last == close
            && !(input.hasPrefix(String(open)) && input.hasSuffix(String(close))) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A stray tag echoed back.
        s = s.replacingOccurrences(of: PolishPrompt.openTag, with: "")
             .replacingOccurrences(of: PolishPrompt.closeTag, with: "")
             .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty else { return .failure(.empty) }
        let n = Double(input.count), m = Double(s.count)
        // Short inputs get slack: "ok" → "OK." is a 50% change.
        if n >= 12 {
            if m > n * 3 { return .failure(.tooLong) }
            if m < n / 3 { return .failure(.tooShort) }
        } else if m > n + 24 {
            return .failure(.tooLong)
        }
        if Self.looksMeta(s, input: input) { return .failure(.meta) }
        return .success(s)
    }

    /// Phrases that mean the model talked instead of typing. Only counted
    /// when the speaker did not say them: "I can't make it Tuesday" is a
    /// perfectly good sentence to dictate.
    ///
    /// Compared with punctuation and case stripped on both sides: the
    /// recogniser writes "sorry im late" and the model, doing its job,
    /// "Sorry, I'm late." — the same words, and not a refusal.
    private static func looksMeta(_ s: String, input: String) -> Bool {
        func fold(_ t: String) -> String {
            let letters = t.lowercased().unicodeScalars.map { u -> Character in
                CharacterSet.letters.contains(u) || u == " " ? Character(u) : " "
            }
            return String(letters).split(separator: " ").joined(separator: " ")
        }
        let tells = [
            "as an ai", "as a language model", "i can't help", "i cannot help",
            "i can't assist", "i cannot assist", "i'm unable to", "i am unable to",
            "i'm sorry, but", "here is the", "here's the", "here is your", "here's your",
            "rewritten text", "cleaned up version", "polished version", "the transcript",
            "i'd be happy to", "certainly!", "sure, here",
        ]
        let low = fold(s)
        let inputLow = fold(input)
        for raw in tells {
            let t = fold(raw)
            if low.contains(t) && !inputLow.contains(t) { return true }
        }
        // A reply that opens as an answer to the transcript rather than a
        // version of it.
        let head = low.prefix(40)
        for t in ["i cant ", "i cannot ", "im not able", "sorry "] where head.hasPrefix(t)
            && !inputLow.hasPrefix(t) { return true }
        return false
    }

    // MARK: - Response parsing

    /// The assistant text from either shape Hermes might send: an SSE stream
    /// of deltas (what `stream: true` gets, see HermesBrain) or, should the
    /// gateway ignore the flag, one JSON completion.
    static func content(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let choice = (obj["choices"] as? [[String: Any]])?.first
            return ((choice?["message"] as? [String: Any])?["content"] as? String)
        }
        var out = ""
        var sawFinish = false
        var failed = false
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            guard line.hasPrefix("data:") else { continue }
            var v = line.dropFirst(5)
            if v.first == " " { v = v.dropFirst() }
            if v == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [String: Any],
                  let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let t = ((choice["delta"] as? [String: Any])?["content"] as? String) { out += t }
            if let reason = choice["finish_reason"] as? String {
                sawFinish = true
                // "stop" and "length" carry real text; anything else is a
                // turn Hermes could not finish and the text is not trusted.
                if reason != "stop" && reason != "length" { failed = true }
                break
            }
        }
        if failed { return nil }
        return (sawFinish || !out.isEmpty) ? out : nil
    }

    // MARK: - Timeout

    private enum Timed<T> {
        case finished(T)
        case timedOut
        case failed(Error)
    }

    /// Race `work` against the clock; whichever loses is cancelled so a slow
    /// request does not linger on the session behind the next dictation.
    private func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                          _ work: @escaping @Sendable () async throws -> T) async -> Timed<T> {
        await withTaskGroup(of: Timed<T>.self) { group in
            group.addTask {
                do { return .finished(try await work()) } catch { return .failed(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            // A request cancelled by the clock reports as a failure; the
            // clock is what should be reported.
            if case .failed(let e) = first, (e as NSError).code == NSURLErrorCancelled { return .timedOut }
            return first
        }
    }
}
