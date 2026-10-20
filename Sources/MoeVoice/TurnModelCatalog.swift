import CryptoKit
import Foundation

/// Which Smart Turn file Moe loads, and where it comes from.
///
/// Today one model: **smart-turn-v3.2**, Pipecat's own (BSD-2), fetched once
/// from Hugging Face into `<Moe home>/models/smart-turn/` the first time voice
/// starts and checked by size ("plausibly a model"), so an upstream re-upload
/// under the same name is picked up rather than refused forever.
///
/// The catalog exists so a better turn model can be put in front of v3.2
/// without losing it: list it first in `preference` with its SHA-256 (ours
/// never changes under a name, so a file that does not hash is not it) and
/// v3.2 stays the fallback whenever it cannot be fetched, verified or opened.
/// A fine-tune of v3.2 for "a complete clause, a breath, more coming" was
/// trained on 2026-09-23/24 and did **not** earn that place: it improved
/// neither the turn bench nor eot-bench without costing the public test set
/// (~/moe-voice-notes/smart-turn-ft.md). `MOE_TURN_MODEL` pins any model by
/// name or path, which is how the benches measure a candidate without
/// touching the one the app uses.
public enum TurnModelCatalog {

    public struct Model: Equatable, Sendable {
        /// Short name for logs and the turn trace.
        public let name: String
        /// File name under `models/smart-turn/`.
        public let file: String
        public let url: URL
        /// Hex SHA-256 of the file; nil means "size-checked only" (upstream's,
        /// which may be re-uploaded under the same name).
        public let sha256: String?
        public let bytes: Int
    }

    public static let upstream = Model(
        name: "smart-turn-v3.2",
        file: "smart-turn-v3.2-cpu.onnx",
        url: URL(string: "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx")!,
        sha256: nil,
        bytes: 8_679_182)

    /// Preference order. The first that is on disk (or downloads), verifies
    /// and loads is the one used.
    public static let preference: [Model] = [upstream]

    /// `MOE_TURN_MODEL=smart-turn-v3.2` (or a path to an .onnx) pins one —
    /// for the benches, which must say which model they measured.
    public static func order(override: String?) -> [Model] {
        guard let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty else { return preference }
        if let m = preference.first(where: { $0.name == o || $0.file == o }) { return [m] }
        let url = URL(fileURLWithPath: (o as NSString).expandingTildeInPath)
        return [Model(name: url.deletingPathExtension().lastPathComponent, file: url.path,
                      url: url, sha256: nil, bytes: 0)]
    }

    /// How a launch loads: whatever is already on disk first, in preference
    /// order, so voice never waits on the network for a model it has; then
    /// the rest, downloaded, in order. The models preferred over the first
    /// one on disk are fetched in the background for next time (`fetchLater`)
    /// — how a Mac holding only v3.2 would come to a model listed before it.
    public struct LoadPlan: Equatable, Sendable {
        public struct Attempt: Equatable, Sendable {
            public let model: Model
            public let download: Bool
        }
        public let attempts: [Attempt]
        public let fetchLater: [Model]
    }

    public static func loadPlan(_ order: [Model], onDisk: (Model) -> Bool) -> LoadPlan {
        let here = order.filter(onDisk)
        let away = order.filter { !onDisk($0) }
        let attempts = here.map { LoadPlan.Attempt(model: $0, download: false) }
            + away.map { LoadPlan.Attempt(model: $0, download: true) }
        var later: [Model] = []
        if let first = here.first {
            later = Array(order.prefix(while: { $0 != first }))
        }
        return LoadPlan(attempts: attempts, fetchLater: later)
    }

    /// Is this file the model it claims to be? Plausibly a model (over 1 MB),
    /// and exactly its hash when the catalog pins one.
    public static func accepts(_ model: Model, data: Data) -> Bool {
        guard data.count > 1_000_000 else { return false }
        guard let want = model.sha256 else { return true }
        return sha256Hex(data) == want.lowercased()
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
