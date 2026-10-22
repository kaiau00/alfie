import Foundation
import Testing
@testable import Moe

/// docs/DEFAULTS.md row 26: the first chat app that connects is ticked for
/// reminders by itself — once, into an empty list — and never again.
/// `ReminderChannels.autoPick` decides; `adopt` is what Conductor writes
/// inside `Config.update`, so these drive the same two functions the app
/// calls, on a `Config` value that is never saved.
struct ReminderChannelAutoPickTests {
    typealias Platform = ReminderChannels.Platform

    static let telegram = Platform(name: "telegram", title: "Telegram", ready: true)
    static let whatsapp = Platform(name: "whatsapp", title: "WhatsApp", ready: true)
    static let whatsappNotReady = Platform(name: "whatsapp", title: "WhatsApp", ready: false)

    @Test("row 26 — the first ready chat app is ticked once, and never again")
    func firstReadyIsTickedOnce() {
        var config = Config()
        #expect(config.reminderChannels.isEmpty)
        #expect(!config.reminderChannelsAutoPicked)

        let picked = ReminderChannels.adopt([Self.telegram, Self.whatsappNotReady], into: &config)
        #expect(picked == "telegram")
        #expect(config.reminderChannels == ["telegram"])
        #expect(config.reminderChannelsAutoPicked)

        // The same list again: nothing more.
        #expect(ReminderChannels.adopt([Self.telegram, Self.whatsappNotReady], into: &config) == nil)
        #expect(config.reminderChannels == ["telegram"])

        // WhatsApp becomes ready later: a second chat app stays opt-in.
        #expect(ReminderChannels.adopt([Self.telegram, Self.whatsapp], into: &config) == nil)
        #expect(config.reminderChannels == ["telegram"])
    }

    @Test("row 26 — two chat apps ready at the first look: none is picked")
    func twoReadyAtOncePicksNone() {
        // Two ready at once says nothing about which one the person means
        // reminders to reach. Moe does not guess; both stay for them to tick.
        var config = Config()
        #expect(ReminderChannels.adopt([Self.telegram, Self.whatsapp], into: &config) == nil)
        #expect(config.reminderChannels.isEmpty)
        // …and not "picked" either: nothing was chosen, by anyone.
        #expect(!config.reminderChannelsAutoPicked)
    }

    @Test("row 26 — nothing ready (connected, never messaged): nothing ticked")
    func notReadyIsNeverPicked() {
        var config = Config()
        #expect(ReminderChannels.adopt([Self.whatsappNotReady], into: &config) == nil)
        #expect(ReminderChannels.adopt([], into: &config) == nil)
        #expect(config.reminderChannels.isEmpty)
    }

    @Test("row 26 — a chat the person unticked is never ticked again")
    func untickIsKept() {
        var config = Config()
        ReminderChannels.adopt([Self.telegram], into: &config)
        #expect(config.reminderChannels == ["telegram"])
        // What Conductor.setReminderChannel("telegram", on: false) writes.
        config.reminderChannels = []
        config.reminderChannelsAutoPicked = true
        #expect(ReminderChannels.adopt([Self.telegram], into: &config) == nil)
        #expect(ReminderChannels.autoPick(current: [], alreadyPicked: true, platforms: [Self.telegram]) == nil)
        #expect(config.reminderChannels.isEmpty)
    }

    @Test("row 26 — a list the person already has is never added to")
    func nonEmptyListIsLeftAlone() {
        #expect(ReminderChannels.autoPick(current: ["slack"], alreadyPicked: false,
                                          platforms: [Self.telegram]) == nil)
    }

    @Test("row 26 — a config.json from before the flag counts as already chosen; a new one does not")
    func decoding() throws {
        // Written by an older Moe: the person has had the list in front of
        // them, and an empty list is their answer.
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"reminderChannels": []}"#.utf8))
        #expect(old.reminderChannelsAutoPicked)
        // Written by this build before any chat was ready.
        let fresh = try JSONDecoder().decode(
            Config.self, from: Data(#"{"reminderChannels": [], "reminderChannelsAutoPicked": false}"#.utf8))
        #expect(!fresh.reminderChannelsAutoPicked)
        // And it round-trips.
        var picked = Config()
        ReminderChannels.adopt([Self.telegram], into: &picked)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(picked))
        #expect(back.reminderChannels == ["telegram"])
        #expect(back.reminderChannelsAutoPicked)
    }

    // MARK: The launch watcher stops

    @Test("row 26 — the watcher stops once a chat is picked, by Alfie or the person")
    func watcherStopsWhenPicked() {
        #expect(ReminderChannels.watchStep(alreadyPicked: true, looks: 1, platforms: [Self.telegram]) == .stop)
        #expect(ReminderChannels.watchStep(alreadyPicked: true, looks: 1, platforms: nil) == .stop)
        // What a look that picked leaves behind: adopt set the flag.
        var config = Config()
        ReminderChannels.adopt([Self.telegram], into: &config)
        #expect(ReminderChannels.watchStep(alreadyPicked: config.reminderChannelsAutoPicked, looks: 1,
                                           platforms: [Self.telegram]) == .stop)
    }

    @Test("row 26 — two chat apps ready at one look: stop, and remember Alfie will never guess")
    func watcherStopsOnTwoReady() {
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 1,
                                           platforms: [Self.telegram, Self.whatsapp]) == .stopAndRemember)
        // One ready and one not is still worth waiting on: nothing was picked
        // only because the look came before the adopt in this call.
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 1,
                                           platforms: [Self.whatsappNotReady]) == .keepWatching)
    }

    @Test("row 26 — a Mac with no chat app stops after a day of looks, not never")
    func watcherGivesUpAfterADay() {
        #expect(ReminderChannels.maxWatchLooks == 144)   // every ten minutes, 24 h
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 1, platforms: []) == .keepWatching)
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 143, platforms: []) == .keepWatching)
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 144, platforms: []) == .stop)
        // A look Hermes could not answer still counts.
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 144, platforms: nil) == .stop)
        #expect(ReminderChannels.watchStep(alreadyPicked: false, looks: 2, platforms: nil) == .keepWatching)
    }
}
