import MoeDesign
import SwiftUI

/// "Send this?" — drawn by Moe rather than by AppleScript.
///
/// What was here before was `display dialog`: a system alert with a caution
/// triangle, the blue folder icon macOS picks when a script has no bundle of
/// its own, the tool's raw id in the first line ("Send this
/// mcp__moe__gmail_send message?"), and the message pasted in as a wall of
/// text that had to be *cut off* at 1,800 characters because that dialog does
/// not scroll. The most consequential question the app ever asks looked like
/// an error from a script somebody left running.
///
/// Three things change here, and only one of them is decoration:
///
/// 1. **The message scrolls.** Nothing is truncated, so nobody is asked to
///    approve words the dialog itself admitted it was not showing them.
/// 2. **The recipient is the loudest thing on screen**, because it is the one
///    fact that decides whether a send is fine or a disaster.
/// 3. It looks like Moe — the same paper, ink, serif and periwinkle as the
///    rest of the app — so an approval prompt is recognisably *from the thing
///    you are talking to*. That is most of what a person has to go on when
///    the alternative is a convincing fake.
/// What a person changed before clicking Send. `nil` for a field they left
/// as it was, so a caller only ever rewrites what was actually rewritten.
struct ConfirmEdits {
    var body: String?
    var subject: String?
    var isEmpty: Bool { body == nil && subject == nil }
}

struct ConfirmSheet: View {
    let request: ConfirmRequest
    /// Send — with the person's edits when there are any, `nil` when the
    /// message goes exactly as it was shown.
    let onSend: (ConfirmEdits?) -> Void
    let onCancel: () -> Void
    /// "Always allow": run it, and never ask about this tool again. Offered
    /// only for acts — a message can never be allowed for good from here.
    let onAlways: () -> Void
    /// "Allow everything this session": send this, and let every browser
    /// and screen action in this conversation run unasked until it has been
    /// quiet for an hour. Offered only for sessions. Asked for on
    /// 2026-09-16 after a run of nine dialogs in four minutes over one X
    /// thread: "for this session … allow it to bypass all of this and do
    /// everything autonomously. There should be an option for that on the
    /// pop-up."
    let onAllowSession: () -> Void
    /// Called after "Show details" opens or closes, so the window can take
    /// the card's new height (main.swift). A no-op for a snapshot.
    let onResize: () -> Void

    /// The code or the arguments behind the card, shown on request. Closed by
    /// default: the sentence above it is what a person decides on.
    @State private var showDetail = false

    /// The message and subject as the person has them now. Seeded from the
    /// request, compared against it on Send: the dialog was read-only from
    /// the day it was written, and the one thing a person could do with a
    /// message that was nearly right was cancel it and ask again — which is
    /// a whole round trip, and a model that may write it differently the
    /// second time. Now the words can be fixed in place and go as fixed.
    @State private var editedBody: String
    @State private var editedSubject: String

    init(request: ConfirmRequest,
         onSend: @escaping (ConfirmEdits?) -> Void,
         onCancel: @escaping () -> Void,
         onAlways: @escaping () -> Void,
         onAllowSession: @escaping () -> Void = {},
         onResize: @escaping () -> Void = {}) {
        self.request = request
        self.onSend = onSend
        self.onCancel = onCancel
        self.onAlways = onAlways
        self.onAllowSession = onAllowSession
        self.onResize = onResize
        let parts = request.fields
        _editedBody = State(initialValue: parts.body)
        _editedSubject = State(initialValue: Self.subject(in: parts.headers) ?? "")
    }

    private static func subject(in headers: [(String, String)]) -> String? {
        headers.first(where: { $0.0.caseInsensitiveCompare("Subject") == .orderedSame })?.1
    }

