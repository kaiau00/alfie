import AppKit
import MoeChat
import MoeIsland
import MoeVoice
import MoeDesign
import SwiftUI
import UniformTypeIdentifiers

/// Chat.
///
/// The old version was a `LazyVStack` of plain `Text` — no markdown, no
/// timestamps, no way back to a finished conversation, and no sign of what
/// Moe had actually done. All the interesting telemetry already existed on
/// `Conductor` and simply was not rendered.
///
/// Three things changed. Conversations persist and are listed, so ⌘N files a
/// thread rather than destroying it. Replies render markdown, with code in its
/// own well. And tool activity appears as chips in the plain language
/// `describeTool` already writes — collapsed by default, opened on click,
/// never a function name.
struct ChatPane: View {
    @ObservedObject var conductor: Conductor

    @State private var typed = ""
    /// Photos and files waiting to go with the next message.
    @State private var attachments: [ChatAttachment] = []
    @State private var dropTargeted = false
    @State private var threads: [ConversationStore.Conversation] = []
    @State private var openTools: Set<UUID> = []
    @State private var confirmDelete: String?
    /// The conversation as one page a drag can run across (`Transcript`).
    @State private var selecting = false
    @ObservedObject private var ax = AccessibilityWatch.shared

    var body: some View {
        HStack(spacing: 0) {
            sessions
            Rectangle().fill(Theme.rule).frame(width: 1)
            thread
        }
        .background(Theme.raised)
        .onAppear {
            reloadThreads()
            // Older threads get their short AI names, a few at a time.
            conductor.nameUntitledConversations()
        }
        // A thread is filed when a reply lands, so the list refreshes then.
        .onChange(of: conductor.turns.count) { _, _ in reloadThreads() }
        // And when another device's turns arrive through the cloud.
        .onReceive(NotificationCenter.default.publisher(for: .moeConversationsChanged)) { _ in
            reloadThreads()
        }
    }

