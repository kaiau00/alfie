import Darwin
import Foundation
import MoeBrain

/// **Moving an installed Hermes to the commit this build of Moe pins.**
///
/// The problem, stated once. `HERMES_COMMIT` in `scripts/install-hermes.sh`
/// names the exact Hermes an install gets, and bumping it is how a fix in the
/// fork reaches people. But every path that could run the installer declined
/// to touch an existing Hermes: `scripts/install.sh` skips it when `hermes` is
/// on the PATH, `HermesSeed.installIfNeeded` returns "already exists and was
/// left untouched", and `Bootstrap.installHermes` is reachable only from two
/// "Set it up" buttons that are shown only when Hermes is *missing*. So a pin
/// bump reached nobody who already had one. Nothing broke and nothing said
/// anything; every Mac kept the commit it was installed with
/// (`docs/BUNDLE.md §5c`).
///
/// ## What this does
///
/// At every launch, in the background, it reads two facts and compares them:
/// the pin out of Moe's own copy of `install-hermes.sh` (`HermesPin` — one
/// source of truth, never a second constant), and `HEAD` of the checkout at
/// `~/.hermes/hermes-agent`. When the checkout is **pristine**
/// (`HermesCheckout` — nobody's branches, worktrees, stash, half-done
/// operations or uncommitted work, on the fork's own remote, a full clone) and
/// not already known to be ahead, it takes its own lock, **fetches the pin**
/// (the tree is about to be modified anyway, and before the fetch neither
/// direction nor the paths the pin touches can be known), re-reads HEAD,
/// direction and the ignored-file overlap with the pin in hand, and only then
/// re-runs the installer. The installer is idempotent: on an existing checkout
/// it does `git fetch` + `--ff-only` and `uv sync --locked`, measured at
/// seconds when little changed, **not** the 1.3 GB a first install downloads.
/// Then it restarts the gateway, because the gateway read the old tree at boot
/// and will run it until told otherwise.
///
/// ## What "healthy" means
///
/// A venv is healthy when `.venv/bin/hermes` is executable **and** the
/// installer's own stamp, `.venv/.moe-sync`, names HEAD. The installer removes
/// that stamp at the START of every sync and writes it only at the end, so a
/// sync that died half-way leaves a venv with a runnable `hermes` and no
/// stamp — `uv` syncs in place and never removes the directory. "At the pin
/// with an executable" was therefore not "up to date", and a rollback copy
/// beside such a venv is the good one, not a leftover.
///
/// ## What it never does
///
/// - **Move a checkout back.** A checkout *ahead* of the pin — after `hermes
///   update`, a developer's pull, or simply because this Moe is older than the
///   one that last moved it — is reported and left, whether that was known
///   before the fetch or learned from it. Moe Dev shares `~/.hermes` with the
///   real Moe and is built from worktrees that are behind `main` most of the
///   time; a workbench that rewound the user's Hermes at every launch would be
///   the 2026-09-03 incident again. And HEAD is read again under the lock:
///   `hermes update` during the wait for the gateway is a moved premise, and
///   a moved premise is a launch that does nothing.
/// - **Move anything from Moe Dev**, or from a bundle-less debug binary,
///   which `BuildInfo.isDev` counts as the workbench too.
/// - **Retry a failed move — or a failed repair — on the same commits for a
///   day.** One failure is a receipt and a banner; the same failure at every
///   launch is a log that grows for ever and a fetch on every start.
/// - **Run under another Moe's gateway**, or over a gateway that failed, or
///   while quitting: the move waits for a gateway of Moe's own to be up.
///   Two Moes on one Mac (the real one and Moe Dev share `hermesPort`) means
///   the second to launch adopts, and never upgrades — it says so, once.
///
/// ## When it refuses, and how it says so
///
/// A checkout that is not pristine is left byte-for-byte alone, and the
/// refusal is written where a developer looks — `moe.log`, the receipt file
/// `~/.moe/logs/hermes-upgrades.log`, and one Notification Centre banner per
/// distinct state — never Moe's own inbox or the island, which belong to the
/// person (CLAUDE.md, the stale-install receipt). The sentence names the
/// reasons and what would do it by hand: the two git commands, naming the
/// remote that actually points at the fork, or how to add one; or, at the pin,
/// how to rebuild the venv.
///
/// A tree with no `.git` — the seed inside Memoe.app laid down on a downloaded
/// Mac, which is the common case — is reported honestly as "not a checkout;
/// cannot fast-forward", never as up to date. No `git` is spawned for it: on a
/// Mac without the developer tools `/usr/bin/git` is a shim that pops a dialog
/// offering to install them, in the middle of a launch.
///
/// ## Failure
///
/// The old Hermes must still be there and working. The lock carries the
/// holder's pid and executable name, is refreshed every minute while a run is
/// in flight, and is taken over when the holder is dead, when the pid now
/// belongs to a process whose executable is not the RECORDED name (pids are
/// recycled; pid 1 is always alive), or when a live holder has not refreshed
/// it in five minutes — after one more refresh interval's grace, since a Mac
/// waking from sleep has a live run whose timer has not fired yet. The
/// takeover is rename-then-claim, as the installer's own is. `.venv` is cloned aside (APFS `clonefile`,
/// near-free) and a venv that cannot be saved is a move that does not start;
/// the installer runs under the same death-pipe wrapper as the gateway, so it
/// dies with Moe, `kill -9` included. If the run fails, times out, is
/// cancelled, ends with `HEAD` anywhere but the pin, or without a healthy
/// venv, the branch is put back at the commit it started on and the venv
/// swapped back. Before every move, `tidy` repairs what a killed run leaves: a
/// rollback copy beside a missing or half-synced venv is put back, a dead
/// holder's lock is cleared. A tree that could not be put back is the one
/// thing announced unconditionally, never throttled.
enum HermesUpgrade {

    static var hermesHome: URL {
        if let env = TestHooks.env("HERMES_HOME") { return URL(fileURLWithPath: env, isDirectory: true) }
        return HermesSeed.destination
    }

    static func agentDir(in home: URL) -> URL {
        home.appendingPathComponent("hermes-agent", isDirectory: true)
    }

    /// The shipped app finds it in the payload (`~/.moe/scripts`, then the
    /// bundle). A bare `swift build` binary with no `MOE_HERMES_INSTALLER`
    /// falls through `ScriptRunner.scriptPath`'s last rung to
    /// `~/moe/scripts/install-hermes.sh` — a developer's checkout, whatever
    /// branch it is on. Harmless for the shipped app, which never reaches
    /// that rung; a bare binary is the workbench anyway (`isWorkbench`) and
    /// moves nothing.
    static func installerPath() -> String? {
        TestHooks.env("MOE_HERMES_INSTALLER") ?? Bootstrap.installerPath()
    }

    static var isWorkbench: Bool {
        switch TestHooks.env("MOE_HERMES_ROLE") {
        case "dev": return true
        case "release": return false
        default: return BuildInfo.isDev
        }
    }

