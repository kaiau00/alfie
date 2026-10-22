import Foundation

/// Who named the person a message is going to — the `provenance` record.
///
/// Kept apart from the rest of the request on purpose: it is one field, added
/// for one incident, and the dialog's lifecycle does not depend on it. On
/// 2026-09-25 a scheduled job told to message the owner sent to his
/// grandfather instead, a name that existed only in Moe's memory. The send
/// was stopped by hand. The dialog showed a real chat and gave no hint that
/// nobody had asked for that person.
///
/// The record is one line of JSON written by `moe-home/tools/recipients.py`
/// and carried by `confirm.sh` (from `MOE_CONFIRM_PROVENANCE`):
///
///     {"v": 1, "state": "named" | "partial" | "found" | "shown" | "owner",
///      "recipient": "…", "quote": "…", "said": "…", "source": "…",
///      "requested": "…", "mismatch": true, "query": "…", "query_unasked": true}
///
/// A record that does not parse says nothing. It is never a reason to refuse:
/// the refusals happen before a dialog opens, and this only describes.
struct ConfirmProvenance: Equatable {
    enum State: String { case named, partial, found, shown, owner, legacy }

    let state: State
    let recipient: String
    let quote: String
    let said: String
    let source: String
    let requested: String
    let mismatch: Bool
    /// The lookup that found this person was Moe's idea, not the person's.
    let query: String
    /// …and whether it was: a search the person never named, or a list Moe
    /// pulled up with no search at all.
    let queryUnasked: Bool

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["state"] as? String,
              let state = State(rawValue: raw) else { return nil }
        func line(_ key: String) -> String {
            ConfirmRequest.legibleLine((object[key] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.state = state
        self.recipient = line("recipient")
        self.quote = line("quote")
        self.said = line("said")
        self.source = line("source")
        self.requested = line("requested")
        self.mismatch = (object["mismatch"] as? Bool ?? false) && !self.requested.isEmpty
        self.queryUnasked = object["query_unasked"] as? Bool ?? false
        self.query = self.queryUnasked ? line("query") : ""
    }

    /// The line under the recipient. Quiet when the person named them; amber
    /// when Moe chose them, or filled in part of the name itself.
    var line: String {
        switch state {
        case .named where !quote.isEmpty:
            return "You named this person: \u{201C}\(quote)\u{201D}"
        case .named:
            return "You named this person."
        case .partial:
            let who = recipient.isEmpty ? "the rest" : recipient
            return said.isEmpty ? "Alfie filled in part of this name itself — it picked \(who)."
                : "You said \u{201C}\(said)\u{201D} — Alfie picked \(who)."
        case .found:
            return source.isEmpty ? "Alfie chose this person — found by looking them up."
                : "Alfie chose this person — found in \(source)."
        case .shown:
            // Ticket #22: an address Moe read off a page or the screen, named
            // in its own message, and the person said yes to. Their yes was to
            // Moe's message, not to this card — so the card says both.
            let where_ = source.isEmpty ? "a page" : source
            return said.isEmpty
                ? "Alfie found this address on \(where_) and showed it to you."
                : "Alfie found this address on \(where_) and showed it to you — you said \u{201C}\(said)\u{201D}."
        case .owner:
            return "This is you — you asked for it to come to you."
        case .legacy:
            return "This job was made before Alfie checked recipients — make sure it should message this person."
        }
    }

    /// True when the line should be drawn as a warning.
    var isWarning: Bool { state == .partial || state == .found || state == .shown || state == .legacy }

    /// Further warnings, each on its own line: somebody else was asked for,
    /// or the search that found this person was Moe's own idea.
    var warnings: [String] {
        var out: [String] = []
        if mismatch {
            out.append("You asked for \u{201C}\(requested)\u{201D} — this is not obviously the same person.")
        }
        if queryUnasked {
            out.append(query.isEmpty
                ? "Alfie picked them from a list it pulled up on its own — you did not name them."
                : "Alfie searched for \u{201C}\(query)\u{201D} on its own — you did not name them.")
        }
        return out
    }
}
