import Foundation
import Testing
@testable import MoeLedger

/// The Away brain sheet's two field rules and the command it builds —
/// CLOUD-PLAN §18.30 S3, S4, S5.
///
/// **This file exists because the code it tests used to be untestable.** The
/// rules were private functions inside `AwayBrainSheet.swift` (now in the closed cloud half)
/// and the argument list was built inline in `AwayBrain.swift`. `Moe` has no
/// test target — `grep -rln "AwayBrain" Tests` found nothing — so a hostile
/// pass deleted the credential check, deleted the length bound, and appended
/// `["--secret", secret]` to the argument list, and all three mutants survived
/// 1905 Swift tests. The last of those is the credential on a command line
/// every local user of this Mac can read with `ps`, which is the exact hazard
/// `AwayBrain.swift`'s own header names.
///
/// Moving the pure parts into `MoeLedger` is what made them killable. Every
/// test below goes red if the rule it names is removed.
@Suite struct AwayBrainFieldTests {

    /// The fifteen vendor key shapes: a published prefix plus a run of the
    /// right LENGTH filled with one repeated character. **Shapes, not
    /// credentials**, and deliberately not random — a file of high-entropy
    /// strings in a repository is a thing somebody later mistakes for a leak.
    ///
    /// The first seven are the seven a hostile pass measured as ACCEPTED by
    /// the 64-character bound this replaced. Together is 64 exactly, which is
    /// the tell that the length had been fitted to examples.
    static let keyShapes: [(String, String)] = [
        ("groq", "gsk_" + String(repeating: "a", count: 48)),
        ("perplexity", "pplx-" + String(repeating: "a", count: 43)),
        ("cerebras", "csk-" + String(repeating: "a", count: 40)),
        ("fireworks", "fw_" + String(repeating: "a", count: 32)),
        ("mistral", String(repeating: "a", count: 32)),
        ("cohere", String(repeating: "a", count: 40)),
        ("together", String(repeating: "a", count: 64)),
        ("google", "AIza" + String(repeating: "a", count: 35)),
        ("anthropic-api", "sk-ant-api03-" + String(repeating: "a", count: 95)),
        ("anthropic-oauth", "sk-ant-oat01-" + String(repeating: "a", count: 95)),
        ("openai", "sk-proj-" + String(repeating: "a", count: 74)),
        ("xai", "xai-" + String(repeating: "a", count: 76)),
        ("openrouter", "sk-or-v1-" + String(repeating: "a", count: 64)),
        ("github", "ghp_" + String(repeating: "a", count: 36)),
        ("huggingface", "hf_" + String(repeating: "a", count: 34)),
    ]

    /// Real model ids, six vendors and four naming conventions. The positive
    /// control: without it the rule under test could be a flat refusal.
    static let realModelIDs = [
        "claude-sonnet-4-6", "claude-opus-4-1-20250805", "claude-3-5-haiku-20241022",
        "gpt-5.5", "gpt-4o-mini", "o3-mini-2025-01-31",
        "deepseek-v4-flash-vision-exp", "deepseek-chat", "deepseek-reasoner",
        "google/gemini-3.1-flash-lite-preview", "gemini-2.5-pro-preview-06-05",
        "anthropic.claude-3-5-sonnet-20241022-v2:0",
        "us.anthropic.claude-sonnet-4-20250514-v1:0",
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        "mistralai/Mixtral-8x7B-Instruct-v0.1",
        "nvidia/llama-3.1-nemotron-70b-instruct",
        "accounts/fireworks/models/qwen2p5-72b-instruct",
        "Qwen/Qwen2.5-72B-Instruct", "moonshotai/kimi-k2-instruct",
        "zai-org/GLM-4.6", "x-ai/grok-4-fast", "openai/gpt-oss-120b",
        "deepseek-ai/DeepSeek-V3.1-Terminus", "text-embedding-3-large",
        "llama-3.3-70b-versatile", "sonar-reasoning-pro",
        "claude-code-cli", "lmstudio-community/qwen3-coder-30b",
    ]

    // MARK: the property the whole slice rests on

