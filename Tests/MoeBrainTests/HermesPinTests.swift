import Foundation
import Testing
@testable import MoeBrain

/// The pin line, read the way Moe reads it — and the ways a rewording of the
/// script would have to be noticed.
struct HermesPinTests {

    static let sha = "17c7948375602b251d62fe3418767a47c942b818"

    @Test func readsTheLineAsTheScriptSpellsIt() {
        let script = """
        HERMES_BRANCH="${HERMES_BRANCH:-claude-code-runtime}"
        # a comment mentioning HERMES_COMMIT="${HERMES_COMMIT-deadbeef}" is not the line
        HERMES_COMMIT="${HERMES_COMMIT-\(Self.sha)}"
        HERMES_EXTRAS="${HERMES_EXTRAS:-mcp anthropic messaging edge-tts}"
        """
        #expect(HermesPin.parse(script: script) == Self.sha)
        #expect(HermesPin.read(script: script) == .pinned(Self.sha))
    }

    @Test func aShortShaIsNotAPin() {
        let script = "HERMES_COMMIT=\"${HERMES_COMMIT-17c7948}\"\n"
        #expect(HermesPin.parse(script: script) == nil, "the script itself refuses fewer than 40 characters")
        #expect(HermesPin.read(script: script) == .missing)
    }

    @Test func anEmptyDefaultIsTheFollowTipModeNotAPinAndNotABug() {
        let script = "HERMES_COMMIT=\"${HERMES_COMMIT-}\"\n"
        #expect(HermesPin.parse(script: script) == nil)
        #expect(HermesPin.read(script: script) == .followsTip)
    }

    @Test func aRewordedLineIsNotRead() {
        // The `:-` form, an unquoted form, an indented form: each is a
        // plausible edit to the script, and each must come back as "no pin"
        // — because "no pin" refuses to move anything, and a wrong pin moves
        // everything to the wrong place.
        #expect(HermesPin.read(script: "HERMES_COMMIT=\"${HERMES_COMMIT:-\(Self.sha)}\"\n") == .missing)
        #expect(HermesPin.read(script: "HERMES_COMMIT=${HERMES_COMMIT-\(Self.sha)}\n") == .missing)
        #expect(HermesPin.read(script: "  HERMES_COMMIT=\"${HERMES_COMMIT-\(Self.sha)}\"\n") == .missing)
        #expect(HermesPin.read(script: "HERMES_COMMIT=\"\(Self.sha)\"\n") == .missing)
    }

    @Test func twoLinesAreTwoTruthsAndNeitherIsChosen() {
        let other = "1e985f50ed5a2c56cb1a4a654adc9003053f1d73"
        let script = "HERMES_COMMIT=\"${HERMES_COMMIT-\(Self.sha)}\"\nHERMES_COMMIT=\"${HERMES_COMMIT-\(other)}\"\n"
        #expect(HermesPin.read(script: script) == .missing)
    }

    @Test func trailingWhitespaceIsTolerated() {
        #expect(HermesPin.parse(script: "HERMES_COMMIT=\"${HERMES_COMMIT-\(Self.sha)}\"  \n") == Self.sha)
    }

    @Test func theForkIsReadFromTheScriptToo() {
        let script = "HERMES_FORK=\"${HERMES_FORK:-https://github.com/Izzy-Gottz/hermes-agent}\"\nHERMES_BRANCH=\"${HERMES_BRANCH:-claude-code-runtime}\"\n"
        #expect(HermesPin.forkURL(script: script) == "https://github.com/Izzy-Gottz/hermes-agent")
        #expect(HermesPin.forkURL(script: "HERMES_FORK=x\n") == nil)
    }

    @Test func aTrailingDotGitNamesTheSameRepository() {
        #expect(HermesPin.sameRepository("https://github.com/Izzy-Gottz/hermes-agent.git", "https://github.com/Izzy-Gottz/hermes-agent"))
        #expect(HermesPin.sameRepository("/tmp/fork.git/", "/tmp/fork.git"))
        #expect(!HermesPin.sameRepository("https://github.com/NousResearch/hermes-agent.git", "https://github.com/Izzy-Gottz/hermes-agent"))
    }

