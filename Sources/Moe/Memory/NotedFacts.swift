import Foundation
import MoeDesign
import SwiftUI

// "Noted · Undo" (docs/PROACTIVE-MEMORY.md §3.4; owner, 2026-09-24: under
// the answer, in the island and in Chat).
//
// After every turn claimstore's per-turn learning (claimstore/learn_turn.py)
// may keep a fact or two from what the person just said, and appends each
// to `~/.moe/memory/noted.jsonl`: `{at, claim, target, text, note}`, where
// `note` is the fact said back to them ("Dana is your business partner"),
// and `reply` the opening and closing words of the answer it followed.
// This reads that file and hangs each fact under the answer it came after,
// so the person sees what Moe learned from the thing they just said, and can
// take it back in one click. Undo is the Memory page's own Forget
// (`MemoryEdit.forgetMemory`, claimstore's cli.py delete), so a fact undone
// here is gone everywhere, the cloud included.
//
// The learning runs after the reply, on Hermes's background worker, and takes
// seconds (4–15 s measured), so the line arrives a moment after the answer.

struct NotedFact: Identifiable, Equatable {
    /// The claim id in the ledger: what Undo forgets.
    let claim: String
    let target: String
    /// The fact said to the person, in the second person.
    let note: String
    let at: Date
    /// The answer it followed, as learn_turn.py wrote it: that reply's
    /// opening and closing words. Empty on a line from an older learner.
    var replyHead = ""
    var replyTail = ""
    /// The opening of what the person said, that the answer answered.
    var said = ""
    var forgotten = false
    var id: String { claim }
}

enum NotedLog {
    static var url: URL { Paths.home.appendingPathComponent("memory/noted.jsonl") }

    /// A fact older than this when first seen is history, not news: it was
    /// learned while the app was closed, or by the cloud while the Mac slept,
    /// and belongs in the weekly digest rather than under today's answer.
    static let freshFor: TimeInterval = 15 * 60

