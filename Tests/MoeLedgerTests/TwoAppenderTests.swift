import Foundation
import CryptoKit
import Testing
import MoeChat
@testable import MoeLedger

/// Slice two: two appenders, one ledger.
///
/// Slice one proved a person's own history could be reconstructed from
/// records on one machine. This is the slice that asks whether *two* things
/// writing records can be relied on to agree, and it asks it here, on one
/// machine, with no network, because a distributed bug found over a loopback
/// costs an afternoon and the same bug found after the cloud is built costs a
/// rewrite.
///
/// **How the two appenders are modelled.** Two ways, deliberately, because
/// the two halves of the design fail differently.
///
/// *Two instances over one ledger directory* is the literal thing §10 asks
/// for — a second Hermes profile against the same `~/.moe/ledger`. Each has
/// its own device id, its own `seq` chain, its own file, its own parse cache
/// and its own projection directory, and they are driven from real
/// concurrent threads. This is what exercises the concurrency: two writers
/// appending while two readers are mid-parse of each other's files, which is
/// the case where the incremental read either agrees with a cold one or
/// silently does not.
///
/// *Two ledger directories with a relay between them* is the Mac and the
/// cloud, and it is the only way to say the things that actually matter
/// later: one side offline for days, records arriving out of order, records
/// arriving twice, a thread whose key never crossed. A shared directory
/// cannot express any of those, because both sides see every byte the
/// instant it is written — convergence there is nearly a tautology.
///
/// Not two processes. The design gives every device its own file, so two
/// processes never contend on one file for appends, and the one thing a
/// second process would add over a second instance — that the `head` cache
/// and the parse cache are not shared — is exactly what two instances with
/// two device ids already have. What a second process *would* catch is
/// covered by `twoRuntimesThatShareADeviceIDForkItsChain` below, which is
/// about identity rather than about processes.
struct TwoAppenderTests {

    // A Sunday evening, so the three-day case has somewhere to start.
    private let sunday = Date(timeIntervalSince1970: 1_756_000_000)

    /// Two appenders over one ledger directory.
    private func shared(_ label: String, distinctInstants: Bool = false)
        -> (a: Appender, b: Appender, ledgerDirectory: URL) {
        let root = scratchRoot(label)
        let dir = root.appendingPathComponent("ledger")
        let a = Appender.make(name: "mac-one", root: root.appendingPathComponent("one"),
                              ledgerDirectory: dir, clock: FakeClock(sunday),
                              distinctInstants: distinctInstants)
        let b = Appender.make(name: "mac-two", root: root.appendingPathComponent("two"),
                              ledgerDirectory: dir, clock: FakeClock(sunday),
                              distinctInstants: distinctInstants)
        return (a, b, dir)
    }

    /// Two appenders, each with its own ledger, and nothing between them but
    /// what a test hands over.
    private func replicas(_ label: String) -> (mac: Appender, cloud: Appender) {
        let root = scratchRoot(label)
        let mac = Appender.make(name: "mac-9f3c", root: root.appendingPathComponent("mac"),
                                ledgerDirectory: root.appendingPathComponent("mac/ledger"),
                                clock: FakeClock(sunday))
        let cloud = Appender.make(name: "cloud-w7", root: root.appendingPathComponent("cloud"),
                                  ledgerDirectory: root.appendingPathComponent("cloud/ledger"),
                                  clock: FakeClock(sunday))
        return (mac, cloud)
    }

    // MARK: - Two appenders, one directory

    @Test func twoAppendersOnOneDirectoryKeepTheirOwnChains() throws {
        let (a, b, dir) = shared("two-chains")
        for i in 0..<5 {
            a.clock.advance(60)
            try a.say("mac one, \(i)", in: "th-shared", turn: "a\(i)")
            b.clock.advance(60)
            try b.say("mac two, \(i)", in: "th-shared", turn: "b\(i)")
        }

        // One file each. The design's reason for that is here: neither
        // appender ever writes a byte into the other's chain.
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.map(\.lastPathComponent).sorted()
        #expect(files == ["mac-one.jsonl", "mac-two.jsonl"])

        #expect(a.ledger.gapsForThisDevice().isEmpty)
        #expect(b.ledger.gapsForThisDevice().isEmpty)
        #expect(a.ledger.forkedSeqsForThisDevice().isEmpty)
        #expect(b.ledger.forkedSeqsForThisDevice().isEmpty)

        let all = a.ledger.all()
        #expect(all.count == 10)
        #expect(Set(all.map(\.id)).count == 10)
        #expect(all.filter { $0.device == "mac-one" }.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(all.filter { $0.device == "mac-two" }.map(\.seq) == [1, 2, 3, 4, 5])
    }

    @Test func aThreadWrittenOnBothSidesProjectsTheSameOnBoth() throws {
        let (a, b, _) = shared("both-sides")
        // A conversation the person carries on from two places, alternating.
        for i in 0..<4 {
            a.clock.advance(30)
            try a.say("from the notch, \(i)", in: "th-kaplan", turn: "a\(i)")
            b.clock.advance(30)
            try b.say("from the phone, \(i)", in: "th-kaplan", turn: "b\(i)", role: .moe)
        }

        #expect(Convergence.between(a, b).isEmpty)
        let projected = try #require(a.projector.project(thread: "th-kaplan"))
        #expect(projected.turns.map(\.id) == ["a0", "b0", "a1", "b1", "a2", "b2", "a3", "b3"])
        #expect(projected.title == "from the notch, 0")
        #expect(try Convergence.onDisk(a, b).isEmpty)
    }

