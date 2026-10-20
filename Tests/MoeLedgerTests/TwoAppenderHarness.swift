import Foundation
import CryptoKit
import MoeChat
@testable import MoeLedger

// The harness slice two's tests are written against: two appenders, a clock
// a test drives by hand, and a relay that decides exactly which records reach
// the other side, in what order, and how many times.
//
// There is no transport in here and there is not meant to be. `Relay` moves
// records by calling `Ledger.adopt`, which is the same call a real push or
// pull would end in; what a network would add is latency, partial delivery,
// duplication and reordering, and all four are things a test wants to *say*
// rather than wait for.

/// A clock a test drives, so three days happen in an afternoon.
///
/// One per appender, because the whole point of two appenders is that there
/// is no shared clock. Setting them to different instants is how a test says
/// "these two machines disagree about what time it is", which is not an edge
/// case — it is every pair of machines.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date

    init(_ start: Date) { self.t = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return t
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        t += interval
    }

    func set(_ instant: Date) {
        lock.lock()
        defer { lock.unlock() }
        t = instant
    }

    /// A distinct instant every time it is asked. For the concurrency tests,
    /// where two threads must not be able to collide on `at` — a tie there
    /// would make the expected order a coin toss rather than a fact, and the
    /// property under test is that both readers agree, whatever the order is.
    func distinct() -> Date {
        lock.lock()
        defer { lock.unlock() }
        t += 0.001
        return t
    }
}

/// One runtime: its own device id, its own clock, its own projection.
///
/// The projection directory is per-appender even when the ledger is shared,
/// because §1.3 is about a projection having one writer, not about there
/// being one projection. Two runtimes each render their own
/// `conversations/`; that they render the *same* one from the same records is
/// the property this slice exists to test, and it cannot be tested by having
/// them write the same files.
struct Appender {
    let name: String
    let root: URL
    let ledger: Ledger
    let store: ConversationStore
    let conversations: ConversationLedger
    let clock: FakeClock

    var keyring: ThreadKeyring { conversations.keyring }
    var projector: ConversationProjector { conversations.projector }

    static func make(name: String, root: URL, ledgerDirectory: URL,
                     clock: FakeClock,
                     distinctInstants: Bool = false) -> Appender {
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let tick: @Sendable () -> Date = { distinctInstants ? clock.distinct() : clock.now }
        let ledger = Ledger(directory: ledgerDirectory, device: name, clock: tick)
        return Appender(name: name, root: root, ledger: ledger, store: store,
                        conversations: ConversationLedger(ledger: ledger, store: store),
                        clock: clock)
    }

    /// Say something in a thread, as this appender.
    ///
    /// Turn ids are the caller's, not a UUID: two appenders writing the same
    /// thread have to be talked about by name in the assertions, and a test
    /// that cannot name a turn cannot say which order it expected them in.
    @discardableResult
    func say(_ text: String, in thread: String, turn: String,
             role: ConversationStore.StoredTurn.Role = .you,
             startedAt: Date? = nil, tools: [String]? = nil) throws
        -> ConversationStore.Conversation {
        let existing = projector.project(thread: thread)
        var turns = existing?.turns ?? []
        turns.append(.init(id: turn, role: role, text: text, at: clock.now, tools: tools))
        let conversation = ConversationStore.Conversation(
            id: thread,
            startedAt: existing?.startedAt ?? startedAt ?? clock.now,
            updatedAt: clock.now, turns: turns)
        try conversations.save(conversation)
        return conversation
    }

    /// A record from one of the background jobs that keep running while a
    /// Mac is "offline" — the hourly digest, the learn crawl, the connectors.
    ///
    /// They are real `claim` records now (§14; slice two wrote a placeholder
    /// body because nothing read one). They still belong in the three-day
    /// test for the reason they always did — hundreds of records that must
    /// take part in ordering and convergence without disturbing a single
    /// conversation — and they now also put §3.1's claim rules under a few
    /// hundred records rather than the handful a focused test writes.
    @discardableResult
    func background(_ source: String, _ key: String, _ value: String,
                    target: String = "memory") throws -> LedgerRecord {
        try ledger.append(
            kind: LedgerRecord.Kind.claim,
            body: Claim.body(op: Claim.Op.assert,
                             id: Claim.id(target: target, text: value),
                             target: target, key: key, source: source, text: value))
    }

    /// Learn a fact, as this appender, through the same writer the app uses.
    ///
    /// `after` is what this side had already seen. Passed explicitly in most
    /// tests rather than left to `ClaimLedger.frontier()`, because the whole
    /// question these tests ask is *what each side knew when it wrote*, and a
    /// test that cannot say that cannot say which rule it expected to fire.
    @discardableResult
    func learn(_ text: String, key: String? = nil, source: String,
               target: String = "memory", after: [String]? = nil) throws -> LedgerRecord? {
        try claims.assert(text, target: target, key: key, source: source, after: after)
    }

    @discardableResult
    func forget(_ text: String, source: String, target: String = "memory",
                after: [String]? = nil) throws -> LedgerRecord? {
        try claims.retract(text, target: target, source: source, after: after)
    }

    /// What this side would show in `MEMORY.md`, and what it would ask about.
    func memory(_ target: String = "memory") -> Claim.Projection {
        claims.resolve(target: target)
    }
}

extension Appender {
    /// This appender's claim writer. A struct, so it is cheap to make and
    /// holds nothing the ledger does not already hold.
    var claims: ClaimLedger { ClaimLedger(ledger: ledger) }
}

/// Test-only carriage of records between two ledgers.
///
/// Slice two has no network in it by design, so this is where a test says
/// what a network would have done to it.
enum Relay {

