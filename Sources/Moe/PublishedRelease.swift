import Foundation

/// What is actually live in the world: the release everybody else is running.
///
/// This is the third of three different answers to "which Moe is this?", and
/// they are genuinely different questions:
///
///   * `main`                what the project contains
///   * `BuildInfo.currency`  what this Mac has built and installed
///   * this                  what is published, and what a stranger downloads
///
/// They were indistinguishable until the day this was written, because a
/// release names itself by version — and the published `0.3.10 (17)` and a
/// build made here an hour later are both `0.3.10 (17)`. The version changes
/// when a release is cut, not when the code does. So "is what everyone is
/// running the same as what we have?" had no answer; the nearest anyone could
/// get was reading the release timestamp and counting the commits since,
/// which is an inference from a clock.
///
/// `scripts/update-appcast.py` now writes `<moe:commit>` into the feed, so the
/// answer is a fact. Releases published before that carry no commit, and this
/// says so rather than guessing — every release up to and including 0.3.10 is
/// in that state, and will be forever.
enum PublishedRelease {

    struct Info {
        let short: String
        let build: String
        /// nil for every release published before the feed carried commits.
        let commit: String?
        let published: Date?
        /// How far the published commit is behind `origin/main`, when the
        /// commit is known and this Mac's checkout has it.
        let behind: Int?
        /// The line to show a person.
        let text: String
    }

    /// Reads the live feed. Network, so call it off the main thread.
    ///
    /// The URL is the one baked into this build, not a constant typed twice:
    /// a build pointed at a different feed must report on THAT feed, or the
    /// line is about somebody else's releases.
    static func read(comparingAgainst repo: String?) -> Info? {
        let feed = (Bundle.main.infoDictionary?["SUFeedURL"] as? String)
            ?? "https://moebot.app/appcast.xml"
        guard let url = URL(string: feed) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Never a cached answer: the whole point is what is live right now,
        // and a 304 from this morning reads exactly like a fresh fact.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var data: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { d, _, _ in
            data = d
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        guard let data, let xml = String(data: data, encoding: .utf8) else { return nil }

        // The feed is newest-first, written by one generator, so the first
        // <item> is the current release. Parsed by scanning rather than with
        // XMLParser because what is wanted is four scalars out of a document
        // shape we produce ourselves.
        guard let itemStart = xml.range(of: "<item>") else { return nil }
        let rest = xml[itemStart.upperBound...]
        let item = rest.range(of: "</item>").map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)

        func element(_ name: String) -> String? {
            guard let open = item.range(of: "<\(name)>"),
                  let close = item.range(of: "</\(name)>", range: open.upperBound..<item.endIndex)
            else { return nil }
            return String(item[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let short = element("sparkle:shortVersionString"),
              let build = element("sparkle:version") else { return nil }
        let commit = element("moe:commit")
        let published = element("pubDate").flatMap(rfc822)

        var behind: Int?
        if let commit, let repo {
            behind = commitsBetween(commit, andMainIn: repo)
        }

        var parts = ["\(short) (\(build))"]
        if let commit { parts.append(commit) }
        if let published {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            parts.append("published \(f.localizedString(for: published, relativeTo: Date()))")
        }
        if let behind {
            parts.append(behind == 0
                         ? "everything on main is out there"
                         : "\(behind) change\(behind == 1 ? "" : "s") behind main")
        } else if commit == nil {
            // Said plainly, because the alternative — inferring from the
            // publication date — is how a guess becomes a number somebody
            // repeats. Releases from before the feed carried commits cannot
            // answer this and never will.
            parts.append("which commit is in it was not recorded")
        }
        return Info(short: short, build: build, commit: commit,
                    published: published, behind: behind,
                    text: parts.joined(separator: " · "))
    }

    // MARK: - Bits

    private static func rfc822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.date(from: s)
    }

    /// Commits on `origin/main` that the published build does not have.
    /// nil when this Mac's checkout has never seen that commit — which is
    /// honest, and different from zero.
    private static func commitsBetween(_ commit: String, andMainIn repo: String) -> Int? {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bare = commit.replacingOccurrences(of: "+dirty", with: "")
        guard git(["cat-file", "-e", bare + "^{commit}"]) != nil,
              let n = git(["rev-list", "--count", bare + "..origin/main"]) else { return nil }
        return Int(n)
    }
}
