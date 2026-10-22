import Foundation
import Testing
@testable import MoeBrain

/// The curated table (BrainCapabilityTable.lookup): one case per row a user
/// can actually pick in the Brain pane, plus the edges — unknown ids,
/// vendor/model on OpenRouter, local families by name.
struct BrainCapabilityTableTests {
    typealias S = BrainCapabilities.Support

    private func caps(_ provider: String, _ model: String) -> BrainCapabilities {
        BrainCapabilityTable.lookup(provider: provider, model: model)
    }

    @Test func claudeSubscriptionAliasesSeeAndAct() {
        for m in ["opus", "sonnet", "haiku", "fable", "claude-sonnet-4-6"] {
            let c = caps("claude-code-cli", m)
            #expect(c.vision == .yes && c.tools == .yes, "\(m)")
            // The claude child owns its thinking; the effort dial is ignored.
            #expect(c.reasoningEffort == .no)
            #expect(c.streaming == .yes && c.source == "table")
        }
    }

    @Test func claudeSubscriptionUnknownModelStaysUnknownButEffortIsStillOff() {
        let c = caps("claude-code-cli", "mystery-model")
        #expect(c.vision == .unknown && c.tools == .unknown && c.reasoningEffort == .no)
    }

    @Test func anthropicAPI() {
        let c = caps("anthropic", "claude-opus-4-8")
        #expect(c == BrainCapabilities(vision: .yes, tools: .yes, reasoningEffort: .yes, streaming: .yes, source: "table"))
        #expect(caps("anthropic", "gpt-5.5") == .unknown)
    }

    @Test func codexGPT5() {
        #expect(caps("openai-codex", "gpt-5.6-sol").vision == .yes)
        #expect(caps("openai-codex", "gpt-5.3-codex").tools == .yes)
        #expect(caps("openai-codex", "GPT-5.5").reasoningEffort == .yes)   // case-insensitive
        #expect(caps("openai-codex", "davinci") == .unknown)
    }

    @Test func openAIFamilies() {
        #expect(caps("openai-api", "gpt-5.4-mini").reasoningEffort == .yes)
        let fourO = caps("openai-api", "gpt-4o")
        #expect(fourO.vision == .yes && fourO.tools == .yes && fourO.reasoningEffort == .no)
        #expect(caps("openai-api", "gpt-4.1").reasoningEffort == .no)
        #expect(caps("openai-api", "o3").vision == .yes)
        #expect(caps("openai-api", "o3-mini") == .unknown)   // no images on the minis
        #expect(caps("openai-api", "text-embedding-3-large") == .unknown)
    }

    @Test func gemini() {
        #expect(caps("gemini", "gemini-3.1-pro-preview").vision == .yes)
        #expect(caps("gemini", "imagen-4") == .unknown)
    }

    @Test func openRouterKnownVendorsOnly() {
        #expect(caps("openrouter", "anthropic/claude-sonnet-4.5").vision == .yes)
        #expect(caps("openrouter", "openai/gpt-5.5").tools == .yes)
        #expect(caps("openrouter", "google/gemini-3.1-pro-preview").reasoningEffort == .yes)
        // Unknown until fetched: a route Moe knows nothing about.
        #expect(caps("openrouter", "z-ai/glm-5.2") == .unknown)
        #expect(caps("openrouter", "deepseek/deepseek-v4-pro") == .unknown)
        #expect(caps("openrouter", "no-slash") == .unknown)
    }

    @Test func localVisionFamiliesByName() {
        for m in ["llava:13b", "llama3.2-vision:11b", "qwen2.5-vl:7b", "gemma3:4b-it-qat", "gemma3n:e4b",
                  "minicpm-v", "hf.co/org/Qwen2-VL-7B-GGUF:Q4", "moondream:latest", "qwen3.5:9b",
                  // LM Studio / Hugging Face spellings of the same families.
                  "google/gemma-3-12b", "qwen/qwen2.5-vl-7b-instruct", "mistralai/mistral-small-3.1-24b-instruct-2503",
                  "meta-llama/llama-3.2-11b-vision-instruct", "microsoft/phi-4-multimodal-instruct"] {
            #expect(caps("custom", m).vision == .yes, Comment(rawValue: m))
            #expect(caps("lmstudio", m).vision == .yes, Comment(rawValue: m))
        }
    }

    @Test func localTextModelsGetNoScreen() {
        // Definite no: a family that never took images, in Ollama's family:tag form.
        for m in ["qwen2.5:7b", "llama3.1:8b", "gemma2:9b", "deepseek-r1:7b", "mistral:7b", "llama3.2:3b", "qwen3:8b"] {
            let c = caps("custom", m)
            #expect(c.vision == .no, Comment(rawValue: m))
            #expect(c.tools == .unknown && c.reasoningEffort == .unknown && c.streaming == .yes)
        }
    }

    @Test func localUnrecognisedModelsStayUnknown() {
        // Not on either list, or a spelling the text-only list doesn't vouch
        // for: unknown, so the screen is still offered and Hermes decides.
        for m in ["mystery-7b", "qwen/qwen2.5-7b-instruct", "mistral-medium:latest", "glm-5.2:latest"] {
            let c = caps("custom", m)
            #expect(c.vision == .unknown, Comment(rawValue: m))
            #expect(c.mayAttachImages, Comment(rawValue: m))
        }
    }

    @Test func emptyOrUnknownProviderIsUnknown() {
        #expect(caps("custom", "") == .unknown)
        #expect(caps("anthropic", "   ") == .unknown)
        #expect(caps("not-a-provider", "opus") == .unknown)
        #expect(BrainCapabilities.unknown.source == "unknown")
    }

    @Test func degradationSwitchesTreatUnknownAsTry() {
        #expect(BrainCapabilities.unknown.mayAttachImages && BrainCapabilities.unknown.mayUseTools)
        #expect(!caps("custom", "qwen2.5:7b").mayAttachImages)
        #expect(!BrainCapabilities(tools: .no).mayUseTools)
    }

    @Test func summaryAndCaptions() {
        let c = caps("claude-code-cli", "opus")
        #expect(c.summaryLine == "Can see your screen ✓ · Can use tools ✓ · Reasoning effort —")
        #expect(c.missingCaption == nil)
        #expect(caps("custom", "qwen2.5:7b").missingCaption
                == "This model can't see images, so Alfie won't attach your screen.")
        let none = BrainCapabilities(vision: .no, tools: .no)
        #expect(none.missingCaption?.contains("No tool calling: Alfie can talk but not act.") == true)
        #expect(BrainCapabilities.unknown.summaryLine.contains("?"))
    }

    @Test func roundTripsThroughJSON() throws {
        let c = caps("openai-api", "gpt-5.5")
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(BrainCapabilities.self, from: data) == c)
    }
}
