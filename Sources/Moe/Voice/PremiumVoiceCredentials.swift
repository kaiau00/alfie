import Foundation
import MoeVoice

// Premium voice: the credentials, and nothing that speaks or listens.
//
// Moe can hear through AssemblyAI Universal-3.5 Pro Realtime and speak through
// Inworld TTS-2 Flash. The STT and TTS backends ask this file for one
// credential per socket and tell it what the socket spent; whether — the
// setting, the plan, the allowance, the backoff — is answered here so neither
// backend grows a second copy of the rule. On any refusal the local Parakeet
// and Kokoro carry on.
//
// Two sources. Developer keys from the login keychain
// (`Config.cloudVoiceDeveloperKeys`), in every build. And, in the official
// build, credentials Memoe's cloud mints per socket on the paid plans: that
// half is closed and plugs in as `CloudVoice.edge`. A build without it has
// developer keys or the voice on this Mac, nothing else.

enum CloudVoiceKind: String, Codable, Sendable { case stt, tts }

struct CloudVoiceAllowance: Codable, Sendable, Equatable {
    let unit: String
    let limit: Int
    let used: Int
    let resetsAt: Date
}

struct CloudVoiceCredential: Sendable {
    let kind: CloudVoiceKind
    let token: String
    /// For `.stt` this is the AssemblyAI socket with `sample_rate`,
    /// `speech_model`, `mode` and `token` already in the query; the STT
    /// backend may append `keyterms_prompt` (the name list) and nothing here
    /// does, so that the list stays the backend's to build. For `.tts` it is
    /// Inworld's `voice:streamBidirectional` socket and the TTS backend adds
    /// `Authorization: Bearer <token>` itself.
    let socketURL: URL
    let expiresAt: Date
    let allowance: CloudVoiceAllowance?
    /// Where the mint's time went, when the source measured it, so the
    /// backend's one timing line can say so. Nil from the edge source.
    /// Additive and defaulted: no call site of the contract above changes.
    var minted: CloudVoiceMintTiming? = nil
}

struct CloudVoiceMintTiming: Sendable, Equatable {
    let keychainMs: Int
    let requestMs: Int
    var described: String { "keychain \(keychainMs) ms, request \(requestMs) ms" }
}

enum CloudVoiceUnavailable: Error, Equatable {
    case notEntitled          // 403 or local tier says free
    case allowanceSpent(resetsAt: Date?)   // 429
    case notConfigured(String) // 503
    case offline              // no network / edge unreachable
    case disabled             // Settings toggle off
}

protocol CloudVoiceCredentials: Sendable {
    /// One credential per socket. Throws `CloudVoiceUnavailable`; callers fall back to local and must not retry in a loop.
    func credential(for kind: CloudVoiceKind) async throws -> CloudVoiceCredential
    /// After a socket closes. Fire-and-forget; never throws.
    func report(kind: CloudVoiceKind, sttSeconds: Double, ttsCharacters: Int) async
}

/// The cloud-minted source and its rules (setting, plan, allowance,
/// backoff), supplied by the closed half at launch. Nil in a build without it.
protocol CloudVoiceEdge: Sendable {
    var credentials: any CloudVoiceCredentials { get }
    func mayUse(_ kind: CloudVoiceKind) -> Bool
    func statusLine(now: Date, tier: String?) -> String
    func whyNotUsable() -> String
}

enum CloudVoice {
    /// Set once at launch by the closed half (`CloudEdition`); nil otherwise.
    nonisolated(unsafe) static var edge: (any CloudVoiceEdge)?

    /// The live source: developer keys when `Config.cloudVoiceDeveloperKeys`
    /// is on, else the cloud's, else one that always says "not entitled".
    static var shared: any CloudVoiceCredentials {
        if Config.load().cloudVoiceDeveloperKeys { return developer }
        return edge?.credentials ?? NoCloudVoice()
    }

    /// Fast local answer with no network: is the premium voice worth asking
    /// for right now?
    static func mayUse(_ kind: CloudVoiceKind) -> Bool {
        let config = Config.load()
        guard config.cloudVoice else { return false }
        // Developer keys stand in for a plan.
        if config.cloudVoiceDeveloperKeys { return true }
        return edge?.mayUse(kind) ?? false
    }

    private static let developer = DeveloperVoiceCredentials(settingOn: { Config.load().cloudVoice })

    /// One line, no network: what the switch is doing right now. `tier`
    /// overrides the cached plan, for `--settings-snapshot`.
    static func statusLine(now: Date = Date(), tier override: String? = nil) -> String {
        let config = Config.load()
        guard config.cloudVoice else { return "Cloud voice: off" }
        if config.cloudVoiceDeveloperKeys {
            return "Cloud voice: on, with developer keys from the keychain — not metered"
        }
        return edge?.statusLine(now: now, tier: override)
            ?? "Cloud voice: needs developer keys in the keychain in this build"
    }

