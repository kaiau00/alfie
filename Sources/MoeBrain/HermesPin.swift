import Foundation

/// **Which Hermes this build of Moe ships, and whether the one on disk may be
/// moved to it.** The decision half of `HermesUpgrade` — pure functions over
/// strings, so the rules can be tested without a git repository, a process,
/// or a Mac that has Hermes on it. The half that runs `git` and the installer
/// is `Sources/Moe/Brain/HermesUpgrade.swift`.
///
/// ## The pin
///
/// `scripts/install-hermes.sh` carries one line naming the exact commit an
/// install gets:
///
///     HERMES_COMMIT="${HERMES_COMMIT-17c7948375602b251d62fe3418767a47c942b818}"
///
/// That line is the only place the pin lives. Moe reads it out of its own
/// copy of the script rather than keeping a second constant in Swift, because
/// two copies of one fact drift, and a pin that drifts is exactly the bug this
/// exists to fix. `linePattern` is anchored to the spelling above and nothing
/// looser; `scripts/test-hermes-upgrade.sh` reads the same line with `sed` and
/// requires the two to agree, so a rewording of the line in the script turns a
/// test red rather than silently making every installed Hermes "up to date".
///
/// `HERMES_COMMIT-}` — an empty default — is the script's documented
/// follow-the-tip mode ("a development convenience and the script says so out
/// loud"). It is not a bug and is not a pin: Moe reports it quietly and moves
/// nothing.
public enum HermesPin {

    /// The exact shape of the line. `[0-9a-f]{40}` because the script itself
    /// refuses anything shorter — a short sha, a tag or a branch would all
    /// "work" and none of them pins anything. The group is optional only so
    /// that the empty default can be told apart from a missing line.
    public static let linePattern = #"^HERMES_COMMIT="\$\{HERMES_COMMIT-([0-9a-f]{40})?\}"[ \t]*$"#

    /// The default fork the script clones. Read for the same reason as the
    /// pin: the checkout's remote has to be *this* repository for a
    /// fast-forward of it to mean anything.
    public static let forkPattern = #"^HERMES_FORK="\$\{HERMES_FORK:-([^"}]+)\}"[ \t]*$"#

    public enum Line: Equatable {
        case pinned(String)
        /// `HERMES_COMMIT="${HERMES_COMMIT-}"`: the script follows the branch tip.
        case followsTip
        /// No line of the shape Moe reads, or more than one.
        case missing
    }

    public static func read(script text: String) -> Line {
        guard let m = single(linePattern, in: text) else { return .missing }
        let ns = text as NSString
        let g = m.range(at: 1)
        return g.location == NSNotFound ? .followsTip : .pinned(ns.substring(with: g))
    }

    /// The pinned sha, or nil for both a missing line and the follow-tip mode.
    public static func parse(script text: String) -> String? {
        if case .pinned(let sha) = read(script: text) { return sha }
        return nil
    }

