import Foundation
import MoeChat

/// Names conversations for the Chat list with one small call each: the
/// cheapest model of your provider (`BrainSelection.cheapest`), your first
/// message and nothing else (`TitleRules`), one side session reused for all
/// of them so no call starts cold or clutters your history.
@MainActor
final class TitleNamer {
    static let sessionKey = "moe-titles"
    /// One fixed side session for every title, like dictation's.
    private static let sessionID = "5e1a7c3b-0d2f-4b8e-9c61-7a4f2e8b1d90"

    private let endpoint: HermesEndpoint
    private let brain: BrainSelection
    private let session: URLSession
    private var inFlight: Set<String> = []

    init(config: Config) {
        endpoint = HermesEndpoint(config: config)
        brain = BrainSelection.cheapest(config: config)
        let cfg = HermesEndpoint.sessionConfiguration()
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    /// Name `thread` from `firstMessage` unless it has a name or is being
    /// named; `done` gets the name, on the main actor.
    func name(thread: String, firstMessage: String, done: @escaping (String?) -> Void) {
        guard !inFlight.contains(thread) else { return }
        inFlight.insert(thread)
        let req = endpoint.chatRequest(sessionID: Self.sessionID, sessionKey: Self.sessionKey,
                                       system: TitleRules.system,
                                       user: TitleRules.user(firstMessage: firstMessage),
                                       stream: false, brain: brain,
                                       origin: nil)   // side session: never live
        let session = self.session
        Task.detached(priority: .utility) {
            let result = try? await session.data(for: req)
            let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
            let reply = result.flatMap { status == 200 ? DictationPolisher.content(from: $0.0) : nil }
            let title = reply.flatMap(TitleRules.accept)
            await MainActor.run {
                self.inFlight.remove(thread)
                if title == nil {
                    Log.write("titles: no name for \(thread.prefix(8)) (HTTP \(status))")
                }
                done(title)
            }
        }
    }
}
