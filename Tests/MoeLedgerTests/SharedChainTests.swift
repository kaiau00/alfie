import Foundation
import Testing
@testable import MoeLedger

/// LEDGER-WIRE §13.1: one device per Mac, one chain, two writers.
///
/// The app and Hermes's `claimstore` plugin append to the same
/// `<device>.jsonl` under the same device id. Slice two found that two
/// runtimes doing that forked the chain — two records claiming one `seq` —
/// and reported it rather than fixing it, because whether they were one
/// device or two was a decision owed. §13.1 made it: they are one, and the
/// chain is shared under `flock` on `<device>.jsonl.lock`, the head re-read
/// from the file whenever the file has moved.
///
/// Two `Ledger` instances over one directory stand in for the two
/// processes. They are two instances, not two processes, and that is
/// enough: `flock` is held per open file description, so two `open`s in one
/// process contend exactly as two processes would, and each instance keeps
/// its own head cache, which is the thing that used to go stale.
struct SharedChainTests {

    private func directory() -> URL {
        scratchRoot("shared-chain").appendingPathComponent("ledger")
    }

    private func body(_ n: Int) -> JSONValue {
        .of(["thread": .string("th"), "n": .int(n)])
    }

    @Test func twoWritersUnderOneDeviceIDKeepOneGaplessChain() throws {
        let dir = directory()
        // No explicit device id, which is what the app does: both resolve
        // the same one out of the directory's own `device.json`, and so does
        // the plugin (§13.1).
        let app = Ledger(directory: dir)
        let plugin = Ledger(directory: dir)
        #expect(app.device == plugin.device)

        // Interleaved. Each instance remembers where the chain was after
        // its *own* last append; the other has moved it since, every time.
        var ids: [String] = []
        for i in 0..<6 {
            ids.append(try app.append(kind: "turn", body: body(i)).id)
            ids.append(try plugin.append(kind: "claim", body: body(100 + i)).id)
        }

        let cold = Ledger(directory: dir, device: app.device)
        #expect(cold.gapsForThisDevice().isEmpty)
        #expect(cold.forkedSeqsForThisDevice().isEmpty, "two writers forked the chain")
        let mine = Ledger.read(file: cold.fileForThisDevice)
        #expect(mine.map(\.seq) == Array(1...12))
        #expect(mine.map(\.id) == ids)
        // And `prev` follows the file, not either writer's memory.
        for (previous, record) in zip(mine, mine.dropFirst()) {
            #expect(record.prev == previous.id)
        }
        // The lock file is beside the chain, and is nobody else's to read.
        let lock = cold.fileForThisDevice.appendingPathExtension("lock")
        #expect(FileManager.default.fileExists(atPath: lock.path))
        let mode = try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aRecordAnotherProcessAppendedBecomesTheHead() throws {
        let dir = directory()
        let app = Ledger(directory: dir, device: "mac-shared")
        let first = try app.append(kind: "turn", body: body(1))
        let second = try app.append(kind: "turn", body: body(2))
        // `app` now holds `second` as its head, and has no reason to look
        // at the file again — until the file moves.

        // Another process — not a `Ledger`; a line written straight into
        // the file, the way the plugin does it — continues the chain.
        let foreign = LedgerRecord(kind: "claim", at: Date(), device: "mac-shared", seq: 3,
                                   prev: second.id, after: [], body: body(3))
        let handle = try FileHandle(forWritingTo: app.fileForThisDevice)
        try handle.seekToEnd()
        try handle.write(contentsOf: try foreign.encoded() + Data([UInt8(ascii: "\n")]))
        try handle.close()

        let fourth = try app.append(kind: "turn", body: body(4))
        #expect(fourth.seq == 4, "the cached head was trusted after the file had moved")
        #expect(fourth.prev == foreign.id)
        #expect(app.gapsForThisDevice().isEmpty)
        #expect(app.forkedSeqsForThisDevice().isEmpty)
        #expect(app.all().map(\.id) == [first.id, second.id, foreign.id, fourth.id])
    }

    @Test func aRestoredCopyOfOurOwnRecordMovesTheHeadToo() throws {
        // A Mac whose ledger directory was lost pulls its own history back
        // from the cloud: `adopt` writes this device's own records into
        // this device's own file. The next append must carry on from what
        // came back, not start again at one.
        let dir = directory()
        let ledger = Ledger(directory: dir, device: "mac-restored")
        let first = try ledger.append(kind: "turn", body: body(1))
        let fromCloud = LedgerRecord(kind: "turn", at: Date(), device: "mac-restored", seq: 7,
                                     prev: nil, after: [], body: body(7))
        #expect(try ledger.adopt(fromCloud))
        let next = try ledger.append(kind: "turn", body: body(8))
        #expect(next.seq == 8)
        #expect(next.prev == fromCloud.id)
        #expect(first.seq == 1)
    }

    /// Both writers, flat out, at the same time. Nothing here asserts an
    /// order; it asserts that the lock did its job — no `seq` claimed twice,
    /// none skipped — under contention rather than under polite turn-taking.
    @Test func concurrentWritersUnderOneDeviceIDDoNotFork() throws {
        let dir = directory()
        let device = "mac-contended"
        let one = Ledger(directory: dir, device: device)
        let two = Ledger(directory: dir, device: device)
        let rounds = 80

        let done = NSCondition()
        var finished = 0
        for side in [one, two] {
            // A detached thread, not a global-queue work item: a Swift
            // Testing body that blocks on a queue it also feeds can hang
            // the suite (see `concurrently` in MoeCloudTests).
            Thread.detachNewThread {
                for i in 0..<rounds {
                    _ = try? side.append(kind: "turn", body: self.body(i))
                    _ = side.all()
                }
                done.lock(); finished += 1; done.signal(); done.unlock()
            }
        }
        done.lock()
        while finished < 2 { done.wait() }
        done.unlock()

        let cold = Ledger(directory: dir, device: device)
        #expect(cold.gapsForThisDevice().isEmpty)
        #expect(cold.forkedSeqsForThisDevice().isEmpty)
        let mine = Ledger.read(file: cold.fileForThisDevice)
        #expect(mine.count == rounds * 2)
        #expect(mine.map(\.seq) == Array(1...(rounds * 2)))
        #expect(one.all().map(\.id) == cold.all().map(\.id))
        #expect(two.all().map(\.id) == cold.all().map(\.id))
    }

    @Test func aChainForkedByAWriterThatSkippedTheLockIsNotForkedAgain() throws {
        // A writer that skipped the lock forked the chain once: two records
        // at seq 2. That fork is history and stays visible. What must not
        // happen is a second one: the head is the *highest* `seq`, so the
        // next append lands at 3, whichever of the two happens to be the
        // last line of the file.
        let dir = directory()
        let ledger = Ledger(directory: dir, device: "mac-forked")
        let first = try ledger.append(kind: "turn", body: body(1))
        let a = LedgerRecord(kind: "turn", at: Date(), device: "mac-forked", seq: 2,
                             prev: first.id, after: [], body: body(2))
        let b = LedgerRecord(kind: "turn", at: Date(), device: "mac-forked", seq: 2,
                             prev: first.id, after: [], body: body(20))
        for record in [a, b] { try ledger.adopt(record) }
        #expect(ledger.forkedSeqsForThisDevice() == [2])

        let third = try ledger.append(kind: "turn", body: body(3))
        let fourth = try ledger.append(kind: "turn", body: body(4))
        #expect(third.seq == 3 && fourth.seq == 4)
        #expect(fourth.prev == third.id)
        #expect(ledger.forkedSeqsForThisDevice() == [2], "the append forked the chain again")
        #expect(ledger.gapsForThisDevice().isEmpty)
    }
}