    /// What changed, or nothing. Compared against the request rather than
    /// against a "dirty" flag: a person who edits and then edits back has
    /// changed nothing, and the message should go exactly as it was asked.
    private var edits: ConfirmEdits? {
        guard request.editable else { return nil }
        let parts = request.fields
        var out = ConfirmEdits()
        if editedBody != parts.body { out.body = editedBody }
        if request.subjectEditable, let original = Self.subject(in: parts.headers),
           editedSubject != original {
            out.subject = editedSubject
        }
        return out.isEmpty ? nil : out
    }

    @Environment(\.colorScheme) private var scheme

    private var service: (label: String, icon: String) {
        Service.identify(channel: request.channel, tool: request.tool, hint: request.service)
    }

    /// The table row that was matched, which is what `macNative` is keyed on.
    private var serviceKey: String {
        Service.identified(channel: request.channel, tool: request.tool,
                           hint: request.service).key
    }

    /// Apple's own channels have no brand mark to ship, and never will, so
    /// they get an SF Symbol instead. Keyed on the SERVICE KEY rather than on
    /// the icon name: iMessage's row carries no icon file, so testing the
    /// icon meant this list could never match and an iMessage confirmation
    /// always drew a coloured "I".
    /// `imessage` is the only one of these that `Service.known` carries, and
    /// it is the only one a MESSAGE can be addressed to — calls, notes,
    /// reminders and calendar are things Moe reads, not things it sends. The
    /// other four were dead entries dressed as a list.
    private static let macNative = ["imessage"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .overlay(WindowDragStrip())   // the handle (WindowDrag.swift)
            Rectangle().fill(Theme.rule).frame(height: Theme.Stroke.hair)
            content
            Rectangle().fill(Theme.rule).frame(height: Theme.Stroke.hair)
            footer
        }
        .frame(width: 480)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.edge)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            HStack(spacing: Theme.Space.snug) {
                Circle().fill(Theme.warn).frame(width: 7, height: 7)
                Text(request.sends ? "Nothing has been sent yet" : "Nothing has been done yet")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.warn)
            }

            HStack(alignment: .center, spacing: Theme.Space.base) {
                ServiceIcon(name: service.icon,
                            label: service.label,
                            macSymbol: Self.macNative.contains(serviceKey)
                                ? ServiceIcons.macSymbol(for: serviceKey) : nil,
                            size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    if !request.headline.isEmpty {
                        // What is being asked, and where, as one sentence.
                        // The service's mark stays beside it; its name would
                        // only repeat what the sentence says.
                        Text(ConfirmRequest.legibleLine(request.headline))
                            .font(Theme.Typo.heading(20))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                    Text(ConfirmRequest.legibleLine(service.label))
                        .font(Theme.Typo.heading(24))
                        .foregroundStyle(Theme.ink)
                        // Two lines at most, and rewritten like everything
                        // else: a service of "Gmail\nTo: dad@example.com"
                        // drew a two-line heading four times the size of the
                        // real recipient, claiming a different one.
                        .lineLimit(2)
                    Text(request.kind == "act" ? "Moe wants to run this. Read it first."
                         : request.kind == "session" ? "Moe wants to do this\(request.displayedTo.isEmpty ? "" : " on " + request.displayedTo). Read it first."
                         : request.editable ? "Moe wants to send this. Read it first — you can change the words before it goes."
                         : "Moe wants to send this. Read it first.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !request.origin.isEmpty {
                        // Not the turn you are in (ConfirmRequest.origin).
                        Text("Asked by \(ConfirmRequest.legibleLine(request.origin)), not by anything you just said.")
                            .font(Theme.Typo.ui(12, weight: .semibold))
                            .foregroundStyle(Theme.warn)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.top, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - What is being sent

    /// Past this the plain, non-scrolling branch is not worth measuring: a
    /// message this long is going to scroll whatever we decide.
    private static let scrollBeyond = 900

    private var content: some View {
        let parts = request.fields
        let shown = request.displayedBody
        // Chosen on a count, never by laying the message out twice.
        // `ViewThatFits` measures every branch it is offered, so a long body
        // was being composed twice before anything appeared at all.
        return Group {
            // An editor scrolls itself, at a height of its own (below), so
            // the outer scroll view would only ever fight it for the wheel.
            // Tall as well as long: 400 newlines is 400 characters and
            // several thousand points.
            if !request.editable && (shown.count > Self.scrollBeyond
                || shown.filter({ $0 == "\n" }).count > 12
                || parts.headers.count > 4) {
                ScrollView(.vertical) { body(of: parts, message: shown) }
                    .frame(height: 340)
            } else {
                body(of: parts, message: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunk)
    }

    private func body(of parts: (headers: [(String, String)], body: String),
                      message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            if request.steered {
                // Named, not silently rewritten: the characters below can make
                // a screen show one address and send another, which is the one
                // thing this dialog exists to prevent.
                Text("Some characters here can reorder text on screen. They are shown as ⟨U+202E⟩ so they cannot.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let confusable = request.confusableRecipient {
                Text(confusable)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A card with a headline has already said where, in words; a
            // message without one leads with who it goes to, loudest.
            if request.headline.isEmpty {
                field("To", request.displayedTo.isEmpty
                      ? "(not named — read the message below)" : request.displayedTo,
                      emphasis: true)
            }
            if let provenance = request.provenance, request.kind == "send" {
                provenanceNote(provenance)
            }
            ForEach(Array(parts.headers.enumerated()), id: \.offset) { _, header in
                if request.subjectEditable, header.0.caseInsensitiveCompare("Subject") == .orderedSame {
                    editableField("Subject", text: $editedSubject)
                } else {
                    field(header.0, header.1.isEmpty ? "—" : header.1)
                }
            }
            if request.editable {
                editableMessage
            } else if !request.headline.isEmpty {
                // Plain words under a plain heading: no label to decode.
                Text(message)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                field(request.kind == "session" ? "What Moe is about to do" : "Message",
                      message.isEmpty ? "(empty message)" : message, prose: true)
            }
            if !request.detail.isEmpty {
                detailBlock
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Who named the person above: quiet when it was the person, amber when
    /// Moe chose. Its own view so the rest of the sheet does not depend on it
    /// (see `ConfirmProvenance`).
    private func provenanceNote(_ provenance: ConfirmProvenance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provenance.line)
                .font(Theme.Typo.ui(11))
                .foregroundStyle(provenance.isWarning ? Theme.warn : Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(provenance.warnings, id: \.self) { warning in
                Text(warning)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The code, or the tool and what it is handed, behind "Show details":
    /// monospaced, smaller, quieter, in a box of its own that scrolls when it
    /// is long. A person who wants to read it can; a person who does not is
    /// not made to — until 2026-09-29 it was open on every card, and the
    /// owner read a card of Python as "technical and unsimple".
    private var detailBlock: some View {
        let text = ConfirmRequest.legible(request.detail).text
        let lines = text.filter { $0 == "\n" }.count + 1
        let height = min(180, max(44, CGFloat(lines) * 16 + 20))
        return VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Button(action: {
                showDetail.toggle()
                onResize()
            }) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: showDetail ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showDetail ? "Hide details" : "Show details")
                        .font(Theme.Typo.ui(11, weight: .medium))
                }
                .foregroundStyle(Theme.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDetail {
            ScrollView(.vertical) {
                Text(text)
                    .font(Theme.Typo.data(11))
                    .foregroundStyle(Theme.ink3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.small)
                    .padding(.vertical, Theme.Space.snug)
            }
            .frame(height: height)
            .background(editorBackground)
            }
        }
    }

    /// A one-line field the person may rewrite: the subject.
    private func editableField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(label.uppercased())
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, Theme.Space.snug)
                .background(editorBackground)
        }
    }

    /// The message, as an editor rather than a label. Sized from the text
    /// so a two-line note is not a 340pt box, and capped so a long one
    /// scrolls inside the editor instead of pushing the buttons off screen.
    private var editableMessage: some View {
        let lines = editedBody.filter { $0 == "\n" }.count + 1
        let height = min(340, max(96, CGFloat(lines) * 21 + 24))
        return VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("MESSAGE")
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            TextEditor(text: $editedBody)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Theme.Space.snug)
                .padding(.vertical, Theme.Space.snug)
                .frame(height: height)
                .background(editorBackground)
        }
    }

    /// A field that reads as a field: the raised paper on the sunk ground,
    /// with the same hairline the rest of the dialog rules itself with.
    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair)
            )
    }

    private func field(_ label: String, _ value: String,
                       emphasis: Bool = false, prose: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(label.uppercased())
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            Text(value)
                .font(emphasis ? Theme.Typo.ui(15, weight: .semibold)
                      : prose ? Theme.Typo.prose(14) : Theme.Typo.ui(13))
                .foregroundStyle(emphasis ? Theme.ink : Theme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - The decision

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            HStack(spacing: Theme.Space.cosy) {
                Button(action: onCancel) {
                    HStack(spacing: Theme.Space.snug) {
                        Text(request.cancelLabel)
                            .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                        Text("esc")
                            .font(Theme.Typo.data(10))
                            .opacity(0.75)
                    }
                    .foregroundStyle(Theme.ink2)
                    // The same padding as Send. Bare text gave the reversible
                    // answer a hit area several times smaller than the
                    // irreversible one, which is backwards for a dialog whose
                    // whole job is to make sending deliberate.
                    .padding(.horizontal, Theme.Space.roomy)
                    .padding(.vertical, Theme.Space.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                            .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
                    )
                    // The whole pill, not just its outline and its letters: a
                    // .plain button hit-tests only what it draws, and this
                    // one draws a hairline and two words.
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                if request.kind == "session" {
                    // No keyboard shortcut, as for Always allow: a decision
                    // that outlives this dialog is made with the pointer.
                    Button(action: onAllowSession) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Allow everything this session")
                                .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                            Text("browser and screen, until it goes quiet for an hour")
                                .font(Theme.Typo.ui(10))
                                .opacity(0.75)
                        }
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, Theme.Space.roomy)
                        .padding(.vertical, Theme.Space.small)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
                        )
                    }
                    .buttonStyle(.plain)
                }
                if request.kind == "act" {
                    // No keyboard shortcut on purpose: a decision that outlives
                    // this dialog is made with the pointer.
                    Button(action: onAlways) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Always allow")
                                .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                            Text("don’t ask about this again")
                                .font(Theme.Typo.ui(10))
                                .opacity(0.75)
                        }
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, Theme.Space.roomy)
                        .padding(.vertical, Theme.Space.small)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Return is bound to nothing at all, deliberately. The
                // AppleScript dialog made it Cancel (`default button
                // "Cancel"`) on the sound instinct that the key people press
                // without reading must not be the key that sends — but doing
                // that here means an invisible zero-size button holding the
                // Return shortcut, and an unseen control that can answer this
                // dialog is not something to add on purpose. Escape cancels,
                // Return does nothing, and sending takes a click or ⌘Return.

                Spacer()

                Button(action: { onSend(edits) }) {
                    HStack(spacing: Theme.Space.snug) {
                        Text(edits == nil ? request.action : "\(request.action) edited")
                            .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                        Text("⌘↩")
                            .font(Theme.Typo.ui(11))
                            .opacity(0.7)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, Theme.Space.roomy)
                    .padding(.vertical, Theme.Space.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                            .fill(Theme.accent)
                    )
                }
                .buttonStyle(.plain)
                // Two keys, not one. Sending is the only thing in this dialog
                // that cannot be undone.
                .keyboardShortcut(.return, modifiers: .command)
            }

            // The tool id, quietly. A person should be able to find out
            // exactly what asked — but they should not have to read it to
            // answer, which is what the old dialog made them do.
            if !request.tool.isEmpty {
                Text(ConfirmRequest.legibleLine(request.tool))
                    .lineLimit(1)
                    .font(Theme.Typo.data(10))
                    .foregroundStyle(Theme.ink3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
