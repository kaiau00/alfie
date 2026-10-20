import Foundation
import Testing

/// The premium voice's two free latency wins, pinned where they are wired.
///
/// The behaviour is tested in MoeVoice against fakes and measured audio —
/// `InworldSessionTests` (re-warm at turn start) and `TrailingSilenceTests`
/// (the tail off a reply). What these pin is that the app calls them: the
/// engine, the player and the audio graph are in the executable target, and
/// a `SpeechOut` cannot be built without a live audio device.
struct InworldPolishWiringTests {

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func slice(_ source: String, from start: String, to end: String) -> Substring? {
        guard let a = source.range(of: start) else { return nil }
        let rest = source[a.upperBound...]
        guard let b = rest.range(of: end) else { return nil }
        return rest[..<b.lowerBound]
    }

    /// Capture opening — a wake, a held key, a barge-in — is when the cloud
    /// socket is re-warmed, so the connect overlaps the person talking.
    @Test func aNewCaptureRewarmsTheCloudVoice() throws {
        let engine = try #require(Self.source("Sources/Moe/Voice/VoiceEngine.swift"))
        let opening = try #require(Self.slice(engine, from: "case .capture(let on):", to: "captureOn = on"))
        #expect(opening.contains("if on, !captureOn {"))
        #expect(opening.contains("tts.isCloudBackend"))
        #expect(opening.contains("await tts.prepareForTurn()"))

        let backend = try #require(Self.source("Sources/Moe/Voice/InworldBackend.swift"))
        let prepare = try #require(Self.slice(backend, from: "func prepareForTurn() async {", to: "\n    }\n"))
        #expect(prepare.contains("session.prepareForTurn()"))
    }

    /// The cloud render trims each generation's tail, puts it back in front
    /// of a following generation, and drops it before "done speaking".
    @Test func theCloudRenderTrimsAndTheReplyEndDropsTheTail() throws {
        let speech = try #require(Self.source("Sources/Moe/Voice/SpeechOut.swift"))
        let render = try #require(Self.slice(speech, from: "private func render(", to: "private func takeHeldTail("))
        #expect(render.contains("backend.isCloudBackend"))
        #expect(render.contains("TrailingSilence(sampleRate: rate)"))
        #expect(render.contains("trimmer!.push(frame)"))
        #expect(render.contains("trimmer!.finish()"))
        #expect(render.contains("heldTail = HeldTail("))
        #expect(render.contains("takeHeldTail(rate: rate)"))

        let pumpEnd = try #require(Self.slice(speech, from: "if self.scheduledSamples <= 0 { break }",
                                              to: "self.onIdle?()"))
        #expect(pumpEnd.contains("self.heldTail = nil"))
    }
}
