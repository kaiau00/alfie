import Foundation
import MoeBrain

/// Asks the gateway what Hermes knows about a model and lays it over the
/// table's answer.
///
/// What Hermes serves: `GET /api/model/options` (`api_server.py`
/// `_handle_model_options` → `hermes_cli/inventory.py`
/// `build_model_options_payload`, `_apply_capabilities`) — one row per
/// provider, `models: [id]` and `capabilities: {id: {fast, reasoning}}`.
/// That is the whole of it: vision and tool calling are decided inside the
/// process (`agent/models_dev.py` `get_model_capabilities`, models.dev +
/// config.yaml overrides) and never put on the wire, and `GET /v1/models`
/// lists only the virtual `hermes-agent` id. So Hermes settles the reasoning
/// column; the other two stay the table's.
enum BrainCapabilityProbe {

    static func fetch(config: Config, brain: BrainSelection, over table: BrainCapabilities) async -> BrainCapabilities {
        let endpoint = HermesEndpoint(config: config)
        let session = URLSession(configuration: HermesEndpoint.sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        var req = endpoint.request("api/model/options")
        req.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return table }
        return merge(payload: obj, brain: brain, over: table)
    }

    /// Pure, for tests and for reading: the row whose `slug` is the
    /// provider, then `capabilities[model].reasoning`. Anything missing
    /// leaves the table's value. The Claude Code child ignores the effort
    /// dial whatever the catalog says (`supportsReasoningEffort`).
    static func merge(payload: [String: Any], brain: BrainSelection, over table: BrainCapabilities) -> BrainCapabilities {
        guard let rows = payload["providers"] as? [[String: Any]],
              let row = rows.first(where: { ($0["slug"] as? String)?.lowercased() == brain.provider.rawValue }),
              let caps = row["capabilities"] as? [String: Any]
        else { return table }
        let model = brain.model
        let entry = (caps[model] ?? caps.first(where: { $0.key.lowercased() == model.lowercased() })?.value) as? [String: Any]
        guard let entry, let reasoning = entry["reasoning"] as? Bool else { return table }
        var out = table
        out.reasoningEffort = (reasoning && brain.provider.supportsReasoningEffort) ? .yes : .no
        out.source = "hermes"
        return out
    }
}