    /// The falsifier this slice names, reduced to the smallest case that
    /// produces it: two appenders, two clocks, and one of them a little
    /// behind.
    ///
    /// Slice one's incremental read put newly-arrived records on the end of
    /// an order it had already computed, checking only that their causal
    /// parents were placed. That is sound for one appender, whose records
    /// only ever arrive in the order it wrote them. With two, a record can
    /// arrive *now* and belong *earlier*, and then the appender that watched
    /// it happen and an appender reading the same bytes cold produce
    /// different conversations from identical records.
    @Test func aRecordThatArrivesLateButBelongsEarlierIsPutWhereItBelongs() throws {
        let (a, b, dir) = shared("late-but-earlier")
        let body = { (turn: String) in
            JSONValue.of(["thread": .string("th"), "turn_id": .string(turn)])
        }
        // A speaks; B speaks twenty seconds later by its own clock; A reads
        // both, then speaks again — and A's clock is ten seconds behind B's.
        let a1 = try a.ledger.append(kind: "turn", body: body("a1"), at: sunday)
        let b1 = try b.ledger.append(kind: "turn", body: body("b1"), at: sunday + 20)
        #expect(a.ledger.all().map(\.id) == [a1.id, b1.id])
        let a2 = try a.ledger.append(kind: "turn", body: body("a2"), after: [a1.id], at: sunday + 10)

        let warm = a.ledger.all().map(\.id)
        let cold = Ledger(directory: dir, device: "mac-one").all().map(\.id)
        #expect(warm == cold)
        #expect(warm == [a1.id, a2.id, b1.id])
        #expect(Convergence.between(a, b).isEmpty)
    }

    /// The same failure from the other direction: a record that was named
    /// before it arrived.
    ///
    /// A reply is placed without its question, because the question has not
    /// turned up yet and `ordered` ignores a parent nobody holds. When the
    /// question does arrive, the reply has to move — so the cheap path has to
    /// know that something already placed was waiting for it.
    @Test func aQuestionThatArrivesAfterItsReplyMovesTheReplyBack() throws {
        let (a, b, dir) = shared("reply-first")
        let body = { (turn: String) in
            JSONValue.of(["thread": .string("th"), "turn_id": .string(turn)])
        }
        // The question, written on B, which A has not seen. Its clock is
        // ahead, so a reader that simply appends what arrives would leave it
        // on the end.
        let question = LedgerRecord(kind: "turn", at: sunday + 60, device: "mac-two", seq: 1,
                                    prev: nil, after: [], body: body("q"))
        let reply = LedgerRecord(kind: "turn", at: sunday, device: "mac-two", seq: 2,
                                 prev: question.id, after: [question.id], body: body("r"))

        try a.ledger.adopt(reply)
        #expect(a.ledger.all().map(\.id) == [reply.id])
        try a.ledger.adopt(question)

        let warm = a.ledger.all().map(\.id)
        let cold = Ledger(directory: dir, device: "mac-one").all().map(\.id)
        #expect(warm == cold)
        #expect(warm == [question.id, reply.id])
        _ = b
    }

    /// Two writers, two readers, at the same time, for as long as it takes to
    /// be sure the interleaving was real.
    ///
    /// Nothing here asserts a particular order — with two clocks there is no
    /// order to predict. It asserts the two things that must be true whatever
    /// the interleaving was: nothing was lost, and everybody agrees.
    @Test func concurrentAppendsLoseNothingAndEverybodyAgreesOnTheOrder() throws {
        let clock = FakeClock(sunday)
        let root = scratchRoot("concurrent")
        let dir = root.appendingPathComponent("ledger")
        // One clock between them, handing out a distinct instant each time,
        // so two threads cannot collide on `at` and make the expected answer
        // a coin toss. The skew cases are tested deterministically above.
        let a = Appender.make(name: "mac-one", root: root.appendingPathComponent("one"),
                              ledgerDirectory: dir, clock: clock, distinctInstants: true)
        let b = Appender.make(name: "mac-two", root: root.appendingPathComponent("two"),
                              ledgerDirectory: dir, clock: clock, distinctInstants: true)

        let rounds = 60
        let group = DispatchGroup()
        for (index, side) in [a, b].enumerated() {
            DispatchQueue.global().async(group: group) {
                for i in 0..<rounds {
                    _ = try? side.ledger.append(kind: "turn", body: .of([
                        "thread": .string("th-\(i % 3)"),
                        "turn_id": .string("\(side.name)-\(i)"),
                    ]))
                    // Read while the other side is writing: this is the whole
                    // point, and it is what folds a half-written view of the
                    // other's file into a cache that must still be right.
                    _ = side.ledger.all()
                }
                _ = index
            }
        }
        group.wait()

        #expect(a.ledger.gapsForThisDevice().isEmpty)
        #expect(b.ledger.gapsForThisDevice().isEmpty)
        #expect(a.ledger.forkedSeqsForThisDevice().isEmpty)
        #expect(b.ledger.forkedSeqsForThisDevice().isEmpty)

        let cold = Ledger(directory: dir, device: "mac-one").all()
        #expect(cold.count == rounds * 2)
        #expect(Set(cold.map(\.id)).count == rounds * 2)
        #expect(a.ledger.all().map(\.id) == cold.map(\.id))
        #expect(b.ledger.all().map(\.id) == cold.map(\.id))
        #expect(Convergence.between(a, b).isEmpty)
    }

