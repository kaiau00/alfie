import Foundation
import Testing
@testable import MoeBrain

/// The cheap-model table: one copy in Swift, one in
/// `moe-home/hermes/model-tiers.json` for configure-hermes.py. Two copies of
/// a table drift, and a drifted one sends the app's meeting scan and Hermes's
/// cron to different models on the same brain.
struct ModelTiersTests {

    private var jsonURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("moe-home/hermes/model-tiers.json")
    }

    @Test("the Swift table is exactly model-tiers.json")
    func swiftMatchesJSON() throws {
        let data = try Data(contentsOf: jsonURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let table = try #require(object?["cheapest"] as? [String: String])
        #expect(table == ModelTiers.cheapest)
    }

    @Test("a provider with an entry gets its own cheap model, never another's")
    func cheapestPerProvider() {
        #expect(ModelTiers.cheapest(provider: "claude-code-cli", chosen: "opus") == "haiku")
        #expect(ModelTiers.cheapest(provider: "openai-codex", chosen: "gpt-5.5") == "gpt-5.4-mini")
        #expect(ModelTiers.cheapest(provider: "deepseek", chosen: "deepseek-v4-pro") == "deepseek-v4-flash")
    }

    @Test("no entry, or no chosen model, keeps what the person has")
    func fallsBackToChosen() {
        #expect(ModelTiers.cheapest(provider: "custom", chosen: "llama3.1") == "llama3.1")
        #expect(ModelTiers.cheapest(provider: "lmstudio", chosen: "qwen") == "qwen")
        #expect(ModelTiers.cheapest(provider: "moe-custom", chosen: "") == "")
        // Empty means "Hermes's config default"; naming a model over it is a guess.
        #expect(ModelTiers.cheapest(provider: "claude-code-cli", chosen: " ") == "")
    }
}
