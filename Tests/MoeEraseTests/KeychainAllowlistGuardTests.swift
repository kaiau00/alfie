import Foundation
import Testing
@testable import MoeErase

// The keychain allowlist guard (CLOUD-REMAINING D9.12).
//
// `MacEraseKeychain.allowlist` is the whole of what an erase deletes from the
// keychain. It is only honest while it keeps up with the code: a new item
// Moe starts storing that the list does not know about is an item an erase
// leaves behind — a person's token, on a Mac they were told was cleared.
//
// So this test reads the code, two ways:
//
//   1. **Every creation line.** Any line in Sources/, moe-home/ or the
//      runtime scripts/ (never scripts/test-*) that creates a keychain item —
//      `SecItemAdd`, `add-generic-password`, `add-internet-password`,
//      Python's `keyring.set_password` / `import keyring` — must name a
//      decided service (allowlist or notOurs) on that line, or carry an
//      `erase-allowlist: <name>` waiver on that line or the one above. A
//      name held in a variable, a `-s"attached"` argument, a `.js` file —
//      the review found the first version of this guard walked past all of
//      those. This rule does not care how the name is spelled; it asks the
//      line that creates the item.
//   2. **Every name.** Service names read next to `find/add/delete-…-password`,
//      in `…KEYCHAIN_SERVICE…` constants, Swift `…service…` constants and
//      fallbacks, and `kSecAttrService`, must be decided.
//
// The literal `keyring.` is NOT a creation form here: in this repo it is the
// ledger's ThreadKeyring (dozens of `keyring.key(…)` calls), and flagging it
// would bury the guard. Python's keyring library is matched by what creates
// with it: `keyring.set_password` and `import keyring`.
//
// And because a scanner that finds nothing passes forever, it is proven on
// the known names (it must find them where they are), on every shape the
// review found it missing, and on two lines it must NOT flag.

