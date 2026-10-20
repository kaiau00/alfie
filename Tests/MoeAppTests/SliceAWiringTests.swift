import Foundation
import Testing

/// The slice A rules (`QuietTurnPolicy`, `WakeOwnerCheck`) are pure and
/// tested in MoeVoiceTests; this pins that the engine and the cloud
/// recogniser actually consult them. Delete a call and this goes red.
struct SliceAWiringTests {

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theEngineConsultsEveryRule() throws {
        let engine = try Self.source("Sources/Moe/Voice/VoiceEngine.swift")
        for call in ["QuietTurnPolicy.isInvented(", "QuietTurnPolicy.liveWordsOutrankEmptyRead(",
                     "QuietTurnPolicy.onsetSoundsLikeSpeech(", "WakeOwnerCheck.refuses(",
                     "WakeOwnerCheck.mayFinishWordless(", "WakeOwnerCheck.stopsReplyAtHead",
                     "feed(.replyEndedWithQuestion("] {
            #expect(engine.contains(call), "VoiceEngine no longer calls \(call)")
        }
        #expect(!engine.contains("voice < 0.3"), "the fixed 0.3 owner refusal is back")
    }

    @Test func theCloudForgivesSilence() throws {
        let cloud = try Self.source("Sources/Moe/Speech/AssemblyAIBackend.swift")
        #expect(cloud.contains("QuietTurnPolicy.isSilent(rms:"))
    }
}
