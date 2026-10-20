import AppKit
import MoeDesign
import SwiftUI

/// Settings › Usage: what Moe has spent, and what happens when it runs out.
///
/// The warning half of HERMES-SURFACES §4.4 already ships — at ≥90% of an
/// Anthropic window the engine says *"heads up — N% of your five hour
/// limit used"* and `HermesBrain` puts it in the transcript, which is the
/// difference between Moe going mute at 100% and Moe saying so first. This
/// is the other half: the numbers underneath it, and an honest account of
/// which of them are money.
///
/// **Four rules, all of them measured rather than assumed.**
///
/// *"Total tokens" is not what you and Moe wrote.* Thirty days on this Mac
/// is 1.6M input and 900k output against 194M of cache read — the same
/// context arriving again on every turn. `hermes insights` adds all four
/// and prints "216,847,032", which reads like a bill and is 98% re-reading.
/// The two are on separate lines here and are never summed.
///
/// *Almost none of it is money, and the database says so.* 708 of 776
/// sessions are `included` against `claude-code-subscription` — the Claude
/// plan paid for them. The only dollars on this Mac are 56 cents of
/// DeepSeek. A pane that showed one big number would be alarming and
/// wrong.
///
/// *Cost per tool does not exist.* §4.4 asks for "which tools cost most".
/// Hermes attributes tokens to a session and to nothing smaller — there is
/// no per-tool token column anywhere in `state.db`. So this shows how
/// often each tool ran, and says in the section's own words that it is
/// counting calls rather than money.
///
/// *A warning that has never fired says so.* The only record that the
/// rate-limit notice ever appeared is `moe.log`, and on this Mac it never
/// has. The section says that, rather than drawing a gauge over a number
/// nothing has ever produced — and it distinguishes "never happened" from
/// "couldn't read the log", which are different facts.
@MainActor
struct UsagePane: View {
    @ObservedObject var conductor: Conductor

    /// Opens with the per-day list already showing. Only
    /// `--settings-snapshot` passes it: that list is folded away, and a
    /// layout no scroll position can reach is a layout that ships
    /// unlooked-at.
    init(conductor: Conductor, showingDays: Bool = false, embedded: Bool = false) {
        self.embedded = embedded
        self.conductor = conductor
        _daily = State(initialValue: showingDays)
    }

    /// Nil until asked, and nil again when nothing answered at all. A
    /// reader that answered and refused arrives with `ok` false and words
    /// to show. Three states, not two.
    @State private var report: Usage.Report?
    @State private var days = 30
    @State private var daily: Bool

