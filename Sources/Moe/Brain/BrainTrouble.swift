import Foundation

/// A brain failure a person has to *do something about*, told where they
/// asked and kept in Settings until it is fixed.
///
/// ## Why this is separate from a rate limit
///
/// A rate limit clears on its own, so Moe says "I'll answer as soon as it
/// clears" and that sentence comes true (`agent/turn_recovery.py`
/// `rate_limit_sentence`, landed 2026-09-15). A revoked key never clears. Told
/// in the same shape it is a lie, and a chat message scrolls away — so the
/// next message fails exactly the same way, with nothing on screen that says
/// why. That is the failure this file exists to stop: **a hard failure is said
/// in the chat the person wrote from AND kept in Settings › Brain until the
/// thing is actually fixed.**
///
/// ## Where the verdict comes from
///
/// Hermes already decides this. `agent/error_classifier.py` classifies every
/// API failure into a `FailoverReason` and a `retryable` boolean, and the
/// terminal paths put both into the result:
///
///     result.update({"failure_reason": classified.reason.value,
///                    "failure_retryable": bool(classified.retryable)})
///                                    — agent/turn_recovery.py, twice
///
/// **Those two fields do not reach Moe.** The OpenAI-shaped route builds the
/// `hermes` envelope by hand and carries neither:
///
///     def _hermes_extras(completed, is_partial, is_failed, err_msg, finish_reason):
///         return {"completed": …, "partial": …, "failed": …, "error": err_msg,
///                 "error_code": "output_truncated" if … else "agent_error"}
///                   — gateway/platforms/api_server_openai_routes.py:79
///
/// measured against the pinned fork (`e1dc67112a`). So `verdict(...)` takes
/// the structured fields **first** and falls back to prose only when they are
/// absent. The day the pin carries them the classification becomes exact with
/// no further change here — and `scripts/test-hard-failures.sh` proves the
/// structured path is preferred by feeding a `failure_reason` that disagrees
/// with the prose and requiring the field to win.
///
/// ## Why the prose fallback is deliberately tiny
///
/// `error_classifier.py` holds about two hundred substrings across a dozen
/// tables. Re-typing them here would be this repo's most expensive mistake —
/// *a closed loop of invented constants agrees with itself* — and would go
/// stale the first time upstream adds a provider. So the fallback carries
/// only markers Hermes itself already treats as user-facing signal, in
/// `gateway/run.py`'s `_GATEWAY_AUTH_ERROR_RE` / `_BILLING_ERROR_CODES`, each
/// one quoted with its source line, and `scripts/test-hard-failures.sh` reads
/// the pinned Hermes and fails if any of them has stopped existing there.
///
/// ## Never Claude
///
/// Not one sentence in this file names a provider. `BrainProviderKind` — the
/// enum keyed on Hermes's own provider slugs — supplies the name
/// (`shortName`), and `BrainGuide` supplies the one next thing to do
/// (`nextStep`). Somebody paying for ChatGPT is never told about Claude
/// because there is nowhere in here for the word to live.
enum BrainTrouble {

    // MARK: - What kind of trouble

