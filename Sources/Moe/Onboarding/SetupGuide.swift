import AppKit
import SwiftUI

// What every setup flow says to the person doing it, written once.
//
// The brief this file answers: could someone who has never heard of an app
// password do this alone, without googling anything? So each guide carries
// the same five things, and none of them may be empty:
//
//   whatItIs        — what this thing actually is, in one sentence
//   why             — what Moe will be able to do once it is connected
//   steps           — numbered, with the exact page to open as a link
//   ifYouSkip       — always: Moe keeps working, that one thing is off
//   afterConnected  — one line confirming what just became possible
//
// plus `headsUp` for the dead end a flow is known to hit (Gmail's missing
// app-passwords page is the biggest one in the product), and `awake` where
// a connection only works while this Mac is on, because people should be
// told that rather than discover it.
//
// Every factual claim here is checked against the thing that implements it;
// the comment on each guide says which file.

struct SetupGuide: Sendable {
    struct Step: Sendable {
        let text: String
        /// A page to open, or "" — always https, always shown as a link.
        var linkLabel: String = ""
        var link: String = ""
        var url: URL? { link.isEmpty ? nil : URL(string: link) }
    }

    /// The Connection.id this belongs to.
    let id: String
    let whatItIs: String
    let why: String
    let steps: [Step]
    let ifYouSkip: String
    let afterConnected: String
    /// The known dead end, said before they walk into it. "" when there is none.
    var headsUp: String = ""
    /// "" unless this only works while the Mac is awake.
    var awake: String = ""

    // MARK: - The hard ones

    /// Gmail. Checked against scripts/connect-gmail.sh (an address and an app
    /// password, saved to the Keychain; the mailbox is opened read-only) and
    /// moe-home/connectors/gmail.py (reading, and `send`, which the
    /// confirmation hook in moe-home/hermes/hooks/confirm-send.sh gates).
    /// The three cases where Google offers no app password are in
    /// docs/GOOGLE-WITHOUT-OAUTH.md.
    static let gmail = SetupGuide(
        id: "mac/gmail",
        whatItIs: """
        An app password is a 16-letter key Google makes for one app and one app only. \
        It is safer than giving Alfie your real password: it reaches your mail and nothing \
        else, it cannot get into your Google account, you can delete it from Google at any \
        moment, and Alfie never sees your actual password.
        """,
        why: "So Alfie can tell you what is waiting, find the message you half remember, and write replies for you.",
        steps: [
            Step(text: "Switch on 2-Step Verification for this Google account, if it isn't on already. Google only offers app passwords to accounts that have it — without it, the page in step 2 does not exist. This is where nearly everyone gets stuck.",
                 linkLabel: "Turn on 2-Step Verification",
                 link: "https://myaccount.google.com/signinoptions/twosv"),
            Step(text: "Open Google's app passwords page.",
                 linkLabel: "Open the app passwords page",
                 link: "https://myaccount.google.com/apppasswords"),
            Step(text: "Give it any name — “Alfie” is fine — and press Create."),
            Step(text: "Google shows you 16 letters. Copy them, and paste them below along with the Gmail address they belong to. The spaces do not matter."),
        ],
        ifYouSkip: "Alfie won't read or send mail, and it will say so rather than pretend it looked. Everything else is unaffected, and you can come back here whenever you like.",
        afterConnected: "Alfie can read your mail and draft replies now. It reads anything it is about to send back to you first, and waits for a yes.",
        headsUp: """
        No app passwords page, or no option to create one? Two kinds of account cannot have \
        them: a work or school account whose administrator has switched them off, and any \
        account on Google's Advanced Protection Program. There is no way around that — and it \
        costs you mail only. Your calendar, your contacts, your Notes and the files in your \
        Google Drive folder all still work, with nothing to sign in to.
        """,
        awake: "Alfie checks this mailbox from this Mac, so new mail arrives while the Mac is awake.")