    public static func forkURL(script text: String) -> String? {
        guard let m = single(forkPattern, in: text) else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    /// The default `HERMES_EXTRAS` the script syncs. The installer's venv
    /// stamp is `"<sha> <HERMES_EXTRAS> <uv --version>"` and its "already in
    /// sync" test compares the WHOLE string, so a health check that compared
    /// the sha alone said "nothing to do" where the installer would re-sync.
    public static let extrasPattern = #"^HERMES_EXTRAS="\$\{HERMES_EXTRAS:-([^"}]+)\}"[ \t]*$"#

    public static func extrasDefault(script text: String) -> String? {
        guard let m = single(extrasPattern, in: text) else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    /// Exactly one match, or nil: two lines would be two truths.
    private static func single(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let matches = re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return matches.count == 1 ? matches[0] : nil
    }

    /// Seven characters, the way `git log --oneline` shows it.
    public static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// Two remote URLs name one repository when they differ only by a
    /// trailing `.git` or `/`.
    public static func sameRepository(_ a: String, _ b: String) -> Bool {
        repositoryKey(a) == repositoryKey(b)
    }

    /// `host/path` with the scheme, user, `.git` and trailing slash gone,
    /// lowercased first so `.GIT` is stripped too — the same repository
    /// however git was told to reach it: `https://github.com/O/r.git`,
    /// `git@github.com:O/r`, `ssh://git@github.com/O/r/`, or a local path.
    public static func repositoryKey(_ url: String) -> String {
        var t = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }          // scheme
        if let slash = t.firstIndex(of: "/"), let at = t[..<slash].lastIndex(of: "@") {
            t = String(t[t.index(after: at)...])                                  // user@ before the host
        } else if !t.hasPrefix("/"), let at = t.firstIndex(of: "@"), !t.contains("/") || t.firstIndex(of: "/")! > at {
            t = String(t[t.index(after: at)...])                                  // git@host:path
        }
        if !t.hasPrefix("/"), let colon = t.firstIndex(of: ":"), !t[..<colon].contains("/") {
            t.replaceSubrange(colon...colon, with: "/")                           // host:path → host/path
        }
        while t.hasSuffix("/") { t.removeLast() }
        if t.hasSuffix(".git") { t.removeLast(4) }
        return t
    }
}

/// Whether a `~/.hermes/hermes-agent` checkout is *pristine* — a plain copy of
/// what `install-hermes.sh` made, that nobody is working in — and therefore
/// Moe's to move.
///
/// ## Why the rule exists
///
/// On the Mac this was written on, `~/.hermes/hermes-agent` is a shared git
/// checkout that several developer sessions work in: dozens of local branches,
/// several attached worktrees, a second remote, and at times uncommitted
/// work (the counts change weekly, so none is quoted here). An upgrade that
/// `git checkout`s over that destroys somebody's afternoon. On a Mac that
/// only ever ran the installer it is a clone on one branch with nothing in it
/// but the installer's own venv, and moving it is safe. The rule has to tell
/// those apart from cheap, local `git` reads — and refuse, in a sentence a
/// developer will understand, when it cannot say "nobody's".
///
/// ## The rule
///
/// A checkout is pristine when **all** of these hold:
///
/// 1. `HEAD` is on the branch the installer tracks (`claude-code-runtime`),
///    not detached and not on any other branch;
/// 2. `git status --porcelain --untracked-files=normal` prints nothing — no
///    modified, staged, deleted *or untracked* files;
/// 3. `git worktree list --porcelain` lists exactly one worktree, the
///    checkout itself;
/// 4. `refs/heads/` holds exactly one branch, the installer's;
/// 5. `git stash list` is empty;
/// 6. no operation is in progress — no `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
///    `REVERT_HEAD`, `BISECT_LOG`, `rebase-merge/` or `rebase-apply/` in the
///    git directory (a clean index does not mean nothing is half-done);
/// 7. there is exactly one remote, `origin`, and it names the fork the
///    installer clones — a clone of some other repository is not this
///    checkout, whatever its branch is called; and the installer would have
///    *added* a `moe-fork` remote to it, which is not "left alone";
/// 8. `HEAD` has not diverged from the pin: when the pin is already in the
///    local object store, one of the two is an ancestor of the other. A
///    diverged checkout has commits of its own; and
/// 9. no ignored or excluded file sits at a path the pin changes. `git merge
///    --ff-only` refuses to overwrite an *untracked* file but silently
///    overwrites an *ignored* one, so a `.git/info/exclude`d file at a path
///    the pin adds would be lost. Checked once the pin is local — which is
///    why `HermesUpgrade.perform` fetches the pin before it decides; and
/// 10. it is a full clone. A shallow clone cannot answer "is the pin an
///    ancestor of HEAD" — its parents are cut off at the boundary — and Moe's
///    own installer never makes one. (Hand-made clones can be, and are: the
///    shared checkout on the Mac this was written on is one.)
///
/// Every failing condition is reported, not just the first: a developer
/// reading the refusal should see the whole picture in one line.
///
/// ## Direction, separately from pristineness
///
/// A pristine checkout that is **ahead** of the pin — the pin is an ancestor
/// of `HEAD` — is never moved. `hermes update` is a `git pull`; a developer's
/// own pull leaves the same shape; and a Moe built from a worktree behind
/// `main` carries an older pin. Moving such a checkout *back* would be the
/// 2026-09-03 "their app kept going backwards" incident, ported to Hermes,
/// with a gateway restart each time. Only a checkout **behind** the pin, or
/// one whose relation cannot yet be told because the pin is not fetched, goes
/// to the installer — which fetches and then refuses anything that is not a
/// plain fast-forward. `Ancestry` carries the answer; the verdict reports
/// `.diverged` as a reason and leaves `.ahead` to the decision.
public enum HermesCheckout {

