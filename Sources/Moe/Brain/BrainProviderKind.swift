import Foundation
import MoeBrain

/// Where Hermes gets its model from — the providers Moe's Brain pane offers,
/// by Hermes's own provider ids (`hermes_cli/models.py` CANONICAL_PROVIDERS;
/// `configure-hermes.py` PROVIDER_KEY_ENV mirrors this list).
///
/// Plain-language groups, not vendor names: the question the user is
/// answering is "what are you paying for already?"
enum BrainProviderKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code-cli"
    case codex      = "openai-codex"
    case anthropic  = "anthropic"
    case openAI     = "openai-api"
    case openRouter = "openrouter"
    case gemini     = "gemini"
    // Two Hermes has always accepted (`configure-hermes.py`
    // PROVIDER_KEY_ENV) and this picker never showed, so the only way to
    // reach them was to edit config.yaml by hand.
    case deepSeek   = "deepseek"
    case xai        = "xai"
    case customKey  = "moe-custom"
    case lmStudio   = "lmstudio"
    case local      = "custom"

    var id: String { rawValue }

    /// How the user pays / signs in — the UI rows depend on this.
    enum Access { case claudeSignIn, codexSignIn, apiKey, localServer }

    var access: Access {
        switch self {
        case .claudeCode: return .claudeSignIn
        case .codex:      return .codexSignIn
        case .anthropic, .openAI, .openRouter, .gemini,
             .deepSeek, .xai, .customKey: return .apiKey
        case .lmStudio, .local: return .localServer
        }
    }

    /// The row in the picker. Says what the person is choosing, in words
    /// that assume nothing: "API key" is a term a first-time reader does not
    /// have, so the row says how you pay instead and BrainGuide explains it.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude — your monthly plan"
        case .codex:      return "ChatGPT — your monthly plan"
        case .anthropic:  return "Anthropic — pay with a key"
        case .openAI:     return "OpenAI — pay with a key"
        case .openRouter: return "OpenRouter — pay with a key"
        case .gemini:     return "Google Gemini — pay with a key"
        case .deepSeek:   return "DeepSeek — pay with a key"
        case .xai:        return "xAI (Grok) — pay with a key"
        case .customKey:  return "Anywhere else — your own key and address"
        case .lmStudio:   return "LM Studio — runs on this Mac"
        case .local:      return "Ollama or any local server — runs on this Mac"
        }
    }

    /// Just the company or app, for a sentence that already carries the
    /// rest ("No OpenAI key yet"). `displayName` reads wrong mid-sentence.
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex:      return "ChatGPT"
        case .anthropic:  return "Anthropic"
        case .openAI:     return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .gemini:     return "Google Gemini"
        case .deepSeek:   return "DeepSeek"
        case .xai:        return "xAI"
        case .customKey:  return "your service"
        case .lmStudio:   return "LM Studio"
        case .local:      return "Ollama"
        }
    }

    // What each provider *is*, what it costs, what you give up and what to
    // do next now lives in one place: `BrainGuide` (Sources/Moe/Onboarding).
    // A `blurb` here as well is how the Brain pane and onboarding drifted
    // apart in the first place, so there is deliberately no second copy.

    /// The .env variable Hermes reads the key from (`hermes_cli/auth.py`
    /// PROVIDER_REGISTRY). Nil: no key — a sign-in or a local server.
    var keyEnvName: String? {
        switch self {
        case .anthropic:  return "ANTHROPIC_API_KEY"
        case .openAI:     return "OPENAI_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .gemini:     return "GEMINI_API_KEY"
        // Its own variable rather than one of the four above: a key for
        // DeepSeek or Groq stored as OPENAI_API_KEY would be handed to the
        // OpenAI provider the moment somebody switched back to it.
        case .deepSeek:   return "DEEPSEEK_API_KEY"
        case .xai:        return "XAI_API_KEY"
        case .customKey:  return "MOE_CUSTOM_API_KEY"
        default:          return nil
        }
    }

    /// Needs an address as well as (or instead of) a credential. A local
    /// server has no key and a custom service has both, so this is not the
    /// same question as `access`.
    var usesBaseURL: Bool { access == .localServer || self == .customKey }
    var defaultBaseURL: String {
        switch self {
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .local:    return "http://127.0.0.1:11434/v1"
        // Deliberately blank: there is no sensible default address for
        // "somewhere else", and a pre-filled one that is wrong is worse
        // than an empty field with a placeholder.
        default:        return ""
        }
    }

    /// Reasoning effort is a per-request option Hermes applies on its own
    /// API transports (`api_server.py` `_request_reasoning_config`).
    ///
    /// This used to say the Claude Code child "owns its own thinking and
    /// ignores it". Measured 2026-08-31, twice, on the dictation prompt with a
    /// warm session — it does not ignore it:
    ///
    ///     default          3178 ms, 3523 ms   (and swinging 2.2-4.7 s)
    ///     effort "none"    2262 ms, 2243 ms   (steady)
    ///
    /// A third off, identical output, and the variance collapses. The claim
    /// was written once and never re-tested. It is still true that the child
    /// does not expose *graded* effort the way an API transport does, so the
    /// picker stays hidden for it — but "none" reaches it, and dictation sends
    /// it (see `forDictation`).
    var supportsReasoningEffort: Bool { self != .claudeCode }

    /// The effort levels this provider's `model` actually accepts, in the
    /// provider's own words — never a Moe-invented scale. Taken from what
    /// Hermes sends on each wire (`agent/reasoning_effort.py`,
    /// `anthropic_adapter.py` ADAPTIVE_EFFORT_MAP, `gemini_native_adapter.py`)
    /// and, for the Claude Code child, from `claude --help` (`--effort`).
    /// Empty means the model has no such setting and the picker is not shown.
    func effortLevels(for model: String) -> [String] {
        let m = model.lowercased()
        switch self {
        case .claudeCode:
            // `claude --effort low|medium|high|xhigh|max`, carried on the
            // child's command line (configure-hermes.py --set-reasoning).
            return ["low", "medium", "high", "xhigh", "max"]
        case .anthropic:
            // Adaptive effort: 4.7 and later take xhigh; Opus/Sonnet 4.6 and
            // older stop at max.
            let older = ["4-6", "4-5", "4-2025"].contains { m.contains($0) }
            return older ? ["low", "medium", "high", "max"] : ["low", "medium", "high", "xhigh", "max"]
        case .openAI, .codex:
            // Responses API: `minimal` is rejected; `max` is gpt-5.6 only.
            return m.contains("gpt-5.6") ? ["none", "low", "medium", "high", "xhigh", "max"]
                                         : ["none", "low", "medium", "high", "xhigh"]
        case .openRouter, .customKey:
            return ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        case .gemini:
            // thinkingLevel: Pro takes low/high, the Flash models the four.
            return m.contains("flash") ? ["minimal", "low", "medium", "high"] : ["low", "high"]
        case .deepSeek:
            return ["low", "medium", "high", "max"]
        case .xai:
            if m.contains("non-reasoning") { return [] }
            return m.contains("4.6") || m.contains("4.7") ? ["low", "medium", "high", "xhigh"]
                                                            : ["low", "medium", "high"]
        case .lmStudio, .local:
            // Sent as `reasoning.effort`; a model that does not think ignores it.
            return ["none", "low", "medium", "high"]
        }
    }

    /// Two words under each effort chip. The level itself is the provider's
    /// own name for it; this is the plain-language gloss.
    static func effortCaption(_ level: String) -> String {
        switch level {
        case "none":    return "No thinking, fastest"
        case "minimal": return "Barely thinks"
        case "low":     return "Quick"
        case "medium":  return "Everyday"
        case "high":    return "The usual choice"
        case "xhigh":   return "Careful, slower"
        case "max":     return "Slowest, most thorough"
        default:        return ""
        }
    }

    /// Two words under each model chip. Real model ids stay the title; this
    /// says what picking one gets you, for someone who has not kept up.
    func modelCaption(_ id: String) -> String {
        let m = id.lowercased()
        let tail = m.split(separator: "/").last.map(String.init) ?? m
        switch self {
        case .claudeCode:
            switch tail {
            case "opus":   return "Smartest, slower"
            case "sonnet": return "Quick and capable"
            case "haiku":  return "Fastest"
            case "fable":  return "Newest"
            default:       return ""
            }
        default:
            if tail.contains("fable") { return "Newest Claude" }
            if tail.contains("opus") { return "Smartest, slower" }
            if tail.contains("sonnet") { return "Quick and capable" }
            if tail.contains("haiku") { return "Fastest, cheapest" }
            if tail.contains("-sol") { return "Newest, largest" }
            if tail.contains("-terra") { return "Newest, balanced" }
            if tail.contains("-luna") { return "Newest, fastest" }
            if tail.contains("codex") { return "Made for code" }
            if tail.contains("nano") { return "Fastest, cheapest" }
            if tail.contains("mini") { return "Fast and cheap" }
            if tail.hasPrefix("gpt-5.5") { return "Smartest of the 5.5s" }
            if tail.hasPrefix("gpt-5.4") { return "Everyday" }
            if tail.hasPrefix("gpt-4") { return "Older" }
            if tail.contains("flash-lite") { return "Fastest, cheapest" }
            if tail.contains("flash") { return "Fast" }
            if tail.contains("pro") { return "Smartest" }
            if tail.contains("non-reasoning") { return "No thinking, fastest" }
            if tail.contains("reasoning") { return "Thinks before answering" }
            if tail.contains("glm") { return "Cheap and capable" }
            return ""
        }
    }

    /// The bundled art `ServiceIcon` looks up, where there is any; the rest
    /// fall back to a monogram in the service's colour.
    var iconName: String {
        switch self {
        case .claudeCode, .anthropic: return "anthropic"
        case .codex, .openAI:         return "openai"
        default:                      return rawValue
        }
    }

    /// The sentence at the top of the Brain pane: who Moe is borrowing from,
    /// and how.
    var accountTitle: String {
        switch self {
        case .claudeCode: return "Claude, on your monthly plan"
        case .codex:      return "ChatGPT, on your monthly plan"
        case .customKey:  return "Your own service, with your key"
        case .lmStudio:   return "LM Studio, on this Mac"
        case .local:      return "Ollama or a local server, on this Mac"
        default:          return "\(shortName), with your key"
        }
    }

    /// What this provider's `model` can do, from the curated table
    /// (`BrainCapabilityTable` in MoeBrain — keyed on these raw ids so it
    /// can be unit-tested). Hermes's own answer, where it has one, is laid
    /// over this by `BrainCapabilityProbe`; `Config.brainCapabilities` is
    /// the cached result.
    func capabilities(for model: String) -> BrainCapabilities {
        BrainCapabilityTable.lookup(provider: rawValue, model: model)
    }

    /// Curated ids, most capable first. The user can always type another
    /// ("Other…"). Sources: `plugins/model-providers/claude-code` fallback
    /// models and `claude --help` aliases; `hermes_cli/models.py`
    /// _PROVIDER_MODELS; `hermes_cli/codex_models.py`.
    var curatedModels: [String] {
        switch self {
        case .claudeCode:
            return ["opus", "sonnet", "haiku", "fable"]
        // No gpt-5.3-codex: Hermes's list still carries it, and the ChatGPT
        // backend refuses it — "HTTP 400: The 'gpt-5.3-codex' model is not
        // supported when using Codex with a ChatGPT account", measured on the
        // owner's Mac 2026-09-09. A button that can only fail is not a
        // choice; "Other…" still takes any name.
        case .codex:
            return ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
        case .anthropic:
            return ["claude-opus-5-5", "claude-sonnet-5", "claude-fable-5", "claude-opus-4-8",
                    "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .openAI:
            return ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
                    "gpt-5.4-nano", "gpt-4.1", "gpt-4o"]
        case .openRouter:
            return ["anthropic/claude-sonnet-4.5", "anthropic/claude-opus-4.5", "openai/gpt-5.5",
                    "google/gemini-3.1-pro-preview", "z-ai/glm-5.2", "deepseek/deepseek-v4-pro"]
        case .gemini:
            return ["gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-3.6-flash",
                    "gemini-3.1-flash-lite-preview"]
        // Straight from Hermes's own table (`hermes_cli/models.py`
        // _PROVIDER_MODELS), not retyped from a vendor page.
        case .deepSeek:
            return ["deepseek-v4-pro", "deepseek-v4-flash"]
        case .xai:
            return ["grok-4.6", "grok-4.5", "grok-4.3",
                    "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning"]
        case .customKey, .lmStudio, .local:
            return []
        }
    }

    var defaultModel: String {
        switch self {
        // Sonnet, not Opus: a new person should not burn through their plan
        // on day one (docs/DEFAULTS.md row 2, decided 2026-09-15).
        case .claudeCode: return "sonnet"
        // Not gpt-5.5: OpenAI retires it from ChatGPT and Codex on every plan
        // on 2026-10-14 (learn.chatgpt.com/docs/pricing, read 2026-09-24).
        // The API keeps it, so `.openAI` below is unaffected.
        case .codex:      return "gpt-5.6-sol"
        case .anthropic:  return "claude-sonnet-5"
        case .openAI:     return "gpt-5.5"
        case .openRouter: return "anthropic/claude-sonnet-4.5"
        case .gemini:     return "gemini-3.1-pro-preview"
        case .deepSeek:   return "deepseek-v4-pro"
        case .xai:        return "grok-4.6"
        case .customKey, .lmStudio, .local: return ""
        }
    }

    /// A short name for status lines: "Sonnet 4.5", "gpt-5.5".
    static func prettyModel(_ id: String) -> String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasPrefix("claude-") { s = String(s.dropFirst(7)) }
        // "sonnet-4-6" → "Sonnet 4.6"; "opus" → "Opus"; "gpt-5.5" stays.
        let parts = s.split(separator: "-").map(String.init)
        guard let first = parts.first, first.first?.isLetter == true,
              ["opus", "sonnet", "haiku", "fable"].contains(first) else { return s }
        let digits = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }
        let name = first.prefix(1).uppercased() + first.dropFirst()
        return digits.isEmpty ? name : name + " " + digits.joined(separator: ".")
    }
}

