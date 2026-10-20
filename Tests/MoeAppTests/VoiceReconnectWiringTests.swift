import Foundation
import Testing
import MoeVoice
@testable import Moe

/// The premium voice coming back after a blip, pinned where it is wired.
/// The rules are tested beside them — the backoff in `CloudVoiceTests`
/// (MoeCloud), the notice in `PremiumVoiceReconnectTests` (MoeVoice); the
/// player cannot run without an audio device, so what these pin is that
/// `SpeechOut` and `CloudVoice` consult those rules, and where.
struct VoiceReconnectWiringTests {

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func slice<S: StringProtocol>(_ source: S, from start: String, to end: String) -> String? {
        let text = String(source)
        guard let a = text.range(of: start) else { return nil }
        let rest = text[a.upperBound...]
        guard let b = rest.range(of: end) else { return nil }
        return String(rest[..<b.lowerBound])
    }

    @Test("the edge not answering is a dropped connection; the other refusals are not")
    func offlineIsTheConnection() {
        #expect(CloudVoiceUnavailable.offline.isConnectionDrop)
        #expect(PremiumVoiceReconnect.isConnectionDrop(CloudVoiceUnavailable.offline))
        for other in [CloudVoiceUnavailable.notEntitled, .allowanceSpent(resetsAt: nil),
                      .notConfigured("x"), .disabled] {
            #expect(!PremiumVoiceReconnect.isConnectionDrop(other), "\(other) read as a dropped connection")
        }
    }

    @Test("a failed cloud sentence feeds the episode, and only its first says anything")
    func failureIsSaidOnce() throws {
        let speech = try Self.source("Sources/Moe/Voice/SpeechOut.swift")
        let render = try #require(Self.slice(speech, from: "private func render(", to: "private func takeHeldTail("))
        let caught = try #require(Self.slice(render, from: "} catch {", to: "Log.write(\"TTS FAILED"))
        #expect(caught.contains("case .connection(let notice) = reconnect.failed(error)"))
        let said = try #require(Self.slice(caught, from: "reconnect.failed(error)", to: "// The sentence is not dropped"))
        #expect(said.contains("if let notice {"), "the notice would be given every sentence")
        #expect(said.contains("onNotice?(notice)"))
        // The out-of-credits rule is untouched and still first.
        let spent = try #require(caught.range(of: "PremiumVoiceSpent.matches(error)"))
        let drop = try #require(caught.range(of: "reconnect.failed(error)"))
        #expect(spent.lowerBound < drop.lowerBound)
    }

    @Test("the voice coming back is logged, never announced")
    func recoveryIsQuiet() throws {
        let speech = try Self.source("Sources/Moe/Voice/SpeechOut.swift")
        let back = try #require(Self.slice(speech, from: "// Credits back: a later run-out is news again.", to: "if underruns > 0"))
        #expect(back.contains("reconnect.succeeded()"))
        #expect(back.contains("Log.write(\"tts: premium voice back after"))
        #expect(!back.contains("onNotice"), "the voice coming back must not interrupt with a notice")
        #expect(speech.contains("reconnect.reset()"), "a reloaded voice inherits the old one's stretch")
    }

    /// The engine is chosen once per render — at its start, a sentence or
    /// batch boundary — and never inside the loop that plays it. A failure
    /// re-renders whole pieces on the local engine, and a recovery takes
    /// effect at the next render, never partway through this one.
    @Test("no engine switch inside a sentence")
    func engineIsChosenAtTheBoundary() throws {
        let speech = try Self.source("Sources/Moe/Voice/SpeechOut.swift")
        let render = try #require(Self.slice(speech, from: "private func render(", to: "private func takeHeldTail("))
        let playing = try #require(Self.slice(render, from: "for try await frame in stream {", to: "// The end of the generation"))
        for word in ["reconnect", "localFallback", "CloudVoice", "mayUse", "backend.stream", "via:"] {
            #expect(!playing.contains(word), "the playing loop consults \(word) — an engine could change mid-sentence")
        }
        let fallback = try #require(Self.slice(render, from: "if override == nil, let local = localFallback", to: "Log.write(\"TTS FAILED"))
        #expect(fallback.contains("SpeechBatch.forLocalEngine(whole)"))
        #expect(fallback.contains("via: local"))
    }
}
