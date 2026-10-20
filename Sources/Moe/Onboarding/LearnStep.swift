import MoeDesign
import SwiftUI

/// The first-run step that asks what Moe may read to learn about the
/// person, and the same question again from the Memory page when there is
/// nothing on it.
///
/// Why it exists. The daily pass (`moe-home/hermes-jobs/moe-learn-deep.sh`)
/// has two gates: its own yes, `background-learning`, and a yes for each
/// source it reads. The app's sheet (`BackgroundLearning.askIfNeeded`) asks
/// the first only once a source has been allowed — a question about reading
/// nothing is noise — and a source was only ever allowed from Settings ›
/// Background or a terminal prompt. Nothing in the flow led there. Measured
/// 2026-09-14 on the owner's Mac: after an erase the pass ran three days
/// running and read nothing each time, and "who am I" in the cloud got
/// nothing back. This step is the front door: one screen, the sources as
/// switches, the daily pass under them, one answer.
///
/// One writer. Every switch here lands in `memory/profile/consent.json`
/// through `BackgroundLearning.set` → `learn/consent.sh grant|revoke` —
/// the same path the Settings › Background switches take — and what is
/// written is decided by `BackgroundLearning.stepWrites`, which has no
/// screen in it and which `Moe --learn-step` runs against a scratch home so
/// the file this leaves can be held against the one Settings leaves.
///
/// Skip records nothing: not a no, nothing. The sheet that asks later
/// keeps its rule — it waits for a source-yes — and this step is what
/// supplies one.
enum LearnStepCopy {
    /// First person, like every other first-run screen ("Can I hear you?",
    /// "I'll take the notes"). The owner's name for the step is "What may
    /// Moe read to learn about you?"; on screen Moe is the one asking.
    static let title = "What may I learn from and watch?"
    /// What the daily pass does, in plain words (docs/DEFAULTS.md row 24):
    /// read back over what is allowed once, keep up with what is new after,
    /// and keep what it works out in writing on this Mac.
    static let lead = "I learn about you from the things ticked here — who matters to you, what you're working on, how you like things done — and watch them for things you'd want help with, with the work ready. Nothing is ever sent unless you say so."
    /// Beside the badge above the switches: the recommendation, and that
    /// it is still the person's to change.
    static let recommended = "Everything here starts switched on. Untick anything you'd rather I left alone, then save. Skip, and nothing is recorded."
    /// The plain-words paragraph under the switches. Every sentence is
    /// checked against what happens: reading back is `learn.sh`'s seed
    /// stage then `update`; nothing is read without a recorded yes
    /// (`--no-ask`); the list is `memory/profile/*.md` on this Mac, and the
    /// ledger carries it to a cloud computer the person has set up; the
    /// switches are Settings › Background's.
    static let detail = "Nothing is read until you save. What I work out stays on this Mac — and on your own cloud computer, if you set one up — in plain writing you can read and change in the Memory tab. Change any of this in Settings › Running in the background."
    /// Under the pass switch: what it is and is not.
    static let passDetail = "Only what's ticked above, once a day. Off, nothing is read on its own."
    /// A Mac with nothing connected yet. The list is the same one Settings
    /// › Background draws, so it fills in as things are connected.
    ///
    /// And the question comes again: the first time something is
    /// connected, Moe asks about that one thing (`ConnectLearnAskSheet`).
    static let nothingYet = "Nothing is connected yet, so there's nothing to read. The next screen is where you connect things — and the moment you connect one, I'll ask about it right then. This list is in Settings › Running in the background too."
    static let loading = "Looking at what's connected…"
    /// The onboarding button: it says what pressing it does.
    static let save = "Save and continue"
    static let next = "Next"
    /// The Memory page's sheet.
    static let sheetSave = "Save"
    static let sheetNotNow = "Not now"
    static let memoryButton = "Choose what Moe may read"
    static let problem = "Couldn't record that. Nothing changed."

    // The question asked when something is connected (docs/DEFAULTS.md
    // row 25). Same words as the switches it sets.
    /// Never claims more than every source does: a service connected
    /// through Connections is not kept ready on a clock (each read of a
    /// dedicated server is a sign-in), so "ready" is not promised here.
    static func askTitle(_ label: String, count: Int = 1) -> String {
        "Let Moe learn from \(label) and watch \(count == 1 ? "it" : "them") for things you'd want help with?"
    }
    static func askBody(_ reads: String, count: Int = 1) -> String {
        "Moe reads \(reads). It learns what matters to you from \(count == 1 ? "it" : "them"), and tells you when something there needs you, with the work ready. Nothing is ever sent unless you say so."
    }
    /// The launch question about several sources at once: a short title,
    /// and every source named in the body, where it has room — in the title
    /// the list was cut to "Calendar, P…" (owner, 2026-09-29).
    static func askTitleMany(_ count: Int) -> String {
        "Let Moe learn from these \(count) and watch them for things you'd want help with?"
    }
    static func askBodyMany(_ listed: String) -> String {
        "\(listed). Moe reads what is in them, learns what matters to you, and tells you when something there needs you, with the work ready. Nothing is ever sent unless you say so."
    }
    static let askDetail = "What it learns stays on this Mac, in plain writing you can read and change in the Memory tab. Not now asks again in a week. Change it any time in Settings › Running in the background."
    static let askYes = "Yes"
    static let askNotNow = "Not now"
}

