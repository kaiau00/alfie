import Foundation
import Testing
@testable import Moe

/// A failure the person has to fix is said where they asked, and kept in
/// Settings until it is fixed.
///
/// The half that landed on 2026-09-15 covers the failures that clear
/// themselves: a rate limit says "I'll answer as soon as it clears, in about
/// ten minutes" and that comes true. This file is the other half, and the
/// difference is the whole point — **a revoked key must never be told in the
/// shape of a rate limit**, because nothing will clear and the sentence is
/// then a lie the person waits on.
struct BrainTroubleTests {

    /// Every provider the picker offers. Several tests sweep all of them
    /// rather than spot-checking one, because "a person on ChatGPT is never
    /// told about Claude" is a claim about all of them.
    private let everyProvider = BrainProviderKind.allCases

    // MARK: - Hard is not temporary

    @Test("a credential that was turned down is never told as something that will clear")
    func hardIsNeverToldAsTemporary() {
        // Falsifier: return `temporarySentence` from any `.hard` branch of
        // `BrainTrouble.verdict`, or reword one of the four `sentence` cases
        // to promise a retry. Each turns this red on the first provider.
        for p in everyProvider {
            for kind in BrainTrouble.Kind.allCases {
                let s = BrainTrouble.sentence(kind, p)
                #expect(s != BrainTrouble.temporarySentence(p), "\(p.rawValue)/\(kind.rawValue)")
                // The three ways the temporary half phrases a wait. None of
                // them may appear over a failure that will not clear.
                for promise in ["as soon as it clears", "in about", "Ask me again in a few minutes"] {
                    #expect(!s.contains(promise), "\(p.rawValue)/\(kind.rawValue) promised: \(promise)")
                }
            }
        }
    }

    @Test("a rate limit is temporary, and keeps nothing in Settings")
    func rateLimitKeepsNothing() {
        // Falsifier: add "rate_limit" to `BrainTrouble.hardReasons`, or drop
        // the `retryable == true` branch so it falls to `.unknown` — the
        // second makes the `.temporary` expectation fail.
        let v = BrainTrouble.verdict(reason: "rate_limit", retryable: true,
                                     message: "429 rate limit exceeded", provider: .openAI)
        guard case .temporary = v else { Issue.record("not temporary: \(v)"); return }
        let words = TurnError.personWords("429 rate limit exceeded", provider: .openAI,
                                          failureReason: "rate_limit", failureRetryable: true)
        #expect(words.keep == nil)
    }

    // MARK: - Hermes's verdict beats prose

    @Test("Hermes's own classification wins over anything read out of the message")
    func structuredVerdictWins() {
        // The case this exists for: a provider that words an auth failure as
        // "your rate limit has been permanently revoked" — prose says wait,
        // the classifier says the credential is dead. The classifier saw the
        // status code and the structured body; this side has a string.
        //
        // Falsifier: move the prose fallback above the `reason` branch in
        // `BrainTrouble.verdict`. Red immediately.
        let v = BrainTrouble.verdict(reason: "auth_permanent", retryable: false,
                                     message: "rate limit: this key has been revoked",
                                     provider: .openAI)
        guard case .hard(let kind, _) = v else { Issue.record("not hard: \(v)"); return }
        #expect(kind == .credentialRejected)
    }

    @Test("every hard FailoverReason Moe knows maps to something a person can do")
    func hardReasonsAreActionable() {
        // Falsifier: add a reason to `hardReasons` with no `sentence` case —
        // it will not compile — or blank one of the four sentences.
        // Both maps, each on a provider for which it is hard at all —
        // `addressReasons` is hard only where the address is the person's own
        // (see `whoseAddressItIsDecides`).
        var both: [(String, BrainTrouble.Kind, BrainProviderKind)] = []
        for (r, k) in BrainTrouble.hardReasons { both.append((r, k, .anthropic)) }
        for (r, k) in BrainTrouble.addressReasons { both.append((r, k, .lmStudio)) }
        // Not `both.count == hardReasons.count + addressReasons.count`: that
        // is true by construction and could never fail. The loop below is the
        // check, and it is empty-safe only because a map that lost every entry
        // would take `hardReasonsAreActionable`'s siblings red first.
        #expect(!both.isEmpty)
        for (reason, kind, p) in both {
            let v = BrainTrouble.verdict(reason: reason, retryable: false, message: "", provider: p)
            guard case .hard(let got, let words) = v else { Issue.record("\(reason) not hard"); return }
            #expect(got == kind, Comment(rawValue: reason))
            #expect(words.contains("Settings"), Comment(rawValue: reason))
        }
    }