/// What every chat request tells Hermes to run: the provider and model from
/// config.json, and the optional reasoning effort. Sent in the body of
/// `POST /v1/chat/completions` (`model`, `provider`, `model_options`) —
/// Hermes honours a bare `model` only alongside a `provider`
/// (`api_server.py` `_request_agent_overrides`), so both always go.
struct BrainSelection: Equatable {
    var provider: BrainProviderKind
    var model: String
    var reasoningEffort: String
    /// Tell the model not to think at all, whatever the provider. Set for the
    /// dictation rewrite only; the conversation wants its reasoning.
    var suppressReasoning: Bool = false

    init(provider: BrainProviderKind, model: String, reasoningEffort: String = "") {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningEffort = reasoningEffort
    }

    /// The conversation's brain.
    init(config: Config) {
        self.init(provider: config.brainProvider, model: config.brainModel,
                  reasoningEffort: config.brainExtras["reasoningEffort"] ?? "")
    }

    /// Work nobody is waiting on — a meeting's action scan, recap, captions
    /// and notes delivery — on the same provider's cheapest model
    /// (`ModelTiers`, one table shared with configure-hermes.py). No
    /// reasoning effort: the person's effort was a choice about their model,
    /// and a small model may not take it. A provider with no table entry
    /// keeps the chosen model.
    static func cheapest(config: Config) -> BrainSelection {
        BrainSelection(provider: config.brainProvider,
                       model: ModelTiers.cheapest(provider: config.brainProvider.rawValue,
                                                  chosen: config.brainModel))
    }