    @Test func sshAndHttpsSpellingsOfOneRepositoryAreTheSame() {
        let https = "https://github.com/Izzy-Gottz/hermes-agent"
        #expect(HermesPin.sameRepository("git@github.com:Izzy-Gottz/hermes-agent.git", https))
        #expect(HermesPin.sameRepository("ssh://git@github.com/Izzy-Gottz/hermes-agent/", https))
        #expect(HermesPin.sameRepository("https://user@github.com/Izzy-Gottz/hermes-agent.GIT", https), ".GIT is stripped after lowercasing")
        #expect(HermesPin.repositoryKey("git@github.com:Izzy-Gottz/hermes-agent.git") == "github.com/izzy-gottz/hermes-agent")
        #expect(!HermesPin.sameRepository("git@github.com:NousResearch/hermes-agent.git", https))
        #expect(HermesPin.sameRepository("/Users/x/my fork/hermes.git", "/Users/x/my fork/hermes"), "a local path with a space")
    }

    @Test func remoteListingIsSplitOnTheTabNotOnSpaces() {
        let remotes = "origin\t/Users/x/my fork/hermes.git (fetch)\norigin\t/Users/x/my fork/hermes.git (push)\n"
        let urls = HermesCheckout.fetchURLs(remotes)
        #expect(urls.count == 1)
        #expect(urls.first?.url == "/Users/x/my fork/hermes.git")
        #expect(HermesCheckout.remoteNamingFork(in: remotes, fork: "/Users/x/my fork/hermes") == "origin")
    }
}

/// The pristine rule, condition by condition. Each test breaks exactly one
/// thing, so a rule that stopped looking at that thing goes red here and
/// nowhere else.
struct HermesCheckoutTests {

    static let clean = HermesCheckout.GitFacts(
        symbolicRef: "refs/heads/claude-code-runtime\n",
        status: "",
        worktrees: "worktree /Users/x/.hermes/hermes-agent\nHEAD 1e985f50ed5a2c56cb1a4a654adc9003053f1d73\nbranch refs/heads/claude-code-runtime\n\n",
        branches: "claude-code-runtime\n",
        stash: "",
        ancestry: .behind)

    @Test func aFreshInstallIsPristine() {
        let v = HermesCheckout.verdict(Self.clean)
        #expect(v.pristine)
        #expect(v.reasons.isEmpty)
    }

