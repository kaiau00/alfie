import AppKit
import MoeDesign
import MoeMeeting
import SwiftUI

/// "Record this meeting?" — the most legally consequential thing the app asks,
/// which until now was an `NSAlert`: the same dialog a crash reporter uses.
///
/// The copy is the design here. Two-party-consent jurisdictions are real
/// (PRODUCT.md §4.2), and the sentence that matters is the one admitting what
/// Moe *cannot* do — tell the other people on the call. An alert's cramped
/// informative text discourages writing it; a sheet does not.
///
/// Still blocking: nothing records until this returns.
///
/// The sentence used to end "— please do that yourself", and the app had a
/// line ready for exactly that (`MeetingOwner.announcement`) which nothing
/// on this sheet offered; Settings › Meetings even said it was "one click
/// away when you start". The click is here now: **Copy a line to tell
/// them** puts the announcement on the clipboard and says Copied for a
/// moment. Moe still cannot tell them itself, and the sentence still says so.
struct MeetingConsentSheet: View {
    let onStart: () -> Void
    let onCancel: () -> Void
    /// What "Copy a line to tell them" puts on the clipboard.
    let announcement: String

    @State private var copied = false

    /// `announcement` is handed in rather than defaulted: the owner's name
    /// is read on the main actor (`MeetingSession.ownerName`), and
    /// `MeetingConsent.present` is where that read belongs.
    init(onStart: @escaping () -> Void, onCancel: @escaping () -> Void, announcement: String) {
        self.onStart = onStart
        self.onCancel = onCancel
        self.announcement = announcement
    }

    /// The words on the copy button, before and after it is pressed.
    static let copyTitle = "Copy a line to tell them"
    static let copiedTitle = "Copied"
    /// The small print: what Moe cannot do, and what the button beside it is for.
    static let smallPrint = "Everything stays on your Mac, in your meetings folder. The recording is deleted once the notes are written. Alfie can't tell the other people on this call that it's listening — copy a line below and paste it into the call's chat, or just say so."

    /// The announcement, onto a pasteboard. A function of its own so the
    /// clipboard write is a thing a test can point at a scratch pasteboard.
    @discardableResult
    static func copy(_ line: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(line, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            HStack(spacing: Theme.Space.snug) {
                Circle().fill(Theme.bad).frame(width: 7, height: 7)
                Text("Nothing is recording yet")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.bad)
            }

            Text("Record this meeting?")
                .font(Theme.Typo.heading(26))
                .foregroundStyle(Theme.ink)

            Text("Alfie will listen to your microphone and to this call's audio, and write you notes when it ends.")
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.smallPrint)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.cosy) {
                Button(action: onCancel) {
                    Text("Not now")
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: copyLine) {
                    Text(copied ? Self.copiedTitle : Self.copyTitle)
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(copied ? Theme.good : Theme.accentDeep)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.copyTitle)

                Spacer()

                Button(action: onStart) {
                    Text("Start")
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, Theme.Space.wide)
                        .padding(.vertical, Theme.Space.small)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .fill(Theme.accent)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Theme.Space.small)
        }
        .padding(Theme.Space.section)
        .frame(width: 400)
        .background(Theme.raised)
    }

    /// "Copied" for two seconds, then the offer again — a second press
    /// copies again, which is what a person who lost the clipboard wants.
    private func copyLine() {
        guard Self.copy(announcement) else { return }
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

/// Presents the sheet over the main window and reports the answer once.
///
/// `onMeetingConsent` already hands us a completion rather than expecting a
/// return value, so nothing about the calling contract had to change to stop
/// using a modal run loop.
@MainActor
final class MeetingConsent {
    /// Held for the life of the sheet so it is not deallocated mid-question.
    private static var live: MeetingConsent?

    private var sheet: NSWindow?
    private let answer: (Bool) -> Void

    private init(answer: @escaping (Bool) -> Void) {
        self.answer = answer
    }

    static func ask(over parent: NSWindow, answer: @escaping (Bool) -> Void) {
        let consent = MeetingConsent(answer: answer)
        live = consent
        consent.present(over: parent)
    }

    private func present(over parent: NSWindow) {
        let view = MeetingConsentSheet(
            onStart: { [weak self] in self?.finish(true) },
            onCancel: { [weak self] in self?.finish(false) },
            announcement: MeetingOwner.announcement(userName: MeetingSession.ownerName()))
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        sheet = window
        parent.beginSheet(window) { _ in }
    }

    /// Idempotent: a double-click on Start must not answer twice.
    private func finish(_ yes: Bool) {
        guard let sheet else { return }
        self.sheet = nil
        sheet.sheetParent?.endSheet(sheet)
        Self.live = nil
        answer(yes)
    }
}
