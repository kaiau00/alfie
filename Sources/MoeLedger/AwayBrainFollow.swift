import Foundation

// Keeping the away machine's brain in step with this Mac's — CLOUD-PLAN §18.30.
//
// **The two halves of "what Moe thinks with" were only ever joined by a person
// remembering.** Settings › Brain writes `~/.hermes` on this Mac through
// `configure-hermes.py`; Settings › Away seals a `brain` document for the
// machine through `moe-brain-away.py`. Nothing connected them. So on
// 2026-09-16 the owner changed his brain here, looked at his away machine, and
// found it thinking with what he had given it weeks before — no error, no
// note, nothing on either pane that said the two could disagree.
//
// There were two failures in that and only one of them is "it didn't copy":
//
//  1. the change did not travel **where it could have** — for a key the person
//     had just typed, for a ChatGPT plan whose `auth.json` is sitting on this
//     Mac, and for the ordinary case of picking a different model on the
//     credential the machine already holds, nothing at all was needed from
//     anybody;
//  2. and where it genuinely **could not** travel — a Claude plan, whose token
//     is minted per machine and cannot be copied — the pane said nothing at
//     the moment it mattered, which is the moment of the change.
//
// This is the fold that decides between those, and it lives in `MoeLedger`
// rather than in the pane for the reason the rest of this file's neighbours
// do: **`Moe` has no test target.** `AwayBrainFields.swift`'s own header
// records what that cost — three deliberate mutants, one of them putting a
// credential on argv, surviving 1905 Swift tests. A rule about when a
// credential travels is not a rule to leave somewhere a mutant survives.
//
// **The owner's decision, 2026-09-25 — this paragraph and the one after it
// are superseded.** Asked "when you change the brain on your Mac, how should
// the cloud machine follow?", he chose *"follow unless I set it apart"*: the
// machine thinks with exactly what this Mac thinks with — the same Claude
// sign-in, the same ChatGPT sign-in, the same API key — and changing or
// signing in again here carries over by itself, unless he deliberately gave
// the machine a brain of its own in Settings › Away (`Here.apart`). What made
// him ask: he signed in to a new Claude plan here after the old one ran out,
// and the machine went on answering with the exhausted one — the fold saw the
// same provider and the same model and called it `upToDate`, because it never
// looked at the account.
//
// So the fold now also takes whether this Mac HAS the credential and whether
// it differs from the one last sent (`credentialAvailable`,
// `credentialChanged` — computed by the app from a fingerprint, never the
// value), and sends it. What it still never does: publish over a brain the
// person removed (`none`/`revoked` stay `noMachine`), touch a machine that is
// set apart, or send a model that only exists on this Mac.
//
// (Superseded.) It never reaches for a credential the
// person did not hand over in the act of changing their brain. `~/.hermes/.env`
// holds this Mac's API key in the clear and reading it would make every
// provider change travel — and it would turn a local-only credential into a
// travelling one without the person ever choosing that, which is the argument
// `AwayBrain.swift` makes against lifting the `moe-child-oauth` keychain item
// and is not weaker for being about a different store. So a provider change
// with no key typed is reported, not performed.

/// What should happen to the away machine's brain when this Mac's changes.
public enum AwayBrainFollow {

    /// What is published for the machine today, as the fold needs to see it.
    /// A straight mirror of `moe-brain-away.py --show`, with the secret absent
    /// there and therefore absent here.
    public struct Published: Equatable, Sendable {
        /// `none`, `set`, `revoked`, `sealed`, `unreadable`, `could-not-ask`.
        public let state: String
        /// `api_key`, `setup_token`, `codex_auth` — `moeledger.brain.KINDS`.
        public let kind: String
        public let provider: String
        public let model: String
        /// The endpoint the machine was given, for the three providers that
        /// take one. Part of `upToDate`'s question and not decoration: a
        /// person who changes only the address of their "Anywhere else"
        /// service changes nothing the model comparison can see, and a
        /// machine left on the old address answers nothing.
        public let baseURL: String

        public init(state: String, kind: String = "", provider: String = "",
                    model: String = "", baseURL: String = "") {
            self.state = state
            self.kind = kind
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
        }
    }