    // MARK: - The prose fallback, for the pin that carries no verdict

    @Test("with no structured verdict, the markers Hermes itself uses still classify")
    func proseFallbackWorks() {
        // Today's pin (e1dc67112a) computes `failure_reason` and drops it at
        // the api_server boundary, so this is the live path, not a fallback.
        //
        // Falsifier: empty `rejectedMarkers` / `outOfCreditMarkers` /
        // `unreachableMarkers`, or return `.unknown` before them.
        // The last one is on LM Studio rather than OpenAI on purpose: a
        // refused connection is only the person's to fix when the address is
        // theirs. See `whoseAddressItIsDecides`.
        let cases: [(String, BrainTrouble.Kind, BrainProviderKind)] = [
            ("Provider authentication failed (HTTP 401)", .credentialRejected, .openAI),
            ("Error code: 401 - Incorrect API key provided", .credentialRejected, .openAI),
            ("OAuth access token is invalid", .credentialRejected, .claudeCode),
            ("{'code': 'insufficient_quota'}", .outOfCredit, .openAI),
            ("HTTPConnectionPool: connection refused", .endpointUnreachable, .lmStudio),
        ]
        for (message, expected, p) in cases {
            let v = BrainTrouble.verdict(reason: nil, retryable: nil,
                                         message: message, provider: p)
            guard case .hard(let kind, _) = v else { Issue.record("not hard: \(message)"); return }
            #expect(kind == expected, Comment(rawValue: message))
        }
    }

