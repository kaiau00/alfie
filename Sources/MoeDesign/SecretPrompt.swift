import Foundation

/// The little window a person types a password or a sign-in code into, so
/// Moe can store it without ever seeing it (ticket #17, owner-approved
/// 2026-09-25).
///
/// Hermes runs the program named by `HERMES_SECRET_PROMPT_CMD` — Moe points
/// it at `Contents/MacOS/moe-secret` inside the app, a link to `moe-confirm`
/// — hands it ONE JSON object on stdin and reads ONE JSON object back on
/// stdout:
///
///     in:  {"kind": "login"|"code"|"unlock", "origin": "https://…",
///           "label": "…", "username": "…", "message": "…",
///           "fields": ["username","password"] | ["code"] | ["password"]}
///     out: {"ok": true, "username": "…", "password": "…"}
///          {"ok": true, "code": "…"}
///          {"ok": true, "password": "…"}            (unlock)
///          {"ok": false, "reason": "cancelled" | "timeout" | …}
///
/// Exit 0 with `ok: true`, 1 with anything else. The secret travels on
/// stdout and nowhere else: never argv, never the environment, never a log
/// line, never the pasteboard. That is why everything a log may say about a
/// request or an answer is produced HERE, by `logLine` and `summary`, which
/// are built from field names and never from values — so a test can hold
/// them to it.
///
/// Parsing and encoding live in this module rather than in MoeConfirm so
/// they are unit tests, not a window someone has to click.
public struct SecretRequest: Equatable {
    public enum Kind: String, CaseIterable {
        /// Save a login: a username and a password, for one site.
        case login
        /// A one-time sign-in code the site sent the person.
        case code
        /// The password that opens the person's password manager.
        case unlock
    }

    public enum Field: String, CaseIterable {
        case username, password, code

        /// Whether the field is drawn masked. Everything but the username.
        public var isSecret: Bool { self != .username }
    }

    public var kind: Kind
    /// The origin as Hermes sent it.
    public var origin: String
    /// The site, as the person reads it: the host, lower-cased, without a
    /// leading `www.`. Empty only for an unlock, which is not about a site.
    public var site: String
    /// The host contains letters outside plain ASCII — which is how a
    /// look-alike address is spelled, so the window says so.
    public var siteHasForeignLetters: Bool
    public var label: String
    /// Prefilled into the username field. Not a secret.
    public var username: String
    /// Hermes's own sentence, shown small. Never the headline: the headline
    /// is built here, from the site, so nothing a page or a model writes can
    /// change which site the person believes they are typing for.
    public var message: String
    public var fields: [Field]

    /// The longest the window waits for a person before answering
    /// `timeout` by itself.
    public static let timeout: TimeInterval = 300

    /// Tests only, and only ever SHORTER than `timeout`.
    public static func timeout(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["MOE_SECRET_TIMEOUT_FOR_TESTS"],
              let seconds = TimeInterval(raw), seconds > 0 else { return timeout }
        return min(seconds, timeout)
    }

    /// Is this process being run as the secret window? Either by name —
    /// `moe-secret`, the link Hermes is pointed at, because the contract is
    /// a program with no arguments — or with `--secret`, for a person
    /// trying it by hand.
    public static func isSecretInvocation(argv: [String]) -> Bool {
        if argv.dropFirst().contains("--secret") { return true }
        guard let first = argv.first else { return false }
        return (first as NSString).lastPathComponent == "moe-secret"
    }

    public enum Problem: Error, Equatable {
        case notJSON
        case badKind
        case badOrigin
        case badFields
    }

    public static func defaultFields(for kind: Kind) -> [Field] {
        switch kind {
        case .login: return [.username, .password]
        case .code: return [.code]
        case .unlock: return [.password]
        }
    }

    /// The fields a kind may ask for. A request for a login that asks for a
    /// "code", or a code that asks for a password, is refused rather than
    /// drawn: the window's words are chosen by kind, and a window that says
    /// "sign-in code" over a password box is a window that lies.
    private static func allowed(_ fields: [Field], for kind: Kind) -> Bool {
        switch kind {
        case .login: return fields.contains(.password) && !fields.contains(.code)
        case .code: return fields == [.code]
        case .unlock: return fields == [.password]
        }
    }