enum KeychainScan {
    static let repo: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/MoeEraseTests/<file>
        return url
    }()

    /// "cloud" is the official build's closed half; a tree without it (the
    /// open export) simply has nothing there to scan.
    static let roots = ["Sources", "moe-home", "scripts", "cloud"]
    static let extensions: Set<String> = ["swift", "sh", "py", "zsh", "bash", "js", "mjs", "cjs", ""]

    static func files() -> [URL] {
        var out: [URL] = []
        for root in roots {
            let base = repo.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in e {
                let rel = url.path.dropFirst(repo.path.count + 1)
                if rel.hasPrefix("scripts/test-") || rel.contains("/tests/") || rel.contains("/Tests/")
                    || rel.contains("/.build/")
                    || rel.contains("node_modules") || rel.contains("/.venv/") { continue }
                guard extensions.contains(url.pathExtension),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                out.append(url)
            }
        }
        return out
    }

    static var decided: Set<String> {
        Set((MacEraseKeychain.allowlist + MacEraseKeychain.devAllowlist).map(\.service))
            .union(MacEraseKeychain.notOurs.keys)
    }

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    /// The creation forms. A line with any of these creates (or documents
    /// creating) a keychain item, and must answer for its name.
    static let creation = ["SecItemAdd", "add-generic-password", "add-internet-password",
                           "keyring.set_password", "import keyring"]
    static let waiver = regex(#"erase-allowlist:\s*([^\s*]+)"#)

    /// `-s "name with spaces"`, `"-s", "name"` (Python/Swift/JS lists), `-s"attached"`.
    static let dashSDouble = regex(#"(?:^|[\s\[,(])(?:-s\s*|["']-s["']\s*,\s*)"([^"]*)""#)
    /// `-s 'name'`, `'-s', 'name'`, `-s'attached'`.
    static let dashSSingle = regex(#"(?:^|[\s\[,(])(?:-s\s*|["']-s["']\s*,\s*)'([^']*)'"#)
    /// `-s name`, unquoted.
    static let dashSBare = regex(#"(?:^|[\s\[,(])-s\s+([^\s"'][^\s"',\])]*)"#)
    /// `SERVICE=moe-x`, `local SERVICE="moe-x"`, `SERVICE="${X:-moe-x}"`.
    static let shellAssign = regex(#"\b[A-Z_]*SERVICE[A-Z_]*=["']?(?:\$\{[A-Z_]+:-)?([A-Za-z0-9_.:/@\-]+)"#)
    /// Python `…KEYCHAIN_SERVICE… = "a"` or `= ("a", "b")`.
    static let pyConst = regex(#"^\s*[A-Z_]*KEYCHAIN_SERVICES?\s*=\s*(.+)$"#)
    /// Swift `static let …service… = "x"` / `…Service = "x"`.
    static let swiftConst = regex(#"(?:static\s+)?let\s+\w*[sS]ervice\w*\s*(?::\s*String\s*)?=\s*"([^"]+)""#)
    /// Swift `?? "moe-x"` on a line that names a service.
    static let swiftFallback = regex(#"[Ss][Ee][Rr][Vv][Ii][Cc][Ee].*\?\?\s*"([^"]+)""#)
    static let kSec = regex(#"kSecAttrService[^"\n]*"([^"]+)""#)
    static let quoted = regex(#"["']([^"']+)["']"#)

    static func captures(_ re: NSRegularExpression, _ line: String) -> [String] {
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// The service names one file's text mentions.
    static func names(in text: String, fileExtension: String) -> [String] {
        let keychainFile = text.contains("generic-password") || text.contains("internet-password")
            || text.contains("kSecAttrService") || text.contains("KEYCHAIN_SERVICE")
            || creation.contains { text.contains($0) }
        guard keychainFile else { return [] }
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("-password") {
                for re in [dashSDouble, dashSSingle, dashSBare] { out += captures(re, line) }
            }
            out += captures(shellAssign, line)
            for rhs in captures(pyConst, line) { out += captures(quoted, rhs) }
            if fileExtension == "swift" {
                out += captures(swiftConst, line) + captures(swiftFallback, line) + captures(kSec, line)
            }
        }
        // A variable is not a name — rule 1 asks its creation line instead.
        return out.filter { !$0.hasPrefix("$") && !$0.hasPrefix("{") && !$0.isEmpty }
    }

    /// Everything wrong with one file: undecided names, and creation lines
    /// that name no decided service and carry no waiver for one.
    static func flagged(in text: String, fileExtension: String, file: String = "<text>") -> [String] {
        var problems: [String] = []
        let decided = Self.decided
        for name in names(in: text, fileExtension: fileExtension) where !decided.contains(name) {
            problems.append("\(file): undecided service name \(name)")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() where creation.contains(where: { line.contains($0) }) {
            if decided.contains(where: { line.contains($0) }) { continue }
            let waived = ([line] + (i > 0 ? [lines[i - 1]] : [])).flatMap { captures(waiver, $0) }
            if let bad = waived.first(where: { !decided.contains($0) }) {
                problems.append("\(file):\(i + 1): waiver names \(bad), which is on neither list")
            } else if waived.isEmpty {
                problems.append("\(file):\(i + 1): creates a keychain item without naming a decided service: "
                                + line.trimmingCharacters(in: .whitespaces))
            }
        }
        return problems
    }

    static func scanRepo() -> (problems: [String], names: [String: [String]]) {
        var problems: [String] = []
        var names: [String: [String]] = [:]
        for file in files() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let rel = String(file.path.dropFirst(repo.path.count + 1))
            problems += flagged(in: text, fileExtension: file.pathExtension, file: rel)
            for name in Self.names(in: text, fileExtension: file.pathExtension) { names[name, default: []].append(rel) }
        }
        return (problems, names)
    }
}

@Suite("The keychain allowlist keeps up with the code")
struct KeychainAllowlistGuardTests {

    @Test("every keychain name and every creation line in the code is decided")
    func everythingDecided() {
        let problems = KeychainScan.scanRepo().problems
        #expect(problems.isEmpty, """
            keychain items the erase has no decision for — add the service to \
            MacEraseKeychain.allowlist (the erase deletes it) or MacEraseKeychain.notOurs (with why not), \
            or put `erase-allowlist: <service>` on the creating line:
            \(problems.sorted().joined(separator: "\n"))
            """)
    }

    @Test("the scanner finds the names it must, where they are — it is not reading nothing")
    func scannerSeesTheKnownNames() {
        let found = KeychainScan.scanRepo().names
        let expected: [String: String] = [
            "moe-child-oauth": "Sources/Moe/Onboarding/ClaudeSignIn.swift",
            "moe-telegram-bot": "moe-home/hermes/configure-hermes.py",
            "moe-gmail": "moe-home/connectors/gmail.py",
            "moe-google-docs": "scripts/connect-drive-docs.sh",
            "assemblyai-api-key": "Sources/Moe/Voice/PremiumVoiceCredentials.swift",
            "Claude Code-credentials": "moe-home/doctor.sh",
        ]
        for (name, file) in expected {
            #expect(found[name]?.contains(file) == true, "the scanner did not find \(name) in \(file); found: \(found[name] ?? [])")
        }
        // The closed half's Composio key, when this tree has the closed half.
        if FileManager.default.fileExists(atPath: KeychainScan.repo.appendingPathComponent("cloud").path) {
            #expect(found["moe-composio-scoped"]?.contains { $0.hasSuffix("/ComposioKeychain.swift") } == true,
                    "the scanner did not find moe-composio-scoped in the closed half; found: \(found["moe-composio-scoped"] ?? [])")
        }
        #expect(KeychainScan.files().count > 50, "the scanner walked almost nothing")
        // The .mjs files are the site's playground tests, which only the private tree has.
        if FileManager.default.fileExists(atPath: KeychainScan.repo.appendingPathComponent("scripts/playground-tests").path) {
            #expect(KeychainScan.files().contains { $0.pathExtension == "mjs" }, "the .js/.mjs files are not scanned")
        }
    }

    @Test("every shape of a new keychain item is flagged", arguments: [
        ("x.sh", "security add-generic-password -U -s moe-new-a -a me -w pw"),
        ("x.sh", "security find-generic-password -s \"moe-new-b\" -w"),
        ("x.sh", "security find-generic-password -s 'moe-new-b2 with space' -w"),
        ("x.sh", "SERVICE=\"${MOE_X:-moe-new-c}\"\nsecurity find-generic-password -s \"$SERVICE\""),
        ("x.py", "r = run([\"security\", \"add-generic-password\", \"-s\", \"moe-new-d\", \"-a\", \"x\"])"),
        ("x.py", "FOO_KEYCHAIN_SERVICES = (\"moe-new-e\", \"moe-new-f\")"),
        ("x.swift", "static let fooService = \"moe-new-g\"\n// generic-password"),
        ("x.swift", "let s = TestHooks.env(\"MOE_X_SERVICE\") ?? \"moe-new-h\"\n// generic-password"),
        ("x.swift", "q[kSecAttrService as String] = \"moe-new-i\""),
        // The six the review found the first scanner walking past:
        ("x.swift", "let svc = makeName()\nq[kSecAttrService as String] = svc\nlet status = SecItemAdd(q as CFDictionary, nil)"),
        ("x.swift", "let tokenName = TestHooks.env(\"X\") ?? \"moe-new-j\"\n_ = run([\"add-generic-password\", \"-s\", tokenName])"),
        ("x.py", "import keyring\nkeyring.set_password(\"moe-new-k\", \"user\", secret)"),
        ("x.sh", "SVC=moe-new-l\nsecurity add-generic-password -s \"$SVC\" -a x -w y"),
        ("x.sh", "security add-generic-password -s\"moe-new-m\" -a x -w y"),
        ("x.js", "execFileSync('security', ['add-generic-password', '-s', 'moe-new-n', '-a', 'x', '-w', pw])"),
        ("x.mjs", "await run('security', ['add-generic-password', '-a', 'x', '-s', name, '-w', pw])"),
        // A waiver that names something undecided is itself a finding.
        ("x.sh", "# erase-allowlist: moe-new-o\nsecurity add-generic-password -s \"$SVC\" -a x -w y"),
    ])
    func scannerShapes(file: String, text: String) {
        let problems = KeychainScan.flagged(in: text, fileExtension: (file as NSString).pathExtension)
        #expect(!problems.isEmpty, "not flagged: \(text)")
    }

    @Test("and two lines it must not flag: a decided name, and a waiver for one", arguments: [
        ("x.sh", "security add-generic-password -a moe -s moe-child-oauth -T /usr/bin/security -w \"$token\""),
        ("x.sh", "# erase-allowlist: moe-gmail\nsecurity add-generic-password -U -s \"$SERVICE\" -a \"$EMAIL\" -w pw"),
    ])
    func scannerAccepts(file: String, text: String) {
        #expect(KeychainScan.flagged(in: text, fileExtension: "sh").isEmpty)
    }

    @Test("every allowlist entry is narrow: a moe- service, or pinned to Alfie's account")
    func entriesAreNarrow() {
        for entry in MacEraseKeychain.allowlist + MacEraseKeychain.devAllowlist {
            #expect(!entry.service.isEmpty)
            #expect(entry.service.hasPrefix("moe-") || entry.account != nil,
                    "\(entry.service) is not Alfie's by name, so it must name Alfie's account")
            #expect(MacEraseKeychain.notOurs[entry.service] == nil, "\(entry.service) is on both lists")
        }
        for never in ["Claude Code-credentials", "https://sparkle-project.org"] {
            #expect(!MacEraseKeychain.allowlist.contains { $0.service == never })
        }
    }
}
