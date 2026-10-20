import Foundation
import Testing
@testable import MoeMeeting

// MARK: - Telegram: opt-in, and honest when it fails

struct TelegramGateTests {

    @Test func offByDefaultMeansNothingIsSentAndNothingIsSaid() {
        let gate = TelegramSelf.gate(enabled: false, target: "telegram:1", connected: true)
        #expect(gate == .off)
        #expect(!gate.isSending)
        #expect(gate.message.isEmpty)
    }

    /// The old behaviour: an entry in `TELEGRAM_ALLOWED_USERS` was the only
    /// condition, so the notes went out because Hermes happened to be
    /// configured — not because anybody asked for it.
    @Test func aConfiguredBotIsNotConsent() {
        #expect(TelegramSelf.gate(enabled: false, target: "telegram:8675309", connected: true) == .off)
        #expect(TelegramSelf.gate(enabled: true, target: "telegram:8675309", connected: true)
                == .send(target: "telegram:8675309"))
    }

    @Test func switchedOnWithoutABotOrABrainSaysWhichIsMissing() {
        #expect(TelegramSelf.gate(enabled: true, target: nil, connected: true) == .notConfigured)
        #expect(TelegramSelf.gate(enabled: true, target: "", connected: true) == .notConfigured)
        #expect(TelegramSelf.gate(enabled: true, target: "telegram:1", connected: false) == .notConnected)
        #expect(TelegramSelf.gate(enabled: true, target: nil, connected: true).message.contains("no Telegram bot"))
        #expect(TelegramSelf.gate(enabled: true, target: "telegram:1", connected: false).message.contains("not connected"))
    }

    @Test func theSettingsSwitchExplainsWhyItIsDisabled() {
        #expect(TelegramSelf.switchExplanation(target: nil).contains("Connect a Telegram bot first"))
        #expect(TelegramSelf.switchExplanation(target: "telegram:1").contains("send_message"))
        #expect(TelegramSelf.switchExplanation(target: "telegram:1").contains("Off by default"))
    }

    /// The real failure, verbatim from the log of the first meeting.
    @Test func theMissingToolIsNamedRatherThanReportedAsFAILED() {
        let reply = "FAILED: no send_message tool is available in this environment."
        #expect(TelegramSelf.looksLikeMissingTool(reply))
        let (sent, message) = TelegramSelf.outcome(reply: reply)
        #expect(!sent)
        #expect(message == TelegramSelf.missingToolNote)
        #expect(message.contains("claude-code"))
        #expect(!message.contains("FAILED"))
    }

    @Test func aSuccessIsSENTAndAnythingElseCarriesItsOwnReason() {
        #expect(TelegramSelf.outcome(reply: "SENT").sent)
        #expect(TelegramSelf.outcome(reply: " sent\n").sent)
        #expect(TelegramSelf.outcome(reply: "SENT").message == "Notes sent to your Telegram.")
        let (sent, message) = TelegramSelf.outcome(reply: "FAILED: the chat id was rejected")
        #expect(!sent)
        #expect(message.contains("the chat id was rejected"))
        #expect(!TelegramSelf.outcome(reply: "").sent)
        #expect(TelegramSelf.outcome(reply: "").message.contains("did not answer"))
    }

    @Test func anUnrelatedFailureIsNotMistakenForTheMissingTool() {
        #expect(!TelegramSelf.looksLikeMissingTool("FAILED: the network was unavailable"))
        #expect(!TelegramSelf.looksLikeMissingTool("SENT"))
        #expect(TelegramSelf.looksLikeMissingTool("there is no send_message tool here"))
    }
}

/// The switch in Settings shows the *stored* setting, not
/// `stored && configured`. It used to show the second, so removing the bot
/// hid a stored `true` and reconnecting it silently re-armed sending.
struct TelegramSwitchTests {

    @Test func aStoredTrueWithNoBotSaysWhatItMeans() {
        let text = TelegramSelf.switchExplanation(target: nil, on: true)
        #expect(text.contains("This is on, but nothing is being sent"))
        #expect(text.contains("switch this off first"))
    }

    @Test func aStoredFalseWithNoBotJustSaysHowToConnectOne() {
        let text = TelegramSelf.switchExplanation(target: nil, on: false)
        #expect(text.contains("Connect a Telegram bot first"))
        #expect(!text.contains("This is on"))
    }

    /// Whatever the switch shows, nothing is actually sent without a bot:
    /// the gate, not the control, is what stops it.
    @Test func theGateStillRefusesWithoutATarget() {
        #expect(TelegramSelf.gate(enabled: true, target: nil, connected: true) == .notConfigured)
        #expect(!TelegramSelf.gate(enabled: true, target: nil, connected: true).isSending)
    }
}