    /// A failure the person must act on. One case per *action* — two errors
    /// that need the same thing done about them are one case, and an error
    /// that needs nothing done is not here at all.
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// The credential was refused: revoked, expired, or wrong.
        /// `FailoverReason.auth_permanent`.
        case credentialRejected
        /// The account cannot pay for the request. `FailoverReason.billing`.
        case outOfCredit
        /// The provider will not serve this model on this account.
        /// `FailoverReason.model_not_found`.
        case modelRefused
        /// The address Moe was told to use is not answering — a local server
        /// that is not running, or a custom endpoint that moved.
        /// `FailoverReason.ssl_cert_verification` lands here too: both are
        /// "the thing at that address cannot be talked to".
        case endpointUnreachable
    }

    /// What Moe does about a finished turn that failed.
    enum Verdict: Equatable {
        /// It will clear by itself. Say so, keep nothing.
        case temporary(String)
        /// It will not clear by itself. Say so, and keep it in Settings.
        case hard(Kind, String)
        /// About this one message, not about the account — the provider's
        /// safety filter refused this prompt. Said in chat, deliberately
        /// **not** kept in Settings: a persistent "something is wrong with
        /// your account" row for a request that was simply refused would be
        /// wrong, and would not clear, because there is nothing to fix.
        case thisRequest(String)
        /// Moe has no opinion; whatever `TurnError` already did stands.
        case unknown
    }

    // MARK: - Hermes's own verdict

    /// `FailoverReason` values that mean "the person must act". Spelled as
    /// `agent/error_classifier.py` spells them, which is what
    /// `failure_reason` carries.
    static let hardReasons: [String: Kind] = [
        "auth_permanent": .credentialRejected,
        "billing": .outOfCredit,
        "model_not_found": .modelRefused,
        // A TLS chain that will not verify is an environment fault, not a
        // blip: it fails identically on every retry, which is why Hermes
        // itself classifies it non-retryable and prints "fix the environment,
        // then try again" (`agent/turn_recovery.py`).
        "ssl_cert_verification": .endpointUnreachable,
    ]

    /// Reasons whose answer depends on **whose address it is**.
    ///
    /// Hermes calls a connection failure retryable, and for a cloud API it is
    /// — the endpoint comes back and asking again works, so the person is
    /// told to ask again. For a server on their own Mac it is not: LM Studio
    /// is not running, or the port moved, and no amount of asking again will
    /// start it. Same fault, two different next steps, and `usesBaseURL` —
    /// "Moe was given an address" — is exactly the question that separates
    /// them.
    ///
    /// This split exists because writing it the other way produced a
    /// disagreement: the prose path called "connection refused" hard while
    /// the structured path called `timeout` temporary, so the same fault
    /// would have been described one way today and the other way after a pin
    /// bump. `proseAndStructuredAgree` is the test that found it.
    static let addressReasons: [String: Kind] = [
        "timeout": .endpointUnreachable,
    ]

    /// The one reason that is about the message rather than the account.
    static let thisRequestReason = "content_policy_blocked"

    // MARK: - The prose fallback

    /// Substrings that mean the credential was refused.
    ///
    /// Every one is a literal out of the pinned Hermes, not a guess:
    /// `gateway/run.py:381` `_GATEWAY_AUTH_ERROR_RE` is
    /// `(provider\s+authentication\s+failed|incorrect\s+api\s+key|invalid\s+api\s+key|\b401\b)`,
    /// and `Sources/Moe/Brain/HermesBrain.swift` already knew the two OAuth
    /// spellings because they were the only hard failure Moe had ever
    /// handled.
    static let rejectedMarkers = [
        "provider authentication failed",   // gateway/run.py:381
        "incorrect api key",                // gateway/run.py:381
        "invalid api key",                  // gateway/run.py:381
        "oauth access token is invalid",    // was HermesBrain's Claude-only check
        "claude code credential rejected",  // was HermesBrain's Claude-only check
    ]

    /// Substrings that mean the account cannot pay. These are Hermes's
    /// *structured* billing codes (`agent/error_classifier.py`
    /// `_BILLING_ERROR_CODES`), not its prose table — a code is a thing a
    /// provider returns, so matching it is not re-typing a heuristic.
    static let outOfCreditMarkers = [
        "insufficient_quota",       // agent/error_classifier.py _BILLING_ERROR_CODES
        "insufficient_credits",     // agent/error_classifier.py _BILLING_ERROR_CODES
        "payment_required",         // agent/error_classifier.py _BILLING_ERROR_CODES
        "billing_not_active",       // agent/error_classifier.py _BILLING_ERROR_CODES
        "no_usable_credits",        // agent/error_classifier.py _BILLING_ERROR_CODES
        "balance_depleted",         // agent/error_classifier.py _BILLING_ERROR_CODES
    ]

    /// Substrings that mean nothing answered at the address.
    /// `gateway/run.py:387` `_CONNECTION_ERROR_MARKERS`, the three that are
    /// plain enough to match as substrings.
    static let unreachableMarkers = [
        "connection refused",   // gateway/run.py _CONNECTION_ERROR_MARKERS
        "could not connect",    // gateway/run.py _CONNECTION_ERROR_MARKERS
        "cannot connect",       // gateway/run.py _CONNECTION_ERROR_MARKERS
    ]

    /// Substrings that mean "wait" — matched only to keep a temporary
    /// failure from being *mistaken* for a hard one. The sentence a person
    /// reads for these is the brain's own (`rate_limit_sentence`), said mid
    /// turn; this is the fallback for a turn that gave up.
    /// `gateway/run.py:385` `_GATEWAY_RATE_LIMIT_RE`.
    static let temporaryMarkers = [
        "rate limit",       // gateway/run.py:385
        "rate-limited",     // gateway/run.py:385
        "overloaded",       // agent/error_classifier.py _OVERLOADED_PATTERNS
        "too many requests",// agent/error_classifier.py _RATE_LIMIT_PATTERNS
    ]

    // MARK: - The verdict

    /// What to do about a failed turn.
    ///
    /// - Parameters:
    ///   - reason: `hermes.failure_reason`, when the pin carries it.
    ///   - retryable: `hermes.failure_retryable`, when the pin carries it.
    ///   - message: the brain's own error text — always present.
    ///   - provider: whose account this turn was spending.
    static func verdict(reason: String?, retryable: Bool?, message: String,
                        provider: BrainProviderKind) -> Verdict {
        // Hermes's own classification wins over anything read out of prose.
        // It saw the status code, the structured error body and the provider;
        // this side has a string.
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            if reason == thisRequestReason { return .thisRequest(blockedSentence(provider)) }
            if let kind = hardReasons[reason] { return .hard(kind, sentence(kind, provider)) }
            if let kind = addressReasons[reason] { return atThatAddress(kind, provider) }
            // A reason Hermes calls retryable is temporary however it reads.
            if retryable == true { return .temporary(temporarySentence(provider)) }
            return .unknown
        }
        // No structured verdict (today's pin): the narrow prose fallback.
        let m = message.lowercased()
        // Temporary first. A 429 body can carry the word "quota", and telling
        // somebody their key is dead when it is merely busy is the worse of
        // the two mistakes — it sends them to cancel and re-issue a working
        // credential.
        // `contains { m.contains($0) }` rather than `contains(where: m.contains)`:
        // the point-free form makes the compiler choose between String's
        // Character and StringProtocol overloads with no context, and the
        // markers are Strings.
        if temporaryMarkers.contains(where: { m.contains($0) }) {
            return .temporary(temporarySentence(provider))
        }
        if rejectedMarkers.contains(where: { m.contains($0) }) {
            return .hard(.credentialRejected, sentence(.credentialRejected, provider))
        }
        if outOfCreditMarkers.contains(where: { m.contains($0) }) {
            return .hard(.outOfCredit, sentence(.outOfCredit, provider))
        }
        if unreachableMarkers.contains(where: { m.contains($0) }) {
            return atThatAddress(.endpointUnreachable, provider)
        }
        return .unknown
    }

    /// A fault at an address: hard when the address is the person's own to
    /// fix, temporary when it is a service that will come back.
    ///
    /// The single place both paths route through, so they cannot disagree
    /// about the same fault — which is what they did before this existed.
    static func atThatAddress(_ kind: Kind, _ provider: BrainProviderKind) -> Verdict {
        provider.usesBaseURL ? .hard(kind, sentence(kind, provider))
                             : .temporary(temporarySentence(provider))
    }

    // MARK: - Moe's words

    /// What the person reads in the chat they wrote from.
    ///
    /// Three things, in this order: what happened, whose it is, and the one
    /// thing to do. Never a status code, never a provider body, never the
    /// word "retry" for something that will not clear.
    static func sentence(_ kind: Kind, _ provider: BrainProviderKind) -> String {
        opening(body(kind, provider))
    }

    /// `shortName` is written for the middle of a sentence — "No OpenAI key
    /// yet" — and one of them is the lower-case "your service". Starting a
    /// sentence with it needs the capital, and doing it here means no
    /// provider needs a second name just to appear first.
    static func opening(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    private static func body(_ kind: Kind, _ provider: BrainProviderKind) -> String {
        let who = provider.shortName
        switch kind {
        case .credentialRejected:
            // **Hedged on purpose.** A 401 says the credential was refused;
            // it does not say whether it was revoked, mistyped, or never
            // there. Moe cannot tell those apart from the answer alone, and
            // only one of the three is true, so naming one would be a guess
            // presented as a fact. Hermes hedges the same way when its own
            // evidence is ambiguous — "usage/credit exhaustion (unverified —
            // the same error can be a content-filter rejection, not
            // billing)", `_billing_terminal_label`.
            //
            // The Brain pane *can* tell, because it knows whether a key is
            // stored at all, and there it says the precise thing ("No key
            // yet.") instead of this. See `BrainPane.outstanding`.
            switch provider.access {
            case .claudeSignIn, .codexSignIn:
                return "\(who) wouldn't let Alfie in — the sign-in has run out, been cancelled, "
                    + "or isn't there. Alfie can't think until you sign in again: Settings › Brain."
            case .apiKey:
                return "\(who) wouldn't let Alfie in — the key is missing, wrong, or no longer "
                    + "good. Alfie can't think until that's sorted: Settings › Brain."
            case .localServer:
                return "\(who) wouldn't let Alfie in. "
                    + "Alfie can't think until that's sorted: Settings › Brain."
            }
        case .outOfCredit:
            switch provider.access {
            case .claudeSignIn, .codexSignIn:
                return "Your \(who) plan has nothing left to spend. "
                    + "Alfie can't think on it until that changes: Settings › Brain."
            default:
                return "\(who) says the account has no credit left. "
                    + "Alfie can't think until it's topped up: Settings › Brain."
            }
        case .modelRefused:
            return "\(who) won't serve the model Alfie is set to. "
                + "Pick a different one in Settings › Brain."
        case .endpointUnreachable:
            return "Nothing answered at the address Alfie has for \(who). "
                + "Check it's running, or change it in Settings › Brain."
        }
    }

    /// The Settings row's first half: what is wrong, in one clause.
    ///
    /// Deliberately not the whole row. The Brain pane composes every
    /// outstanding thing as `what + " " + BrainGuide.nextStep` — "Not signed
    /// in yet." + "Click Sign in with Claude. …" — and a row that carried its
    /// own advice would say the next step twice, in two sets of words that
    /// could drift. So the "what to do" half stays where it already lives.
    static func whatIsWrong(_ kind: Kind, _ provider: BrainProviderKind) -> String {
        let who = provider.shortName
        switch kind {
        case .credentialRejected:
            // Shown only when a credential IS stored — the pane prefers its
            // own "No key yet." when there is none, because that is the more
            // precise truth and it already carries the right next step.
            return opening(provider.access == .apiKey
                ? "\(who) turned down the key."
                : "\(who) turned down the sign-in.")
        case .outOfCredit:         return opening("\(who) says there's no credit left.")
        case .modelRefused:        return opening("\(who) won't serve the model Alfie is set to.")
        case .endpointUnreachable: return "Nothing is answering at the address Alfie has for \(who)."
        }
    }

    /// The whole row, for a caller that is not the Brain pane.
    static func settingsRow(_ kind: Kind, _ provider: BrainProviderKind) -> String {
        whatIsWrong(kind, provider) + " " + BrainGuide.find(provider).nextStep
    }

    /// A turn that gave up on something that *will* clear. The mid-turn
    /// sentence is the brain's (`rate_limit_sentence`); this is what a
    /// person reads when the retries ran out before it cleared.
    static func temporarySentence(_ provider: BrainProviderKind) -> String {
        opening("\(provider.shortName) is busy right now and kept saying so. "
                + "Ask me again in a few minutes.")
    }

    /// The provider's safety filter refused this prompt. About the message,
    /// not the account — so no Settings row, and nothing to fix.
    static func blockedSentence(_ provider: BrainProviderKind) -> String {
        opening("\(provider.shortName) wouldn't answer that one. Try asking it a different way.")
    }

    // MARK: - The thing that persists

    /// What is kept on disk between launches, so the Settings row survives a
    /// restart — and so the *next* message does not simply fail again with
    /// nothing on screen saying why.
    /// Three fields, and deliberately not a fourth. **The provider's own
    /// message is not kept** — it is the thing most likely to carry a
    /// credential, a request id or an account number, and none of it is
    /// needed: the kind says what to do and the provider says whose. The raw
    /// line goes to `~/.moe/logs/moe.log`, redacted, where a developer looks.
    struct Record: Codable, Equatable {
        var kind: Kind
        /// Hermes's provider slug (`BrainProviderKind.rawValue`). Stored
        /// rather than the display name so a row written on one provider is
        /// never shown against another.
        var provider: String
        var at: Date
    }

    /// Posted whenever the record is written or cleared, so a Settings pane
    /// already open changes under the person's eyes. Without it the row is
    /// correct only on the next visit — and the most likely moment somebody
    /// is looking at Settings › Brain is the moment they are fixing this.
    static let changed = Notification.Name("moe.brainTrouble")

    /// `~/Library/Application Support/Moe/hermes/brain-trouble.json`.
    ///
    /// Beside `claude-signin-rejected`, which this generalises: that marker
    /// is one provider's, one error's, and boolean. A file in the same place
    /// keeps the two discoverable together and keeps `MacErase` honest.
    static var storeURL: URL { Paths.home.appendingPathComponent("hermes/brain-trouble.json") }

    /// Keep it. Rewriting the same kind for the same provider only moves the
    /// timestamp, so a row does not flicker while somebody retries.
    static func record(_ kind: Kind, provider: BrainProviderKind, at url: URL? = nil) {
        let url = url ?? storeURL
        let rec = Record(kind: kind, provider: provider.rawValue, at: Date())
        guard let data = try? JSONEncoder().encode(rec) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        announce()
    }

    /// What is wrong right now for `provider`, or nil.
    ///
    /// A record written against another provider answers nil rather than
    /// being shown: changing account is one of the ways a person fixes this,
    /// and a stale row would tell them their new key was refused.
    static func current(for provider: BrainProviderKind, at url: URL? = nil) -> Record? {
        let url = url ?? storeURL
        guard let data = try? Data(contentsOf: url),
              let rec = try? JSONDecoder().decode(Record.self, from: data),
              rec.provider == provider.rawValue else { return nil }
        return rec
    }

    /// Fixed. Called on every turn that finishes without an error, so the row
    /// clears the moment the thing works again — no restart, no "check for
    /// updates", no second place to press.
    static func clear(at url: URL? = nil) {
        let url = url ?? storeURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        announce()
    }

    /// Tell an open Settings window. Main-thread, because a SwiftUI view is
    /// what listens and `finishTurn` runs off it.
    private static func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    // MARK: - Nothing credential-shaped ever reaches the screen

    /// A provider's 401 body quotes the key back — OpenAI's says
    /// `Incorrect API key provided: sk-proj-AbC***XyZ`. Moe's own route is
    /// `api_server`, which is in Hermes's `_GATEWAY_RAW_TEXT_PLATFORMS`
    /// (`gateway/run.py:358`), so `_redact_gateway_user_facing_secrets` never
    /// runs on the way here and that body arrives verbatim.
    ///
    /// Same patterns Hermes redacts with (`_GATEWAY_SECRET_PATTERNS`,
    /// `gateway/run.py:395`). Kept even though every sentence above is
    /// written from scratch: `TurnError.personWords` passes an unmatched
    /// message through unchanged, and that is the path a new provider's
    /// wording takes.
    static let secretPatterns = [
        "sk-[A-Za-z0-9][A-Za-z0-9_\\-]{12,}",
        "gh[pousr]_[A-Za-z0-9_]{20,}",
        "xox[baprs]-[A-Za-z0-9\\-]{20,}",
        "xapp-[0-9]+-[A-Za-z0-9\\-]{20,}",
        "hf_[A-Za-z0-9]{20,}",
        "glpat-[A-Za-z0-9_\\-]{20,}",
        "(?i)Bearer\\s+[A-Za-z0-9._\\-]{20,}",
    ]

    /// `message` with anything credential-shaped replaced. Never logs what it
    /// found — a redaction that reports its input is not a redaction.
    static func redacted(_ message: String) -> String {
        var out = message
        for p in secretPatterns {
            while let r = out.range(of: p, options: .regularExpression) {
                out.replaceSubrange(r, with: "[removed]")
            }
        }
        return out
    }
}
