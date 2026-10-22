import Foundation
import Testing
@testable import MoeLedger

/// Keeping the away machine's brain in step with this Mac's — CLOUD-PLAN §18.30.
///
/// **What this is a test of, and why it is here rather than beside the pane.**
/// On 2026-09-16 the owner changed his brain in Settings › Brain, looked at his
/// away machine, and found it thinking with what he had given it weeks before.
/// Two separate failures: the change did not travel where nothing was needed
/// from anybody, and where it genuinely could not travel — a Claude plan, whose
/// token is minted per machine — no pane said so at the moment of the change.
///
/// The fold that decides between those cases lives in `MoeLedger` for the
/// reason `AwayBrainField` does: **`Moe` has no test target**, and three
/// deliberate mutants in that target once survived 1905 Swift tests. A rule
/// about when a credential travels off this Mac is not a rule to leave
/// somewhere a mutant survives.
@Suite struct AwayBrainFollowTests {

    static func here(_ provider: String, _ model: String,
                     baseURL: String = "", key: Bool = false) -> AwayBrainFollow.Here {
        .init(provider: provider, model: model, baseURL: baseURL, keyInHand: key)
    }

    static func away(_ state: String, kind: String = "", provider: String = "",
                     model: String = "", baseURL: String = "") -> AwayBrainFollow.Published {
        .init(state: state, kind: kind, provider: provider, model: model, baseURL: baseURL)
    }

    static func follows(_ provider: String, _ model: String, changed: Bool,
                        available: Bool = true, apart: Bool = false) -> AwayBrainFollow.Here {
        .init(provider: provider, model: model, baseURL: "", keyInHand: false,
              credentialAvailable: available, credentialChanged: changed, apart: apart)
    }

    // MARK: - Follow unless set apart (owner, 2026-09-25)

