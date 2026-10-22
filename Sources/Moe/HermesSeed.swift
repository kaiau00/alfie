import Darwin
import Foundation

/// Lays down the Hermes that ships inside Memoe.app, so a new Mac can think
/// without touching the network.
///
/// Before this, `Bootstrap.installHermes` was the only path: a `git clone` of
/// a public fork plus a `curl … | sh` of the uv installer, run at the moment
/// onboarding reaches the brain step. That works, and it fails in all the
/// ways a network step fails — on a plane, behind a corporate proxy, on the
/// day GitHub is down — and it asks a stranger to accept two downloads from
/// hosts they have no reason to trust, at the exact moment they are least
/// able to judge. Seeding moves both into the image Apple already notarized.
///
/// ## Why a copy and not a run-in-place
///
/// `hermes_agent` is installed *editable*, so its finder hardcodes paths into
/// the working tree; `tools/lazy_deps.py` runs `uv pip install` into its own
/// venv at runtime, by design and by policy; and any write inside
/// `Contents/` breaks the code-signature seal and Gatekeeper kills the app.
/// So the seed is a read-only template and `~/.hermes/hermes-agent` is the
/// live, writable copy. `docs/BUNDLE.md §5` has the measurements.
///
/// ## Why the placeholder
///
/// A venv is full of absolute paths — the shebang of every script in
/// `.venv/bin`, and `home =` in `pyvenv.cfg`. At stage time
/// (`scripts/stage-hermes-seed.sh`) those become the literal `@HERMES_ROOT@`;
/// here they become this user's real path. That keeps the shipped bytes
/// identical for everybody, which is what lets the privacy gate pass and what
/// lets a Sparkle delta skip all 818 MB of it.
enum HermesSeed {

    /// The token `stage-hermes-seed.sh` leaves behind in every absolute path.
    static let placeholder = "@HERMES_ROOT@"

    /// The seed inside the app bundle, when this build has one.
    ///
    /// `MOE_HERMES_SEED` overrides it. A `swift build` binary has no bundle
    /// Resources at all, so without that seam the only way to exercise any of
    /// this would be to build and sign the full 1.7 GB app — which means in
    /// practice it would not be exercised.
    static var bundleSeed: URL? {
        let fm = FileManager.default
        var candidate: URL?
        if let override = ProcessInfo.processInfo.environment["MOE_HERMES_SEED"], !override.isEmpty {
            candidate = URL(fileURLWithPath: override, isDirectory: true)
        } else if let res = Bundle.main.resourceURL {
            candidate = res.appendingPathComponent("hermes-seed", isDirectory: true)
        }
        guard let dir = candidate else { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir
    }

    /// Where the live copy goes. `Bootstrap.hermesInstalled()` already looks
    /// here, so nothing about the lookup changes.
    /// The commit the bundled seed was staged from (`hermes-agent/.moe-seed-commit`),
    /// or nil when this build carries no seed or an unreadable stamp.
    static func bundledCommit() -> String? {
        guard let seed = bundleSeed,
              let text = try? String(contentsOf: seed.appendingPathComponent("hermes-agent/.moe-seed-commit"),
                                     encoding: .utf8) else { return nil }
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count == 40 && sha.allSatisfy({ $0.isHexDigit }) ? sha : nil
    }
    static var destination: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes", isDirectory: true)
    }

    static func stampURL(in root: URL) -> URL { root.appendingPathComponent(".seed") }

