import Foundation
import Testing
@testable import MoeBrain

/// `~/.moe/CLAUDE.md` is written once and never again, so every prompt fix
/// after someone's first run has reached nobody. These tests pin the way out:
/// Moe rewrites the block it owns, and touches nothing else.
struct ManagedSectionTests {

    let id = "driving-the-mac"

    func doc(_ version: Int, body: String = "old rules") -> String {
        """
        # Alfie

        The person's own opening notes.

        \(ManagedSection.block(id: id, version: version, body: body))

        Their notes after it.
        """
    }

    // MARK: The bug this exists for

    @Test func anOlderBlockIsReplacedInPlace() {
        let r = ManagedSection.apply(id: id, version: 3, body: "new rules",
                                     to: doc(2))
        #expect(r.outcome == .updated(from: 2))
        #expect(r.text.contains("new rules"))
        #expect(!r.text.contains("old rules"))
        #expect(r.text.contains("moe:begin driving-the-mac v3"))
    }

    @Test func thePersonsOwnTextSurvivesAnUpdate() {
        let r = ManagedSection.apply(id: id, version: 3, body: "new rules",
                                     to: doc(2))
        #expect(r.text.contains("The person's own opening notes."))
        #expect(r.text.contains("Their notes after it."))
        #expect(r.text.hasPrefix("# Alfie"))
    }

    @Test func thesameVersionIsLeftByteIdentical() {
        // Runs on every launch; it must be a no-op when nothing changed.
        let before = doc(3, body: "current rules")
        let r = ManagedSection.apply(id: id, version: 3, body: "current rules",
                                     to: before)
        #expect(r.outcome == .unchanged)
        #expect(r.text == before)
    }

    @Test func aNewerBlockIsAlsoReplaced() {
        // A file stamped by a build that is no longer installed would
        // otherwise pin the agent to instructions whose code is gone.
        let r = ManagedSection.apply(id: id, version: 3, body: "new rules",
                                     to: doc(9))
        #expect(r.outcome == .updated(from: 9))
        #expect(r.text.contains("moe:begin driving-the-mac v3"))
    }

    // MARK: The file everyone already has — no markers at all

    @Test func anUnmarkedDocumentGainsTheBlockAtTheEnd() {
        let existing = "# Alfie\n\nHand-written prompt from months ago.\n"
        let r = ManagedSection.apply(id: id, version: 1, body: "the rules",
                                     to: existing)
        #expect(r.outcome == .appended)
        #expect(r.text.hasPrefix(existing))
        #expect(r.text.contains("the rules"))
        // the person's own words stay first
        #expect(r.text.range(of: "Hand-written")!.lowerBound <
                r.text.range(of: "moe:begin")!.lowerBound)
    }

    @Test func appendingLeavesExactlyOneBlankLineAndATrailingNewline() {
        let r = ManagedSection.apply(id: id, version: 1, body: "x",
                                     to: "# Alfie\nno trailing newline")
        #expect(r.text.contains("no trailing newline\n\n<!-- moe:begin"))
        #expect(r.text.hasSuffix("-->\n"))
    }

    @Test func anEmptyDocumentGetsJustTheBlock() {
        let r = ManagedSection.apply(id: id, version: 1, body: "x", to: "")
        #expect(r.outcome == .appended)
        #expect(r.text == ManagedSection.block(id: id, version: 1, body: "x") + "\n")
    }

    // MARK: Not touching what is not ours

    @Test func aDifferentManagedBlockIsUntouched() {
        let other = ManagedSection.block(id: "voice", version: 7, body: "voice rules")
        let r = ManagedSection.apply(id: id, version: 2, body: "new",
                                     to: other + "\n\n" + doc(1))
        #expect(r.text.contains("moe:begin voice v7"))
        #expect(r.text.contains("voice rules"))
        #expect(r.outcome == .updated(from: 1))
    }

    @Test func applyingTwiceIsIdempotent() {
        let once = ManagedSection.apply(id: id, version: 4, body: "b", to: doc(1)).text
        let twice = ManagedSection.apply(id: id, version: 4, body: "b", to: once)
        #expect(twice.outcome == .unchanged)
        #expect(twice.text == once)
    }

    @Test func aTruncatedBlockIsNotEditedInPlace() {
        // An opening marker with no close: editing by range would eat the rest
        // of the person's file. Append instead and leave the wreckage visible.
        let broken = "# Alfie\n\(ManagedSection.begin(id, 1))\nhalf a block, no end\n"
        let r = ManagedSection.apply(id: id, version: 2, body: "new", to: broken)
        #expect(r.outcome == .appended)
        #expect(r.text.contains("half a block, no end"))
        #expect(r.text.contains("moe:begin driving-the-mac v2"))
    }

    @Test func aMalformedVersionIsTreatedAsStaleAndRewritten() {
        let weird = "# Alfie\n<!-- moe:begin driving-the-mac vXYZ -->\nold\n\(ManagedSection.end(id))\n"
        let r = ManagedSection.apply(id: id, version: 1, body: "new", to: weird)
        #expect(r.outcome == .updated(from: -1))
        #expect(r.text.contains("new"))
        #expect(!r.text.contains("old"))
    }

    @Test func bodyContainingMarkerLikeTextDoesNotBreakTheNextUpdate() {
        let tricky = "talk about <!-- moe:end driving-the-mac --> in prose"
        let first = ManagedSection.apply(id: id, version: 1, body: tricky, to: "# Alfie\n").text
        let second = ManagedSection.apply(id: id, version: 2, body: "clean", to: first)
        #expect(second.outcome == .updated(from: 1))
        #expect(second.text.contains("clean"))
        // the stray end-marker inside the old body is gone with it
        #expect(second.text.components(separatedBy: ManagedSection.end(id)).count == 2)
    }
}
