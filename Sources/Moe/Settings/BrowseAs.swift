import Foundation

/// The browser profiles Moe could browse as, and which one it does.
///
/// Hermes's real-profile mode copies ONE profile of the person's default
/// Chromium browser into a private copy and browses signed in as it — and,
/// unless `browser.real_profile_pin` names one, the profile it copies is
/// whichever Chrome used last. That is fine for a Mac with one profile and
/// a trap for one with seven: on 2026-09-18 a daily X job found the copy
/// signed out because the last snapshot had taken "Pulse" (ticket #5).
///
/// configure-hermes.py writes `~/.moe/hermes/browser-profiles.json` on
/// every run: the browser it detected, its profiles by name and account
/// (from Chrome's own `Local State`), the pin, the profile the last
/// snapshot actually copied, and any problem with the person's choice. This
/// reads that file. Nothing here touches Chrome; the app never needs to.
struct BrowseAs: Equatable {
    struct Profile: Equatable, Identifiable {
        /// Chrome's directory name: "Default", "Profile 4". The value stored.
        let dir: String
        /// What Chrome calls it in its own profile menu: "Jordy", "Work".
        let name: String
        /// The Google account signed into it, or "".
        let account: String
        var id: String { dir }
        /// "Jordy (jordy@…)" — the name, plus the account when there is one.
        var label: String { account.isEmpty ? name : "\(name) (\(account))" }
    }

    /// "chrome", "edge", "brave" — nil when the default browser is not one
    /// Hermes can borrow a profile from (Safari, Firefox), in which case Moe
    /// browses signed out and there is nothing to choose.
    let browser: String?
    let profiles: [Profile]
    /// The profile Chrome used last — what Moe browses as when nothing is pinned.
    let lastUsed: String?
    /// What `browser.real_profile_pin` names, or nil.
    let pinned: String?
    /// What the last Hermes snapshot actually copied, or nil if none yet.
    let snapshot: String?
    /// configure-hermes.py's note when the person's choice named no profile.
    let problem: String?

    static let fileName = "hermes/browser-profiles.json"

    static func read(home: URL) -> BrowseAs? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(fileName)) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> BrowseAs? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let profiles = ((obj["profiles"] as? [[String: Any]]) ?? []).compactMap { p -> Profile? in
            guard let dir = p["dir"] as? String, !dir.isEmpty else { return nil }
            return Profile(dir: dir, name: (p["name"] as? String) ?? dir, account: (p["account"] as? String) ?? "")
        }
        func str(_ k: String) -> String? {
            guard let v = obj[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        return BrowseAs(browser: str("browser"), profiles: profiles, lastUsed: str("last_used"),
                        pinned: str("pinned"), snapshot: str("snapshot"), problem: str("problem"))
    }

    /// The value the picker stores for "whichever I used last".
    static let followLastUsed = ""

    func profile(_ dir: String?) -> Profile? {
        guard let dir, !dir.isEmpty else { return nil }
        return profiles.first { $0.dir == dir }
    }

    /// The profile Moe browses as right now, by the rule Hermes applies:
    /// the pin if it names a real profile, else the one Chrome used last.
    var effective: Profile? { profile(pinned) ?? profile(lastUsed) }

    /// One sentence for the row: who Moe is on the web, and why.
    var summary: String {
        guard let browser else { return "Your default browser isn't Chrome, Edge or Brave, so Moe browses signed out." }
        let name = browserName
        if profiles.count <= 1 {
            return "Moe's browser carries your \(name) logins. \(name) has one profile, so there is nothing to choose."
        }
        if let p = profile(pinned) { return "Moe browses as \(p.label) — you chose this." }
        if let p = profile(lastUsed) {
            return "Moe browses as \(p.label) — whichever \(name) profile you used last. With \(profiles.count) profiles that changes as you switch windows; pick one to keep it fixed."
        }
        return "\(name) has \(profiles.count) profiles; pick the one whose logins Moe should use."
    }

    var browserName: String {
        switch browser {
        case "chrome": return "Chrome"
        case "edge": return "Edge"
        case "brave": return "Brave"
        default: return browser ?? "your browser"
        }
    }
}
