import AppKit
import MoeChat
import MoeDesign
import SwiftUI

/// Settings › Chats: every conversation, and a way back into one.
///
/// Chat itself is where you talk to Moe and its sidebar lists the recent
/// threads. This is the archive: all of them, with how long each ran,
/// where it happened, and a search that goes through the words rather
/// than the titles.
///
/// **The ledger decides what exists here, always.** Hermes keeps its own
/// copy of every session and that copy outlives a deletion on purpose
/// (`CLOUD-PLAN` §9): deleting a conversation destroys the key the
/// ledger sealed it with, and Hermes's transcript of the same turns stays
/// where it is. So Hermes is asked where to look and never what to show —
/// `Chats.search` resolves each hit to a thread the ledger vouches for
/// before a word of it reaches this file, and the script it asks refuses
/// to search at all outside the sessions it is handed.
///
/// **A thread is a conversation only if it has surviving `turn` records.**
/// Not "is in the ledger": slice 3 files `intent`, `intent.result` and
/// `intent.attempt` records inside a thread, because work is queued in
/// the conversation it was asked in. A thread holding nothing else is a
/// queued lookup, and listing it here would put a job Moe gave itself in
/// among the things a person said.
///
/// **A conversation whose key is gone is counted, never listed.** The
/// ledger still holds its shape — that a thread existed, how many turns,
/// who spoke — and none of its words. A row for one could only
/// disappoint, so the number is stated and the rows are not drawn.
@MainActor
struct ChatsPane: View {
    @ObservedObject var conductor: Conductor

    /// Set just before `.moeShowSection` asks for this pane, so a row in
    /// Activity can land on a particular conversation. A static rather
    /// than a value in the notification because Settings reuses one
    /// window: the pane may already be mounted, in which case nothing new
    /// is constructed and no initialiser would run.
    @MainActor static var pendingThread = ""

    /// Opens straight onto a conversation, or onto a search. Both exist
    /// for `--settings-snapshot`, which is how the halves of this pane
    /// that no list state can reach get looked at without launching the
    /// app. Nothing in the app passes either.
    init(conductor: Conductor, opening: String = "", searching: String = "", embedded: Bool = false) {
        self.embedded = embedded
        self.conductor = conductor
        _open = State(initialValue: opening)
        _query = State(initialValue: searching)
        _typed = State(initialValue: searching)
    }