/// The switches' state while the screen is up: which rows are ticked, how
/// the daily-pass switch is set, and where both started, so the save can
/// write only what moved.
@MainActor
final class LearnStepModel: ObservableObject {
    @Published private(set) var rows: [BackgroundLearning.Row] = []
    @Published private(set) var loaded = false
    @Published var ticked: Set<String> = []
    @Published var pass = true
    @Published private(set) var saving = false
    @Published private(set) var problem: String?

    /// Posed rows (a snapshot, a rehearsal): `load` reads nothing.
    private let posed: [BackgroundLearning.Source]?
    private var passState: BackgroundLearning.State = .unset
    private var loading = false
    /// Pre-tick every connected source (docs/DEFAULTS.md row 24). Only the
    /// welcome recommends: the Memory page's sheet asks the same question
    /// and starts from what the person has already said, nothing more.
    private let recommend: Bool

    init(posed: [BackgroundLearning.Source]? = nil, recommend: Bool = false) {
        self.posed = posed
        self.recommend = recommend
    }

    /// True once a source is ticked: the button says "Save and continue".
    var hasChoice: Bool { rows.contains { ticked.contains($0.id) } }

    /// The quick list first (no probe, well under a second), then the full
    /// one behind it — the same two reads Settings › Background makes. A row
    /// already granted in the file starts ticked; the pass switch starts
    /// where the file has it, or on when the file has no answer.
    func load() {
        guard !loading, !loaded else { return }
        loading = true
        if let posed {
            apply(posed, passState: .unset)
            loaded = true
            loading = false
            return
        }
        Task {
            let quick = await ScriptRunner.offMain { BackgroundLearning.sources(quick: true) }
            let state = await ScriptRunner.offMain { BackgroundLearning.state() }
            apply(quick, passState: state)
            loaded = true
            let full = await ScriptRunner.offMain { BackgroundLearning.sources() }
            if full != nil { apply(full, passState: state) }
            loading = false
        }
    }

    /// A switch the person moved, and which way. Outranks the list catching
    /// up behind it; a row that has left the list takes its tick with it.
    private var touched: [String: Bool] = [:]

    func tick(_ id: String, _ on: Bool) {
        touched[id] = on
        if on { ticked.insert(id) } else { ticked.remove(id) }
    }

    private func apply(_ sources: [BackgroundLearning.Source]?, passState: BackgroundLearning.State) {
        let fresh = BackgroundLearning.rows(sources)
        // Recommended on in the welcome (docs/DEFAULTS.md row 24): every
        // connected source starts ticked except one already said no to.
        // Anywhere else a row starts where the file has it.
        var next = recommend
            ? BackgroundLearning.recommendedTicks(sources)
            : Set(fresh.filter { $0.on }.map(\.id))
        for r in fresh {
            if let on = touched[r.id] { if on { next.insert(r.id) } else { next.remove(r.id) } }
        }
        rows = fresh
        ticked = next
        if !loaded {
            self.passState = passState
            pass = passState != .refused
        }
    }

    /// What pressing the button writes, in order. Empty when nothing moved
    /// and nothing is on.
    var writes: [(name: String, on: Bool)] {
        BackgroundLearning.stepWrites(rows: rows, ticked: ticked, pass: pass, passState: passState)
    }

    /// A source this screen showed and the person left off, or passed over
    /// with Skip, counts as asked: the question at launch comes back to it
    /// a week later, not seconds after the welcome closes (review
    /// 2026-09-29 #4).
    func markShownOff(all: Bool = false) {
        // On the main actor, not detached: the connect flow writes the same
        // small marker file, and two unlocked read-modify-writes at once lose
        // one (re-review 2026-09-29 N6).
        for r in rows where !r.on && (all || !ticked.contains(r.id)) {
            BackgroundLearning.ConnectAsk.markAsked(r.id)
        }
    }

