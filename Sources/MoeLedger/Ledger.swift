import Foundation
import CryptoKit

/// The append-only log every other store is derived from.
///
/// One JSONL file per device under `~/.moe/ledger/`, alongside the memory and
/// conversations it explains rather than hidden in a database: plain text, one
/// record per line, `git`-able, readable in `less`, and appendable by a second
/// writer without a lock on anyone else's file.
///
/// Nothing here is ever rewritten. Appends are `O_APPEND` + `fsync`, one
/// `write(2)` per record, so a crash can lose the tail of the last line but
/// can never interleave two records or corrupt an earlier one. A reader drops
/// a trailing partial line; the next append heals the file by starting on a
/// fresh line first.
public final class Ledger {

    public let directory: URL
    /// This machine, as it appears in `device` — `mac-<8 hex>`, derived from
    /// the ledger directory's own identity file so a copied `~/.moe` on a
    /// second Mac does not silently claim the first one's sequence numbers.
    public let device: String
    /// What `at` is stamped with when the caller does not say. Injectable so
    /// a test can run three days of two devices in an afternoon; in the app
    /// it is `Date()` and nothing passes anything else.
    public let clock: @Sendable () -> Date

    private let fileManager = FileManager.default
    private let lock = NSLock()
    /// Last `seq` and `id` written by this device, so the chain is gapless.
    ///
    /// A cache, and only trusted while `headStamp` still matches the file
    /// (LEDGER-WIRE §13.1). Two writers share this chain — the app and
    /// Hermes's `claimstore` plugin, under one device id — and a head
    /// remembered across another writer's append is exactly how two records
    /// come to claim one `seq`.
    private var head: (seq: Int, id: String)?
    /// The `(size, mtime_ns)` of this device's file when `head` was last
    /// known to be its tail: after this process's own append, or after it
    /// re-read the file. Anything else having written since shows up here
    /// before it shows up anywhere else, and costs one `stat` to notice.
    private var headStamp: FileStamp?

    /// Enough of a file to tell whether anybody has appended to it. The size
    /// alone would do for an append-only file — a record is never zero bytes
    /// — and the modification time is the second witness §13.1 asks for.
    struct FileStamp: Equatable {
        let size: Int
        let mtimeNs: Int64
    }
    /// What has already been parsed out of each file, and the ordered result
    /// built from all of them. Its own lock: `adopt` reads while holding
    /// `lock`.
    ///
    /// This exists because every save reads the whole ledger and a ledger is
    /// every turn a person has ever taken. Re-parsing a year of history to
    /// add one line to it is not a cost that can be paid per reply.
    private let cacheLock = NSLock()
    private var parses: [String: FileParse] = [:]
    private var orderedCache: Ordered?

    /// The ordered records and the by-thread index, always built together so
    /// they cannot disagree, and both extended rather than rebuilt when the
    /// ledger has only grown at the end.
    private struct Ordered {
        var signature: String
        var records: [LedgerRecord]
        /// Every id in `records`, so the incremental path never has to
        /// rebuild the set it tests membership against.
        var ids: Set<String>
        /// How many of each file's records are already folded in.
        var folded: [String: Int]
        var byThread: [String: [LedgerRecord]]
        /// The largest seed key in `records`. A record that arrives with a
        /// smaller one belongs *inside* this order, not after it, so the
        /// cheap path must refuse it. See `Ledger.appendable`.
        var highWater: SortKey?
        /// Parents named by records already placed that we do not hold. If
        /// one of them turns up, records already placed have to move, so the
        /// cheap path must refuse that too — this is out-of-order arrival.
        var wanted: Set<String>
    }

    /// The seed order records are considered in: wall clock first, then the
    /// writing device, then its own sequence. Never the id, which is a hash
    /// and would shuffle records written in the same millisecond into an
    /// order nobody wrote them in.
    ///
    /// This decides nothing on its own — `ordered` places causal parents
    /// first regardless — it only separates records that are genuinely
    /// concurrent, which is all `at` is ever allowed to do (§1.5).
    struct SortKey: Comparable {
        let at: Date
        let device: String
        let seq: Int
        static func < (a: SortKey, b: SortKey) -> Bool {
            (a.at, a.device, a.seq) < (b.at, b.device, b.seq)
        }
    }