    // MARK: - Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversations")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button {
                    conductor.newConversation()
                    reloadThreads()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Start a fresh conversation (⌘N)")
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.top, Theme.Space.cosy)
            .padding(.bottom, Theme.Space.small)

            if threads.isEmpty {
                Text("Nothing yet")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, Theme.Space.base)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(grouped, id: \.0) { day, items in
                        Text(day)
                            .font(Theme.Typo.label(9))
                            .tracking(Theme.tracking)
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, Theme.Space.small)
                            .padding(.top, Theme.Space.base)
                            .padding(.bottom, Theme.Space.tight)
                        ForEach(items) { convo in
                            threadRow(convo)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.snug)
                .padding(.bottom, Theme.Space.base)
            }
        }
        .frame(width: 172)
        .background(Theme.paper)
        .confirmationDialog("Delete this conversation?",
                            isPresented: .init(get: { confirmDelete != nil },
                                               set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete { conductor.deleteConversation(id: id) }
                confirmDelete = nil
                reloadThreads()
            }
        } message: {
            Text("The daily log in your history folder keeps the text either way.")
        }
    }

    private func threadRow(_ convo: ConversationStore.Conversation) -> some View {
        let on = convo.id == conductor.currentConversationID
        return Button {
            conductor.openConversation(id: convo.id)
        } label: {
            Text(convo.title)
                .font(Theme.Typo.ui(12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.ink : Theme.ink2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, Theme.Space.snug)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(on ? Theme.selected : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { confirmDelete = convo.id }
        }
    }

    // MARK: - Thread

    private var thread: some View {
        VStack(spacing: 0) {
            if !conductor.turns.isEmpty { copyBar }
            ScrollViewReader { proxy in
                ScrollView {
                    if selecting {
                        // One text, so a selection can run from any message
                        // to any other; ⌘A takes the lot.
                        Text(Transcript.styled(conductor.turns))
                            .font(Theme.Typo.prose(14))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.section)
                            .padding(.vertical, Theme.Space.wide)
                        // The same anchor as the list, so toggling Select
                        // keeps the reader where they were: at the end.
                        Color.clear.frame(height: 1).id("bottom")
                    } else {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.roomy) {
                        if conductor.turns.isEmpty { greeting }
                        ForEach(conductor.turns) { turn in
                            TurnRow(turn: turn,
                                    expanded: openTools.contains(turn.id),
                                    toggle: { toggleTools(turn.id) },
                                    play: canPlay(turn) ? { conductor.playPauseReply(turn.id) } : nil,
                                    restart: { conductor.restartReply() },
                                    voiceState: conductor.voiceState(of: turn.id),
                                    readFromTop: canPlay(turn) ? { conductor.playReply(turn.id) } : nil,
                                    forgetNoted: { conductor.forgetNoted(turnID: turn.id, claim: $0) },
                                    copyAll: { Transcript.copy(Transcript.plain(conductor.turns)) })
                                .id(turn.id)
                        }
                        if !conductor.partial.isEmpty {
                            TurnRow(turn: Turn(role: .you, text: conductor.partial),
                                    expanded: false, toggle: {})
                                .opacity(0.45)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, Theme.Space.section)
                    .padding(.vertical, Theme.Space.wide)
                    }
                }
                .onChange(of: conductor.turns.count) { _, _ in
                    withAnimation(Theme.Motion.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // Swapping the list for the page rebuilds the scroll content,
                // which lands at the top; send it back to the latest message.
                .onChange(of: selecting) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if !ax.granted { talkKeyBanner }
            ForEach(conductor.fixOffers) { offer in
                ChatFixBanner(offer: offer,
                              perform: { conductor.performFix(offer) },
                              dismiss: { conductor.dismissFix(offer) })
            }
            if conductor.inConversation { liveBar }
            composer
        }
        // Anywhere on the thread, not only the box: a drop target the size
        // of a text field is one a drag has to be aimed at.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { attachments.append(contentsOf: await AttachmentIntake.take(providers)) }
            return true
        }
        .overlay { if dropTargeted { dropHint } }
    }

    private var copyBar: some View {
        ChatCopyBar(selecting: $selecting) { Transcript.copy(Transcript.plain(conductor.turns)) }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.raised.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: Theme.Stroke.edge, dash: [6, 4]))
            )
            .overlay {
                VStack(spacing: Theme.Space.snug) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Drop to give it to Moe")
                        .font(Theme.Typo.heading(20))
                        .foregroundStyle(Theme.ink)
                    Text("Photos, PDFs, documents — anything on your Mac")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .padding(Theme.Space.base)
            .allowsHitTesting(false)
    }

    /// The talk key is dead until Accessibility is on, and chat is one of the
    /// places a person looks when it is. Gone the moment the grant lands.
    private var talkKeyBanner: some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: "keyboard")
                .foregroundStyle(Theme.warn)
            Text(ax.problem(for: conductor.config.talkKey))
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.small)
            PaneButton(title: "Fix") { ax.fix() }
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.warn.opacity(0.08))
    }

    /// The shortcut as configured, never a hard-coded one: the default is
    /// ⌃⌥Space (Config.hotKeyModifiers) and this said ⌥Space.
    private var talkKey: String {
        HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text("Hey. What's up?")
                .font(Theme.Typo.display(30))
                .foregroundStyle(Theme.ink)
            Text("Press \(talkKey) and talk, or type below. Ask about your calendar, notes, tasks, files — anything.")
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
        .padding(.top, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.small)
    }

    /// Only while a spoken conversation is open — it says whose turn it is,
    /// which is the thing you cannot tell from a microphone being on.
    private var liveBar: some View {
        HStack(spacing: Theme.Space.small) {
            // Muted mirrors the island's red pill: the same value
            // (`Conductor.micMuted`), the same words, the same colour.
            if conductor.micMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.bad)
            } else {
                Circle()
                    .fill(conductor.mode == .listening ? Theme.bad : Theme.ink3)
                    .frame(width: 6, height: 6)
            }
            Text(conductor.micMuted
                 ? ConversationControls.mutedLine
                 : conductor.mode == .listening
                 ? "Your turn — just talk, no wake word needed"
                 : conductor.mode == .thinking ? "Thinking…" : "Speaking…")
                .font(Theme.Typo.ui(11, weight: conductor.micMuted ? .semibold : .regular))
                .foregroundStyle(conductor.micMuted ? Theme.bad : Theme.ink2)
            Spacer()
            // One direction per label: the word on the button is what it
            // does, even if the state moved under the click.
            Button(conductor.micMuted ? "Unmute" : "Mute") { [muted = conductor.micMuted] in
                conductor.setMicMuted(!muted, from: "chat's \(muted ? "Unmute" : "Mute") button")
            }
                .buttonStyle(.plain)
                .font(Theme.Typo.ui(11, weight: .semibold))
                .foregroundStyle(conductor.micMuted ? Theme.bad : Theme.accentDeep)
                .help(conductor.micMuted ? ConversationControls.unmuteHelp
                                         : ConversationControls.muteHelp)
            Button("End conversation") { conductor.endConversation() }
                .buttonStyle(.plain)
                .font(Theme.Typo.ui(11, weight: .semibold))
                .foregroundStyle(Theme.accentDeep)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.accentTint)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
        if !attachments.isEmpty { AttachmentTray(attachments: $attachments) }
        HStack(spacing: Theme.Space.base) {
            AddAttachmentButton { attachments.append(contentsOf: $0) }

            // Grows to six lines, then scrolls with the trackpad
            // (`ComposerEditor`); Return sends, Shift-Return is a new line.
            ComposerEditor(text: $typed,
                           placeholder: conductor.meeting.isRecording ? "Ask Moe — quietly" : "Ask Moe",
                           size: 13, lineHeight: 18, maxLines: 6,
                           ink: Theme.ink, placeholderInk: Theme.ink3,
                           onSubmit: send)
                // Another screen handed over something to say (Memory's
                // "Answer"): it lands in the box, unsent, for the person
                // to finish or change.
                .onAppear { takeDraft() }
                .onChange(of: conductor.chatDraft) { _, _ in takeDraft() }

            Button(action: { conductor.toggle() }) {
                Image(systemName: conductor.mode == .listening ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(conductor.mode == .listening ? Theme.accent : Theme.ink3)
            }
            .buttonStyle(.plain)
            .help("Talk to Moe (\(talkKey))")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(sendable ? Theme.accent : Theme.ink3))
            }
            .buttonStyle(.plain)
            .disabled(!sendable)
            .help("Send")
        }
        }
        .padding(.leading, Theme.Space.base)
        .padding(.trailing, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.base)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.edge)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.paper)
        )
        .padding(.horizontal, Theme.Space.section)
        .padding(.bottom, Theme.Space.roomy)
        .padding(.top, Theme.Space.small)
    }

    private var sendable: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: - Actions

    private func takeDraft() {
        guard let draft = conductor.chatDraft, !draft.isEmpty else { return }
        typed = draft
        conductor.chatDraft = nil
    }

    private func send() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !t.isEmpty || !files.isEmpty else { return }
        typed = ""
        attachments = []
        conductor.submit(t, origin: .typed, starter: .person, attachments: files)
    }

    /// ▶ on a finished reply of Moe's, and not while a turn is being worked
    /// on: that reply owns the voice (`Conductor.playReply` refuses too).
    /// One rule for the chat and the island (`Conductor.canPlayReply`).
    private func canPlay(_ turn: Turn) -> Bool { conductor.canPlayReply(turn) }

    private func toggleTools(_ id: UUID) {
        if openTools.contains(id) { openTools.remove(id) } else { openTools.insert(id) }
    }

    private func reloadThreads() {
        threads = conductor.conversations()
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private var grouped: [(String, [ConversationStore.Conversation])] {
        var order: [String] = []
        var byDay: [String: [ConversationStore.Conversation]] = [:]
        for convo in threads {
            let key = Self.day.string(from: convo.updatedAt)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(convo)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }
}

// MARK: - Turn

struct TurnRow: View {
    let turn: Turn
    var expanded: Bool = false
    var toggle: () -> Void = {}
    /// Read this reply out; nil where nothing may be played (a turn still
    /// being written, the live partial).
    var play: (() -> Void)? = nil
    /// From the top again — offered only on the reply whose voice is out.
    var restart: () -> Void = {}
    /// This reply's voice: ▶ when silent or paused, ⏸ while it plays.
    var voiceState: ReplyVoice = .silent
    /// The ⋯ menu's "Read it from the top"; nil where nothing may be played.
    var readFromTop: (() -> Void)? = nil
    /// Undo on a "Noted" line under this answer: forget that claim.
    var forgetNoted: (String) -> Void = { _ in }
    /// Right-click › Copy conversation.
    var copyAll: (() -> Void)? = nil

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Two sides. Every turn used to sit on the left in the same serif and the
    /// same ink, told apart only by a nine-point "YOU" or "MOE" above it, so
    /// finding where you had asked something meant reading labels.
    var body: some View {
        Group {
            switch turn.role {
            case .you: yours
            case .moe: moes
            case .system: note
            }
        }
        // Every message copies, yours as well as Moe's (2026-09-29).
        .contextMenu {
            if !turn.text.isEmpty {
                Button("Copy message") { Transcript.copy(turn.text) }
            }
            if let copyAll { Button("Copy conversation", action: copyAll) }
        }
    }

    /// Yours: on the right, on the accent's tint, in the sans you typed it in.
    private var yours: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.snug) {
            if !turn.attachments.isEmpty { SentAttachments(attachments: turn.attachments) }
            if !turn.text.isEmpty {
                Text(MarkdownText.styled(turn.text))
                    .font(Theme.Typo.ui(14))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.small)
                    .background(bubble.fill(Theme.bubble))
                    .overlay(bubble.strokeBorder(Theme.bubbleRule, lineWidth: Theme.Stroke.hair))
            }
            Text(Self.clock.string(from: turn.at))
                .font(Theme.Typo.data(9))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: 460, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The corner nearest the edge it came from is the tight one.
    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card,
                               bottomLeadingRadius: Theme.Radius.card,
                               bottomTrailingRadius: Theme.Radius.row / 2,
                               topTrailingRadius: Theme.Radius.card,
                               style: .continuous)
    }

    /// Moe's: on the left, its mark and name, the reading serif at full ink.
    private var moes: some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            Text("M")
                .font(Theme.Typo.heading(13))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accent))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                HStack(spacing: Theme.Space.small) {
                    Text("Moe")
                        .font(Theme.Typo.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(Self.clock.string(from: turn.at))
                        .font(Theme.Typo.data(9))
                        .foregroundStyle(Theme.ink3)
                    if let play {
                        replyButton(voiceState == .playing ? "pause.fill" : "play.fill",
                                    lit: voiceState != .silent,
                                    help: voiceState == .playing ? "Pause — ▶ carries on from here"
                                        : voiceState == .paused ? "Carry on from where it paused"
                                        : "Read this aloud",
                                    action: play)
                        if voiceState != .silent {
                            replyButton("arrow.counterclockwise", lit: false,
                                        help: "Start it again from the top", action: restart)
                        }
                    }
                    if !turn.isStreaming, !turn.text.isEmpty {
                        Menu {
                            ReplyMenuItems(text: turn.text, readFromTop: readFromTop)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.ink3)
                                .frame(width: 20, height: 18)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                        .strokeBorder(Theme.rule, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                        .accessibilityLabel("More for this answer")
                    }
                }
                .frame(height: 24)

                if !turn.tools.isEmpty { chips }

                MarkdownText(turn.text)
                    .font(Theme.Typo.prose(15))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: Theme.measure, alignment: .leading)

                if !turn.links.isEmpty { sources }

                if !turn.noted.isEmpty {
                    NotedLines(facts: turn.noted, style: .chat, forget: forgetNoted)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Neither side's: centred, small and quiet.
    private var note: some View {
        Text(MarkdownText.styled(turn.text))
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.tight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.sunk))
            .frame(maxWidth: Theme.measure)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Hear it. A typed conversation is read on a screen, and sometimes the
    /// answer is better heard — so every reply can be played in Moe's voice,
    /// and paused and carried on with a tap of the talk key like any other.
    private func replyButton(_ symbol: String, lit: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(lit ? Theme.accent : Theme.ink3)
                .frame(width: 20, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Collapsed by default. One line each, in the words `describeTool`
    /// already produces — the expansion shows the same list, not raw output.
    private var chips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button(action: toggle) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                    Text(summary)
                        .font(Theme.Typo.ui(11, weight: .medium))
                }
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.rule, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(turn.tools.enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .font(Theme.Typo.data(10))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .padding(Theme.Space.small)
                .frame(maxWidth: Theme.measure, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Theme.sunk)
                )
            }
        }
        .animation(Theme.Motion.easeOut, value: expanded)
    }

    private var summary: String {
        turn.tools.count == 1
            ? turn.tools[0]
            : "\(turn.tools.count) steps"
    }

    /// The pages this answer came from, as links you can click. Read off
    /// the tool calls Moe made, so this is where it went — not where it
    /// says it went. Always shown when there are any: a source you have to
    /// ask for twice is the bug this fixes.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            ForEach(turn.links, id: \.url) { link in
                if let url = URL(string: link.url) {
                    Link(destination: url) {
                        Text(link.label)
                            .font(Theme.Typo.ui(11))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help(link.url)
                }
            }
        }
        .padding(.top, Theme.Space.tight)
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }
}

