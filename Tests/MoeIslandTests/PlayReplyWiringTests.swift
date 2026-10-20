import Foundation
import Testing

/// ▶ on a reply in the chat, 2026-09-23: "there should be a way to play that
/// message that he sent to you so he can talk back to you."
///
/// Read from source for the reason `NudgeHandleWiringTests` gives: the
/// Conductor and the chat pane are in an executable target Swift cannot
/// import. The behaviour — that a tap pauses what ▶ started — is
/// `PausingTheReplyTests`; these pin the calls that route ▶ into it.
struct PlayReplyWiringTests {

    private static func source(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func body(of signature: String, in source: String) -> Substring? {
        guard let start = source.range(of: signature) else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test func thePaneRoutesPlayPauseAndRestartToTheConductor() throws {
        let pane = try #require(Self.source("Sources/Moe/Chat/ChatPane.swift"))
        #expect(pane.contains("conductor.playPauseReply(turn.id)"))
        #expect(pane.contains("conductor.restartReply()"))
        #expect(pane.contains("voiceState: conductor.voiceState(of: turn.id)"))
    }

    /// The owner, 2026-09-23: "I press the play button, then I pause it,
    /// and I press the play button again, and it restarts it." ▶ on a
    /// paused reply must resume it, never play it from the top.
    @Test func playOnAPausedReplyResumesIt() throws {
        let conductor = try #require(Self.source("Sources/Moe/Conductor.swift"))
        let pp = try #require(Self.body(of: "func playPauseReply(_ id: UUID) {", in: conductor))
        let paused = try #require(pp.range(of: "case .paused:"))
        let line = pp[paused.upperBound...].prefix(while: { $0 != "\n" })
        #expect(line.contains("resumeReply()"))
        #expect(!line.contains("playReply"))
        let resume = try #require(Self.body(of: "func resumeReply() {", in: conductor))
        #expect(resume.contains("voice.pauseReply(false)"))
    }

    /// The island has the same three, on the reply being said.
    @Test func theIslandHasPauseResumeAndRestart() throws {
        let island = try #require(Self.source("Sources/Moe/IslandView.swift"))
        // In the dropdown's tray (IslandTray, 2026-09-24): pause or resume
        // and start over whenever a reply's voice is out.
        #expect(island.contains("case .pause, .resume:"))
        #expect(island.contains("conductor.playPauseReply(id)"))
        #expect(island.contains("conductor.restartReply()"))
    }

    /// A tap of the key reaches the voice as a tap. Its release arrives a
    /// double-tap window late, so timing it read every tap as a hold: the
    /// reply was cut and "Yeah" — the recogniser's reading of silence — was
    /// sent as a question (2026-09-23 16:40:59).
    @Test func aTapOfTheKeyArrivesAsATap() throws {
        let app = try #require(Self.source("Sources/Moe/AppDelegate.swift"))
        #expect(app.contains("self?.conductor.holdEnded(tap: true)"))
        let conductor = try #require(Self.source("Sources/Moe/Conductor.swift"))
        #expect(conductor.contains("Task { await voice.endHold(tap: tapped) }"))
        let engine = try #require(Self.source("Sources/Moe/Voice/VoiceEngine.swift"))
        #expect(engine.contains("if tap || held < tapSeconds {"))
        let ptt = try #require(Self.source("Sources/Moe/PushToTalk.swift"))
        #expect(ptt.contains("case .tap:       if let onTap { onTap() } else { onRelease?() }"))
    }

    /// Spoken as a reply is — with offsets — or a tap has nothing to resume
    /// from (`SpeechOut.carriesReply`) and the pause becomes a stop.
    @Test func playReplySpeaksWithOffsets() throws {
        let conductor = try #require(Self.source("Sources/Moe/Conductor.swift"))
        let play = try #require(Self.body(of: "func playReply(_ id: UUID) {", in: conductor))
        #expect(play.contains("speakToEnd(of: turn.text)"))
        #expect(play.contains("replayingTurnID = id"))
        #expect(!play.contains("voice.speak(turn.text)"), "a bare speak carries no offsets")
    }

    /// The resume after a tap goes back to the reply ▶ started, not to
    /// whichever reply happens to be last.
    @Test func aResumeFindsTheReplayFirst() throws {
        let conductor = try #require(Self.source("Sources/Moe/Conductor.swift"))
        let resume = try #require(Self.body(of: "private func resumeSpokenReply() {", in: conductor))
        let replay = try #require(resume.range(of: "replayingTurnID"))
        let usual = try #require(resume.range(of: "guard replySpeaks"))
        #expect(replay.lowerBound < usual.lowerBound)
    }
}
