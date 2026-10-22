import Foundation

// The two free-text fields of the Away brain sheet, and the command they build
// — CLOUD-PLAN §18.30 S3, S4, S5.
//
// **Why this is a module and not three private functions in the sheet.** It
// used to be private functions in `Sources/Moe/Settings/AwayBrainSheet.swift`,
// and a hostile pass measured what that cost: `Moe` has no test target, so
// `grep -rln "AwayBrain" Tests` found nothing, and three deliberate mutants —
// including `args += ["--secret", secret]`, which puts the credential on a
// command line every local user can read with `ps` — survived all 1905 Swift
// tests. A rule that cannot go red is a decoration, and this one is the only
// half of the pair that runs *before* the value reaches argv: `moeledger.brain`
// refuses the same things on the far side, but by then it has been in the
// process table.
//
// So the parts that can be tested live here, in a module `MoeLedgerTests`
// already depends on, and `Sources/Moe` keeps only the `Process` plumbing that
// genuinely needs a subprocess. The Python and the Swift are pinned to the same
// numbers by `moe-ledger/tests/test_brain.py`, which reads this file.

/// Whether a free-text field holds something shaped like a credential.
///
/// Both fields sit one line from the SecureField — Base URL above it, Model
/// below — and the slip that puts a key in one of them is ordinary. What
/// follows the slip is not: the value goes on **argv**, into the sealed
/// document on every device of the tenant, into `config.yaml` in cleartext, into
/// the machine's log, and into the pane's own headline.
public enum AwayBrainField {

    /// No real model id is close to this. The longest in a 28-id survey across
    /// six vendors is `accounts/fireworks/models/qwen2p5-72b-instruct`, at 46.
    public static let modelMaxLength = 64

    /// **The measurement that replaced a prefix list, twice.**
    ///
    /// A length bound alone answered eight named formats and let seven more
    /// through — Groq (52), Perplexity (49), Cerebras (44), Fireworks (35),
    /// Mistral (32), Cohere (40), Together (64 exactly). Adding those seven
    /// prefixes would have been the same mistake a third time.
    ///
    /// What separates the two grammars is structure. A model id is vendor,
    /// family, size and date, all separated: over 28 real ids the longest
    /// unbroken run of letters and digits is **10**. A credential has to carry
    /// entropy, so it is opaque: over 15 vendor formats the shortest such run
    /// is **32**. Twenty sits between them with a factor of two either way, and
    /// no new vendor can walk past it — a key short enough to pass would be too
    /// short to be a key.
    public static let modelMaxRun = 20

    /// Generous: the longest real endpoint in Hermes's registry is under 60.
    public static let baseURLMaxLength = 200

    /// The longest unbroken run of letters and digits.
    ///
    /// `moeledger.brain.longest_alnum_run` is the same function on the far
    /// side, and `test_brain.py` requires the two constants above to equal
    /// `MODEL_RUN_MAX` and `MODEL_MAX` by reading this file.
    public static func longestAlnumRun(_ text: String) -> Int {
        var best = 0, run = 0
        for ch in text.unicodeScalars {
            let isAlnum = (ch.value >= 48 && ch.value <= 57)
                || (ch.value >= 65 && ch.value <= 90)
                || (ch.value >= 97 && ch.value <= 122)
            run = isAlnum ? run + 1 : 0
            if run > best { best = run }
        }
        return best
    }

    /// Vendor prefixes that announce a credential, kept only for the cases the
    /// run rule cannot see — a `Bearer …` or a JWT, whose structure breaks the
    /// runs up. Knowingly incomplete, and no longer load-bearing: the run rule
    /// is what catches an unknown vendor.
    private static let announcedPrefixes = [
        "sk-", "sk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "github_pat_", "glpat-", "xox", "aiza", "ya29.", "npm_",
        "hf_", "ak_", "xai-", "bearer ", "basic ", "eyj", "gsk_", "pplx-",
        "csk-", "fw_", "dop_v1_", "shpat_", "shpss_",
    ]

