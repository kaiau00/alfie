import AppKit
import MoeDesign
import SwiftUI

/// Settings › Reminders: everything Moe does on a clock, and the place to
/// put something new on one.
///
/// Two lists, and the split is the point. **Yours** is what you asked for
/// — you can pause it, run it now, or throw it away. **Moe's own upkeep**
/// is the seven jobs that keep Moe current; they are shown so nothing is
/// hidden, and they are read-only here because switching one off is a
/// consent answer that belongs in Running in the background, not a cron
/// edit. That group is seven, not three: `moe-drain-intents` and
/// `moe-calendar-heads-up` joined it after the first two lists of it were
/// written, and both lists were wrong for a day; `moe-loop-check` and
/// `moe-channel-holder` joined on 2026-09-16, having sat under Yours with
/// raw names since they were installed. The set is `reminders.py UPKEEP`.
///
/// **Nothing on this screen says a job is scheduled when it cannot fire.**
/// A finished one, a paused one and a stopped clock look alike from a
/// distance and none of them is a next time — `Reminders.Job.when` is
/// where that is decided, and the banner at the top is the fifth case:
/// the ticker itself. A row promising "next at 6:30pm" while nothing is
/// running the clock is a promise the machine cannot keep.
///
/// The fourth case is the one that made the rule false rather than
/// incomplete, and it was missing until 2026-09-04: a job not tied to a
/// brain, whose brain has since moved, is refused by Hermes **at
/// dispatch** — so its record still reads runnable with a next time, and
/// this pane said so. It is a stop (`Reminders.Job.when`), Run now is not
/// offered on it, and the near miss beside it — not tied to a brain and
/// with no snapshot either, so nothing stops it running on whatever brain
/// comes next — is a caution beside the row rather than a stop, because
/// that job *does* fire.
///
/// **A template's blanks start blank.** The sixteen blueprints carry
/// defaults — `custom-reminder.what` is "take a break and stretch" — and
/// they are stripped in `reminders.py` before they reach this file, so
/// there is nothing here to pre-fill. Create stays disabled until every
/// question has an answer the person typed or picked. Tapping through
/// cannot produce a reminder.
///
/// Where the data comes from: `Reminders` for the schedule store and the
/// catalogue, `JobActivity` for what each job has done and cost. Two
/// scripts, joined on the job id, because the second already answers that
/// question for Settings › Background and a second reader of Hermes's
/// usage tables would be two files with two beliefs about one shape.
@MainActor
struct RemindersPane: View {
    @ObservedObject var conductor: Conductor

    /// `composing` opens on the template picker rather than the list, and
    /// `template` goes one step further and opens that template's form.
    /// Both exist for `--settings-snapshot`, which is how these get looked
    /// at without launching the app — the same reason `VoicePane` takes
    /// its tab. Nothing in the app passes either.
    private let openOn: String

    init(conductor: Conductor, composing: Bool = false, template: String = "", embedded: Bool = false) {
        self.embedded = embedded
        self.conductor = conductor
        self.openOn = template
        _picking = State(initialValue: composing || !template.isEmpty)
    }

    /// Nil until asked, and nil again when the reader gave no answer at
    /// all. A reader that answered and refused arrives here with `ok`
    /// false and words to show. Three states, not two: "nothing is on the
    /// clock", "I could not look", and "here is why I could not" are
    /// different answers, and only the first is fine.
    @State private var listing: Reminders.Listing?
    @State private var asked = false
    /// What each job has done and cost, by job id. Empty is fine: the
    /// rows lose a line and keep everything else.
    @State private var activity: [String: JobActivity.Job] = [:]
    @State private var catalog: Reminders.Catalog?
    @State private var picking: Bool
    @State private var draft: Draft?
    @State private var busy = false
    @State private var note = ""
    @State private var noteIsBad = false
    /// "Not now" on a keep card: hidden for this visit to the pane.
    @State private var dismissedKeep: Set<String> = []
    /// Removing is the one action with nothing behind it, so it asks.
    @State private var confirmRemove: String?

    /// One half-filled form. `answers` starts empty and stays that way
    /// until the person answers something — there is no default anywhere
    /// in this type, deliberately.
    struct Draft {
        let blueprint: Reminders.Blueprint
        var answers: [String: String] = [:]
        var name = ""