    @Test("A new Claude account here reaches the machine, even on the same model")
    func newClaudeAccountFollows() {
        // The owner's case: a new Claude plan signed in on the Mac after the old
        // one ran out; same model. The fold called this `upToDate` and the
        // machine kept answering with the exhausted account.
        let machine = Self.away("set", kind: "setup_token", provider: "anthropic", model: "claude-sonnet-5")
        #expect(AwayBrainFollow.step(here: Self.follows("claude-code-cli", "sonnet", changed: true),
                                     away: machine) == .sendClaudeToken(model: "claude-sonnet-5"))
        // The same sign-in already sent: nothing to do.
        #expect(AwayBrainFollow.step(here: Self.follows("claude-code-cli", "sonnet", changed: false),
                                     away: machine) == .upToDate)
        #expect(AwayBrainFollow.travels(.sendClaudeToken(model: "claude-sonnet-5")))
    }

    @Test("A machine on another kind of brain is given this Mac's Claude sign-in")
    func claudeSignInReplacesAnotherKind() {
        let onKey = Self.away("set", kind: "api_key", provider: "deepseek", model: "deepseek-v4-flash")
        #expect(AwayBrainFollow.step(here: Self.follows("claude-code-cli", "opus", changed: false),
                                     away: onKey) == .sendClaudeToken(model: "claude-opus-5-5"))
        // No sign-in stored here: still reported, never guessed.
        #expect(AwayBrainFollow.step(here: Self.follows("claude-code-cli", "opus", changed: false, available: false),
                                     away: onKey) == .needsItsOwnToken)
    }

    @Test("This Mac's own key follows without being typed again")
    func storedKeyFollows() {
        let other = Self.away("set", kind: "api_key", provider: "anthropic", model: "claude-sonnet-5")
        #expect(AwayBrainFollow.step(here: Self.follows("deepseek", "deepseek-v4-flash", changed: false),
                                     away: other)
                == .sendKey(provider: "deepseek", model: "deepseek-v4-flash", baseURL: ""))
        let same = Self.away("set", kind: "api_key", provider: "deepseek", model: "deepseek-v4-flash")
        #expect(AwayBrainFollow.step(here: Self.follows("deepseek", "deepseek-v4-flash", changed: true),
                                     away: same)
                == .sendKey(provider: "deepseek", model: "deepseek-v4-flash", baseURL: ""))
        #expect(AwayBrainFollow.step(here: Self.follows("deepseek", "deepseek-v4-flash", changed: false),
                                     away: same) == .upToDate)
    }

    @Test("A machine set apart is never overwritten, and nothing is said")
    func apartIsLeftAlone() {
        let machine = Self.away("set", kind: "api_key", provider: "deepseek", model: "deepseek-v4-flash")
        for provider in ["claude-code-cli", "deepseek", "openai-codex", "anthropic"] {
            #expect(AwayBrainFollow.step(here: Self.follows(provider, "m", changed: true, apart: true),
                                         away: machine) == .apart, "\(provider)")
        }
        #expect(!AwayBrainFollow.travels(.apart))
        #expect(AwayBrainCopy.followNote(.apart) == nil)
    }

    @Test("Following never puts back a brain the person removed")
    func followRespectsRemoval() {
        for state in ["none", "revoked"] {
            #expect(AwayBrainFollow.step(here: Self.follows("claude-code-cli", "sonnet", changed: true),
                                         away: Self.away(state)) == .noMachine)
        }
    }

    // MARK: - Nobody with no machine ever sees a word of this

    @Test("No machine published: nothing to do and nothing to say")
    func noMachine() {
        for state in ["none", "revoked"] {
            #expect(AwayBrainFollow.step(here: Self.here("anthropic", "claude-sonnet-4-6"),
                                         away: Self.away(state)) == .noMachine)
        }
        #expect(AwayBrainCopy.followNote(.noMachine) == nil)
    }

    /// **`revoked` is `noMachine` and that is a decision, not a fold.**
    /// Removing the brain is an act the person took deliberately; republishing
    /// on their next model change would undo it without a word.
    @Test("A removed brain is not quietly put back")
    func revokedStaysRemoved() {
        let step = AwayBrainFollow.step(here: Self.here("deepseek", "deepseek-v4-pro", key: true),
                                        away: Self.away("revoked"))
        #expect(step == .noMachine)
        #expect(AwayBrainFollow.travels(step) == false)
    }

    /// A failure to ask is not an answer — and here the answer to "is there a
    /// machine" is unknown, so the pane says nothing rather than inventing
    /// either verdict. Settings › Away is where an unanswerable check is
    /// reported, and it already reports it.
    @Test("Could not ask, could not read: silence, never a claim")
    func cannotTell() {
        for state in ["could-not-ask", "sealed", "unreadable", "a-state-a-later-build-invented"] {
            let step = AwayBrainFollow.step(here: Self.here("anthropic", "claude-sonnet-4-6"),
                                            away: Self.away(state))
            #expect(step == .cannotTell, "\(state)")
            #expect(AwayBrainCopy.followNote(step) == nil, "\(state)")
            #expect(AwayBrainFollow.travels(step) == false, "\(state)")
        }
    }

    // MARK: - The change that travels by itself

    @Test("Same key-paid provider, new model: re-seal what the machine has")
    func modelChangeRetunes() {
        let step = AwayBrainFollow.step(
            here: Self.here("deepseek", "deepseek-v4-flash"),
            away: Self.away("set", kind: "api_key", provider: "deepseek",
                            model: "deepseek-v4-pro"))
        #expect(step == .retune(model: "deepseek-v4-flash", baseURL: "",
                                assertProvider: "deepseek"))
        #expect(AwayBrainFollow.travels(step))
    }

    /// The provider goes with a retune as an **assertion that it has not
    /// changed**. Without it, `moe-brain-away.py --retune` would have nothing
    /// to compare against and a later fold bug could re-seal a DeepSeek key as
    /// Anthropic's: published cleanly, applied cleanly, 401 on every turn.
    @Test("A retune carries the provider to be checked against, and no stdin")
    func retuneCommandShape() {
        let cmd = AwayBrainCommand.retune(model: "deepseek-v4-flash", baseURL: "",
                                          assertProvider: "deepseek")
        #expect(cmd.standardInput == nil)
        #expect(cmd.arguments == ["--retune", "--model", "deepseek-v4-flash",
                                  "--provider", "deepseek"])
        // Nothing on argv may be a credential, and `--retune` is the one mode
        // that carries one without being handed it.
        #expect(!cmd.arguments.contains { $0.hasPrefix("sk-") })
    }

    @Test("A Claude plan retunes on the model alone — the token is already its own")
    func claudePlanModelChangeRetunes() {
        let step = AwayBrainFollow.step(
            here: Self.here(AwayBrainFollow.claudePlanProvider, "claude-opus-4-8"),
            away: Self.away("set", kind: "setup_token", provider: "anthropic",
                            model: "claude-sonnet-4-6"))
        // nil provider: this Mac spells it `claude-code-cli` and the document
        // spells it `anthropic`, and both are SETUP_TOKEN_PROVIDERS. The kind
        // is the assertion that matters.
        #expect(step == .retune(model: "claude-opus-4-8", baseURL: "", assertProvider: nil))
        let cmd = AwayBrainCommand.retune(model: "claude-opus-4-8", baseURL: "",
                                          assertProvider: nil)
        #expect(cmd.arguments == ["--retune", "--model", "claude-opus-4-8"])
    }

    @Test("A key typed here travels, even to a provider the machine has never had")
    func typedKeyTravels() {
        let step = AwayBrainFollow.step(
            here: Self.here("anthropic", "claude-sonnet-4-6", key: true),
            away: Self.away("set", kind: "api_key", provider: "deepseek",
                            model: "deepseek-v4-pro"))
        #expect(step == .sendKey(provider: "anthropic", model: "claude-sonnet-4-6",
                                 baseURL: ""))
    }

    /// **The ChatGPT plan follows by itself, and it follows a change of
    /// account too.** `~/.codex/auth.json` is on this Mac; re-sealing the old
    /// copy under a new model would leave the machine signed into an account
    /// the person has left.
    @Test("A ChatGPT plan is sent from the live file, not re-sealed")
    func codexAlwaysRepublishes() {
        let step = AwayBrainFollow.step(
            here: Self.here(AwayBrainFollow.codexProvider, "gpt-5.6"),
            away: Self.away("set", kind: "codex_auth", provider: "openai-codex",
                            model: "gpt-5.5"))
        #expect(step == .sendCodex(model: "gpt-5.6"))
        #expect(AwayBrainFollow.travels(step))
    }

    /// 2026-09-22, the owner's machine: `brain.json` said `claude-sonnet-4-6`
    /// while his Mac thought with Claude Code's `sonnet`. The machine calls the
    /// Messages API, which has no `sonnet`, so the alias is translated before
    /// it travels. Falsifier: retune with `here.model` again and the first
    /// expectation goes red with `.retune(model: "sonnet", …)`.
    @Test("A Claude Code alias follows as its full name; a stale Sonnet 4.6 is brought up")
    func claudePlanAliasFollowsAsFullName() {
        let stale = Self.away("set", kind: "setup_token", provider: "anthropic",
                              model: "claude-sonnet-4-6")
        #expect(AwayBrainFollow.step(here: Self.here(AwayBrainFollow.claudePlanProvider, "sonnet"),
                                     away: stale)
                == .retune(model: "claude-sonnet-5", baseURL: "", assertProvider: nil))
        #expect(AwayBrainFollow.step(here: Self.here(AwayBrainFollow.claudePlanProvider, "opus[1m]"),
                                     away: stale)
                == .retune(model: "claude-opus-5-5", baseURL: "", assertProvider: nil))
        // Already there: `sonnet` here and `claude-sonnet-5` there are the same.
        let current = Self.away("set", kind: "setup_token", provider: "anthropic",
                                model: "claude-sonnet-5")
        #expect(AwayBrainFollow.step(here: Self.here(AwayBrainFollow.claudePlanProvider, "sonnet"),
                                     away: current) == .upToDate)
    }

    @Test("The machine's Claude: the Mac's tier when it has one, else the current Sonnet")
    func machineModelForAClaudePlan() {
        #expect(AwayBrainFollow.defaultClaudeModel == "claude-sonnet-5")
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "sonnet") == "claude-sonnet-5")
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "Opus") == "claude-opus-5-5")
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "haiku") == "claude-haiku-4-5-20251001")
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "sonnet[1m]") == "claude-sonnet-5")
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "") == "claude-sonnet-5")
        // A full name the person chose is theirs.
        #expect(AwayBrainFollow.machineModel(forClaudePlan: "claude-opus-4-8") == "claude-opus-4-8")
        // Only a Claude plan speaks for the machine's Claude. A Mac on ChatGPT
        // or a DeepSeek key does not — and its model name must never leak in.
        #expect(AwayBrainFollow.machineModel(macProvider: AwayBrainFollow.claudePlanProvider,
                                             macModel: "opus") == "claude-opus-5-5")
        #expect(AwayBrainFollow.machineModel(macProvider: AwayBrainFollow.codexProvider,
                                             macModel: "gpt-5.5") == "claude-sonnet-5")
        #expect(AwayBrainFollow.machineModel(macProvider: "deepseek",
                                             macModel: "deepseek-v4-pro") == "claude-sonnet-5")
    }

    @Test("Nothing is published when the machine already has exactly this")
    func upToDate() {
        let cases: [(AwayBrainFollow.Here, AwayBrainFollow.Published)] = [
            (Self.here("deepseek", "deepseek-v4-pro"),
             Self.away("set", kind: "api_key", provider: "deepseek", model: "deepseek-v4-pro")),
            (Self.here(AwayBrainFollow.claudePlanProvider, "claude-sonnet-4-6"),
             Self.away("set", kind: "setup_token", provider: "anthropic",
                       model: "claude-sonnet-4-6")),
            (Self.here(AwayBrainFollow.codexProvider, "gpt-5.5"),
             Self.away("set", kind: "codex_auth", provider: "openai-codex", model: "gpt-5.5")),
        ]
        for (mac, machine) in cases {
            let step = AwayBrainFollow.step(here: mac, away: machine)
            #expect(step == .upToDate, "\(mac.provider)")
            #expect(AwayBrainCopy.followNote(step) == nil, "\(mac.provider)")
        }
    }

    // MARK: - The change that cannot travel, and has to be said

    /// The owner's own words: *"I think if it's a Claude subscription, he has
    /// to get another auth token. It should tell him over there."*
    @Test("A Claude plan the machine has never had needs a sign-in of its own")
    func claudePlanNeedsItsOwnToken() {
        let step = AwayBrainFollow.step(
            here: Self.here(AwayBrainFollow.claudePlanProvider, "claude-sonnet-4-6"),
            away: Self.away("set", kind: "api_key", provider: "deepseek",
                            model: "deepseek-v4-pro"))
        #expect(step == .needsItsOwnToken)
        #expect(AwayBrainFollow.travels(step) == false)
        let note = AwayBrainCopy.followNote(step, stillOn: "your DeepSeek key")
        #expect(note != nil)
        #expect(note?.needsYou == true)
        #expect(note?.action != nil)
        #expect(note?.sentence.contains("your DeepSeek key") == true)
    }

    /// **The line this whole area exists to prevent.** The Mac has the key in
    /// `~/.hermes/.env` in the clear and could send it. It does not: a
    /// credential that has only ever lived on this Mac does not become a
    /// travelling one because somebody changed a dropdown. The pane says so
    /// and offers the field instead.
    @Test("A stored key is reported, never read back out and sent")
    func storedKeyIsNotSent() {
        let step = AwayBrainFollow.step(
            here: Self.here("anthropic", "claude-sonnet-4-6", key: false),
            away: Self.away("set", kind: "api_key", provider: "deepseek",
                            model: "deepseek-v4-pro"))
        #expect(step == .needsItsOwnKey(provider: "anthropic"))
        #expect(AwayBrainFollow.travels(step) == false)
        let note = AwayBrainCopy.followNote(step, stillOn: "your DeepSeek key")
        #expect(note?.needsYou == true)
        #expect(note?.sentence.contains("Anthropic") == true)
    }

    /// A model on this Mac's own loopback. `moeledger.brain` would seal and
    /// apply it without a murmur — `BASE_URL_PROVIDERS` is three provider ids
    /// and has no opinion about hosts — and the machine would point at its own
    /// empty port. That is the worst of the outcomes, because it looks like it
    /// worked.
    @Test("A model that runs on this Mac is never sent")
    func localOnly() {
        for provider in ["lmstudio", "custom"] {
            let step = AwayBrainFollow.step(
                here: Self.here(provider, "qwen3-30b", baseURL: "http://127.0.0.1:1234/v1"),
                away: Self.away("set", kind: "api_key", provider: "deepseek",
                                model: "deepseek-v4-pro"))
            #expect(step == .localOnly, Comment(rawValue: provider))
            #expect(AwayBrainFollow.travels(step) == false, Comment(rawValue: provider))
        }
    }

    /// **Matched on what the address is, not on which provider carries it.**
    /// `moe-custom` is a key-paid row called "Anywhere else", and pointing it
    /// at a local server is an ordinary thing to do. A guard that enumerated
    /// `lmstudio` and `custom` would be walked past by it — which is CLAUDE.md's
    /// rule about guards that enumerate names, and this is the third time this
    /// area has met it.
    @Test("A key-paid provider aimed at a local address is local too")
    func localAddressUnderAnyProvider() {
        for address in ["http://127.0.0.1:8080/v1", "http://localhost:1234/v1",
                        "http://192.168.1.40:11434/v1", "http://10.0.0.5/v1",
                        "http://172.20.3.4/v1", "http://mini.local:1234/v1",
                        "http://169.254.7.8/v1"] {
            #expect(AwayBrainFollow.isLocalAddress(address), Comment(rawValue: address))
            let step = AwayBrainFollow.step(
                here: Self.here("moe-custom", "some-model", baseURL: address, key: true),
                away: Self.away("set", kind: "api_key", provider: "moe-custom",
                                model: "other-model"))
            #expect(step == .localOnly, Comment(rawValue: address))
        }
    }

    @Test("A real endpoint is not mistaken for a local one")
    func remoteAddressesTravel() {
        for address in ["https://api.example.com/v1", "https://11.0.0.2/v1",
                        "https://172.32.0.1/v1", "https://192.169.1.1/v1", ""] {
            #expect(AwayBrainFollow.isLocalAddress(address) == false, Comment(rawValue: address))
        }
        let step = AwayBrainFollow.step(
            here: Self.here("moe-custom", "some-model",
                            baseURL: "https://api.example.com/v1", key: true),
            away: Self.away("set", kind: "api_key", provider: "moe-custom", model: "old"))
        #expect(step == .sendKey(provider: "moe-custom", model: "some-model",
                                 baseURL: "https://api.example.com/v1"))
    }

    // MARK: - The field the pane does not show

    /// **An address from a provider that has none.** `BrainPane.apply` passes
    /// `config.brainExtras["baseURL"] ?? provider.defaultBaseURL` — one slot
    /// shared by every provider — so a value in it reaches the away machine
    /// under whatever provider happens to be current.
    ///
    /// Two wrong answers come out of reading it unconditionally, and a person
    /// can see neither:
    ///
    ///  * the fold calls a **DeepSeek** brain `localOnly`, on the strength of a
    ///    field DeepSeek does not have, and sends nothing at all;
    ///  * and past that, the address goes into the retune, where `check_body`
    ///    refuses the whole document — *"'deepseek' takes no base_url"* — and
    ///    the person is told their machine could not be brought up to date
    ///    because of a field they cannot see and did not set.
    ///
    /// **Honest about how this gets in.** The first version of this note said
    /// the slot is never cleared on a provider change. It is:
    /// `BrainAccountSheet.apply` passes `""` for a provider with no address and
    /// `Conductor.applyBrain` writes nil for an empty one. **No reachable path
    /// in the current build was shown to leave a stale address behind** — an
    /// older build's config or a hand-edited one are the remaining ways in, and
    /// neither was measured. So this is a defence, kept because
    /// `AwayBrainCommand.carriesBaseURL` already enforces the same rule one
    /// road over against a slip that *was* measured, and a rule that holds on
    /// one road and not the other is the drift this area keeps paying for.
    @Test("A leftover address from another provider is dropped, not carried")
    func staleBaseURLIsDropped() {
        let stale = "http://127.0.0.1:1234/v1"
        let here = Self.here("deepseek", "deepseek-v4-flash", baseURL: stale)
        let step = AwayBrainFollow.step(
            here: here,
            away: Self.away("set", kind: "api_key", provider: "deepseek",
                            model: "deepseek-v4-pro"))
        #expect(step != .localOnly, "a DeepSeek brain is not local because of a field it does not have")
        #expect(step == .retune(model: "deepseek-v4-flash", baseURL: "",
                                assertProvider: "deepseek"))
        // And the same on the road where a key was typed.
        let typed = AwayBrainFollow.step(
            here: Self.here("anthropic", "claude-sonnet-4-6", baseURL: stale, key: true),
            away: Self.away("set", kind: "api_key", provider: "deepseek", model: "x"))
        #expect(typed == .sendKey(provider: "anthropic", model: "claude-sonnet-4-6",
                                  baseURL: ""))
    }

    /// The three that genuinely take one still carry it — the drop above must
    /// not be a flat refusal.
    @Test("The providers that do take an address still send it")
    func realBaseURLIsCarried() {
        #expect(AwayBrainFollow.carriesBaseURL("moe-custom"))
        #expect(AwayBrainFollow.carriesBaseURL("lmstudio"))
        #expect(AwayBrainFollow.carriesBaseURL("custom"))
        for spelled in ["anthropic", "openai-api", "deepseek", "gemini", "xai",
                        "openrouter", "claude-code-cli", "openai-codex"] {
            #expect(AwayBrainFollow.carriesBaseURL(spelled) == false, Comment(rawValue: spelled))
        }
        let step = AwayBrainFollow.step(
            here: Self.here("moe-custom", "some-model",
                            baseURL: "https://api.example.com/v1"),
            away: Self.away("set", kind: "api_key", provider: "moe-custom",
                            model: "other-model", baseURL: "https://api.example.com/v1"))
        #expect(step == .retune(model: "some-model", baseURL: "https://api.example.com/v1",
                                assertProvider: "moe-custom"))
    }

    /// **Changing only the address is a change.** The model is the same, so a
    /// comparison that looked at the model alone would answer `upToDate` and
    /// leave the machine talking to a service that has moved — which answers
    /// nothing, and says nothing, because from every surface it looks set.
    @Test("A new address on the same model is not up to date")
    func addressChangeIsNotUpToDate() {
        let step = AwayBrainFollow.step(
            here: Self.here("moe-custom", "some-model", baseURL: "https://new.example.com/v1"),
            away: Self.away("set", kind: "api_key", provider: "moe-custom",
                            model: "some-model", baseURL: "https://old.example.com/v1"))
        #expect(step == .retune(model: "some-model", baseURL: "https://new.example.com/v1",
                                assertProvider: "moe-custom"))
    }

    // MARK: - What the pane actually says

    /// Three rules, and each of them has been broken on this surface before.
    @Test("No note claims the machine has it, and none speaks the code's words")
    func wordingRules() {
        let steps: [AwayBrainFollow.Step] = [
            .retune(model: "m", baseURL: "", assertProvider: "deepseek"),
            .sendKey(provider: "anthropic", model: "m", baseURL: ""),
            .sendCodex(model: "m"),
            .needsItsOwnToken,
            .needsItsOwnKey(provider: "gemini"),
            .localOnly,
        ]
        let jargon = ["setup_token", "api_key", "codex_auth", "moe:brain", "Hermes",
                      "moe-brain-away", "base_url", "claude-code-cli", "openai-codex",
                      "document", "ledger", "seal"]
        for step in steps {
            guard let note = AwayBrainCopy.followNote(step, stillOn: "your Claude plan") else {
                Issue.record("\(step) says nothing")
                continue
            }
            for word in jargon {
                #expect(!note.sentence.contains(word), "\(step) says \(word)")
            }
        }
        // Nothing may claim the machine already has the change: a published
        // document reaches it on its next sync, and a pane that says "done"
        // over a machine still on last week's model is the fourteen-hour
        // failure of 2026-09-14 said one surface further out.
        let done = AwayBrainCopy.followed()
        #expect(done.sentence.contains("next time it syncs"))
        #expect(done.needsYou == false)
    }

    /// Where a person has to do something, the note carries the button that
    /// does it — not a pointer to another pane, which is how this whole area
    /// lost the owner in the first place.
    @Test("Every note that needs the person carries an action")
    func actionableNotesHaveAButton() {
        for step: AwayBrainFollow.Step in [.needsItsOwnToken,
                                           .needsItsOwnKey(provider: "gemini")] {
            let note = AwayBrainCopy.followNote(step)
            #expect(note?.needsYou == true, "\(step)")
            #expect(note?.action?.isEmpty == false, "\(step)")
        }
    }

    @Test("A refusal from the job is shown as it came, not wrapped in a guess")
    func failureKeepsTheJobsSentence() {
        let note = AwayBrainCopy.followFailed("Your away machine is set up with a "
                                              + "different account, so Alfie hasn't changed it.")
        #expect(note.sentence.hasPrefix("Your away machine is set up"))
        #expect(note.needsYou)
        // And an empty stream still says something, rather than an empty line.
        #expect(!AwayBrainCopy.followFailed("").sentence.isEmpty)
    }
}