    @Test func detachedHeadIsRefused() {
        var f = Self.clean; f.symbolicRef = ""
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["HEAD is detached"])
    }

    @Test func anotherBranchCheckedOutIsRefusedByName() {
        var f = Self.clean
        f.symbolicRef = "refs/heads/relay-inbound-seal\n"
        f.branches = "claude-code-runtime\nrelay-inbound-seal\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons.count == 2)
        #expect(v.reasons[0] == "it is on branch 'relay-inbound-seal', not 'claude-code-runtime'")
        #expect(v.reasons[1] == "1 other local branch: relay-inbound-seal")
    }

    @Test func anUntrackedFileIsNotClean() {
        var f = Self.clean; f.status = "?? scratch.py\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["1 uncommitted change (git status is not clean)"])
    }

    @Test func modifiedFilesAreCounted() {
        var f = Self.clean; f.status = " M agent/x.py\nM  agent/y.py\nD  gone.py\n"
        let v = HermesCheckout.verdict(f)
        #expect(v.reasons == ["3 uncommitted changes (git status is not clean)"])
    }

    @Test func anAttachedWorktreeIsRefusedWithItsPath() {
        var f = Self.clean
        f.worktrees = Self.clean.worktrees
            + "worktree /Users/x/hermes-speed\nHEAD 52cbd5c2001234567890abcdef1234567890abcd\nbranch refs/heads/computer-use-browser\n\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["1 other worktree attached: /Users/x/hermes-speed"])
    }

    @Test func manyWorktreesAreSummarised() {
        var f = Self.clean
        var text = Self.clean.worktrees
        for i in 1...5 { text += "worktree /tmp/wt\(i)\nHEAD 0000000000000000000000000000000000000000\ndetached\n\n" }
        f.worktrees = text
        let v = HermesCheckout.verdict(f)
        #expect(v.reasons == ["5 other worktrees attached: /tmp/wt1, /tmp/wt2, /tmp/wt3, …"])
    }

    @Test func extraLocalBranchesAreRefused() {
        var f = Self.clean; f.branches = "agent-cache\nclaude-code-runtime\nmain\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["2 other local branches: agent-cache, main"])
    }

    @Test func aStashIsSomebodysWork() {
        var f = Self.clean; f.stash = "stash@{0}: WIP on claude-code-runtime: 1e985f5 tidy\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["1 stash entry"])
    }

    @Test func aHalfDoneMergeIsRefusedEvenWithACleanIndex() {
        var f = Self.clean; f.inProgress = ["MERGE_HEAD"]
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["an operation is in progress (MERGE_HEAD in .git)"])
        f.inProgress = ["rebase-merge", "REVERT_HEAD"]
        #expect(HermesCheckout.verdict(f).reasons == ["an operation is in progress (rebase-merge, REVERT_HEAD in .git)"])
    }

    @Test func aCloneOfAnotherRepositoryIsNotThisCheckout() {
        var f = Self.clean
        f.remotes = "origin\thttps://github.com/NousResearch/hermes-agent.git (fetch)\norigin\thttps://github.com/NousResearch/hermes-agent.git (push)\n"
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["origin is https://github.com/NousResearch/hermes-agent.git, not https://github.com/Izzy-Gottz/hermes-agent"])
    }

    @Test func aSecondRemoteIsADevelopersAndNoRemoteIsNobodys() {
        var f = Self.clean
        f.remotes = Self.clean.remotes + "upstream\thttps://github.com/NousResearch/hermes-agent (fetch)\nupstream\thttps://github.com/NousResearch/hermes-agent (push)\n"
        #expect(HermesCheckout.verdict(f).reasons == ["its remotes are origin, upstream, not just origin"])
        f.remotes = ""
        #expect(HermesCheckout.verdict(f).reasons == ["it has no remote"])
        // A `fork`-named remote — the hand-made install's — is not `origin`.
        f.remotes = "fork\thttps://github.com/Izzy-Gottz/hermes-agent.git (fetch)\nfork\thttps://github.com/Izzy-Gottz/hermes-agent.git (push)\n"
        #expect(HermesCheckout.verdict(f).reasons == ["its remotes are fork, not just origin"])
    }

    @Test func theForksDotGitSpellingIsTheFork() {
        var f = Self.clean
        f.remotes = "origin\thttps://github.com/Izzy-Gottz/hermes-agent.git (fetch)\norigin\thttps://github.com/Izzy-Gottz/hermes-agent.git (push)\n"
        #expect(HermesCheckout.verdict(f).pristine)
        // And the fork itself can be given with or without it.
        #expect(HermesCheckout.verdict(Self.clean, fork: "https://github.com/Izzy-Gottz/hermes-agent.git").pristine)
    }

    @Test func divergedIsARefusalAheadIsNot() {
        var f = Self.clean; f.ancestry = .diverged
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["it has diverged from the pin (neither is an ancestor of the other)"])
        // Ahead is pristine — it is the DECISION that declines to move it back.
        f.ancestry = .ahead
        #expect(HermesCheckout.verdict(f).pristine)
        f.ancestry = .unknown
        #expect(HermesCheckout.verdict(f).pristine)
    }

    @Test func aShallowCloneIsRefusedBecauseDirectionCannotBeRead() {
        var f = Self.clean; f.shallow = true
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["it is a shallow clone (.git/shallow), which Moe's own installer never makes"])
    }

    @Test func theExtrasDefaultIsReadFromTheScriptForTheWholeStampComparison() {
        let script = "HERMES_EXTRAS=\"${HERMES_EXTRAS:-mcp anthropic messaging edge-tts}\"\nPYTHON_VERSION=\"3.11\"\n"
        #expect(HermesPin.extrasDefault(script: script) == "mcp anthropic messaging edge-tts")
        #expect(HermesPin.extrasDefault(script: "HERMES_EXTRAS=x\n") == nil)
    }

    @Test func anIgnoredFileWhereThePinWritesIsRefused() {
        var f = Self.clean; f.overwritten = ["agent/local_notes.py"]
        let v = HermesCheckout.verdict(f)
        #expect(!v.pristine)
        #expect(v.reasons == ["1 ignored file the fast-forward would overwrite: agent/local_notes.py"])
    }

    @Test func everyFailingConditionIsReportedNotJustTheFirst() {
        // The real shared checkout on the Mac this was written on, in
        // miniature: on the right branch and clean, but with worktrees,
        // branches and a stash. A developer must see all three.
        var f = Self.clean
        f.worktrees = Self.clean.worktrees + "worktree /tmp/forkseal\nHEAD 17c7948375602b251d62fe3418767a47c942b818\nbranch refs/heads/relay-inbound-seal\n\n"
        f.branches = "claude-code-runtime\nmain\nrelay-inbound-seal\n"
        f.stash = "stash@{0}: x\nstash@{1}: y\n"
        let v = HermesCheckout.verdict(f)
        #expect(v.reasons.count == 3)
        #expect(v.reasons[0].hasPrefix("1 other worktree attached"))
        #expect(v.reasons[1].hasPrefix("2 other local branches"))
        #expect(v.reasons[2] == "2 stash entries")
    }

    @Test func aDifferentInstallerBranchIsHonoured() {
        var f = Self.clean
        f.symbolicRef = "refs/heads/main\n"; f.branches = "main\n"
        #expect(HermesCheckout.verdict(f, branch: "main").pristine)
        #expect(!HermesCheckout.verdict(f).pristine)
    }
}

