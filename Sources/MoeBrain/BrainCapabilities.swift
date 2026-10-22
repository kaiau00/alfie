import Foundation

/// What a provider+model pair can do, as far as Moe can tell. PRODUCT.md
/// §3.4a: every feature needs a graceful fallback when the model can't —
/// no screenshot to a model without vision, a prompt that says so when
/// there are no tools — and the Brain pane shows what the chosen model can
/// do. Each answer is yes / no / unknown; unknown is treated as "try it".
///
/// Sources, in order (`BrainCapabilityTable.lookup` is the last two):
///   1. Hermes, asked over the gateway (`GET /api/model/options` →
///      `hermes_cli/inventory.py` `_apply_capabilities`): per-model
///      `reasoning` only. Nothing Hermes serves says vision or tools —
///      those live in `agent/models_dev.py` `get_model_capabilities`
///      (models.dev catalog + config.yaml `model.supports_vision`) and are
///      consulted inside the process (`agent/image_routing.py`).
///   2. The curated table below, by provider id and model family.
///   3. Unknown.
public struct BrainCapabilities: Equatable, Codable, Sendable {
    public enum Support: String, Codable, Sendable {
        case yes, no, unknown

        /// "✓", "—", "?" — what the Brain pane prints.
        public var mark: String {
            switch self {
            case .yes: return "✓"
            case .no: return "—"
            case .unknown: return "?"
            }
        }
    }

    /// Accepts images (Moe's screen context attaches a screenshot).
    public var vision: Support
    /// Tool calling (Moe can act, not just talk).
    public var tools: Support
    /// Honours a `reasoning_effort` request option.
    public var reasoningEffort: Support
    /// Streams tokens. Every Hermes transport streams over the gateway's
    /// SSE, so this is yes for anything Hermes runs.
    public var streaming: Support
    /// Where the answer came from: "hermes", "table", "unknown".
    public var source: String

    public init(vision: Support = .unknown, tools: Support = .unknown,
                reasoningEffort: Support = .unknown, streaming: Support = .yes,
                source: String = "unknown") {
        self.vision = vision
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.streaming = streaming
        self.source = source
    }

    public static let unknown = BrainCapabilities()

    /// The graceful-degradation switches: a feature is withheld only on a
    /// definite no. Unknown means try, and let Hermes sort it out.
    public var mayAttachImages: Bool { vision != .no }
    public var mayUseTools: Bool { tools != .no }

    /// The one-liner under the model picker.
    public var summaryLine: String {
        "Can see your screen \(vision.mark) · Can use tools \(tools.mark) · Reasoning effort \(reasoningEffort.mark)"
    }