    /// Record the answers through the one writer. False if a write failed;
    /// the switches stay where they are so the person can try again.
    @discardableResult
    func save() async -> Bool {
        markShownOff()
        let writes = self.writes
        guard !writes.isEmpty else { return true }
        saving = true
        problem = nil
        let ok = await ScriptRunner.offMain { BackgroundLearning.record(writes) }
        saving = false
        if ok {
            Log.write("learn step: recorded \(writes.map { "\($0.name)=\($0.on ? "yes" : "no")" }.joined(separator: " "))")
            // What the file says now is the new starting point.
            for w in writes where w.name == BackgroundLearning.source {
                passState = w.on ? .granted : .refused
            }
            rows = rows.map { r in
                let on = ticked.contains(r.id)
                return on == r.on ? r : BackgroundLearning.Row(id: r.id, label: r.label, detail: r.detail,
                                                              names: r.names, on: on, profile: r.profile,
                                                              awaitingRecipe: r.awaitingRecipe)
            }
            touched = [:]
        } else {
            problem = LearnStepCopy.problem
        }
        return ok
    }
}

/// The switches: one per connected source, then the daily pass. Drawn by
/// the first-run screen and by the Memory page's sheet.
struct LearnStepBody: View {
    @ObservedObject var model: LearnStepModel
    /// `ImageRenderer` cannot draw an AppKit switch; a snapshot draws a
    /// still one in the state it is in.
    var snapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            if !model.loaded {
                HStack(spacing: Theme.Space.small) {
                    if !snapshot { ProgressView().controlSize(.small) }
                    Text(LearnStepCopy.loading)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                }
            } else if model.rows.isEmpty {
                Text(LearnStepCopy.nothingYet)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    Text("Recommended")
                        .font(Theme.Typo.label(9))
                        .tracking(Theme.tracking)
                        .foregroundStyle(Theme.accentDeep)
                        .padding(.horizontal, Theme.Space.small)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentTint))
                    Text(LearnStepCopy.recommended)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.rows) { r in
                    row(title: BackgroundLearning.Words.row(r.label),
                        detail: "Reads " + r.reads(default: r.label) + ".",
                        isOn: Binding(get: { model.ticked.contains(r.id) },
                                      set: { model.tick(r.id, $0) }))
                }
                Rectangle().fill(Theme.rule).frame(height: 1)
                    .padding(.vertical, Theme.Space.tight)
                row(title: BackgroundLearning.Words.pass,
                    detail: LearnStepCopy.passDetail,
                    isOn: $model.pass)
            }
            if let problem = model.problem {
                Text(problem)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            lever(isOn)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lever(_ isOn: Binding<Bool>) -> some View {
        if snapshot {
            Capsule().fill(isOn.wrappedValue ? Theme.accent : Theme.ruleStrong)
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Circle().fill(Theme.raised).frame(width: 13, height: 13).padding(1)
                }
        } else {
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                .disabled(model.saving)
        }
    }
}

/// The same question, from the Memory page: one click from "Moe hasn't
/// learned about you yet" to the switches that fix it. Same copy, same
/// rows, same writer.
struct LearnStepSheet: View {
    @StateObject private var model = LearnStepModel()
    /// Called when the sheet is done, with whether anything was recorded.
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            Text(LearnStepCopy.title)
                .font(Theme.Typo.display(24))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(LearnStepCopy.lead)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(showsIndicators: false) {
                LearnStepBody(model: model)
                    .padding(.trailing, Theme.Space.small)
            }
            .frame(maxHeight: 300)
            Text(LearnStepCopy.detail)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                PaneButton(title: LearnStepCopy.sheetNotNow) { done(false) }
                    .keyboardShortcut(.cancelAction)
                PaneButton(title: LearnStepCopy.sheetSave, prominent: true) {
                    Task {
                        let recorded = !model.writes.isEmpty
                        if await model.save() { done(recorded) }
                    }
                }
                .disabled(model.saving || !model.loaded)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.generous)
        .frame(width: 560)
        .background(Theme.paper)
        .onAppear(perform: model.load)
    }
}


/// The question asked the first time a source is connected
/// (docs/DEFAULTS.md row 25): one source, Yes recommended, Not now. Yes
/// writes through `BackgroundLearning.ConnectAsk.grant` — the one writer;
/// Not now records nothing. ConnectionsView shows it once per source.
struct ConnectLearnAskSheet: View {
    let row: BackgroundLearning.Row
    let done: () -> Void
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            Text("Recommended")
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.accentDeep)
                .padding(.horizontal, Theme.Space.small)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.accentTint))
            Text(LearnStepCopy.askTitle(row.label))
                .font(Theme.Typo.display(22))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(LearnStepCopy.askBody(row.reads(default: row.label)))
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(LearnStepCopy.askDetail)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                PaneButton(title: LearnStepCopy.askNotNow) { done() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                PaneButton(title: LearnStepCopy.askYes, prominent: true) { yes() }
                    .disabled(saving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.generous)
        .frame(width: 460)
        .background(Theme.paper)
    }

    private func yes() {
        saving = true
        problem = nil
        let row = self.row
        Task {
            let ok = await ScriptRunner.offMain { BackgroundLearning.ConnectAsk.grant(row) }
            saving = false
            if ok { done() } else { problem = LearnStepCopy.problem }
        }
    }
}
