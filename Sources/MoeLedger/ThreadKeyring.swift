import Foundation
import CryptoKit

/// One key per thread, kept beside the ledger and never inside it.
///
/// This is what makes Delete mean something on an append-only log. A record
/// cannot be unwritten — the whole design rests on that — so the words in it
/// are sealed with a key that *can* be removed. Delete destroys the key: the
/// record survives, carrying the id, the ordering and the timestamps that
/// other records point at, and the conversation itself becomes unrecoverable.
///
/// The keyring is a separate file for exactly that reason. A key stored in
/// the ledger would be as permanent as the thing it protects.
///
/// **Losing this file loses those conversations.** That is not a bug to be
/// engineered around: any copy that could bring a key back could bring back a
/// key the person destroyed on purpose, which would make Delete a lie. The
/// file says so in its own first line, and `docs/ONE-AGENT.md` §12 says it
/// again where the decision is recorded.
public final class ThreadKeyring: @unchecked Sendable {

    public let url: URL
    private var keys: [String: SymmetricKey]
    /// Keys this device used to seal under and must still be able to *open*.
    ///
    /// CLOUD-PLAN §15.1. Two Macs that both ran Moe free each minted their own
    /// `moe:memory`, honestly — §13.2 refuses a mint only when the keyring
    /// looks lost and a peer could deliver, and a free Mac has a healthy
    /// keyring and no peers. When the second joins the first's tenant it is
    /// offered the tenant's key, and the courier declined it, because
    /// `has(thread:)` was true. Right for a conversation, whose key nobody
    /// else can have minted; wrong for the one id two devices can both mint
    /// honestly. What one side sealed, the other opened as `nil` — not lost,
    /// **unreadable**, which is worse, because `ThreadCrypto.open` returns nil
    /// and nothing upstream says a word.
    ///
    /// So a retired key is never used to seal and is always tried when
    /// opening. The pre-upgrade claims stay readable *on this Mac*, are
    /// projected into `MEMORY.md` as they always were, and reach the tenant
    /// through the `document` path — the content converges without rewriting
    /// one signed record, which is the one thing this design does not do.
    private var retired: [String: [SymmetricKey]]
    private let lock = NSLock()
    /// Which file, and which version of it, `keys` was last read from — so a
    /// lookup can tell in one `stat` whether somebody else has written to it.
    private var loadedFrom: (ino: UInt64, size: Int, mtime: Double)?
    /// Told once, not on every read, so a lost keyring is a line in the log
    /// rather than a stream of them.
    private var haveComplained = false
    private let note: (String) -> Void

    /// What a person finds if they open the file. It is the only place they
    /// are likely to meet this before they need it.
    /// Rewritten once the cloud existed, because the old line — *"There is no
    /// copy"* — was true and was no longer the whole truth, and the half it
    /// left out is the half a person needs *before* they lose the file rather
    /// than after. Enrolling a second device is how a copy comes to exist,
    /// and it is the only way one ever will: `docs/ONE-AGENT.md` §15.1
    /// records the decision that there is no escrow and no reset, and that
    /// losing every enrolled device means these conversations are gone.
    static let warning = "Deleting this file permanently destroys the conversations it unlocks. "
        + "Each key belongs to one thread in ../ledger; deleting a conversation in Moe deletes "
        + "its key from here, which is what makes that deletion real. "
        + "Nobody else has a copy — not us, not the cloud, which only ever holds these keys "
        + "sealed to a device you enrolled yourself. There is no reset and no support path: if "
        + "you lose every Mac you have enrolled, those conversations are gone. Two ways to have "
        + "a second copy, and they are the only two: enrol another Mac (Settings → Devices), "
        + "or copy this file and device-identity.json somewhere you trust."

    // MARK: - Reserved entries (LEDGER-WIRE §13.2)

    /// Ids under this prefix are keyring entries that are not threads. A
    /// conversation thread id never starts with it — the Mac mints
    /// UUID-derived ids and the machine takes the Mac's — so a reader that
    /// meets one knows it is looking at something a `thread.delete` can
    /// never name.
    public static let reservedPrefix = "moe:"

    /// The key every `claim` and `document` record is sealed with (§13.4,
    /// §13.5). Memory is not filed under a conversation, so no thread key
    /// covers it; this one entry does, minted by whichever writer on a Mac
    /// first needs it — when `memoryKey(peerBook:)` says a mint is safe —
    /// and delivered by the courier like any thread's key.
    ///
    /// **Never deleted.** Forgetting memory is revoking devices (§12.3), not
    /// a record: `destroy` and `forget` refuse it, and every delete path
    /// upstream of them skips it as well, because a key that a forged or
    /// stray `thread.delete` could destroy would make the whole of a
    /// person's memory hang on one line in one file.
    public static let memoryKeyID = reservedPrefix + "memory"