        func answer(_ field: Reminders.Field) -> String {
            (answers[field.name] ?? "").trimmingCharacters(in: .whitespaces)
        }

        /// Whether Create may be pressed. Every slot that is not optional
        /// needs an answer, and a `time` slot needs one Hermes will accept
        /// — it rejects "6pm" and "25:00", and finding that out after
        /// pressing Create is a worse way to learn it.
        var complete: Bool {
            blueprint.fields.allSatisfy { field in
                let value = answer(field)
                if value.isEmpty { return field.optional }
                return field.type != "time" || Draft.isClockTime(value)
            }
        }

        /// 24-hour HH:MM, which is what `fill_blueprint` parses.
        static func isClockTime(_ text: String) -> Bool {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
            return (0...23).contains(h) && (0...59).contains(m)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { PaneHeader(title: "Reminders") { headerActions } }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if embedded { HStack { Spacer(minLength: 0); headerActions } }
                    clockBanner
                    if picking || draft != nil { composer }
                    keepCards
                    yoursGroup
                    upkeepGroup
                    if !note.isEmpty {
                        Text(note)
                            .font(Theme.Typo.prose(13))
                            .foregroundStyle(noteIsBad ? Theme.warn : Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Theme.measure, alignment: .leading)
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

    /// Drawn inside another page (Running in the background › Reminders,
    /// 2026-09-28): no header of its own, its button at the top instead.
    var embedded = false

    @ViewBuilder
    private var headerActions: some View {
        if listing?.ok == true, draft == nil, !picking {
            PaneButton(title: "New reminder", symbol: "plus", prominent: true) {
                picking = true
                loadCatalog()
            }
        }
    }

    /// The fourth way a reminder fails to happen, and the only one no row
    /// can see: the thing that runs the clock is not running. Silent when
    /// it is fine, and silent when Hermes cannot tell — an unknown
    /// heartbeat is not a stopped one, and saying "stopped" on no evidence
    /// tells a person their reminders are broken when they are not.
    @ViewBuilder
    private var clockBanner: some View {
        if listing?.ticker.alive == false {
            PaneBanner(tone: .warn,
                       text: "Nothing is running the clock at the moment, so none of these will fire. Moe's thinking part may be starting up.")
        }
    }

    // MARK: - Yours

    /// Only a listing that came back `ok` has jobs to show. A refusal has
    /// none, and drawing an empty list beside its explanation would say
    /// "nothing is on the clock", which is a different and worse claim.
    private var jobs: [Reminders.Job] { listing?.ok == true ? listing!.jobs : [] }
    private var mine: [Reminders.Job] { jobs.filter { !$0.upkeep } }
    private var upkeep: [Reminders.Job] { jobs.filter(\.upkeep) }
    private var ticker: Reminders.Ticker { listing?.ticker ?? Reminders.Ticker() }

    /// Why the list is not there, in the script's own words when it gave
    /// any. It says things a person can act on — "Moe's thinking part
    /// isn't installed here yet" — and swapping that for one line of ours
    /// throws away the only part that told them what to do.
    private var problem: String {
        let said = listing?.error.trimmingCharacters(in: .whitespaces) ?? ""
        return said.isEmpty
            ? "Couldn't read what is on the clock. Moe's thinking part keeps it; it may be starting up."
            : said
    }

    // MARK: - "This job messages X — keep?"

    /// Jobs made before jobs recorded who asked for them, that message
    /// somebody. Moe now sends only to people the person named, and a job's
    /// own text never counts — so until these are answered, what they send to
    /// a named person shows amber on the send card rather than going quietly.
    /// One card per job, asked once: Keep records the person's words for the
    /// job; Not now hides it for this visit.
    private var toKeep: [Reminders.Job] {
        mine.filter { $0.keep != nil && !dismissedKeep.contains($0.id) }
    }

    @ViewBuilder
    private var keepCards: some View {
        if !toKeep.isEmpty {
            SettingGroup(title: "Check who these message") {
                ForEach(toKeep) { job in
                    keepCard(job)
                }
            }
        }
    }

    private func keepCard(_ job: Reminders.Job) -> some View {
        let keep = job.keep ?? Reminders.Job.Keep()
        return VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(keep.question)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(job.title)
                .font(Theme.Typo.ui(11))
                .foregroundStyle(Theme.ink3)
            HStack(spacing: Theme.Space.snug) {
                PaneButton(title: "Keep", symbol: "checkmark", prominent: true) { keepJob(job, keep) }
                PaneButton(title: "Not now", symbol: "xmark", prominent: false) {
                    dismissedKeep.insert(job.id)
                }
            }
        }
        .padding(.vertical, Theme.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keepJob(_ job: Reminders.Job, _ keep: Reminders.Job.Keep) {
        let id = job.id
        Task {
            let out = await ScriptRunner.offMain { Reminders.keep(id: id, answer: keep.answer) }
            await MainActor.run {
                noteIsBad = !out.ok
                note = out.ok ? "" : out.error
                load()
            }
        }
    }

    @ViewBuilder
    private var yoursGroup: some View {
        SettingGroup(title: "Yours") {
            if listing == nil, !asked {
                checking("Looking at what is on the clock…")
            } else if listing?.ok != true {
                Text(problem)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            } else if mine.isEmpty, listing?.unreadable != true {
                Text("Nothing yet. New reminder starts from one of Moe's templates.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.base)
            } else {
                ForEach(Array(mine.enumerated()), id: \.element.id) { i, job in
                    row(job, last: i == mine.count - 1, editable: true)
                }
                // Said whether or not any row survived, and never instead
                // of "Nothing yet" — the two are different answers, and
                // this is the one that must not be mistaken for the other.
                if listing?.unreadable == true {
                    Text(couldNotRead)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
            }
        }
    }

    /// One list came back with something in it Moe could not read.
    ///
    /// "Nothing is on the clock" and "I could not read what is on the
    /// clock" are different answers and only one of them is fine — the
    /// rule at the head of `Reminders.swift`. Until 2026-09-04 a single
    /// malformed element in the `jobs` array produced the first sentence
    /// for the second situation, silently, because the array was decoded
    /// with the same forgiving helper as every scalar field.
    private let couldNotRead =
        "Some of what is on the clock could not be read, so this list may be short. "
        + "Nothing was changed. Moe's thinking part keeps the list; it may be mid-update."

    @ViewBuilder
    private var upkeepGroup: some View {
        if !upkeep.isEmpty {
            SettingGroup(title: "Moe's own upkeep") {
                ForEach(Array(upkeep.enumerated()), id: \.element.id) { i, job in
                    row(job, last: i == upkeep.count - 1, editable: false)
                }
            }
            Text("These are how Moe stays current: reading what changed, learning about you, watching the things you asked it to watch, checking the pages you asked it to keep an eye on, keeping your chat apps connected, picking up work handed back from Moe Away, and the word before a meeting starts. They are shown here so nothing is hidden, and they are changed under Running in the background, where the answer is what Moe may read rather than when it runs.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    private func row(_ job: Reminders.Job, last: Bool, editable: Bool) -> some View {
        SettingRow(title: job.title,
                   detail: job.when(ticker),
                   note: under(job),
                   last: last) {
            if editable { controls(job) }
        }
    }

    /// The quieter line: how often, where it goes, and what it has been
    /// doing. `JobActivity` owns the last two sentences and is allowed to
    /// be missing — a row without them is still a useful row.
    private func under(_ job: Reminders.Job) -> String? {
        var parts: [String] = []
        if !job.cadence.isEmpty { parts.append(job.cadence + ".") }
        // Not for the upkeep jobs: their prompts are Moe's own operating
        // instructions, several hundred words of them, and none of it is
        // an answer to "what does this do for me".
        if !job.summary.isEmpty, !job.upkeep { parts.append(job.summary) }
        parts.append(delivery(job.deliver))
        // Not a stop, so not in `when` — but not silence either: this job
        // will run on whatever brain Moe is moved to, and spend on it.
        if let caution = job.caution { parts.append(caution) }
        if let a = activity[job.id] {
            if a.isTrouble { parts.append(a.state) }
            if a.cost.basis != "none", a.cost.basis != "elsewhere" {
                parts.append("\(a.cost.tokens), \(a.cost.summary).")
            }
        }
        let line = parts.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// Where a reminder lands, in the words the rest of Settings uses for
    /// the same platforms — `ReminderChannels` is what Background names
    /// them with, and one platform with two spellings across two screens
    /// is a support question forever.
    private func delivery(_ deliver: String) -> String {
        switch deliver {
        case "", "moe": return "Spoken here, and sent to the chats you picked."
        // Neither is offered by this pane; both turn up on jobs made
        // elsewhere, and each is a different thing. `origin` goes back to
        // whatever set the job up; `local` writes a file and stops.
        case "origin": return "Goes back to wherever it was set up from."
        case "local": return "Saved to a file, not sent anywhere."
        default: return "Sent to \(ReminderChannels.title(for: deliver))."
        }
    }

    @ViewBuilder
    private func controls(_ job: Reminders.Job) -> some View {
        HStack(spacing: Theme.Space.small) {
            // A finished job has no clock left to pause or resume, so it
            // is offered neither — a Resume that leaves it finished is a
            // button that does nothing and blames the person for it.
            if !job.terminal {
                PaneButton(title: job.runnable ? "Pause" : "Resume",
                           symbol: job.runnable ? "pause" : "play") {
                    act(job.runnable ? "pause" : "resume", on: job)
                }
                // A job Hermes would refuse at dispatch is offered no Run
                // now. The script refuses it too — a pane is not a guard —
                // but a button that can only produce a refusal is a button
                // that blames the person for pressing it, and this one
                // used to produce no visible answer at all: `trigger_job`
                // stamps `manual_run_at`, returns true, and the drift
                // guard then skips the job into a log nobody opens.
                if job.runnable, job.drifted.isEmpty {
                    PaneButton(title: "Run now", symbol: "bolt") { act("run", on: job) }
                }
            }
            if confirmRemove == job.id {
                PaneButton(title: "Really remove", symbol: "trash", danger: true) {
                    confirmRemove = nil
                    act("remove", on: job)
                }
                PaneButton(title: "Keep") { confirmRemove = nil }
            } else {
                PaneButton(title: "Remove", symbol: "trash", danger: true) {
                    confirmRemove = job.id
                }
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    // MARK: - Making one

    /// Pick a template, then answer its questions. Two steps rather than
    /// one long form: sixteen templates each with up to six blanks is a
    /// wall, and the choice of template is what decides which blanks there
    /// are.
    @ViewBuilder
    private var composer: some View {
        SettingGroup(title: draft == nil ? "What kind of reminder?" : "Set it up") {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                if let draft {
                    form(draft)
                } else if let catalog, catalog.ok {
                    ChipRow(chips: catalog.blueprints.map {
                        ChoiceChip(id: $0.key, title: $0.heading, caption: $0.description)
                    }, selected: nil) { key in
                        guard let b = catalog.blueprints.first(where: { $0.key == key }) else { return }
                        self.draft = Draft(blueprint: b, name: b.heading)
                    }
                    PaneButton(title: "Cancel") { picking = false }
                } else if let catalog {
                    // Same rule as the list: the script's refusal is a
                    // sentence, and it is more use than ours.
                    Text(catalog.error.isEmpty
                         ? "Couldn't read Moe's templates."
                         : catalog.error)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                    PaneButton(title: "Cancel") { picking = false }
                } else {
                    checking("Reading Moe's templates…")
                }
            }
            .padding(.vertical, Theme.Space.base)
        }
    }

    @ViewBuilder
    private func form(_ draft: Draft) -> some View {
        Text(draft.blueprint.description)
            .font(Theme.Typo.prose(13))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)

        ForEach(draft.blueprint.fields) { field in
            question(field)
        }

        // The name is Moe's suggestion and the person's to change: it is
        // what the row is called and what stops a second morning briefing
        // from silently updating the first, so it is shown rather than
        // generated out of sight.
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Call it")
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            TextField("", text: Binding(
                get: { self.draft?.name ?? "" },
                set: { self.draft?.name = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(Theme.Typo.ui(13))
                .frame(maxWidth: Theme.measure)
        }

        HStack(spacing: Theme.Space.base) {
            PaneButton(title: busy ? "Setting it up…" : "Create", symbol: "checkmark",
                       prominent: true, large: true) {
                create(draft)
            }
            // Disabled until every question has an answer. This is the
            // visible half of "a template's default is never an answer";
            // the refusing half is in reminders.py, because a pane is not
            // a guard.
            .disabled(busy || !draft.complete || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(busy || !draft.complete ? 0.5 : 1)
            PaneButton(title: "Cancel") {
                self.draft = nil
                picking = false
            }
            if !draft.complete {
                Text("Every question needs an answer — Moe does not fill any of them in for you.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    @ViewBuilder
    private func question(_ field: Reminders.Field) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(field.label)
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
            if field.isChoice {
                // `selected: nil` until they pick: a chip row with one
                // already filled in is a default by another name.
                ChipRow(chips: field.options.map { option in
                    ChoiceChip(id: option, title: choiceTitle(field, option))
                }, selected: draft?.answers[field.name]) { value in
                    draft?.answers[field.name] = value
                }
            } else {
                TextField("", text: binding(field), prompt: Text(placeholder(field)))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typo.ui(13))
                    .frame(maxWidth: Theme.measure)
            }
            let typed = draft?.answers[field.name] ?? ""
            if field.type == "time", !typed.isEmpty, !Draft.isClockTime(typed) {
                Text("Moe reads times as 24-hour HH:MM — 08:00, 18:30.")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.warn)
            } else if !field.help.isEmpty {
                Text(field.help)
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
    }

    private func binding(_ field: Reminders.Field) -> Binding<String> {
        Binding(get: { self.draft?.answers[field.name] ?? "" },
                set: { self.draft?.answers[field.name] = $0 })
    }

    /// A chip's words. The value is the catalogue's and goes back exactly
    /// as it came; only the label changes, which is what §4.1 means by
    /// rewriting Hermes's wording at the surface rather than in the
    /// catalogue. `deliver` carries platform ids, and Moe has a name for
    /// each of those already.
    private func choiceTitle(_ field: Reminders.Field, _ option: String) -> String {
        if field.name == "deliver" {
            return option == "moe" ? "Moe, here" : ReminderChannels.title(for: option)
        }
        switch option {
        case "everyday": return "Every day"
        case "weekdays": return "Weekdays"
        case "weekends": return "Weekends"
        default:
            guard let first = option.first, first.isLowercase else { return option }
            return first.uppercased() + option.dropFirst()
        }
    }

    /// A shape, not a time. A grey "18:30" in the field reads as an answer
    /// already chosen, which is the one thing this form must never show —
    /// and the help line under it gives a real example anyway.
    private func placeholder(_ field: Reminders.Field) -> String {
        field.type == "time" ? "HH:MM" : ""
    }

    // MARK: - Doing it

    private func create(_ draft: Draft) {
        busy = true
        note = ""
        let key = draft.blueprint.key
        let values = draft.answers.mapValues { $0.trimmingCharacters(in: .whitespaces) }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        Task {
            let out = await ScriptRunner.offMain { Reminders.create(key: key, values: values, name: name) }
            await MainActor.run {
                busy = false
                noteIsBad = !out.ok
                if out.ok {
                    // The name, not the template's heading: "Moe will
                    // remind me to… from now on" is what the heading gives
                    // you, and it reads as a sentence that lost its end.
                    note = "Set up. “\(name)” is on the clock — it is in the list below."
                    self.draft = nil
                    picking = false
                } else {
                    note = out.error
                }
                load()
            }
        }
    }

    private func act(_ verb: String, on job: Reminders.Job) {
        busy = true
        note = ""
        let id = job.id
        Task {
            let out = await ScriptRunner.offMain { Reminders.verb(verb, id: id) }
            await MainActor.run {
                busy = false
                noteIsBad = !out.ok
                note = out.ok ? "" : out.error
                // Always reload, success or not: what the person should be
                // looking at is the store, never this screen's guess about
                // what a button did.
                load()
            }
        }
    }

    // MARK: - Loading

    private func load() {
        // The templates too, when the pane opened straight onto the form:
        // the button is the usual way to ask for them, and `composing`
        // skips the button.
        if picking { loadCatalog() }
        Task {
            let l = await ScriptRunner.offMain { Reminders.list() }
            await MainActor.run {
                listing = l
                asked = true
            }
        }
        Task {
            let a = await ScriptRunner.offMain { JobActivity.all() }
            await MainActor.run {
                activity = Dictionary(uniqueKeysWithValues: (a ?? []).map { ($0.id, $0) })
            }
        }
    }

    private func loadCatalog() {
        guard catalog == nil else { return }
        Task {
            let c = await ScriptRunner.offMain { Reminders.catalog() }
            await MainActor.run {
                catalog = c
                if let b = c?.blueprints.first(where: { $0.key == openOn }) {
                    draft = Draft(blueprint: b, name: b.heading)
                }
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