    /// Google Drive. Checked against moe-home/connectors/drive.sh: it reads
    /// Drive for Desktop's synced folders off the disk and asks for no
    /// credential; native Google files are shortcuts, and the connector says
    /// so rather than claiming to have read one (docs/GOOGLE-WITHOUT-OAUTH.md).
    static let drive = SetupGuide(
        id: "mac/drive",
        whatItIs: """
        Alfie reads the Google Drive folder that Google's own app keeps on this Mac. There is \
        nothing to sign in to and no password to hand over — if you can see the files in \
        Finder, Alfie can read them.
        """,
        why: "So Alfie can find the file you can only half describe, and tell you what is in it.",
        steps: [
            Step(text: "Install Google Drive for Desktop. It is Google's own free app, not ours.",
                 linkLabel: "Get Drive for Desktop from Google",
                 link: "https://www.google.com/drive/download/"),
            Step(text: "Open it and sign in to Google there. That sign-in is between you and Google; Alfie never sees it and never asks for a Google password of its own."),
            Step(text: "Let it finish syncing. Your Drive then shows up in Finder, and Alfie reads it from there."),
            Step(text: "If Alfie says it still can't read the folder, that is macOS protecting another app's files: give Alfie Full Disk Access, then quit and reopen Alfie."),
        ],
        ifYouSkip: "Alfie won't see your Drive. Nothing else changes.",
        afterConnected: "Alfie can search and read the files in your Drive folder now.",
        headsUp: """
        Docs, Sheets and Slides are the exception. Google keeps those on its own servers, so \
        what lands on this Mac is only a shortcut to them. Alfie gives you the name and the link \
        and tells you it could not read the contents — it never pretends it did.
        """,
        awake: "These files are read off this Mac, so Alfie only sees them while the Mac is awake.")

    /// Chrome browsing. Checked against moe-home/connectors/chrome.sh: it is
    /// off until learn/consent.sh grants it, and it keeps the page title and
    /// the site — the query and fragment are dropped by construction
    /// (`urlsplit`, and the header's rule 3), and the path is not kept either.
    static let chrome = SetupGuide(
        id: "mac/chrome",
        whatItIs: """
        Alfie reads Chrome's own history and bookmarks on this Mac — the same lists you see under \
        History and Bookmarks in Chrome. It is off until you turn it on, and turning it off again \
        takes one click here.
        """,
        why: "So you can ask “what was that page I had open on Tuesday” and get a real answer.",
        steps: [
            Step(text: "Click Turn on. That is the whole setup — there is no sign-in and no password."),
            Step(text: "What Alfie keeps from your history: the page's title, the site it was on, and when you were there — not the rest of the address. Your bookmarks come across as their name and page. Never what you typed into a search box: the part of an address after a question mark is thrown away before Alfie sees it."),
            Step(text: "To turn it off, come back to this row and click Disconnect. Alfie stops reading it, and what it already read is dropped."),
        ],
        ifYouSkip: "Alfie knows nothing about your browsing. Everything else works as before.",
        afterConnected: "Alfie can look back over what you were reading. It picks it up on the next sync.",
        awake: "Chrome's history is read off this Mac, so Alfie only sees it while the Mac is awake.")

    /// The managed Telegram bot. Checked against ConnectFlow.oneClick →
    /// scripts/connect.sh platform/telegram, then the pairing step
    /// (scripts/pairing.sh approve), which is what decides who may talk to Moe.
    static let telegramBot = SetupGuide(
        id: "platform/telegram",
        whatItIs: """
        A Telegram bot is an account on Telegram that a program answers for. You message it \
        the way you would message a person, and Alfie is the one replying. Alfie makes one for \
        you — you do not have to set anything up in Telegram first.
        """,
        why: "So you can text Alfie from your phone, without coming back to the Mac.",
        steps: [
            Step(text: "Click the button. Alfie asks Telegram to create a bot for you and takes the key it hands back."),
            Step(text: "Telegram opens with your new bot. Tap Start, then send it any message at all."),
            Step(text: "Your message appears here. Click Approve — that is how Alfie knows the phone is yours."),
        ],
        ifYouSkip: "Alfie stays on this Mac only. Nothing else changes.",
        afterConnected: "You can text Alfie from your phone now. Nobody else can: only the people you approve here are answered.",
        awake: "Alfie replies from this Mac, so it can only answer while the Mac is awake.")