    /// The key `connection/<name>` documents are sealed with (LEDGER-WIRE §15,
    /// CLOUD-PLAN §18.3). Separate from `moe:memory` so that a thing which can read a
    /// person's memory cannot thereby act as them on a provider, and minted
    /// at first use rather than at enrolment: a tenant who never gives the
    /// machine a connection never carries a credential key at all (§18.9).
    public static let connectionsKeyID = reservedPrefix + "connections"

    /// The key the `brain` document is sealed with — the model credential the
    /// away machine thinks with (CLOUD-PLAN §18.30, `moeledger/brain.py`).
    ///
    /// Its own id rather than a third use of `connectionsKeyID`, and the
    /// argument is the one that split `connections` off `memory`, sharper. A
    /// connection is authority over one provider the person chose to connect;
    /// a brain credential is either a **bill** — an API key, metered and
    /// charged to them — or the whole of their Claude or ChatGPT
    /// subscription. "This machine may act as me on Supabase" and "this
    /// machine may spend my Anthropic plan" are two different answers, and a
    /// person is entitled to give one and refuse the other. One key for both
    /// would make the second a silent consequence of the first.
    ///
    /// Minted at first use, like `connectionsKeyID`: a tenant who never gives
    /// a machine a brain never carries a brain key.
    public static let brainKeyID = reservedPrefix + "brain"

    /// True for an id no thread can have and no deletion may touch.
    public static func isReserved(_ id: String) -> Bool { id.hasPrefix(reservedPrefix) }

    /// Reserved ids a device may be refused delivery of (CLOUD-PLAN §18.9's
    /// per-key-per-peer courier). `moe:connections` alone.
    ///
    /// **An explicit list, not the `moe:` prefix, and §15.1 is why.** `adopt`
    /// took `isReserved` and therefore accepted `moe:connections`, whose
    /// readers know nothing about retirement, and the fix was a list —
    /// *"adding an id here is then the same act as teaching its reader,
    /// in one place, instead of a silent consequence of choosing a name."*
    /// The identical trap is here, and it is worse, because withholding is a
    /// refusal that nothing retries:
    ///
    /// * **`moe:memory` must never be withholdable.** `memoryKey(peerBook:)`
    ///   refuses to mint when the book names a peer, on the explicit promise
    ///   that *"the courier's reseal delivers the key within the hour"*.
    ///   Withhold it and that promise is false for ever: the peer holds back
    ///   every memory write, permanently, and says it is waiting for a
    ///   courier that has been told not to come.
    /// * **A typo must not be accepted either.** `moe:conections` is
    ///   well-formed under a prefix test, resolves to nothing, and is a
    ///   refusal that silently protects nothing — the "well-formed
    ///   identifier that resolves to nothing" failure this repository keeps
    ///   paying for.
    ///
    /// So a new withholdable id is a deliberate edit here, next to the reader
    /// that has to cope with not having it.
    ///
    /// `brainKeyID` is the second, added 2026-09-08 with the reader that
    /// copes: `moeledger/brain.applyDocuments` counts the documents it cannot
    /// open, writes nothing, and says so once — the same behaviour
    /// `connections` has, because it is literally the same reader
    /// (`connections.authorised_documents`, called with the other key id).
    /// A device denied this one holds a `brain` document it cannot open and
    /// runs on whatever brain it already had, which is what revocation looks
    /// like where a provider offers no revocation endpoint.
    public static let withholdable: Set<String> = [connectionsKeyID, brainKeyID]

    /// Reserved ids whose readers try every key, not just the current one, and
    /// which `adopt` will therefore retire a key for (§15.1). `moe:memory`
    /// alone today: `claimstore.store.open_text` and `Keyring.opening_keys`
    /// know about retirement, and the connections readers do not.
    static let retirable: Set<String> = [memoryKeyID]

    public init(url: URL, note: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.note = note
        retired = [:]
        if case .keys(let onDisk, let onDiskRetired) = ThreadKeyring.read(url) {
            retired = onDiskRetired
            self.keys = onDisk
            self.loadedFrom = ThreadKeyring.stamp(of: url)
        } else {
            // Nothing readable yet. `loadedFrom` stays nil so the first
            // lookup tries again rather than trusting an empty answer.
            self.keys = [:]
            self.loadedFrom = nil
        }
    }

    // MARK: - Reading

