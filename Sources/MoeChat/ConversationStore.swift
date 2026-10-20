import Foundation

/// Conversations that survive ⌘N.
///
/// Chat used to keep its turns in one in-memory array that `newConversation()`
/// emptied. There was no session list and no way back: starting a new
/// conversation destroyed the previous one, permanently. The daily markdown in
/// `~/.moe/history/` recorded the text, but nothing could reopen a thread.
///
/// One JSON file per conversation under `conversations/`, rather than one
/// combined log: adding a turn rewrites a single small file instead of the
/// whole history, and a file that goes bad takes only its own thread down.
/// Files are 0600 and the directory 0700 — a conversation is at least as
/// private as a dictation.
public struct ConversationStore {

    // MARK: - Model

    /// One turn, as stored. Deliberately not the app's `Turn`: that carries
    /// `isStreaming`, which is a live-UI concern and has no business on disk.
    public struct StoredTurn: Codable, Equatable, Identifiable {
        public var id: String
        public var role: Role
        public var text: String
        public var at: Date
        /// What Moe did to answer, in plain language. Optional so threads
        /// written before this existed still decode.
        public var tools: [String]?
        /// Photos and files handed over with the message. Optional for the
        /// same reason as `tools`.
        public var attachments: [ChatAttachment]?

        public enum Role: String, Codable {
            case you, moe, system
        }

        public init(id: String = UUID().uuidString, role: Role, text: String,
                    at: Date = Date(), tools: [String]? = nil,
                    attachments: [ChatAttachment]? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.at = at
            self.tools = tools
            self.attachments = attachments
        }

        /// A turn with no words can still be a turn: a photo sent on its own.
        public var hasContent: Bool {
            !text.isEmpty || !(attachments ?? []).isEmpty
        }
    }

    public struct Conversation: Codable, Equatable, Identifiable {
        public var id: String
        public var startedAt: Date
        public var updatedAt: Date
        public var turns: [StoredTurn]

        public init(id: String = UUID().uuidString,
                    startedAt: Date = Date(),
                    updatedAt: Date = Date(),
                    turns: [StoredTurn] = []) {
            self.id = id
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.turns = turns
        }

        /// A short name a small model gave the thread (`TitleNamer`), kept
        /// beside the threads in `titles.idx` and merged in on reading, so a
        /// re-projection of the thread from the ledger cannot lose it.
        public var aiTitle: String? = nil

        /// What the session list shows: the AI name when there is one, else
        /// the first thing *you* said, because that is what you will
        /// recognise — Moe's opening line is usually a restatement of it and
        /// reads the same across every thread.
        public var title: String {
            if let ai = aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty { return ai }
            return firstLine
        }

        /// The first thing you said, one line, as a title.
        public var firstLine: String {
            let first = turns.first(where: { $0.role == .you && !$0.text.isEmpty })
                ?? turns.first(where: { !$0.text.isEmpty })
            guard let text = first?.text else { return "New conversation" }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "New conversation" }
            return clean.count <= 48 ? clean : String(clean.prefix(47)) + "…"
        }

        /// A conversation nobody said anything in is not worth keeping.
        public var isEmpty: Bool {
            !turns.contains { $0.role != .system && $0.hasContent }
        }
    }

    // MARK: - Store

    public let directory: URL
    /// Oldest threads beyond this are pruned on save. Generous: a conversation
    /// is a few kilobytes and people look further back than they expect to.
    public let cap: Int

    public init(directory: URL, cap: Int = 400) {
        self.directory = directory
        self.cap = cap
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Reading

    /// Every readable conversation, newest activity first. A file that does
    /// not parse is skipped rather than fatal — one bad thread must not take
    /// the list down.
    public func all() -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = titles()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Conversation? in
                guard let data = try? Data(contentsOf: url),
                      var convo = try? Self.decoder.decode(Conversation.self, from: data) else { return nil }
                convo.aiTitle = names[convo.id]
                return convo
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Titles

    /// `titles.idx`: thread id → the short name `TitleNamer` gave it. Not
    /// `.json`, so `all()` never mistakes it for a thread.
    private var titlesURL: URL { directory.appendingPathComponent("titles.idx") }

    public func titles() -> [String: String] {
        guard let data = try? Data(contentsOf: titlesURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    public func setTitle(_ title: String, for id: String) throws {
        var map = titles()
        map[id] = title
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(map)
        try data.write(to: titlesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: titlesURL.path)
    }

    /// Newest first, narrowed to threads whose title or any turn contains
    /// `query` (case- and diacritic-insensitive). An empty query is all.
    public func search(_ query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all() }
        return all().filter { convo in
            convo.title.localizedStandardContains(q)
                || convo.turns.contains { $0.text.localizedStandardContains(q) }
        }
    }

    public func load(id: String) -> Conversation? {
        guard let data = try? Data(contentsOf: url(for: id)),
              var convo = try? Self.decoder.decode(Conversation.self, from: data) else { return nil }
        convo.aiTitle = titles()[id]
        return convo
    }

    // MARK: Writing

    /// Write one conversation, then prune. An empty thread is deleted instead
    /// of saved, so ⌘N on an untouched window leaves nothing behind.
    public func save(_ conversation: Conversation) throws {
        guard !conversation.isEmpty else {
            try? delete(id: conversation.id)
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = try Self.encoder.encode(conversation)
        try data.write(to: url(for: conversation.id), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url(for: conversation.id).path)

        try prune()
    }

    public func delete(id: String) throws {
        // A deleted thread's name goes with it.
        var map = titles()
        if map.removeValue(forKey: id) != nil, let data = try? JSONEncoder().encode(map) {
            try? data.write(to: titlesURL, options: .atomic)
        }
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    public func deleteAll() throws {
        for convo in all() { try delete(id: convo.id) }
        try? FileManager.default.removeItem(at: titlesURL)
    }

    /// Drop the least-recently-touched threads once past the cap.
    private func prune() throws {
        let convos = all()
        guard convos.count > cap else { return }
        for convo in convos.dropFirst(cap) {
            try delete(id: convo.id)
        }
    }

    /// Ids come from `UUID()`, but a hand-edited or hostile id must never
    /// escape the directory — so anything that is not a plain filename
    /// component is rejected by construction.
    private func url(for id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safe.isEmpty ? "untitled" : safe)
            .appendingPathExtension("json")
    }
}