/// One sentence for the person, out of a stream written for a log.
///
/// The owner was shown, in amber, under the model field of Settings › Away:
/// *"moe-brain-away: this copies /Users/…/.codex/auth.json to the machine. It
/// is a credential FILE, not a token minted for the purpose — the weakest of
/// the three shapes… moe-brain-away: /Users/…/.codex/auth.json is not there —
/// sign in with `codex login` on this Mac first"*. `AwayBrainSetup.run` took
/// the last three stderr lines and joined them with a space.
@Suite struct AwayBrainMessageTests {

    /// The stream that produced the screenshot, in the shape the job emits it.
    static let theScreenshot = """
        moe-brain-away: this copies /Users/someone/.codex/auth.json to the machine. It is a credential FILE, not a token minted for the purpose — the weakest of the three shapes, and the one to change if OpenAI's device-code flow becomes available to you.
        moe-brain-away: Sign in with codex login on this Mac first — that file is what your machine will think with, and there isn't one at /Users/someone/.codex/auth.json yet.
        """

    @Test("The job's own name never reaches the person")
    func prefixIsStripped() {
        let shown = AwayBrainMessage.personFacing(Self.theScreenshot)
        #expect(shown?.hasPrefix("Sign in with codex login") == true)
        #expect(shown?.contains("moe-brain-away") == false)
    }

