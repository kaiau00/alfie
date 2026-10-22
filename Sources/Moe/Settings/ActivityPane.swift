import AppKit
import MoeDesign
import SwiftUI

/// Settings › Activity: what Moe has been doing, in time order.
///
/// The screen exists because most of what Moe does happens where nobody
/// is looking. A reply on Telegram never touches the app. A briefing at
/// seven in the morning runs, delivers and is gone. A watch job stops
/// working and the only sign is a line in a log nobody opens. This is the
/// one place all of that lands.
///
/// **Three rules, and none of them is a preference.**
///
/// *No message bodies.* The activity hook records when, where, which
/// model and how many characters, and nothing else — its own header
/// explains that a log of both sides of every conversation on every
/// platform would be the best prize in `~/.moe`. So a row about a
/// Telegram reply says that it happened and says plainly that Moe does
/// not know what was in it. The words live in the conversation, under the
/// person's own key.
///
/// *Nothing here is a health check.* `gateway.log` is not a complete
/// record of what Hermes did — some of it is written to `agent.log`
/// instead, and `Loaded hook '<name>'` is a bare `print()` that reaches
/// no file at all — and a check built on the first of those told a
/// healthy machine it was broken. The log is shown as a log, behind a
/// disclosure, described as incomplete and unfiltered.
///
/// *This Mac only.* Moe Away keeps its logs on its own machine. The
/// heading says so, because a timeline that stayed silent about it would
/// be read as "Moe did nothing away".
///
/// **Moe's own upkeep is folded away by default.** Seven jobs tick every
/// few minutes; on this Mac that is about 250 runs a day against a
/// handful of things a person did. Shown when asked for, never mixed into
/// the answer to "what happened today".
@MainActor
struct ActivityPane: View {
    @ObservedObject var conductor: Conductor

    /// Opens with the upkeep rows and the raw log already showing.
    /// Only `--settings-snapshot` passes either — the two halves of this
    /// pane no scroll position can reach, the same reason `VoicePane`
    /// takes its tab.
    init(conductor: Conductor, showingUpkeep: Bool = false, showingLog: Bool = false, embedded: Bool = false) {
        self.embedded = embedded
        self.conductor = conductor
        _upkeep = State(initialValue: showingUpkeep)
        _rawLog = State(initialValue: showingLog)
    }

    /// Nil until asked, and nil again when nothing answered at all. A
    /// reader that answered and refused arrives with `ok` false and words
    /// to show. Three states, not two.
    @State private var feed: Activity.Feed?
    @State private var asked = false
    @State private var days = 7
    @State private var upkeep: Bool
    @State private var rawLog: Bool