    /// The personal Telegram chats connector. Checked against
    /// scripts/connect-telegram.sh, driven in the sheet (NEED=phone, then the
    /// code and, if set, the two-step password) — not a Terminal.
    static let telegramChats = SetupGuide(
        id: "mac/telegram",
        whatItIs: """
        This is your own Telegram — your real conversations — not the bot. Telegram checks it \
        is you exactly the way it does on a new phone: it texts you a code.
        """,
        why: "So Alfie knows what people have actually been saying to you on Telegram.",
        steps: [
            Step(text: "Type your phone number, with the country code."),
            Step(text: "Telegram sends you a code. Type it here."),
            Step(text: "If you have a two-step password on Telegram, type that too. Alfie stays signed in on this Mac afterwards, so this happens once."),
        ],
        ifYouSkip: "Alfie won't read your Telegram conversations. The bot, if you set one up, still works.",
        afterConnected: "Alfie can follow your Telegram conversations now, and write a message when you ask — it shows you every one before it goes.",
        awake: "Alfie talks to Telegram from this Mac, so it can only look while the Mac is awake. Nothing is stored on Telegram's side for it to catch up on later.")

    /// The same flow on a copy of Memoe that was built without an application
    /// pair (build.sh › MOE_TELEGRAM_API_ID/HASH). Telegram issues those per
    /// application, so the product is meant to carry one and nobody should
    /// ever see my.telegram.org — but a build without one used to ask for a
    /// phone number and then fail with an error naming environment
    /// variables. Asking, with the steps, beats failing.
    static let telegramChatsNeedingKeys = SetupGuide(
        id: "mac/telegram+keys",
        whatItIs: """
        This is your own Telegram — your real conversations — not the bot. Telegram checks it \
        is you exactly the way it does on a new phone: it texts you a code.

        This copy of Alfie was built without an application of its own, so Telegram needs you to \
        register one first. It is free, it takes a minute, and you only ever do it once.
        """,
        why: "So Alfie knows what people have actually been saying to you on Telegram.",
        steps: [
            Step(text: "Open Telegram's application page and log in with your phone number.",
                 linkLabel: "Open my.telegram.org/apps",
                 link: "https://my.telegram.org/apps"),
            Step(text: "Fill in the short form to create an application. Any name will do — “Alfie” is fine — and the other boxes can be left alone."),
            Step(text: "It shows you an api_id (a number) and an api_hash (a long code). Copy both into the boxes below."),
            Step(text: "Add your phone number with its country code, and press Connect. Telegram texts you a code; type it on the next screen."),
            Step(text: "If you have a two-step password on Telegram, type that too. Alfie stays signed in on this Mac afterwards, so all of this happens once."),
        ],
        ifYouSkip: "Alfie won't read your Telegram conversations. The bot, if you set one up, still works.",
        afterConnected: "Alfie reads your Telegram conversations on this Mac now.",
        headsUp: """
        The api_id and api_hash identify the application, not you — they are not a password and \
        they give nobody access to your account. Alfie keeps them on this Mac and reuses them, so \
        you will not be asked again.
        """,
        awake: "These are read on this Mac, so Alfie only sees them while the Mac is awake.")

    /// WhatsApp, both ways in. Genuinely a Terminal flow: the pairing is a QR
    /// code that has to be scanned live, and both paths open Terminal
    /// (ConnectionsView.act → runInTerminal).
    static let whatsappBridge = SetupGuide(
        id: "mac/whatsapp",
        whatItIs: """
        WhatsApp links this Mac to your phone the same way WhatsApp Web does: your phone \
        scans a code, and this Mac becomes one of your linked devices.
        """,
        why: "So Alfie knows what people have been saying to you on WhatsApp.",
        steps: [
            Step(text: "This one runs in a Terminal window — the code has to be scanned live, so it is a window you watch rather than a form you fill in. Clicking below opens it for you."),
            Step(text: "The command it runs, if you would rather run it yourself: ~/.moe/scripts/connect-whatsapp.sh"),
            Step(text: "On your phone: WhatsApp → Settings → Linked devices → Link a device, then point it at the code in the Terminal window."),
        ],
        ifYouSkip: "Alfie won't read your WhatsApp. Nothing else changes.",
        afterConnected: "Alfie reads your WhatsApp conversations on this Mac now.",
        awake: "The link runs on this Mac, so it only works while the Mac is awake. It also has to be renewed every few weeks — Alfie tells you when.")