/// When the launch-time move may start.
struct HermesUpgradeGateTests {
    @Test func onlyAnOwnedGatewayThatIsUpLetsTheMoveRun() {
        #expect(HermesUpgradeGate.mayRun(ready: true, owned: true, shuttingDown: false))
        #expect(!HermesUpgradeGate.mayRun(ready: true, owned: false, shuttingDown: false), "adopted: not Moe's to restart")
        #expect(!HermesUpgradeGate.mayRun(ready: false, owned: true, shuttingDown: false), "failed: nothing to restart")
        #expect(!HermesUpgradeGate.mayRun(ready: true, owned: true, shuttingDown: true), "quitting: an orphan installer")
        #expect(!HermesUpgradeGate.mayRun(ready: false, owned: false, shuttingDown: true))
    }
}

/// The sentences a person reads, held to what they must contain.
struct HermesUpgradeDecisionTests {
    static let dir = "/Users/x/.hermes/hermes-agent"
    static let head = "1e985f50ed5a2c56cb1a4a654adc9003053f1d73"
    static let pin = "17c7948375602b251d62fe3418767a47c942b818"

    @Test func aRefusalNamesTheReasonsAndTheCommandToDoItByHand() {
        let d = HermesUpgradeDecision.refused(agentDir: Self.dir, head: Self.head, pin: Self.pin,
                                              reasons: ["HEAD is detached", "1 stash entry"], remote: "origin",
                                              fork: HermesCheckout.defaultFork)
        #expect(d.line.contains("not moving \(Self.dir) from 1e985f5 to 17c7948"))
        #expect(d.line.contains("HEAD is detached; 1 stash entry"))
        #expect(d.line.contains("git -C \(Self.dir) fetch origin && git -C \(Self.dir) merge --ff-only \(Self.pin)"))
        #expect(d.exitCode == 3)
    }

    @Test func theByHandCommandNamesTheRemoteThatIsTheFork() {
        // The real ~/.hermes/hermes-agent: origin is NousResearch, the fork is `fork`.
        let remotes = "fork\thttps://github.com/Izzy-Gottz/hermes-agent.git (fetch)\nfork\thttps://github.com/Izzy-Gottz/hermes-agent.git (push)\n"
                    + "origin\thttps://github.com/NousResearch/hermes-agent.git (fetch)\norigin\thttps://github.com/NousResearch/hermes-agent.git (push)\n"
        #expect(HermesCheckout.remoteNamingFork(in: remotes) == "fork")
        #expect(HermesCheckout.remoteNamingFork(in: "origin\thttps://example.com/x (fetch)\n") == nil)
        let d = HermesUpgradeDecision.refused(agentDir: Self.dir, head: Self.head, pin: Self.pin,
                                              reasons: ["its remotes are fork, origin, not just origin"], remote: "fork",
                                              fork: HermesCheckout.defaultFork)
        #expect(d.line.contains("git -C \(Self.dir) fetch fork &&"))
    }

    @Test func noRemoteNamingTheForkSaysHowToAddOneInsteadOfFetchingTheWrongRepository() {
        let d = HermesUpgradeDecision.refused(agentDir: Self.dir, head: Self.head, pin: Self.pin,
                                              reasons: ["origin is https://example.com/x, not \(HermesCheckout.defaultFork)"],
                                              remote: nil, fork: HermesCheckout.defaultFork)
        #expect(d.line.contains("no remote here names the fork; add one first: git -C \(Self.dir) remote add fork \(HermesCheckout.defaultFork)"))
        #expect(!d.line.contains("fetch origin"))
    }

    @Test func aRefusalAtThePinTalksAboutTheVenvNotAboutFetching() {
        let d = HermesUpgradeDecision.refused(agentDir: Self.dir, head: Self.pin, pin: Self.pin,
                                              reasons: ["1 uncommitted change (git status is not clean)"],
                                              remote: "origin", fork: HermesCheckout.defaultFork)
        #expect(d.line.contains("rebuild its venv yourself: re-run scripts/install-hermes.sh"))
        #expect(!d.line.contains("merge --ff-only"))
    }

    @Test func atThePinWithNoRunnableHermesIsARepairNotUpToDate() {
        let d = HermesUpgradeDecision.repair(agentDir: Self.dir, head: Self.pin)
        #expect(d.line.contains("at the pinned 17c7948 but .venv/bin/hermes is not runnable"))
        #expect(d.line.contains("re-running the installer"))
        #expect(!d.line.contains("nothing to do"))
        #expect(d.exitCode == 0)
    }