    /// Why `mayUse` said no, in the person's words.
    static func whyNotUsable() -> String {
        let config = Config.load()
        if !config.cloudVoice { return "the cloud voice is switched off in Settings" }
        return edge?.whyNotUsable() ?? "this build has no cloud voice without developer keys"
    }

    /// Run a blocking read (a subprocess) off the cooperative pool.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

/// The source of a build with no cloud and no developer keys.
private struct NoCloudVoice: CloudVoiceCredentials {
    func credential(for kind: CloudVoiceKind) async throws -> CloudVoiceCredential {
        throw CloudVoiceUnavailable.notEntitled
    }
    func report(kind: CloudVoiceKind, sttSeconds: Double, ttsCharacters: Int) async {}
}

extension CloudVoiceUnavailable {
    /// Every refusal, in words a person can act on.
    ///
    /// Never the raw case name. `offline` is what this enum calls an edge
    /// that answered **404** — which is what happened on 2026-09-07, when
    /// `/v1/voice/credential` did not exist on the edge at all — and
    /// putting the word "offline" on screen would send someone to check
    /// their wifi over a missing server route.
    static func reason(for error: Error) -> String {
        guard let unavailable = error as? CloudVoiceUnavailable else {
            return "Moe's cloud could not be reached just now"
        }
        switch unavailable {
        case .notEntitled:      return "it is not part of your plan"
        case .allowanceSpent:   return "this month's cloud-voice allowance is used up"
        case .notConfigured:    return "Moe's cloud is not set up for it yet"
        case .offline:          return "Moe's cloud could not be reached just now"
        case .disabled:         return "the cloud voice is switched off in Settings"
        }
    }
}

/// The edge not answering is a dropped connection to the voice's episode
/// rule (`PremiumVoiceReconnect`); every other refusal is the account's or
/// the setting's, and is not.
extension CloudVoiceUnavailable: PremiumVoiceConnectionFailure {
    var isConnectionDrop: Bool { self == .offline }
}

// MARK: - The developer source

/// For this Mac, before the edge route lands: the vendor keys from the login
/// keychain, and the token minted here exactly as the edge will mint it.
/// `Config.cloudVoiceDeveloperKeys` turns it on; nothing is metered and
/// `report` only logs.
///
/// Add the keys with the `security` tool:
///
///     security add-generic-password -a moe -s assemblyai-api-key -w '<key>'
///     security add-generic-password -a moe -s inworld-api-key    -w '<key>'
///
/// They are read back through `/usr/bin/security`, not `SecItemCopyMatching`
/// — the same route `HermesSupervisor` and `ComposioKeychain` take — and for
/// a reason measured on 2026-09-06, not the dialog one. A secret read through
/// the API makes securityd evaluate the calling app's code signature, and on
/// a Mac with a filtering proxy (Canopy, 127.0.0.1:9169) that evaluation ran
/// a Gatekeeper scan plus a notarization lookup that failed TLS through the
/// proxy on every call: 3.3–7.7 s per read, every read, for any binary not
/// signed by Apple, while `security find-generic-password -w` on the same
/// item took 85–101 ms including the spawn. That was the whole of the
/// "assemblyai credential minted in 5423 ms" — the request itself was
/// 170–560 ms. The tool is a platform binary and is never scanned. Its own
/// access list is on every item it created, so `-A` is no longer needed
/// (and harmless if present).
final class DeveloperVoiceCredentials: CloudVoiceCredentials, @unchecked Sendable {

    static let assemblyAIService = "assemblyai-api-key"
    static let inworldService = "inworld-api-key"
    static let account = "moe"

    private let settingOn: @Sendable () -> Bool
    private let session: URLSession

