import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Moe

/// Owner feedback on the Memory page, 2026-09-22: hover must never re-wrap
/// a line; To check is one card at a time; every section, every line and the
/// whole memory can be talked through with Moe; lines read as "you".
///
/// Falsifiers: put the source back inside the row's HStack, or make the
/// action column's width depend on hover, and `hoverNeverReflows` goes red;
/// drop a rule from `shown`, a case from `plan(card:)`, or a file name from
/// a draft, and the matching test goes red.

private func line(_ id: String, _ file: String, _ text: String, active: Bool = true) -> MemoryLine {
    MemoryLine(id: "claim:" + id, section: .things, text: text, origin: .claim(id: id),
               source: "WhatsApp · Jul 16", sureness: nil, file: file, active: active)
}

@Suite("Memory › lines said as you")
struct MemoryShownTests {
    @Test("'the user' becomes 'you'; quoted text and the person's own words stay")
    func secondPerson() {
        #expect(MemoryReader.shown("Ima — the user's mother; calls the user 'Jordie'")
                == "Ima — your mother; calls you 'Jordie'")
        #expect(MemoryReader.shown("The user is planning a trip") == "You are planning a trip")
        #expect(MemoryReader.shown("User's brother runs it this year") == "Your brother runs it this year")
        #expect(MemoryReader.shown("Does the user still run?") == "Do you still run?")
        #expect(MemoryReader.shown("Is \"the user is kind\" right?") == "Is \"the user is kind\" right?")
        #expect(MemoryReader.shown("My mother") == "My mother")
        #expect(MemoryReader.shown("they shared costs and the user reports breakdowns to him")
                == "They shared costs and you report breakdowns to him")
        #expect(MemoryReader.shown("coordinates logistics with the user: tents") == "Coordinates logistics with you: tents")
        #expect(MemoryReader.shown("The user carries it; the user watches") == "You carry it; you watch")
        #expect(MemoryReader.shown("Uses Supabase for users") == "Uses Supabase for users")
    }

    @Test("the page draws the shown text, and saving it unchanged writes nothing")
    func itemsAreShown() {
        let l = line("a", "people", "**Ima** — the user's mother")
        let item = MemoryItem.of(l)
        #expect(item.text == "Ima — your mother")
        #expect(MemoryReader.plan(item, draft: "Ima — your mother") == .nothing)
        #expect(MemoryReader.plan(item, draft: "Ima — mother") == .correct(id: "a", text: "**Ima** — mother"))
    }
}

@Suite("Memory › To check, one at a time")
struct MemoryCardTests {
    let lines = [line("a", "identity", "Works from the studio on Tuesdays"),
                 line("b", "identity", "Works from home on Tuesdays"),
                 line("h", "threads", "Half marathon on October 12"),
                 line("u", "people", "**Marco** — landlord, the user's studio"),
                 line("p", "people", "**Past** — gone", active: false)]
    let list = [MemoryCheck(kind: .contradicts, text: "Which is right: \"A\" or \"B\"?", ids: ["a", "b"]),
                MemoryCheck(kind: .question, text: "Is \"Half marathon on October 12\" still on?", ids: ["h"]),
                MemoryCheck(kind: .question, text: "Still learning Spanish?", ids: []),
                MemoryCheck(kind: .unsure, text: "**Marco** — landlord", ids: ["u"]),
                MemoryCheck(kind: .new, text: "past", ids: ["p"])]

    @Test("each kind becomes one card, asked in 'you' form; an archived line is not asked")
    func cards() {
        let cards = MemoryReader.cards(list, lines: lines)
        #expect(cards.count == 4)
        #expect(cards[0].prompt == "Which of these is right?")
        #expect(cards[0].choices == ["Works from the studio on Tuesdays", "Works from home on Tuesdays"])
        #expect(cards[1].prompt == "Is \"Half marathon on October 12\" still on?")
        #expect(cards[2].prompt == "Still learning Spanish?" && cards[2].detail == nil)
        #expect(cards[3].prompt == "Is this right?")
        #expect(cards[3].detail == "Marco — landlord, your studio")
        #expect(cards[3].label == "Moe isn't sure")
    }

