import Foundation
import Testing
@testable import Moe

/// Ticket #10, 2026-09-23. The persona's "How to answer" list said "Don't
/// preface with what you're about to do" while the per-turn reminder
/// (`BrainPrompt.deliveryReminder`) says "say a plain sentence about what you
/// are about to do", and it answered an unchecked fact with "say you could
/// not confirm it" instead of the next way of finding out. The brain said
/// "let me check China Eastern directly for a real fare", ran one search, and
/// settled for "figure around there".
struct FollowThroughPersonaTests {

    private func scratch(_ text: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-agents-\(UUID().uuidString).md")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a fresh AGENTS.md treats an announcement as a promise, and agrees with the reminder")
    func freshTemplate() {
        let text = FirstRun.agentsMd
        #expect(text.contains(FirstRun.announceBullets))
        #expect(text.contains(FirstRun.uncheckedFactLines))
        #expect(!text.contains(FirstRun.legacyAnnounceBullets))
        #expect(!text.contains(FirstRun.legacyUncheckedFactLines))
        #expect(!text.contains("Don't preface with what you're about to do"))
        // The reminder this has to agree with still asks for the opener.
        #expect(BrainPrompt.deliveryReminder.contains("say a plain sentence about what you are about to do"))
    }

    @Test("an install carrying the old bullets gets the new ones once, and nothing else moves")
    func legacyIsReplaced() throws {
        let before = """
        # Moe

        Mine: I like short answers.

        ## How to answer

        - Be brief.
        \(FirstRun.legacyAnnounceBullets)
        - If you're unsure about a judgment call, say so and give your best guess.
        \(FirstRun.legacyUncheckedFactLines)
        - Last bullet.
        """
        let url = scratch(before)
        FirstRun.refreshManagedSections(at: url)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains(FirstRun.announceBullets))
        #expect(after.contains(FirstRun.uncheckedFactLines))
        #expect(!after.contains("Don't preface with what you're about to do"))
        #expect(!after.contains("guess: say you could not confirm it."))
        #expect(after.contains("Mine: I like short answers."))
        #expect(after.contains("- Last bullet."))
        FirstRun.refreshManagedSections(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == after)
    }

    @Test("a bullet the person rewrote is theirs and stays, while the untouched one beside it upgrades")
    func editedBulletStays() throws {
        // The announce bullets rewritten by the person; the unchecked-fact
        // lines left exactly as shipped. Only the second may move.
        let mine = "- Say the answer first. Never announce anything, ever.\n"
            + "- Never say \"I'll go check\" — mine, keep it."
        let before = """
        # Moe

        - Be brief.
        \(mine)
        - If you're unsure about a judgment call, say so and give your best guess.
        \(FirstRun.legacyUncheckedFactLines)
        - Last bullet.
        """
        let url = scratch(before)
        FirstRun.refreshManagedSections(at: url)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains(mine), "the person's own bullet is left exactly as they wrote it")
        #expect(!after.contains(FirstRun.announceBullets), "an edited bullet gets nothing added beside it")
        #expect(after.contains(FirstRun.uncheckedFactLines), "the untouched legacy lines are upgraded")
        #expect(!after.contains("guess: say you could not confirm it."))
        #expect(after.contains("- Last bullet."))
    }
}

/// 2026-10-06: 73% of spoken turns thought before their first word, 2.8 s
/// p50 to the first token against 0.93 s without. The reminder asks for the
/// first sentence before the deliberation, on spoken turns.
struct SpokenFirstSentenceRuleTests {
    @Test func theReminderPutsTheFirstSentenceFirst() {
        #expect(BrainPrompt.deliveryReminder.contains("Spoken, the first sentence is the wait."))
    }
}
