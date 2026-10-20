import Foundation
import MoeDictation

/// Finds a model server already running on this computer.
///
/// **Found, never installed.** Ollama and LM Studio are separate
/// applications with their own background services, updates and disk; an app
/// that downloads and installs one because dictation would be faster has
/// helped itself to a decision that was not its to take. So this looks, and
/// if nothing is there it says so and Settings offers a link rather than a
/// button that installs software.
///
/// Both speak an OpenAI-shaped API on a well-known loopback port, which is
/// also what Hermes already talks to (`BrainProviderKind.lmstudio`,
/// `.custom`) — so a server found here needs no new transport, only a
/// provider and a base URL.
///
/// Portable by construction: the ports and the API are the same on Windows
/// and Linux, so this file is one of the pieces that survives the move
/// (CROSS-PLATFORM.md).
enum LocalModelServer {

    struct Found: Equatable, Sendable {
        /// What to show a person: "LM Studio", "Ollama".
        let name: String
        /// The provider Hermes should route through.
        let provider: String
        let baseURL: String
        /// Models the server reports. Empty is a real answer — a server can
        /// be running with nothing pulled, which looks identical from the
        /// outside and fails only when asked to generate.
        let models: [String]

        /// Usable only when it actually has a model to run.
        var isReady: Bool { !models.isEmpty }
    }

    /// Where the two look. Ollama's own API is on 11434 and it also serves
    /// an OpenAI-compatible surface at /v1; LM Studio serves /v1 on 1234.
    private static let candidates: [(name: String, provider: String, base: String)] = [
        ("LM Studio", "lmstudio", "http://127.0.0.1:1234/v1"),
        ("Ollama", "custom", "http://127.0.0.1:11434/v1"),
    ]

    /// Short, because this runs while someone is looking at a Settings pane
    /// and a server that is not there must not make the row hang.
    static let probeTimeout: TimeInterval = 1.5

    /// The first server that answers, or nil.
    static func detect() async -> Found? {
        for c in candidates {
            if let models = await models(at: c.base), !models.isEmpty {
                return Found(name: c.name, provider: c.provider, baseURL: c.base, models: models)
            }
        }
        return nil
    }

    /// `GET /v1/models` — the one call both servers answer and neither
    /// charges for. Nil when nothing is listening; an empty array when
    /// something is, but has no model pulled.
    static func models(at baseURL: String) async -> [String]? {
        guard let url = URL(string: baseURL + "/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = probeTimeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = probeTimeout
        cfg.timeoutIntervalForResource = probeTimeout
        // A proxy has no business intercepting a loopback probe, and on a
        // corporate Mac one would turn "not running" into a hang.
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.modelIDs(from: data)
        } catch {
            return nil
        }
    }

    /// Model ids out of an OpenAI-shaped `/v1/models` body, and which one to
    /// use. Both live in `LocalModelChoice` (MoeDictation) so their edge
    /// cases are tested without a running server.
    static func modelIDs(from data: Data) -> [String] {
        LocalModelChoice.modelIDs(from: data)
    }

    static func preferredModel(from models: [String]) -> String? {
        LocalModelChoice.preferredModel(from: models)
    }
}
