import Foundation

/// User-supplied words the recogniser gets wrong: names, jargon, company
/// words. Loaded from `<home>/vocabulary.txt`, one entry per line:
///
///     # comments and blank lines are ignored
///     Kubernetes              # a term: whatever casing is heard → this casing
///     cooper netties => Kubernetes   # a replacement: heard form → canonical
///
/// Matching is case-insensitive and whole-word, so "kubernetes" and
/// "KUBERNETES" both become "Kubernetes" while "kubernetesy" is left alone.
///
/// Several files can feed one vocabulary (`init(sources:)`): `.shared` reads
/// the hand-written `vocabulary.txt`, then `vocabulary-learned.txt` (what
/// `CorrectionLearner` picked up from the user's own edits), then
/// `vocabulary-contacts.txt` (names the app caches from Contacts). An earlier
/// source wins when two define the same heard form, so a line the user typed
/// is never overridden by something inferred. `additionalTerms` is a final,
/// in-memory source below all of the files.
///
/// Each file is re-read whenever its modification time changes. A stat per
/// dictation is far cheaper than a file watcher and means edits take effect
/// on the next utterance without a restart.
public final class Vocabulary: @unchecked Sendable {

    /// Where `.shared` looks for its files. The app sets this to its
    /// `~/.moe` before first use; `MOE_HOME` overrides it for tests and
    /// scripts. Read once, when `.shared` is first touched.
    public static var homeDirectory: URL = {
        if let env = ProcessInfo.processInfo.environment["MOE_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // ~/Library/Application Support/Moe, matching Config.homeDir. Kept in
        // step by scripts/test-moe-home.sh rather than by a shared constant:
        // this module is below Moe in the dependency graph and cannot see it.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Moe", isDirectory: true)
    }()

    /// File names under `homeDirectory`, highest priority first.
    public static let userFile = "vocabulary.txt"
    public static let learnedFile = "vocabulary-learned.txt"
    public static let contactsFile = "vocabulary-contacts.txt"

    public static let shared = Vocabulary(sources: [userFile, learnedFile, contactsFile].map {
        homeDirectory.appendingPathComponent($0)
    })

    /// The files, highest priority first. Empty for the in-memory initialiser.
    public let sources: [URL]

    /// The user-written file, for the settings UI; `/dev/null` for the
    /// in-memory initialiser.
    public var url: URL { sources.first ?? URL(fileURLWithPath: "/dev/null") }

    private let lock = NSLock()
    /// One entry per source: its mtime at last load (nil = missing or
    /// unreadable) and the table parsed from it.
    private var loaded: [(mtime: Date?, table: [String: String])]
    private var extra: [String: String] = [:]
    private var regex: NSRegularExpression?
    /// Lowercased heard form → canonical form, merged across sources.
    private var canonical: [String: String] = [:]

    public convenience init(url: URL) {
        self.init(sources: [url])
    }

    /// `sources` are read on first use and again whenever one of them
    /// changes. A missing file is an empty source.
    public init(sources: [URL]) {
        self.sources = sources
        // A sentinel mtime no file has, so the first use always loads.
        self.loaded = sources.map { _ in (Date.distantPast, [:]) }
    }

    /// Build from in-memory lines; what the tests use.
    public init(lines: [String]) {
        self.sources = []
        self.loaded = []
        self.loaded = [(nil, parse(lines))]
        install()
    }

    /// Terms merged in below every file, each in the file syntax (a bare
    /// term or a `heard => Form` line). Setting it replaces the previous set.
    public var additionalTerms: [String] {
        get {
            lock.lock(); defer { lock.unlock() }
            return extra.map { $0.key == $0.value.lowercased() ? $0.value : "\($0.key) => \($0.value)" }.sorted()
        }
        set {
            let table = parse(newValue)
            lock.lock()
            extra = table
            lock.unlock()
            install()
        }
    }

    /// Heard → canonical pairs currently loaded, for the settings UI.
    public var entries: [String: String] {
        reloadIfChanged()
        lock.lock(); defer { lock.unlock() }
        return canonical
    }

    /// Canonical spellings for a prompt: highest-priority source first,
    /// alphabetical within a source, at most `limit` of them. The cap is
    /// what keeps a 2,000-name Contacts cache from swamping the polish
    /// prompt — and, since that prompt is baked into the warm brain session,
    /// from costing a respawn each time a name changes.
    public func promptTerms(limit: Int) -> [String] {
        reloadIfChanged()
        lock.lock()
        let tables = loaded.map(\.table) + [extra]
        lock.unlock()
        var seen = Set<String>()
        var out: [String] = []
        for table in tables {
            for term in Set(table.values).sorted() where out.count < limit {
                if seen.insert(term).inserted { out.append(term) }
            }
        }
        return out
    }

    /// Replace every heard form in `text` with its canonical form.
    public func apply(to text: String) -> String {
        reloadIfChanged()
        lock.lock()
        let rx = regex
        let table = canonical
        lock.unlock()
        guard let rx else { return text }

        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let heard = ns.substring(with: m.range).lowercased()
            out += table[heard] ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Loading

    private func reloadIfChanged() {
        guard !sources.isEmpty else { return }
        let mtimes = sources.map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        lock.lock()
        let stale = zip(mtimes, loaded).contains { $0 != $1.mtime }
        lock.unlock()
        guard stale else { return }

        var fresh: [(mtime: Date?, table: [String: String])] = []
        for (source, mtime) in zip(sources, mtimes) {
            let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
            fresh.append((mtime, parse(text.components(separatedBy: .newlines))))
        }
        lock.lock()
        loaded = fresh
        lock.unlock()
        install()
    }

    private func parse(_ lines: [String]) -> [String: String] {
        var table: [String: String] = [:]
        for raw in lines {
            // Strip a trailing comment; a `#` inside a term is not supported.
            // Also drops a BOM (an editor may leave one on the first line)
            // and the `\r` of a CRLF file.
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) ?? ""
            if line.isEmpty { continue }
            if let arrow = line.range(of: "=>") {
                let heard = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let form = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                if !heard.isEmpty, !form.isEmpty { table[heard.lowercased()] = form }
            } else {
                table[line.lowercased()] = line
            }
        }
        return table
    }

    /// Merge the loaded sources (earlier wins) and rebuild the matcher.
    private func install() {
        lock.lock()
        var table = extra
        for source in loaded.reversed() { table.merge(source.table) { _, higher in higher } }
        lock.unlock()
        // Longest first so "new york times" wins over "new york" when both
        // are listed. Lookarounds rather than `\b` so a term that starts or
        // ends with a symbol (".net", "C++") still matches whole-word.
        let alts = table.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let rx = table.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\w])(?:"# + alts + #")(?![\w])"#, options: [.caseInsensitive])
        lock.lock()
        canonical = table
        regex = rx
        lock.unlock()
    }
}
