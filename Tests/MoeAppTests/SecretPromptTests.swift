import Foundation
@testable import Moe
import MoeDesign
import Testing

/// The password window (ticket #17): Hermes hands it one JSON object and
/// reads one back (Sources/MoeDesign/SecretPrompt.swift). The process-level
/// half — reached by name, timeout, SIGTERM, the caller going away, out of
/// the built binary — is scripts/test-secret-prompt.sh.
struct SecretPromptTests {

    private func parse(_ json: String) -> Result<SecretRequest, SecretRequest.Problem> {
        SecretRequest.parse(Data(json.utf8))
    }

    private func request(_ json: String) throws -> SecretRequest {
        try parse(json).get()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Reading the request

    @Test func aLoginNamesItsSiteAndAsksForBothBoxes() throws {
        let r = try request(#"{"kind":"login","origin":"https://www.Fazier.com/login?x=1","label":"Fazier","username":"izzy@example.com"}"#)
        #expect(r.kind == .login)
        #expect(r.site == "fazier.com")
        #expect(r.fields == [.username, .password])
        #expect(r.username == "izzy@example.com")
        #expect(r.headline == "Save your login for fazier.com")
    }

    @Test func eachKindHasItsOwnWords() throws {
        #expect(try request(#"{"kind":"code","origin":"https://fazier.com"}"#).headline == "Sign-in code for fazier.com")
        #expect(try request(#"{"kind":"code","origin":"https://fazier.com"}"#).fields == [.code])
        #expect(try request(#"{"kind":"unlock"}"#).headline == "Unlock your saved logins")
        #expect(try request(#"{"kind":"unlock"}"#).fields == [.password])
    }

    /// Hermes's passcode mode (2026-09-29) asks as kind "code" with this exact
    /// message; a passcode the person knows is not a code the site sent.
    @Test func aPasscodeIsNotCalledASignInCode() throws {
        let r = try request(#"{"kind":"code","origin":"https://x.com","label":"x.com","message":"Enter your passcode for x.com (4 digits). Moe types it into the page without seeing it.","fields":["code"]}"#)
        #expect(r.headline == "Your passcode for x.com")
        #expect(r.explanation.contains("passcode or PIN you use on x.com"))
        #expect(!r.explanation.contains("sent you"))
        #expect(r.fields == [.code])
    }

    /// Fields come back in one order whatever order they were sent in, and
    /// a kind cannot be dressed in another kind's boxes: a "sign-in code"
    /// window over a password box is a window that lies.
    @Test func fieldsMustFitTheKind() throws {
        #expect(try request(#"{"kind":"login","origin":"https://a.com","fields":["password","username"]}"#).fields
                == [.username, .password])
        #expect(try request(#"{"kind":"login","origin":"https://a.com","fields":["password"]}"#).fields == [.password])
        #expect(parse(#"{"kind":"login","origin":"https://a.com","fields":["username"]}"#) == .failure(.badFields))
        #expect(parse(#"{"kind":"code","origin":"https://a.com","fields":["password"]}"#) == .failure(.badFields))
        #expect(parse(#"{"kind":"unlock","fields":["code"]}"#) == .failure(.badFields))
        #expect(parse(#"{"kind":"login","origin":"https://a.com","fields":["pin"]}"#) == .failure(.badFields))
        #expect(parse(#"{"kind":"login","origin":"https://a.com","fields":"password"}"#) == .failure(.badFields))
    }

    /// No site, no window: the site is the headline.
    @Test func aLoginOrACodeWithoutAWebSiteIsRefused() {
        #expect(parse(#"{"kind":"login"}"#) == .failure(.badOrigin))
        #expect(parse(#"{"kind":"login","origin":"javascript:alert(1)"}"#) == .failure(.badOrigin))
        #expect(parse(#"{"kind":"code","origin":"file:///etc/passwd"}"#) == .failure(.badOrigin))
        #expect(parse(#"{"kind":"code","origin":"fazier.com"}"#) == .failure(.badOrigin))
        #expect(parse(#"{"kind":"steal"}"#) == .failure(.badKind))
        #expect(parse("password=hunter2") == .failure(.notJSON))
        #expect(parse(#"["login"]"#) == .failure(.notJSON))
    }

    /// What a page or a model writes cannot reorder or hide text, and the
    /// headline is built from the origin alone.
    @Test func wordsFromTheRequestCannotSteerTheWindow() throws {
        let r = try request(#"{"kind":"login","origin":"https://evil.example","label":"Google‮ moc.elgoog","message":"line one\nline two\u0007"}"#)
        #expect(!r.label.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!r.message.unicodeScalars.contains { $0.value == 0x07 })
        #expect(r.message.contains("\n"))
        #expect(r.headline == "Save your login for evil.example")
    }

    @Test func aLookAlikeAddressIsFlagged() throws {
        let r = try request(#"{"kind":"login","origin":"https://pаypal.com"}"#)  // Cyrillic а
        #expect(r.siteHasForeignLetters)
        #expect(try !request(#"{"kind":"login","origin":"https://paypal.com"}"#).siteHasForeignLetters)
    }

    // MARK: - The answer

    @Test func aSavedLoginIsExactlyTheContractsObject() throws {
        let r = try request(#"{"kind":"login","origin":"https://fazier.com"}"#)
        let a = r.answer([.username: "  izzy@example.com ", .password: " pa ss\"word/ ", .code: "leftover"])
        #expect(a.ok)
        #expect(a.exitCode == 0)
        let o = try object(a.json)
        #expect(o["ok"] as? Bool == true)
        #expect(o["username"] as? String == "izzy@example.com")
        // A password goes as typed: spaces, quotes and slashes are characters.
        #expect(o["password"] as? String == " pa ss\"word/ ")
        #expect(o["code"] == nil, "only the fields asked for")
        #expect(Set(o.keys) == ["ok", "username", "password"])
        #expect(a.json.last == UInt8(ascii: "\n"))
        #expect(a.json.filter { $0 == UInt8(ascii: "\n") }.count == 1, "one line")
    }

    @Test func aCodeLosesItsSpacesAndAnUnlockIsAPassword() throws {
        let code = try request(#"{"kind":"code","origin":"https://fazier.com"}"#).answer([.code: " 123 456 "])
        #expect(try object(code.json)["code"] as? String == "123456")
        #expect(Set(try object(code.json).keys) == ["ok", "code"])
        let unlock = try request(#"{"kind":"unlock"}"#).answer([.password: "master"])
        #expect(Set(try object(unlock.json).keys) == ["ok", "password"])
    }

    @Test func nothingTypedIsNotAnAnswer() throws {
        let r = try request(#"{"kind":"login","origin":"https://fazier.com"}"#)
        #expect(!r.canSubmit([.username: "izzy", .password: ""]))
        #expect(!r.canSubmit([.username: "  ", .password: "x"]))
        #expect(r.canSubmit([.username: "izzy", .password: " "]))
        #expect(!r.answer([.username: "izzy"]).ok)
    }

    @Test func declinedAnswersAreOkFalseExitOne() throws {
        for (reason, word) in [(SecretAnswer.Reason.cancelled, "cancelled"), (.timeout, "timeout")] {
            let a = SecretAnswer.declined(reason)
            #expect(a.exitCode == 1)
            let o = try object(a.json)
            #expect(o["ok"] as? Bool == false)
            #expect(o["reason"] as? String == word)
            #expect(Set(o.keys) == ["ok", "reason"])
        }
        #expect(String(decoding: SecretAnswer.declined(.cancelled).json, as: UTF8.self)
                == "{\"ok\":false,\"reason\":\"cancelled\"}\n")
    }

    /// What may be logged names fields, never values — not the password,
    /// not the code, not the username.
    @Test func noLogLineCarriesASecret() throws {
        let r = try request(#"{"kind":"login","origin":"https://fazier.com","username":"izzy.private@example.com"}"#)
        let a = r.answer([.username: "izzy.private@example.com", .password: "hunter2-SECRET"])
        for line in [r.logLine, a.summary] {
            #expect(!line.contains("hunter2"))
            #expect(!line.contains("izzy.private"))
        }
        #expect(a.summary == "secret-prompt answered fields=username,password")
        let c = try request(#"{"kind":"code","origin":"https://fazier.com"}"#).answer([.code: "918273"])
        #expect(!c.summary.contains("918273"))
        // And the one line SecretMain writes to stderr is built only from these.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("Sources/MoeConfirm/SecretMain.swift"),
                              encoding: .utf8)
        let stderrWrites = main.components(separatedBy: "\n").filter { $0.contains("standardError.write") }
        #expect(!stderrWrites.isEmpty)
        for w in stderrWrites {
            #expect(w.contains("summary") || w.contains("logLine") || w.contains("did not parse (\\(problem))"),
                    "stderr carries only summary/logLine: \(w)")
        }
    }

    // MARK: - How it is reached

    @Test func reachedByItsNameOrByAFlag() {
        #expect(SecretRequest.isSecretInvocation(argv: ["/Applications/Memoe Dev.app/Contents/MacOS/moe-secret"]))
        #expect(SecretRequest.isSecretInvocation(argv: ["/x/moe-confirm", "--secret"]))
        #expect(!SecretRequest.isSecretInvocation(argv: ["/Applications/Memoe.app/Contents/MacOS/moe-confirm"]))
        #expect(!SecretRequest.isSecretInvocation(argv: ["/x/moe-confirm", "Gmail", "--secret-ish"]))
    }

    @Test func theTestSeamOnlyEverShortensTheWait() {
        #expect(SecretRequest.timeout == 300)
        #expect(SecretRequest.timeout(environment: [:]) == 300)
        #expect(SecretRequest.timeout(environment: ["MOE_SECRET_TIMEOUT_FOR_TESTS": "2"]) == 2)
        #expect(SecretRequest.timeout(environment: ["MOE_SECRET_TIMEOUT_FOR_TESTS": "99999"]) == 300)
    }

    // MARK: - Hermes is told where the window is

    /// The gateway's environment names the `moe-secret` inside the app —
    /// as a bare path, space and all — and never one it inherited.
    @MainActor @Test func hermesIsToldWhereTheWindowIs() throws {
        try StallGuardConductorTests.requireScratchHome()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString)")
        let macos = root.appendingPathComponent("Memoe Dev.app/Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let link = macos.appendingPathComponent("moe-secret")
        try "#!/bin/sh\nexit 1\n".write(to: link, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.path)

        let env = HermesSupervisor.childEnvironment(token: "", executableDirectory: macos)
        #expect(env["HERMES_SECRET_PROMPT_CMD"] == link.path)
        #expect(env["HERMES_SECRET_PROMPT_CMD"]?.contains("Memoe Dev.app/") == true)
        #expect(env["HERMES_SECRET_PROMPT_CMD"]?.hasPrefix("\"") == false, "a path, not a quoted shell word")

        // Inherited, with no window in the app: removed, not passed on.
        setenv("HERMES_SECRET_PROMPT_CMD", "/tmp/not-moe", 1)
        defer { unsetenv("HERMES_SECRET_PROMPT_CMD") }
        let bare = HermesSupervisor.childEnvironment(token: "", executableDirectory: root)
        #expect(bare["HERMES_SECRET_PROMPT_CMD"] == nil)
        let planted = HermesSupervisor.childEnvironment(token: "", executableDirectory: macos)
        #expect(planted["HERMES_SECRET_PROMPT_CMD"] == link.path)
    }

    /// build.sh makes the link, inside the bundle, next to the card it runs.
    @Test func theBundleCarriesTheLink() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        #expect(build.contains(#"ln -s moe-confirm "$APP/Contents/MacOS/moe-secret""#))
    }
}
