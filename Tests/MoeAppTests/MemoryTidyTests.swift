import Foundation
import Testing
@testable import Moe

/// **The nightly tidy on the Memory page** (docs/PROACTIVE-MEMORY.md §3.4,
/// slice 4): what the tidy set aside is under Past with Restore, and a
/// deleted fact noticed again is a "Remember this again?" card.
///
/// Falsifiers: drop `tidied()` from `lines()` (nothing under Past), send
/// Restore to profile.py instead of cli.py undo, show a revival as an
/// ordinary line, or answer one with `confirm` — each turns a test red.
@Suite("Memory › nightly tidy")
struct MemoryTidyTests {

    // The exact shape `cli.py tidied --json` prints (claimstore/tidy.py `recent`).
    static let tidied = """
    [{"target": "user", "before": [{"id": "a1", "text": "Lives in Brooklyn", "source": "moe:turn", "key": null},
       {"id": "a2", "text": "Lives in Brooklyn, NY", "source": "moe:turn", "key": null}],
      "after": [{"id": "b1", "text": "Lives in Brooklyn, New York"}], "do": "merge", "why": "same",
      "n": "2026-09-25T031500-1", "at": 1.0},
     {"target": "memory", "before": [{"id": "c1", "text": "Dentist next Tuesday", "source": "moe:turn", "key": null}],
      "after": [], "do": "retire", "why": "past", "n": "2026-09-25T031500-2", "at": 1.0},
     {"target": "memory", "before": [{"id": "d1", "text": "Undone already", "source": "moe:turn", "key": null}],
      "after": [], "do": "retire", "why": "past", "n": "2026-09-24T031500-1", "at": 1.0, "undone": 2.0}]
    """

    static let revivals = """
    [{"id": "e1", "target": "memory", "text": "Invoices go out on the 1st", "by_person": true}]
    """

    @Test func tidiedLinesAreInPastWithTheirChange() {
        let lines = MemoryReader.parseTidied(Self.tidied)
        #expect(lines.map(\.text) == ["Lives in Brooklyn", "Lives in Brooklyn, NY", "Dentist next Tuesday"])
        #expect(lines.allSatisfy { !$0.active })
        #expect(lines[0].tidyChange == "2026-09-25T031500-1")
        #expect(lines[0].date == "2026-09-25")
        #expect(lines[0].source == "Tidied overnight · Merged into “Lives in Brooklyn, New York”")
        #expect(lines[2].source == "Tidied overnight · Over, so set aside")
        let past = MemoryReader.past(lines)
        #expect(past.count == 3 && past.allSatisfy { $0.role == .past })
    }

    @Test func restoreIsCliUndo() {
        #expect(MemoryReader.memoryCommand(.undoTidy(change: "2026-09-25T031500-1"), cli: "cli.py")
                == ["cli.py", "undo", "2026-09-25T031500-1", "--json"])
        #expect(MemoryReader.command(.undoTidy(change: "x"), script: "profile.py") == nil)
    }

    @Test func aRevivalIsACardNotALine() {
        let revival = MemoryReader.parseRevivals(Self.revivals)
        #expect(revival.count == 1 && revival[0].revival && revival[0].ledgerID == "e1")
        let secs = MemoryReader.sections(lines: revival, checks: [])
        let you = secs.first { $0.id == MemoryTab.you.rawValue }!.items
        let things = secs.flatMap(\.items).filter { $0.role != .check }
        #expect(you.isEmpty && things.isEmpty)
        #expect(MemoryReader.past(revival).isEmpty)
        let cards = MemoryReader.cards([], lines: revival)
        #expect(cards.count == 1)
        #expect(cards[0].prompt == "Remember this again?")
        #expect(cards[0].label == "You deleted this before")
    }

    @Test func aRevivalIsAnsweredWithRevive() {
        let card = MemoryReader.cards([], lines: MemoryReader.parseRevivals(Self.revivals))[0]
        #expect(MemoryReader.plan(card, .yes) == [.revive(id: "e1", keep: true)])
        #expect(MemoryReader.plan(card, .no) == [.revive(id: "e1", keep: false)])
        #expect(MemoryReader.plan(card, .other("something")) == [])
        // Its row in the list view cannot be edited into a correct/delete.
        let row = MemoryItem.of(MemoryReader.parseRevivals(Self.revivals)[0], role: .check)
        #expect(MemoryReader.plan(row, draft: "") == .nothing)
        #expect(MemoryReader.plan(row, draft: "other words") == .nothing)
        #expect(MemoryReader.memoryCommand(.revive(id: "e1", keep: true), cli: "cli.py")
                == ["cli.py", "revive", "e1", "yes", "--json"])
    }
}