    @Test("One message, and it is the one that can be acted on")
    func onlyTheLastLine() {
        let shown = AwayBrainMessage.personFacing(Self.theScreenshot) ?? ""
        // The explanation above it is working-out for a log, and it is exactly
        // the design-doc language that has no business on a settings pane.
        #expect(!shown.contains("weakest of the three shapes"))
        #expect(!shown.contains("device-code flow"))
        #expect(!shown.contains("credential FILE"))
    }

    /// **Matched by shape, not by name.** `moe-brain-away` is one job and the
    /// next one will be called something else; a guard that enumerates names is
    /// walked past by a new name (CLAUDE.md), and this area has met that rule
    /// three times already.
    @Test("Any log prefix goes, not just this job's")
    func anyPrefixGoes() {
        #expect(AwayBrainMessage.stripLogPrefix("some-other-job: Try again.") == "Try again.")
        #expect(AwayBrainMessage.stripLogPrefix("moe_connect.away: Try again.") == "Try again.")
    }

    /// Moe's own sentences begin with a capital letter, so the rule cannot eat
    /// one — and a sentence that merely contains ": " keeps all of itself.
    @Test("A real sentence is never mistaken for a prefix")
    func sentencesSurvive() {
        let kept = [
            "Your away machine is set up with a different account, so Alfie hasn't changed it.",
            "Give it one of these: a key, a sign-in, or an address.",
            "Open https://example.com/v1: that is the address it will use.",
            "Sign in with codex login on this Mac first.",
        ]
        for line in kept {
            #expect(AwayBrainMessage.stripLogPrefix(line) == line, Comment(rawValue: line))
        }
    }

    @Test("Nothing said is nil, not an empty sentence")
    func emptyStreamIsNil() {
        #expect(AwayBrainMessage.personFacing("") == nil)
        #expect(AwayBrainMessage.personFacing("\n   \n") == nil)
        // A line that is only a prefix is not a message; what there is stays.
        #expect(AwayBrainMessage.stripLogPrefix("moe-brain-away: ") == "moe-brain-away: ")
    }
}
