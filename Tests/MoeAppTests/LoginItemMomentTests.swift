import Foundation
import Testing
@testable import Moe
import MoeErase

/// docs/DEFAULTS.md row 30 — when Moe first becomes a login item.
///
/// The review (2026-09-15) found the erase undoing itself: *Erase Memoe from
/// this Mac* took Moe out of Login Items, reopened the app with an empty home,
/// and that launch registered it again at once — so a person who erased and
/// dragged Moe to the Bin still found it listed. The first registration now
/// happens when the welcome is finished; launch applies it only for a Mac that
/// finished the welcome before, and never on a launch an erase opened.
///
/// Nothing here reaches ServiceManagement: every call hands `applyOnce` a
/// registrar that records what it was asked, and a temporary home.
struct LoginItemMomentTests {

    /// A registrar that records each call and answers `answer`.
    final class Registrar {
        var calls: [Bool] = []
        var answer: String
        init(answer: String = "registered") { self.answer = answer }
        func call(_ on: Bool) -> String { calls.append(on); return answer }
    }

    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-login-moment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func marker(in home: URL) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".login-item-applied").path)
    }

    // MARK: The decision

    @Test("launch registers only for a Mac past the welcome with no erase note; the welcome's end always may")
    func decision() {
        #expect(!LoginItem.shouldApply(.launch(onboarded: false, erased: false), markerPresent: false))
        #expect(!LoginItem.shouldApply(.launch(onboarded: true, erased: true), markerPresent: false))
        #expect(!LoginItem.shouldApply(.launch(onboarded: false, erased: true), markerPresent: false))
        #expect(LoginItem.shouldApply(.launch(onboarded: true, erased: false), markerPresent: false))
        #expect(LoginItem.shouldApply(.welcomeFinished, markerPresent: false))
        // Once applied, neither moment applies it again.
        #expect(!LoginItem.shouldApply(.launch(onboarded: true, erased: false), markerPresent: true))
        #expect(!LoginItem.shouldApply(.welcomeFinished, markerPresent: true))
    }

    @Test("only an outcome macOS accepted counts as applied")
    func appliedOutcomes() {
        #expect(LoginItem.isApplied("registered"))
        #expect(LoginItem.isApplied("unregistered"))
        #expect(!LoginItem.isApplied("failed: Operation not permitted"))
        #expect(!LoginItem.isApplied("skipped (developer build)"))
    }

    // MARK: The launch

    @Test("a launch with the welcome not finished registers nothing and writes no marker")
    func launchBeforeWelcome() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = Registrar()
        let moment = LoginItem.launchMoment(home: home, onboarded: false)
        let outcome = LoginItem.applyOnce(Config(), at: moment, home: home, developerBuild: false, registrar: r.call)
        #expect(r.calls.isEmpty, "\(outcome)")
        #expect(!Self.marker(in: home))
    }

    @Test("the launch an erase opened registers nothing, even with the welcome marked done")
    func launchAfterErase() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        // What the erase leaves for the launch that follows (MacErase.leaveNote).
        try Data("{}".utf8).write(to: MacEraseNote.url(in: home))
        let moment = LoginItem.launchMoment(home: home, onboarded: true)
        #expect(moment == LoginItem.Moment.launch(onboarded: true, erased: true))
        let r = Registrar()
        let outcome = LoginItem.applyOnce(Config(), at: moment, home: home, developerBuild: false, registrar: r.call)
        #expect(r.calls.isEmpty, "\(outcome)")
        #expect(!Self.marker(in: home))
    }

    @Test("a Mac that finished the welcome before this rule is registered once at launch")
    func launchForAnEarlierMac() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = Registrar()
        let moment = LoginItem.launchMoment(home: home, onboarded: true)
        #expect(moment == LoginItem.Moment.launch(onboarded: true, erased: false))
        #expect(LoginItem.applyOnce(Config(), at: moment, home: home, developerBuild: false, registrar: r.call) == "registered")
        #expect(r.calls == [true])
        #expect(Self.marker(in: home))
        #expect(LoginItem.applyOnce(Config(), at: moment, home: home, developerBuild: false, registrar: r.call) == "already applied")
        #expect(r.calls == [true])
    }

    // MARK: The end of the welcome

    @Test("finishing the welcome registers once and writes the marker; finishing again does not re-register")
    func welcomeFinishedOnce() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        // Finished after an erase: the note is still in the home, and the
        // person has now chosen — the note does not hold this moment back.
        try Data("{}".utf8).write(to: MacEraseNote.url(in: home))
        let r = Registrar()
        #expect(LoginItem.applyOnce(Config(), at: .welcomeFinished, home: home, developerBuild: false, registrar: r.call) == "registered")
        #expect(r.calls == [true])
        #expect(Self.marker(in: home))
        #expect(LoginItem.applyOnce(Config(), at: .welcomeFinished, home: home, developerBuild: false, registrar: r.call) == "already applied")
        #expect(r.calls == [true])
    }

    @Test("the welcome's switch turned off is what is applied")
    func welcomeFinishedOff() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        var config = Config()
        config.launchAtLogin = false
        let r = Registrar(answer: "unregistered")
        #expect(LoginItem.applyOnce(config, at: .welcomeFinished, home: home, developerBuild: false, registrar: r.call) == "unregistered")
        #expect(r.calls == [false])
        #expect(Self.marker(in: home))
    }

    @Test("a registration macOS refused writes no marker, so the next moment tries again")
    func failureIsRetried() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = Registrar(answer: "failed: Operation not permitted")
        _ = LoginItem.applyOnce(Config(), at: .welcomeFinished, home: home, developerBuild: false, registrar: r.call)
        #expect(!Self.marker(in: home))
        r.answer = "registered"
        #expect(LoginItem.applyOnce(Config(), at: .launch(onboarded: true, erased: false), home: home,
                                    developerBuild: false, registrar: r.call) == "registered")
        #expect(r.calls == [true, true])
        #expect(Self.marker(in: home))
    }

    @Test("Moe Dev never registers")
    func developerBuild() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let r = Registrar()
        #expect(LoginItem.applyOnce(Config(), at: .welcomeFinished, home: home, developerBuild: true, registrar: r.call)
                == "skipped (developer build)")
        #expect(r.calls.isEmpty)
        #expect(!Self.marker(in: home))
    }
}
