import Foundation
import Testing
@testable import MoeMeeting

/// Audio kept as evidence of a thin transcript goes after 30 days; every
/// other meeting's audio, and every meeting's notes, are left alone.
struct MeetingAudioJanitorTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let old = now.addingTimeInterval(-31 * 24 * 3600)
    static let recent = now.addingTimeInterval(-29 * 24 * 3600)

    private func meeting(in dir: URL, _ name: String, startedAt: Date, summarised: Bool,
                         kept: String?, deleted: Bool = false) throws -> URL {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var r = MeetingRecord(startedAt: startedAt, durationSeconds: 95, folder: folder.path)
        r.summarised = summarised
        r.recordingsKeptReason = kept
        r.recordingsDeleted = deleted
        try r.json().write(to: folder.appendingPathComponent("meeting.json"))
        for f in MeetingAudioJanitor.wavs + ["transcript.txt", "summary.md"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(f).path, contents: Data(count: 64))
        }
        return folder
    }

    private func exists(_ folder: URL, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }

    @Test("kept evidence older than 30 days: the WAVs go, the notes stay, the record says why")
    func oldEvidenceGoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try meeting(in: dir, "2026-08-01-1000", startedAt: Self.old, summarised: true,
                            kept: "one line in 95 seconds")

        #expect(MeetingAudioJanitor.sweep(meetings: dir, now: Self.now) == ["2026-08-01-1000"])

        #expect(!exists(m, "system.wav") && !exists(m, "mic.wav"))
        #expect(exists(m, "transcript.txt") && exists(m, "summary.md") && exists(m, "meeting.json"))
        let r = try MeetingRecord.load(m.appendingPathComponent("meeting.json"))
        #expect(r.recordingsDeleted)
        #expect(r.recordingsKeptReason == nil, "the pane must not still say the recording is kept")
        #expect(r.recordingsDeletedNote == MeetingAudioJanitor.deletedNote)
    }

    @Test("left alone: recent evidence, an unsummarised meeting, and one with no kept reason")
    func othersStay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recent = try meeting(in: dir, "recent", startedAt: Self.recent, summarised: true, kept: "thin")
        let unsummarised = try meeting(in: dir, "unsummarised", startedAt: Self.old, summarised: false, kept: nil)
        let normal = try meeting(in: dir, "normal", startedAt: Self.old, summarised: true, kept: nil)

        #expect(MeetingAudioJanitor.sweep(meetings: dir, now: Self.now).isEmpty)

        for m in [recent, unsummarised, normal] {
            #expect(exists(m, "system.wav") && exists(m, "mic.wav"), "\(m.lastPathComponent)")
        }
    }

    @Test("a missing meetings folder is nothing to do")
    func noFolder() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        #expect(MeetingAudioJanitor.sweep(meetings: dir, now: Self.now).isEmpty)
    }
}