    /// The secret reaches the child on **stdin and nowhere else**.
    ///
    /// Asserted over the whole argument list rather than at a known index, so
    /// a mutant that appends, inserts or interleaves is caught the same way.
    @Test func theSecretIsNeverAnArgument() {
        let secret = "sk-ant-oat01-fixture-not-a-real-setup-token"
        for kind in ["api-key", "setup-token", "codex"] {
            let command = AwayBrainCommand.publish(
                kindArgument: kind, provider: "anthropic", model: "claude-sonnet-4-6",
                baseURL: "https://api.example/v1", secret: secret)
            #expect(!command.arguments.contains(where: { $0.contains(secret) }),
                    "\(kind): the credential is on argv, where `ps` reads it")
            #expect(!command.arguments.contains("--secret"))
        }
    }

    /// And it does reach stdin for the two kinds that carry one — otherwise
    /// the test above passes on a publisher that sends nothing at all.
    @Test func theSecretReachesStandardInput() {
        let secret = "fixture-not-a-real-key"
        #expect(AwayBrainCommand.publish(kindArgument: "api-key", provider: "deepseek",
                                         model: "deepseek-chat", baseURL: "",
                                         secret: secret).standardInput == secret)
        #expect(AwayBrainCommand.publish(kindArgument: "setup-token", provider: "anthropic",
                                         model: "claude-sonnet-4-6", baseURL: "",
                                         secret: secret).standardInput == secret)
        // Codex carries none: what travels is the file the machine already has.
        #expect(AwayBrainCommand.publish(kindArgument: "codex", provider: "openai-codex",
                                         model: "gpt-5.5-codex", baseURL: "",
                                         secret: secret).standardInput == nil)
    }

    @Test func theChoicesDoReachTheArgumentList() {
        let command = AwayBrainCommand.publish(kindArgument: "api-key", provider: "moe-custom",
                                               model: "my-model",
                                               baseURL: "https://x.example/v1", secret: "s")
        #expect(command.arguments == ["--kind", "api-key", "--model", "my-model",
                                      "--provider", "moe-custom",
                                      "--base-url", "https://x.example/v1"])
    }

    // MARK: the Model field

    @Test func everyVendorKeyShapeIsRefusedAsAModelName() {
        for (name, shape) in Self.keyShapes {
            #expect(AwayBrainField.modelProblem(shape) != nil,
                    "\(name)'s key shape passes as a model id")
        }
    }

    @Test func everyRealModelIDIsAccepted() {
        for model in Self.realModelIDs {
            #expect(AwayBrainField.modelProblem(model) == nil, "\(model)")
        }
    }

    /// The bound sits between the two measurements, asserted rather than
    /// described — which is what makes it a property instead of a list.
    @Test func theRunBoundSitsBetweenTheTwoMeasurements() {
        let longestReal = Self.realModelIDs.map { AwayBrainField.longestAlnumRun($0) }.max() ?? 0
        let shortestKey = Self.keyShapes.map { AwayBrainField.longestAlnumRun($0.1) }.min() ?? 0
        #expect(longestReal <= AwayBrainField.modelMaxRun)
        #expect(AwayBrainField.modelMaxRun < shortestKey,
                "real ids reach \(longestReal), key shapes start at \(shortestKey)")
    }

    @Test func aModelNameOutsideTheCharacterClassIsRefused() {
        // It reaches `config.yaml` and a log line as itself.
        #expect(AwayBrainField.modelProblem("claude sonnet") != nil)
        #expect(AwayBrainField.modelProblem("model\nmoe brain: applied") != nil)
        #expect(AwayBrainField.modelProblem("") != nil)
    }

    // MARK: the Base URL field, which had no rule at all

    @Test func everyVendorKeyShapeIsRefusedAsABaseURL() {
        for (name, shape) in Self.keyShapes {
            #expect(AwayBrainField.baseURLProblem(shape) != nil,
                    "\(name)'s key shape passes as an endpoint")
        }
    }

    @Test func aRealEndpointIsAccepted() {
        for url in ["https://api.deepseek.com/v1", "https://openrouter.ai/api/v1",
                    "http://127.0.0.1:1234/v1",
                    "https://gateway.example.co.uk:8443/v1/openai"] {
            #expect(AwayBrainField.baseURLProblem(url) == nil, "\(url)")
        }
        #expect(AwayBrainField.baseURLProblem("") == nil, "no endpoint is the ordinary case")
    }

    @Test func aSignInInsideTheAddressIsRefused() {
        #expect(AwayBrainField.baseURLProblem("https://user:hunter2@gateway.example/v1") != nil)
        #expect(AwayBrainField.baseURLProblem("https://gateway.example/v1") == nil)
    }
}