// MARK: - Markdown

/// Replies arrive as markdown and used to render as literal asterisks.
///
/// Inline styling goes through `AttributedString`; the blocks come from
/// `ReplyBlocks`, the same split the island draws from. Fenced code gets its
/// own well, because a monospaced block inside justified serif prose is the
/// one case where the text really is a different kind of thing. A quote —
/// almost always a draft Moe wrote for you, an email or a message — is a
/// card, the way a mail client shows a message, rather than a column of ">"
/// down the page (the owner, 2026-09-25).
struct MarkdownText: View {
    private let blocks: [ReplyBlock]

    init(_ text: String) {
        self.blocks = ReplyBlocks.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(Self.styled(s))
                case .heading(let s):
                    Text(Self.styled(s)).fontWeight(.semibold)
                case .quote(let s):
                    Text(Self.styled(s))
                        .textSelection(.enabled)
                        .padding(Theme.Space.base * 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                                .fill(Theme.sunk)
                        )
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s)
                            .font(Theme.Typo.data(12))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                            .padding(Theme.Space.base)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .fill(Theme.sunk)
                    )
                }
            }
        }
    }

    /// Inline only, and whitespace preserved: full markdown parsing collapses
    /// the line breaks that make a list a list.
    ///
    /// `BareLinks.autolink` runs first so a bare `https://example.com` — far
    /// and away the commonest shape a model writes — arrives at the parser as
    /// markdown it already knows how to make clickable. Without it the
    /// renderer links `[label](href)` and leaves every bare address as flat
    /// prose you have to select and copy by hand.
    static func styled(_ s: String) -> AttributedString {
        ReplyMarkdown.inline(s)
    }
}

