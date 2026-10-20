import Foundation
import MoeMeeting

/// Re-derives `summary.md` and the notes in `meeting.json` from a meeting's
/// `transcript.txt`, using the current `MeetingSummaryPrompt` and the current
/// dedupe in `ActionItemScan`.
///
/// It exists because the notes prompt and the merge are the parts of meeting
/// mode most likely to be improved after meetings are already on disk, and a
/// fix that only applies to meetings not yet recorded is half a fix. The first
/// pass it was written for added a "todos" bucket for work nobody took on —
/// which had been falling out of the notes entirely — and replaced an
/// exact-string dedupe that shipped twenty-one action items where eleven were
/// distinct.
///
/// The transcript is never touched: it is the record, and everything here is
/// derived from it. `summary.md` is rewritten in place, with the old footer
/// (clock drift, off the record, kept audio) carried across verbatim, because
/// those lines describe the recording rather than the reading of it.
///
///     swift run MeetingNotesRedo ~/.moe/meetings/2026-08-31-0946
///     swift run MeetingNotesRedo --all          # every meeting in ~/.moe/meetings
///     swift run MeetingNotesRedo --all --dry-run
///
/// The brain is the `claude` CLI rather than the Hermes gateway, so this runs
/// whether or not Moe is up.

// MARK: - The brain

struct ClaudeCLI: MeetingBrain {
    let binary: String

    func complete(system: String, user: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        // No tools: the transcript is in the prompt and the reply is one
        // JSON object, so a tool call here is only ever a wrong turn.
        p.arguments = ["-p", "--append-system-prompt", system, "--output-format", "text"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["USER"] = NSUserName()
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        try p.run()
        stdin.fileHandleForWriting.write(Data(user.utf8))
        try stdin.fileHandleForWriting.close()
        // Read before waiting: a reply larger than the pipe buffer deadlocks
        // a wait-then-read, and a long meeting's notes are exactly that.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Fail("claude exited \(p.terminationStatus): "
                       + String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: out, as: UTF8.self)
    }
}

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - The old footer

/// The footer lines of an existing `summary.md`, unwrapped from their
/// italics, or none when the file has no footer or is not there. They are
/// facts about the recording — drift, off-the-record spans, why the audio
/// was kept — which this pass has no way to recompute and no business
/// dropping.
func existingFooter(_ summary: URL) -> [String] {
    guard let text = try? String(contentsOf: summary, encoding: .utf8),
          let block = text.components(separatedBy: "\n---\n\n").last,
          block != text else { return [] }
    return block.split(separator: "\n").map {
        var line = $0.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("_") { line.removeFirst() }
        if line.hasSuffix("_") { line.removeLast() }
        return line
    }.filter { !$0.isEmpty }
}

// MARK: - One meeting

@discardableResult
func redo(_ folder: URL, brain: MeetingBrain, dryRun: Bool) async -> Bool {
    let name = folder.lastPathComponent
    let recordURL = folder.appendingPathComponent("meeting.json")
    let summaryURL = folder.appendingPathComponent("summary.md")

    guard let recordData = try? Data(contentsOf: recordURL),
          var record = try? MeetingRecord.decoder().decode(MeetingRecord.self, from: recordData) else {
        print("· \(name): no readable meeting.json, skipped")
        return false
    }
    let transcriptURL = folder.appendingPathComponent(record.transcriptFile)
    guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
          !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("· \(name): transcript is empty or missing, skipped")
        return false
    }

    let before = record.notes?.actionItems.count ?? 0
    let reply: String
    do {
        reply = try await brain.complete(
            system: MeetingSummaryPrompt.system,
            user: MeetingSummaryPrompt.user(transcript: transcript, date: record.startedAt,
                                            duration: record.durationSeconds, bookmarks: record.bookmarks))
    } catch {
        print("✗ \(name): \(error)")
        return false
    }
    guard var notes = MeetingNotes.parse(reply) else {
        print("✗ \(name): the reply was not notes, left alone")
        return false
    }
    // The summary's own list goes through the same sieve as a live scan's,
    // because a single pass over a long transcript repeats itself too.
    notes.actionItems = ActionItemScan.merge(notes.actionItems, [])

    let markdown = notes.markdown(date: record.startedAt, duration: record.durationSeconds,
                                  bookmarks: record.bookmarks, captures: record.captures, footer: existingFooter(summaryURL))
    let delta = "\(before) → \(notes.actionItems.count) action items, \(notes.todos.count) to do"
    guard !dryRun else {
        print("· \(name): would rewrite — \(delta)")
        return true
    }

    record.notes = notes
    record.summarised = true
    record.summaryFile = "summary.md"
    record.summaryFailure = nil
    do {
        try markdown.write(to: summaryURL, atomically: true, encoding: .utf8)
        try record.json().write(to: recordURL, options: .atomic)
    } catch {
        print("✗ \(name): could not write — \(error.localizedDescription)")
        return false
    }
    print("✓ \(name): \(delta)")
    return true
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
let paths = args.filter { !$0.hasPrefix("--") }
let meetingsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".moe/meetings")

var folders: [URL]
if args.contains("--all") {
    folders = ((try? FileManager.default.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.hasDirectoryPath }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} else if !paths.isEmpty {
    folders = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
} else {
    print("usage: MeetingNotesRedo [--all | <meeting folder>…] [--dry-run]")
    exit(2)
}
guard !folders.isEmpty else { print("no meetings in \(meetingsRoot.path)"); exit(1) }

guard let claude = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    print("no `claude` on this Mac; this tool needs it to write the notes")
    exit(1)
}
let brain = ClaudeCLI(binary: claude)

print("\(dryRun ? "Dry run over" : "Re-deriving notes for") \(folders.count) meeting\(folders.count == 1 ? "" : "s")\n")
var done = 0
// One at a time on purpose: each request carries a whole transcript, and
// twenty at once is a rate limit rather than a speed-up.
for folder in folders where await redo(folder, brain: brain, dryRun: dryRun) { done += 1 }
print("\n\(done) of \(folders.count) \(dryRun ? "would be rewritten" : "rewritten")")