    /// The branch `install-hermes.sh` clones and fast-forwards.
    public static let branch = "claude-code-runtime"

    /// The default fork, when the installer script cannot be read for it.
    public static let defaultFork = "https://github.com/Izzy-Gottz/hermes-agent"

    /// The state files that mean "an operation is half done". Paths relative
    /// to the git directory; the app checks which exist.
    public static let inProgressMarkers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
                                           "rebase-merge", "rebase-apply"]

    public enum Ancestry: Equatable {
        /// HEAD is an ancestor of the pin: the ordinary update.
        case behind
        /// The pin is an ancestor of HEAD: this checkout has moved on.
        case ahead
        /// Neither contains the other.
        case diverged
        /// The pin is not in the local object store; the installer's fetch
        /// will be the first to know.
        case unknown
    }

    /// The raw output of the reads, exactly as git printed them, plus the
    /// three facts that are not a single command's output.
    public struct GitFacts: Equatable {
        /// `git symbolic-ref -q HEAD` — `refs/heads/<branch>`, or empty when
        /// HEAD is detached (the command exits 1 and prints nothing).
        public var symbolicRef: String
        /// `git status --porcelain --untracked-files=normal`.
        public var status: String
        /// `git worktree list --porcelain`.
        public var worktrees: String
        /// `git for-each-ref refs/heads --format=%(refname:short)`.
        public var branches: String
        /// `git stash list`.
        public var stash: String
        /// `git remote -v`.
        public var remotes: String
        /// Which of `inProgressMarkers` exist in the git directory.
        public var inProgress: [String]
        /// HEAD against the pin.
        public var ancestry: Ancestry
        /// Ignored/excluded files at paths the pin changes, when the pin is
        /// local; empty otherwise.
        public var overwritten: [String]
        /// `.git/shallow` exists.
        public var shallow: Bool

        public init(symbolicRef: String, status: String, worktrees: String, branches: String, stash: String,
                    remotes: String = "origin\t\(HermesCheckout.defaultFork) (fetch)\norigin\t\(HermesCheckout.defaultFork) (push)\n",
                    inProgress: [String] = [], ancestry: Ancestry = .unknown, overwritten: [String] = [],
                    shallow: Bool = false) {
            self.symbolicRef = symbolicRef
            self.status = status
            self.worktrees = worktrees
            self.branches = branches
            self.stash = stash
            self.remotes = remotes
            self.inProgress = inProgress
            self.ancestry = ancestry
            self.overwritten = overwritten
            self.shallow = shallow
        }
    }

    public struct Verdict: Equatable {
        public let pristine: Bool
        /// Why not, one clause per failing condition. Empty when pristine.
        public let reasons: [String]
    }

    /// The remote whose fetch URL is the fork, from `git remote -v` — the one
    /// a by-hand `git fetch` has to name. On the Mac this was written on,
    /// `origin` is NousResearch and the fork is called `fork`; a refusal that
    /// said `git fetch && merge` would have fetched the wrong repository.
    public static func remoteNamingFork(in remotes: String, fork: String = defaultFork) -> String? {
        for (name, url) in fetchURLs(remotes) where HermesPin.sameRepository(url, fork) { return name }
        return nil
    }

