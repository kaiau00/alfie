import Foundation
import MoeVoice

/// The wake threshold this Mac settled on, and the measurement that
/// chose it. Written by Settings › Voice › "Teach Moe its name"; read by
/// `WakeHead.load` beside the shipped sidecar, so the number survives a
/// relaunch and an update — the sidecar is the model's, this is the
/// person's. Lives in `~/Library/Application Support/Moe/voice/`, next
/// to the owner-voice centroid and the recordings it was measured on.
struct WakeTuning: Codable, Equatable {
    var threshold: Float
    var measured: Date
    var pick: Pick
    /// The head it was measured on: the sidecar's `trained` stamp. A
    /// threshold is a line through one model's scores, so a new head
    /// ignores it (`WakeCalibration.tuningApplies`) — v5's 0.9 on v6, whose
    /// scores stop near 0.85, would have silenced the wake word. Absent in
    /// files written before 2026-09-23.
    var head: String?

    /// `WakeCalibration.Pick`, as JSON.
    struct Tally: Codable, Equatable {
        var positives: Int, caught: Int, confusables: Int, falseAccepts: Int
        init(_ t: WakeCalibration.Tally) {
            positives = t.positives; caught = t.caught; confusables = t.confusables; falseAccepts = t.falseAccepts
        }
        var value: WakeCalibration.Tally {
            .init(positives: positives, caught: caught, confusables: confusables, falseAccepts: falseAccepts)
        }
    }
    struct Pick: Codable, Equatable {
        var after: Tally, before: Tally
    }

    init(_ pick: WakeCalibration.Pick, head: String?, measured: Date = Date()) {
        threshold = pick.threshold
        self.head = head
        self.measured = measured
        self.pick = Pick(after: Tally(pick.after), before: Tally(pick.before))
    }

    var calibration: WakeCalibration.Pick {
        .init(threshold: threshold, after: pick.after.value, before: pick.before.value)
    }

    static let file = Config.homeDir
        .appendingPathComponent("voice", isDirectory: true)
        .appendingPathComponent("wake-threshold.json")

    /// What is on disk for `head`, or nil. A threshold outside (0, 1) is
    /// not a setting, and one measured on another head does not apply;
    /// both are ignored as if the file were absent. The file stays: the
    /// next "Teach Moe its name" overwrites it, from the same recordings.
    static func load(for head: String?) -> WakeTuning? {
        guard let data = try? Data(contentsOf: file),
              let t = try? decoder.decode(WakeTuning.self, from: data),
              t.threshold > 0, t.threshold < 1,
              WakeCalibration.tuningApplies(tunedFor: t.head, head: head) else { return nil }
        return t
    }

    /// What is on disk for the head this copy of Moe ships.
    static func load() -> WakeTuning? {
        load(for: WakeHead.shippedIdentity())
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// The note under the row: when it was measured and what it found.
    var note: String {
        let f = DateFormatter()
        f.dateStyle = .long; f.timeStyle = .none
        return "Measured \(f.string(from: measured)): \(WakeCalibration.summary(calibration, changed: true))"
    }
}
