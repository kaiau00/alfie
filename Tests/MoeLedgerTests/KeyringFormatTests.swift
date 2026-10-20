import Foundation
import Testing
import CryptoKit
@testable import MoeLedger

/// `thread-keys.json` is the one file in this design whose contents cannot be
/// reconstructed from anything else, and two implementations write it: the
/// Swift app, and Python's `moeledger.vault.Keyring` inside Hermes. `read` has
/// always been careful that a shape it does not understand is left alone
/// rather than replaced. `write` was not: it built the object from scratch,
/// so a field one implementation added was deleted by the next write of the
/// other — on a Mac, typically within minutes, and with no sign of it.
///
/// That is a prerequisite for CLOUD-PLAN §15.1's `retired` field, and it is
/// worth its own tests because the failure is invisible: everything keeps
/// working, and only the new field disappears.
@Suite struct KeyringFormatTests {

    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyring-format-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("thread-keys.json")
    }

    private func onDisk(_ url: URL) -> [String: Any] {
        let data = try! Data(contentsOf: url)
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    /// The case that would have destroyed §15.1's retired keys.
    @Test func aFieldThisBuildDoesNotKnowSurvivesAWrite() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "thread-a")

        // Something a newer build — or the Python side — wrote.
        var body = onDisk(url)
        body["some_later_field"] = ["thread-a": ["opaque"]]
        body["written_by"] = "a build from the future"
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        // Any write at all: a mint is the commonest.
        let second = ThreadKeyring(url: url) { _ in }
        _ = try second.key(creatingFor: "thread-b")

        let after = onDisk(url)
        #expect(after["some_later_field"] != nil, "the unknown field was deleted by an ordinary mint")
        #expect(after["written_by"] as? String == "a build from the future")
        // And the fields this build owns are still its own.
        let keys = after["keys"] as! [String: String]
        #expect(keys["thread-a"] != nil && keys["thread-b"] != nil)
        #expect(after["version"] as? Int == 1)
    }

    @Test func aDestroyAlsoPreservesWhatItDoesNotUnderstand() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "thread-a")
        _ = try keyring.key(creatingFor: "thread-b")
        var body = onDisk(url)
        // A name this build genuinely does not know. This test first used
        // `retired`, which was unknown when it was written and is a field of
        // its own since §15.1 — so it started asserting that a KNOWN field
        // survives a destroy, which is a different claim and not this one's.
        body["some_later_field"] = ["thread-a": []]
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        try ThreadKeyring(url: url) { _ in }.destroy(thread: "thread-b")

        let after = onDisk(url)
        #expect(after["some_later_field"] != nil)
        #expect((after["keys"] as! [String: String])["thread-b"] == nil, "the destroy still happened")
    }

    /// A field that cannot round-trip through JSON must not wedge every future
    /// write of the keyring. Losing a field this build could never have used
    /// is much cheaper than a keyring that can no longer be saved.
    @Test func anUnserialisableFieldIsDroppedRatherThanBreakingTheWrite() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "thread-a")
        // Written as text, because JSONSerialization would refuse to produce
        // it — which is the point: a file on disk can hold what an encoder
        // will not emit.
        try """
        {"README": "x", "version": 1, "keys": {}, "odd": 1e999}
        """.write(to: url, atomically: true, encoding: .utf8)

        let second = ThreadKeyring(url: url) { _ in }
        #expect(throws: Never.self) { _ = try second.key(creatingFor: "thread-c") }
        #expect((onDisk(url)["keys"] as! [String: String])["thread-c"] != nil)
    }

    /// Nothing about the round trip may change what the file means.
    @Test func preservingExtrasDoesNotDisturbTheKeysThemselves() throws {
        let url = scratch()
        let first = ThreadKeyring(url: url) { _ in }
        let key = try first.key(creatingFor: "thread-a")
        var body = onDisk(url)
        body["some_later_field"] = ["something": "opaque"]
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        let second = ThreadKeyring(url: url) { _ in }
        _ = try second.key(creatingFor: "thread-b")
        let third = ThreadKeyring(url: url) { _ in }
        #expect(third.key(for: "thread-a") == key, "the original key changed under a rewrite")
    }
}
