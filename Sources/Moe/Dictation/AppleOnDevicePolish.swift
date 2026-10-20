#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

/// The dictation rewrite on Apple's on-device model.
///
/// The fastest and most private tier, and the one that needs no setup at all:
/// no key, no download we manage, no server, no subscription. Apple ships the
/// model, the Neural Engine runs it, and the transcript never leaves the Mac.
///
/// **Availability is not a given and must never be assumed.** It needs
/// macOS 26, Apple silicon, a supported region and language, Apple
/// Intelligence switched on by the user, *and* the model actually downloaded —
/// which is a separate, slow, background step. Measured on this machine, the
/// three states came in sequence: `appleIntelligenceNotEnabled` before the
/// user turned it on, then `modelNotReady` for some minutes while it
/// downloaded, then available. `PolishRouter` therefore re-asks rather than
/// caching a "no" forever, and every other tier stays wired up.
///
/// Compiled out entirely where the framework does not exist, so the Windows
/// and Linux shells (CROSS-PLATFORM.md) build without it and fall to
/// `.localServer`.
final class AppleOnDevicePolish: PolishBackend {

    nonisolated let displayName = "On this Mac (fastest, private)"
    nonisolated let isOnDevice = true

    /// One session, kept warm and reused. A session carries the instructions,
    /// so rebuilding it per dictation would re-pay whatever prefill they cost
    /// — the same reason `DictationPolisher` keeps one Hermes session rather
    /// than one per utterance.
    ///
    /// Rebuilt when the instructions change, which in practice means when the
    /// vocabulary does.
    #if canImport(FoundationModels)
    /// `Any?` rather than `LanguageModelSession?`, for the reason written out
    /// in `AddresseeJudge`: a stored property cannot be marked potentially
    /// unavailable, so naming the macOS 26 type here raised the floor for the
    /// entire app — over a dictation tier that is optional, and that falls
    /// back to Hermes when Apple's model is not there.
    private var sessionBox: Any?
    @available(macOS 26.0, *)
    private var session: LanguageModelSession? {
        get { sessionBox as? LanguageModelSession }
        set { sessionBox = newValue }
    }
    private var sessionInstructions: String?
    #endif

    var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
            #endif
            return false
        }
    }

    /// Available, or the reason it is not — in words someone can act on.
    ///
    /// The three states below all happened in sequence on one Mac in one
    /// afternoon: off, then downloading for some minutes, then ready. A pane
    /// that said only "unavailable" for all three would have been useless in
    /// every one of them.
    func status() async -> (ready: Bool, detail: String) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return (false, "Needs macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "Ready. Nothing you dictate leaves this Mac.")
        case .unavailable(let why):
            switch why {
            case .appleIntelligenceNotEnabled:
                return (false, "Apple Intelligence is off. Turn it on in System Settings.")
            case .modelNotReady:
                return (false, "Apple is still downloading the model. It will start working on its own.")
            case .deviceNotEligible:
                return (false, "This Mac cannot run Apple's on-device model.")
            @unknown default:
                return (false, "Not available on this Mac.")
            }
        @unknown default:
            return (false, "Not available on this Mac.")
        }
        #else
        return (false, "Not available on this system.")
        #endif
    }

    func warmUp() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), await isAvailable else { return }
        // Nothing to warm without knowing the instructions; the first polish
        // builds the session and prewarms it.
        #endif
    }

    func polish(_ text: String, prompt: PolishPrompt.Assembled,
                budget: TimeInterval) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), await isAvailable else { return nil }

        let session: LanguageModelSession
        if let existing = self.session, sessionInstructions == prompt.system {
            session = existing
        } else {
            session = LanguageModelSession(instructions: prompt.system)
            session.prewarm()
            self.session = session
            self.sessionInstructions = prompt.system
        }

        let started = Date()
        do {
            // The budget is enforced by the caller racing this; on-device
            // inference cannot be cancelled mid-token, so a slow one is
            // abandoned rather than stopped. It still costs nothing the user
            // waits for, because the caller has already moved on.
            let reply = try await session.respond(to: prompt.user)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.write("dictation: polished on-device in \(ms) ms")
            return reply.content
        } catch {
            // A refusal, a guardrail trip, a context overflow. Never fatal:
            // the router falls to the next tier, and the caller still has the
            // rule-cleaned text.
            Log.write("dictation: on-device polish failed (\(error.localizedDescription))")
            // A session that has thrown may be poisoned — a guardrail
            // violation sticks to the transcript it happened on. Drop it so
            // the next dictation starts clean.
            self.session = nil
            self.sessionInstructions = nil
            return nil
        }
        #else
        return nil
        #endif
    }
}
