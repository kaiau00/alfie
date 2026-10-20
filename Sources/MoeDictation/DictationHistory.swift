import Foundation

/// What you dictated, kept on this Mac: one JSON object per line in
/// `dictation-history.jsonl`, newest last, the file owner-readable only.
///
/// JSON Lines rather than one document so an append is an append — no
/// read-modify-write of the whole history for every sentence — and so a
/// line that goes bad takes only itself down. Rotation rewrites the file
/// only when it is over the cap. Nothing here logs the text.
public struct DictationHistory {

    public struct Entry: Codable, Equatable, Identifiable {
        public var id: String
        public var at: Date
        public var appBundleID: String?
        public var appName: String?
        public var chars: Int
        public var polished: Bool
        public var text: String

        public init(id: String = UUID().uuidString, at: Date = Date(),
                    appBundleID: String? = nil, appName: String? = nil,
                    polished: Bool, text: String) {
            self.id = id
            self.at = at
            self.appBundleID = appBundleID
            self.appName = appName
            self.chars = text.count
            self.polished = polished
            self.text = text
        }

        /// The first line, for a list row.
        public var firstLine: String {
            text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
    }

    public let url: URL
    public let cap: Int

    public init(url: URL, cap: Int = 2000) {
        self.url = url
        self.cap = cap
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Reading

    /// Every readable entry, oldest first. A line that doesn't parse is
    /// skipped, not fatal.
    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? Self.decoder.decode(Entry.self, from: line)
        }
    }

    /// Newest first.
    public func recent() -> [Entry] { entries().reversed() }

    /// Newest first, narrowed to entries whose text or app contains `query`
    /// (case- and diacritic-insensitive). An empty query is everything.
    public func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recent() }
        return recent().filter {
            $0.text.localizedStandardContains(q)
                || ($0.appName?.localizedStandardContains(q) ?? false)
        }
    }

    // MARK: Writing

    /// Add one entry at the end, creating the file (mode 0600) if needed,
    /// then drop the oldest if that took the file over the cap.
    public func append(_ entry: Entry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            // Born 0600, not written 0644 and tightened a moment later.
            guard FileManager.default.createFile(atPath: url.path, contents: line,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try Self.restrict(url)
        // Cheap check first: a line count needs no parsing.
        if let data = try? Data(contentsOf: url),
           data.reduce(0, { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }) > cap {
            try rewrite(Array(entries().suffix(cap)))
        }
    }

    public func delete(id: String) throws {
        let kept = entries().filter { $0.id != id }
        try rewrite(kept)
    }

    public func clear() throws {
        try rewrite([])
    }

    /// Write the whole file afresh, oldest first, 0600.
    private func rewrite(_ entries: [Entry]) throws {
        var data = Data()
        for e in entries {
            data.append(try Self.encoder.encode(e))
            data.append(UInt8(ascii: "\n"))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try Self.restrict(url)
    }

    private static func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