    static func forkURL(script text: String?) -> String {
        if let env = ProcessInfo.processInfo.environment["HERMES_FORK"], !env.isEmpty { return env }
        if let text, let url = HermesPin.forkURL(script: text) { return url }
        return HermesCheckout.defaultFork
    }

    static let receiptName = "hermes-upgrades.log"
    static let saidName = "hermes-upgrade.said"
    static let triedName = "hermes-upgrade.tried"
    nonisolated(unsafe) static var quietBanners = false
    static var installerTimeout: TimeInterval {
        TestHooks.env("MOE_HERMES_INSTALLER_TIMEOUT").flatMap(Double.init) ?? 1200
    }
    /// A lock with no readable holder is presumed dead after this long; one
    /// with a live holder is presumed abandoned when its mtime — refreshed
    /// every minute by a run in flight — is older than this.
    static let lockStaleAfter: TimeInterval = 1800
    static let lockQuietAfter: TimeInterval = 300
    static let lockRefreshEvery: TimeInterval = 60
    /// The installer's own lock is an empty directory; its script takes one
    /// over after an hour, so a lock older than that is nobody's.
    static let installerLockStaleAfter: TimeInterval = 3600

    // MARK: - git

    static func gitExecutable() -> String? {
        let fm = FileManager.default
        for p in ["/Library/Developer/CommandLineTools/usr/bin/git",
                  "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                  "/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/xcode-select"),
              fm.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        let r = run("/usr/bin/xcode-select", ["-p"], timeout: 10)
        return r.status == 0 ? "/usr/bin/git" : nil
    }

    struct Git {
        let exe: String
        let dir: URL
        func run(_ args: [String], timeout: TimeInterval = 60) -> (status: Int32, out: String) {
            let r = HermesUpgrade.run(exe, ["-C", dir.path] + args, timeout: timeout)
            return (r.status, r.out)
        }
        func head() -> String? {
            let r = run(["rev-parse", "--verify", "-q", "HEAD"])
            let sha = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.status == 0 && sha.count == 40 ? sha : nil
        }
        func hasCommit(_ sha: String) -> Bool {
            run(["cat-file", "-e", "\(sha)^{commit}"]).status == 0
        }
        func isAncestor(_ a: String, of b: String) -> Bool {
            run(["merge-base", "--is-ancestor", a, b]).status == 0
        }
        func ancestry(head: String, pin: String) -> HermesCheckout.Ancestry {
            guard hasCommit(pin) else { return .unknown }
            if isAncestor(head, of: pin) { return .behind }
            if isAncestor(pin, of: head) { return .ahead }
            return .diverged
        }
        func overwritten(head: String, pin: String) -> [String] {
            guard hasCommit(pin) else { return [] }
            let changed = run(["diff", "--name-only", head, pin]).out
                .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            guard !changed.isEmpty else { return [] }
            let status = run(["status", "--porcelain", "--ignored=matching", "--untracked-files=all", "--"] + changed).out
            return status.split(whereSeparator: \.isNewline).map(String.init)
                .filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }
        }
        func gitDir() -> URL? {
            let g = run(["rev-parse", "--git-dir"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !g.isEmpty else { return nil }
            return g.hasPrefix("/") ? URL(fileURLWithPath: g) : dir.appendingPathComponent(g)
        }
        func inProgress() -> [String] {
            guard let base = gitDir() else { return [] }
            return HermesCheckout.inProgressMarkers.filter {
                FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
            }
        }
        func facts(head: String, pin: String) -> HermesCheckout.GitFacts {
            HermesCheckout.GitFacts(
                symbolicRef: run(["symbolic-ref", "-q", "HEAD"]).out,
                status: run(["status", "--porcelain", "--untracked-files=normal"]).out,
                worktrees: run(["worktree", "list", "--porcelain"]).out,
                branches: run(["for-each-ref", "refs/heads", "--format=%(refname:short)"]).out,
                stash: run(["stash", "list"]).out,
                remotes: run(["remote", "-v"]).out,
                inProgress: inProgress(),
                ancestry: ancestry(head: head, pin: pin),
                overwritten: overwritten(head: head, pin: pin),
                shallow: gitDir().map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("shallow").path) } ?? false)
        }
    }

