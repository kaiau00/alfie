import Foundation

/// Keeps the append-only files under `~/.moe/logs` that nothing else bounds
/// from growing for ever.
///
/// moe.log, turns.jsonl and hermes-gateway.log rotate themselves as they are
/// written; activity.jsonl and situations.jsonl trim themselves. What is left
/// is written by processes Moe does not own the handle of — launchd's
/// stdout/stderr for the background jobs (`<label>.err`), the Python plugins'
/// failure and audit logs — so they are cut back here instead, on every entry
/// through `FirstRun.installHomeIfNeeded` (app launch and every `--sync`).
///
/// Named, not globbed, on purpose: `installs.log` and `overrides.log` in the
/// same folder are the install receipts CLAUDE.md relies on to reconstruct a
/// bad day, and must never be trimmed by a sweep that matched them by accident.
enum LogJanitor {
    /// A file past `limit` is cut to its last `keep` bytes, at a line boundary.
    static let limit = 5 * 1024 * 1024
    static let keep = 1024 * 1024

    static let named: Set<String> = [
        "job-failures.log", "no-verbatim.jsonl",
        "hermes-upgrades.log", "install-hermes.log",
    ]

    static func isManaged(_ name: String) -> Bool {
        name.hasSuffix(".err") || named.contains(name)
    }

    /// Returns the names it trimmed, for the log line and the tests.
    @discardableResult
    static func sweep(in dir: URL = Paths.logs) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var trimmed: [String] = []
        for name in names.sorted() where isManaged(name) {
            let url = dir.appendingPathComponent(name)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size > limit else { continue }
            if trim(url, size: size) { trimmed.append(name) }
        }
        if !trimmed.isEmpty { Log.write("logs: trimmed \(trimmed.joined(separator: ", "))") }
        return trimmed
    }

    /// Replaces the file with its tail by rename, so a writer holding the old
    /// file open (launchd, between runs of a job) keeps writing to the unlinked
    /// copy and picks up the new one on its next start — it is never handed a
    /// file truncated under its offset.
    private static func trim(_ url: URL, size: Int) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(size - keep))
        guard var tail = try? h.readToEnd() else { return false }
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail.subdata(in: (nl + 1)..<tail.endIndex) }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).trim")
        do {
            try tail.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
}
