import Foundation

/// The open ask, as the brain reports it: "I am working on this" at turn
/// start, "done" at the end, and whether the turn has reached for something
/// only this Mac has (`TaskPortability`). System words only — a task id, a
/// thread id, a flag, a status; the ask itself never travels this way. A
/// build with a cloud hands these to it (docs/AWAY-HANDOFF.md slice 2); a
/// build without one drops them.
struct BrainTaskReport: Equatable, Sendable {
    enum Op: String, Sendable { case open, done }
    let op: Op
    let task: String
    let thread: String
    var portable: Bool = true
    var status: String = "ok"
}