/// What the ⋯ on one of Moe's answers offers — in the chat window and on the
/// island alike, so the two menus are one menu.
struct ReplyMenuItems: View {
    let text: String
    /// Nil where nothing may be played (`Conductor.canPlayReply`).
    var readFromTop: (() -> Void)?

    var body: some View {
        Button("Copy") { Self.copy(text) }
        if let readFromTop {
            Button("Read it from the top", action: readFromTop)
        }
    }

    /// The answer as written, markdown and all — what was said, not a
    /// rendering of it.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A tool failed for a reason the person can fix (`FixOffer`): the same card
/// the island shows, where the talk-key row sits in Chat.
struct ChatFixBanner: View {
    let offer: FixOffer
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(Theme.warn)
            Text(offer.why)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.small)
            if let title = offer.actionTitle {
                PaneButton(title: title, prominent: true, action: perform)
            }
            PaneButton(title: FixOffer.dismiss, action: dismiss)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.small)
        .background(Theme.warn.opacity(0.08))
    }
}

/// Select (the conversation as one page to drag across) and Copy all — a
/// slim bar of its own above the thread, never floating over the text.
struct ChatCopyBar: View {
    @Binding var selecting: Bool
    let copyAll: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            if selecting {
                Text("Drag across any messages, or press ⌘A, then ⌘C.")
                    .font(Theme.Typo.ui(11.5))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PaneButton(title: selecting ? "Done" : "Select",
                       symbol: selecting ? "checkmark" : "text.cursor") { selecting.toggle() }
                .help(selecting ? "Back to the conversation"
                                : "Show the conversation as one page, to select across messages")
            PaneButton(title: "Copy all", symbol: "doc.on.doc", action: copyAll)
                .help("Copy the whole conversation")
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, 6)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}