    /// Two runtimes that share `~/.moe` also share `device.json`, and the
    /// design says a gap in a device's chain means records were lost. Two
    /// writers under one device id do not leave a gap; left to their own
    /// memories of the chain they leave two records with the same `seq`,
    /// which the loss detector cannot see.
    ///
    /// Slice two reported that rather than fixing it, because the fix was a
    /// policy question — whether two runtimes on one Mac are one device or
    /// two. LEDGER-WIRE §13.1 answered it: one device, one chain, shared
    /// under a lock, the head taken from the file. So this test now asserts
    /// the opposite of what it used to: two runtimes under one id do *not*
    /// fork. `SharedChainTests` has the rest of that contract; this stays
    /// here because it is the shape the app actually runs in — no explicit
    /// device id, both resolved from `device.json`.
    @Test func twoRuntimesThatShareADeviceIDShareItsChain() throws {
        let dir = scratchRoot("shared-identity").appendingPathComponent("ledger")
        let one = Ledger(directory: dir)
        let two = Ledger(directory: dir)
        #expect(one.device == two.device)

        for i in 0..<4 {
            _ = try one.append(kind: "turn", body: .of(["thread": .string("th"), "n": .int(i)]))
            _ = try two.append(kind: "turn", body: .of(["thread": .string("th"), "n": .int(100 + i)]))
        }

        let cold = Ledger(directory: dir, device: one.device)
        #expect(cold.all().count == 8)
        #expect(cold.gapsForThisDevice().isEmpty)
        #expect(cold.forkedSeqsForThisDevice().isEmpty)
        #expect(Ledger.read(file: cold.fileForThisDevice).map(\.seq) == Array(1...8))
    }

    // MARK: - Two replicas and a relay

    @Test func replayingEveryRecordAgainChangesNothing() throws {
        let (mac, cloud) = replicas("idempotent")
        try mac.say("what's in the Vasquez deck?", in: "th-1", turn: "m1")
        mac.clock.advance(30)
        try mac.say("Twelve slides; the ask is on nine.", in: "th-1", turn: "m2", role: .moe)
        try Relay.handKey(for: "th-1", from: mac, to: cloud)

        let delivered = try Relay.deliver(Relay.records(of: mac), to: cloud)
        #expect(delivered == 2)
        let after = cloud.ledger.all().map(\.id)

        // Again, and again in reverse, and once with the whole set doubled.
        #expect(try Relay.deliver(Relay.records(of: mac), to: cloud) == 0)
        #expect(try Relay.deliver(Relay.records(of: mac).reversed(), to: cloud) == 0)
        #expect(try Relay.deliver(Relay.records(of: mac) + Relay.records(of: mac), to: cloud) == 0)

        #expect(cloud.ledger.all().map(\.id) == after)
        #expect(Convergence.between(mac, cloud).isEmpty)
    }

    @Test func recordsThatArriveInAnyOrderProduceTheSameLedger() throws {
        let (mac, cloud) = replicas("out-of-order")
        for i in 0..<8 {
            mac.clock.advance(30)
            try mac.say("turn \(i)", in: "th-1", turn: "m\(i)", role: i.isMultiple(of: 2) ? .you : .moe)
        }
        try Relay.handKey(for: "th-1", from: mac, to: cloud)
        let written = Relay.records(of: mac)

        // Backwards, which is the worst case: every record arrives before
        // everything it depends on.
        try Relay.deliver(written.reversed(), to: cloud)
        #expect(cloud.ledger.all().map(\.id) == written.map(\.id))

        // And a shuffle that is the same every run, so a failure is a bug
        // rather than a bad afternoon.
        let (other, _) = replicas("out-of-order-shuffled")
        var shuffled = written
        for i in shuffled.indices { shuffled.swapAt(i, (i * 5 + 3) % shuffled.count) }
        try Relay.deliver(shuffled, to: other)
        try Relay.handKey(for: "th-1", from: mac, to: other)
        #expect(other.ledger.all().map(\.id) == written.map(\.id))
        #expect(Convergence.between(mac, other).isEmpty)
    }

    @Test func twoAppendersThatHaveSeenEachOtherProjectIdentically() throws {
        let (mac, cloud) = replicas("converge")

        // A thread they both write, a thread only the Mac has, a thread only
        // the cloud has.
        try mac.say("what did we decide about Kaplan?", in: "th-shared", turn: "m1")
        mac.clock.advance(45)
        try mac.say("nothing yet — you wanted the Q3 numbers first.", in: "th-shared",
                    turn: "m2", role: .moe, tools: ["Reading your notes"])
        try mac.say("remind me to call the plumber", in: "th-mac", turn: "m3")

        cloud.clock.advance(3_600)
        try cloud.say("what's on for tomorrow?", in: "th-cloud", turn: "c1")

        try Relay.sync(mac, cloud)
        for thread in ["th-shared", "th-mac"] { try Relay.handKey(for: thread, from: mac, to: cloud) }
        try Relay.handKey(for: "th-cloud", from: cloud, to: mac)

        // Now the cloud carries on the shared thread, and the Mac answers in
        // the cloud's thread. Both then see everything.
        cloud.clock.advance(600)
        try cloud.say("the Q3 numbers are in", in: "th-shared", turn: "c2")
        mac.clock.advance(900)
        try mac.say("moving it to Thursday", in: "th-cloud", turn: "m4")
        try Relay.sync(mac, cloud)

        #expect(Convergence.between(mac, cloud).isEmpty)
        #expect(try Convergence.onDisk(mac, cloud).isEmpty)
        let shared = try #require(mac.projector.project(thread: "th-shared"))
        #expect(shared.turns.map(\.id) == ["m1", "m2", "c2"])
        #expect(shared.turns[1].tools == ["Reading your notes"])
    }

    // MARK: - Tombstones

    @Test func carryingOnAThreadYouDeletedBringsItBack() throws {
        let (mac, _) = replicas("revive-same-device")
        try mac.say("the thing I meant to forget", in: "th-1", turn: "m1")
        try mac.conversations.delete(id: "th-1")
        #expect(mac.projector.project(thread: "th-1") == nil)
        #expect(mac.projector.isDeleted(thread: "th-1"))

        // Talking in it again is the clearer intent, and it is causally after
        // the deletion because the same device wrote both.
        mac.clock.advance(60)
        try mac.say("actually, keep this", in: "th-1", turn: "m2")
        let projected = try #require(mac.projector.project(thread: "th-1"))
        // Only what was said after the deletion. What was deleted stays
        // deleted — its key is gone, and now so is its place in the thread.
        #expect(projected.turns.map(\.id) == ["m2"])
    }

