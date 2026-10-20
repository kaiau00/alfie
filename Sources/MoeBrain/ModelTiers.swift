import Foundation

/// The cheapest model each brain provider serves, for work nobody is waiting
/// on: a meeting's live action-item scan, its recap, captions and notes
/// delivery. The conversation and the meeting notes stay on the model the
/// person chose.
///
/// # Why
///
/// Measured on the owner's Mac, 2026-09-15: a 62-minute meeting sent the
/// action scan to Opus 61 times, its context growing 38k → 77k tokens, and
/// the plan's five-hour gauge moved 10 points that hour with nobody typing.
/// A mechanical "any action items in these lines?" does not need the
/// person's best model, on any provider.
///
/// # One table, two readers
///
/// `moe-home/hermes/model-tiers.json` is the source: `configure-hermes.py`
/// reads it for Hermes's `cron.model` and `auxiliary.background_review`.
/// This is the Swift copy, and `ModelTiersTests` fails when the two differ.
/// A provider missing from it — a custom endpoint, LM Studio, a local server
/// — has no list to choose from, so its cheap work stays on the chosen model.
public enum ModelTiers {

    /// Provider id (Hermes's, as `BrainProviderKind.rawValue`) → model.
    public static let cheapest: [String: String] = [
        "claude-code-cli": "haiku",
        "claude-code": "haiku",
        "openai-codex": "gpt-5.4-mini",
        "anthropic": "claude-haiku-4-5-20251001",
        "openai-api": "gpt-5.4-nano",
        "openrouter": "deepseek/deepseek-v4-flash",
        "gemini": "gemini-3.1-flash-lite-preview",
        "deepseek": "deepseek-v4-flash",
        "xai": "grok-4.20-0309-non-reasoning",
    ]

    /// The model cheap work runs on for `provider`. An empty `chosen` stays
    /// empty — that means "Hermes's own config default", and a cheap model
    /// named over it would be a provider guess nobody made.
    public static func cheapest(provider: String, chosen: String) -> String {
        let chosen = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty, let model = cheapest[provider] else { return chosen }
        return model
    }
}
