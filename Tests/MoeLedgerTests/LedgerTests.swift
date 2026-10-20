import Foundation
import Testing
@testable import MoeLedger

/// The log itself: append-only, content-addressed, and readable after a crash.
/// Everything a person has ever said is downstream of this file, so its
/// failure modes are the ones worth writing tests about.
struct LedgerTests {

    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-ledger-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func body(_ text: String) -> JSONValue {
        .of(["thread": .string("th-1"), "text": .string(text)])
    }

    // MARK: Identity

    @Test func theSameRecordHashesToTheSameID() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let a = LedgerRecord(kind: "turn", at: at, device: "mac-1", seq: 1,
                             prev: nil, after: [], body: body("hello"))
        let b = LedgerRecord(kind: "turn", at: at, device: "mac-1", seq: 1,
                             prev: nil, after: [], body: body("hello"))
        #expect(a.id == b.id)
        #expect(a.id.count == 32)

        let different = LedgerRecord(kind: "turn", at: at, device: "mac-1", seq: 1,
                                     prev: nil, after: [], body: body("goodbye"))
        #expect(different.id != a.id)
    }

    @Test func aRecordSurvivesARoundTripThroughTheFileFormat() throws {
        let record = LedgerRecord(kind: "turn", at: Date(timeIntervalSince1970: 1_755_000_000.25),
                                  device: "mac-1", seq: 7, prev: "abc", after: ["def"],
                                  body: body("what's in the Vasquez deck?"))
        let line = try record.encoded()
        let back = try #require(LedgerRecord.decode(line: line))
        #expect(back == record)
        #expect(LedgerRecord.hash(of: back) == record.id)
    }

    // MARK: Appending

    @Test func appendsChainPerDevice() throws {
        let ledger = Ledger(directory: tempDirectory(), device: "mac-test")
        let first = try ledger.append(kind: "turn", body: body("one"))
        let second = try ledger.append(kind: "turn", body: body("two"), after: [first.id])

        #expect(first.seq == 1)
        #expect(first.prev == nil)
        #expect(second.seq == 2)
        #expect(second.prev == first.id)
        #expect(ledger.gapsForThisDevice().isEmpty)
        #expect(ledger.all().map(\.id) == [first.id, second.id])
    }

    @Test func aNewLedgerContinuesTheChainItFindsOnDisk() throws {
        let dir = tempDirectory()
        let first = try Ledger(directory: dir, device: "mac-test").append(kind: "turn", body: body("one"))
        // A restarted process must not start counting from one again: a
        // duplicate seq would look exactly like a lost record.
        let second = try Ledger(directory: dir, device: "mac-test").append(kind: "turn", body: body("two"))
        #expect(second.seq == 2)
        #expect(second.prev == first.id)
    }

    @Test func adoptingTheSameRecordTwiceWritesItOnce() throws {
        let ledger = Ledger(directory: tempDirectory(), device: "mac-test")
        let record = LedgerRecord(kind: "turn", at: Date(), device: "cloud-x", seq: 1,
                                  prev: nil, after: [], body: body("from elsewhere"))
        #expect(try ledger.adopt(record) == true)
        #expect(try ledger.adopt(record) == false)
        #expect(ledger.all().count == 1)
    }

    // MARK: Crash safety

    @Test func anInterruptedAppendCostsOnlyTheRecordItWasWriting() throws {
        let dir = tempDirectory()
        let ledger = Ledger(directory: dir, device: "mac-test")
        let first = try ledger.append(kind: "turn", body: body("one"))
        let second = try ledger.append(kind: "turn", body: body("two"))

        // The machine dies halfway through writing a third record.
        let file = ledger.fileForThisDevice
        var bytes = try Data(contentsOf: file)
        let torn = try LedgerRecord(kind: "turn", at: Date(), device: "mac-test", seq: 3,
                                    prev: second.id, after: [], body: body("three")).encoded()
        bytes.append(torn.prefix(torn.count / 2))
        try bytes.write(to: file)

        // Reading is unaffected: the half-line was never a durable record.
        let reader = Ledger(directory: dir, device: "mac-test")
        #expect(reader.all().map(\.id) == [first.id, second.id])

        // And the next append heals the file rather than joining the wreckage.
        let third = try reader.append(kind: "turn", body: body("three, properly"))
        #expect(third.seq == 3)
        #expect(Ledger(directory: dir, device: "mac-test").all().map(\.id) == [first.id, second.id, third.id])
    }

    @Test func aLineThatIsNotARecordIsSkippedRatherThanFatal() throws {
        let dir = tempDirectory()
        let ledger = Ledger(directory: dir, device: "mac-test")
        let good = try ledger.append(kind: "turn", body: body("one"))
        let file = ledger.fileForThisDevice
        var bytes = try Data(contentsOf: file)
        bytes.append(contentsOf: Array("{ this is not json\nnor is this\n".utf8))
        try bytes.write(to: file)

        #expect(Ledger(directory: dir, device: "mac-test").all().map(\.id) == [good.id])
    }

    @Test func aMissingSequenceNumberIsReportedRatherThanSilent() throws {
        let dir = tempDirectory()
        let ledger = Ledger(directory: dir, device: "mac-test")
        _ = try ledger.append(kind: "turn", body: body("one"))
        _ = try ledger.append(kind: "turn", body: body("two"))
        _ = try ledger.append(kind: "turn", body: body("three"))

        // Someone deletes the middle line of the file by hand.
        let file = ledger.fileForThisDevice
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        try ([lines[0], lines[2]].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(Ledger(directory: dir, device: "mac-test").gapsForThisDevice() == [2])
    }

    @Test func theIncrementalReadAgreesWithReadingItAllAgain() throws {
        let dir = tempDirectory()
        let ledger = Ledger(directory: dir, device: "mac-test")
        var ids: [String] = []
        // The same instance reads after each append, so it takes the cheap
        // path every time. A reader that has never seen the file takes the
        // slow one. They must not be able to disagree — the fast path is an
        // optimisation, and an optimisation that changes the answer is a bug.
        for i in 0..<40 {
            ids.append(try ledger.append(kind: "turn", body: body("turn \(i)"),
                                         after: ids.suffix(1).map { $0 }).id)
            #expect(ledger.all().map(\.id) == ids)
        }
        #expect(Ledger(directory: dir, device: "mac-test").all().map(\.id) == ids)
    }

    @Test func aRecordAppearingOutOfOrderFallsBackToTheFullSort() throws {
        // Two devices, and the second file names a record that comes after it
        // in file order. The cheap path cannot place that, so the full sort
        // has to run — the point of the test is that the answer is right, not
        // which path produced it.
        let dir = tempDirectory()
        let one = Ledger(directory: dir, device: "mac-one")
        let first = try one.append(kind: "turn", body: body("asked"))
        let second = LedgerRecord(kind: "turn", at: first.at.addingTimeInterval(-500),
                                  device: "cloud-zz", seq: 1, prev: nil, after: [first.id],
                                  body: body("answered"))
        try one.adopt(second)

        let fresh = Ledger(directory: dir, device: "mac-one")
        #expect(fresh.all().map(\.id) == [first.id, second.id])
    }

    // MARK: Forward compatibility

    @Test func recordsFromANewerVersionDoNotCrashAnOlderReader() throws {
        let dir = tempDirectory()
        let ledger = Ledger(directory: dir, device: "mac-test")
        let known = try ledger.append(kind: "turn", body: body("one"))

        // A kind this build has never heard of, extra top-level fields, and a
        // body with a shape it does not know — all written by a later Moe.
        let future = """
        {"id":"ffff0000ffff0000ffff0000ffff0000","kind":"quorum","at":"2099-01-01T00:00:00.000Z",\
        "device":"cloud-w7","seq":9,"prev":null,"after":["\(known.id)"],"schema":42,\
        "body":{"thread":"th-1","weights":[1,2.5,true,null],"nested":{"deep":{"deeper":"yes"}}}}
        """
        let file = ledger.fileForThisDevice
        var bytes = try Data(contentsOf: file)
        bytes.append(contentsOf: Array((future + "\n").utf8))
        try bytes.write(to: file)

        let all = Ledger(directory: dir, device: "mac-test").all()
        #expect(all.count == 2)
        #expect(all.map(\.kind).contains("quorum"))
        // Nothing in the unknown body is lost, so re-writing it is faithful.
        let unknown = try #require(all.first { $0.kind == "quorum" })
        #expect(unknown.body["nested"]?["deep"]?["deeper"]?.stringValue == "yes")
        let reencoded = try #require(LedgerRecord.decode(line: try unknown.encoded()))
        #expect(reencoded == unknown)
    }

    // MARK: Ordering

    @Test func aRecordSortsBehindWhatItsAuthorHadSeen() throws {
        // Two devices, and the second one's clock is wrong — the only thing
        // that keeps the order right is `after`.
        let late = Date(timeIntervalSince1970: 2_000)
        let early = Date(timeIntervalSince1970: 1_000)
        let first = LedgerRecord(kind: "turn", at: late, device: "mac-1", seq: 1,
                                 prev: nil, after: [], body: body("asked"))
        let reply = LedgerRecord(kind: "turn", at: early, device: "cloud-1", seq: 1,
                                 prev: nil, after: [first.id], body: body("answered"))

        let ordered = Ledger.ordered([reply, first])
        #expect(ordered.map(\.id) == [first.id, reply.id])
    }
}