    /// The key for a thread, or nil — which is an ordinary answer, not an
    /// error. A destroyed key and a thread that never had one look the same
    /// from here, and both mean "there is nothing readable to show".
    public func key(for thread: String) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return keys[thread]
    }

    public func has(thread: String) -> Bool { key(for: thread) != nil }

    /// Every key that may open this thread: the current one first, then any
    /// retired under it (§15.1).
    ///
    /// **Opening asks this; sealing asks `key(for:)`.** That split is the
    /// whole safety property — a retired key that could still seal would put
    /// new records beyond the reach of every other device in the tenant, which
    /// is the defect this exists to fix, pointing the other way.
    public func openingKeys(for thread: String) -> [SymmetricKey] {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        // Deduplicated on the READ side, which is where Python already does it
        // (`Keyring.opening_keys`), and the two must agree because the shared
        // vectors compare them.
        //
        // Doing it here rather than on the write is deliberate, and a review
        // plus a vector between them are why. A reviewer argued the write-side
        // deduplication was dead — `wins` is strict, so a key can only be
        // displaced by a strictly smaller one, so the same key cannot be
        // displaced twice — and that argument is sound only while `adopt` is
        // the sole writer. `install` is `.callerWins` with no order check, so
        // a key can be put back as current and then displaced a second time.
        // Deduplicating what is read makes a repeat harmless wherever it came
        // from, instead of relying on every writer to prevent one.
        var all: [SymmetricKey] = []
        if let current = keys[thread] { all.append(current) }
        for old in retired[thread] ?? [] where !all.contains(old) { all.append(old) }
        return all
    }

    /// How many retired keys this thread carries. For tests and for the pane;
    /// the keys themselves never leave.
    public func retiredCount(for thread: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return (retired[thread] ?? []).count
    }

    /// Which threads this keyring can open. What a key courier iterates when
    /// it decides what a newly enrolled device is owed.
    public func threads() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return keys.keys.sorted()
    }

    // MARK: - Writing

    /// The thread's key, minted on first use. 256 bits from the system's
    /// random source; nothing derives it from the thread id, or destroying it
    /// would not destroy anything.
    ///
    /// A reserved entry (§13.2) is never minted here: `memoryKey(peerBook:)`
    /// is the one path that mints `moe:memory`, because it is the one that
    /// asks whether a peer already holds it. Asking for one that exists is
    /// fine; asking this to mint one throws.
    @discardableResult
    public func key(creatingFor thread: String) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        if let existing = keys[thread] { return existing }
        guard !ThreadKeyring.isReserved(thread) else { throw ThreadKeyringError.reservedMint(thread) }
        let minted = SymmetricKey(size: .bits256)
        // A key that exists only in memory would seal turns that nothing
        // could open after a restart, so nothing is returned until it is on
        // disk. `commit` leaves memory alone when it throws.
        //
        // **What comes back is the file's key, not necessarily the one just
        // minted.** The check above is outside the lock, so two runtimes
        // saving the same thread at the same moment both see no key and both
        // mint one. Whoever gets the lock second must take the first one's
        // key and throw its own away: the first has already sealed a turn
        // with it, and overwriting it would leave that record as ciphertext
        // under a key that exists nowhere. `.fileWins` is that rule, and it
        // is the only merge here that has it — a destroy or an enrolment is
        // an instruction, while a mint is only a guess that nobody had one.
        let merged = try commitLocked(adding: [thread: minted], removing: [],
                                      resolving: .fileWins)
        return merged.keys[thread] ?? minted
    }

    /// The memory key (§13.2): what the keyring holds, or a fresh mint when
    /// it is *safe* to mint one — and nil when it is not.
    ///
    /// `.fileWins` covers two writers minting at the same moment on one Mac.
    /// It does not cover the case that actually loses memory: a Mac whose
    /// keyring is gone (moved aside as damaged, or lost with the directory)
    /// while a peer still holds the real `moe:memory`. A mint there is a
    /// second key under the same id; `collect` keeps the key it already has,
    /// so the two sides seal to each other under keys neither can open, and
    /// every sealed claim written before the courier's next hourly reseal
    /// puts the peer's key back is lost for good. So the rule is: **refuse
    /// to mint only when a peer could deliver the key and this Mac's copy
    /// looks lost** — `peerBook` names at least one non-revoked peer, and
    /// either
    ///
    /// * a `thread-keys.json.damaged.*` lies beside the keyring
    ///   (`preserveDamagedLocked` moved one aside), or
    /// * the keyring file is absent (a lost directory on an enrolled Mac).
    ///
    /// With no peer nobody can deliver anything, so a Mac mints whatever
    /// state its keyring is in: refusing there would be a Mac with no memory
    /// key for ever. When refused, nil, with a line in the log: the
    /// courier's reseal (`CloudSync.fullCourierEvery`) delivers the key
    /// within the hour, and a writer with no key writes nothing (§13.5) —
    /// one hour of memory writes held back, against a memory nobody can
    /// read.
    ///
    /// `peerBook` is the peer book's URL — `<ledger dir>/../cloud/peers.json`
    /// on the Mac; the caller passes it rather than this file guessing a
    /// layout. Nil means the caller has no peer book at all (a Mac that has
    /// never enrolled), which reads as "no peers".
    ///
    /// A machine never calls this: it takes the key the Mac delivers (§13.2).
    @discardableResult
    public func memoryKey(peerBook: URL?) throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        if let existing = keys[ThreadKeyring.memoryKeyID] { return existing }
        if let why = mintingRefusedLocked(peerBook: peerBook) {
            note("ledger: not minting moe:memory — \(why); waiting for moe:memory to come back "
                 + "from a peer (the next full courier run delivers it). Memory writes are "
                 + "held until then.")
            return nil
        }
        let minted = SymmetricKey(size: .bits256)
        let merged = try commitLocked(adding: [ThreadKeyring.memoryKeyID: minted], removing: [],
                                      resolving: .fileWins)
        return merged.keys[ThreadKeyring.memoryKeyID] ?? minted
    }

    /// The reason a mint of `moe:memory` would be a second key under one
    /// id, or nil when there is none. Reads the disk, not `keys`: the
    /// question is whether this Mac's *file* is the one a peer was sealed
    /// against. Without a peer there is never a reason.
    private func mintingRefusedLocked(peerBook: URL?) -> String? {
        guard let peerBook, ThreadKeyring.peerBookNamesAPeer(at: peerBook) else { return nil }
        if let marker = ThreadKeyring.damagedMarker(beside: url) {
            return "\(peerBook.lastPathComponent) names a peer and \(marker) is beside the "
                + "keyring, so the key existed here, was lost here, and the peer holds it"
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            return "\(peerBook.lastPathComponent) names a peer and \(url.lastPathComponent) is "
                + "absent, so the key was minted before and this Mac lost it"
        }
        return nil
    }

    /// The name of a `thread-keys.json.damaged.*` file beside the keyring,
    /// if any — what `preserveDamagedLocked` leaves behind.
    static func damagedMarker(beside url: URL) -> String? {
        let prefix = url.lastPathComponent + ".damaged."
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().first
    }

    /// Whether the peer book at `url` names at least one peer that is not
    /// revoked. The file is `PeerBook`'s (`MoeCloud`): `{"peers": {id: …},
    /// "revoked": [id]}`. Read here, minimally, rather than through
    /// `PeerBook`, because the ledger does not link the cloud. A file that
    /// is missing or does not parse names nobody: an unreadable peer book
    /// is not evidence of a peer, and refusing to mint on it would leave a
    /// fresh Mac with no memory key for ever.
    static func peerBookNamesAPeer(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = object["peers"] as? [String: Any]
        else { return false }
        let revoked = Set((object["revoked"] as? [String]) ?? [])
        return peers.keys.contains { !revoked.contains($0) }
    }

    /// Destroy a thread's key. The words it unlocked are gone at this point;
    /// the records that carried them are not, and neither is the ordering
    /// every other thread's records may depend on.
    ///
    /// A reserved entry (§13.2) is never destroyed, whoever asks.
    public func destroy(thread: String) throws {
        guard !ThreadKeyring.isReserved(thread) else { return }
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        guard keys[thread] != nil else { return }
        // Forgetting a key in memory while it survives on disk would make a
        // deleted conversation readable again after a restart, so the removal
        // only reaches memory once the file has it.
        try commitLocked(adding: [:], removing: [thread], resolving: .callerWins)
    }

    /// Drop keys for threads the ledger says were deleted.
    ///
    /// Closes the window where the process died between writing the delete
    /// record and rewriting the keyring. It only ever removes, so it cannot
    /// bring anything back.
    @discardableResult
    public func forget(threads: [String]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        // The reserved entries are not threads and are never deleted
        // (§13.2), whatever a `thread.delete` record says.
        let doomed = Set(threads).filter { keys[$0] != nil && !ThreadKeyring.isReserved($0) }
        guard !doomed.isEmpty else { return 0 }
        try commitLocked(adding: [:], removing: doomed, resolving: .callerWins)
        return doomed.count
    }

    /// Put a key somebody else minted into this keyring.
    ///
    /// This was internal while §12's first undecided question — how a thread
    /// key reaches a second device — had no answer, so that nothing could
    /// pretend a transport existed. It has one now: `MoeCloud`'s
    /// `KeyCourier.collect` calls this, and only for an envelope that opened
    /// under this machine's own X25519 private key *and* verified against a
    /// device the person authenticated by comparing a code on two screens.
    /// The decision and what it costs are in `docs/ONE-AGENT.md` §12.
    ///
    /// `.callerWins`: an enrolment is an instruction, not a guess.
    public func install(_ key: SymmetricKey, for thread: String) throws {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        try commitLocked(adding: [thread: key], removing: [], resolving: .callerWins)
    }

    /// Take the tenant's key for a thread this device already has one for,
    /// **keeping the old one readable** (§15.1).
    ///
    /// The case is exactly one: a reserved id, `moe:memory`, that two Macs
    /// both minted honestly while each was free and peerless. Joining does not
    /// make this Mac's own memory wrong — it makes it *older*. So the tenant's
    /// key becomes the one everything seals under, and what this Mac wrote
    /// before it joined stays openable here, gets projected into `MEMORY.md`
    /// as it always was, and travels to the tenant as documents.
    ///
    /// Deliberately narrower than `install`: it refuses anything but a
    /// reserved id. For a conversation thread there is no legitimate second
    /// minter — nobody else can have that thread's key — so a second key
    /// arriving for one is a fact worth failing on rather than absorbing, and
    /// silently keeping both would hide it for ever.
    /// Returns whether the incoming key became the current one.
    ///
    /// **Which key wins is decided by the keys themselves, and it has to be.**
    /// Every device ships every key it holds to every peer on a full courier
    /// run (`sealed(for: peers.all(), threads: keyring.threads())`), so with a
    /// caller-wins rule two Macs holding different `moe:memory` keys would
    /// swap them for ever: A adopts B's, B adopts A's, and the next run undoes
    /// both. Traced before it was written — it converges on nothing, and every
    /// record in between is sealed under whichever key that device happened to
    /// hold that minute.
    ///
    /// So the rule is a total order over the key material — the numerically
    /// smaller of the two wins — which every device applies to the same pair
    /// and therefore agrees on, in one round, with no coordination and no
    /// notion of who joined whom. The choice of *smaller* is arbitrary; that
    /// it is total, deterministic and computable from what both sides already
    /// hold is not.
    ///
    /// The loser is not lost: whoever displaces a key retires it, so the
    /// records it sealed stay readable on the device that wrote them, and
    /// their content reaches the tenant as documents (§15.1).
    @discardableResult
    public func adopt(_ key: SymmetricKey, for thread: String) throws -> Bool {
        // Narrower than "reserved", and a review is why. `isReserved` is a
        // prefix test on `moe:`, so this accepted `moe:connections` as well —
        // which two free Macs also mint two of, through the same
        // `mint_reserved` rule. But retiring a key is only safe where
        // something can still READ under it, and the connections readers
        // (`connections.apply_documents`, `identity_document`) ask for one
        // key. Adopting there would retire a key nothing consults, which by
        // 664712f's own words leaves "the connection frozen at whatever is
        // already on disk, with nothing to re-seed a file that later
        // vanishes."
        //
        // So the list is the ids whose readers understand retirement, and it
        // is deliberately a list rather than a prefix: adding an id here is
        // then the same act as teaching its reader about retired keys, in one
        // place, instead of a silent consequence of choosing a name.
        guard ThreadKeyring.retirable.contains(thread) else {
            throw ThreadKeyringError.notReserved(thread)
        }
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        // No same-key early-out: `wins` finds no differing byte between two
        // equal keys and returns false, so re-delivery is already a no-op.
        // There was one, and no mutation could tell it from its absence —
        // which is the tell for a line that reads as a guard and is not one.
        // The comparison that decides the winner happens INSIDE the lock, in
        // `commitLocked`, against the file rather than against this instance's
        // cache. Deciding it here — after `refreshLocked` but before the flock
        // — leaves a window where another writer installs a smaller key in
        // between, and `.callerWins` then installs the larger one anyway. The
        // device would seal under a key its peers decline to adopt, and since
        // retired keys never leave a device those records would be unreadable
        // tenant-wide until the next full courier run. Not reachable today,
        // because on a Mac only this code adopts `moe:memory` and Python's
        // only write to it is a mint that cannot lower it — which is exactly
        // the kind of "not reachable today" this file has been bitten by.
        return try commitLocked(adding: [thread: key], removing: [],
                                resolving: .smallerWins, retiring: true).changed
    }

    /// The total order that makes `adopt` converge. Raw bytes, compared as
    /// unsigned; both keys are 256 bits, so there is no length case.
    static func wins(_ candidate: SymmetricKey, over held: SymmetricKey) -> Bool {
        let a = candidate.withUnsafeBytes { Array($0) }
        let b = held.withUnsafeBytes { Array($0) }
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    // MARK: - On disk

    /// Enough of the file to tell whether it is the same file.
    ///
    /// `stat`, rather than `URL.resourceValues`, which answers from a cache
    /// held on the URL and would happily report the size the file had before
    /// the other appender wrote to it. The inode is in here because every
    /// write of this file is an atomic replace and so lands a new one: a
    /// destroy followed by a mint elsewhere can leave the size and the
    /// modification time looking untouched, and the contents are different.
    private static func stamp(of url: URL) -> (ino: UInt64, size: Int, mtime: Double)? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (UInt64(info.st_ino), Int(info.st_size), mtime)
    }

    /// Pick up what another appender wrote, if it wrote anything.
    ///
    /// Two runtimes sharing one `~/.moe` share this file, and each held its
    /// own copy of it in memory: whichever saved last wrote its own map over
    /// the other's, so a thread the *other* one had just sealed became
    /// permanently unreadable. It is one `stat` to notice, and the file is a
    /// few hundred bytes, so noticing is the whole fix.
    ///
    /// The file is the truth, in both directions. A key it has and we do not
    /// is one the other appender minted; a key we have and it does not is one
    /// somebody destroyed, and keeping it would make that deletion a lie.
    private func refreshLocked() {
        let stamp = ThreadKeyring.stamp(of: url)
        if let stamp, let loadedFrom, stamp == loadedFrom { return }
        switch ThreadKeyring.read(url) {
        case .keys(let onDisk, let onDiskRetired):
            keys = onDisk
            retired = onDiskRetired
            loadedFrom = stamp
        case .missing:
            // Nothing on disk. Memory stays, which is what this did before
            // it re-read at all: the file being gone is not somebody saying
            // these conversations should go.
            loadedFrom = nil
        case .unreadable:
            // Transient, or a shape a later version wrote. Keep what we have
            // and look again next time. Treating "cannot read" as "no keys"
            // is how a permissions blip becomes permanent amnesia.
            loadedFrom = nil
        }
    }

    /// Which of two keys for one thread wins when the file and the caller
    /// both have one.
    private enum Resolution {
        /// The file. For a mint, which is only a guess that nobody had a key.
        case fileWins
        /// The caller. For a destroy or an enrolment, which is an instruction.
        case callerWins
        /// The smaller key material, compared under the lock. §15.1's total
        /// order: two devices applying it to the same pair agree in one round
        /// with no coordination, where a caller-wins rule makes them swap keys
        /// for ever.
        case smallerWins
    }

    /// Add and remove keys, against whatever the file says *now*.
    ///
    /// Read-modify-write under an exclusive lock rather than a write of what
    /// this instance happens to hold. The delta is explicit in both
    /// directions, which is what keeps the two appenders' rules intact: a
    /// mint cannot resurrect a key the other one destroyed, and a destroy
    /// cannot drop a key the other one has just minted.
    @discardableResult
    private func commitLocked(adding: [String: SymmetricKey], removing: Set<String>,
                              resolving: Resolution,
                              retiring: Bool = false)
        throws -> (keys: [String: SymmetricKey], changed: Bool) {
        try withFileLock {
            preserveDamagedLocked()
            var merged: [String: SymmetricKey]
            var mergedRetired: [String: [SymmetricKey]] = [:]
            switch ThreadKeyring.read(url) {
            case .keys(let onDisk, let onDiskRetired):
                merged = onDisk
                mergedRetired = onDiskRetired
            case .missing:
                // Nothing to merge with — either there never was a file, or
                // `preserveDamagedLocked` has just moved an unparseable one
                // aside. What this instance holds is all there is.
                merged = keys
                mergedRetired = retired
            case .unreadable:
                // The file is there and this process cannot see inside it.
                // Writing now would replace keys it cannot read with the
                // handful it happens to hold, which is exactly the permanent
                // loss the keyring exists to have only one cause of. Fail the
                // write instead; the caller already treats an unmintable key
                // as a reason not to seal anything.
                throw ThreadKeyringError.unreadable(url)
            }
            // The order is decided HERE, against what the file holds now,
            // rather than against this instance's cache before the lock was
            // taken. `adopt` used to decide it outside and then commit
            // `.callerWins`, which loses a race with another writer.
            var accepted = adding
            if case .smallerWins = resolving {
                accepted = adding.filter { thread, incoming in
                    guard let mine = merged[thread] else { return true }
                    return ThreadKeyring.wins(incoming, over: mine)
                }
            }
            // §15.1: keep what we are about to displace, so it can still
            // *open*. Only on the path that asks — an ordinary mint or
            // enrolment must not quietly accumulate keys.
            //
            // No `contains` check before appending: a review pointed out that
            // it was dead, and it was. `wins` is strict, so a key can only be
            // displaced by a strictly smaller one, so the same key can never
            // be displaced twice — the deduplication was guarding a case its
            // own caller had already made impossible. That is the criticism
            // this file makes of the same-key early-out it deleted, and
            // keeping the line here would have been the same mistake.
            if retiring {
                for (thread, incoming) in accepted {
                    // `displaced != incoming` was here and is gone, on the
                    // same argument that deleted the `contains` check beside
                    // it: `.smallerWins` has already filtered out anything
                    // that does not strictly win, so an equal key never
                    // reaches this loop. The vectors agent pointed out that
                    // keeping one dead guard while deleting its neighbour was
                    // the inconsistency, and it was right.
                    _ = incoming
                    guard let displaced = merged[thread] else { continue }
                    mergedRetired[thread, default: []].append(displaced)
                }
            }
            switch resolving {
            case .fileWins:   merged.merge(accepted) { mine, _ in mine }
            case .callerWins, .smallerWins: merged.merge(accepted) { _, theirs in theirs }
            }
            let changed = !accepted.isEmpty || !removing.isEmpty
            // A destroy is a person saying these conversations should go, and
            // a retired key that outlived it would keep them readable — the
            // opposite of what they asked for.
            for thread in removing { merged[thread] = nil; mergedRetired[thread] = nil }
            try write(merged, retired: mergedRetired, forgetting: removing)
            keys = merged
            retired = mergedRetired
            loadedFrom = ThreadKeyring.stamp(of: url)
            return (merged, changed)
        }
    }

    /// Exclusive access to the keyring across processes, held on a lock file
    /// beside it rather than on the keyring itself: the keyring is replaced
    /// atomically on every write, and a lock on a replaced inode excludes
    /// nobody. A lock that cannot be taken is not fatal — the read-modify-
    /// write still runs, and the worst case is what happened before it
    /// existed.
    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let path = url.appendingPathExtension("lock").path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR { continue }
        return try body()
    }

    /// What a read of the file found — three states, not two.
    ///
    /// "No keys" and "cannot tell" used to collapse into one empty
    /// dictionary, and every caller then treated a file it could not read as
    /// a file with nothing in it. A read that fails for a moment, or a file
    /// whose shape a later version changed, would have been written over with
    /// whatever this instance happened to hold. §8 promises that a newer
    /// version's records survive an older reader; the same has to be true of
    /// the one file here that cannot be reconstructed from anything else.
    private enum OnDisk {
        case missing
        case unreadable
        case keys([String: SymmetricKey], retired: [String: [SymmetricKey]])
    }

    private static func read(_ url: URL) -> OnDisk {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }
        // Not a fallback to empty: a keyring whose `keys` is a shape this
        // build does not understand is one to leave alone, not to replace.
        guard let stored = obj["keys"] as? [String: String] else { return .unreadable }
        var keys: [String: SymmetricKey] = [:]
        for (thread, encoded) in stored {
            guard let raw = Data(base64Encoded: encoded), raw.count == 32 else { continue }
            keys[thread] = SymmetricKey(data: raw)
        }
        // §15.1. Absent is the ordinary case — every keyring written before
        // this existed — so unlike `keys` a missing or malformed `retired` is
        // "none", not "unreadable": refusing to read a keyring because a
        // field added later is the wrong shape would strand every install
        // that never had one.
        var retired: [String: [SymmetricKey]] = [:]
        for (thread, list) in (obj["retired"] as? [String: [String]]) ?? [:] {
            let parsed = list.compactMap { encoded -> SymmetricKey? in
                guard let raw = Data(base64Encoded: encoded), raw.count == 32 else { return nil }
                return SymmetricKey(data: raw)
            }
            if !parsed.isEmpty { retired[thread] = parsed }
        }
        return .keys(keys, retired: retired)
    }

    /// A keyring that exists but cannot be read is kept, once, before a fresh
    /// one replaces it. This is not a backup — it is never taken of a file
    /// that parsed, so it can never hold a key somebody deleted on purpose.
    private func preserveDamagedLocked() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) == nil
        else { return }
        let aside = url.appendingPathExtension("damaged.\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        note("ledger: \(url.lastPathComponent) could not be read and was kept as "
             + "\(aside.lastPathComponent). Conversations it unlocked cannot be shown.")
    }

    /// Top-level fields this build does not know about.
    ///
    /// `read` is careful in one direction — a `keys` shape it cannot parse is
    /// left alone rather than replaced — and `write` was not careful in the
    /// other: it built the object from scratch, so **any field a newer build
    /// had added was deleted by the next write of an older one.** On a Mac
    /// that is not hypothetical and not slow: the Swift app and Python's
    /// `moeledger.vault.Keyring` share this file and both write it, so a field
    /// one of them added survived until the other minted a key — minutes,
    /// typically, and silently.
    ///
    /// §8 promises a newer version's records survive an older reader. This is
    /// that promise for the one file whose contents cannot be reconstructed
    /// from anything else, and it has to be in both implementations before any
    /// field is added to this format — which is what `retired` (§15.1) needs.
    private static func rawObject(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func extras(_ url: URL) -> [String: Any] {
        var extras = ThreadKeyring.rawObject(url)
        for known in ["README", "version", "keys", "retired"] { extras[known] = nil }
        // Anything that will not survive a round trip through JSON is dropped
        // rather than carried: writing it back would throw, and failing every
        // future write of the keyring is far worse than losing a field this
        // build could not have understood anyway.
        return extras.filter { JSONSerialization.isValidJSONObject([$0.value]) }
    }

    private func write(_ keys: [String: SymmetricKey],
                       retired: [String: [SymmetricKey]] = [:],
                       forgetting: Set<String> = []) throws {
        var body: [String: Any] = ThreadKeyring.extras(url)
        body["README"] = ThreadKeyring.warning
        body["version"] = 1
        body["keys"] = keys.mapValues { $0.withUnsafeBytes { Data($0).base64EncodedString() } }
        // Start from what is on disk rather than from what this build parsed.
        //
        // `read` drops a retired entry it cannot decode — a later build's
        // encoding, a longer key — and writing only the parsed set would then
        // DELETE it, which is `extras`' bug one level down: the field survives
        // and its contents do not. Found by probing this exact case rather
        // than by reading, and it is the §8 promise the whole of `bc7349a` is
        // about, so it must hold for a field's contents too.
        //
        // Threads this write actually touched are replaced from `retired`;
        // threads it did not are carried across untouched; threads being
        // removed are dropped, because a retired key that outlived a destroy
        // would keep readable exactly what somebody asked to be gone.
        var onDisk = (ThreadKeyring.rawObject(url)["retired"] as? [String: Any]) ?? [:]
        for thread in forgetting { onDisk[thread] = nil }
        for (thread, list) in retired {
            onDisk[thread] = list.map { $0.withUnsafeBytes { Data($0).base64EncodedString() } }
        }
        // Written only when there is something to write, so a keyring that
        // never had a retired key is byte-identical to one from before §15.1.
        body["retired"] = onDisk.isEmpty ? nil : onDisk
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: body,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Said once per process, when records exist that nothing here can open
    /// and the ledger does not say they were deleted. The likely cause is a
    /// keyring that was moved, restored from a partial backup, or lost.
    func noteUnreadable(threads: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !haveComplained, threads > 0 else { return }
        haveComplained = true
        note("conversations: \(threads) thread\(threads == 1 ? "" : "s") cannot be read — "
             + "no key for them in \(url.lastPathComponent). If you did not delete them, that "
             + "file is missing or damaged, and there is no copy of it by design.")
    }
}

/// Sealing and opening one field.
public enum ThreadCrypto {

    /// Names the scheme in the record, so a later reader never has to guess
    /// how something was wrapped.
    public static let scheme = "aes-gcm-256.v1"

    /// AES-GCM with a fresh random nonce per field. The nonce, ciphertext and
    /// tag travel together in CryptoKit's combined form, base64 for JSON.
    ///
    /// A random nonce means the same sentence seals differently every time,
    /// so a record id is the hash of the bytes actually written rather than
    /// of the words. Replaying that record is still idempotent, which is what
    /// content-addressing is for here; what is lost is only the ability to
    /// recognise the same sentence twice, which nothing wants.
    public static func seal(_ plaintext: String, with key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw ThreadCryptoError.sealFailed }
        return combined.base64EncodedString()
    }

    /// Nil for anything that will not open: the wrong key, a truncated field,
    /// a tag that does not verify. Never throws — unreadable is a state the
    /// projection handles, not a failure that stops it.
    public static func open(_ encoded: String, with key: SymmetricKey?) -> String? {
        guard let key,
              let raw = Data(base64Encoded: encoded),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let opened = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: opened, encoding: .utf8)
    }
}

public enum ThreadKeyringError: Error, CustomStringConvertible {
    /// The keyring exists and could not be read, so it was left alone.
    case unreadable(URL)
    /// `key(creatingFor:)` was asked to mint a reserved entry (§13.2), which
    /// only `memoryKey(peerBook:)` may do.
    case reservedMint(String)
    /// `adopt` was asked to keep two keys for an ordinary thread. Only a
    /// reserved id can honestly have been minted twice (§15.1).
    case notReserved(String)

    public var description: String {
        switch self {
        case .unreadable(let url):
            return "ledger: " + url.lastPathComponent + " exists but could not be read, so it "
                + "was left alone. Writing over it would destroy the keys inside it."
        case .notReserved(let id):
            return "ledger: " + id + " is not a reserved id, so two devices cannot both have "
                + "minted its key. Refusing to keep a second one rather than hiding the fact."
        case .reservedMint(let id):
            return "ledger: \(id) is a reserved keyring entry; it is minted through "
                + "memoryKey(peerBook:), which checks that no peer already holds it"
        }
    }
}

public enum ThreadCryptoError: Error, CustomStringConvertible {
    case sealFailed
    public var description: String { "ledger: could not seal a turn" }
}
