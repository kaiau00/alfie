import Foundation
import Testing
@testable import Moe

/// 2026-09-29, owner. The Driving the Mac section said "Never type a
/// password, passcode, 2FA code … say the field needs them and let them type
/// it", and Moe read it as a refusal: it told the owner "I can't type
/// passcodes" and moved on from the task. The safety stays — Moe never types
/// a secret it was told in the conversation or saw on screen — but the
/// section now gives the route instead of the refusal: the password tools ask
/// the person in Moe's own window and enter it unseen, and anywhere else Moe
/// asks them to type it and waits. General on purpose: no site is named.
struct DrivingTheMacSecretsTests {

    @Test("a secret is never typed from the conversation, and the section gives the route instead of a refusal")
    func routeNotRefusal() {
        let text = FirstRun.drivingTheMac
        // The safety intent, kept.
        #expect(text.contains("never typed from what you know"))
        #expect(text.contains("not one they read out or write to you in"))
        #expect(text.contains("Do not screenshot while they type."))
        // The route.
        #expect(text.contains("That is never a reason to\nsay you cannot do it or to move on"))
        #expect(text.contains("use your\npassword tools (`browser_vault_*`)"))
        #expect(text.contains("without you ever seeing it"))
        #expect(text.contains("a passcode or PIN they know"))
        #expect(text.contains("wait while they\ntype it there, and carry on"))
        // The refusal, gone.
        #expect(!text.contains("Never type a password, passcode"))
        #expect(!text.contains("say the field needs\nthem and let them type it"))
        for word in ["x.com", "twitter", "google", "encrypted", "direct message"] {
            #expect(!text.lowercased().contains(word))
        }
    }

    @Test("existing installs are handed the new section")
    func versionBumped() {
        #expect(FirstRun.drivingTheMacVersion >= 6)
        #expect(FirstRun.agentsMd.contains("a passcode or PIN they know"))
    }
}
