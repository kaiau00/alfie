import Foundation

/// Turning a job's stderr into one sentence a person can act on.
///
/// **What this replaces, and what the owner was actually shown.** Picking
/// "Your ChatGPT plan" in Settings › Away on a Mac with no `~/.codex/auth.json`
/// put this on screen, in amber, as a single run-on paragraph:
///
/// > **moe-brain-away:** this copies /Users/…/.codex/auth.json to the machine.
/// > It is a credential FILE, not a token minted for the purpose — the weakest
/// > of the three shapes, and the one to change if OpenAI's device-code flow
/// > becomes available to you. **moe-brain-away:** /Users/…/.codex/auth.json is
/// > not there — sign in with `codex login` on this Mac first
///
/// Four faults, three of them here. `AwayBrainSetup.run` took the last **three**
/// stderr lines and joined them with a space, so:
///
///  1. **the job's own name was printed at the person, twice.**
///     `moe-brain-away.py`'s `log()` writes `"<job>: <message>"` because stderr
///     is a log; a pane that renders a log line verbatim is the "engine talking
///     about itself" class, and it has no business on a settings pane;
///  2. **two unrelated messages were concatenated** — an explanation and an
///     error, run together with no break, so neither read;
///  3. **the only actionable sentence was last**, after forty words of design
///     reasoning that belongs in `moeledger/brain.py`'s docstring, where it
///     already is. (The fourth fault was that sentence's own wording, fixed on
///     the job's side.)
///
/// **Two rules, and both are about shape rather than about this job.**
///
///  * **The last line.** A script's last line before a non-zero exit is its
///    refusal; everything above it is working-out. Nothing is lost — the caller
///    writes the whole stream to Moe's log.
///  * **The prefix goes by what it is, not by what it is called.** Matching
///    `moe-brain-away` would be a guard that enumerates names, and the next job
///    will have a different one (CLAUDE.md: *a guard that enumerates names is
///    walked past by a new name*). So the rule is the grammar of a log prefix —
///    a short, bare, lowercase token followed by `": "` — which Moe's own
///    sentences cannot match, because they begin with a capital letter.
///
/// It lives in `MoeLedger` because `Moe` has no test target, which is the same
/// reason as `AwayBrainField` and `AwayBrainCopy`, and the same reason three
/// mutants once survived 1905 Swift tests.
public enum AwayBrainMessage {

    /// The longest a token may be and still read as a log prefix. Generous for
    /// a job name, far short of a sentence clause.
    public static let prefixMaxLength = 40

    /// One sentence for the person, out of a stream written for a log, or nil
    /// when the stream said nothing at all.
    public static func personFacing(_ stream: String) -> String? {
        let last = stream.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let last else { return nil }
        return stripLogPrefix(last)
    }

    /// `"moe-brain-away: Sign in with…"` → `"Sign in with…"`. Anything not
    /// shaped like a log prefix comes back untouched.
    public static func stripLogPrefix(_ line: String) -> String {
        guard let colon = line.range(of: ": ") else { return line }
        let head = String(line[line.startIndex..<colon.lowerBound])
        guard !head.isEmpty, head.count <= prefixMaxLength else { return line }
        // Lowercase only: a capital means a sentence, and a sentence that
        // happens to contain ": " is not a prefixed log line.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard head.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return line }
        let rest = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        // A line that is only a prefix is not a message; keep what there is
        // rather than hand the pane an empty string.
        return rest.isEmpty ? line : rest
    }
}