    /// §3.1: **a tombstone suppresses only what is causally before it or
    /// concurrent with it.**
    ///
    /// Slice one read this positionally — deleted if the thread's last record
    /// in ledger order is a `thread.delete` — which is the same answer with
    /// one appender and the wrong one with two. The second appender never
    /// heard about the deletion; its turn is concurrent with it; and whether
    /// the deleted conversation came back was then decided by which machine's
    /// wall clock was ahead.
    @Test func aTurnWrittenWithoutKnowingAboutTheDeleteDoesNotUndoIt() throws {
        for cloudIsAhead in [true, false] {
            let (mac, cloud) = replicas("concurrent-delete-\(cloudIsAhead)")
            try mac.say("the Kaplan thread", in: "th-1", turn: "m1")
            try Relay.sync(mac, cloud)
            try Relay.handKey(for: "th-1", from: mac, to: cloud)

            // The person deletes it on the Mac. The cloud, which has not
            // heard, answers in it — earlier or later by its own clock, which
            // must make no difference at all (§1.5).
            mac.clock.advance(3_600)
            try mac.conversations.delete(id: "th-1")
            cloud.clock.set(mac.clock.now.addingTimeInterval(cloudIsAhead ? 600 : -600))
            try cloud.say("and here is more about Kaplan", in: "th-1", turn: "c1")

            try Relay.sync(mac, cloud)

            #expect(mac.projector.isDeleted(thread: "th-1"), "mac, cloud ahead: \(cloudIsAhead)")
            #expect(cloud.projector.isDeleted(thread: "th-1"), "cloud, cloud ahead: \(cloudIsAhead)")
            #expect(mac.projector.project(thread: "th-1") == nil)
            #expect(cloud.projector.project(thread: "th-1") == nil)
            #expect(Convergence.between(mac, cloud).isEmpty)
            #expect(try Convergence.onDisk(mac, cloud).isEmpty)
            // And the record that carried the deleted words is still there,
            // holding the place other records point at.
            #expect(mac.projector.records(thread: "th-1").count == 3)
        }
    }

