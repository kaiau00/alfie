import Foundation
import Testing
@testable import MoeBrain

/// `FixCode` is exactly the vocabulary of the Hermes this app pins — read
/// from that Hermes, not from a list typed here.
///
/// The pin is `HERMES_COMMIT` in scripts/install-hermes.sh (`HermesPin`), and
/// the vocabulary is `CODES` and `GRANTS` in that commit's
/// `tools/fix_reasons.py`. So a pin bump to a Hermes with a code the app does
/// not know turns this red, and so does a code the app knows that Hermes
/// dropped, or a grant whose owner or pane moved. The fork is found as a git
/// checkout that holds the pinned commit: `MOE_HERMES_FORK` alone when it is set, otherwise
/// ~/hermes-agent-fork, then ~/.hermes/hermes-agent. Not finding one is a
/// failure, not a skip: a vocabulary check that stands down on a Mac without
/// the fork reports green forever.
///
/// The app half — every `FixCode` has an answer in `PermissionGuide.forCode`,
/// and every grant's guide has this owner and pane — is
/// MoeAppTests/PermissionGuideFixCodeTests, which launches no process.
struct ToolFixVocabularyTests {

    struct Vocabulary {
        var codes: Set<String>
        /// code → (owner, pane)
        var grants: [String: (String, String)]
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func git(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Where to look for the fork. `MOE_HERMES_FORK`, when set, is the only
    /// place: a path someone chose that does not hold the pin must fail, not
    /// quietly pass on whatever ~/hermes-agent-fork happens to hold.
    static func candidates(env: [String: String], home: String) -> [String] {
        if let chosen = env["MOE_HERMES_FORK"], !chosen.isEmpty { return [chosen] }
        return ["\(home)/hermes-agent-fork", "\(home)/.hermes/hermes-agent"]
    }

    /// `tools/fix_reasons.py` at `pin` from the first candidate that has it,
    /// or the failure to report, which says how to get the commit.
    static func locate(pin: String, in candidates: [String]) -> Result<String, VocabularyNotFound> {
        for dir in candidates {
            let (status, text) = git(["-C", dir, "show", "\(pin):tools/fix_reasons.py"])
            if status == 0, !text.isEmpty { return .success(text) }
        }
        return .failure(VocabularyNotFound(message:
            "no checkout holds Hermes \(pin) (looked in \(candidates)). "
            + "Fetch it — git -C ~/hermes-agent-fork fetch fork — or set MOE_HERMES_FORK to a checkout that has it."))
    }

    struct VocabularyNotFound: Error { let message: String }

    static func pinnedFixReasons() throws -> String {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/install-hermes.sh"), encoding: .utf8)
        let pin = try #require(HermesPin.parse(script: script), "no HERMES_COMMIT pin in install-hermes.sh")
        switch locate(pin: pin, in: candidates(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())) {
        case .success(let text): return text
        case .failure(let why):
            Issue.record(Comment(rawValue: why.message))
            throw why
        }
    }

    /// An explicit `MOE_HERMES_FORK` is the only place looked, so a wrong one
    /// fails — and the failure says how to fetch the commit.
    @Test func anExplicitForkThatDoesNotExistFailsAndSaysHowToFetch() throws {
        let only = Self.candidates(env: ["MOE_HERMES_FORK": "/nonexistent"], home: "/Users/someone")
        #expect(only == ["/nonexistent"])
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/install-hermes.sh"), encoding: .utf8)
        let pin = try #require(HermesPin.parse(script: script))
        guard case .failure(let why) = Self.locate(pin: pin, in: only) else {
            Issue.record("/nonexistent was believed to hold Hermes \(pin)")
            return
        }
        #expect(why.message.contains("git -C ~/hermes-agent-fork fetch fork"), "\(why.message)")
        #expect(Self.candidates(env: [:], home: "/h") == ["/h/hermes-agent-fork", "/h/.hermes/hermes-agent"])
    }

    /// `NAME = "value"` constants, then the names inside `CODES = frozenset({…})`
    /// and `GRANTS: … = {…}`, resolved through the constants.
    static func vocabulary() throws -> Vocabulary {
        let py = try pinnedFixReasons()
        var constants: [String: String] = [:]
        let constRE = try NSRegularExpression(pattern: #"^([A-Z_]+) = "([a-z_]+)""#, options: [.anchorsMatchLines])
        let ns = py as NSString
        for m in constRE.matches(in: py, range: NSRange(location: 0, length: ns.length)) {
            constants[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        func block(_ start: String, _ end: String) throws -> String {
            let from = try #require(py.range(of: start), "no \(start) in fix_reasons.py")
            let to = try #require(py.range(of: end, range: from.upperBound..<py.endIndex))
            return String(py[from.upperBound..<to.lowerBound])
        }
        let codeNames = try block("CODES = frozenset({", "})")
            .components(separatedBy: CharacterSet(charactersIn: ", \n"))
            .filter { !$0.isEmpty }
        let codes = Set(try codeNames.map { try #require(constants[$0], "CODES names \($0), which is not a constant") })

        var grants: [String: (String, String)] = [:]
        let grantRE = try NSRegularExpression(pattern: #"([A-Z_]+): \((OWNER_[A-Z]+), "(Privacy_[A-Za-z]+)"\)"#)
        let g = try block("GRANTS: Dict[str, tuple] = {", "\n}") as NSString
        for m in grantRE.matches(in: g as String, range: NSRange(location: 0, length: g.length)) {
            let code = try #require(constants[g.substring(with: m.range(at: 1))])
            let owner = try #require(constants[g.substring(with: m.range(at: 2))])
            grants[code] = (owner, g.substring(with: m.range(at: 3)))
        }
        return Vocabulary(codes: codes, grants: grants)
    }

    @Test func theAppKnowsExactlyThePinnedHermesCodes() throws {
        let v = try Self.vocabulary()
        #expect(v.codes.count >= 17, "parsed only \(v.codes.count) codes: \(v.codes.sorted())")
        let app = Set(FixCode.allCases.map(\.rawValue))
        #expect(v.codes.subtracting(app).isEmpty, "Hermes sends codes the app ignores: \(v.codes.subtracting(app).sorted())")
        #expect(app.subtracting(v.codes).isEmpty, "the app knows codes Hermes never sends: \(app.subtracting(v.codes).sorted())")
    }

    /// Every grant Hermes names is `FixCode.grant`, owner and pane alike.
    @Test func theGrantsAreThePinnedHermesGrants() throws {
        let v = try Self.vocabulary()
        #expect(v.grants.count >= 9, "parsed only \(v.grants.count) grants")
        for (code, (owner, pane)) in v.grants {
            let fix = try #require(FixCode(rawValue: code))
            let grant = try #require(fix.grant, "\(code) is a grant in Hermes and not in the app")
            #expect(grant.owner.rawValue == owner, "\(code): Hermes says \(owner), the app \(grant.owner)")
            #expect(grant.pane == pane, "\(code): Hermes says \(pane), the app \(grant.pane)")
        }
        for fix in FixCode.allCases where fix.grant != nil {
            #expect(v.grants[fix.rawValue] != nil, "\(fix.rawValue) is a grant in the app and not in Hermes")
        }
    }
}