    private static func announced(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return announcedPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Why `model` is not a model id, in the words the sheet shows — or nil.
    public static func modelProblem(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name a model." }
        if trimmed.count > modelMaxLength || longestAlnumRun(trimmed) > modelMaxRun
            || announced(trimmed) {
            return "That looks like a key, not a model name. Keys go in the field above — "
                + "this one is the model, like \"claude-sonnet-5\"."
        }
        // The character class the far side spells as `MODEL_RE`. Anything
        // outside it reaches a YAML file and a log line as itself.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/+-")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "A model name is letters, digits and . _ : / + - only."
        }
        return nil
    }

    /// Why `baseURL` is not an endpoint, or nil. Empty is fine — most
    /// providers have none, and absence is the honest state.
    ///
    /// A **grammar** rather than a shape list, and complete in a way no shape
    /// list can be: a pasted secret does not parse as an absolute http(s) URL.
    /// The one credential that is genuinely URL-shaped — `https://u:p@host` —
    /// is refused by name, because userinfo would be stored and logged with the
    /// address every time.
    public static func baseURLProblem(_ baseURL: String) -> String? {
        if baseURL.isEmpty { return nil }
        if baseURL.count > baseURLMaxLength {
            return "That address is too long to be an endpoint."
        }
        if baseURL != baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || baseURL.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return "That address has spaces in it."
        }
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else {
            return "That is not an address. It starts with https:// — a key goes in the "
                + "field below it."
        }
        if url.user != nil || url.password != nil {
            return "Take the sign-in out of the address — it would be stored in the clear."
        }
        if announced(baseURL) { return "That looks like a key, not an address." }
        return nil
    }
}

/// What `moe-brain-away.py` is actually run with.
///
/// A value type with no `Process` in it, so a test can read the argument list
/// and the standard input separately and require of them the one property that
/// matters: **the secret is never an argument.**
public struct AwayBrainCommand: Equatable, Sendable {
    /// argv after the script path. Read by `ps` on this Mac, so nothing here
    /// may be a credential.
    public let arguments: [String]
    /// What is written to the child's stdin, and the only route a secret takes.
    public let standardInput: String?

    public init(arguments: [String], standardInput: String?) {
        self.arguments = arguments
        self.standardInput = standardInput
    }

    /// The publish command. `kindArgument` is `api-key`, `setup-token` or
    /// `codex`; Codex carries no secret at all, because what travels is the
    /// file the machine already has.
    public static func publish(kindArgument: String, provider: String, model: String,
                               baseURL: String, secret: String) -> AwayBrainCommand {
        var args = ["--kind", kindArgument, "--model", model]
        if !provider.isEmpty { args += ["--provider", provider] }
        if carriesBaseURL(kindArgument), !baseURL.isEmpty { args += ["--base-url", baseURL] }
        return AwayBrainCommand(arguments: args,
                                standardInput: kindArgument == "codex" ? nil : secret)
    }

    /// **A field the sheet does not show must not be sent.** The Base URL row
    /// appears only under "A key you pay for", but the sheet holds it in one
    /// `@State` for the whole sheet and never cleared it on a change of kind.
    /// So: pick that row, choose a provider with an endpoint, type one, switch
    /// to "Your Claude plan", press the button — and a value the person can no
    /// longer see travelled with the token. `moeledger.brain` refuses it
    /// (`'anthropic' takes no base_url`; `BASE_URL_PROVIDERS` is `custom`,
    /// `lmstudio`, `moe-custom` and nothing else, so no setup-token or codex
    /// provider can ever take one) — but only **after** the browser round trip
    /// and **after** Anthropic has minted a real year-long token, which is the
    /// most expensive moment in the flow to discover a stale field.
    ///
    /// Dropped rather than refused: refusing would name a field that is not on
    /// screen. It lives here, not in the sheet, because `Moe` has no test
    /// target — the whole reason this file exists.
    public static func carriesBaseURL(_ kindArgument: String) -> Bool {
        kindArgument == "api-key"
    }