    /// Nil until asked. `Library.ok == false` is a refusal with words in
    /// it; an empty list with `ok` is "you have not talked to Moe yet",
    /// and the two must never draw the same.
    @State private var library: Chats.Library?
    @State private var asked = false
    @State private var typed = ""
    /// What was actually searched for, which lags what is being typed:
    /// the search shells out to Hermes's index and is not run per
    /// keystroke.
    @State private var query = ""
    @State private var results: Chats.Results?
    @State private var searching = false
    @State private var open = ""
    @State private var reading: ConversationStore.Conversation?
    @State private var loadingThread = false
    /// Set only when a read actually came back empty. Without it, "nobody
    /// has asked yet" and "asked, and the key is gone" are the same two
    /// nils, and the pane accuses the ledger of losing a conversation
    /// nobody ever asked it for.
    @State private var openFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { PaneHeader(title: "Chats") { headerActions } }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if embedded { HStack { headerActions; Spacer(minLength: 0) } }
                    if !open.isEmpty || reading != nil {
                        transcript
                    } else {
                        searchResults
                        list
                        unreadableNote
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.raised)
        .onAppear(perform: appeared)
        .onReceive(NotificationCenter.default.publisher(for: .moeShowSection)) { n in
            guard (n.userInfo?["section"] as? String) == MainWindow.Section.chats.rawValue
            else { return }
            appeared()
        }
    }

    /// Drawn inside Settings › History (2026-09-28): no header of its own,
    /// the search at the top of the page instead.
    var embedded = false

    @ViewBuilder
    private var headerActions: some View {
                if reading == nil, open.isEmpty {
                    PaneSearch(prompt: "Search what was said", text: $typed, width: 190)
                        .onSubmit { runSearch() }
                    PaneButton(title: searching ? "Looking…" : "Search", symbol: "magnifyingglass") {
                        runSearch()
                    }
                    .disabled(searching || typed.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    PaneButton(title: "All conversations", symbol: "chevron.left") { close() }
                }
    }

    // MARK: - Copy

    // MARK: - The list

    private var threads: [Chats.Thread] { library?.ok == true ? library!.threads : [] }

    @ViewBuilder
    private var list: some View {
        // "Everything else" only when there is something above it for this
        // to be else to. A heading that names a group that is not on the
        // page is a heading that lies about the page.
        SettingGroup(title: results == nil ? "All conversations" : "Everything else") {
            if library == nil, !asked {
                checking("Reading what Alfie has kept…")
            } else if library?.ok != true {
                Text(library?.error.isEmpty == false
                     ? library!.error
                     : "Couldn't read what Alfie has kept.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            } else if threads.isEmpty {
                Text("Nothing yet. Conversations appear here as you have them.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.base)
            } else {
                ForEach(Array(threads.enumerated()), id: \.element.id) { i, thread in
                    row(thread, excerpt: thread.preview, hint: "",
                        last: i == threads.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if !query.isEmpty, let results {
            SettingGroup(title: "Matching “\(query)”") {
                if !results.error.isEmpty {
                    Text(results.error)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                        .padding(.vertical, Theme.Space.base)
                }
                if results.matches.isEmpty, results.error.isEmpty {
                    Text("Nothing matched. Alfie looked through what it holds and through Hermes's index of \(results.indexed) of those conversations.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                        .padding(.vertical, Theme.Space.base)
                } else {
                    ForEach(Array(results.matches.enumerated()), id: \.element.id) { i, match in
                        row(match.thread, excerpt: match.excerpt,
                            // Said, rather than left to be inferred: an
                            // excerpt Hermes found is Hermes's copy of the
                            // session, which holds more than the ledger
                            // does — tool results and the silent turn that
                            // reminds a model what was said before. It is
                            // a signpost, not a quote.
                            hint: match.fromIndex ? "Found in Hermes's index of this conversation." : "",
                            last: i == results.matches.count - 1)
                    }
                }
            }
        }
    }

    private func row(_ thread: Chats.Thread, excerpt: String, hint: String,
                     last: Bool) -> some View {
        SettingRow(title: thread.title,
                   detail: excerpt,
                   note: under(thread, hint: hint),
                   last: last) {
            PaneButton(title: "Read", symbol: "text.alignleft") { openThread(thread.id) }
        }
    }

    private func under(_ thread: Chats.Thread, hint: String) -> String? {
        var parts = ["\(thread.turns) turn\(thread.turns == 1 ? "" : "s")",
                     thread.whereFrom.lowercased(),
                     when(thread.updatedAt)]
        var line = parts.removeFirst() + ", " + parts.joined(separator: ", ") + "."
        if !hint.isEmpty { line += " " + hint }
        return line
    }

    private func when(_ at: Date) -> String {
        let cal = Calendar.current
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        let clock = time.string(from: at).lowercased()
        if cal.isDateInToday(at) { return "today at \(clock)" }
        if cal.isDateInYesterday(at) { return "yesterday at \(clock)" }
        let day = DateFormatter()
        day.dateFormat = "d MMMM"
        return "on \(day.string(from: at))"
    }

    /// The threads the ledger holds and cannot open. Stated as a number
    /// and an explanation, never as rows: their words are gone, and a row
    /// promising a conversation it cannot show is worse than the honest
    /// sentence.
    @ViewBuilder
    private var unreadableNote: some View {
        if let library, library.unreadable > 0 {
            Text("\(library.unreadable) more \(library.unreadable == 1 ? "conversation is" : "conversations are") in Alfie's record without their words. That is what deleting one does — the key is destroyed and the shape stays — and it is also what a conversation from another device looks like before its key has reached this Mac.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    // MARK: - Reading one

    @ViewBuilder
    private var transcript: some View {
        if loadingThread {
            checking("Opening it…")
        } else if let convo = reading {
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text(convo.title)
                    .font(Theme.Typo.heading(17))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(convo.turns.count) turn\(convo.turns.count == 1 ? "" : "s"), \(when(convo.startedAt)).")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
            // Their own stack, with their own spacing. Left as siblings of
            // the heading they inherited the page's section gap and a
            // fourteen-turn conversation read as fourteen unrelated
            // paragraphs — visible only in the render.
            VStack(alignment: .leading, spacing: Theme.Space.cosy) {
                ForEach(convo.turns) { turn in
                    turnRow(turn)
                }
            }
        } else if openFailed {
            Text("Alfie couldn't open that conversation. Its words are sealed with a key this Mac does not have — either it was deleted, or it belongs to a device that has not shared the key yet.")
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        } else {
            checking("Opening it…")
        }
    }

    private func turnRow(_ turn: ConversationStore.StoredTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(turn.role == .you ? "You" : (turn.role == .moe ? "Alfie" : "Note"))
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(turn.role == .you ? Theme.accentDeep : Theme.ink3)
            Text(turn.text)
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Doing it

    private func appeared() {
        if !ChatsPane.pendingThread.isEmpty {
            let wanted = ChatsPane.pendingThread
            ChatsPane.pendingThread = ""
            openThread(wanted)
        }
        // A pane opened *on* a conversation has to go and get it. Found by
        // rendering: `--settings-snapshot` asked for Chats reading the
        // newest thread and got "Moe couldn't open that conversation",
        // because `open` was set and nothing had ever been asked to load
        // it — the state a failed read leaves behind and the state a read
        // that never started leaves behind are the same state.
        if !open.isEmpty, reading == nil, !loadingThread { openThread(open) }
        // A pane opened on a search has to run it. Found by rendering:
        // `--settings-snapshot` asked for Chats searching "meeting", the
        // word appeared in the field, and nothing else happened — the
        // heading said "Everything else" over a page with no results
        // above it.
        if !query.isEmpty, results == nil, !searching { runSearch() }
        guard library == nil else { return }
        load()
    }

    private func load() {
        Task {
            let l = await ScriptRunner.offMain { Chats.library() }
            await MainActor.run {
                library = l
                asked = true
            }
        }
    }

    private func runSearch() {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        query = text
        Task {
            let r = await ScriptRunner.offMain { Chats.search(text) }
            await MainActor.run {
                searching = false
                // Only if it is still the search being waited for: the
                // index is a subprocess and two of these can land out of
                // the order they were asked in.
                guard query == text else { return }
                results = r
            }
        }
    }

    private func openThread(_ id: String) {
        open = id
        reading = nil
        openFailed = false
        loadingThread = true
        Task {
            let convo = await ScriptRunner.offMain { Chats.open(id) }
            await MainActor.run {
                guard open == id else { return }
                reading = convo
                openFailed = convo == nil
                loadingThread = false
            }
        }
    }

    private func close() {
        open = ""
        reading = nil
        openFailed = false
        loadingThread = false
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