    @Test("Yes / No / Something else write through profile.py's verbs")
    func answers() {
        let c = MemoryReader.cards(list, lines: lines)
        // A line: confirm, delete, correct (bold name kept).
        #expect(MemoryReader.plan(c[3], .yes) == [.confirm(id: "u")])
        #expect(MemoryReader.plan(c[3], .no) == [.forget(id: "u")])
        #expect(MemoryReader.plan(c[3], .other("Marco — old landlord")) == [.correct(id: "u", text: "**Marco** — old landlord")])
        #expect(MemoryReader.plan(c[3], .other("  ")) == [])
        // A question about a line: the same verbs on the line (each closes it).
        #expect(MemoryReader.plan(c[1], .yes) == [.confirm(id: "h")])
        #expect(MemoryReader.plan(c[1], .no) == [.forget(id: "h")])
        // A question about nothing: answered, in the person's words.
        #expect(MemoryReader.plan(c[2], .yes) == [.answer(question: "Still learning Spanish?", text: "Still learning Spanish? Yes.")])
        #expect(MemoryReader.plan(c[2], .other("Stopped in May")) == [.answer(question: "Still learning Spanish?", text: "Stopped in May")])
        // A contradiction: the chosen line is confirmed; something else is
        // answered first, then both lines forgotten.
        #expect(MemoryReader.plan(c[0], .pick(1)) == [.confirm(id: "b")])
        #expect(MemoryReader.plan(c[0], .other("Office on Wednesdays"))
                == [.answer(question: "Which is right: \"A\" or \"B\"?", text: "Office on Wednesdays"),
                    .forget(id: "a"), .forget(id: "b")])
        #expect(MemoryReader.command(.confirm(id: "u"), script: "p.py") == ["p.py", "confirm", "u", "--json"])
    }
}

@Suite("Memory › a card is answered the way its question asks")
struct MemoryCardShapeTests {
    @Test("yes-or-no questions get Yes and No; the rest get a box")
    func shapes() {
        for q in ["Still learning Spanish?",
                  "Is Marco still your landlord, or did that change with the move?",
                  "Is the 'chicken man' the same person as Modche?",
                  "Are you still at the studio or not?"] {
            #expect(CheckCard.isYesNo(q), "\(q)")
        }
        for q in ["One line reads \"he ran one part of it\" — unclear who \"he\" is or what it refers to.",
                  "Who is \"he\" in \"he ran the other part\"?",
                  "What's the name of your landlord?",
                  "Is Dana your sister or your cousin?",
                  "Which day is the half marathon?"] {
            #expect(!CheckCard.isYesNo(q), "\(q)")
        }
    }

    @Test("an open question is answered in words and never rewrites its line")
    func openAnswers() {
        let l = line("h", "threads", "He ran one part of it and ran the other")
        let q = "One line reads \"He ran one part of it and ran the other\" — unclear who \"he\" is."
        let card = MemoryReader.cards([MemoryCheck(kind: .question, text: q, ids: ["h"])], lines: [l])[0]
        #expect(card.shape == .open)
        #expect(MemoryReader.plan(card, .other(" Mendy, my brother ")) == [.answer(question: q, text: "Mendy, my brother")])
        #expect(MemoryReader.plan(card, .other("  ")) == [])
        #expect(MemoryReader.plan(card, .yes) == [])
        #expect(MemoryReader.plan(card, .no) == [])
        #expect(MemoryReader.plan(card, .dismiss) == [.dismiss(question: q)])
    }

    @Test("quotes are curled the way a page sets them")
    func curled() {
        #expect(CheckCardView.curled("Is the 'chicken man' \"he\"? It's (\"x\")")
                == "Is the ‘chicken man’ “he”? It’s (“x”)")
    }
}