    /// The windows offered. A day is "what have I used today"; a week is
    /// the shape of a working rhythm; a month is the billing period every
    /// provider bills on.
    private static let windows = [1, 7, 30]

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                PaneHeader(title: "Usage") {
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
                    if let report {
                        if !report.error.isEmpty { PaneBanner(tone: .warn, text: report.error) }
                        if report.missing {
                            PaneBanner(tone: .neutral,
                                       text: "Nothing has been recorded on this Mac yet, so there is nothing to add up.")
                        } else {
                            tokens(report)
                            cost(report)
                            models(report)
                            sources(report)
                            toolSection(report)
                            dailySection(report)
                        }
                        limitSection
                    } else {
                        checking("Adding up what Moe has used…")
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

    // MARK: - The warning, which is the half that already ships

    @ViewBuilder
    private var limitSection: some View {
        SettingGroup(title: "When you get close to a limit") {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                Text("Moe tells you before it stops. Once you pass nine tenths of a plan window, the answer arrives with a line saying how much of it is gone — so you find out from Moe rather than from Moe going quiet.")
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                if let report {
                    let w = report.warning
                    if w.seen {
                        PaneBanner(tone: .warn, text: last(w))
                    } else if w.checked {
                        PaneBanner(tone: .good,
                                   text: "Moe has never had to say that on this Mac.")
                    } else {
                        // Not "never happened". The log could not be read,
                        // and those are different facts — one of which
                        // this screen would be inventing.
                        PaneBanner(tone: .neutral,
                                   text: "Moe couldn't read its own log, so it can't say whether that has ever happened.")
                    }
                }
            }
            .padding(.vertical, Theme.Space.base)
        }
    }

    /// The engine's own sentence, with the time it was said. Its words,
    /// not a paraphrase: it names the window ("five hour", "weekly") and a
    /// rewritten version would be a second belief about a number.
    private func last(_ w: Usage.Warning) -> String {
        let when = stamp(w.at)
        let said = Chats.line(w.text, limit: 160)
        if when.isEmpty { return "The last time: \(said)" }
        return "\(when): \(said)"
    }

    private func stamp(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let date else { return "" }
        let out = DateFormatter()
        out.dateFormat = "d MMMM, h:mm a"
        return out.string(from: date)
    }

    // MARK: - Window

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

    // MARK: - Tokens

    private func tokens(_ r: Usage.Report) -> some View {
        SettingGroup(title: "Tokens") {
            SettingRow(title: "What you and Moe said",
                       detail: "Everything typed, spoken and answered — \(Usage.grouped(r.totals.input)) in and \(Usage.grouped(r.totals.output)) out.",
                       note: r.totals.sessions == 0 ? nil
                             : "Across \(Usage.grouped(r.totals.sessions)) \(r.totals.sessions == 1 ? "conversation" : "conversations") and \(Usage.grouped(r.totals.messages)) messages.") {
                Text(Usage.compact(r.totals.written))
                    .font(Theme.Typo.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            // The number that would frighten someone if it were added to
            // the one above. It is the same context being handed back to
            // the model on every turn — cheap, cached, and not a
            // conversation.
            SettingRow(title: "What Moe re-read each turn",
                       detail: "Moe re-reads what it already knows on every turn: your instructions, the thread so far, the tools it has. This is that, and it is not something you said.",
                       note: r.totals.readBack > r.totals.written * 4
                             ? "This is normally far bigger than the line above, and it is billed at a fraction of the rate — where it is billed at all."
                             : nil,
                       last: true) {
                Text(Usage.compact(r.totals.readBack))
                    .font(Theme.Typo.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - Cost

    private func cost(_ r: Usage.Report) -> some View {
        SettingGroup(title: "What it cost") {
            SettingRow(title: "Covered by a plan you already pay for",
                       detail: "Sessions your plan — Claude or ChatGPT — paid for by the month, not by the token. These are recorded as included and never priced, because there is no per-token price to record.",
                       note: r.money.planProviders.isEmpty ? nil
                             : "Through \(r.money.planProviders.joined(separator: ", ")).") {
                Text("\(Usage.grouped(r.money.included))")
                    .font(Theme.Typo.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            SettingRow(title: "Billed per token",
                       detail: "The lanes that charge by use — the smaller models Moe reaches for titles, summaries and background work. This is an estimate from a published price list, not a bill.",
                       note: (r.money.meteredProviders.isEmpty ? ""
                              : "Through \(r.money.meteredProviders.joined(separator: ", ")). ")
                             + (r.money.actualUSD > 0
                                ? "A provider reported \(Usage.dollars(r.money.actualUSD)) actually charged."
                                : "No provider has reported an actual charge, so every figure here is an estimate.")) {
                Text(Usage.dollars(r.money.meteredUSD))
                    .font(Theme.Typo.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            if r.money.unknown > 0 {
                SettingRow(title: "Nothing recorded",
                           detail: r.money.unknownTokens == 0
                             ? "Sessions that opened and never took a turn. They have no tokens and no cost — there is nothing missing here."
                             : "Sessions with no billing route recorded, and \(Usage.compact(r.money.unknownTokens)) tokens between them. That is a gap: Moe cannot say what these cost.",
                           last: true) {
                    Text("\(Usage.grouped(r.money.unknown))")
                        .font(Theme.Typo.ui(15, weight: .semibold))
                        .foregroundStyle(r.money.unknownTokens == 0 ? Theme.ink3 : Theme.warn)
                }
            }
        }
    }

    // MARK: - Models

    @ViewBuilder
    private func models(_ r: Usage.Report) -> some View {
        if !r.models.isEmpty {
            SettingGroup(title: "Which brain answered") {
                ForEach(Array(r.models.enumerated()), id: \.element.id) { i, m in
                    SettingRow(title: m.model.isEmpty ? "Not recorded" : m.model,
                               detail: "\(Usage.compact(m.written)) said, \(Usage.compact(m.cacheRead + m.cacheWrite)) read back, over \(Usage.grouped(m.sessions)) \(m.sessions == 1 ? "conversation" : "conversations").",
                               note: Usage.billing(m.status)
                                   + (m.provider.isEmpty ? "" : " · \(m.provider)"),
                               last: i == r.models.count - 1) {
                        // A dash, not "$0", for anything that was never
                        // priced. `claude-opus-4` here has no billing
                        // status and no tokens, and rendering it as "$0"
                        // said "this was free" about something nobody
                        // costed — which is a claim, and the wrong one.
                        Text(m.usd > 0 ? Usage.dollars(m.usd) : "—")
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(m.usd > 0 ? Theme.ink : Theme.ink3)
                    }
                }
            }
        }
    }

    // MARK: - Where the work came from

    @ViewBuilder
    private func sources(_ r: Usage.Report) -> some View {
        if !r.sources.isEmpty {
            SettingGroup(title: "Where the work came from") {
                ForEach(Array(r.sources.enumerated()), id: \.element.id) { i, s in
                    // The token count is the row's trailing value, so it
                    // is not repeated in the sentence — it read "…2.1M
                    // tokens said." with "2.1M" printed beside it, which
                    // is the same number twice on one line.
                    SettingRow(title: Usage.where_(s.source),
                               detail: "\(Usage.grouped(s.sessions)) \(s.sessions == 1 ? "conversation" : "conversations"), \(Usage.grouped(s.messages)) messages.",
                               last: i == r.sources.count - 1) {
                        Text(Usage.compact(s.written))
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private func toolSection(_ r: Usage.Report) -> some View {
        if !r.tools.isEmpty {
            SettingGroup(title: "What Moe reached for") {
                VStack(alignment: .leading, spacing: 0) {
                    // Said before the list, not after it. §4.4 asks for
                    // "which tools cost most" and there is no such number
                    // anywhere in Hermes: tokens belong to a session and
                    // to nothing smaller. A column of counts under a
                    // heading about cost would be read as money.
                    Text("How often each one ran. Moe can't tell you what a tool cost: tokens are counted per conversation and never per tool, so there is no per-tool figure to show anywhere.")
                        .font(Theme.Typo.prose(13))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                        .padding(.vertical, Theme.Space.base)
                    ForEach(Array(r.tools.enumerated()), id: \.element.id) { i, t in
                        SettingRow(title: t.tool,
                                   detail: "",
                                   last: i == r.tools.count - 1) {
                            Text("\(Usage.grouped(t.calls)) \(t.calls == 1 ? "call" : "calls")")
                                .font(Theme.Typo.ui(12))
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                    if r.toolsTotal > r.tools.count {
                        Text("\(r.toolsTotal - r.tools.count) more ran less often.")
                            .font(Theme.Typo.ui(11))
                            .foregroundStyle(Theme.ink3)
                            .padding(.top, Theme.Space.small)
                    }
                }
            }
        }
    }

    // MARK: - Day by day

    @ViewBuilder
    private func dailySection(_ r: Usage.Report) -> some View {
        if !r.daily.isEmpty {
            SettingGroup(title: "Day by day") {
                VStack(alignment: .leading, spacing: Theme.Space.small) {
                    PaneButton(title: daily ? "Hide the day-by-day list" : "Show the day-by-day list (\(r.daily.count))",
                               symbol: daily ? "chevron.up" : "chevron.down") {
                        daily.toggle()
                    }
                    if daily {
                        // Newest first: "what did I use today" is the
                        // question, and the script hands them back oldest
                        // first because that is the order a chart wants.
                        let rows = r.daily.reversed().map { $0 }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, d in
                            SettingRow(title: Usage.day(d.day),
                                       detail: "\(Usage.compact(d.written)) said, \(Usage.compact(d.cacheRead + d.cacheWrite)) read back, \(Usage.grouped(d.sessions)) \(d.sessions == 1 ? "conversation" : "conversations").",
                                       last: i == rows.count - 1) {
                                Text(d.usd > 0 ? Usage.dollars(d.usd) : "—")
                                    .font(Theme.Typo.ui(12, weight: .semibold))
                                    .foregroundStyle(d.usd > 0 ? Theme.ink : Theme.ink3)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func load() {
        let window = days
        Task {
            let r = await ScriptRunner.offMain { Usage.report(days: window) }
            await MainActor.run {
                // Ignore an answer for a window the person has already
                // moved off: two overlapping loads used to land in the
                // order they finished rather than the order they were
                // asked for. The same guard `ActivityPane` carries.
                guard window == days else { return }
                if let r {
                    report = r
                } else {
                    var blank = Usage.Report()
                    blank.days = window
                    blank.error = "Moe couldn't reach the part of itself that adds this up."
                    report = blank
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
