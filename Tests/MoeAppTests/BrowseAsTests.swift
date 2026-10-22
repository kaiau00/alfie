import Foundation
import Testing
@testable import Moe

/// Settings › Permissions › "Browse as" — which browser profile Moe's own
/// browser carries the logins of. The list comes from configure-hermes.py's
/// `browser-profiles.json` (Hermes's own detector); the choice is
/// `Config.browseAsProfile`, handed back as `browser.real_profile_pin`.
/// Ticket #5: with seven Chrome profiles Hermes copied whichever was used
/// last, and a daily X job found the copy signed out.
struct BrowseAsTests {

    static let facts = Data("""
    {"browser": "chrome", "last_used": "Profile 4", "pinned": null, "snapshot": "Profile 4",
     "problem": null,
     "profiles": [{"dir": "Default", "name": "Jordy", "account": "s@x.com"},
                  {"dir": "Profile 4", "name": "Pulse", "account": ""}]}
    """.utf8)

    @Test("the facts file parses, Default first, accounts and the snapshot come through")
    func parses() throws {
        let b = try #require(BrowseAs.parse(Self.facts))
        #expect(b.browser == "chrome")
        #expect(b.profiles.map(\.dir) == ["Default", "Profile 4"])
        #expect(b.profiles[0].label == "Jordy (s@x.com)")
        #expect(b.profiles[1].label == "Pulse")
        #expect(b.pinned == nil)
        #expect(b.snapshot == "Profile 4")
        #expect(b.problem == nil)
    }

    @Test("unpinned, Alfie is whoever Chrome used last — and the row says that is a moving target")
    func unpinnedFollowsLastUsed() throws {
        let b = try #require(BrowseAs.parse(Self.facts))
        #expect(b.effective?.dir == "Profile 4")
        #expect(b.summary.contains("Pulse"))
        #expect(b.summary.contains("used last"))
        #expect(b.summary.contains("2 profiles"))
    }

    @Test("pinned, the pin wins and the row says the person chose it")
    func pinnedWins() throws {
        var json = String(decoding: Self.facts, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"pinned\": null", with: "\"pinned\": \"Default\"")
        let b = try #require(BrowseAs.parse(Data(json.utf8)))
        #expect(b.effective?.dir == "Default")
        #expect(b.summary == "Alfie browses as Jordy (s@x.com) — you chose this.")
    }

    @Test("a pin that names no profile falls back to last-used, never to nothing")
    func stalePinFallsBack() throws {
        var json = String(decoding: Self.facts, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"pinned\": null", with: "\"pinned\": \"Profile 9\"")
        let b = try #require(BrowseAs.parse(Data(json.utf8)))
        #expect(b.effective?.dir == "Profile 4")
    }

    @Test("Safari or Firefox: no browser, nothing to choose, and the row says why")
    func noChromium() throws {
        let b = try #require(BrowseAs.parse(Data(#"{"browser": null, "profiles": [], "last_used": null}"#.utf8)))
        #expect(b.browser == nil)
        #expect(b.summary.contains("signed out"))
    }

    @Test("a fresh install has not chosen; the key stays out of config.json, and \"\" means last-used")
    func configKey() throws {
        #expect(Config().browseAsProfile == nil)
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        #expect(!json.contains("browseAsProfile"), "\(json)")
        let chosen = try JSONDecoder().decode(Config.self, from: Data(#"{"browseAsProfile": "Profile 4"}"#.utf8))
        #expect(chosen.browseAsProfile == "Profile 4")
        let last = try JSONDecoder().decode(Config.self, from: Data(#"{"browseAsProfile": ""}"#.utf8))
        #expect(last.browseAsProfile == BrowseAs.followLastUsed)
        // A hand-edited number is no choice, never a decode failure.
        let odd = try JSONDecoder().decode(Config.self, from: Data(#"{"browseAsProfile": 4}"#.utf8))
        #expect(odd.browseAsProfile == nil)
    }

    @Test("the flag configure-hermes.py gets is the directory name, verbatim — \"\" included")
    func flag() {
        #expect(BrainSetup.browseAsArguments(profileDir: "Profile 4") == ["--set-browse-as", "Profile 4"])
        #expect(BrainSetup.browseAsArguments(profileDir: "") == ["--set-browse-as", ""])
    }
}
