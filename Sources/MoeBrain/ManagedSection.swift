import Foundation

/// Keeping a section of a user-owned file up to date without overwriting the
/// user.
///
/// `~/.moe/CLAUDE.md` is the agent's own system prompt, and it is written
/// exactly once — `FirstRun.write` returns early if the file exists. That was
/// a deliberate choice (it is the person's file; they may edit it) with an
/// invisible cost: **every improvement to that prompt after someone's first
/// run reaches nobody.** The "Driving the Mac" section already told the agent
/// not to repeat an unproven action, and the copy on this Mac had drifted from
/// the template months ago, so a fix shipped as prompt text would have been
/// delivered to no one and nothing would have said so.
///
/// The way out is the one `Payload.installIfNeeded` already uses for the rest
/// of `~/.moe`: version-stamp what we own, replace it when the stamp changes,
/// and leave everything else exactly as the person left it. Here the unit is a
/// marked block rather than a whole file, because this file has two authors.
///
/// A block looks like:
///
/// ```markdown
/// <!-- moe:begin driving-the-mac v3 -->
/// ...text Moe owns and will rewrite...
/// <!-- moe:end driving-the-mac -->
/// ```
///
/// Outside those markers the file is the person's. Inside, it is ours.
public enum ManagedSection {

    public static func begin(_ id: String, _ version: Int) -> String {
        "<!-- moe:begin \(id) v\(version) -->"
    }

    public static func end(_ id: String) -> String {
        "<!-- moe:end \(id) -->"
    }

    /// Wrap `body` in the markers for `id` at `version`.
    public static func block(id: String, version: Int, body: String) -> String {
        "\(begin(id, version))\n\(body)\n\(end(id))"
    }

    public enum Outcome: Equatable {
        /// The file already carried this block at this version.
        case unchanged
        /// An older version of the block was replaced in place.
        case updated(from: Int)
        /// No marked block was present, so one was appended.
        case appended
    }

    public struct Result: Equatable {
        public var text: String
        public var outcome: Outcome
    }

    /// Return `document` with the managed block at `version`.
    ///
    /// - An existing block at the same version is left completely alone, so
    ///   this is safe to run on every launch.
    /// - An existing block at any other version — older *or* newer — is
    ///   replaced. Newer too, because a file carrying a version this build has
    ///   never heard of came from a build that is no longer installed, and
    ///   leaving it would pin the agent to instructions whose code is gone.
    /// - A document with no block gains one at the end. Appending rather than
    ///   inserting keeps the person's own opening paragraphs first, which is
    ///   where they put the things they care most about.
    /// - Text outside the markers is never touched, including a second
    ///   managed block with a different id.
    public static func apply(id: String, version: Int, body: String,
                             to document: String) -> Result {
        let endMarker = end(id)
        let openPrefix = "<!-- moe:begin \(id) v"

        // The block ends at the LAST end-marker before the next block begins,
        // not the first one found. A body that quotes its own end-marker in
        // prose otherwise terminates the block early, and the replacement
        // leaves the real marker orphaned in the person's file — which then
        // never parses again. Bounding the search at the next `moe:begin`
        // keeps a second managed block from being swallowed.
        let searchStart = document.range(of: openPrefix).map(\.upperBound)
        let versionEnd = searchStart.flatMap {
            document.range(of: " -->", range: $0..<document.endIndex)
        }
        let blockLimit = versionEnd.flatMap {
            document.range(of: "<!-- moe:begin ", range: $0.upperBound..<document.endIndex)?.lowerBound
        } ?? document.endIndex
        guard let openRange = document.range(of: openPrefix),
              let versionEnd,
              let closeRange = document.range(of: endMarker, options: .backwards,
                                              range: versionEnd.upperBound..<blockLimit)
        else {
            // No block (or a truncated one we cannot safely edit): append.
            var out = document
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty { out += "\n" }
            out += block(id: id, version: version, body: body) + "\n"
            return Result(text: out, outcome: .appended)
        }

        let found = Int(document[openRange.upperBound..<versionEnd.lowerBound]) ?? -1
        if found == version {
            return Result(text: document, outcome: .unchanged)
        }

        var out = document
        out.replaceSubrange(openRange.lowerBound..<closeRange.upperBound,
                            with: block(id: id, version: version, body: body))
        return Result(text: out, outcome: .updated(from: found))
    }
}