    @Test func aSeedCopyIsNamedAsSuchAndNeverCalledUpToDate() {
        let stamped = HermesUpgradeDecision.notACheckout(agentDir: Self.dir, seedCommit: Self.head)
        #expect(stamped.line.contains("not a git checkout"))
        #expect(stamped.line.contains("seed inside Memoe.app at 1e985f5"))
        #expect(!stamped.line.contains("nothing to do"))
        let unstamped = HermesUpgradeDecision.notACheckout(agentDir: Self.dir, seedCommit: nil)
        #expect(unstamped.line.contains("its commit is unknown"))
        #expect(stamped.exitCode == 4 && unstamped.exitCode == 4)
    }

    /// A stamped seed is a move to make, and the sentence has to carry the two
    /// commits and the boundary. Before this it read "Moe cannot fast-forward
    /// it and leaves it alone", which was true of git and false of the
    /// question anyone was asking — and it is why a pin bump reached nobody who
    /// already had Moe.
    @Test func aStampedSeedIsAMoveToMakeAndSaysWhatItWillNotTouch() {
        let d = HermesUpgradeDecision.seedRefresh(agentDir: Self.dir, from: Self.head, to: Self.pin)
        #expect(d.line.contains("is a seed at 1e985f5"))
        #expect(d.line.contains("pins 17c7948"))
        #expect(d.line.contains("leaving .venv alone"))
        #expect(!d.line.contains("cannot"))
        #expect(!d.line.contains("leaves it alone"))
        #expect(d.exitCode == 0)
        // And it is a different sentence from the one for a tree nothing can
        // identify — the two must never be confusable, because the stamp is
        // the whole difference between "move it" and "do not touch it".
        let unstamped = HermesUpgradeDecision.notACheckout(agentDir: Self.dir, seedCommit: nil)
        #expect(d.line != unstamped.line)
        #expect(d.exitCode != unstamped.exitCode)
    }

    @Test func aheadIsNeverMovedBackAndSaysSo() {
        let d = HermesUpgradeDecision.ahead(agentDir: Self.dir, head: Self.head, pin: Self.pin)
        #expect(d.line.contains("ahead of the pinned 17c7948"))
        #expect(d.line.contains("never moves a checkout back"))
        #expect(!d.line.contains("moving it"))
        #expect(d.exitCode == 6)
    }

    @Test func theWorkbenchNamesItselfAndTheOwner() {
        let d = HermesUpgradeDecision.workbench(agentDir: Self.dir, head: Self.head, pin: Self.pin)
        #expect(d.line.contains("this is Moe Dev, which never moves"))
        #expect(d.line.contains("the real Moe owns it"))
        #expect(d.exitCode == 7)
    }

    @Test func triedAlreadySaysWhenAndHowToRetry() {
        let d = HermesUpgradeDecision.triedAlready(agentDir: Self.dir, head: Self.head, pin: Self.pin, when: "2026-09-06T22:10:00Z")
        #expect(d.line.contains("failed at 2026-09-06T22:10:00Z"))
        #expect(d.line.contains("hermes-upgrade.tried"))
        #expect(d.exitCode == 8)
    }

    @Test func followingTheTipIsQuietAndNotABug() {
        let d = HermesUpgradeDecision.followingTip(installer: "/x/install-hermes.sh")
        #expect(d.line.contains("follows the branch tip"))
        #expect(!d.line.contains("bug"))
        #expect(d.exitCode == 0)
    }

    @Test func exitCodesSeparateTheStates() {
        #expect(HermesUpgradeDecision.upToDate(head: Self.pin).exitCode == 0)
        #expect(HermesUpgradeDecision.upgrade(agentDir: Self.dir, from: Self.head, to: Self.pin).exitCode == 0)
        #expect(HermesUpgradeDecision.absent(agentDir: Self.dir).exitCode == 4)
        #expect(HermesUpgradeDecision.noPin(installer: "/x/install-hermes.sh").exitCode == 5)
        #expect(HermesUpgradeDecision.noInstaller.exitCode == 5)
        #expect(HermesUpgradeDecision.noGit(agentDir: Self.dir).exitCode == 5)
    }

    @Test func aMissingPinSaysWhichFileAndThatATestShouldBeRed() {
        let d = HermesUpgradeDecision.noPin(installer: "/x/scripts/install-hermes.sh")
        #expect(d.line.contains("/x/scripts/install-hermes.sh"))
        #expect(d.line.contains("test-hermes-upgrade.sh should be red"))
    }
}