    /// Re-seal the brain that is already published under a new model.
    ///
    /// **`standardInput` is nil and that is the property worth testing.** This
    /// is the one command that carries a credential without ever being handed
    /// one: the job opens the published document in its own process and seals
    /// it again. Nothing about the secret crosses this boundary in either
    /// direction — not on argv, where `ps` would have it, and not on stdin,
    /// where the pane would have had to hold it.
    ///
    /// `assertProvider` is an assertion that the provider has **not** changed,
    /// never an instruction to change it: `moe-brain-away.py --retune` refuses
    /// when it does not match what is published, because a DeepSeek key
    /// relabelled `anthropic` publishes cleanly, applies cleanly and 401s on
    /// every turn. It is nil where the two halves legitimately spell one
    /// account differently — a Claude plan is `claude-code-cli` on this Mac
    /// and `anthropic` in the document.
    public static func retune(model: String, baseURL: String,
                              assertProvider: String?) -> AwayBrainCommand {
        var args = ["--retune", "--model", model]
        if let assertProvider, !assertProvider.isEmpty {
            args += ["--provider", assertProvider]
        }
        if !baseURL.isEmpty { args += ["--base-url", baseURL] }
        return AwayBrainCommand(arguments: args, standardInput: nil)
    }

    public static let show = AwayBrainCommand(arguments: ["--show"], standardInput: nil)
    public static let revoke = AwayBrainCommand(arguments: ["--revoke"], standardInput: nil)
}

/// What the Brain pane says about the away machine after a change here.
///
/// nil is a real answer and the common one: a person with no away machine must
/// not meet a word of this on a pane about their own Mac.
public struct AwayBrainFollowNote: Equatable, Sendable {
    public let sentence: String
    /// Something the person has to do, rather than news. The pane colours it.
    public let needsYou: Bool
    /// The button's title, or nil when there is nothing to press.
    public let action: String?

    public init(sentence: String, needsYou: Bool, action: String?) {
        self.sentence = sentence
        self.needsYou = needsYou
        self.action = action
    }
}

/// The Away brain sheet's "Your Claude plan" description.
///
/// It is here rather than in `AwayBrainKind.explanation` for the reason the
/// rest of this file is here — `Moe` has no test target — and because this
/// particular sentence has been wrong twice in two different ways:
///
///  * it told the person to run `claude setup-token` in a terminal for as long
///    as the row existed, while the app had shipped the same flow with a button
///    (`Sources/Moe/Onboarding/ClaudeSignIn.swift`) for the Brain pane;
///  * and when the button was added, the description stayed **static per
///    kind** — so on a Mac with no Claude Code the person read "Press Sign in
///    with Claude" and, directly underneath, "Claude Code isn't on this Mac".
///    Two sentences contradicting each other on one screen, with the only line
///    that had ever said how to *get* a token deleted between them.
///
/// So there is one entry point and it takes the fact that decides the wording.
public enum AwayBrainCopy {

    /// `available` is "there is a `claude` on this Mac to drive".
    ///
    /// The unavailable branch names the command on purpose. That is not the
    /// defect the first bullet describes: telling somebody to do by hand a
    /// thing the button has already done is the defect, and when there is no
    /// button, the command is the only true answer left. It says "wherever you
    /// have Claude Code" rather than "on this Mac", because by hypothesis this
    /// Mac is not where it is.
    public static func setupTokenExplanation(signInAvailable available: Bool) -> String {
        if available {
            return "Press Sign in with Claude. Alfie opens claude.ai in your browser, you "
                + "approve, and your machine gets a token of its own: a year long, model "
                + "requests only, Anthropic's own path for servers. Alfie seals it here and "
                + "never keeps a copy, so it is not the token this Mac thinks with. "
                + "Already have one? Paste it instead."
        }
        return "Claude Code isn't on this Mac, so there is no sign-in here to run. On a "
            + "computer that has it, `claude setup-token` prints a token that lasts a year "
            + "and can only make model requests; paste that below. Alfie seals it here and "
            + "never keeps a copy."
    }

    /// Whether the two sentences can contradict each other. A test can assert
    /// this without a screen: the available wording must name the button and
    /// not the command, and the unavailable wording the reverse.
    public static func namesTheButton(_ text: String) -> Bool {
        text.contains("Sign in with Claude")
    }

    public static func namesTheCommand(_ text: String) -> Bool {
        text.contains("claude setup-token")
    }

    // MARK: - Keeping the away machine in step (CLOUD-PLAN §18.30)

    /// The word for what the person's away machine is called, used often
    /// enough that a second spelling would read as a second thing.
    public static let machine = "away machine"