    /// `git remote -v` is `name<TAB>url (fetch|push)`. Split on the tab and
    /// the trailing kind, never on spaces: a URL can contain one.
    public static func fetchURLs(_ remotes: String) -> [(name: String, url: String)] {
        var out: [(String, String)] = []
        for line in lines(remotes) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[..<tab])
            var rest = String(line[line.index(after: tab)...])
            if rest.hasSuffix(" (push)") { continue }
            if rest.hasSuffix(" (fetch)") { rest.removeLast(" (fetch)".count) }
            out.append((name, rest.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    public static func verdict(_ f: GitFacts, branch: String = branch, fork: String = defaultFork) -> Verdict {
        var reasons: [String] = []

        // 1. on the installer's branch
        let ref = f.symbolicRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.isEmpty {
            reasons.append("HEAD is detached")
        } else if ref != "refs/heads/\(branch)" {
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            reasons.append("it is on branch '\(name)', not '\(branch)'")
        }

        // 2. clean, untracked files included
        let changes = lines(f.status)
        if !changes.isEmpty {
            reasons.append("\(changes.count) uncommitted change\(changes.count == 1 ? "" : "s") (git status is not clean)")
        }

        // 3. one worktree — the checkout itself
        let paths = lines(f.worktrees).filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
        if paths.count > 1 {
            let others = Array(paths.dropFirst())
            reasons.append("\(others.count) other worktree\(others.count == 1 ? "" : "s") attached: "
                           + others.prefix(3).joined(separator: ", ") + (others.count > 3 ? ", …" : ""))
        }

        // 4. one branch — the installer's
        let heads = lines(f.branches)
        let otherHeads = heads.filter { $0 != branch }
        if !otherHeads.isEmpty {
            reasons.append("\(otherHeads.count) other local branch\(otherHeads.count == 1 ? "" : "es"): "
                           + otherHeads.prefix(3).joined(separator: ", ") + (otherHeads.count > 3 ? ", …" : ""))
        }

        // 5. nothing stashed
        let stashed = lines(f.stash)
        if !stashed.isEmpty {
            reasons.append("\(stashed.count) stash entr\(stashed.count == 1 ? "y" : "ies")")
        }

        // 6. nothing half-done
        if !f.inProgress.isEmpty {
            reasons.append("an operation is in progress (\(f.inProgress.joined(separator: ", ")) in .git)")
        }

        // 7. one remote, origin, the fork
        let urls = fetchURLs(f.remotes)
        let names = urls.map(\.name).sorted()
        if names.isEmpty {
            reasons.append("it has no remote")
        } else if names != ["origin"] {
            reasons.append("its remotes are \(names.joined(separator: ", ")), not just origin")
        } else if let url = urls.first(where: { $0.name == "origin" })?.url, !HermesPin.sameRepository(url, fork) {
            reasons.append("origin is \(url), not \(fork)")
        }

        // 10. a full clone. Moe's installer never makes a shallow one, and a
        // shallow clone cannot answer "is the pin an ancestor of HEAD" — its
        // parents are cut off at the boundary — so nothing below could be
        // decided honestly.
        if f.shallow {
            reasons.append("it is a shallow clone (.git/shallow), which Moe's own installer never makes")
        }

        // 8. not diverged
        if f.ancestry == .diverged {
            reasons.append("it has diverged from the pin (neither is an ancestor of the other)")
        }

        // 9. nothing ignored where the pin writes
        if !f.overwritten.isEmpty {
            reasons.append("\(f.overwritten.count) ignored file\(f.overwritten.count == 1 ? "" : "s") the fast-forward would overwrite: "
                           + f.overwritten.prefix(3).joined(separator: ", ") + (f.overwritten.count > 3 ? ", …" : ""))
        }

        return Verdict(pristine: reasons.isEmpty, reasons: reasons)
    }

    private static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Whether the launch-time move may start, given where the gateway stands.
///
/// `HermesSupervisor.whenReady` answers with *any* terminal state: ready,
/// failed, or "Moe is shutting down". Only one of those means "a gateway of
/// Moe's own is up and has finished reading the tree": `.ready(owned: true)`.
/// An adopted gateway is not Moe's to restart, so moving the tree under it
/// would leave it running old code with no way to fix that; a failed one
/// gives `reload` nothing to restart, contradicting "restarts the thinking
/// part once"; and shutting down means the installer would run as an orphan
/// with nobody to roll it back.
public enum HermesUpgradeGate {
    public static func mayRun(ready: Bool, owned: Bool, shuttingDown: Bool) -> Bool {
        ready && owned && !shuttingDown
    }
}

/// What Moe decided about the Hermes on disk, and the one sentence it logs.
///
/// Every case carries what a reader of the log needs to act: the path, the
/// commits, and — for a refusal — the reasons and the command that would do
/// it by hand. The sentences are here rather than at the call sites so the
/// same words reach `moe.log`, the receipt file and the `--hermes-upgrade`
/// CLI, and so a test can hold them to account.
public enum HermesUpgradeDecision: Equatable {
    /// Moe cannot find its own copy of `install-hermes.sh`.
    case noInstaller
    /// The installer exists but its pin line is not the shape Moe reads.
    case noPin(installer: String)
    /// `HERMES_COMMIT-}`: the script follows the branch tip. Documented,
    /// development-only, and not a pin to move anything to.
    case followingTip(installer: String)
    /// No `git` this Mac can run without a "install the developer tools?"
    /// dialog. Reached both for a checkout, which cannot be read without one,
    /// and for a stamped seed, whose refresh needs one to reach the fork —
    /// and popping that dialog in the middle of a launch is worse than
    /// waiting for the next one.
    case noGit(agentDir: String)
    /// Nothing at the path. Onboarding installs it; this does not.
    case absent(agentDir: String)
    /// A directory with no `.git` and **no readable stamp** — a hand-made
    /// tree, or a seed from before `.moe-seed-commit` existed. Nothing can say
    /// which Hermes it is, so nothing can safely move it.
    ///
    /// A *stamped* seed is `.seedRefresh` and is no longer this case: from
    /// 0.3.13 it is the normal shape on a downloaded Mac, and reporting the
    /// normal shape as "Moe cannot move it" is how a pin bump reached nobody.
    case notACheckout(agentDir: String, seedCommit: String?)
    /// A seed laid down from inside Memoe.app, stamped `from`, while this build
    /// pins `to`. `scripts/refresh-hermes-seed.sh` moves the tracked source
    /// the two commits differ in and leaves `.venv` alone.
    case seedRefresh(agentDir: String, from: String, to: String)
    case upToDate(head: String)
    /// At the pin, but `.venv/bin/hermes` is not runnable — a run that was
    /// killed between the fast-forward and the sync. The installer repairs
    /// it, the same way as a move.
    case repair(agentDir: String, head: String)
    /// `remote` is the one whose URL is the fork (`HermesCheckout.remoteNamingFork`),
    /// so the by-hand command fetches the right repository; nil when none
    /// does, in which case the command is to add one. `fork` is that URL.
    case refused(agentDir: String, head: String, pin: String, reasons: [String], remote: String?, fork: String)
    /// Pristine, but the pin is an ancestor of HEAD. Never moved back.
    case ahead(agentDir: String, head: String, pin: String)
    /// Pristine and behind, but this is Moe Dev, which never moves the
    /// Hermes the real Moe owns.
    case workbench(agentDir: String, head: String, pin: String)
    /// Pristine and behind, but the same move failed before and neither end
    /// has changed since. Not retried until one does.
    case triedAlready(agentDir: String, head: String, pin: String, when: String)
    case upgrade(agentDir: String, from: String, to: String)

    public var line: String {
        switch self {
        case .noInstaller:
            return "hermes upgrade: Moe cannot find its own install-hermes.sh, so it does not know "
                 + "which Hermes this build ships; nothing is moved"
        case .noPin(let installer):
            return "hermes upgrade: \(installer) has no HERMES_COMMIT line of the shape Moe reads "
                 + "(HermesPin.linePattern) — the pin is unknown, so nothing is moved. That is a bug "
                 + "in one of the two, and scripts/test-hermes-upgrade.sh should be red"
        case .followingTip(let installer):
            return "hermes upgrade: \(installer) follows the branch tip (HERMES_COMMIT is empty) — "
                 + "a development mode with no pin to move to; nothing is moved"
        case .noGit(let dir):
            return "hermes upgrade: no git on this Mac that Moe can run without a dialog; "
                 + "\(dir) is left alone"
        case .absent(let dir):
            return "hermes upgrade: no Hermes at \(dir); nothing to move (onboarding installs it)"
        case .notACheckout(let dir, let seed):
            let origin = seed.map { "laid down from the seed inside Memoe.app at \(HermesPin.short($0))" }
                ?? "with no seed stamp either, so its commit is unknown"
            return "hermes upgrade: \(dir) is not a git checkout (\(origin)); Moe cannot "
                 + "fast-forward it and leaves it alone"
        case .seedRefresh(let dir, let from, let to):
            return "hermes upgrade: \(dir) is a seed at \(HermesPin.short(from)) and this Moe pins "
                 + "\(HermesPin.short(to)); refreshing the source that commit covers, leaving .venv alone"
        case .upToDate(let head):
            return "hermes upgrade: Hermes is at the pinned \(HermesPin.short(head)); nothing to do"
        case .repair(let dir, let head):
            return "hermes upgrade: \(dir) is at the pinned \(HermesPin.short(head)) but .venv/bin/hermes "
                 + "is not runnable — a run was stopped between the fast-forward and the sync; "
                 + "re-running the installer to repair it"
        case .refused(let dir, let head, let pin, let reasons, let remote, let fork):
            let byHand: String
            if head == pin {
                // Nothing to fetch or merge: the checkout is at the pin and
                // the venv beside it is what is wrong.
                byHand = "rebuild its venv yourself: re-run scripts/install-hermes.sh, or `uv sync --locked` in \(dir)"
            } else if let remote {
                byHand = "git -C \(dir) fetch \(remote) && git -C \(dir) merge --ff-only \(pin)"
            } else {
                byHand = "no remote here names the fork; add one first: git -C \(dir) remote add fork \(fork), "
                       + "then git -C \(dir) fetch fork && git -C \(dir) merge --ff-only \(pin)"
            }
            return "hermes upgrade: not moving \(dir) from \(HermesPin.short(head)) to "
                 + "\(HermesPin.short(pin)) — it is not a pristine checkout: "
                 + reasons.joined(separator: "; ")
                 + ". Somebody works in it, so it is theirs to move (\(byHand))"
        case .ahead(let dir, let head, let pin):
            return "hermes upgrade: \(dir) is at \(HermesPin.short(head)), ahead of the pinned "
                 + "\(HermesPin.short(pin)); Moe never moves a checkout back, so it is left where it is"
        case .workbench(let dir, let head, let pin):
            return "hermes upgrade: this is Moe Dev, which never moves \(dir) (at "
                 + "\(HermesPin.short(head)); this build pins \(HermesPin.short(pin))) — the real Moe owns it"
        case .triedAlready(let dir, let head, let pin, let when):
            return "hermes upgrade: moving \(dir) from \(HermesPin.short(head)) to \(HermesPin.short(pin)) "
                 + "failed at \(when) and neither has changed since; not retrying for a day "
                 + "(details in hermes-upgrades.log; delete hermes-upgrade.tried beside it to retry now)"
        case .upgrade(let dir, let from, let to):
            return "hermes upgrade: \(dir) is at \(HermesPin.short(from)) and this Moe pins "
                 + "\(HermesPin.short(to)); moving it"
        }
    }

    /// For the CLI. 0 is "nothing wrong", and everything else names a state a
    /// script can branch on.
    public var exitCode: Int32 {
        switch self {
        case .upToDate, .upgrade, .followingTip, .repair, .seedRefresh: return 0
        case .refused:                           return 3
        case .absent, .notACheckout:             return 4
        case .noInstaller, .noPin, .noGit:       return 5
        case .ahead:                             return 6
        case .workbench:                         return 7
        case .triedAlready:                      return 8
        }
    }
}
