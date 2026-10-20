import Foundation

/// The one meeting audio that outlives its summary is kept on purpose: a
/// short meeting whose transcript came out suspiciously thin keeps its WAVs as
/// evidence (`MeetingSummary.keepCeilingSeconds`). Each is bounded — 30
/// minutes, ~115 MB — but nothing bounded how many piled up. After
/// `maxAge` the evidence has had its chance to be looked at; the WAVs go, and
/// the record says so, the same way it does when the ceiling deletes them.
///
/// Only that case. A meeting that was never summarised keeps its audio — it
/// is what "redo the notes" runs on — and nothing else in the folder (the
/// transcript, the notes, the record) is touched.
public enum MeetingAudioJanitor {
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let wavs = ["system.wav", "mic.wav"]

    public static let deletedNote =
        "The recording was kept for 30 days because the transcript looked incomplete, then removed."

    /// Folder names whose kept audio was removed.
    @discardableResult
    public static func sweep(meetings: URL, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil) else {
            return []
        }
        var swept: [String] = []
        for folder in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let recordURL = folder.appendingPathComponent("meeting.json")
            guard var record = try? MeetingRecord.load(recordURL),
                  record.summarised, !record.recordingsDeleted,
                  record.recordingsKeptReason != nil,
                  now.timeIntervalSince(record.startedAt) > maxAge else { continue }
            let present = wavs.map { folder.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }
            guard !present.isEmpty else { continue }
            for url in present { try? fm.removeItem(at: url) }
            record.recordingsKeptReason = nil
            record.recordingsDeleted = true
            record.recordingsDeletedNote = deletedNote
            if let data = try? record.json() {
                try? data.write(to: recordURL)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            }
            swept.append(folder.lastPathComponent)
        }
        return swept
    }
}
