import Foundation
import Testing
@testable import MoeBrain

/// The persona file is named for no vendor.
///
/// It was `CLAUDE.md` until 2026-09-04, which told a Codex or plain-API-key
/// user something false about a file in their own directory. Nothing ever
/// auto-discovered that name — the Claude Code workspace is
/// `~/.hermes/claude-code/workspace`, not `~/.moe`, and Moe reads the file and
/// injects it itself, which is why the persona already reached every provider.
/// So this was a misleading name rather than a functional dependency, and
/// `AGENTS.md` is the cross-vendor convention several agents read natively.
///
/// The migration logic lives in `Paths` (the app target). What is testable
/// without a filesystem is the rule it follows, which is the same rule the
/// `~/.moe` home migration uses: never merge two candidates.
struct PersonaFileTests {

    /// Mirrors `Paths.migratePersonaFile`'s decision table.
    enum Decision: Equatable {
        case nothingToMigrate
        case rename
        case keepBothPreferNew
        case leaveForeignLinkAlone
    }

    func decide(oldExists: Bool, newExists: Bool,
                oldIsLinkTo: String? = nil,
                newPath: String = "/home/AGENTS.md") -> Decision {
        if let dest = oldIsLinkTo {
            return dest == newPath ? .nothingToMigrate : .leaveForeignLinkAlone
        }
        if !oldExists { return .nothingToMigrate }
        if newExists { return .keepBothPreferNew }
        return .rename
    }

    @Test func aFreshInstallHasNothingToMigrate() {
        #expect(decide(oldExists: false, newExists: false) == .nothingToMigrate)
        #expect(decide(oldExists: false, newExists: true) == .nothingToMigrate)
    }

    @Test func anExistingInstallIsRenamedOnce() {
        #expect(decide(oldExists: true, newExists: false) == .rename)
    }

    @Test func alreadyMigratedIsASteadyStateNotAReRun() {
        // After the rename the old name is a symlink to the new one; seeing
        // that again must do nothing at all.
        #expect(decide(oldExists: true, newExists: true,
                       oldIsLinkTo: "/home/AGENTS.md") == .nothingToMigrate)
    }

    @Test func twoRealFilesAreNeverMerged() {
        // Merging two personas is how someone loses what they wrote. The new
        // name wins and the old file is left exactly as it is.
        #expect(decide(oldExists: true, newExists: true) == .keepBothPreferNew)
    }

    @Test func someoneElsesSymlinkIsLeftAlone() {
        // If CLAUDE.md points somewhere we did not put it, it is not ours.
        #expect(decide(oldExists: true, newExists: false,
                       oldIsLinkTo: "/somewhere/else.md") == .leaveForeignLinkAlone)
    }

    /// The managed section must key off the file's contents, not its name, so
    /// a renamed file keeps its version stamp and is not re-appended.
    @Test func aRenamedFileKeepsItsManagedSection() {
        let doc = """
        # Alfie

        Someone's own notes.

        \(ManagedSection.block(id: "driving-the-mac", version: 2, body: "old"))
        """
        let after = ManagedSection.apply(id: "driving-the-mac", version: 3,
                                         body: "new", to: doc)
        #expect(after.outcome == .updated(from: 2))
        #expect(after.text.contains("Someone's own notes."))
        // ...and not appended a second time under the new filename.
        #expect(after.text.components(separatedBy: "moe:begin driving-the-mac").count == 2)
    }
}
