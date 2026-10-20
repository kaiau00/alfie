import Foundation
import Testing
@testable import MoeBrain

/// The rule `PromptSource` exists to hold: **the system prompt is rebuilt
/// when what it was built from actually changed, and at no other time.**
///
/// Both halves of that cost something real, which is why both are tested from
/// both sides:
///
/// - Never firing is the bug of 2026-09-07. Two Gmail accounts were connected
///   at 21:34, `_connections.md` still said what it had said at 21:27, and at
///   21:36 Moe answered "no mailbox is added yet" and offered to walk the
///   owner through connecting the mailbox he had just connected.
/// - Firing too often costs 5–7 s of respawn per turn. `sync.sh` rewrites
///   `_connections.md` every ten minutes whether or not anything changed, so
///   anything keyed on mtime rather than bytes buys six respawns an hour for
///   nothing — the exact bill `BrainPrompt.briefBlock()` was written to stop
///   paying.
///
/// These write real files and read real answers. There is no decision table
/// here for the test to agree with.
struct PromptSourceTests {

    /// A scratch file that exists for the length of one test.
    private func scratch(_ body: (URL) throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("promptsource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("_connections.md"))
    }

    @Test func beforeThePromptIsBuiltNothingIsStale() throws {
        try scratch { url in
            let source = PromptSource(url: url)
            // No prompt has been built, so there is nothing to be stale. A
            // `true` here would rebuild the prompt on the first turn of every
            // conversation, for nothing.
            #expect(source.isStale() == false)
            try "Gmail\n".write(to: url, atomically: true, encoding: .utf8)
            #expect(source.isStale() == false)
        }
    }

    @Test func aMissingFileReadsAsEmptyRatherThanThrowing() throws {
        try scratch { url in
            #expect(PromptSource.read(url) == "")
            var source = PromptSource(url: url)
            #expect(source.take() == "")
        }
    }

    @Test func anUnchangedFileIsNeverStaleHoweverOftenItIsAsked() throws {
        try scratch { url in
            try "Connected: Gmail\n".write(to: url, atomically: true, encoding: .utf8)
            var source = PromptSource(url: url)
            _ = source.take()
            for _ in 0..<20 { #expect(source.isStale() == false) }
        }
    }

    /// The one that stops this becoming a respawn every ten minutes.
    ///
    /// `sync.sh` writes `context/_connections.md` on every tick — same bytes,
    /// new file, new mtime and new inode, because it writes a temp file and
    /// renames it. A watcher keyed on the file's metadata would call that a
    /// change six times an hour.
    @Test func rewritingIdenticalBytesIsNotAChange() throws {
        try scratch { url in
            let same = "Connected: Gmail\n"
            try same.write(to: url, atomically: true, encoding: .utf8)
            var source = PromptSource(url: url)
            _ = source.take()

            let before = try FileManager.default.attributesOfItem(atPath: url.path)
            // Exactly what sync.sh does: write beside it, rename over it.
            let tmp = url.deletingLastPathComponent().appendingPathComponent("._connections.md.tmp")
            try same.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)

            // Prove the metadata really did move, or this test is proving
            // nothing at all — an assertion about a rewrite that did not
            // happen passes for ever.
            let inodeBefore = before[.systemFileNumber] as? Int
            let inodeAfter = after[.systemFileNumber] as? Int
            #expect(inodeBefore != nil && inodeAfter != nil)
            #expect(inodeBefore != inodeAfter)

            #expect(source.isStale() == false)
        }
    }

    @Test func aRealChangeIsStaleUntilItIsTaken() throws {
        try scratch { url in
            try "Connected: Gmail\n".write(to: url, atomically: true, encoding: .utf8)
            var source = PromptSource(url: url)
            _ = source.take()
            #expect(source.isStale() == false)

            // The moment of the bug: a second mailbox arrives.
            try "Connected: Gmail (one, two)\n".write(to: url, atomically: true, encoding: .utf8)
            #expect(source.isStale() == true)
            // Still stale until the prompt is actually rebuilt — a flag that
            // cleared itself on being read would lose the rebuild if anything
            // asked twice.
            #expect(source.isStale() == true)

            #expect(source.take() == "Connected: Gmail (one, two)\n")
            #expect(source.isStale() == false)
        }
    }

    @Test func disconnectingTheLastServiceIsAChangeToo() throws {
        try scratch { url in
            try "Connected: Gmail\n".write(to: url, atomically: true, encoding: .utf8)
            var source = PromptSource(url: url)
            _ = source.take()
            // `hermes-connections.py refresh` writes an empty file when
            // nothing is connected, deliberately: a person who disconnected
            // everything must not keep a prompt saying they are connected.
            try "".write(to: url, atomically: true, encoding: .utf8)
            #expect(source.isStale() == true)

            _ = source.take()
            try FileManager.default.removeItem(at: url)
            // Empty and absent are the same thing to `BrainPrompt`, so they
            // must be the same thing here: removing an already-empty file is
            // not a change, and must not respawn the child.
            #expect(source.isStale() == false)
        }
    }
}

/// The rebuild says what changed (2026-10-06): 53 rebuilds in three weeks
/// with no connect action near them, and nothing to say what flapped.
struct PromptSourceChangedLinesTests {

    @Test func itNamesTheLinesThatWentAndCame() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "Connected:\n  - Gmail (a@x.com)\n  - GitHub\n".write(to: url, atomically: true, encoding: .utf8)
        var source = PromptSource(url: url)
        _ = source.take()
        #expect(source.changedLines().isEmpty)
        try "Connected:\n  - Gmail (a@x.com, b@y.com)\n  - GitHub\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(source.changedLines() == ["- - Gmail (a@x.com)", "+ - Gmail (a@x.com, b@y.com)"])
    }
}
