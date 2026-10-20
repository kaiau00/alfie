import Foundation
import MoeDictation

/// Picks who rewrites a dictation, and falls onward when that one cannot.
///
/// The rule is "first available tier wins", ordered by what the user
/// experiences rather than by model capability: on-device before local
/// server, local server before cloud, and rules under all of it. A dictation
/// rewrite is mechanical, and a 3B model on the Neural Engine does it as well
/// as a frontier model and several times faster.
///
/// **Availability is asked, not assumed, and re-asked.** Apple's model
/// reports three different unavailable states in sequence on a fresh machine
/// — not enabled, then downloading, then ready — so a router that cached the
/// first answer would never use it. `available()` is cheap and consulted per
/// dictation, with only the *negative* answer briefly remembered so a machine
/// that will never have it does not pay a check every time.
///
/// **Portability.** `.appleOnDevice` is compiled out where the framework does
/// not exist. On Windows and Linux (CROSS-PLATFORM.md) the ladder starts at
/// `.localServer` — Hermes talking to Ollama or LM Studio, which it already
/// speaks — and nothing else about this file changes. That is the point of
/// having a ladder rather than an `if #available`.
actor PolishRouter {

    /// How long a "this tier is not available" answer is trusted before
    /// asking again. Long enough that a machine without Apple Intelligence is
    /// not probed every dictation; short enough that switching it on starts
    /// working within a minute, without a restart.
    static let unavailableFor: TimeInterval = 60

    private let apple = AppleOnDevicePolish()
    /// The cloud tier. Owned by the caller because it holds the Hermes
    /// session and is rebuilt when Settings change.
    private var brain: DictationPolisher

    /// Tier → when its "unavailable" answer expires.
    private var deferredUntil: [PolishTier: Date] = [:]
    /// Which tier last did the work, for Settings and the log.
    private(set) var lastUsed: PolishTier = .rulesOnly

    init(brain: DictationPolisher) {
        self.brain = brain
    }

    func replaceBrain(_ new: DictationPolisher) { brain = new }

    /// The order tiers are tried for this config.
    ///
    /// `preferred` is the user's choice when they have made one; it is moved
    /// to the front rather than made exclusive, so choosing the fastest tier
    /// on a machine that loses it does not silently disable the rewrite.
    func ladder(preferred: PolishTier?) -> [PolishTier] {
        PolishTier.ladder(preferred: preferred)
    }

    /// Rewrite `text`, or nil to keep it. Tries each available tier in turn
    /// and stops at the first that answers.
    func polish(_ text: String, prompt: PolishPrompt.Assembled,
                budget: TimeInterval, preferred: PolishTier?,
                brainReachable: Bool) async -> String? {
        let started = Date()
        for tier in ladder(preferred: preferred) {
            // A tier that said no recently is skipped without asking again.
            if let until = deferredUntil[tier], until > Date() { continue }

            // Whatever the earlier tiers spent comes out of the budget: the
            // user is waiting on the total, not on the last attempt.
            let left = budget - Date().timeIntervalSince(started)
            guard left > 0.2 else { break }

            switch tier {
            case .appleOnDevice:
                guard await apple.isAvailable else { defer_(tier); continue }
                if let out = await apple.polish(text, prompt: prompt, budget: left) {
                    lastUsed = tier
                    return out
                }
                // Available but declined this one — a guardrail, a refusal.
                // Not a reason to stop asking it in general.
                continue

            case .localServer:
                guard let found = await localServer(), found.isReady,
                      let model = LocalModelServer.preferredModel(from: found.models),
                      let provider = BrainProviderKind(rawValue: found.provider) else {
                    defer_(tier)
                    continue
                }
                var pick = BrainSelection(provider: provider, model: model)
                // A rewrite has nothing to deliberate about, and a small local
                // model that starts reasoning will blow the budget outright.
                pick.suppressReasoning = true
                if let out = await brain.polish(text, prompt: prompt, budget: left, via: pick) {
                    lastUsed = tier
                    return out
                }
                continue

            case .configuredBrain:
                guard brainReachable else { defer_(tier); continue }
                if let out = await brain.polish(text, prompt: prompt, budget: left) {
                    lastUsed = tier
                    return out
                }
                continue

            case .rulesOnly:
                continue
            }
        }
        lastUsed = .rulesOnly
        return nil
    }

    /// The detected server, remembered briefly.
    ///
    /// Detection is two loopback probes with a 1.5 s timeout, which is far
    /// too much to spend per dictation on a machine that has neither — and
    /// far too little to cache forever on one where the user just started LM
    /// Studio. Same reasoning as the tier deferral, same window.
    private var foundServer: LocalModelServer.Found?
    private var serverCheckedAt: Date?

    private func localServer() async -> LocalModelServer.Found? {
        if let at = serverCheckedAt, Date().timeIntervalSince(at) < Self.unavailableFor {
            return foundServer
        }
        foundServer = await LocalModelServer.detect()
        serverCheckedAt = Date()
        if let f = foundServer {
            Log.write("dictation: found \(f.name) with \(f.models.count) model(s)")
        }
        return foundServer
    }

    private func defer_(_ tier: PolishTier) {
        deferredUntil[tier] = Date().addingTimeInterval(Self.unavailableFor)
    }

    /// Whether Apple's model could run, and why not when it cannot.
    ///
    /// The reason matters: "Apple Intelligence is off" is something a person
    /// can act on, and "still downloading" is something they only need to
    /// wait for. Both were real states on the machine this was written on.
    func appleStatus() async -> (ready: Bool, detail: String) {
        await apple.status()
    }

    /// Which tier would run right now, for Settings to show without doing a
    /// dictation. Asks for real; does not consult the deferral cache, because
    /// a person looking at Settings has usually just changed something.
    func currentTier(preferred: PolishTier?, brainReachable: Bool) async -> PolishTier {
        for tier in ladder(preferred: preferred) {
            switch tier {
            case .appleOnDevice:   if await apple.isAvailable { return tier }
            case .localServer:     if await localServer()?.isReady == true { return tier }
            case .configuredBrain: if brainReachable { return tier }
            case .rulesOnly:       continue
            }
        }
        return .rulesOnly
    }
}
