import AppKit
import Foundation

/// The person's own wake-word clips on this Mac: where they are, how many
/// there are, and the two things Settings offers to do with them —
/// forget them, or hand them to the people who train the next head.
///
/// One folder for everything that records the name, in-app or from the
/// Terminal (`Moe --wake-record`), so `--wake-bench` and the trainer keep
/// finding them where they always have: `voice/recordings/{positive,
/// confusable,negative}` under Moe's home, which `~/.moe` still reaches.
enum WakeRecordings {

    static let dir = Config.homeDir
        .appendingPathComponent("voice", isDirectory: true)
        .appendingPathComponent("recordings", isDirectory: true)

    static let teamAddress = "hello@moebot.app"

    /// Clips with the name in them, and clips without.
    static func count() -> (positives: Int, others: Int) {
        let all = WakeBench.files(under: dir)
        let positives = all.filter { isPositive($0) }.count
        return (positives, all.count - positives)
    }

    /// A directory named positive/positives on the path — the bench's
    /// rule, never a substring.
    static func isPositive(_ file: URL) -> Bool {
        file.pathComponents.contains { $0.lowercased() == "positive" || $0.lowercased() == "positives" }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The folder as one zip, in a temporary place, by `ditto` — what the
    /// Finder's own Compress uses; nothing third-party.
    static func zip() throws -> URL {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay]
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("hey-moe-recordings-\(stamp.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw NSError(domain: "WakeRecordings", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "could not zip the recordings"])
        }
        return out
    }

    enum Handed: Equatable {
        /// A compose window is open in the mail app with the zip attached.
        case composed
        /// No mail app would take an attachment: the zip is shown in the
        /// Finder and a bare mailto: was opened.
        case revealed(URL)
    }

    /// Open a message to the team with the zip attached. Never sends: the
    /// person presses Send, or closes the window.
    @MainActor
    static func hand(_ zip: URL) -> Handed {
        let body = "Here are my “Hey Moe” recordings from Settings › Voice, for training the next wake word.\n\n"
        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [teamAddress]
            mail.subject = "Hey Moe recordings"
            let items: [Any] = [body, zip]
            if mail.canPerform(withItems: items) {
                mail.perform(withItems: items)
                return .composed
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        var parts = URLComponents(string: "mailto:\(teamAddress)")!
        parts.queryItems = [URLQueryItem(name: "subject", value: "Hey Moe recordings"),
                            URLQueryItem(name: "body", value: body + "(The zip is beside this window in the Finder — drag it in.)")]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        return .revealed(zip)
    }
}
