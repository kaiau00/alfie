import Foundation
import Testing
@testable import MoeIsland

/// A job Moe handed off finishes while the person is doing something else.
/// The gateway offers the result to moe-screen (`deliver_detached_completion`),
/// which spools it into the inbox as `kind: "turn"`; the app runs a turn on
/// it so Moe says the outcome in its own words. And nothing Moe says about a
/// long job is a stock line any more.
///
/// The Mac app has no unit-test target that can drive a Conductor, so these
/// read the source the way `NudgeHandleWiringTests` does. Each one fails if
/// the wiring it names is removed.
struct FinishedHelperWiringTests {

    private static let conductor: String? = source("Sources/Moe/Conductor.swift")
    private static let channels: String? = source("Sources/Moe/Settings/ReminderChannels.swift")
    private static let prompt: String? = source("Sources/Moe/Brain/BrainPrompt.swift")
    private static let completions: String? = source("moe-home/hermes-plugins/moe-screen/completions.py")
    private static let adapter: String? = source("moe-home/hermes-plugins/moe-screen/adapter.py")

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theInboxReaderCarriesTheKind() throws {
        let source = try #require(Self.channels)
        #expect(source.contains("kind: obj[\"kind\"] as? String ?? \"\""),
                "ReminderChannels stopped reading `kind` out of the inbox file.")
    }

    @Test func aFinishedHelperIsATurnNotANudge() throws {
        let source = try #require(Self.conductor)
        #expect(source.contains("queued.filter { $0.kind == \"turn\" }") && source.contains("reportFinishedHelper(m.text)"),
                "drainInbox no longer turns a kind=turn message into a turn.")
        #expect(source.contains("for m in queued where m.kind != \"turn\""),
                "a finished helper's result would be kept as an inbox item instead of answered.")
        #expect(source.contains("func reportFinishedHelper(_ result: String)"))
        #expect(source.contains("origin: .spoken, starter: .background, outgoing:"),
                "the helper's report must be spoken and hand the brain the result, not show it as the person's words.")
        #expect(source.contains("outgoing outgoingOverride: String? = nil"),
                "submit lost the outgoing override the helper report relies on.")
    }

    @Test func thePluginSpoolsAFinishedHelperAsATurn() throws {
        let completions = try #require(Self.completions)
        let adapter = try #require(Self.adapter)
        #expect(completions.contains("def deliver_detached_completion("))
        #expect(completions.contains("kind=\"turn\""))
        #expect(adapter.contains("ctx.register_hook(\"deliver_detached_completion\""),
                "moe-screen no longer registers the hook the gateway offers a finished helper to.")
    }

    @Test func nothingCannedIsSpokenAboutAJob() throws {
        let source = try #require(Self.conductor)
        #expect(!source.contains("stillWorkingLines"), "the stock 'Still on it' lines are back.")
        #expect(!source.contains("SpokenStep.continuing("), "'Still <step>' repeats are back.")
        #expect(!source.contains("say(phrase + \".\")"), "the step table is spoken again.")
    }

    @Test func theBrainIsAskedToHandOffAndToUseItsOwnWords() throws {
        let source = try #require(Self.prompt)
        #expect(source.contains("hand it off with your \\\n    delegation tool") || source.contains("hand it off with your delegation tool"),
                "the prompt no longer tells the brain to hand a background job off.")
        #expect(source.contains("no \"still on it\""), "the prompt no longer forbids stock progress lines.")
    }
}