@Suite("Memory › talking it through with Moe")
struct MemoryTalkDraftTests {
    @Test("every section's draft names its files; Past has none")
    func drafts() {
        #expect(MemoryTalk.draft(for: .you) == "Let's go through what you know about me — the You lines in my memory (identity.md, preferences.md, voice.md and USER.md). Ask me about anything that looks off, one at a time, and fix it as we go.")
        #expect(MemoryTalk.draft(for: .people)?.contains("(people.md)") == true)
        #expect(MemoryTalk.draft(for: .now)?.contains("(threads.md)") == true)
        #expect(MemoryTalk.draft(for: .check)?.contains("questions.md and check.md") == true)
        #expect(MemoryTalk.draft(for: .chats)?.contains("(MEMORY.md)") == true)
        #expect(MemoryTalk.draft(for: .past) == nil)
        for f in ["identity.md", "preferences.md", "voice.md", "people.md", "threads.md", "USER.md", "MEMORY.md"] {
            #expect(MemoryTalk.everything.contains(f), "\(f)")
        }
    }

    @Test("Discuss quotes the line as shown and names where it lives")
    func discuss() {
        let item = MemoryItem.of(line("a", "people", "**Ima** — the user's mother"))
        #expect(MemoryTalk.discuss(item)
                == "Let's talk about this memory: “Ima — your mother” (from people.md). Is it right, and should we change it?")
        let hermes = MemoryLine(id: "hermes:1", section: .you, text: "Prefers short answers",
                                origin: .hermes(group: "you"), source: "", sureness: nil)
        #expect(MemoryTalk.discuss(.of(hermes)).contains("(from USER.md)"))
        let notes = MemoryLine(id: "hermes:2", section: .things, text: "Invoices on the 1st",
                               origin: .hermes(group: "memory"), source: "", sureness: nil)
        #expect(MemoryTalk.discuss(.of(notes)).contains("(from MEMORY.md)"))
    }
}

/// The row, laid out for real in a window-less hosting view, hovered and
/// not: the words must have the same width and the row the same height.
@MainActor
@Suite("Memory › hover never reflows a row")
struct MemoryRowLayoutTests {
    private struct Host: View {
        let item: MemoryItem
        let hovered: Bool
        let measured: (CGFloat) -> Void
        @FocusState private var focus: MemoryPane.Focus?
        @State private var draft = ""

        var body: some View {
            MemoryRowView(item: item, text: item.text, meta: "WhatsApp · Jul 16", editing: false,
                          selected: false, hovered: hovered, draft: $draft, focus: $focus,
                          begin: {}, save: {}, cancel: {}, forget: {}, confirm: {}, restore: {},
                          hover: { _ in }, measured: measured)
                .frame(width: 560)
        }
    }

    private func layout(_ item: MemoryItem, hovered: Bool) -> (width: CGFloat, height: CGFloat) {
        _ = NSApplication.shared
        var width: CGFloat = 0
        let host = NSHostingView(rootView: Host(item: item, hovered: hovered) { width = $0 })
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return (width, host.fittingSize.height)
    }

    @Test("same words width and same height, hovered or not, for every row kind")
    func hoverNeverReflows() {
        let long = "**Rebecca** — family member (likely sister); calls the user by the nickname 'Jordie' and keeps him informed of family events, e.g. reminded him of their grandfather's birthday"
        let l = line("s", "people", long)
        for role in [MemoryItem.Role.line, .check, .past] {
            let item = MemoryItem.of(l, role: role)
            let still = layout(item, hovered: false)
            let hover = layout(item, hovered: true)
            #expect(still.width > 300, "\(role): \(still.width)")
            #expect(still.width == hover.width, "\(role): \(still.width) vs \(hover.width)")
            #expect(still.height == hover.height, "\(role): \(still.height) vs \(hover.height)")
            // The words use the row less one fixed column, not less the source.
            #expect(still.width == 560 - MemoryRowView.actionWidth - 12, "\(role): \(still.width)")
        }
    }
}