    /// A caption for whatever is definitely missing; nil when nothing is.
    public var missingCaption: String? {
        var lines: [String] = []
        if vision == .no { lines.append("This model can't see images, so Alfie won't attach your screen.") }
        if tools == .no { lines.append("No tool calling: Alfie can talk but not act.") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

/// The curated table. Keyed on Hermes provider ids (the raw values of
/// `BrainProviderKind`) so it can live in a testable module; the enum's
/// `capabilities(for:)` is the caller.
public enum BrainCapabilityTable {

    /// Local model families known to take images, and families known not
    /// to. Anything else is unknown: Hermes settles it itself at image time
    /// (`agent/image_routing.py` `_lookup_supports_vision`: config.yaml
    /// `supports_vision`, then models.dev, then Ollama's `/api/show`) and a
    /// model it can't see through gets the screenshot as text via
    /// `vision_analyze` — so a wrong "no" here, which would withhold the
    /// screen for good, is the worse failure. "no" is therefore only for
    /// families that never took images, and only in Ollama's `family:tag`
    /// form, where the family is unambiguous.
    ///
    /// Names are matched with `-`, `_` and `.` removed, so Ollama's
    /// `gemma3:4b`, LM Studio's `google/gemma-3-12b` and Hugging Face's
    /// `Gemma-3-4b-it-GGUF` all land on `gemma3`.
    static let localVisionFamilies = [
        "llava", "bakllava", "llama3.2-vision", "llama4", "qwen2-vl", "qwen2.5-vl",
        "qwen2.5-omni", "qwen3-vl", "qwen3.5", "gemma3", "gemma4", "minicpm-v",
        "moondream", "pixtral", "granite3.2-vision", "granite3.3-vision",
        "mistral-small3.1", "mistral-small3.2", "phi-4-multimodal", "smolvlm",
        "internvl", "idefics", "paligemma", "glm-4.1v", "glm-4.5v", "glm-4.6v",
        "kimi-vl", "molmo",
    ]
    static let localTextOnlyFamilies = [
        "qwen", "qwen2", "qwen2.5", "qwen2.5-coder", "qwen3", "qwen3-coder", "qwq",
        "llama2", "llama3", "llama3.1", "llama3.2", "llama3.3", "codellama",
        "gemma", "gemma2", "codegemma", "mistral", "mistral-nemo", "mixtral", "codestral",
        "magistral", "devstral", "phi3", "phi3.5", "phi4", "phi4-mini", "deepseek-r1",
        "deepseek-v2", "deepseek-v3", "deepseek-coder", "deepseek-coder-v2", "gpt-oss",
        "command-r", "hermes3", "nemotron", "olmo2", "smollm2", "tinyllama", "starcoder2",
    ]

    public static func lookup(provider: String, model: String) -> BrainCapabilities {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return .unknown }
        func table(_ vision: BrainCapabilities.Support, _ tools: BrainCapabilities.Support,
                   _ reasoning: BrainCapabilities.Support) -> BrainCapabilities {
            BrainCapabilities(vision: vision, tools: tools, reasoningEffort: reasoning,
                              streaming: .yes, source: "table")
        }
        switch provider {
        case "claude-code-cli":
            // The `claude` CLI only ever runs Claude models; every one Moe
            // offers sees images and calls tools. The child owns its own
            // thinking, so the effort dial is not honoured (see
            // BrainProviderKind.supportsReasoningEffort).
            return isClaude(id) ? table(.yes, .yes, .no) : BrainCapabilities(reasoningEffort: .no, source: "table")
        case "anthropic":
            return isClaude(id) ? table(.yes, .yes, .yes) : .unknown
        case "openai-codex":
            return id.hasPrefix("gpt-5") ? table(.yes, .yes, .yes) : .unknown
        case "openai-api":
            return openAI(id) ?? .unknown
        case "gemini":
            return id.hasPrefix("gemini-") ? table(.yes, .yes, .yes) : .unknown
        case "openrouter":
            // vendor/model. Unknown until fetched, except the families whose
            // capabilities don't depend on the route.
            guard let slash = id.firstIndex(of: "/") else { return .unknown }
            let vendor = String(id[..<slash]), name = String(id[id.index(after: slash)...])
            switch vendor {
            case "anthropic": return isClaude(name) ? table(.yes, .yes, .yes) : .unknown
            case "openai":    return openAI(name) ?? .unknown
            case "google":    return name.hasPrefix("gemini-") ? table(.yes, .yes, .yes) : .unknown
            default:          return .unknown
            }
        case "lmstudio", "custom":
            // Ollama, LM Studio, vLLM, llama.cpp. Tool calling depends on
            // the model *and* the server's template, so it is unknown;
            // Hermes probes reasoning itself (`/api/show` for Ollama).
            return BrainCapabilities(vision: localVision(id), tools: .unknown, reasoningEffort: .unknown,
                                     streaming: .yes, source: "table")
        default:
            return .unknown
        }
    }

    static func isClaude(_ id: String) -> Bool {
        id.hasPrefix("claude-") || ["opus", "sonnet", "haiku", "fable"].contains(where: { id.hasPrefix($0) })
    }

    /// OpenAI ids, by family. Nil for a family the table doesn't know.
    static func openAI(_ id: String) -> BrainCapabilities? {
        func table(_ reasoning: BrainCapabilities.Support) -> BrainCapabilities {
            BrainCapabilities(vision: .yes, tools: .yes, reasoningEffort: reasoning, streaming: .yes, source: "table")
        }
        if id.hasPrefix("gpt-5") { return table(.yes) }
        if id.hasPrefix("gpt-4o") || id.hasPrefix("gpt-4.1") { return table(.no) }
        // o1-mini/o3-mini never took images; the full o-series does.
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return id.contains("mini") ? nil : table(.yes)
        }
        return nil
    }

    /// Yes for a known vision family, no for a known text-only family in
    /// Ollama's `family:tag` form (or the bare family), else unknown.
    static func localVision(_ id: String) -> BrainCapabilities.Support {
        // "llava:13b", "hf.co/org/qwen2.5-vl-7b-gguf:q4", "google/gemma-3-12b".
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let bare = name.split(separator: ":").first.map(String.init) ?? name
        func squash(_ s: String) -> String { s.filter { !"-_.".contains($0) } }
        let tokens = bare.split(whereSeparator: { "-_".contains($0) }).map(String.init)
        if tokens.contains("vision") || tokens.contains("vl") { return .yes }
        let flat = squash(bare)
        if localVisionFamilies.contains(where: { flat.hasPrefix(squash($0)) || flat.contains(squash($0)) }) {
            return .yes
        }
        if localTextOnlyFamilies.contains(bare) { return .no }
        return .unknown
    }
}
