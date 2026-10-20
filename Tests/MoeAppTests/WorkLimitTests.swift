import Foundation
import Testing
@testable import Moe

/// docs/DEFAULTS.md row 32 — Settings › Brain › "How long Moe may work on one
/// thing": 5 / 15 / 30 / 60 minutes, default 30, written to Hermes as
/// `claude_code.turn_timeout` by `configure-hermes.py --set-turn-timeout`.
struct WorkLimitTests {

    @Test("row 32 — a fresh install has not chosen, and the pane shows 30 for that")
    func defaultIsUnchosen() throws {
        #expect(Config().workLimitMinutes == nil)
        #expect(WorkLimit.normalised(Config().workLimitMinutes) == 30)
        // Not chosen stays out of config.json, so configure-hermes.py leaves
        // a hand-set turn_timeout alone.
        let json = String(decoding: try JSONEncoder().encode(Config()), as: UTF8.self)
        #expect(!json.contains("workLimitMinutes"), "\(json)")
    }

    @Test("a config.json without the key has not chosen")
    func absentIsUnchosen() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data(#"{"replyLength": "detailed"}"#.utf8))
        #expect(decoded.workLimitMinutes == nil)
    }

    @Test("a saved value that is not one of the four is no choice")
    func oddValueIsUnchosen() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data(#"{"workLimitMinutes": 45}"#.utf8))
        #expect(decoded.workLimitMinutes == nil)
    }

    @Test("a saved hour is kept, and survives a save")
    func hourIsKept() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data(#"{"workLimitMinutes": 60}"#.utf8))
        #expect(decoded.workLimitMinutes == 60)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(decoded))
        #expect(back.workLimitMinutes == 60)
    }

    @Test("a value of the wrong type falls back instead of failing the whole config")
    func wrongTypeFallsBack() throws {
        let decoded = try JSONDecoder().decode(Config.self,
                                               from: Data(#"{"workLimitMinutes": "sixty", "replyLength": "detailed"}"#.utf8))
        #expect(decoded.workLimitMinutes == nil)
        #expect(decoded.replyLength == "detailed")
    }

    @Test("an hour is handed to configure-hermes.py as 3600 seconds")
    func flagForAnHour() {
        #expect(BrainSetup.workLimitArguments(minutes: 60).joined(separator: " ") == "--set-turn-timeout 3600")
        #expect(BrainSetup.workLimitArguments(minutes: 5) == ["--set-turn-timeout", "300"])
    }

    @Test("a turn the limit stopped is said in the person's words; other errors are left alone")
    func timedOutTurnWords() {
        let words = WorkLimit.personWords(forTurnError: "claude turn exceeded 1802s")
        #expect(words?.contains("Settings › Brain") == true)
        #expect(WorkLimit.personWords(forTurnError: "claude produced no output for 120s") == nil)
    }
}