    /// Everything `from` holds, in its own order.
    static func records(of appender: Appender) -> [LedgerRecord] { appender.ledger.all() }

    /// Deliver records, returning how many were new. Nothing here checks
    /// whether the other side already has them: `adopt` is content-addressed
    /// and idempotent, and proving that is one of the cases.
    @discardableResult
    static func deliver(_ records: [LedgerRecord], to appender: Appender) throws -> Int {
        var adopted = 0
        for record in records {
            if try appender.ledger.adopt(record) { adopted += 1 }
        }
        return adopted
    }

    /// Both directions, once each. What "and then they both came back"
    /// means.
    static func sync(_ a: Appender, _ b: Appender) throws {
        let fromA = records(of: a)
        let fromB = records(of: b)
        try deliver(fromA, to: b)
        try deliver(fromB, to: a)
    }

    /// The key exchange the design has not designed yet.
    ///
    /// §12's first undecided question is how a thread key reaches a second
    /// device, and slice 3 cannot ship without an answer. Nothing in this
    /// slice builds one. Tests that need the other side to be *able* to read
    /// a thread call this and say so; tests about what happens when it cannot
    /// do not call it, which is the honest default.
    static func handKey(for thread: String, from a: Appender, to b: Appender) throws {
        guard let key = a.keyring.key(for: thread) else { return }
        try b.keyring.install(key, for: thread)
    }
}

/// What "identical, not similar" means, as a list of the ways it is not.
///
/// Empty is the assertion. Everything in here is an id, a count or a field
/// name — never a turn's text, so a failure prints what diverged rather than
/// somebody's conversation.
enum Convergence {

    static func between(_ a: Appender, _ b: Appender) -> [String] {
        var out: [String] = []

        let orderA = a.ledger.all()
        let orderB = b.ledger.all()
        if orderA.map(\.id) != orderB.map(\.id) {
            out.append("ledger order: \(a.name) has \(orderA.count) records, "
                       + "\(b.name) has \(orderB.count); first difference at index "
                       + "\(firstDifference(orderA.map(\.id), orderB.map(\.id)))")
        }

        // Reading the same bytes cold must give the same answer as reading
        // them as they arrived. The incremental read is an optimisation, and
        // an optimisation that changes the order changes the conversation.
        for side in [a, b] {
            let cold = Ledger(directory: side.ledger.directory, device: side.name).all()
            if cold.map(\.id) != side.ledger.all().map(\.id) {
                out.append("\(side.name): a cold reader disagrees with the warm one at index "
                           + "\(firstDifference(cold.map(\.id), side.ledger.all().map(\.id)))")
            }
        }

        let threadsA = Set(a.projector.threads())
        let threadsB = Set(b.projector.threads())
        if threadsA != threadsB {
            out.append("threads: only \(a.name) has \(threadsA.subtracting(threadsB).sorted()), "
                       + "only \(b.name) has \(threadsB.subtracting(threadsA).sorted())")
        }

        for thread in threadsA.union(threadsB).sorted() {
            let projectedA = a.projector.project(thread: thread)
            let projectedB = b.projector.project(thread: thread)
            guard projectedA != projectedB else { continue }
            switch (projectedA, projectedB) {
            case (nil, .some): out.append("thread \(thread): only \(b.name) projects it")
            case (.some, nil): out.append("thread \(thread): only \(a.name) projects it")
            case let (.some(x), .some(y)):
                if x.turns.map(\.id) != y.turns.map(\.id) {
                    out.append("thread \(thread): turn order \(x.turns.map(\.id)) vs \(y.turns.map(\.id))")
                } else if x.startedAt != y.startedAt {
                    out.append("thread \(thread): startedAt \(x.startedAt) vs \(y.startedAt)")
                } else if x.updatedAt != y.updatedAt {
                    out.append("thread \(thread): updatedAt \(x.updatedAt) vs \(y.updatedAt)")
                } else {
                    out.append("thread \(thread): turns differ in a field other than id or time")
                }
            case (nil, nil): break
            }
        }
        return out
    }

    /// The same comparison made against the files rather than the objects:
    /// both sides rebuild `conversations/` from records and must produce the
    /// same set of threads with the same bytes in them.
    static func onDisk(_ a: Appender, _ b: Appender) throws -> [String] {
        _ = try a.conversations.rebuild()
        _ = try b.conversations.rebuild()
        var out: [String] = []
        let filesA = Dictionary(uniqueKeysWithValues: a.store.all().map { ($0.id, $0) })
        let filesB = Dictionary(uniqueKeysWithValues: b.store.all().map { ($0.id, $0) })
        if Set(filesA.keys) != Set(filesB.keys) {
            out.append("projected threads: only \(a.name) has "
                       + "\(Set(filesA.keys).subtracting(filesB.keys).sorted()), only \(b.name) has "
                       + "\(Set(filesB.keys).subtracting(filesA.keys).sorted())")
        }
        for id in Set(filesA.keys).intersection(filesB.keys) where filesA[id] != filesB[id] {
            out.append("projected thread \(id) differs")
        }
        return out
    }

    private static func firstDifference(_ a: [String], _ b: [String]) -> String {
        for (i, pair) in zip(a, b).enumerated() where pair.0 != pair.1 { return "\(i)" }
        return a.count == b.count ? "none" : "\(min(a.count, b.count)) (length)"
    }
}

/// A root nobody else is using. Never `~/.moe`.
func scratchRoot(_ label: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("moe-\(label)-\(UUID().uuidString)", isDirectory: true)
}
