import Foundation

/// One line in moe.log for each stop, saying how long each part of it took:
///
///     stop: tts silent +3ms, capture closed +41ms, brain abandoned +2ms
///
/// A stop has three parts that finish on three different clocks — the voice
/// (synchronous), the microphone (behind the pipeline's queue) and the brain
/// (behind its own) — and "the stop worked" was, until this, a claim the log
/// could not check. A part that had nothing to do says so ("was silent",
/// "was closed", "was idle"); one that never answers within `limit` is
/// written as such rather than holding the line back forever.
@MainActor
final class StopReceipt {

    enum Part: CaseIterable, Sendable {
        case ttsSilent, captureClosed, brainAbandoned
    }

    /// A part's result: how long after the stop it was done, or that it had
    /// nothing to do.
    enum Mark: Equatable, Sendable {
        case after(ms: Int)
        case notApplicable
    }

    static let limit: TimeInterval = 3

    private let began: Date
    private var marks: [Part: Mark] = [:]
    private var written = false
    private let write: (String) -> Void

    init(began: Date = Date(), write: @escaping (String) -> Void = { Log.write($0) }) {
        self.began = began
        self.write = write
        // Holds itself until written: the receipt outlives the stop call.
        Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.limit * 1_000_000_000))
            self.finish()
        }
    }

    func mark(_ part: Part, applies: Bool, at now: Date = Date()) {
        guard marks[part] == nil, !written else { return }
        marks[part] = applies ? .after(ms: max(0, Int((now.timeIntervalSince(began) * 1000).rounded()))) : .notApplicable
        if marks.count == Part.allCases.count { finish() }
    }

    private func finish() {
        guard !written else { return }
        written = true
        write(Self.line(marks))
    }

    /// The log line for a set of marks; a missing one never answered.
    nonisolated static func line(_ marks: [Part: Mark]) -> String {
        func part(_ p: Part, _ name: String, _ idle: String) -> String {
            switch marks[p] {
            case .after(let ms)?: return "\(name) +\(ms)ms"
            case .notApplicable?: return idle
            case nil: return "\(name): no answer in \(Int(limit)) s"
            }
        }
        return "stop: " + [
            part(.ttsSilent, "tts silent", "tts was silent"),
            part(.captureClosed, "capture closed", "capture was closed"),
            part(.brainAbandoned, "brain abandoned", "brain was idle"),
        ].joined(separator: ", ")
    }
}