    /// Every well-formed line, oldest first. A line that does not parse is
    /// skipped, never a reason to show nothing.
    static func parse(_ data: Data) -> [NotedFact] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let claim = obj["claim"] as? String, !claim.isEmpty,
                  let at = obj["at"] as? Double
            else { return nil }
            let text = (obj["text"] as? String) ?? ""
            let note = ((obj["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? text
            guard !note.isEmpty else { return nil }
            let reply = obj["reply"] as? [String: Any]
            return NotedFact(claim: claim, target: (obj["target"] as? String) ?? "memory",
                             note: note, at: Date(timeIntervalSince1970: at),
                             replyHead: (reply?["head"] as? String) ?? "",
                             replyTail: (reply?["tail"] as? String) ?? "",
                             said: (obj["said"] as? String) ?? "")
        }
    }

    /// Letters and digits only, lower-cased, tags gone: what the reply Hermes
    /// kept and the answer on screen are compared on. The screen's copy has
    /// had its point tags and end marker taken out (learn_turn.py takes the
    /// same out of its copy), and under a tool-using turn Hermes keeps only
    /// the last message where the screen shows all of them — so the reply's
    /// opening is looked for at the start of the answer, OR its close at the
    /// end, never anywhere in the middle.
    static func fold(_ text: String) -> String {
        let untagged = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return String(untagged.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// How much of each end of the reply is looked for.
    static let markLength = 40
    /// A reply shorter than this ("Sure.", "Done.") is too little to find
    /// by its ends — "sure" is inside "make sure" — so it must be the whole
    /// answer.
    static let shortest = 12

    /// Whether `turns[i]` is the answer `fact` was learned after: its reply,
    /// anchored at the answer's start or end (the whole answer, for a short
    /// one), and — when the line says — after the question it answered.
    static func followed(_ fact: NotedFact, in turns: [Turn], at i: Int) -> Bool {
        let turn = turns[i]
        guard turn.role == .moe, !turn.isStreaming else { return false }
        let text = fold(turn.text)
        guard !text.isEmpty else { return false }
        let head = fold(fact.replyHead), tail = fold(fact.replyTail)
        let answered: Bool
        if max(head.count, tail.count) < shortest {
            answered = text == head || text == tail
        } else {
            let h = String(head.prefix(markLength)), t = String(tail.suffix(markLength))
            answered = (h.count >= shortest && text.hasPrefix(h)) || (t.count >= shortest && text.hasSuffix(t))
        }
        guard answered else { return false }
        let said = String(fold(fact.said).prefix(markLength))
        guard !said.isEmpty else { return true }
        guard let q = turns[..<i].lastIndex(where: { $0.role == .you }) else { return false }
        let asked = fold(turns[q].text)
        return asked.hasPrefix(said) || said.hasPrefix(asked) && !asked.isEmpty
    }

    /// Hang each fresh, unseen fact under the answer it followed. Returns the
    /// turns changed and the claims consumed; a fact whose answer is not on
    /// screen (another conversation, or it was cleared) is consumed too, so
    /// it is not looked at again, and is never hung under some other answer.
    /// Pure, for the tests.
    ///
    /// Not by time: learning finishes 4–60 s after the reply, by which point
    /// the person has often asked the next thing, and "the newest answer
    /// before the fact" was that next answer, still streaming — or, after a
    /// switch, an answer in another thread (review 2026-09-24 §5).
    static func attach(_ facts: [NotedFact], to turns: [Turn], seen: Set<String>,
                       now: Date = Date()) -> (turns: [Turn], consumed: Set<String>) {
        var turns = turns
        var consumed = Set<String>()
        for fact in facts where !seen.contains(fact.claim) {
            consumed.insert(fact.claim)
            guard now.timeIntervalSince(fact.at) <= freshFor else { continue }
            let found: Int?
            if !fact.replyHead.isEmpty || !fact.replyTail.isEmpty {
                // The newest answer that fits, and only one given before
                // the fact was learned.
                found = turns.indices.last { turns[$0].at <= fact.at && followed(fact, in: turns, at: $0) }
            } else if let last = turns.indices.last, turns[last].role == .moe,
                      !turns[last].isStreaming, turns[last].at <= fact.at {
                // A line that names no answer (an older learner): only while
                // the answer before it is still the last thing on screen.
                found = last
            } else {
                found = nil
            }
            guard let i = found else { continue }
            if !turns[i].noted.contains(where: { $0.claim == fact.claim }) {
                turns[i].noted.append(fact)
            }
        }
        return (turns, consumed)
    }
}


/// "✓ Noted: Dana is your business partner   Undo", under an answer. Quiet
/// on purpose: it is a receipt, not a question, and it never speaks.
struct NotedLines: View {
    enum Style { case island, chat }
    let facts: [NotedFact]
    let style: Style
    let forget: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(facts) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: fact.forgotten ? "xmark" : "checkmark")
                        .font(.system(size: style == .island ? 8.5 : 9, weight: .bold))
                        .foregroundStyle(faint)
                    Text(fact.forgotten ? "Forgotten" : "Noted: \(fact.note)")
                        .font(style == .island ? .system(size: 11.5) : Theme.Typo.ui(12))
                        .foregroundStyle(fact.forgotten ? faint : dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if !fact.forgotten {
                        Button("Undo") { forget(fact.claim) }
                            .buttonStyle(.plain)
                            .font(style == .island ? .system(size: 11.5, weight: .medium)
                                                   : Theme.Typo.ui(12).weight(.medium))
                            .foregroundStyle(style == .island ? Color.white.opacity(0.7) : Theme.accent)
                            .help("Forget this. Alfie won't use it again.")
                            .accessibilityLabel("Undo: forget that \(fact.note)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var dim: Color { style == .island ? .white.opacity(0.5) : Theme.ink3 }
    private var faint: Color { style == .island ? .white.opacity(0.32) : Theme.ink3.opacity(0.7) }
}