    @Test func aTurnWrittenAfterSeeingTheDeleteDoesBringTheThreadBack() throws {
        let (mac, cloud) = replicas("causal-revive")
        try mac.say("the Kaplan thread", in: "th-1", turn: "m1")
        try Relay.sync(mac, cloud)
        try Relay.handKey(for: "th-1", from: mac, to: cloud)

        mac.clock.advance(3_600)
        try mac.conversations.delete(id: "th-1")
        try Relay.sync(mac, cloud)

        // The cloud has the tombstone now, so what it writes next names it.
        cloud.clock.advance(60)
        try cloud.say("actually, one more thing about Kaplan", in: "th-1", turn: "c1")
        let written = try #require(cloud.projector.records(thread: "th-1").last)
        #expect(written.after.contains(where: { id in
            cloud.projector.records(thread: "th-1")
                .contains { $0.id == id && $0.kind == LedgerRecord.Kind.threadDelete }
        }))

        try Relay.sync(mac, cloud)
        // The Mac destroyed its key when it deleted the thread, so it holds
        // the cloud's ciphertext and cannot read it. That is §12's second
        // undecided question — what Delete means once a second device has the
        // copy — and it is a real, currently-unanswered asymmetry.
        #expect(cloud.projector.project(thread: "th-1")?.turns.map(\.id) == ["c1"])
        #expect(mac.projector.project(thread: "th-1") == nil)
        #expect(mac.projector.unreadableThreads() == ["th-1"])

        // Given the key — which nothing in this slice transports — they agree.
        try Relay.handKey(for: "th-1", from: cloud, to: mac)
        #expect(mac.projector.project(thread: "th-1")?.turns.map(\.id) == ["c1"])
        #expect(Convergence.between(mac, cloud).isEmpty)
    }

    @Test func aDeletionReachesTheOtherSideAsARecordAndThenAsAKey() throws {
        let (mac, cloud) = replicas("delete-propagates")
        try mac.say("something private", in: "th-1", turn: "m1")
        try mac.say("something else", in: "th-2", turn: "m2")
        for thread in ["th-1", "th-2"] { try Relay.handKey(for: thread, from: mac, to: cloud) }
        try Relay.sync(mac, cloud)
        #expect(cloud.keyring.has(thread: "th-1"))

        mac.clock.advance(60)
        try mac.conversations.delete(id: "th-1")
        try Relay.sync(mac, cloud)

        // The record alone is enough to stop showing it, immediately.
        #expect(cloud.projector.project(thread: "th-1") == nil)
        // The key is what makes the deletion real, and it goes on the next
        // rebuild — which is a repair path, not something that runs after
        // every reply. Until then the other side still holds a key it should
        // not, and that is worth knowing.
        #expect(cloud.keyring.has(thread: "th-1"))
        _ = try cloud.conversations.rebuild()
        #expect(!cloud.keyring.has(thread: "th-1"))
        #expect(cloud.projector.project(thread: "th-2")?.turns.map(\.id) == ["m2"])
        #expect(Convergence.between(mac, cloud).isEmpty)
    }

    // MARK: - Encryption across appenders

    @Test func aSealedThreadIsUnreadableByTheOtherSideUntilItHasTheKey() throws {
        let (mac, cloud) = replicas("sealed-across")
        try mac.say("the ask is on slide nine", in: "th-sealed", turn: "m1")
        mac.clock.advance(30)
        try mac.say("noted", in: "th-sealed", turn: "m2", role: .moe)
        cloud.clock.advance(60)
        try cloud.say("what's on for tomorrow?", in: "th-open", turn: "c1")
        try Relay.handKey(for: "th-open", from: cloud, to: mac)
        try Relay.sync(mac, cloud)

        // The cloud holds every record and not one word of the sealed thread.
        #expect(cloud.projector.records(thread: "th-sealed").count == 2)
        #expect(cloud.projector.project(thread: "th-sealed") == nil)
        #expect(cloud.projector.unreadableThreads() == ["th-sealed"])
        let onDisk = try FileManager.default
            .contentsOfDirectory(at: cloud.ledger.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!onDisk.contains("slide nine"))

        // What it cannot read does not cost it anything else: the order is
        // the same order, and the thread it can read is untouched.
        #expect(cloud.ledger.all().map(\.id) == mac.ledger.all().map(\.id))
        #expect(cloud.ledger.gapsForThisDevice().isEmpty)
        #expect(cloud.projector.project(thread: "th-open") == mac.projector.project(thread: "th-open"))
        #expect(try cloud.conversations.rebuild() == 1)

        // And with the key, the two projections are identical.
        try Relay.handKey(for: "th-sealed", from: mac, to: cloud)
        #expect(Convergence.between(mac, cloud).isEmpty)
        #expect(try Convergence.onDisk(mac, cloud).isEmpty)
    }

    @Test func aThreadWhoseKeyWasDestroyedStaysUnreadableOnBothSides() throws {
        let (mac, cloud) = replicas("destroyed-key")
        try mac.say("the one to go", in: "th-doomed", turn: "m1")
        try mac.say("the one to keep", in: "th-kept", turn: "m2")
        for thread in ["th-doomed", "th-kept"] { try Relay.handKey(for: thread, from: mac, to: cloud) }
        try Relay.sync(mac, cloud)

        mac.clock.advance(60)
        try mac.conversations.delete(id: "th-doomed")
        try Relay.sync(mac, cloud)
        _ = try cloud.conversations.rebuild()

        for side in [mac, cloud] {
            #expect(side.projector.project(thread: "th-doomed") == nil)
            #expect(!side.keyring.has(thread: "th-doomed"))
            #expect(side.projector.unreadableThreads().isEmpty)
            #expect(side.projector.project(thread: "th-kept")?.turns.map(\.id) == ["m2"])
            #expect(side.ledger.gapsForThisDevice().isEmpty)
        }
        #expect(mac.ledger.all().map(\.id) == cloud.ledger.all().map(\.id))
        #expect(Convergence.between(mac, cloud).isEmpty)
    }

    /// Two runtimes over one `~/.moe` share one keyring file, and each held
    /// its own copy of it in memory. Whichever saved last wrote its own map
    /// over the other's, and a thread the other had just sealed became
    /// unreadable forever — the same permanent amnesia Delete is supposed to
    /// be the only cause of.
    @Test func oneAppenderMintingAKeyDoesNotEraseTheOthers() throws {
        let file = scratchRoot("keyring-clobber")
            .appendingPathComponent("ledger/thread-keys.json")
        // Both exist before either writes, which is what two long-lived
        // runtimes look like.
        let one = ThreadKeyring(url: file)
        let two = ThreadKeyring(url: file)

        let first = try one.key(creatingFor: "th-1")
        let second = try two.key(creatingFor: "th-2")

        let cold = ThreadKeyring(url: file)
        #expect(cold.key(for: "th-1") == first)
        #expect(cold.key(for: "th-2") == second)
        // And each of them can now read what the other sealed.
        #expect(one.key(for: "th-2") == second)
        #expect(two.key(for: "th-1") == first)
    }

    @Test func aKeyDestroyedByOneAppenderIsNotBroughtBackByTheOther() throws {
        let file = scratchRoot("keyring-no-resurrect")
            .appendingPathComponent("ledger/thread-keys.json")
        let one = ThreadKeyring(url: file)
        let two = ThreadKeyring(url: file)
        _ = try one.key(creatingFor: "th-doomed")
        _ = try two.key(creatingFor: "th-other")
        // The second runtime has read the doomed thread, so it is holding
        // that key in memory too — which is the state that makes this
        // dangerous rather than academic.
        #expect(two.key(for: "th-doomed") != nil)

        try one.destroy(thread: "th-doomed")
        // `two` still has it in memory. Anything it writes next must not put
        // it back: a deletion that a sister session can undo is not one.
        _ = try two.key(creatingFor: "th-later")

        #expect(ThreadKeyring(url: file).key(for: "th-doomed") == nil)
        #expect(two.key(for: "th-doomed") == nil)
        #expect(two.key(for: "th-other") != nil)
        #expect(two.key(for: "th-later") != nil)
    }

    @Test func twoAppendersMintingKeysAtOnceKeepAllOfThem() throws {
        let file = scratchRoot("keyring-concurrent")
            .appendingPathComponent("ledger/thread-keys.json")
        let rings = [ThreadKeyring(url: file), ThreadKeyring(url: file)]
        let group = DispatchGroup()
        for (side, ring) in rings.enumerated() {
            DispatchQueue.global().async(group: group) {
                for i in 0..<25 { _ = try? ring.key(creatingFor: "th-\(side)-\(i)") }
            }
        }
        group.wait()

        let cold = ThreadKeyring(url: file)
        for side in 0..<2 {
            for i in 0..<25 { #expect(cold.key(for: "th-\(side)-\(i)") != nil, "th-\(side)-\(i)") }
        }
    }

    // MARK: - Three days apart

    /// The case §1.4 says kills naive designs: the Mac offline Monday to
    /// Wednesday while the cloud is used daily, then the Mac comes back.
    ///
    /// The framing that matters is that **an offline Mac is not an idle Mac**.
    /// `sync.sh` runs every ten minutes from a LaunchAgent, an hourly digest
    /// distils the day, and iMessage, Notes and Calendar are Mac-only sources
    /// that keep producing whether or not anybody is talking to the machine.
    /// So the Mac writes several hundred records over the three days while
    /// the cloud writes the conversations, and the reconciliation has to
    /// survive both — not a quiet machine that appends nothing.
    ///
    /// The Mac's clock also drifts while it is away, because a machine that
    /// has been asleep for three days comes back with one, and §1.5 says
    /// `at` is never allowed to decide who wins.
    @Test func threeDaysApartAndBothSidesComeBackTheSame() throws {
        let (mac, cloud) = replicas("three-days")
        var expectedRecords = 0

        // Sunday: in step, on one thread.
        try mac.say("what did we decide about Kaplan?", in: "th-kaplan", turn: "m-sun-1")
        mac.clock.advance(40)
        try mac.say("that you'd send the Q3 numbers first.", in: "th-kaplan",
                    turn: "m-sun-2", role: .moe)
        expectedRecords += 2
        try Relay.sync(mac, cloud)
        try Relay.handKey(for: "th-kaplan", from: mac, to: cloud)

        // Monday to Wednesday. Neither hears from the other.
        let day: TimeInterval = 86_400
        for dayIndex in 0..<3 {
            // The cloud: the person's phone, used all day.
            for hour in [9, 13, 18] {
                cloud.clock.set(sunday + Double(dayIndex + 1) * day + Double(hour) * 3_600)
                try cloud.say("day \(dayIndex) at \(hour): what's the status?",
                              in: "th-kaplan", turn: "c-\(dayIndex)-\(hour)")
                cloud.clock.advance(20)
                try cloud.say("day \(dayIndex) at \(hour): still waiting on legal.",
                              in: "th-kaplan", turn: "c-\(dayIndex)-\(hour)-r", role: .moe)
                expectedRecords += 2
            }
            // A thread that only ever existed on the phone.
            cloud.clock.advance(3_600)
            try cloud.say("book the Thursday flight", in: "th-travel-\(dayIndex)",
                          turn: "c-travel-\(dayIndex)")
            expectedRecords += 1
            // And the cloud's own connectors, pulling all day.
            for slot in 0..<24 {
                cloud.clock.advance(600)
                try cloud.background("gmail", "thread-\(dayIndex)-\(slot)", "unread")
                expectedRecords += 1
            }

            // The Mac: nobody is talking to it, and it never stops writing.
            // `sync.sh` every ten minutes, the digest every hour, the crawl
            // over the Mac-only sources nothing else can see.
            for slot in 0..<144 {
                mac.clock.set(sunday + Double(dayIndex + 1) * day + Double(slot) * 600
                              // Three days of drift, which is what a machine
                              // that has been asleep comes back with.
                              + Double(dayIndex) * 47)
                try mac.background("sync", "heartbeat-\(dayIndex)-\(slot)", "ok")
                expectedRecords += 1
                if slot.isMultiple(of: 6) {
                    try mac.background("digest", "hour-\(dayIndex)-\(slot / 6)", "nothing said")
                    try mac.background("imessage", "naomi-\(dayIndex)-\(slot / 6)", "is my daughter")
                    expectedRecords += 2
                }
            }
            // And one thread the Mac itself produced: a meeting it recorded
            // while nobody was talking to it.
            try mac.say("notes from the standup", in: "th-standup-\(dayIndex)",
                        turn: "m-standup-\(dayIndex)")
            expectedRecords += 1
        }

        // Nothing has crossed yet.
        #expect(cloud.projector.project(thread: "th-kaplan")?.turns.count == 20)
        #expect(mac.projector.project(thread: "th-kaplan")?.turns.count == 2)

        // Wednesday evening: the lid opens.
        try Relay.sync(mac, cloud)
        for dayIndex in 0..<3 {
            try Relay.handKey(for: "th-standup-\(dayIndex)", from: mac, to: cloud)
            try Relay.handKey(for: "th-travel-\(dayIndex)", from: cloud, to: mac)
        }

        // Nothing lost, on either side.
        #expect(mac.ledger.all().count == expectedRecords)
        #expect(cloud.ledger.all().count == expectedRecords)
        #expect(mac.ledger.gapsForThisDevice().isEmpty)
        #expect(cloud.ledger.gapsForThisDevice().isEmpty)
        #expect(mac.ledger.forkedSeqsForThisDevice().isEmpty)
        #expect(cloud.ledger.forkedSeqsForThisDevice().isEmpty)

        // Identical, not similar — including that reading the three days cold
        // gives the same order as having watched them arrive.
        #expect(Convergence.between(mac, cloud).isEmpty)
        #expect(try Convergence.onDisk(mac, cloud).isEmpty)

        // And the thing the person actually notices on Wednesday evening:
        // opening the Kaplan thread on the Mac shows Tuesday's phone
        // conversation, in order, after Sunday's.
        let kaplan = try #require(mac.projector.project(thread: "th-kaplan"))
        #expect(kaplan.turns.map(\.id) == [
            "m-sun-1", "m-sun-2",
            "c-0-9", "c-0-9-r", "c-0-13", "c-0-13-r", "c-0-18", "c-0-18-r",
            "c-1-9", "c-1-9-r", "c-1-13", "c-1-13-r", "c-1-18", "c-1-18-r",
            "c-2-9", "c-2-9-r", "c-2-13", "c-2-13-r", "c-2-18", "c-2-18-r",
        ])
        #expect(kaplan.startedAt == sunday)
        #expect(kaplan.title == "what did we decide about Kaplan?")

        // The hundreds of background records took part in the ordering and
        // disturbed no conversation.
        // 26 turns: two on Sunday, eighteen on the phone, three travel
        // threads and three standups. Everything else is a background job.
        #expect(mac.ledger.records(kind: LedgerRecord.Kind.turn).count == 26)
        #expect(mac.ledger.records(kind: LedgerRecord.Kind.claim).count == expectedRecords - 26)
        #expect(Set(mac.projector.threads()) == Set([
            "th-kaplan", "th-standup-0", "th-standup-1", "th-standup-2",
            "th-travel-0", "th-travel-1", "th-travel-2",
        ]))
    }

    /// The same three days, run again from the records alone.
    ///
    /// A second sync after both sides have everything must be a no-op, and a
    /// rebuild from records must give back exactly what was on screen. This
    /// is the reconciliation pass §3.2 asks for, minus the part that talks to
    /// the person.
    @Test func aSecondReconciliationAfterTheThreeDaysChangesNothing() throws {
        let (mac, cloud) = replicas("three-days-again")
        try mac.say("Sunday", in: "th", turn: "m1")
        try Relay.sync(mac, cloud)
        try Relay.handKey(for: "th", from: mac, to: cloud)
        for i in 0..<20 {
            cloud.clock.advance(3_600)
            try cloud.say("cloud \(i)", in: "th", turn: "c\(i)")
            mac.clock.advance(600)
            try mac.background("sync", "heartbeat-\(i)", "ok")
        }
        try Relay.sync(mac, cloud)

        let before = mac.ledger.all().map(\.id)
        let projected = mac.projector.project(thread: "th")
        try Relay.sync(mac, cloud)
        try Relay.sync(cloud, mac)
        #expect(mac.ledger.all().map(\.id) == before)
        #expect(mac.projector.project(thread: "th") == projected)
        #expect(try mac.conversations.rebuild() == 1)
        #expect(mac.store.load(id: "th")?.turns.map(\.id) == projected?.turns.map(\.id))
        #expect(Convergence.between(mac, cloud).isEmpty)
    }

    // MARK: - Contending for one thread, rather than for the file

    /// The first version of the keyring fix stopped two runtimes writing
    /// their whole map over each other, and left a narrower way to lose a
    /// conversation permanently: the "do I have a key?" check is outside the
    /// lock, so two runtimes saving the *same* thread both see no key and
    /// both mint one. A wrote K_A and sealed a turn with it; B then took the
    /// lock, saw K_A, and replaced it with K_B. A's record was ciphertext
    /// under a key that existed nowhere.
    ///
    /// The first tests missed it because they raced on *disjoint* thread
    /// names, so the two sides never contended for one key. This one does.
    @Test func twoRingsMintingTheSameThreadAtOnceAgreeOnOneKey() throws {
        for round in 0..<40 {
            let file = scratchRoot("keyring-same-thread-\(round)")
                .appendingPathComponent("ledger/thread-keys.json")
            let rings = [ThreadKeyring(url: file), ThreadKeyring(url: file)]
            var got = [SymmetricKey?](repeating: nil, count: 2)
            let lock = NSLock()
            let group = DispatchGroup()
            for (index, ring) in rings.enumerated() {
                DispatchQueue.global().async(group: group) {
                    let key = try? ring.key(creatingFor: "th-contended")
                    lock.lock()
                    got[index] = key
                    lock.unlock()
                }
            }
            group.wait()

            let onDisk = ThreadKeyring(url: file).key(for: "th-contended")
            #expect(onDisk != nil, "round \(round)")
            // Whichever key survived, both callers were handed *that* one —
            // otherwise one of them is about to seal a turn with a key the
            // file does not have.
            #expect(got[0] == onDisk, "round \(round)")
            #expect(got[1] == onDisk, "round \(round)")
        }
    }

    /// The same thing said the way a person would notice it: two runtimes
    /// answering in one thread at the same moment, and afterwards every turn
    /// that was recorded can still be read.
    @Test func aTurnSealedDuringAConcurrentMintIsStillReadable() throws {
        for round in 0..<20 {
            let (a, b, _) = shared("contended-thread-\(round)", distinctInstants: true)
            let group = DispatchGroup()
            for (index, side) in [a, b].enumerated() {
                DispatchQueue.global().async(group: group) {
                    try? side.say("from \(side.name)", in: "th-both", turn: "t\(index)")
                }
            }
            group.wait()

            let recorded = a.projector.turnRecords(thread: "th-both").count
            #expect(recorded == 2, "round \(round)")
            for side in [a, b] {
                // Every record that was written is a turn somebody can read.
                // A key overwritten mid-flight shows up here as a record that
                // projects to nothing, which is a conversation half lost.
                #expect(side.projector.project(thread: "th-both")?.turns.count == recorded,
                        "\(side.name), round \(round)")
                #expect(side.projector.unreadableThreads().isEmpty, "\(side.name), round \(round)")
            }
        }
    }

    /// A tombstone must not be decided by `seq`, because two runtimes fork it.
    ///
    /// The first version of the causal rule read "same device, higher `seq`"
    /// as "had certainly seen it". True of one writer per chain, and false in
    /// the configuration this slice exists to support — so the fork this
    /// slice *found* became the signal the deletion rule leaned on. The
    /// person deletes a conversation in one window and it reappears in the
    /// list, on a forked counter instead of a wall clock, which is no better
    /// and much harder to see.
    @Test func aForkedSequenceNumberDoesNotReviveADeletedThread() throws {
        let root = scratchRoot("forked-seq-tombstone")
        let dir = root.appendingPathComponent("ledger")
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: dir, device: "mac-shared")
        let conversations = ConversationLedger(ledger: ledger, store: store)
        let at = sunday

        func turn(_ thread: String, _ id: String, seq: Int, prev: String?,
                  after: [String]) -> LedgerRecord {
            LedgerRecord(kind: LedgerRecord.Kind.turn, at: at, device: "mac-shared", seq: seq,
                         prev: prev, after: after, body: .of([
                             "thread": .string(thread),
                             "thread_started_at": .string(LedgerRecord.timestamps.string(from: at)),
                             "turn_id": .string(id),
                             "role": .string("you"),
                             "at": .string(LedgerRecord.timestamps.string(from: at)),
                             "text": .string("turn \(id)"),
                         ]))
        }

        // Both runtimes resolved the same device id out of `device.json` and
        // both believe the chain stands at `m1`.
        let m1 = turn("th-1", "m1", seq: 1, prev: nil, after: [])
        // Runtime A deletes the thread. Its tombstone continues the chain it
        // remembers, at seq 2.
        let tomb = LedgerRecord(kind: LedgerRecord.Kind.threadDelete, at: at,
                                device: "mac-shared", seq: 2, prev: m1.id, after: [m1.id],
                                body: .of(["thread": .string("th-1")]))
        // Runtime B, which never heard about it, carries on its own chain
        // from the same place — seq 2 again, then 3, then a turn back in
        // th-1 at seq 4 that names only what it had seen of that thread.
        let x2 = turn("th-other", "x2", seq: 2, prev: m1.id, after: [])
        let x3 = turn("th-other", "x3", seq: 3, prev: x2.id, after: [x2.id])
        let c1 = turn("th-1", "c1", seq: 4, prev: x3.id, after: [m1.id])

        for record in [m1, tomb, x2, x3, c1] { try ledger.adopt(record) }

        // The precondition this test is about, stated rather than assumed.
        #expect(ledger.forkedSeqsForThisDevice() == [2])
        // c1 has a higher `seq` than the tombstone on the same device and has
        // not seen it. The deletion stands.
        #expect(conversations.projector.isDeleted(thread: "th-1"))
        #expect(conversations.projector.project(thread: "th-1") == nil)
        // And the thread that was never deleted is untouched by any of it.
        #expect(conversations.projector.project(thread: "th-other")?.turns.map(\.id) == ["x2", "x3"])
    }

    // MARK: - A keyring that cannot be read is not a keyring with no keys

    @Test func aKeyringThatCannotBeReadIsLeftAloneRatherThanReplaced() throws {
        let file = scratchRoot("keyring-unreadable")
            .appendingPathComponent("ledger/thread-keys.json")
        let ring = ThreadKeyring(url: file)
        let first = try ring.key(creatingFor: "th-1")
        let second = try ring.key(creatingFor: "th-2")
        let before = try Data(contentsOf: file)

        // Unreadable without changing its size, inode or modification time,
        // so nothing upstream notices — a permissions change is the cheapest
        // way to say "this read failed" and is not the only way it happens.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: file.path) }

        // The write is refused. Going ahead would put one key where two were,
        // and the caller already treats an unmintable key as a reason not to
        // seal anything — which is the right end for this to come to.
        #expect(throws: (any Error).self) { _ = try ring.key(creatingFor: "th-3") }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == before)
        let cold = ThreadKeyring(url: file)
        #expect(cold.key(for: "th-1") == first)
        #expect(cold.key(for: "th-2") == second)
        // And in memory too: a read that failed for a moment must not be the
        // reason a live session stops being able to show a conversation.
        #expect(ring.key(for: "th-1") == first)
        #expect(ring.key(for: "th-2") == second)
    }

    /// §8 promises an older reader survives a newer version's records. The
    /// keyring is the one file here that cannot be rebuilt from anything
    /// else, so an unrecognised shape has to be left exactly where it is —
    /// not read as "no keys" and written over with today's.
    @Test func aKeyringInAShapeThisBuildDoesNotKnowIsNotOverwritten() throws {
        let file = scratchRoot("keyring-future-shape")
            .appendingPathComponent("ledger/thread-keys.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Valid JSON, and `keys` holds per-thread objects rather than strings
        // — the obvious next version of this file.
        let future = """
        {"README":"...","version":2,"keys":{"th-1":{"alg":"aes-gcm-256.v2","k":"aaaa"}}}
        """
        try Data(future.utf8).write(to: file)

        let ring = ThreadKeyring(url: file)
        #expect(ring.key(for: "th-1") == nil)
        #expect(throws: (any Error).self) { _ = try ring.key(creatingFor: "th-2") }
        #expect(try String(contentsOf: file, encoding: .utf8) == future)
        // Not filed as damaged either: it parsed, and that rescue is only
        // ever taken of a file that did not.
        let aside = try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path).filter { $0.contains("damaged") }
        #expect(aside.isEmpty)
    }

    /// `surviving` starts from turn records, so a thread with records of some
    /// other kind and no turns has nothing surviving — which is not the same
    /// statement as "the person deleted this", and `write` removes a deleted
    /// thread's file on every save rather than only on repair. Nothing but
    /// `turn` and `thread.delete` names a thread today; the day a `claim`
    /// does, this is what stops it quietly deleting a projection.
    @Test func aThreadWithNoTurnRecordsIsNotADeletedThread() throws {
        let root = scratchRoot("no-turns-not-deleted")
        let store = ConversationStore(directory: root.appendingPathComponent("conversations"))
        let ledger = Ledger(directory: root.appendingPathComponent("ledger"), device: "mac-test")
        let conversations = ConversationLedger(ledger: ledger, store: store)

        let existing = ConversationStore.Conversation(
            id: "th-x", startedAt: sunday, updatedAt: sunday,
            turns: [.init(id: "t1", role: .you, text: "written before the ledger", at: sunday)])
        try store.save(existing)

        // A record that names the thread and is not a turn.
        try ledger.append(kind: LedgerRecord.Kind.claim,
                          body: .of(["thread": .string("th-x"), "key": .string("topic")]))

        #expect(!conversations.projector.isDeleted(thread: "th-x"))
        #expect(try conversations.projector.write(thread: "th-x") == nil)
        #expect(store.load(id: "th-x") == existing)
    }
}