    @Test("the two paths reach the same verdict, so neither can rot behind the other")
    func proseAndStructuredAgree() {
        // **This is the test that has to outlive the pin bump.** Today every
        // real failure takes the prose path, because the pin drops
        // `failure_reason`. The day somebody carries it through
        // `_hermes_extras`, every real failure takes the structured path and
        // the prose one stops being exercised by anything except this — so
        // from that day on, this is the only thing standing between the
        // fallback and silent rot.
        //
        // It is written as an agreement rather than two separate checks on
        // purpose: two paths asserted independently can both be green while
        // disagreeing about the same failure, and a person whose Moe was
        // updated would be told something different about an unchanged fault.
        //
        // Falsifier: change any marker list so it classifies one of these
        // differently from its `FailoverReason`, or drop a reason from
        // `hardReasons`. Red on the pair that disagrees, naming both.
        // The last two are the same fault on two providers, and they are here
        // because writing this test is what found the bug: the prose path
        // called "connection refused" hard while the structured path called
        // Hermes's `timeout` retryable, so a person would have been told one
        // thing today and the other after a pin bump, about an unchanged
        // fault. Both now route through `atThatAddress`.
        let pairs: [(prose: String, reason: String, provider: BrainProviderKind)] = [
            ("Provider authentication failed (HTTP 401)", "auth_permanent", .openAI),
            ("Error code: 401 - Incorrect API key provided", "auth_permanent", .openAI),
            ("{'code': 'insufficient_quota'}", "billing", .openAI),
            ("HTTPConnectionPool: connection refused", "timeout", .lmStudio),
            ("HTTPConnectionPool: connection refused", "timeout", .openAI),
        ]
        for (prose, reason, p) in pairs {
            let byProse = BrainTrouble.verdict(reason: nil, retryable: nil,
                                               message: prose, provider: p)
            // The structured path ignores the message entirely, which is the
            // point: it is handed the same prose so that a disagreement can
            // only come from the classification, never from the input.
            // `retryable: true` on the connection pairs is what Hermes really
            // says about `timeout` — the disagreement was real, not contrived.
            let byVerdict = BrainTrouble.verdict(reason: reason, retryable: true,
                                                 message: prose, provider: p)
            #expect(byProse == byVerdict,
                    "\(reason) on \(p.rawValue): prose \(byProse) vs verdict \(byVerdict)")
        }
    }

    @Test("a server on your own Mac that isn't running is yours to fix; a cloud API that isn't answering isn't")
    func whoseAddressItIsDecides() {
        // Same fault, two next steps. "LM Studio isn't running" is fixed by
        // starting LM Studio and by nothing else, so it is kept in Settings.
        // A cloud endpoint that did not answer comes back on its own, so
        // telling somebody to go and check an address they do not control
        // would send them nowhere.
        //
        // Falsifier: return `.hard` unconditionally from `atThatAddress`, or
        // drop the `usesBaseURL` test. Either turns one of these two red.
        let mine = BrainTrouble.verdict(reason: nil, retryable: nil,
                                        message: "connection refused", provider: .lmStudio)
        guard case .hard(let kind, _) = mine else { Issue.record("not hard: \(mine)"); return }
        #expect(kind == .endpointUnreachable)

        let theirs = BrainTrouble.verdict(reason: nil, retryable: nil,
                                          message: "connection refused", provider: .anthropic)
        guard case .temporary = theirs else { Issue.record("not temporary: \(theirs)"); return }
    }

    @Test("a TLS chain that won't verify stays hard wherever it happens")
    func tlsIsAlwaysHard() {
        // Unlike a refused connection, this fails identically on every retry
        // — Hermes classifies it non-retryable and prints "fix the
        // environment, then try again". So it is in `hardReasons`, not
        // `addressReasons`, and a cloud provider gets it too.
        //
        // Falsifier: move "ssl_cert_verification" into `addressReasons`.
        let v = BrainTrouble.verdict(reason: "ssl_cert_verification", retryable: false,
                                     message: "certificate verify failed", provider: .anthropic)
        guard case .hard(let kind, _) = v else { Issue.record("not hard: \(v)"); return }
        #expect(kind == .endpointUnreachable)
    }

    @Test("with no verdict and nothing recognisable, Moe keeps its old answer rather than guessing")
    func absentVerdictIsNotAGuess() {
        // The other half of the fallback contract. A pin that carries no
        // verdict and a message Moe cannot place must not be forced into one
        // of the four kinds — a wrong Settings row that never clears is worse
        // than none, because the person acts on it.
        //
        // Falsifier: make `verdict` return a `.hard` default instead of
        // `.unknown` at the end.
        let v = BrainTrouble.verdict(reason: nil, retryable: nil,
                                     message: "the model produced no output", provider: .openAI)
        #expect(v == .unknown)
        #expect(TurnError.personWords("the model produced no output", provider: .openAI).keep == nil)
    }

    @Test("a busy provider is read as busy, not as a dead key")
    func busyIsNotDead() {
        // Telling somebody their key is revoked when it is merely busy sends
        // them to cancel and re-issue a working credential. That is the worse
        // of the two mistakes, so the temporary markers are checked first.
        //
        // Falsifier: move the `temporaryMarkers` check below `rejectedMarkers`
        // in `verdict` — this message carries both "rate limit" and "401".
        let v = BrainTrouble.verdict(reason: nil, retryable: nil,
                                     message: "rate limit reached; see 401 docs", provider: .anthropic)
        guard case .temporary = v else { Issue.record("not temporary: \(v)"); return }
    }

    // MARK: - Never Claude

    @Test("a person on any provider is only ever told about that provider")
    func nobodyIsToldAboutSomebodyElse() {
        // The owner's explicit instruction: "Do not hardcode Claude." This
        // sweeps every sentence this file can produce, for every provider,
        // and fails if any of them names a service that is not the one the
        // person is paying for.
        //
        // Falsifier: write the word "Claude" into any `sentence` /
        // `whatIsWrong` / `temporarySentence` / `blockedSentence` case that
        // is not already provider-derived. Red on the first non-Claude row.
        for p in everyProvider {
            let others = everyProvider.filter { $0.shortName != p.shortName }.map(\.shortName)
            var lines = [BrainTrouble.temporarySentence(p), BrainTrouble.blockedSentence(p)]
            for kind in BrainTrouble.Kind.allCases {
                lines.append(BrainTrouble.sentence(kind, p))
                lines.append(BrainTrouble.whatIsWrong(kind, p))
            }
            // Case-insensitive on both sides: `shortName` is written for the
            // middle of a sentence ("your service") and `opening` capitalises
            // it when it starts one, so a case-sensitive sweep would miss the
            // one provider whose name is not a proper noun.
            for line in lines.map({ $0.lowercased() }) {
                for other in others.map({ $0.lowercased() }) {
                    #expect(!line.contains(other),
                            "\(p.rawValue) was told about \(other): \(line)")
                }
                #expect(line.contains(p.shortName.lowercased()), "\(p.rawValue) unnamed: \(line)")
            }
        }
    }

    @Test("a refusal names no single cause, because a 401 does not say which")
    func theRejectionIsHedged() {
        // The owner's Mac was wiped clean at 21:12 on 2026-09-15, so "there
        // is no credential at all" is his actual next state, not a
        // hypothetical — and a provider's 401 cannot tell a revoked key from
        // a mistyped one from one that was never sent. Naming one of the
        // three would be a guess presented as a fact; Hermes itself hedges
        // the same way (`_billing_terminal_label`'s "unverified").
        //
        // The Brain pane *can* tell, because it knows whether a key is
        // stored, and prefers "No key yet." — asserted by
        // scripts/test-hard-failures.sh, which reads the order of that
        // switch. Falsifier here: reword either branch to assert one cause,
        // e.g. "it's been revoked".
        for p in everyProvider where p.access != .localServer {
            let s = BrainTrouble.sentence(.credentialRejected, p)
            // Three possibilities offered, not one asserted.
            #expect(s.contains(" or "), "\(p.rawValue) asserted one cause: \(s)")
            #expect(!s.contains("it's been revoked"), Comment(rawValue: p.rawValue))
        }
    }

    @Test("a subscription and a key are told apart, because the fix is different")
    func planAndKeyAreDifferentSentences() {
        // "Get a new key" is useless to somebody on a monthly plan and
        // "sign in again" is useless to somebody holding an API key.
        //
        // Falsifier: collapse the `provider.access` switch in
        // `sentence(.credentialRejected, _)` to one branch.
        let plan = BrainTrouble.sentence(.credentialRejected, .codex)
        let key = BrainTrouble.sentence(.credentialRejected, .openAI)
        #expect(plan.contains("sign in"))
        #expect(key.contains("key"))
        #expect(!plan.contains("key"))
    }

    // MARK: - The Settings row

    @Test("the Settings row says what is wrong, and the pane's own next step says what to do")
    func settingsRowIsWhatPlusNext() {
        // Falsifier: inline advice into `whatIsWrong` — the row would then
        // carry the next step twice, in two wordings, and this fails because
        // `whatIsWrong` is no longer a strict prefix of `settingsRow`.
        for p in everyProvider {
            for kind in BrainTrouble.Kind.allCases {
                let what = BrainTrouble.whatIsWrong(kind, p)
                let row = BrainTrouble.settingsRow(kind, p)
                #expect(row.hasPrefix(what))
                #expect(row.hasSuffix(BrainGuide.find(p).nextStep))
            }
        }
    }

    @Test("a row is kept, survives being read back, and clears when the brain works again")
    func theRowPersistsAndClears() throws {
        // The reason it is kept at all: a chat message scrolls away, and the
        // next message fails the same way with nothing on screen saying why.
        //
        // Falsifier: make `BrainTrouble.clear` a no-op, or drop the
        // `BrainTrouble.clear()` call from `HermesBrain.finishTurn`'s
        // `error == nil` branch (that one is covered by
        // scripts/test-hard-failures.sh, which reads the call site).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-trouble-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("brain-trouble.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BrainTrouble.current(for: .openAI, at: url) == nil)
        BrainTrouble.record(.credentialRejected, provider: .openAI, at: url)
        let back = try #require(BrainTrouble.current(for: .openAI, at: url))
        #expect(back.kind == .credentialRejected)
        #expect(back.provider == BrainProviderKind.openAI.rawValue)
        BrainTrouble.clear(at: url)
        #expect(BrainTrouble.current(for: .openAI, at: url) == nil)
    }

    @Test("a row written against one provider is never shown against another")
    func aRowDoesNotFollowTheAccount() throws {
        // Changing account is one of the ways a person fixes this. A row that
        // followed them would tell them their brand-new key was refused.
        //
        // Falsifier: drop `rec.provider == provider.rawValue` from
        // `BrainTrouble.current`.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-trouble-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("brain-trouble.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        BrainTrouble.record(.outOfCredit, provider: .openAI, at: url)
        #expect(BrainTrouble.current(for: .openAI, at: url) != nil)
        #expect(BrainTrouble.current(for: .gemini, at: url) == nil)
        #expect(BrainTrouble.current(for: .claudeCode, at: url) == nil)
    }

    // MARK: - About the message, not about the account

    @Test("a safety refusal is said, and deliberately kept out of Settings")
    func aRefusalIsNotAnAccountProblem() {
        // A persistent "something is wrong with your account" row for a
        // request the provider simply would not answer would be wrong, and
        // could never clear, because there is nothing to fix.
        //
        // Falsifier: add "content_policy_blocked" to `hardReasons`.
        let v = BrainTrouble.verdict(reason: BrainTrouble.thisRequestReason, retryable: false,
                                     message: "blocked by safety policy", provider: .gemini)
        guard case .thisRequest(let words) = v else { Issue.record("not thisRequest: \(v)"); return }
        #expect(words.contains("Gemini"))
        let got = TurnError.personWords("blocked by safety policy", provider: .gemini,
                                        failureReason: BrainTrouble.thisRequestReason,
                                        failureRetryable: false)
        #expect(got.keep == nil)
        #expect(got.words == words)
    }

    // MARK: - Nothing credential-shaped reaches a screen

    @Test("a provider's 401 body never reaches the island with the key still in it")
    func credentialsAreNeverShown() {
        // Moe's own route is `api_server`, which Hermes lists in
        // `_GATEWAY_RAW_TEXT_PLATFORMS` — its redaction never runs on the way
        // here, so this side has to do it. OpenAI's 401 quotes the key back.
        //
        // Falsifier: `return message` at the end of `TurnError.personWords`.
        let body = "Error code: 401 - {'error': {'message': 'Incorrect API key provided: "
            + "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789'}}"
        let shown = TurnError.personWords(body)
        #expect(!shown.contains("sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz"))
        // And by the provider-aware route, where it becomes Moe's words.
        let words = TurnError.personWords(body, provider: .openAI)
        #expect(!words.words.contains("sk-proj-"))
        #expect(words.keep == .credentialRejected)
    }

    @Test("redaction covers the shapes Hermes redacts, and leaves ordinary prose alone")
    func redactionIsShapeBased() {
        // Falsifier: empty `BrainTrouble.secretPatterns`.
        for secret in ["sk-abcdefghijklmnopqrstuvwxyz", "ghp_abcdefghijklmnopqrstuvwxyz123",
                       "hf_abcdefghijklmnopqrstuvwxyz", "Bearer abcdefghijklmnopqrstuvwxyz"] {
            #expect(!BrainTrouble.redacted("failed: \(secret)").contains(secret), Comment(rawValue: secret))
        }
        let prose = "The model server is not responding."
        #expect(BrainTrouble.redacted(prose) == prose)
    }

    // MARK: - What already worked still works

    @Test("the work limit the person set outranks any provider verdict")
    func workLimitStillWins() {
        // They chose 5 minutes and Moe stopped at 5 minutes. That is not
        // their provider failing, however the brain worded it, and it must
        // not write a row telling them their key is dead.
        //
        // Falsifier: move the `WorkLimit` check below the `BrainTrouble`
        // switch in the provider-aware `personWords`.
        let got = TurnError.personWords("claude turn exceeded 302s", provider: .claudeCode,
                                        failureReason: "auth_permanent", failureRetryable: false)
        #expect(got.words.contains("Settings › Brain"))
        #expect(got.keep == nil)
    }

    @Test("a turn error Moe has no opinion about still gets the old translation")
    func unknownFallsBackToTheOldPath() {
        // Falsifier: return something other than `personWords(message)` from
        // the `.unknown` branch.
        let raw = "another turn is still running for session 1e495ecf-d44; try again"
        let got = TurnError.personWords(raw, provider: .claudeCode)
        #expect(got.words == TurnError.busy)
        #expect(got.keep == nil)
    }
}