/// A stale field the sheet no longer shows, and a description that has to
/// change with the machine it is describing. Both were found by a hostile
/// review of the in-app sign-in (2026-09-10); both live in `MoeLedger` for the
/// same reason as everything above — `Moe` has no test target, so a defect in
/// a SwiftUI view body cannot go red anywhere.
@Suite struct AwayBrainSheetLeftoversTests {

    /// The Base URL row is only ever drawn under "A key you pay for", but the
    /// sheet holds one `baseURL` for the whole sheet and never cleared it on a
    /// change of kind. So a URL typed under that row travelled with a Claude
    /// setup-token: invisible on screen, refused by `moeledger.brain` only
    /// **after** Anthropic had minted a real year-long token.
    @Test func onlyApiKeyCarriesABaseURL() {
        #expect(AwayBrainCommand.carriesBaseURL("api-key"))
        #expect(!AwayBrainCommand.carriesBaseURL("setup-token"))
        #expect(!AwayBrainCommand.carriesBaseURL("codex"))
    }

    @Test func aLeftoverBaseURLNeverReachesArgvForASetupToken() {
        let stale = "https://gateway.example/v1"
        let token = AwayBrainCommand.publish(kindArgument: "setup-token", provider: "anthropic",
                                             model: "claude-sonnet-4-6", baseURL: stale,
                                             secret: "sk-ant-oat01-xyz")
        #expect(!token.arguments.contains("--base-url"))
        #expect(!token.arguments.contains(stale))
        #expect(token.standardInput == "sk-ant-oat01-xyz", "the secret still goes on stdin")

        let codex = AwayBrainCommand.publish(kindArgument: "codex", provider: "openai-codex",
                                             model: "gpt-5.5", baseURL: stale, secret: "")
        #expect(!codex.arguments.contains("--base-url"))

        // …and the kind that does show the field still sends it.
        let key = AwayBrainCommand.publish(kindArgument: "api-key", provider: "custom",
                                           model: "some-model", baseURL: stale, secret: "k")
        #expect(key.arguments.contains("--base-url"))
        #expect(key.arguments.contains(stale))
    }

    /// The row used to say "Press Sign in with Claude" on a Mac with no Claude
    /// Code, directly above a second line saying there was nothing to sign in
    /// with — and the sentence that had told people how to *get* a token had
    /// been deleted between the two.
    @Test func theDescriptionSaysOneThingAtATime() {
        let withButton = AwayBrainCopy.setupTokenExplanation(signInAvailable: true)
        #expect(AwayBrainCopy.namesTheButton(withButton))
        #expect(!AwayBrainCopy.namesTheCommand(withButton),
                "telling someone to run the command the button just ran is the defect")

        let without = AwayBrainCopy.setupTokenExplanation(signInAvailable: false)
        #expect(!AwayBrainCopy.namesTheButton(without),
                "a button that is not on screen must not be named")
        #expect(AwayBrainCopy.namesTheCommand(without),
                "with no button, the command is the only true answer left")
    }

    /// Neither branch may promise anything about Anthropic's side.
    @Test func neitherBranchClaimsWhatMoeCannotKnow() {
        for text in [AwayBrainCopy.setupTokenExplanation(signInAvailable: true),
                     AwayBrainCopy.setupTokenExplanation(signInAvailable: false)] {
            #expect(!text.lowercased().contains("untouched"))
            #expect(!text.lowercased().contains("in a terminal"))
        }
    }
}