    /// A short local command: stdout+stderr merged, bounded, no shell. With
    /// `cancellable`, the process is registered so `cancelForShutdown` can
    /// stop it — the fetch is the one long command outside the installer.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, cancellable: Bool = false) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        // A read must not write: without this `git status` refreshes the
        // index — a write into somebody's tree, from a check that promised
        // to leave it byte-for-byte alone.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        if cancellable { stateLock.lock(); auxiliaryProcess = p; stateLock.unlock() }
        defer { if cancellable { stateLock.lock(); auxiliaryProcess = nil; stateLock.unlock() } }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.5); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - What is on disk

    enum Installed {
        case absent
        case notACheckout(seedCommit: String?)
        case checkout
    }

    static func installed(agentDir: URL) -> Installed {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: agentDir.path, isDirectory: &isDir), isDir.boolValue else { return .absent }
        if fm.fileExists(atPath: agentDir.appendingPathComponent(".git").path) { return .checkout }
        let stamp = agentDir.appendingPathComponent(".moe-seed-commit")
        let sha = (try? String(contentsOf: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = sha.map { $0.count == 40 && $0.allSatisfy { $0.isHexDigit } } ?? false
        return .notACheckout(seedCommit: valid ? sha : nil)
    }

    /// `.venv/.moe-sync`, whole, or nil when there is no stamp: the installer
    /// removes it at the start of every sync and writes it back only at the
    /// end. It reads `"<sha> <HERMES_EXTRAS> <uv --version>"`.
    static func syncStamp(venv: URL) -> String? {
        (try? String(contentsOf: venv.appendingPathComponent(".moe-sync"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sha the venv was synced for — the stamp's first field.
    static func syncStampSha(venv: URL) -> String? {
        let first = syncStamp(venv: venv)?.split(whereSeparator: { $0 == " " || $0.isNewline }).first.map(String.init)
        return first.flatMap { $0.count == 40 ? $0 : nil }
    }

    /// What the installer would write for `head` right now — the string its
    /// own "already in sync" test compares against (`install-hermes.sh`,
    /// step 4): `"<sha> <HERMES_EXTRAS> <uv --version>"`. Extras come from
    /// the environment, else the script's default; uv from where the
    /// installer looks for it. Nil when uv cannot be found, in which case the
    /// sha alone is compared — a Mac with no uv has no installer to disagree.
    static func expectedStamp(head: String, script: String?) -> String? {
        let env = ProcessInfo.processInfo.environment
        let extras = env["HERMES_EXTRAS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? script.flatMap(HermesPin.extrasDefault(script:))
            ?? "all messaging anthropic edge-tts voice"   // install-hermes.sh HERMES_EXTRAS
        guard let uv = uvVersion() else { return nil }
        return "\(head) \(extras) \(uv)"
    }

    nonisolated(unsafe) private static var cachedUVVersion: String??
    static func uvVersion() -> String? {
        if let c = cachedUVVersion { return c }
        let fm = FileManager.default
        let bin = ProcessInfo.processInfo.environment["MOE_BIN_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/bin"
        var candidates = [bin + "/uv"]
        for dir in ScriptRunner.environment()["PATH"]?.split(separator: ":") ?? [] { candidates.append("\(dir)/uv") }
        var found: String?
        for c in candidates where fm.isExecutableFile(atPath: c) {
            let r = run(c, ["--version"], timeout: 20)
            if r.status == 0, let line = r.out.split(whereSeparator: \.isNewline).first { found = String(line); break }
        }
        cachedUVVersion = .some(found)
        return found
    }

    /// Runnable AND synced for this HEAD, by the installer's own rule: the
    /// whole stamp, not just its sha. A changed extra or a new uv without a
    /// pin bump is a venv the installer would re-sync, so it is not "up to
    /// date" here either.
    static func venvHealthy(_ venv: URL, head: String, script: String?) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: venv.appendingPathComponent("bin/hermes").path),
              let stamp = syncStamp(venv: venv) else { return false }
        if let want = expectedStamp(head: head, script: script) { return stamp == want }
        return syncStampSha(venv: venv) == head
    }

    // MARK: - The decision

    static func decide(home: URL) -> HermesUpgradeDecision {
        let agent = agentDir(in: home)
        guard let installer = installerPath() else { return .noInstaller }
        let text = try? String(contentsOfFile: installer, encoding: .utf8)
        let pin: String
        switch text.map(HermesPin.read(script:)) ?? .missing {
        case .missing:          return .noPin(installer: installer)
        case .followsTip:       return .followingTip(installer: installer)
        case .pinned(let sha):  pin = sha
        }
        switch installed(agentDir: agent) {
        case .absent:
            return .absent(agentDir: agent.path)
        case .notACheckout(let seed):
            // No stamp: nothing on this Mac can say which Hermes this is, and
            // an unknown tree is not one to write into. Unchanged.
            guard let seed else { return .notACheckout(agentDir: agent.path, seedCommit: nil) }
            // A stamped seed. Until this change every route stopped here and
            // said so honestly — and honest was not enough: the pin moved and
            // nothing moved with it, on every Mac that had downloaded Moe.
            //
            // `venvHealthy` is deliberately NOT asked. It encodes the
            // installer's own rule ("this venv was synced for this HEAD with
            // these extras by this uv"), and a seed's venv was built by
            // stage-hermes-seed.sh with a different set of extras — measured
            // on this Mac: the seed carries "…edge-tts voice google youtube
            // acp" where the installer's default is "…edge-tts". Asking it
            // would call every seed unhealthy and start a rebuild that
            // replaces .venv, which is the one thing that must not happen.
            if seed == pin { return .upToDate(head: seed) }
            // The refresh reaches the fork, and reaching it needs git. On a
            // Mac with no developer tools `/usr/bin/git` is a shim that offers
            // to install them — a dialog, in the middle of a launch.
            //
            // Unless this Memoe carries a seed AT the pin: then the installer
            // lays that seed (scripts/reseed-hermes.sh) and reaches nothing.
            guard HermesSeed.bundledCommit() == pin || gitExecutable() != nil else {
                return .noGit(agentDir: agent.path)
            }
            if isWorkbench { return .workbench(agentDir: agent.path, head: seed, pin: pin) }
            if let when = triedBefore(head: seed, pin: pin) {
                return .triedAlready(agentDir: agent.path, head: seed, pin: pin, when: when)
            }
            return .seedRefresh(agentDir: agent.path, from: seed, to: pin)
        case .checkout:
            break
        }
        guard let exe = gitExecutable() else { return .noGit(agentDir: agent.path) }
        let git = Git(exe: exe, dir: agent)
        guard let head = git.head() else {
            return .notACheckout(agentDir: agent.path, seedCommit: nil)
        }
        let venv = agent.appendingPathComponent(".venv", isDirectory: true)
        if head == pin, venvHealthy(venv, head: head, script: text) { return .upToDate(head: head) }
        let facts = git.facts(head: head, pin: pin)
        let fork = forkURL(script: text)
        let verdict = HermesCheckout.verdict(facts, fork: fork)
        guard verdict.pristine else {
            return .refused(agentDir: agent.path, head: head, pin: pin, reasons: verdict.reasons,
                            remote: HermesCheckout.remoteNamingFork(in: facts.remotes, fork: fork), fork: fork)
        }
        if facts.ancestry == .ahead { return .ahead(agentDir: agent.path, head: head, pin: pin) }
        if isWorkbench { return .workbench(agentDir: agent.path, head: head, pin: pin) }
        // A failed move OR repair is remembered for a day; a repair that keeps
        // failing must not fetch and banner at every launch.
        if let when = triedBefore(head: head, pin: pin) {
            return .triedAlready(agentDir: agent.path, head: head, pin: pin, when: when)
        }
        if head == pin { return .repair(agentDir: agent.path, head: head) }
        return .upgrade(agentDir: agent.path, from: head, to: pin)
    }

    static let retryAfter: TimeInterval = 86_400
    static func triedBefore(head: String, pin: String) -> String? {
        let url = Paths.logs.appendingPathComponent(triedName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard parts.count == 3, parts[0] == head, parts[1] == pin else { return nil }
        guard let when = ISO8601DateFormatter().date(from: parts[2]),
              Date().timeIntervalSince(when) < retryAfter else { return nil }
        return parts[2]
    }

    private static func rememberFailure(head: String, pin: String) {
        let url = Paths.logs.appendingPathComponent(triedName)
        try? "\(head) \(pin) \(ISO8601DateFormatter().string(from: Date()))\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func forgetFailure() {
        try? FileManager.default.removeItem(at: Paths.logs.appendingPathComponent(triedName))
    }

    // MARK: - The lock

    /// `<home>/.hermes-upgrade.lock/`, a directory (mkdir is atomic) holding
    /// `pid` — the holder's pid and the name of its executable. It is stale
    /// when the holder is dead, when the pid belongs to something that is not
    /// a Moe (pids are recycled: pid 1 is always alive), or when a live
    /// holder has not refreshed the mtime for five minutes (a run refreshes
    /// every minute). A lock with no readable pid falls back to a long age.
    enum Lock {
        case held
        case busy(pid_t)
        case failed(String)
    }

    static func lockURL(in home: URL) -> URL { home.appendingPathComponent(".hermes-upgrade.lock", isDirectory: true) }

    static var ownExecutable: String {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
    }

    static func holder(of lock: URL) -> (pid: pid_t, exe: String)? {
        guard let s = try? String(contentsOf: lock.appendingPathComponent("pid"), encoding: .utf8) else { return nil }
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let pid = pid_t(first) else { return nil }
        return (pid, lines.count > 1 ? lines[1] : "")
    }

    /// The executable name of a live process, or nil when there is none.
    static func executableName(of pid: pid_t) -> String? {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        let r = run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"], timeout: 10)
        let comm = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !comm.isEmpty else { return nil }
        var name = URL(fileURLWithPath: comm).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    /// Why a lock may be taken over, or nil when it is somebody's.
    static func staleness(of lock: URL) -> String? {
        let fm = FileManager.default
        let age = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date)
            .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
        guard let h = holder(of: lock) else {
            return age >= lockStaleAfter ? "no readable holder, \(Int(age))s old" : nil
        }
        if h.pid == getpid() { return "held by this process" }
        guard let name = executableName(of: h.pid) else { return "holder pid \(h.pid) is gone" }
        if !h.exe.isEmpty, name != h.exe { return "pid \(h.pid) is now \(name), not \(h.exe) — a recycled pid" }
        if age >= lockQuietAfter { return quietMarker + "pid \(h.pid) is alive but the lock has not been refreshed for \(Int(age))s" }
        return nil
    }
    private static let quietMarker = "quiet:"

    /// How long to wait before taking over a live holder's quiet lock — one
    /// refresh interval and change. A Mac waking from sleep has a live run
    /// whose refresher has not fired yet; giving it one interval to touch the
    /// lock (or to finish and release it) is the difference between a
    /// takeover of an abandoned lock and a takeover of a run that is still
    /// putting a venv back. `MOE_HERMES_LOCK_RECHECK` (debug) shortens it.
    static var lockRecheckAfter: TimeInterval {
        TestHooks.env("MOE_HERMES_LOCK_RECHECK").flatMap(Double.init) ?? (lockRefreshEvery + 30)
    }

    static func acquireLock(in home: URL) -> Lock {
        let fm = FileManager.default
        let lock = lockURL(in: home)
        for _ in 0..<3 {
            if mkdir(lock.path, 0o755) == 0 {
                try? "\(getpid())\n\(ownExecutable)\n".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
                return .held
            }
            guard errno == EEXIST else { return .failed("cannot create \(lock.path) (errno \(errno))") }
            guard var why = staleness(of: lock) else { return .busy(holder(of: lock)?.pid ?? 0) }
            if why.hasPrefix(quietMarker) {
                // Live, matching, quiet. Wait one refresh interval and look
                // again: a refreshed mtime is a run; a released lock is a
                // finished one; the same mtime is an abandoned lock.
                let before = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date).flatMap { $0 }
                Log.write("hermes upgrade: the upgrade lock's holder is alive but quiet; waiting \(Int(lockRecheckAfter))s before deciding it is abandoned")
                Thread.sleep(forTimeInterval: lockRecheckAfter)
                let after = (try? fm.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date).flatMap { $0 }
                if after == nil { continue }                       // released meanwhile; claim it
                if after != before { return .busy(holder(of: lock)?.pid ?? 0) }   // refreshed: a run
                why = String(why.dropFirst(quietMarker.count)) + ", even after waiting \(Int(lockRecheckAfter))s"
            }
            // Rename, then claim — the installer's own shape (install-hermes.sh
            // :157). Remove-then-mkdir lets two takers interleave so that the
            // second removes the FRESH lock the first just made.
            let aside = home.appendingPathComponent(".hermes-upgrade.lock.stale.\(getpid())")
            if (try? fm.moveItem(at: lock, to: aside)) != nil {
                try? fm.removeItem(at: aside)
                Log.write("hermes upgrade: cleared a stale upgrade lock (\(why))")
            }
        }
        return .failed("could not take \(lock.path)")
    }

    static func releaseLock(in home: URL) {
        try? FileManager.default.removeItem(at: lockURL(in: home))
    }

    private static func refreshing(_ lock: URL) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + lockRefreshEvery, repeating: lockRefreshEvery)
        t.setEventHandler { utimes(lock.path, nil) }
        t.resume()
        return t
    }

    // MARK: - Tidying what a killed run leaves

    /// Under the lock. A surviving `.venv-rollback` means the venv beside it
    /// is SUSPECT: it is put back when `.venv` is missing OR unhealthy (no
    /// stamp, or a stamp for another HEAD — the shape a kill mid-`uv sync`
    /// leaves, since uv syncs in place). Only beside a healthy venv is the
    /// copy a leftover. Returns what it did.
    private static func tidyLocked(home: URL, git: Git?, script: String?) -> [String] {
        let fm = FileManager.default
        let agent = agentDir(in: home)
        let venv = agent.appendingPathComponent(".venv", isDirectory: true)
        let rollback = home.appendingPathComponent(".venv-rollback", isDirectory: true)
        let failed = home.appendingPathComponent(".venv-failed", isDirectory: true)
        var notes: [String] = []
        let head = git?.head()
        let copyRunnable = fm.isExecutableFile(atPath: rollback.appendingPathComponent("bin/hermes").path)
        let venvPresent = fm.fileExists(atPath: venv.path)
        let besideIsHealthy = head.map { Self.venvHealthy(venv, head: $0, script: script) } ?? false
        if copyRunnable, fm.fileExists(atPath: agent.path), !besideIsHealthy {
            // The copy's own stamp names the commit it was synced for. If the
            // branch has moved on since (the killed run had fast-forwarded
            // before its sync died), restoring the venv alone would leave
            // new source over old dependencies — for a day, if the repair
            // then failed offline. The branch goes back with the venv.
            let syncedFor = syncStampSha(venv: rollback)
            do {
                if venvPresent {
                    try? fm.removeItem(at: failed)
                    try fm.moveItem(at: venv, to: failed)
                }
                try fm.moveItem(at: rollback, to: venv)
                try? fm.removeItem(at: failed)
                notes.append(venvPresent
                    ? "restored .venv from the rollback copy; the venv beside it was half-synced (no stamp for HEAD) — a run was stopped mid-sync"
                    : "restored .venv from the rollback copy a stopped run left behind")
                if let git, let syncedFor, let head, syncedFor != head, git.hasCommit(syncedFor) {
                    let back = git.run(["checkout", "-B", HermesCheckout.branch, syncedFor, "--"])
                    notes.append(back.status == 0
                        ? "the checkout is back at \(HermesPin.short(syncedFor)), the commit the restored venv was synced for"
                        : "the checkout could NOT be put back at \(HermesPin.short(syncedFor)) to match the restored venv (\(back.out.split(whereSeparator: \.isNewline).last ?? ""))")
                }
            } catch {
                if !venvPresent, fm.fileExists(atPath: failed.path) { try? fm.moveItem(at: failed, to: venv) }
                notes.append("could NOT restore .venv from the rollback copy (\(error.localizedDescription))")
            }
        }
        for (url, name) in [(rollback, ".venv-rollback"), (failed, ".venv-failed")] where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
            notes.append("removed \(name), left by a run that did not finish")
        }
        for n in notes { Log.write("hermes upgrade: \(n)") }
        return notes
    }

    /// The launch path's first step, before `decide`: take the lock (or stand
    /// aside), repair, release. Never from `--hermes-upgrade-check`, which is
    /// read-only.
    @discardableResult
    static func tidy(home: URL) -> [String] {
        let agent = agentDir(in: home)
        guard FileManager.default.fileExists(atPath: agent.path) else { return [] }
        switch acquireLock(in: home) {
        case .busy(let pid):
            Log.write("hermes upgrade: another Moe (pid \(pid)) holds the upgrade lock; not tidying")
            return []
        case .failed(let why):
            Log.write("hermes upgrade: \(why); not tidying")
            return []
        case .held:
            defer { releaseLock(in: home) }
            let git = gitExecutable().map { Git(exe: $0, dir: agent) }
            let script = installerPath().flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            return tidyLocked(home: home, git: git, script: script)
        }
    }

    // MARK: - Doing it

    struct Outcome {
        let moved: Bool
        let line: String
        let notify: Notify
    }

    nonisolated(unsafe) private static var installerProcess: Process?
    /// The fetch, while it runs: the one long command that is not the installer.
    nonisolated(unsafe) private static var auxiliaryProcess: Process?
    nonisolated(unsafe) private static var shuttingDown = false
    private static let idle = DispatchSemaphore(value: 1)
    private static let stateLock = NSLock()

    static func cancelForShutdown(wait: TimeInterval = 20) {
        stateLock.lock()
        shuttingDown = true
        let p = installerProcess, a = auxiliaryProcess
        stateLock.unlock()
        if let p, p.isRunning { p.terminate() }
        if let a, a.isRunning { a.terminate() }
        if idle.wait(timeout: .now() + wait) == .success { idle.signal() }
        else { Log.write("hermes upgrade: the rollback did not finish within \(Int(wait))s of quitting; check hermes-upgrades.log") }
    }

    private static var quitting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return shuttingDown }

    struct InstallerRun {
        let status: Int32
        let timedOut: Bool
        let output: String
    }

    static func runInstaller(_ installer: String, home: URL, timeout: TimeInterval,
                             onLine: ((String) -> Void)?) -> InstallerRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", HermesSupervisor.wrapperScript, "Moe Installer", installer]
        // MOE_HERMES_SEED_BUNDLE: the seed inside this Memoe.app. When the pin
        // changes what the venv contains (the Python 3.14 move, any uv.lock
        // change) refresh-hermes-seed.sh refuses by design, and the installer
        // lays THIS seed down instead (scripts/reseed-hermes.sh) — the venv the
        // release built and signed, offline. Without it an existing Mac never
        // leaves the Hermes it first installed.
        var extra = ["HERMES_HOME": home.path]
        if let seed = HermesSeed.bundleSeed { extra["MOE_HERMES_SEED_BUNDLE"] = seed.path }
        p.environment = ScriptRunner.environment(extra)
        p.currentDirectoryURL = Paths.home
        let life = Pipe(), out = Pipe()
        p.standardInput = life
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            return InstallerRun(status: -1, timedOut: false, output: "could not run \(installer): \(error.localizedDescription)")
        }
        stateLock.lock(); installerProcess = p; stateLock.unlock()
        defer { stateLock.lock(); installerProcess = nil; stateLock.unlock() }
        var timedOut = false
        let timer = DispatchWorkItem { timedOut = true; if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        var text = ""
        var buffer = Data()
        let h = out.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.hasPrefix("moe-hermes-pid ") { continue }
                text += line + "\n"
                onLine?(line)
            }
        }
        if !buffer.isEmpty { let line = String(decoding: buffer, as: UTF8.self); text += line; onLine?(line) }
        p.waitUntilExit()
        timer.cancel()
        _ = life
        return InstallerRun(status: p.terminationStatus, timedOut: timedOut, output: text)
    }

    /// Runs the installer against `home` and holds it to the result. Never
    /// throws; every path ends with the old Hermes or the new one, and a
    /// sentence saying which. `from == to` is a repair: no fetch, no direction.
    static func perform(home: URL, from: String, to: String, installer: String,
                        onLine: ((String) -> Void)? = nil) -> Outcome {
        idle.wait()
        defer { idle.signal() }
        let fm = FileManager.default
        let agent = agentDir(in: home)
        let venv = agent.appendingPathComponent(".venv", isDirectory: true)
        let rollback = home.appendingPathComponent(".venv-rollback", isDirectory: true)
        let failed = home.appendingPathComponent(".venv-failed", isDirectory: true)
        let hermesBin = venv.appendingPathComponent("bin/hermes").path
        let installerLock = home.appendingPathComponent(".install.lock")
        let repair = from == to
        guard let exe = gitExecutable() else {
            return Outcome(moved: false, line: "hermes upgrade: git disappeared between the check and the run; nothing was touched", notify: .record)
        }
        let git = Git(exe: exe, dir: agent)

        if quitting {
            return Outcome(moved: false, line: "hermes upgrade: Moe is quitting; the move was not started", notify: .log)
        }

        switch acquireLock(in: home) {
        case .busy(let pid):
            return Outcome(moved: false, line: "hermes upgrade: another Moe\(pid > 0 ? " (pid \(pid))" : "") is already moving \(agent.path); this one stood aside and touched nothing", notify: .log)
        case .failed(let why):
            return Outcome(moved: false, line: "hermes upgrade: \(why); nothing was touched", notify: .record)
        case .held:
            break
        }
        defer { releaseLock(in: home) }
        let refresher = refreshing(lockURL(in: home))
        defer { refresher.cancel() }
        let script = try? String(contentsOfFile: installer, encoding: .utf8)
        _ = tidyLocked(home: home, git: git, script: script)

        // Debug seam: something happens to the tree after the lock is taken
        // and before the premise is re-read — `hermes update` during the wait
        // for the gateway, in the suite's hands.
        if let cmd = TestHooks.env("MOE_HERMES_TEST_AFTER_LOCK") {
            _ = run("/bin/sh", ["-c", cmd], timeout: 30)
        }

        // The installer's own lock, read as a directory rather than as a
        // sentence — and with the installer's own staleness rule: its script
        // takes a lock over after an hour, so an older one is a run that died.
        if fm.fileExists(atPath: installerLock.path) {
            let age = (try? fm.attributesOfItem(atPath: installerLock.path)[.modificationDate] as? Date)
                .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
            if age < installerLockStaleAfter {
                return Outcome(moved: false, line: "hermes upgrade: another install of Hermes is running (\(installerLock.path) exists, \(Int(age))s old); this one stood aside and touched nothing", notify: .log)
            }
            Log.write("hermes upgrade: \(installerLock.path) is \(Int(age))s old — a run that died; the installer takes such a lock over itself")
        }

        if !repair {
            // Fetch first — the pin by sha, bounded, the way the installer's
            // own pin-probe does. Before the pin is local neither direction
            // nor the paths it touches can be known.
            let fetch = run(exe, ["-C", agent.path, "fetch", "--quiet", "origin", to], timeout: 300, cancellable: true)
            if quitting {
                return Outcome(moved: false, line: "hermes upgrade: Moe quit during the fetch; nothing was moved", notify: .log)
            }
            if fetch.status != 0 {
                rememberFailure(head: from, pin: to)
                let why = fetch.out.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(fetch.status)"
                return Outcome(moved: false,
                               line: "hermes upgrade: could not fetch the pinned \(HermesPin.short(to)) from origin for \(agent.path) (\(why)); nothing was moved, and it is not retried for a day",
                               notify: .once("nofetch \(from) \(to)", banner: false))
            }
            // The premise, re-read under the lock. The wait for the gateway
            // is tens of seconds; `hermes update` in that window moved HEAD,
            // and a move planned from the old HEAD would have been the
            // installer's "moved back … it was ahead".
            guard let now = git.head() else {
                return Outcome(moved: false, line: "hermes upgrade: HEAD of \(agent.path) became unreadable; nothing was moved", notify: .record)
            }
            if now != from {
                return Outcome(moved: false,
                               line: "hermes upgrade: HEAD of \(agent.path) moved from \(HermesPin.short(from)) to \(HermesPin.short(now)) while Moe was waiting; nothing was moved this launch",
                               notify: .log)
            }
            let fork = forkURL(script: script)
            let refusal = { (reasons: [String], key: String) -> Outcome in
                let d = HermesUpgradeDecision.refused(agentDir: agent.path, head: from, pin: to, reasons: reasons, remote: "origin", fork: fork)
                return Outcome(moved: false, line: d.line + " (learned after fetching)", notify: .once(key, banner: true))
            }
            switch git.ancestry(head: from, pin: to) {
            case .ahead:
                let d = HermesUpgradeDecision.ahead(agentDir: agent.path, head: from, pin: to)
                return Outcome(moved: false, line: d.line + " (learned after fetching)", notify: .once("ahead \(from) \(to)", banner: false))
            case .diverged:
                return refusal(["it has diverged from the pin (neither is an ancestor of the other)"], "refused \(from) \(to) diverged")
            case .unknown:
                rememberFailure(head: from, pin: to)
                return Outcome(moved: false,
                               line: "hermes upgrade: the pinned \(HermesPin.short(to)) could not be fetched from origin; nothing was moved (is the pin pushed?)",
                               notify: .once("nopin-on-branch \(to)", banner: true))
            case .behind:
                break
            }
            let over = git.overwritten(head: from, pin: to)
            if !over.isEmpty {
                return refusal(["\(over.count) ignored file\(over.count == 1 ? "" : "s") the fast-forward would overwrite: "
                                + over.prefix(3).joined(separator: ", ") + (over.count > 3 ? ", …" : "")],
                               "refused \(from) \(to) overwrite \(over.joined(separator: "|"))")
            }
        }

        if fm.fileExists(atPath: venv.path) {
            let cloned = TestHooks.env("MOE_HERMES_NO_CLONEFILE") == nil && clonefile(venv.path, rollback.path, 0) == 0
            if !cloned {
                let why = TestHooks.env("MOE_HERMES_NO_CLONEFILE") != nil ? "disabled for the test" : "clonefile failed, errno \(errno)"
                return Outcome(moved: false,
                               line: "hermes upgrade: cannot save \(venv.path) aside (\(why)) — a move that could not be undone is not started; "
                                     + "Hermes is left at \(HermesPin.short(from)). This home is not on APFS, or is a link into another volume",
                               notify: .once("nosave \(to)", banner: true))
            }
        }
        defer { try? fm.removeItem(at: rollback) }
        if quitting {
            return Outcome(moved: false, line: "hermes upgrade: Moe is quitting; the installer was not started", notify: .log)
        }

        let started = Date()
        let r = runInstaller(installer, home: home, timeout: installerTimeout, onLine: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("✓") || t.hasPrefix("✗") || t.hasPrefix("›") { onLine?(t) }
        })
        let cancelled = quitting
        let secs = Int(Date().timeIntervalSince(started).rounded())

        if r.status != 0, fm.fileExists(atPath: installerLock.path) {
            return Outcome(moved: false, line: "hermes upgrade: another install of Hermes is running (\(installerLock.path) is held); this one stood aside and touched nothing", notify: .log)
        }

        let head = git.head()
        let healthy = venvHealthy(venv, head: to, script: script)
        if r.status == 0, !r.timedOut, !cancelled, head == to, healthy {
            forgetFailure()
            let what = repair ? "repaired \(agent.path) at \(HermesPin.short(to)) (installer re-run)"
                              : "moved \(agent.path) from \(HermesPin.short(from)) to \(HermesPin.short(to))"
            return Outcome(moved: true, line: "hermes upgrade: \(what) in \(secs)s", notify: .always)
        }

        // Put it back.
        let why: String
        if cancelled { why = "Moe quit while the installer was running, so it was stopped" }
        else if r.timedOut { why = "the installer ran past \(Int(installerTimeout))s and was stopped" }
        else if r.status != 0 { why = "the installer exited \(r.status): \(installerReason(r.output))" }
        else if head != to { why = "the installer finished but HEAD is \(head.map(HermesPin.short) ?? "unreadable"), not \(HermesPin.short(to))" }
        else if !fm.isExecutableFile(atPath: hermesBin) { why = ".venv/bin/hermes is not executable after the run" }
        else { why = "the installer finished but left no sync stamp for \(HermesPin.short(to)) (.venv/.moe-sync)" }
        var notes: [String] = []
        if head != from {
            let back = git.run(["checkout", "-B", HermesCheckout.branch, from, "--"])
            notes.append(back.status == 0 ? "the checkout is back at \(HermesPin.short(from))"
                                          : "the checkout could NOT be put back at \(HermesPin.short(from)) (\(back.out.split(whereSeparator: \.isNewline).last ?? ""))")
        }
        if fm.fileExists(atPath: rollback.path) {
            if fm.fileExists(atPath: venv.path) { try? fm.moveItem(at: venv, to: failed) }
            do {
                try fm.moveItem(at: rollback, to: venv)
                try? fm.removeItem(at: failed)
                notes.append("the venv is restored")
            } catch {
                try? fm.moveItem(at: failed, to: venv)
                notes.append("the venv could NOT be restored (\(error.localizedDescription))")
            }
        } else {
            notes.append("the rollback copy of the venv was gone, so it could not be restored")
        }
        let backHead = git.head()
        // A repair started from a venv that was not healthy, so "back where it
        // was" is HEAD alone; a move also wants the venv runnable again.
        let backOK = backHead == from && (repair || fm.isExecutableFile(atPath: hermesBin))
        if !cancelled { rememberFailure(head: from, pin: to) }
        notes.append(backOK ? (repair ? "the checkout is unchanged; the venv still needs repairing (not retried for a day)"
                                      : "the old Hermes is in place and runnable")
                            : "CHECK IT: HEAD is \(backHead.map(HermesPin.short) ?? "unreadable") and .venv/bin/hermes is \(fm.isExecutableFile(atPath: hermesBin) ? "runnable" : "not runnable")")
        return Outcome(moved: false,
                       line: "hermes upgrade: FAILED to \(repair ? "repair" : "move") \(agent.path) \(repair ? "at" : "to") \(HermesPin.short(to)) — \(why); "
                             + notes.joined(separator: "; ") + " (details: \(Paths.logs.appendingPathComponent("install-hermes.log").path))",
                       notify: backOK ? .once("failed \(from) \(to)", banner: true) : .always)
    }

    /// Moves a **seed** to the pin, by running the installer, which runs
    /// `scripts/refresh-hermes-seed.sh`.
    ///
    /// Deliberately not `perform`. Every safety mechanism in that function is
    /// git-shaped — fetch the pin, read ancestry, put the branch back with
    /// `checkout -B` — and a seed has no `.git` for any of it. Threading a
    /// second shape through it would have meant `if seed` at a dozen points in
    /// the most consequential function in this file.
    ///
    /// **The undo lives in the script**, which is where the writes are: it
    /// saves every file it is about to touch, restores all of them on any
    /// failure or signal, and writes the stamp last. So there is no venv to
    /// clone aside here — the refresh does not write into `.venv` at all —
    /// and nothing to roll back on this side.
    ///
    /// What is checked here is **arrival**, not the exit code: the stamp has
    /// to read the pin and `.venv/bin/hermes` has to still be runnable. An
    /// installer that exits 0 having refreshed nothing is exactly the failure
    /// this whole change is about.
    static func performSeedRefresh(home: URL, from: String, to: String, installer: String,
                                   onLine: ((String) -> Void)? = nil) -> Outcome {
        idle.wait()
        defer { idle.signal() }
        let fm = FileManager.default
        let agent = agentDir(in: home)
        let stampURL = agent.appendingPathComponent(".moe-seed-commit")
        let hermesBin = agent.appendingPathComponent(".venv/bin/hermes").path
        let installerLock = home.appendingPathComponent(".install.lock")

        if quitting {
            return Outcome(moved: false, line: "hermes upgrade: Moe is quitting; the seed refresh was not started", notify: .log)
        }
        switch acquireLock(in: home) {
        case .busy(let pid):
            return Outcome(moved: false, line: "hermes upgrade: another Moe\(pid > 0 ? " (pid \(pid))" : "") is already moving \(agent.path); this one stood aside and touched nothing", notify: .log)
        case .failed(let why):
            return Outcome(moved: false, line: "hermes upgrade: \(why); nothing was touched", notify: .record)
        case .held:
            break
        }
        defer { releaseLock(in: home) }
        let refresher = refreshing(lockURL(in: home))
        defer { refresher.cancel() }

        if fm.fileExists(atPath: installerLock.path) {
            let age = (try? fm.attributesOfItem(atPath: installerLock.path)[.modificationDate] as? Date)
                .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
            if age < installerLockStaleAfter {
                return Outcome(moved: false, line: "hermes upgrade: another install of Hermes is running (\(installerLock.path) exists, \(Int(age))s old); this one stood aside and touched nothing", notify: .log)
            }
        }

        // The premise, re-read under the lock. The wait for the gateway is tens
        // of seconds and another Moe, or a person, may have refreshed it since.
        let nowStamp = (try? String(contentsOf: stampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if nowStamp != from {
            return Outcome(moved: false,
                           line: "hermes upgrade: \(agent.path) was stamped \(HermesPin.short(from)) and is now "
                                 + "\(nowStamp.map(HermesPin.short) ?? "unreadable") — it moved while Moe was waiting; nothing was done this launch",
                           notify: .log)
        }
        if quitting {
            return Outcome(moved: false, line: "hermes upgrade: Moe is quitting; the installer was not started", notify: .log)
        }

        let started = Date()
        let r = runInstaller(installer, home: home, timeout: installerTimeout, onLine: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("✓") || t.hasPrefix("✗") || t.hasPrefix("›") { onLine?(t) }
        })
        let cancelled = quitting
        let secs = Int(Date().timeIntervalSince(started).rounded())

        let after = (try? String(contentsOf: stampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runnable = fm.isExecutableFile(atPath: hermesBin)
        if r.status == 0, !r.timedOut, !cancelled, after == to, runnable {
            forgetFailure()
            return Outcome(moved: true,
                           line: "hermes upgrade: refreshed the seed at \(agent.path) from \(HermesPin.short(from)) "
                                 + "to \(HermesPin.short(to)) in \(secs)s (.venv untouched)",
                           notify: .always)
        }

        let why: String
        if cancelled { why = "Moe quit while the installer was running, so it was stopped" }
        else if r.timedOut { why = "the installer ran past \(Int(installerTimeout))s and was stopped" }
        else if r.status != 0 { why = "the installer exited \(r.status): \(installerReason(r.output))" }
        else if after != to { why = "the installer finished but the seed is stamped \(after.map(HermesPin.short) ?? "unreadably"), not \(HermesPin.short(to))" }
        else { why = ".venv/bin/hermes is not runnable after the run" }
        if !cancelled { rememberFailure(head: from, pin: to) }
        // The refresh puts back everything it touched before it fails, so the
        // honest thing to report is what the tree says NOW rather than a claim
        // about a rollback this side did not perform.
        let state = after == from
            ? "the seed is still \(HermesPin.short(from)) and \(runnable ? "runnable" : "NOT runnable — CHECK IT")"
            : "CHECK IT: the seed is stamped \(after.map(HermesPin.short) ?? "unreadably") and .venv/bin/hermes is \(runnable ? "runnable" : "not runnable")"
        return Outcome(moved: false,
                       line: "hermes upgrade: FAILED to refresh the seed at \(agent.path) to \(HermesPin.short(to)) — \(why); "
                             + state + " (details: \(Paths.logs.appendingPathComponent("install-hermes.log").path))",
                       notify: after == from ? .once("failed-seed \(from) \(to)", banner: true) : .always)
    }

    static func installerReason(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let cross = lines.last(where: { $0.hasPrefix("✗") }) { return cross }
        return lines.last(where: { !$0.isEmpty }) ?? ""
    }

    // MARK: - The receipt

    enum Notify: Equatable {
        case log
        case record
        case once(String, banner: Bool)
        case always
    }

    @discardableResult
    static func receipt(_ line: String, notify: Notify) -> Bool {
        Log.write(line)
        switch notify {
        case .log:
            return false
        case .record:
            appendReceipt(line)
            return false
        case .once(let key, let banner):
            let said = Paths.logs.appendingPathComponent(saidName)
            let last = (try? String(contentsOf: said, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if last == key { return false }
            appendReceipt(line)
            try? key.write(to: said, atomically: true, encoding: .utf8)
            if banner, !quietBanners { self.banner(line) }
            return banner
        case .always:
            appendReceipt(line)
            if !quietBanners { banner(line) }
            return true
        }
    }

    private static func appendReceipt(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let url = Paths.logs.appendingPathComponent(receiptName)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(NSUserName())  \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(entry.utf8))
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func banner(_ line: String) {
        let body = line.replacingOccurrences(of: "hermes upgrade: ", with: "")
        let clipped = body.count > 230 ? String(body.prefix(227)) + "…" : body
        let escaped = clipped.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = run("/usr/bin/osascript",
                ["-e", "display notification \"\(escaped)\" with title \"Moe: the part that thinks\""],
                timeout: 10)
    }

    static func notify(for decision: HermesUpgradeDecision) -> Notify {
        switch decision {
        case .refused(_, let head, let pin, let reasons, _, _):
            return .once("refused \(head) \(pin) \(reasons.joined(separator: "|"))", banner: true)
        case .notACheckout(_, let seed):
            return .once("seed \(seed ?? "unknown")", banner: false)
        case .seedRefresh:
            return .log
        case .noPin:
            return .once("nopin", banner: true)
        case .ahead(_, let head, let pin):
            return .once("ahead \(head) \(pin)", banner: false)
        case .workbench(_, let head, let pin):
            return .once("workbench \(head) \(pin)", banner: false)
        case .triedAlready(_, let head, let pin, _):
            return .once("tried \(head) \(pin)", banner: false)
        case .noInstaller, .followingTip, .noGit, .absent, .upToDate, .upgrade, .repair:
            return .log
        }
    }

    @discardableResult
    static func record(_ decision: HermesUpgradeDecision) -> Bool {
        receipt(decision.line, notify: notify(for: decision))
    }

    // MARK: - At launch

    private static let queue = DispatchQueue(label: "moe.hermes.upgrade")
    nonisolated(unsafe) private static var running = false

    /// The browser Hermes drives (Chrome for Testing, ~330 MB) is not in the
    /// seed — the download stays its old size — so the first launch puts it
    /// into Hermes's tool store, pinned and sha256-checked by the fork's
    /// pm/lock.json (scripts/fetch-hermes-browser.sh). The seed carries
    /// `tools/.browser-pending` until then, and the browser tools answer
    /// "still downloading its browser" meanwhile. One file check when there is
    /// nothing to do; on failure the marker stays and the next launch retries.
    /// A launch that moves Hermes instead gets it from install-hermes.sh.
    static func fetchBrowserIfPending(home: URL) {
        let marker = home.appendingPathComponent("tools/.browser-pending")
        guard FileManager.default.fileExists(atPath: marker.path), !quitting,
              let script = ScriptRunner.scriptPath("fetch-hermes-browser.sh") else { return }
        Log.write("hermes browser: not in Hermes's tool store yet — fetching the pinned build")
        let run = runInstaller(script, home: home, timeout: 1800,
                               onLine: { Log.write("fetch-hermes-browser: \($0)") })
        Log.write("hermes browser: " + (run.status == 0
            ? "in place"
            : "not yet (exit \(run.status)\(run.timedOut ? ", timed out" : "")); the next launch tries again"))
    }

    /// The commit the tree on disk says it is: the seed's stamp, or a
    /// checkout's HEAD. Nil when it cannot be read.
    static func commitOnDisk(home: URL, isSeed: Bool) -> String? {
        let agent = agentDir(in: home)
        if isSeed {
            if case .notACheckout(let sha) = installed(agentDir: agent) { return sha }
            return nil
        }
        guard let exe = gitExecutable() else { return nil }
        return Git(exe: exe, dir: agent).head()
    }

    /// **Whether the running gateway is now running a tree that is gone.**
    ///
    /// The gateway imports most of Hermes at boot and the rest lazily, per
    /// turn. Once the files under it change, every lazy import reads the new
    /// tree against modules held from the old one, and a name that moved
    /// between them fails every turn: on 2026-10-09 a seed refresh laid down
    /// eb8e427, then the installer's `hermes doctor` exited 1, the run counted
    /// as not moved, nothing reloaded, and every message for a day and a half
    /// answered `cannot import name 'AwakeIdleMeter' from
    /// 'agent.session_activity'`. So the question is not whether the move
    /// *succeeded* but whether the tree is still the one the gateway booted
    /// on — and an unreadable tree is not.
    static func gatewayIsStale(moved: Bool, bootedOn from: String, onDisk now: String?) -> Bool {
        moved || now != from
    }

    static func checkAtLaunch(gatewayUp: @escaping (@escaping (Bool, String) -> Void) -> Void,
                              reload: @escaping (String) -> Void) {
        queue.async {
            guard !running else { return }
            running = true
            let home = hermesHome
            tidy(home: home)
            let decision = decide(home: home)
            let move: (from: String, to: String)?
            var isSeed = false
            switch decision {
            case .upgrade(_, let from, let to): move = (from, to)
            case .repair(_, let head):          move = (head, head)
            case .seedRefresh(_, let from, let to): move = (from, to); isSeed = true
            default:                            move = nil
            }
            guard let move, let installer = installerPath() else {
                record(decision)
                fetchBrowserIfPending(home: home)
                running = false
                return
            }
            Log.write(decision.line + " — once Moe's own gateway is up")
            DispatchQueue.main.async {
                gatewayUp { ok, why in
                    queue.async {
                        guard ok, !quitting else {
                            Log.write("hermes upgrade: not moving Hermes this launch — \(quitting ? "Moe is quitting" : why)")
                            running = false
                            return
                        }
                        let onLine: (String) -> Void = { Log.write("install-hermes: \($0)") }
                        let outcome = isSeed
                            ? performSeedRefresh(home: home, from: move.from, to: move.to, installer: installer, onLine: onLine)
                            : perform(home: home, from: move.from, to: move.to, installer: installer, onLine: onLine)
                        receipt(outcome.line, notify: outcome.notify)
                        let now = commitOnDisk(home: home, isSeed: isSeed)
                        if gatewayIsStale(moved: outcome.moved, bootedOn: move.from, onDisk: now) {
                            let why = outcome.moved
                                ? "Hermes moved to \(HermesPin.short(move.to))"
                                : "the Hermes move failed but left \(now.map(HermesPin.short) ?? "an unreadable tree") on disk, "
                                  + "not the \(HermesPin.short(move.from)) the gateway booted on"
                            if !outcome.moved { Log.write("hermes upgrade: reloading the gateway — " + why) }
                            DispatchQueue.main.async { reload(why) }
                        }
                        running = false
                    }
                }
            }
        }
    }
}