    /// This Mac's new brain, in the three facts that decide the answer.
    public struct Here: Equatable, Sendable {
        /// Hermes's provider id — `BrainProviderKind.rawValue`.
        public let provider: String
        public let model: String
        public let baseURL: String
        /// Whether the person typed a key **in this change**.
        public let keyInHand: Bool
        /// This Mac holds the credential for its brain — the Claude sign-in in
        /// the keychain, or the provider's key in Hermes's `.env` — so it can
        /// be sent without anybody typing it again.
        public let credentialAvailable: Bool
        /// That credential is not the one this Mac last sent the machine (or
        /// nothing was ever recorded as sent). A fingerprint comparison, made
        /// by the app; the value never reaches this fold.
        public let credentialChanged: Bool
        /// The person gave the machine a brain of its own in Settings › Away.
        /// Nothing here overwrites it until they choose "the same as my Mac".
        public let apart: Bool

        public init(provider: String, model: String, baseURL: String, keyInHand: Bool,
                    credentialAvailable: Bool = false, credentialChanged: Bool = false,
                    apart: Bool = false) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
            self.keyInHand = keyInHand
            self.credentialAvailable = credentialAvailable
            self.credentialChanged = credentialChanged
            self.apart = apart
        }
    }

    public enum Step: Equatable, Sendable {
        /// Nothing is published for a machine, so there is nothing to keep in
        /// step. The pane says nothing: somebody with no Away plan must not
        /// meet a word of this.
        case noMachine
        /// We could not find out what the machine has. **The pane still says
        /// nothing**, and that is a deliberate, narrow exception to *"a
        /// failure to ask is not an answer"*: the Brain pane is not reporting
        /// on the away machine, it is keeping it in step, and silence asserts
        /// nothing. Settings › Away is where a failure to ask is reported, and
        /// it already says so (`AwayBrainStatus.headline`, `could-not-ask`).
        case cannotTell
        /// The machine already has exactly this. Nothing to do and nothing to
        /// say.
        case upToDate
        /// Re-seal what the machine already holds under a new model. No
        /// credential is asked for, read, or moved.
        /// `assertProvider` is passed to `--retune` as an assertion that the
        /// provider has **not** changed; nil where the two halves legitimately
        /// spell it differently (a Claude plan is `claude-code-cli` here and
        /// `anthropic` there).
        case retune(model: String, baseURL: String, assertProvider: String?)
        /// Publish a whole new document with the key — the one the person just
        /// typed, else this Mac's own.
        case sendKey(provider: String, model: String, baseURL: String)
        /// Publish this Mac's own Claude sign-in for the machine, under the
        /// machine's name for the model. The follow the owner asked for on
        /// 2026-09-25: a new Claude account here is the machine's too.
        case sendClaudeToken(model: String)
        /// The machine has a brain of its own, by the person's choice. Say
        /// nothing and send nothing.
        case apart
        /// Publish a copy of `~/.codex/auth.json`. Needs nothing typed — the
        /// file is on this Mac — so a ChatGPT plan follows by itself, and it
        /// follows a change of ChatGPT *account* too, which re-sealing the old
        /// copy under a new model would not.
        case sendCodex(model: String)
        /// A Claude plan. The machine needs a `claude setup-token` of its own
        /// and there is no act on this Mac that can produce one for it.
        case needsItsOwnToken
        /// A different key-paid provider, with no key typed in this change.
        case needsItsOwnKey(provider: String)
        /// A model that only exists on this Mac. `127.0.0.1` on the machine is
        /// the machine's own empty loopback, and `moeledger.brain` would seal
        /// and apply it without a murmur — `BASE_URL_PROVIDERS` is a list of
        /// three provider ids and has no opinion about hosts.
        case localOnly
    }

    // MARK: - Provider vocabulary

    /// Providers whose model runs on the machine you are sitting at.
    /// `BrainProviderKind.lmStudio` and `.local`, by their Hermes ids.
    public static let localProviders: Set<String> = ["lmstudio", "custom"]
    /// The Claude-plan provider — a token minted per machine, never copied.
    public static let claudePlanProvider = "claude-code-cli"
    /// The ChatGPT-plan provider, on both sides (`moeledger.brain.CODEX_PROVIDERS`).
    public static let codexProvider = "openai-codex"

    // MARK: - Which Claude the machine thinks with

    /// The model a machine on a Claude plan thinks with when nothing else
    /// says: the current Sonnet, by its full API name.
    ///
    /// It was `claude-sonnet-4-6`, typed in four places on the Mac — measured
    /// on the owner's machine on 2026-09-22, `/opt/data/moe/brain.json` said
    /// `claude-sonnet-4-6` while his Mac thought with Claude Code's `sonnet`,
    /// which is Sonnet 5. Sonnet rather than Opus for `docs/DEFAULTS.md` row
    /// 2's reason: a new person should not burn their plan on day one.
    public static let defaultClaudeModel = "claude-sonnet-5"

    /// Claude Code's aliases, as the full names the machine needs.
    ///
    /// **The machine is not Claude Code.** Its brain is Hermes's `anthropic`
    /// provider carrying `CLAUDE_CODE_OAUTH_TOKEN` (`moeledger.brain`,
    /// `SETUP_TOKEN_PROVIDERS`), which sends `model.default` to the Messages
    /// API as written — and the Messages API has no model called `sonnet`. So
    /// the Mac's tier word is translated here, once, rather than published
    /// raw for the machine to fail on.
    public static let claudeAliases: [String: String] = [
        "sonnet": "claude-sonnet-5",
        "opus": "claude-opus-5-5",
        "haiku": "claude-haiku-4-5-20251001",
        "fable": "claude-fable-5",
    ]

    /// What the machine should think with, given the model this Mac's Claude
    /// plan is set to. An alias (with or without Claude Code's `[1m]` context
    /// suffix) becomes its full name; a full name is kept as the person chose
    /// it; nothing at all is `defaultClaudeModel`.
    public static func machineModel(forClaudePlan model: String) -> String {
        var m = model.trimmingCharacters(in: .whitespaces)
        if let bracket = m.firstIndex(of: "[") { m = String(m[..<bracket]) }
        if m.isEmpty { return defaultClaudeModel }
        return claudeAliases[m.lowercased()] ?? m
    }

    /// The model to give a machine that is about to sign in with a Claude
    /// plan: this Mac's own tier when this Mac is on a Claude plan, else the
    /// default. A Mac on ChatGPT or an API key says nothing about which
    /// Claude the machine should use, so it is not read as if it did.
    public static func machineModel(macProvider: String, macModel: String) -> String {
        macProvider == claudePlanProvider ? machineModel(forClaudePlan: macModel) : defaultClaudeModel
    }

    public static let kindAPIKey = "api_key"
    public static let kindSetupToken = "setup_token"
    public static let kindCodexAuth = "codex_auth"

    /// Providers whose endpoint is `model.base_url` — `moeledger.brain`'s
    /// `BASE_URL_PROVIDERS`, and `configure-hermes.py`'s list of the same name.
    ///
    /// **A field the pane does not show must not be sent**, and this one is
    /// held in a slot shared by every provider. `BrainPane.apply` passes
    /// `config.brainExtras["baseURL"] ?? provider.defaultBaseURL`, which is one
    /// value for the whole pane; a provider that takes no address would carry
    /// whatever is in it into the retune, where `check_body` refuses the entire
    /// document — *"'deepseek' takes no base_url"* — and the person is told
    /// their machine could not be brought up to date because of a field they
    /// cannot see and did not set.
    ///
    /// **What is measured and what is defence, because the difference matters
    /// and the first version of this comment got it wrong.** It claimed the
    /// slot is never cleared on a provider change. It is:
    /// `BrainAccountSheet.apply` computes `url` as `""` for a provider with no
    /// address, and `Conductor.applyBrain` writes `extras["baseURL"] = nil` for
    /// an empty one — so switching provider through the sheet does clear it.
    /// **No writer was found that creates the mismatch.** Every reader of the
    /// slot round-trips it (`BrainPane.apply`, `choose(polish:)`,
    /// `ConnectionsView`) and none of them can change the provider; the account
    /// sheet is the only road that can, and it clears. A config written by an
    /// older build, or edited by hand, is the remaining way in, and neither was
    /// measured.
    ///
    /// That is said plainly so the next person can decide: this is a defence
    /// against nothing currently reachable, and somebody who establishes that
    /// an old config cannot carry it either may remove it knowingly, rather
    /// than finding a rule with no reason attached and guessing.
    ///
    /// So this is a defence, and it is kept for two reasons that stand without
    /// that claim. It is the same rule `AwayBrainCommand.carriesBaseURL`
    /// already enforces one road over — there against the away sheet's
    /// sheet-wide `@State`, where the slip **was** measured — and a rule that
    /// holds on one road and not the other is the drift this area keeps paying
    /// for. And it is what makes the `localOnly` test a test of the *model's*
    /// address rather than of whatever shares its slot.
    ///
    /// Dropped rather than refused, for `carriesBaseURL`'s own reason:
    /// refusing would name a field that is not on screen.
    public static let baseURLProviders: Set<String> = ["custom", "lmstudio", "moe-custom"]

    public static func carriesBaseURL(_ provider: String) -> Bool {
        baseURLProviders.contains(provider)
    }

    /// Whether `baseURL` names somewhere only this Mac can reach.
    ///
    /// **A grammar over the host, not a list of provider ids.** `moe-custom`
    /// is a key-paid provider that takes an address, and pointing it at
    /// `http://127.0.0.1:8080/v1` is an ordinary thing to do — it is the row
    /// called "Anywhere else". Sealing that for a machine in Virginia publishes
    /// a brain that applies cleanly and cannot answer, which is the worst of
    /// the three outcomes: it looks like it worked. Matching on what the
    /// address *is* catches it however the provider is spelled, which is
    /// CLAUDE.md's rule about guards that enumerate names.
    public static func isLocalAddress(_ baseURL: String) -> Bool {
        guard !baseURL.isEmpty, let host = URL(string: baseURL)?.host?.lowercased(),
              !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "[::1]" { return true }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        if a == 127 { return true }                       // loopback
        if a == 10 { return true }                        // private
        if a == 192 && b == 168 { return true }           // private
        if a == 172 && (16...31).contains(b) { return true }
        if a == 169 && b == 254 { return true }           // link-local
        return false
    }

    // MARK: - The fold

    /// What to do about the away machine, given this Mac's new brain.
    ///
    /// Written out case by case with no `default` that folds an answer we do
    /// not recognise into an action. An unknown published state is
    /// `cannotTell`, never `noMachine`: those look identical on screen and are
    /// not the same fact, and the difference is the one `AwayPane.loadBrain`
    /// was wrong about twice in a row.
    public static func step(here: Here, away: Published) -> Step {
        switch away.state {
        case "set": break
        // A person who removed the brain removed it. Re-publishing on their
        // next model change would undo an act they took deliberately.
        case "none", "revoked": return .noMachine
        case "sealed", "unreadable", "could-not-ask": return .cannotTell
        default: return .cannotTell
        }
        if here.apart { return .apart }

        // The address, but only from a provider that has one — see
        // `carriesBaseURL`. `brainExtras["baseURL"]` is one slot for the whole
        // pane and keeps whatever the last local server put in it, so reading
        // it unconditionally would call a DeepSeek brain "local" on the
        // strength of a field DeepSeek does not have.
        let address = carriesBaseURL(here.provider) ? here.baseURL : ""

        // A model on this Mac's own loopback, whatever provider carries it.
        if localProviders.contains(here.provider) || isLocalAddress(address) {
            return .localOnly
        }

        if here.provider == claudePlanProvider {
            // This Mac's `sonnet` is the machine's `claude-sonnet-5`: the
            // machine calls the Messages API, which has no aliases.
            let wanted = machineModel(forClaudePlan: here.model)
            // A sign-in the machine does not have — a different kind, or a
            // Claude account this Mac changed to — goes over as it is.
            if here.credentialAvailable && (away.kind != kindSetupToken || here.credentialChanged) {
                return .sendClaudeToken(model: wanted)
            }
            guard away.kind == kindSetupToken else { return .needsItsOwnToken }
            return away.model == wanted
                ? .upToDate
                // nil: this Mac says `claude-code-cli` and the document says
                // `anthropic`, and both are `SETUP_TOKEN_PROVIDERS`. The kind
                // is the assertion that matters here.
                : .retune(model: wanted, baseURL: "", assertProvider: nil)
        }

        if here.provider == codexProvider {
            // Always from the live file rather than a re-seal: signing into a
            // different ChatGPT account on this Mac writes a new `auth.json`,
            // and re-sealing the old copy under a new model would leave the
            // machine on an account the person has left.
            return away.kind == kindCodexAuth && away.model == here.model
                && away.provider == codexProvider
                ? .upToDate
                : .sendCodex(model: here.model)
        }

        // Everything else is a key-paid provider.
        if here.keyInHand {
            return .sendKey(provider: here.provider, model: here.model, baseURL: address)
        }
        if here.credentialAvailable
            && (away.kind != kindAPIKey || away.provider != here.provider || here.credentialChanged) {
            return .sendKey(provider: here.provider, model: here.model, baseURL: address)
        }
        guard away.kind == kindAPIKey, away.provider == here.provider else {
            return .needsItsOwnKey(provider: here.provider)
        }
        return away.model == here.model && away.baseURL == address
            ? .upToDate
            : .retune(model: here.model, baseURL: address, assertProvider: here.provider)
    }

    /// Whether this step publishes anything at all — the question the pane
    /// asks before it puts a spinner up.
    public static func travels(_ step: Step) -> Bool {
        switch step {
        case .retune, .sendKey, .sendCodex, .sendClaudeToken: return true
        case .noMachine, .cannotTell, .upToDate, .needsItsOwnToken,
             .needsItsOwnKey, .localOnly, .apart: return false
        }
    }
}