    public static func parse(_ data: Data) -> Result<SecretRequest, Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return .failure(.notJSON) }
        guard let rawKind = dict["kind"] as? String, let kind = Kind(rawValue: rawKind) else {
            return .failure(.badKind)
        }
        let origin = (dict["origin"] as? String) ?? ""
        let site = Self.site(of: origin)
        // A login or a code is FOR a site, and the site is the headline. No
        // site, no window: "save your login for (nothing)" would ask a
        // person to trust a sentence with a hole where the fact goes.
        if kind != .unlock && site == nil { return .failure(.badOrigin) }
        if kind == .unlock && !origin.isEmpty && site == nil { return .failure(.badOrigin) }

        var fields: [Field]
        if let raw = dict["fields"] {
            guard let list = raw as? [Any] else { return .failure(.badFields) }
            fields = []
            for item in list {
                guard let name = item as? String, let field = Field(rawValue: name) else {
                    return .failure(.badFields)
                }
                if !fields.contains(field) { fields.append(field) }
            }
            // Always in the same order on screen, whatever order they came in.
            fields.sort { Field.allCases.firstIndex(of: $0)! < Field.allCases.firstIndex(of: $1)! }
        } else {
            fields = defaultFields(for: kind)
        }
        guard allowed(fields, for: kind) else { return .failure(.badFields) }

        return .success(SecretRequest(
            kind: kind,
            origin: origin,
            site: site ?? "",
            siteHasForeignLetters: (site ?? "").unicodeScalars.contains { !$0.isASCII },
            label: Self.plain((dict["label"] as? String) ?? "", limit: 120, lines: false),
            username: Self.plain((dict["username"] as? String) ?? "", limit: 320, lines: false),
            message: Self.plain((dict["message"] as? String) ?? "", limit: 400, lines: true),
            fields: fields))
    }

    /// The host of an http(s) origin, as a person reads it, or nil.
    public static func site(of origin: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        // Percent-encoded hosts (what URLComponents makes of non-ASCII) are
        // decoded, so the look-alike warning sees the real letters.
        host = host.removingPercentEncoding ?? host
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") && host.count > 4 { host.removeFirst(4) }
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        return host
    }

    /// One line (or a few), with nothing that draws invisibly or reorders
    /// text: controls, format characters (the bidi overrides among them).
    static func plain(_ text: String, limit: Int, lines: Bool) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" { out += lines ? "\n" : " "; continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.count > limit ? String(out.prefix(limit - 1)) + "…" : out
    }

    // MARK: - Words

    /// A code the person already KNOWS (a passcode or PIN the site asks for),
    /// not one the site sent. Hermes asks for it as kind "code" with a message
    /// that says so ("Enter your passcode for x.com…"), and "Sign-in code for"
    /// over a passcode is a window that says the wrong thing.
    public var isPasscode: Bool {
        guard kind == .code else { return false }
        return message.range(of: #"\b(passcode|pin)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The headline. Built from the site alone.
    public var headline: String {
        switch kind {
        case .login: return "Save your login for \(site)"
        case .code: return isPasscode ? "Your passcode for \(site)" : "Sign-in code for \(site)"
        case .unlock: return site.isEmpty ? "Unlock your saved logins" : "Unlock your saved logins for \(site)"
        }
    }

    /// One plain sentence under the headline: what happens to what is typed.
    public var explanation: String {
        switch kind {
        case .login:
            return "Type it here and Moe stores it without seeing it. It is only ever filled in on \(site)."
        case .code:
            if isPasscode {
                return "Type the passcode or PIN you use on \(site). Moe enters it for you without seeing it."
            }
            return "Type the code \(site) sent you. Moe enters it on \(site) for you."
        case .unlock:
            return "The password for your password manager. Moe uses it to open your saved logins and never sees it."
        }
    }

    public func title(of field: Field) -> String {
        switch field {
        case .username: return "Username or email"
        case .password: return kind == .unlock ? "Master password" : "Password"
        case .code: return "Code"
        }
    }

    /// What a log may say about this request. Field names and the site —
    /// never a username, never a value.
    public var logLine: String {
        "secret-prompt kind=\(kind.rawValue) site=\(site.isEmpty ? "-" : site) fields=\(fields.map(\.rawValue).joined(separator: ","))"
    }

    /// Whether the person has typed enough to save. A username the site
    /// asked for must be there; a password or code must not be empty.
    public func canSubmit(_ values: [Field: String]) -> Bool {
        fields.allSatisfy { field in
            let value = values[field] ?? ""
            switch field {
            case .password: return !value.isEmpty
            case .username, .code: return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// The answer for what was typed: exactly the fields asked for, nothing
    /// else. Passwords go as typed — a leading space is a real character in
    /// a password. A username loses its outer spaces; a code loses every
    /// space, because "123 456" is how people copy "123456".
    public func answer(_ values: [Field: String]) -> SecretAnswer {
        guard canSubmit(values) else { return .declined(.cancelled) }
        var out: [Field: String] = [:]
        for field in fields {
            let value = values[field] ?? ""
            switch field {
            case .password: out[field] = value
            case .username: out[field] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .code: out[field] = value.filter { !$0.isWhitespace }
            }
        }
        return .entered(out)
    }
}

public enum SecretAnswer: Equatable {
    public enum Reason: String {
        /// The person pressed Cancel or Escape, closed it, or it was closed
        /// for them (a quit, SIGTERM, whoever asked went away).
        case cancelled
        /// Nobody answered within `SecretRequest.timeout`.
        case timeout
        /// The request could not be read. Nothing was shown.
        case invalid
        /// There is no screen to ask on. Nothing was shown.
        case unavailable
    }

    case entered([SecretRequest.Field: String])
    case declined(Reason)

    public var ok: Bool { if case .entered = self { return true } else { return false } }

    /// 0 for an answer, 1 for anything else — the contract's two statuses.
    public var exitCode: Int32 { ok ? 0 : 1 }

    /// The one JSON object that goes on stdout, newline-terminated.
    public var json: Data {
        var object: [String: Any] = ["ok": ok]
        switch self {
        case .entered(let values):
            for (field, value) in values { object[field.rawValue] = value }
        case .declined(let reason):
            object["reason"] = reason.rawValue
        }
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"reason":"invalid"}"#.utf8)
        return data + Data("\n".utf8)
    }

    /// What a log may say about an answer: which fields came back, never
    /// what was in them.
    public var summary: String {
        switch self {
        case .entered(let values):
            let names = SecretRequest.Field.allCases.filter { values[$0] != nil }.map(\.rawValue)
            return "secret-prompt answered fields=\(names.joined(separator: ","))"
        case .declined(let reason):
            return "secret-prompt not answered reason=\(reason.rawValue)"
        }
    }
}