    /// The windows offered. A day is "what happened while I was out"; a
    /// week is the unit the run ledger and the incident store are both
    /// already keeping.
    private static let windows = [1, 7, 30]

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                PaneHeader(title: "Activity") {
                    PaneButton(title: "Refresh", symbol: "arrow.clockwise") { load() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack {
                        window
                        Spacer(minLength: 0)
                        if embedded { PaneButton(title: "Refresh", symbol: "arrow.clockwise") { load() } }
                    }
                    // Two states, and they are the two there are.
                    // `Activity.timeline` never returns nothing: a source
                    // it could not read comes back as `ok` false with a
                    // sentence, and the sources it *could* read are still
                    // in the list underneath. A pane that drew nothing
                    // because one of four readers failed would be lying
                    // about the other three.
                    if let feed {
                        if !feed.error.isEmpty { PaneBanner(tone: .warn, text: feed.error) }
                        timeline(feed)
                        if feed.trimmed > 0 {
                            Text("\(feed.trimmed) older \(feed.trimmed == 1 ? "thing is" : "things are") not shown. Narrow the window to see further back in detail.")
                                .font(Theme.Typo.prose(13))
                                .foregroundStyle(Theme.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: Theme.measure, alignment: .leading)
                        }
                        upkeepToggle(feed)
                        // Hermes's raw log is for the rare look: under More,
                        // as Settings › Voice keeps its rarely-touched rows.
                        VStack(alignment: .leading, spacing: 0) {
                            Rectangle().fill(Theme.rule).frame(height: 1).padding(.bottom, 4)
                            Calm.MoreToggle(open: $logOpen, hint: "Hermes's own log for this Mac")
                            if logOpen { logSection(feed).padding(.leading, 20) }
                        }
                    } else {
                        checking("Looking at what Alfie has been doing…")
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.raised)
        .onAppear(perform: load)
    }

    // MARK: - Copy

    /// Drawn inside Settings › History (2026-09-28): no header of its own.
    var embedded = false
    @State private var logOpen = false

    private var window: some View {
        // The pill track Settings › Voice uses for a short choice.
        Calm.Segments(options: Self.windows.map { (String($0), label(days: $0)) },
                      selection: Binding(get: { String(days) }, set: { pick in
                          guard let n = Int(pick), n != days else { return }
                          days = n
                          load()
                      }))
    }

    private func label(days: Int) -> String {
        switch days {
        case 1: return "Today"
        case 7: return "This week"
        default: return "Last \(days) days"
        }
    }

    // MARK: - The timeline

    private func shown(_ feed: Activity.Feed) -> [Activity.Event] {
        // A failure is never folded away, whoever's job it was. The point
        // of hiding upkeep is that its successes are noise; its failures
        // are the reason this screen exists.
        feed.events.filter { upkeep || !$0.upkeep || $0.kind == .incident }
    }

    @ViewBuilder
    private func timeline(_ feed: Activity.Feed) -> some View {
        let events = shown(feed)
        if events.isEmpty {
            SettingGroup(title: label(days: days)) {
                Text(feed.ok
                     ? "Nothing in this window. Alfie has been quiet."
                     : "Nothing Alfie could read.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.base)
            }
        } else {
            // Grouped by day, because that is the question — "what
            // happened yesterday" — and a flat list of forty rows with
            // forty timestamps answers it much more slowly.
            ForEach(groups(events), id: \.0) { heading, items in
                SettingGroup(title: heading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, event in
                        row(event, last: i == items.count - 1)
                    }
                }
            }
        }
    }

    /// Days in the order the events are already in — newest first — so
    /// nothing is re-sorted here and the headings cannot disagree with
    /// the rows under them.
    private func groups(_ events: [Activity.Event]) -> [(String, [Activity.Event])] {
        var out: [(String, [Activity.Event])] = []
        for event in events {
            let heading = Activity.day(event.at)
            if out.last?.0 == heading {
                out[out.count - 1].1.append(event)
            } else {
                out.append((heading, [event]))
            }
        }
        return out
    }

    private func row(_ event: Activity.Event, last: Bool) -> some View {
        SettingRow(title: mark(event) + "  " + event.title,
                   detail: event.detail,
                   note: under(event),
                   last: last) {
            // A conversation is the only row with anywhere to go. A job
            // has no words, and a turn that happened elsewhere has none
            // that reached this Mac — offering an Open on either would be
            // a button that lands nowhere.
            if !event.thread.isEmpty {
                PaneButton(title: "Read", symbol: "text.alignleft") {
                    // The thread goes through a static rather than the
                    // notification, because Settings reuses one window: if
                    // Chats is already mounted nothing is constructed and
                    // no initialiser would see it. `ChatsPane` consumes it
                    // on appearing and on being asked for again.
                    ChatsPane.pendingThread = event.thread
                    NotificationCenter.default.post(
                        name: .moeShowSection, object: nil,
                        userInfo: ["section": MainWindow.Section.chats.rawValue])
                }
            }
        }
    }

    /// A mark rather than a coloured dot: four kinds of row, and colour
    /// alone would say "this one is bad" about the one that is merely
    /// somewhere else.
    ///
    /// All four are codepoints whose *default* presentation is emoji.
    /// `🕰` (U+1F570) is not — it defaults to text and needs U+FE0F after
    /// it — and it rendered as a pale outline beside three solid marks
    /// until this was measured in the snapshot.
    private func mark(_ event: Activity.Event) -> String {
        switch event.kind {
        case .talked: return "💬"
        case .elsewhere: return "📱"
        case .job: return "⏰"
        case .incident: return "⚠️"
        }
    }

    private func under(_ event: Activity.Event) -> String? {
        var parts: [String] = []
        if !event.note.isEmpty { parts.append(event.note) }
        if event.upkeep { parts.append("Part of Alfie's own upkeep.") }
        let line = parts.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    // MARK: - Upkeep

    @ViewBuilder
    private func upkeepToggle(_ feed: Activity.Feed) -> some View {
        let hidden = feed.events.filter { $0.upkeep && $0.kind != .incident }.count
        if hidden > 0 || upkeep {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                PaneButton(title: upkeep ? "Hide Alfie's own upkeep"
                                         : "Show Alfie's own upkeep (\(hidden))",
                           symbol: upkeep ? "eye.slash" : "eye") {
                    upkeep.toggle()
                }
                Text("Alfie keeps itself current on a clock of its own: reading what changed, learning about you, watching what you asked it to watch, and picking up work handed back from Alfie Away. That is a few hundred runs a day and almost none of it is about you, so it is folded away — but a run that failed is never folded away, whoever's job it was.")
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
    }

    // MARK: - The raw log

    @ViewBuilder
    private func logSection(_ feed: Activity.Feed) -> some View {
        SettingGroup(title: "Underneath") {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                Text(feed.log.note.isEmpty
                     ? "Hermes keeps its own log for this Mac. It is not a complete record of what Hermes did, and it is not filtered."
                     : feed.log.note)
                    .font(Theme.Typo.prose(12.5))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                if feed.log.missing {
                    // Named only when there is a name. Found by rendering:
                    // an answer that never arrived leaves `path` empty and
                    // this read "There is no log at  yet." — a sentence
                    // with a hole where its subject should be.
                    Text(feed.log.path.isEmpty
                         ? "Alfie couldn't find Hermes's log on this Mac."
                         : "There is no log at \(feed.log.path) yet.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                } else {
                    HStack(spacing: Theme.Space.base) {
                        PaneButton(title: rawLog ? "Hide the raw log" : "Show the raw log",
                                   symbol: rawLog ? "chevron.up" : "chevron.down") {
                            rawLog.toggle()
                        }
                        PaneButton(title: "Reveal in Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: feed.log.path)])
                        }
                    }
                    if rawLog { lines(feed.log.lines) }
                }
            }
            .padding(.vertical, Theme.Space.base)
        }
    }

    /// Monospaced, scrolling sideways rather than wrapping: a wrapped log
    /// line loses the column that says which component wrote it, which is
    /// most of what a log line is for.
    private func lines(_ lines: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(Theme.Space.small)
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.sidebar)
        )
    }

    // MARK: - Loading

    private func load() {
        let window = days
        Task {
            let f = await ScriptRunner.offMain { Activity.timeline(days: window) }
            await MainActor.run {
                // Ignore an answer for a window the person has already
                // moved off: two overlapping loads used to land in the
                // order they finished rather than the order they were
                // asked for.
                guard window == days else { return }
                feed = f
                asked = true
            }
        }
    }

    private func checking(_ text: String) -> some View {
        HStack(spacing: Theme.Space.small) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.base)
    }
}