    static let whatsappPlatform = SetupGuide(
        id: "platform/whatsapp",
        whatItIs: """
        This lets you message Alfie on WhatsApp and get answers back. Your phone links this Mac \
        by scanning a code, the same way WhatsApp Web does.
        """,
        why: "So you can talk to Alfie from WhatsApp, wherever you are.",
        steps: [
            Step(text: "This one runs in a Terminal window — the code has to be scanned live. Clicking below opens it for you."),
            Step(text: "The command it runs, if you would rather run it yourself: ~/.moe/scripts/connect.sh platform/whatsapp"),
            Step(text: "On your phone: WhatsApp → Settings → Linked devices → Link a device, then point it at the code in the Terminal window."),
        ],
        ifYouSkip: "Alfie stays on this Mac only. Nothing else changes.",
        afterConnected: "You can message Alfie on WhatsApp now.",
        awake: "Alfie replies from this Mac, so it can only answer while the Mac is awake.")

    static let all: [SetupGuide] = [
        gmail, drive, chrome, telegramBot, telegramChats, telegramChatsNeedingKeys,
        whatsappBridge, whatsappPlatform,
    ]

    static func find(_ id: String) -> SetupGuide? { all.first { $0.id == id } }

    var json: [String: Any] {
        ["id": id, "whatItIs": whatItIs, "why": why, "ifYouSkip": ifYouSkip,
         "afterConnected": afterConnected, "headsUp": headsUp, "awake": awake,
         "steps": steps.map { ["text": $0.text, "link": $0.link] }]
    }

    // MARK: - Everything else in the catalog

    /// A service with no hand-written guide still gets the same five things.
    /// `label`, `blurb` and how it signs in are all the row already knows.
    static func generic(label: String, blurb: String, signsIn: Bool, pastesKey: Bool) -> SetupGuide {
        var steps: [Step] = []
        if signsIn {
            steps.append(Step(text: "Click Sign in. \(label)'s own page opens in your browser — you say yes to Alfie there and come back. Alfie never sees your \(label) password."))
            steps.append(Step(text: "That's it. To take it back later, click Disconnect here, and change your mind at \(label) too if you want to be thorough."))
        } else if pastesKey {
            steps.append(Step(text: "\(label) gives you a key in its own settings — usually under a heading like Developers, Integrations or Connected apps. Copy it."))
            steps.append(Step(text: "Paste it below. It is kept on this Mac, readable only by you, and never shown here again."))
            steps.append(Step(text: "If you can't find where \(label) hands out keys, the “Where do I find this?” link below goes straight to its page."))
        } else {
            steps.append(Step(text: "Click Connect. There is nothing to sign in to and nothing to paste."))
        }
        return SetupGuide(
            id: "",
            whatItIs: blurb.isEmpty ? "\(label) is one of the services Alfie can work with." : blurb,
            why: "So Alfie can use \(label) on your behalf when you ask it to.",
            steps: steps,
            ifYouSkip: "Nothing happens. Alfie carries on without \(label), and this waits here for whenever you want it.",
            afterConnected: "Alfie can reach \(label) now. Ask it something about \(label) and see.")
    }
}

// MARK: - The one way a setup flow is ever explained on screen

/// What it is, why, the numbered steps with their links, and the line about
/// skipping. Used inside the connect sheet, above whatever the flow needs
/// the person to actually do.
struct SetupGuideView: View {
    let guide: SetupGuide
    /// Off when the flow's own step list is showing instead.
    var showSteps = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(guide.whatItIs)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(guide.why)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showSteps {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.text).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let url = step.url, url.scheme == "https" {
                                    Link(step.linkLabel, destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            if !guide.headsUp.isEmpty {
                Text(guide.headsUp)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !guide.awake.isEmpty {
                Label(guide.awake, systemImage: "bolt.slash")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(guide.ifYouSkip)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