    /// One file, parsed up to `consumed` bytes — always a line boundary, so
    /// a torn tail is re-examined next time rather than baked in.
    private struct FileParse {
        var size: Int
        var mtime: Double
        var consumed: Int
        var records: [LedgerRecord]
    }

    public init(directory: URL, device: String? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.device = device ?? Ledger.resolveDevice(in: directory)
        self.clock = clock
    }

    // MARK: - Device identity

    private static func resolveDevice(in directory: URL) -> String {
        let file = directory.appendingPathComponent("device.json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String, !id.isEmpty {
            return id
        }
        // Random rather than a hash of the hostname: hostnames change, repeat
        // across machines on the same network, and are not ours to put in a
        // file that will one day be uploaded.
        let id = "mac-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8).lowercased()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body: [String: Any] = ["id": id, "createdAt": LedgerRecord.timestamps.string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return id
    }

    public var fileForThisDevice: URL { file(for: device) }

    private func file(for device: String) -> URL {
        // A device id from a file someone else wrote must not escape the
        // directory, for the same reason ConversationStore sanitises ids.
        let safe = device.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safe.isEmpty ? "unknown" : safe)
            .appendingPathExtension("jsonl")
    }

    // MARK: - Reading

    /// Every readable record from every device, oldest first.
    ///
    /// Ordering is causal where causality says anything — a record whose
    /// `after` names another sorts behind it — and falls back to `at` then
    /// `id` for records that are genuinely concurrent, which is all `at` is
    /// ever allowed to decide (§1.5).
    public func all() -> [LedgerRecord] {
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        var signature = ""
        var byFile: [[LedgerRecord]] = []
        var present = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            present.insert(name)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

            let parse: FileParse
            if let cached = parses[name], cached.size == size, cached.mtime == mtime {
                parse = cached
            } else if var cached = parses[name], size >= cached.consumed {
                // The file only ever grows, so what was parsed before is still
                // true and only the new bytes need reading. This is the whole
                // point of an append-only log.
                let tail = Ledger.parse(Ledger.bytes(of: file, from: cached.consumed),
                                        from: cached.consumed)
                cached.records += tail.records
                cached.consumed = tail.consumed
                cached.size = size
                cached.mtime = mtime
                parse = cached
            } else {
                // Shorter than what we read, so it was replaced or truncated
                // by something outside this process. Start again.
                let whole = Ledger.parse(Ledger.bytes(of: file, from: 0), from: 0)
                parse = FileParse(size: size, mtime: mtime,
                                  consumed: whole.consumed, records: whole.records)
            }
            parses[name] = parse
            byFile.append(parse.records)
            signature += "\(name):\(size):\(mtime);"
        }
        // A file that has gone must not keep its parse alive forever.
        for name in parses.keys where !present.contains(name) { parses[name] = nil }

        if let orderedCache, orderedCache.signature == signature { return orderedCache.records }

        // The cheap path, and the one that runs on every save: each file has
        // only grown, so the records already folded in are still folded in
        // and only the new tail has to be looked at. Nothing here walks the
        // whole history — that is the difference between a save costing what
        // a reply costs and costing what a lifetime of them costs.
        if let prior = orderedCache, present == Set(prior.folded.keys) {
            var fresh: [LedgerRecord] = []
            var freshIDs = Set<String>()
            var folded = prior.folded
            var grewOnly = true
            for file in files {
                let name = file.lastPathComponent
                let parsed = parses[name]?.records ?? []
                let already = prior.folded[name] ?? 0
                guard parsed.count >= already else { grewOnly = false; break }
                if parsed.count > already {
                    for record in parsed[already...]
                    where !prior.ids.contains(record.id) && freshIDs.insert(record.id).inserted {
                        fresh.append(record)
                    }
                }
                folded[name] = parsed.count
            }
            // Seed order, not the order the files happened to be walked in:
            // two devices' records interleave, and appending B's before A's
            // because "b.jsonl" sorts after "a.jsonl" is not an order anyone
            // wrote them in.
            fresh.sort { $0.key < $1.key }
            var ids = prior.ids
            ids.formUnion(freshIDs)
            if grewOnly, Ledger.appendable(prior: prior.highWater, wanted: prior.wanted,
                                           after: prior.ids, adding: fresh, knowing: ids) {
                var index = prior.byThread
                for record in fresh {
                    guard let thread = record.body["thread"]?.stringValue else { continue }
                    index[thread, default: []].append(record)
                }
                var wanted = prior.wanted
                for record in fresh {
                    for parent in record.parents where !ids.contains(parent) { wanted.insert(parent) }
                }
                orderedCache = Ordered(signature: signature, records: prior.records + fresh,
                                       ids: ids, folded: folded, byThread: index,
                                       highWater: fresh.last?.key ?? prior.highWater,
                                       wanted: wanted)
                return orderedCache?.records ?? []
            }
        }

        var seen = Set<String>()
        var records: [LedgerRecord] = []
        var folded: [String: Int] = [:]
        for (file, parsed) in zip(files, byFile) {
            folded[file.lastPathComponent] = parsed.count
            for record in parsed where !seen.contains(record.id) {
                seen.insert(record.id)
                records.append(record)
            }
        }
        let ordered = Ledger.ordered(records)
        var index: [String: [LedgerRecord]] = [:]
        var wanted = Set<String>()
        for record in ordered {
            for parent in record.parents where !seen.contains(parent) { wanted.insert(parent) }
            guard let thread = record.body["thread"]?.stringValue else { continue }
            index[thread, default: []].append(record)
        }
        orderedCache = Ordered(signature: signature, records: ordered,
                               ids: seen, folded: folded, byThread: index,
                               highWater: ordered.map(\.key).max(), wanted: wanted)
        return ordered
    }

    /// Whether `fresh` can simply go on the end of an order already computed.
    ///
    /// This is what makes a save cost what a thread costs rather than what a
    /// lifetime of them costs, and it is only allowed to be cheap while it is
    /// *identical* to running the full sort again. Three things have to hold,
    /// and slice one only checked the first of them:
    ///
    /// 1. Every fresh record's causal parents are already placed, or are
    ///    earlier in this same batch. A parent nobody holds is ignored by
    ///    `ordered` too, so it does not count.
    /// 2. Every fresh record sorts after everything already placed. Two
    ///    appenders write concurrently and their clocks are not the same
    ///    clock: a record that arrives now but is stamped before one already
    ///    folded in belongs *between* records, and putting it on the end
    ///    gives an order no fresh reader of the same bytes would produce.
    /// 3. No record already placed was waiting for one of these. A reply that
    ///    arrives before its question is placed without it; when the question
    ///    turns up, the reply has to move, so the whole order is recomputed.
    ///
    /// False whenever any of that fails, and then the full sort runs, which
    /// is always correct and merely slower. Two appenders that disagree about
    /// order project different conversations, which is this slice's falsifier;
    /// an optimisation that changes the answer is where that would come from.
    static func appendable(prior highWater: SortKey?, wanted: Set<String>,
                           after placed: Set<String>, adding fresh: [LedgerRecord],
                           knowing all: Set<String>) -> Bool {
        var available = placed
        for record in fresh {
            if let highWater, !(highWater < record.key) { return false }
            if wanted.contains(record.id) { return false }
            for parent in record.parents where all.contains(parent) {
                guard available.contains(parent) else { return false }
            }
            available.insert(record.id)
        }
        return true
    }

    /// The file's bytes from `offset` on. Empty for anything unreadable — a
    /// ledger that cannot be read is an empty one, never a crash.
    static func bytes(of file: URL, from offset: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        return (try? handle.readToEnd()) ?? Data()
    }

    /// Records out of `data`, plus the offset just past the last complete
    /// line. Whatever follows that is unterminated: either nothing, or half a
    /// record a crash left behind, and neither is a record yet.
    static func parse(_ data: Data, from offset: Int) -> (records: [LedgerRecord], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }
        let complete = data[data.startIndex...lastNewline]
        let records = complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { LedgerRecord.decode(line: Data($0)) }
        return (records, offset + complete.count)
    }

    public func records(kind: String) -> [LedgerRecord] {
        all().filter { $0.kind == kind }
    }

    /// Records grouped by the `thread` their body names, in ledger order.
    ///
    /// An index, not truth — the same records `all()` returns, arranged the
    /// way every reader of them asks. Without it each save scans the whole
    /// history several times to find the one thread it is writing, which is
    /// the difference between a save that costs what a thread costs and one
    /// that costs what a lifetime of them costs.
    public func byThread() -> [String: [LedgerRecord]] {
        _ = all()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return orderedCache?.byThread ?? [:]
    }

    /// Parse one file from the start. A line that does not decode is skipped,
    /// and a final line with no newline after it is treated as a torn write
    /// and dropped — the record it was going to be was never durably written.
    static func read(file: URL) -> [LedgerRecord] {
        parse(bytes(of: file, from: 0), from: 0).records
    }

    /// A stable topological order: each record after everything it names in
    /// `after` that we actually hold.
    ///
    /// Ties fall back to `at`, then to the writing device's own `seq` — never
    /// to the id, which is a hash and would shuffle records written in the
    /// same second into an order nobody wrote them in.
    static func ordered(_ records: [LedgerRecord]) -> [LedgerRecord] {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [LedgerRecord] = []
        var placed = Set<String>()
        var visiting = Set<String>()

        func place(_ record: LedgerRecord) {
            guard !placed.contains(record.id) else { return }
            // A cycle can only come from a corrupt or hostile file; break it
            // rather than recurse forever.
            guard !visiting.contains(record.id) else { return }
            visiting.insert(record.id)
            // `prev` is causality too, and the cheapest kind: a device had
            // certainly seen its own previous write. Including it is what
            // makes a clock that steps backwards — an NTP correction, someone
            // changing the date — harmless rather than an inverted thread.
            let parents = record.parents
                .compactMap { byID[$0] }
                .sorted { $0.key < $1.key }
            for parent in parents { place(parent) }
            visiting.remove(record.id)
            placed.insert(record.id)
            out.append(record)
        }

        for record in records.sorted(by: { $0.key < $1.key }) { place(record) }
        return out
    }

    /// Which records in `ordered` are causally after `pivot`, by what the
    /// records themselves say and by nothing else.
    ///
    /// One forward pass from the pivot's own position. `ordered` places every
    /// record after the parents it holds, so a record's parents are already
    /// decided by the time it is reached, and nothing ahead of the pivot in
    /// that order can be behind it in causality.
    ///
    /// **There is no `seq` comparison here, and there must not be.** An
    /// earlier version of the tombstone rule took "same device, higher `seq`"
    /// as proof that a record had seen another, on the grounds that a device
    /// has certainly seen its own previous write. That holds for one writer
    /// per chain and fails in exactly the configuration slice 2 exists to
    /// support: two runtimes sharing a `~/.moe` share its `device.json`, keep
    /// their own idea of where the chain has got to, and both write `seq` 7
    /// (§13.5). Deciding whether a deleted conversation — or a deleted
    /// memory — comes back on a counter two writers fork is no better than
    /// deciding it on a wall clock, and much harder for anyone to see.
    /// Following `prev` and `after` by id costs a pass over the ledger and
    /// assumes nothing about who wrote it.
    ///
    /// Shared by `ConversationProjector.surviving` (thread tombstones) and
    /// `ClaimLedger.resolve` (claim retractions), because §3.1 states one
    /// rule and two implementations of it would be two rules.
    static func causallyAfter(_ pivot: LedgerRecord, in ordered: [LedgerRecord]) -> Set<String> {
        guard let start = ordered.firstIndex(where: { $0.id == pivot.id }) else { return [] }
        var after = Set<String>()
        for record in ordered[ordered.index(after: start)...] {
            if record.parents.contains(where: { $0 == pivot.id || after.contains($0) }) {
                after.insert(record.id)
            }
        }
        return after
    }

    // MARK: - Appending

    /// Append one record, durably, and return it with its id filled in.
    ///
    /// `after` is what the caller had already seen. The `seq`/`prev` chain is
    /// this device's own and is continued from the file, so a process that
    /// restarts picks up where it left off.
    ///
    /// The chain is shared (LEDGER-WIRE §13.1): the app and the `claimstore` plugin both
    /// append to this file under one device id, so the head is derived under
    /// an exclusive lock on `<device>.jsonl.lock` and from the *file* whenever
    /// the file has changed since this process last looked. Without the lock
    /// the two writers fork the chain — two records with one `seq` — which the
    /// sync layer tolerates by re-sending everything, every time
    /// (`SyncClient.outstanding`). The lock is what keeps the watermark
    /// cheap, not what keeps data safe.
    @discardableResult
    public func append(kind: String, body: JSONValue, after: [String] = [],
                       at: Date? = nil) throws -> LedgerRecord {
        lock.lock()
        defer { lock.unlock() }
        let at = at ?? clock()
        return try withChainLock {
            let head = try currentHeadLocked()
            let record = LedgerRecord(kind: kind, at: at, device: device, seq: head.seq + 1,
                                      prev: head.id, after: after, body: body)
            try appendLocked(record)
            self.head = (record.seq, record.id)
            self.headStamp = Ledger.stamp(of: fileForThisDevice)
            return record
        }
    }

    /// Append a record that already has an id — a copy from somewhere else.
    /// Idempotent: a record whose id we already hold is not written twice.
    @discardableResult
    public func adopt(_ record: LedgerRecord) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !all().contains(where: { $0.id == record.id }) else { return false }
        // A copy of this device's own record — a Mac whose ledger directory
        // was lost, taking its history back from the cloud — lands in this
        // device's own file, and so under the chain lock like any other
        // writer. The stamp changes and the next `append` re-reads the head,
        // which is how a restored chain carries on from where the cloud says
        // it got to rather than from one.
        if record.device == device {
            try withChainLock { try appendLocked(record) }
        } else {
            try appendLocked(record)
        }
        return true
    }

    /// The head of this device's chain, from memory when the file has not
    /// moved and from the file when it has.
    ///
    /// The whole file is re-read rather than its last line: it is a few
    /// hundred KB, and the head is the record with the *highest* `seq`, not
    /// the last line — on a file an unlocked writer once forked, continuing
    /// from the last line could fork it again, while continuing from the
    /// highest `seq` closes the fork. For an unforked file the two are the
    /// same record.
    private func currentHeadLocked() throws -> (seq: Int, id: String?) {
        let stamp = Ledger.stamp(of: fileForThisDevice)
        if let head, let headStamp, stamp == headStamp { return (head.seq, head.id) }
        let mine = Ledger.read(file: fileForThisDevice)
        guard let last = mine.max(by: { $0.seq < $1.seq }) else {
            head = nil
            headStamp = stamp
            return (0, nil)
        }
        head = (last.seq, last.id)
        headStamp = stamp
        return (last.seq, last.id)
    }

    /// `(size, mtime_ns)` of a file, or nil when there is no file. `stat`,
    /// not `URL.resourceValues`, which answers from a cache on the URL and
    /// would happily report the size the file had before the other writer
    /// appended to it.
    static func stamp(of url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let ns = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileStamp(size: Int(info.st_size), mtimeNs: ns)
    }

    /// Exclusive access to this device's chain across processes (LEDGER-WIRE
    /// §13.1): `flock(LOCK_EX)` on `<device>.jsonl.lock`, beside the file,
    /// `0600`. The same idea as `ThreadKeyring.withFileLock`, for the same
    /// two writers. A lock that cannot be taken is not fatal — the append
    /// still runs, and the worst case is what happened before the lock
    /// existed: a fork the sync layer already tolerates.
    private func withChainLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let path = fileForThisDevice.appendingPathExtension("lock").path
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR { continue }
        return try body()
    }

    private func appendLocked(_ record: LedgerRecord) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let url = file(for: record.device)

        var payload = Data()
        // A previous crash can have left half a line. Starting on a new one
        // keeps that damage to the record that was lost.
        if Ledger.endsMidLine(at: url) { payload.append(UInt8(ascii: "\n")) }
        payload.append(try record.encoded())
        payload.append(UInt8(ascii: "\n"))

        // O_APPEND rather than seek-then-write: those are two syscalls and a
        // second appender can land between them. One record, one write, and
        // the kernel decides where it goes.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw LedgerError.cannotOpen(url.path, errno) }
        defer { close(fd) }

        // One record, one `write(2)`. Deliberately not a loop over a partial
        // write: a second `write` on an `O_APPEND` descriptor is a second
        // append, and another writer can land between the two — so the retry
        // that looks like robustness is the one thing that could split a
        // record in half. A short write is reported instead. (`EINTR` before
        // any bytes have moved is the one case worth retrying, and it is not
        // a partial write.)
        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var n = 0
            repeat {
                n = write(fd, base, buffer.count)
            } while n < 0 && errno == EINTR
            if n < 0 { throw LedgerError.writeFailed(url.path, errno) }
            if n != buffer.count { throw LedgerError.shortWrite(url.path, n, buffer.count) }
        }
        // fsync, not F_FULLFSYNC: the record must survive this process dying,
        // which it does. Paying a drive-cache flush on every turn to also
        // survive the power being pulled is not the trade a chat app makes.
        guard fsync(fd) == 0 else { throw LedgerError.writeFailed(url.path, errno) }
    }

    /// True when the file's last byte is not a newline — a torn write.
    static func endsMidLine(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        try? handle.seek(toOffset: size - 1)
        return (try? handle.read(upToCount: 1))??.first != UInt8(ascii: "\n")
    }

    // MARK: - Integrity

    /// Where this device's own chain has a hole. Empty is healthy; anything
    /// else means records were lost between two writes and the projection
    /// built from this file is missing something (§8, "ledger corrupted").
    public func gapsForThisDevice() -> [Int] {
        let mine = Ledger.read(file: fileForThisDevice).sorted { $0.seq < $1.seq }
        guard let first = mine.first else { return [] }
        var expected = first.seq
        var gaps: [Int] = []
        for record in mine {
            while record.seq > expected { gaps.append(expected); expected += 1 }
            expected = max(expected, record.seq + 1)
        }
        return gaps
    }

    /// Sequence numbers this device wrote more than once. Empty is healthy.
    ///
    /// The counterpart to `gapsForThisDevice`, and it exists because two
    /// appenders make the gap detector blind. `seq`/`prev` are how §1.5 makes
    /// loss detectable rather than silent, and that argument holds only while
    /// one writer owns a chain. Two runtimes sharing a `~/.moe` also share
    /// its `device.json`, so they take the same identity, keep their own idea
    /// of where the chain has got to, and both write `seq` 7 — which leaves
    /// no gap and no complaint, and quietly retires the guarantee.
    ///
    /// Whether two runtimes on one Mac are one device or two is a decision,
    /// not a bug to be patched over here. What this does is make the state
    /// visible instead of silent, which is the whole reason the field is in
    /// the record.
    public func forkedSeqsForThisDevice() -> [Int] {
        var seen: [Int: String] = [:]
        var forked = Set<Int>()
        for record in Ledger.read(file: fileForThisDevice) {
            if let first = seen[record.seq], first != record.id { forked.insert(record.seq) }
            seen[record.seq] = record.id
        }
        return forked.sorted()
    }
}

public enum LedgerError: Error, CustomStringConvertible {
    case cannotOpen(String, Int32)
    case writeFailed(String, Int32)
    /// A record went in half. Retrying would append the other half as a
    /// separate write, which another appender can land between — so the
    /// truncated line is left to be skipped on the next read, and the caller
    /// is told rather than silently handed a split record.
    case shortWrite(String, Int, Int)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let code):
            return "ledger: cannot open \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let path, let code):
            return "ledger: write to \(path) failed: \(String(cString: strerror(code)))"
        case .shortWrite(let path, let done, let wanted):
            return "ledger: short append to \(path) (\(done) of \(wanted) bytes); the "
                 + "partial line will be skipped on the next read"
        }
    }
}