    /// A cheap identity for the seed: its version file if upstream left one,
    /// else the size and count of the tree. Not a hash — hashing 818 MB on
    /// every launch to answer "is it already there" would cost more than the
    /// copy it avoids.
    static func version(of seed: URL) -> String {
        let fm = FileManager.default
        var files = 0
        var bytes: UInt64 = 0
        // No `.skipsHiddenFiles`. That option does not merely skip hidden
        // files, it refuses to descend into hidden *directories* — and the
        // seed's bulk is `.venv`, so the fingerprint covered 12,786 of 24,414
        // files and 421 MB of 796 MB. A Hermes release that changes only venv
        // contents, which is the most common kind, produced a byte-identical
        // stamp and would never have been laid down.
        if let e = fm.enumerator(at: seed, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey])
                if let s = v?.fileSize { files += 1; bytes &+= UInt64(s) }
            }
        }
        return "\(files)-\(bytes)"
    }

    /// Installs the seed if this Mac has no Hermes yet.
    ///
    /// Returns a line for the log, always. Never throws, never blocks the
    /// caller's decision: a Mac with no seed and no Hermes is exactly the
    /// state onboarding's network install already handles, so failing here
    /// costs the offline path and nothing else.
    ///
    /// - Note: copies ~820 MB. Call it off the main thread.
    @discardableResult
    static func installIfNeeded(into root: URL = destination) -> String {
        guard let seed = bundleSeed else {
            return "no hermes seed in this build; onboarding will install over the network"
        }

        // An existing Hermes is never replaced. It may be newer than the seed
        // (`hermes update` does a git pull in place), it may be a developer's
        // checkout with unpushed work, and it certainly holds auth.json,
        // memories and sessions. Overwriting any of that to save a download
        // would be indefensible. Two guards say so, and both are needed.
        //
        // The first only applies when installing to the real location. `hermesInstalled()` asks
        // about this *Mac* — it looks at ~/.local/bin, /opt/homebrew and the
        // configured binary — so applying it to an arbitrary destination would
        // make the answer depend on whether the machine running the check
        // happens to have Hermes, which is neither what the caller asked nor
        // testable.
        if root == Self.destination, Bootstrap.hermesInstalled() {
            return "hermes is already installed; the seed was not used"
        }

        // `hermesInstalled()` is not sufficient on its own. It asks whether a
        // *runnable* hermes exists, and the move below `rm -rf`s each
        // top-level entry it is about to replace — so a checkout whose venv
        // never finished, which is precisely the half-installed state this
        // whole change exists to rescue, would have been deleted along with
        // any work in it. A developer mid-`hermes update`, or one whose
        // `.venv/bin/hermes` merely lost its exec bit, looks identical.
        //
        // So: an existing hermes-agent directory is left alone, full stop, and
        // the network installer — which knows how to repair a partial clone —
        // is what runs instead.
        let existingAgent = root.appendingPathComponent("hermes-agent")
        if FileManager.default.fileExists(atPath: existingAgent.path) {
            return "hermes seed: \(existingAgent.path) already exists and was left untouched"
        }

        let want = version(of: seed)
        let stamp = stampURL(in: root)
        if let have = try? String(contentsOf: stamp, encoding: .utf8),
           have.trimmingCharacters(in: .whitespacesAndNewlines) == want {
            // The stamp matches but hermesInstalled() said no: the tree was
            // laid down and then damaged. Say so rather than silently
            // re-copying 818 MB on every launch forever.
            return "hermes seed \(want) was installed but is not runnable; reinstall Alfie"
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        // One writer, same mechanism and same reasoning as Payload: `--ask`,
        // `--sync` and the app all reach this, and two concurrent 818 MB
        // copies into one directory interleave into a tree that is neither.
        let lock = root.appendingPathComponent(".seed.lock")
        let fd = open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 && errno != EEXIST {
            return "hermes seed: cannot write to \(root.path) (errno \(errno))"
        }
        if fd < 0 {
            // Ten minutes is Payload's figure; this copy is far larger, so a
            // live one can legitimately still be running well past that.
            let age = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date)
                .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
            if age < 1800 { return "hermes seed: another copy of Alfie is installing it" }
            try? fm.removeItem(at: lock)
            return "hermes seed: cleared a stale lock; the next launch installs it"
        }
        close(fd)
        defer { try? fm.removeItem(at: lock) }

        // Copy beside the destination and move into place, so an interrupted
        // copy leaves no half-tree that `hermesInstalled()` would later call
        // good. `.hermes-seeding` rather than a temp dir: it has to be on the
        // same filesystem for the move to be a rename.
        let staging = root.appendingPathComponent(".hermes-seeding", isDirectory: true)
        try? fm.removeItem(at: staging)

        // Clone, don't copy.
        //
        // `fm.copyItem` writes every byte a second time, and the seed is
        // 817 MB — so a Mac with Moe on it carried the whole of Hermes
        // TWICE, once inside the app and once here, for no reason anybody
        // chose. It was measured, not guessed: `/Applications/Memoe.app` is
        // 1.89 GB and `~/.hermes` is another 817 MB of the same bytes.
        //
        // APFS `clonefile` gives the copy its own directory entries while
        // the two share their blocks, so this costs almost no disk and
        // almost no time. It is not a symlink or a hard link: the trees are
        // independent, and `substitute` below rewrites the placeholder in
        // roughly a hundred small text files, each of which quietly stops
        // sharing at that moment. Deleting or updating Memoe.app leaves this
        // tree whole — APFS refcounts the blocks, and the last reference
        // frees them.
        //
        // It needs both trees on one APFS volume. A user-installed
        // `/Applications/Memoe.app` and `~/Library` are both on the Data
        // volume, so that is the normal case — but a Mac booted off HFS+,
        // an app run from a mounted image, or a home directory on a network
        // share are all real, and there clonefile fails with EXDEV or
        // ENOTSUP. So the byte copy stays as the fallback rather than being
        // deleted: the saving is worth having and is worth nothing if it
        // makes a Mac unable to install Hermes at all.
        // **Both of these preserve modification times, and that is
        // load-bearing — do not normalise them.**
        //
        // CPython decides whether cached bytecode is still valid by comparing
        // the `.pyc`'s recorded mtime and size against the source file's. The
        // seed's `.pyc` are timestamp-based (`flags == 0`, measured
        // 2026-09-08), so distinct mtimes between one seed and the next are
        // what makes a refreshed file recompile.
        //
        // A build that fixed every mtime to a constant — SOURCE_DATE_EPOCH for
        // reproducible builds, `touch -t` to make notarisation diffs quiet,
        // both entirely reasonable things to want — would give two different
        // versions of a file the same mtime, and where the size also matched,
        // CPython would keep the old bytecode. The new source would be on disk
        // and the old code would run, with every hash-based check in this repo
        // green. `scripts/refresh-hermes-seed.sh` drops the cached bytecode for
        // each file it rewrites so its own path does not depend on this; a
        // fresh lay-down still does.
        var cloned = false
        if clonefile(seed.path, staging.path, 0) == 0 {
            cloned = true
        } else {
            let why = errno
            Log.write("hermes seed: clonefile unavailable (errno \(why)) — copying instead")
            do {
                try fm.copyItem(at: seed, to: staging)
            } catch {
                try? fm.removeItem(at: staging)
                return "hermes seed: copy failed (\(error.localizedDescription))"
            }
        }
        Log.write("hermes seed: staged by \(cloned ? "clone" : "copy")")

        let rewritten = substitute(placeholder, with: root.path, under: staging)
        restoreExecutableBits(under: staging)

        // Move the three top-level pieces in. The destination directory
        // already exists and holds the lock, so this cannot be one rename.
        var moved = 0
        var failed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] {
            let src = staging.appendingPathComponent(name)
            let dst = root.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                moved += 1
            } catch {
                failed.append(name)
            }
        }
        try? fm.removeItem(at: staging)

        guard failed.isEmpty else {
            return "hermes seed: could not place \(failed.joined(separator: ", "))"
        }
        // `contentsOfDirectory` throwing yields nil, `?? []` makes the loop a
        // no-op, and `failed` is then empty — so without this, an unreadable
        // or empty staging directory reported success and wrote the stamp
        // having installed nothing at all.
        guard moved > 0 else {
            return "hermes seed: nothing was placed; leaving it for the next launch"
        }

        // Nothing may still name the placeholder. This is the difference
        // between a working brain and one that is permanently dead while
        // claiming to be fine: `restoreExecutableBits` makes `.venv/bin/hermes`
        // executable whether or not its shebang was rewritten, so
        // `Bootstrap.hermesInstalled()` says yes, the network fallback is
        // skipped, the stamp is written — and every launch afterwards reports
        // "installed but not runnable" and never retries.
        //
        // The two sides of this rewrite use different rules by necessity (the
        // staging script decodes every file; this one scopes by location and
        // extension for speed), and nothing but this check keeps them honest
        // when an upstream venv change puts a path somewhere new.
        if let stranded = firstFileContaining(Self.placeholder, under: root) {
            return "hermes seed: \(stranded.lastPathComponent) still names the seed's build path; "
                 + "not marking it installed, so the download fallback runs"
        }

        try? want.write(to: stamp, atomically: true, encoding: .utf8)
        return "hermes seed \(want) installed (\(moved) parts, \(rewritten) paths rewritten)"
    }

    /// Replaces the placeholder with this Mac's real path, in text files only.
    ///
    /// Scoped by location and extension rather than by sniffing every one of
    /// ~18,000 files: the placeholder is only ever written into `bin/`
    /// scripts and a handful of config formats, and a blind byte-substitution
    /// across a 400 MB tree would eventually corrupt a `.so`.
    @discardableResult
    static func substitute(_ token: String, with real: String, under tree: URL) -> Int {
        let fm = FileManager.default
        let interesting: Set<String> = ["cfg", "pth", "json", "txt", "py", "sh", "toml", "yaml", "yml"]
        var count = 0
        guard let e = fm.enumerator(at: tree, includingPropertiesForKeys: nil) else { return 0 }
        for case let url as URL in e {
            let isBin = url.deletingLastPathComponent().lastPathComponent == "bin"
            guard isBin || interesting.contains(url.pathExtension) else { continue }
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8),
                  text.contains(token) else { continue }
            let out = text.replacingOccurrences(of: token, with: real)
            // Preserve the mode: writing through String drops it, and these
            // are the very files that have to stay executable.
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
                .flatMap { $0 }
            if (try? out.write(to: url, atomically: true, encoding: .utf8)) != nil {
                if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
                count += 1
            }
        }
        return count
    }

    /// The first file under `tree` whose bytes still contain `token`, or nil.
    ///
    /// Byte-level and unscoped, unlike `substitute` — this is the check, not
    /// the fix, and it has to be able to see a file that `substitute`'s rules
    /// did not reach. Stops at the first hit, so the common case (none) is
    /// one pass and the failing case is short.
    static func firstFileContaining(_ token: String, under tree: URL) -> URL? {
        let fm = FileManager.default
        let needle = Data(token.utf8)
        guard let e = fm.enumerator(at: tree, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = v?.fileSize, size > 0, size < 8_000_000 else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if data.range(of: needle) != nil { return url }
        }
        return nil
    }

    /// `atomically: true` writes through a temp file and loses the exec bit,
    /// and a venv whose `bin/` is not executable is a venv that cannot start.
    /// Cheaper and more reliable to assert the bit than to remember it.
    private static func restoreExecutableBits(under tree: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: tree, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e {
            guard url.deletingLastPathComponent().lastPathComponent == "bin" else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        }
    }
}
