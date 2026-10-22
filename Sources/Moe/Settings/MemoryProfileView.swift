import AppKit
import SwiftUI

// What Moe actually knows about you — read straight from Hermes's own memory.
//
// This screen USED to read a separate "learn profile" (~/.moe/learn/profile.py),
// a side-store that in practice sat empty while the REAL memory — the one the
// agent reads and writes every turn — lived elsewhere and was never shown here.
// So the tab said "nothing" while Moe plainly remembered things. Now it reads
// the engine's own memory files directly, which is the whole rule: the screen
// reflects the Hermes engine, not a Moe-only sidecar.
//
//   ~/.hermes/memories/USER.md    — who you are             → "You"
//   ~/.hermes/memories/MEMORY.md  — everything else it knows → "What Moe remembers"
//
// One rule this file does not bend: every remembered line is drawn with
// Text(verbatim:), never as markdown. The text came out of your mail, messages
// and conversations, so a link or an image in a signature must render as the
// characters it is — not as live markup.
//
// Read-only, on purpose: those files carry a lock and the agent writes them
// live, so editing them from here would race the engine. To change what Moe
// knows, tell Moe — it owns its own memory and updates it as you talk.

/// One remembered line, as it sits in a memory file.
struct MemoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let group: String   // "you" (USER.md) or "memory" (MEMORY.md)
    let text: String
}

/// Reads Hermes's memory files. All of it in one place.
enum HermesMemory {
    /// ~/.hermes/memories, honouring HERMES_HOME if the engine was relocated.
    static func dir() -> URL {
        let home = ProcessInfo.processInfo.environment["HERMES_HOME"]
        let base: URL = (home?.isEmpty == false)
            ? URL(fileURLWithPath: home!, isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
        return base.appendingPathComponent("memories", isDirectory: true)
    }

    /// The entries in one memory file, split on the `§` line the store writes
    /// between them (an entry may itself run to several lines). Blocking; call
    /// off the main thread.
    private static func entries(of file: String, group: String) -> [MemoryEntry] {
        let url = dir().appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [MemoryEntry] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current.removeAll()
            if !joined.isEmpty {
                out.append(MemoryEntry(id: "\(group):\(out.count)", group: group, text: joined))
            }
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "§" { flush() } else { current.append(line) }
        }
        flush()
        return out
    }

    /// Blocking; call off the main thread.
    static func read() -> [MemoryEntry] {
        entries(of: "USER.md", group: "you") + entries(of: "MEMORY.md", group: "memory")
    }
}

/// The headings, said the way the rest of the app says things.
enum MemoryWording {
    static func heading(_ group: String) -> String {
        switch group {
        case "you":    return "You"
        case "memory": return "What Alfie remembers"
        default:       return group
        }
    }
}