    /// The dictation polisher's — the same, or a cheaper model of the same
    /// provider when `dictationPolishModel` says so.
    /// The brain the dictation rewrite goes to.
    ///
    /// Model *and* provider can differ from the conversation's, because they
    /// are different jobs. The conversation wants an agent: tools, memory,
    /// a session that remembers. A dictation polish is a mechanical rewrite
    /// of thirty words with a hard time budget, and the agent runtime is pure
    /// overhead on it.
    ///
    /// Measured on this Mac, `haiku` via `claude-code-cli` (Hermes spawning a
    /// `claude` child): 2.1–2.5 s typical, with excursions past the 4 s budget
    /// that silently drop the rewrite. The model was never the cost — the
    /// engines ahead of it take 125 ms — so pointing the same model at a plain
    /// API provider is the lever that remains.
    ///
    /// Empty `dictationPolishProvider` keeps the conversation's provider,
    /// which is the behaviour this has always had.
    static func forDictation(config: Config) -> BrainSelection {
        var s = BrainSelection(config: config)
        let cheaper = config.dictationPolishModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cheaper.isEmpty { s.model = cheaper }
        let via = config.dictationPolishProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !via.isEmpty, let p = BrainProviderKind(rawValue: via) { s.provider = p }
        // A dictation rewrite is mechanical: there is nothing to deliberate
        // about, and deliberating costs a third of the wait. Measured on the
        // Claude Code child, twice: 3178/3523 ms with thinking, 2262/2243 ms
        // without, identical output. `dictationPolishThinking` exists to turn
        // this back on for anyone who finds a rewrite it gets wrong.
        s.suppressReasoning = !config.dictationPolishThinking
        return s
    }

    /// Body fields for the request. Empty model → nothing, so Hermes uses
    /// its config.yaml default (the pre-Brain-pane behaviour).
    var bodyFields: [String: Any] {
        guard !model.isEmpty else { return [:] }
        var f: [String: Any] = ["model": model, "provider": provider.rawValue]
        // `suppressReasoning` bypasses the provider gate on purpose: the gate
        // is about offering a *graded* effort picker, and every provider
        // understands being told not to think — measured, including the
        // Claude Code child.
        if suppressReasoning {
            f["model_options"] = ["reasoning_effort": "none"]
        } else if !reasoningEffort.isEmpty, provider.supportsReasoningEffort {
            f["model_options"] = ["reasoning_effort": reasoningEffort]
        }
        return f
    }
}
