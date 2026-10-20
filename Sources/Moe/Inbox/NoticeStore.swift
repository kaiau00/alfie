import Foundation
import MoeIsland

/// Where the inbox lives between launches: `~/.moe/notices.json`.
///
/// The island used to delete an inbox file the moment it showed it, so a
/// card waved away, or on screen when the app quit, was gone for good. A
/// notice now stays until it is finished, and a finished one stays a week
/// so the app's Inbox can show what was done today.
enum NoticeStore {

    static var url: URL { Paths.home.appendingPathComponent("notices.json") }

    /// Finished notices are kept this long, for the app's "Done" list.
    static let keepDone: TimeInterval = 7 * 24 * 3600
    /// And never more than this many notices in all, newest kept.
    static let cap = 300

    static func load() -> [InboxItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode([InboxItem].self, from: data)
        } catch {
            // Kept aside rather than overwritten: a file that will not read
            // is worth a look, and the next save must not erase it.
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("notices.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.write("inbox: notices.json would not read (\(error)); kept as \(aside.lastPathComponent)")
            return []
        }
    }

    static func save(_ notices: [InboxItem], now: Date = Date()) {
        let kept = prune(notices, now: now)
        guard let data = try? encoder.encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func prune(_ notices: [InboxItem], now: Date = Date()) -> [InboxItem] {
        let live = notices.filter {
            $0.status == .open || now.timeIntervalSince($0.doneAt ?? $0.at) < keepDone
        }
        return Array(live.sorted { $0.at > $1.at }.prefix(cap))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
