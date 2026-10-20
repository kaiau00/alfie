import AppKit
import MoeDesign
import SwiftUI

/// The app's one way of saying something that needs an answer.
///
/// Everything meeting-shaped used to be an `NSAlert`, which is why the app had
/// two dialog systems: designed sheets in Connections and Onboarding, and
/// system alerts everywhere else. This is the other half of retiring them —
/// `MeetingConsentSheet` is its own view because its copy carries real legal
/// weight, and everything else routes through here.
///
/// Deliberately plain: a heading, a body, an optional detail, and at most two
/// buttons. A notice that needs more than that is a pane, not a sheet.
struct NoticeSheet: View {
    let title: String
    let body_: String
    var detail: String = ""
    /// Nil for a single-button notice.
    var confirm: String?
    var dismiss: String = "OK"
    var destructive = false
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(title)
                .font(Theme.Typo.heading(24))
                .foregroundStyle(Theme.ink)
                // Wraps, never truncates: a title that names things (the
                // sources a question is about) cut to "Calendar, P…" hid
                // exactly what was being asked (owner, 2026-09-29).
                .fixedSize(horizontal: false, vertical: true)

            Text(body_)
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .fill(Theme.sunk)
                    )
            }

            HStack(spacing: Theme.Space.cosy) {
                Button(action: onDismiss) {
                    Text(confirm == nil ? dismiss : "Not now")
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                if let confirm {
                    Button(action: onConfirm) {
                        Text(confirm)
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Space.wide)
                            .padding(.vertical, Theme.Space.small)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                    .fill(destructive ? Theme.bad : Theme.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, Theme.Space.small)
        }
        .padding(Theme.Space.section)
        .frame(width: 420)
        .background(Theme.raised)
    }
}

/// Shows a `NoticeSheet` over a window and reports which button was used.
@MainActor
final class Notice {
    private static var live: Notice?
    /// A notice is on screen now: a second question waits rather than
    /// replace it (a replaced one kept its sheet with dead buttons).
    static var showing: Bool { live != nil }

    private var sheet: NSWindow?
    private let answer: (Bool) -> Void

    private init(answer: @escaping (Bool) -> Void) {
        self.answer = answer
    }

    /// `answer(true)` means the confirm button; `false` means dismissed.
    /// Falls back to an `NSAlert` with no window to hang a sheet from, so a
    /// notice is never simply swallowed.
    static func show(over parent: NSWindow?,
                     title: String,
                     body: String,
                     detail: String = "",
                     confirm: String? = nil,
                     dismiss: String = "OK",
                     destructive: Bool = false,
                     answer: @escaping (Bool) -> Void = { _ in }) {
        guard let parent else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail.isEmpty ? body : "\(body)\n\n\(detail)"
            if let confirm { alert.addButton(withTitle: confirm) }
            alert.addButton(withTitle: confirm == nil ? dismiss : "Not now")
            NSApp.activate(ignoringOtherApps: true)
            let clicked = alert.runModal()
            answer(confirm != nil && clicked == .alertFirstButtonReturn)
            return
        }
        let notice = Notice(answer: answer)
        live = notice
        notice.present(over: parent, title: title, body: body, detail: detail,
                       confirm: confirm, dismiss: dismiss, destructive: destructive)
    }

    private func present(over parent: NSWindow, title: String, body: String,
                         detail: String, confirm: String?, dismiss: String,
                         destructive: Bool) {
        let view = NoticeSheet(
            title: title, body_: body, detail: detail,
            confirm: confirm, dismiss: dismiss, destructive: destructive,
            onConfirm: { [weak self] in self?.finish(true) },
            onDismiss: { [weak self] in self?.finish(false) })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        sheet = window
        parent.beginSheet(window) { _ in }
    }

    /// Idempotent, so a double-click cannot answer twice.
    private func finish(_ confirmed: Bool) {
        guard let sheet else { return }
        self.sheet = nil
        sheet.sheetParent?.endSheet(sheet)
        Self.live = nil
        answer(confirmed)
    }
}