    init(settingOn: @escaping @Sendable () -> Bool) {
        self.settingOn = settingOn
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func credential(for kind: CloudVoiceKind) async throws -> CloudVoiceCredential {
        guard settingOn() else { throw CloudVoiceUnavailable.disabled }
        let credential: CloudVoiceCredential
        switch kind {
        case .stt: credential = try await assemblyAI()
        case .tts: credential = try await inworld()
        }
        let seconds = Int(credential.expiresAt.timeIntervalSinceNow.rounded())
        Log.write("cloud voice (developer keys): \(kind.rawValue) credential from "
                  + "\(credential.socketURL.host ?? "?"), expires in \(seconds) s")
        return credential
    }

    func report(kind: CloudVoiceKind, sttSeconds: Double, ttsCharacters: Int) async {
        let spent = kind == .stt ? "\(Int(sttSeconds.rounded(.up))) s" : "\(ttsCharacters) chars"
        Log.write("cloud voice (developer keys): \(kind.rawValue) used \(spent) — not metered")
    }

    /// `GET /v3/token?expires_in_seconds=60` with the raw key as the
    /// `Authorization` value (no `Bearer`) → `{"token": …}`. The socket URL
    /// carries the model and mode; `keyterms_prompt` is left for the STT
    /// backend to append.
    private func assemblyAI() async throws -> CloudVoiceCredential {
        let readBegan = Date()
        // Off the cooperative pool: the read is a subprocess and waits on it.
        guard let key = try await CloudVoice.blocking({
            DeveloperKeychain.password(service: Self.assemblyAIService, account: Self.account)
        }) else {
            throw CloudVoiceUnavailable.notConfigured(
                "no \(Self.assemblyAIService) item for account \(Self.account) in the login keychain")
        }
        let keychainMs = Self.elapsedMs(since: readBegan)
        var request = URLRequest(
            url: URL(string: "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        let requestBegan = Date()
        let object = try await json(request, vendor: "AssemblyAI")
        let requestMs = Self.elapsedMs(since: requestBegan)
        guard let token = object["token"] as? String, !token.isEmpty else {
            throw CloudVoiceUnavailable.notConfigured("AssemblyAI answered without a token")
        }
        let lifetime = (object["expires_in_seconds"] as? NSNumber)?.doubleValue ?? 60
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "speech_model", value: "universal-3-5-pro"),
            URLQueryItem(name: "mode", value: "max_accuracy"),
            URLQueryItem(name: "token", value: token),
        ]
        return CloudVoiceCredential(kind: .stt, token: token, socketURL: components.url!,
                                    expiresAt: Date().addingTimeInterval(lifetime), allowance: nil,
                                    minted: CloudVoiceMintTiming(keychainMs: keychainMs, requestMs: requestMs))
    }

    /// `POST /auth/v1/tokens` with `Authorization: Basic <key>` and
    /// `{"single_use": true, "ttl": "3600s", "client_reference_id": "moe-mac"}`
    /// → `{"accessToken": …, "expireTime": "<RFC 3339>", …}` (docs.inworld.ai,
    /// portal/ephemeral-tokens, read 2026-09-06). The socket takes
    /// `Authorization: Bearer <accessToken>`; where a client cannot set
    /// headers, Inworld also accepts `Sec-WebSocket-Protocol: bearer_<token>`.
    private func inworld() async throws -> CloudVoiceCredential {
        let readBegan = Date()
        // Off the cooperative pool: the read is a subprocess and waits on it.
        guard let key = try await CloudVoice.blocking({
            DeveloperKeychain.password(service: Self.inworldService, account: Self.account)
        }) else {
            throw CloudVoiceUnavailable.notConfigured(
                "no \(Self.inworldService) item for account \(Self.account) in the login keychain")
        }
        let keychainMs = Self.elapsedMs(since: readBegan)
        var request = URLRequest(url: URL(string: "https://api.inworld.ai/auth/v1/tokens")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "single_use": true,
            "ttl": "3600s",
            "client_reference_id": "moe-mac",
        ] as [String: Any], options: [.sortedKeys])
        let requestBegan = Date()
        let object = try await json(request, vendor: "Inworld")
        let requestMs = Self.elapsedMs(since: requestBegan)
        guard let token = object["accessToken"] as? String, !token.isEmpty else {
            throw CloudVoiceUnavailable.notConfigured("Inworld answered without an accessToken")
        }
        let expires = (object["expireTime"] as? String).flatMap(Self.rfc3339)
            ?? Date().addingTimeInterval(3600)
        return CloudVoiceCredential(
            kind: .tts, token: token,
            socketURL: URL(string: "wss://api.inworld.ai/tts/v1/voice:streamBidirectional")!,
            expiresAt: expires, allowance: nil,
            minted: CloudVoiceMintTiming(keychainMs: keychainMs, requestMs: requestMs))
    }

    private static func elapsedMs(since began: Date) -> Int {
        Int(Date().timeIntervalSince(began) * 1000)
    }

    /// A vendor's answer, or the refusal it amounts to. The body of a non-2xx
    /// is not quoted: it is the vendor's text about our key.
    private func json(_ request: URLRequest, vendor: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudVoiceUnavailable.offline
        }
        guard let http = response as? HTTPURLResponse else { throw CloudVoiceUnavailable.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudVoiceUnavailable.notConfigured("\(vendor) answered \(http.statusCode) to the token request")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudVoiceUnavailable.notConfigured("\(vendor) answered without a JSON object")
        }
        return object
    }

    private static func rfc3339(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// One generic-password read through `/usr/bin/security -w` (see the class
/// comment above for why not the API). The value lives in this pipe and the
/// returned string and nowhere else; stderr is dropped so a refusal cannot
/// echo anything. `MOE_SECURITY_BIN` is the debug-only stub hook the other
/// two readers honour.
enum DeveloperKeychain {
    static func password(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TestHooks.env("MOE_SECURITY_BIN") ?? "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