    /// What the Brain pane says **before** anything is sent — the note that
    /// belongs on screen at the moment of the change.
    ///
    /// `stillOn` is a short phrase for what the machine has today ("your
    /// Anthropic key", "your Claude plan"), or "" when the pane cannot put one
    /// together. The sentence reads without it; it is not padded in.
    ///
    /// **Three rules this wording keeps.**
    ///
    ///  * It never says the machine *has* the change. A published document
    ///    reaches the machine on its next sync, which may be minutes and may
    ///    be the next time it wakes, and a pane that says "done" while a
    ///    machine is still on last week's model is the fourteen-hour failure
    ///    of 2026-09-14 said one surface further out.
    ///  * It never names a kind, a document, a key id or a provider id.
    ///    "setup_token" is a fact about this repository.
    ///  * Where the person has to do something, the sentence says what, and
    ///    the note carries the button that does it — not a pointer to another
    ///    pane, which is where this whole area lost the owner in the first
    ///    place.
    public static func followNote(_ step: AwayBrainFollow.Step,
                                  stillOn: String = "") -> AwayBrainFollowNote? {
        let still = stillOn.isEmpty ? "what you gave it before" : stillOn
        switch step {
        case .noMachine, .cannotTell, .upToDate, .apart:
            return nil
        case .retune, .sendKey, .sendCodex, .sendClaudeToken:
            return AwayBrainFollowNote(
                sentence: "Sending this to your \(machine) too…",
                needsYou: false, action: nil)
        case .needsItsOwnToken:
            return AwayBrainFollowNote(
                sentence: "Your \(machine) can't share this Mac's Claude sign-in — Claude "
                    + "hands out one sign-in per computer, so your machine needs its own. "
                    + "Until you give it one it keeps thinking with \(still).",
                needsYou: true, action: "Sign your machine in too…")
        case .needsItsOwnKey(let provider):
            let named = provider.isEmpty ? "that" : shortProviderName(provider)
            return AwayBrainFollowNote(
                sentence: "Your \(machine) doesn't have your \(named) key — Alfie won't send a "
                    + "key off this Mac that you didn't just type. Give it the same key and "
                    + "it thinks with the same thing you do; until then it keeps thinking "
                    + "with \(still).",
                needsYou: true, action: "Give your machine this too…")
        case .localOnly:
            return AwayBrainFollowNote(
                sentence: "This model runs on this Mac, so your \(machine) can't reach it. "
                    + "It keeps thinking with \(still).",
                needsYou: false, action: "Change what your machine uses…")
        }
    }

    /// What the pane says once the send has actually gone. Only ever reached
    /// from a step `AwayBrainFollow.travels` said yes to.
    ///
    /// **"Next time it syncs", not "it has it".** This is what is true: the
    /// document is on the ledger and the machine picks it up when it next
    /// reaches it. `moeledger.brain._apply_body` then has it in force from that
    /// moment — it writes `.env` *and* the running process's own environment —
    /// so there is no restart to wait for and the pane does not promise one.
    public static func followed() -> AwayBrainFollowNote {
        AwayBrainFollowNote(
            sentence: "Your \(machine) is getting this too — it picks it up the next time "
                + "it syncs, and uses it from then on.",
            needsYou: false, action: nil)
    }

    /// When the send was refused. `why` is the job's own last line, already
    /// stripped of its log prefix by `AwayBrainSetup.run`.
    public static func followFailed(_ why: String) -> AwayBrainFollowNote {
        let trimmed = why.trimmingCharacters(in: .whitespacesAndNewlines)
        return AwayBrainFollowNote(
            sentence: trimmed.isEmpty
                ? "Alfie couldn't send this to your \(machine). It keeps what it had."
                : trimmed,
            needsYou: true, action: "Change what your machine uses…")
    }

    /// A provider id in the words a person uses. Deliberately small: the Brain
    /// pane has `BrainProviderKind.shortName` and this is the same answer for
    /// the handful of ids that can reach `needsItsOwnKey`, kept here because
    /// `Moe` has no test target and this sentence is one a test must be able
    /// to read.
    public static func shortProviderName(_ provider: String) -> String {
        switch provider {
        case "anthropic":  return "Anthropic"
        case "openai-api": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "gemini":     return "Google Gemini"
        case "deepseek":   return "DeepSeek"
        case "xai":        return "xAI"
        case "moe-custom": return "own"
        default:           return provider
        }
    }
}
