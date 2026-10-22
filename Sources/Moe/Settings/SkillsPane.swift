import AppKit
import MoeDesign
import SwiftUI

/// Settings › Skills: what Moe knows how to do, and what to switch off.
///
/// A skill is a page of instructions Hermes hands the model when the job
/// looks like the one the page describes. Ninety-six of them are on this
/// Mac and nothing has ever shown a person which — so the screen's first
/// job is simply to say what is there, in words rather than in folder
/// names.
///
/// **Three rules, and none of them is a preference.**
///
/// *The only thing this writes is `skills.disabled`.* HERMES-SURFACES
/// §4.5: that key already crosses between this Mac and Moe Away as a
/// sealed record, so a switch here is a switch in both places on the day
/// it ships. A second mechanism would be a second answer to one question.
///
/// *A skill that cannot run says so, and that is the point of the screen.*
/// Hermes never checks a skill's declared prerequisites — `skills_tool.py`
/// hard-codes `required_commands` and `missing_required_commands` to empty
/// lists — so the model reads the page, runs `memo`, gets `command not
/// found`, and the turn is gone. On this Mac eleven skills declare a
/// command that is missing and seven of those eleven are switched **on**.
/// Those seven are the reason this pane exists, so they are shown first
/// and by name, not left for someone to find by scrolling.
///
/// *A switch that cannot do anything is not drawn.* Hermes refuses to
/// disable `hermes-agent`, and it only offers `sdlc-review` inside a
/// kanban session. Both are shown, with the reason, and neither gets a
/// button — a well-formed control that resolves to nothing is worse than
/// an absent one, because absence is honest.
///
/// **What this pane deliberately does not do:** install a skill, write
/// one, or delete one. `hermes skills install` reaches seven registries
/// and `skill_manage` is offered to the model on this runtime — but
/// whether Moe should be *authoring* skills is an open decision (§4.5),
/// and a settings pane is not where a decision gets taken by accident.
@MainActor
struct SkillsPane: View {
    @ObservedObject var conductor: Conductor

    /// Opens on a particular filter. Only `--settings-snapshot` passes
    /// one — the trouble list and the off list are both layouts no scroll
    /// position can reach, and a layout that ships unlooked-at is how
    /// eleven presentation bugs reached two panes on 2026-09-04.
    init(conductor: Conductor, filter: Filter = .all, embedded: Bool = false) {
        self.embedded = embedded
        self.conductor = conductor
        _shown = State(initialValue: filter)
    }

    /// Which slice of ninety-six is on screen. `trouble` is first in the
    /// row because it is the one a person can act on.
    enum Filter: String, CaseIterable {
        case all, trouble, off, used

        var title: String {
            switch self {
            case .all: return "Everything"
            case .trouble: return "Can't run"
            case .off: return "Switched off"
            case .used: return "Alfie has used"
            }
        }
    }

    /// Nil until asked. A reader that answered and refused arrives with
    /// `ok` false and words to show. Three states, not two.
    @State private var catalogue: Skills.Catalogue?
    @State private var shown: Filter
    @State private var busy = ""
    @State private var trouble = ""

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                PaneHeader(title: "Skills") {
                    PaneButton(title: "Refresh", symbol: "arrow.clockwise") { load() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let catalogue {
                        summary(catalogue)
                        if !catalogue.error.isEmpty {
                            PaneBanner(tone: .warn, text: catalogue.error)
                        }
                        if !trouble.isEmpty { PaneBanner(tone: .bad, text: trouble) }
                        if !catalogue.canWrite, catalogue.ok {
                            PaneBanner(tone: .warn, text: catalogue.whyNot.isEmpty
                                       ? "Alfie can't change these from here."
                                       : catalogue.whyNot)
                        }
                        if catalogue.ok {
                            filters(catalogue)
                            groups(catalogue)
                        }
                    } else {
                        checking("Looking at what Alfie knows how to do…")
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

    /// Drawn inside Settings › Brain › Skills (2026-09-28).
    var embedded = false

    @ViewBuilder
    private func summary(_ c: Skills.Catalogue) -> some View {
        if c.ok {
            // The bad news first and by name. A skill that is on and
            // cannot run is the one thing on this screen that costs a
            // person a turn, and it is invisible everywhere else in the
            // product — Hermes does not check, and the model finds out by
            // trying.
            if c.misfiring > 0 {
                PaneBanner(tone: .warn,
                           text: "\(c.misfiring) \(c.misfiring == 1 ? "skill is" : "skills are") switched on but tell Alfie to run something that isn't installed on this Mac. Alfie finds that out by trying, which costs you the answer.")
            }
            // On plus off equals the total, always. It did not until this
            // was rendered — the gated one was quietly missing from both
            // sides and the sentence read "96 skills — 91 on, 4 off",
            // which invites a reader to go looking for the ninety-sixth.
            Text("\(c.counted) skills on this Mac — \(c.on) switched on, \(c.off) off. Alfie reads one when a job looks like it."
                 + (c.gated == 0 ? ""
                    : " \(c.gated == 1 ? "One of them is" : "\(c.gated) of them are") only offered inside another kind of session."))
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
    }

    // MARK: - Filters

    private func filters(_ c: Skills.Catalogue) -> some View {
        Calm.Segments(options: Filter.allCases.map { ($0.rawValue, "\($0.title) · \(count($0, c))") },
                      selection: Binding(get: { shown.rawValue }, set: { pick in
                          guard let f = Filter(rawValue: pick) else { return }
                          shown = f
                      }))
    }

    private func count(_ filter: Filter, _ c: Skills.Catalogue) -> String {
        String(slice(filter, c).count)
    }

    /// The rows a filter shows. Written once and used for both the chip's
    /// count and the list, so a chip saying "7" can never sit above a list
    /// of five.
    private func slice(_ filter: Filter, _ c: Skills.Catalogue) -> [Skills.Skill] {
        switch filter {
        case .all: return c.skills
        case .trouble: return c.skills.filter(\.willMisfire)
        case .off: return c.skills.filter { !$0.enabled }
        case .used: return c.skills.filter { $0.uses > 0 }
        }
    }

    // MARK: - The list

    @ViewBuilder
    private func groups(_ c: Skills.Catalogue) -> some View {
        let rows = slice(shown, c)
        if rows.isEmpty {
            SettingGroup(title: shown.title) {
                Text(empty(shown))
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.base)
            }
        } else {
            ForEach(byCategory(rows), id: \.0) { heading, items in
                SettingGroup(title: heading) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, skill in
                        row(skill, last: i == items.count - 1, canWrite: c.canWrite)
                    }
                }
            }
        }
    }

    /// The empty state has to be different per filter. "Nothing here" over
    /// the trouble list is good news and over the whole list is a broken
    /// install, and one sentence for both would say neither.
    private func empty(_ filter: Filter) -> String {
        switch filter {
        case .all: return "There are no skills on this Mac."
        case .trouble: return "Nothing switched on is missing a command. This is the state to be in."
        case .off: return "Nothing is switched off."
        case .used: return "Alfie hasn't opened any of these yet."
        }
    }

    /// Grouped by category, in the order the catalogue already sorted
    /// them — so nothing is re-sorted here and a heading cannot disagree
    /// with the rows under it.
    private func byCategory(_ rows: [Skills.Skill]) -> [(String, [Skills.Skill])] {
        var out: [(String, [Skills.Skill])] = []
        for skill in rows {
            let heading = Skills.heading(for: skill.category)
            if out.last?.0 == heading {
                out[out.count - 1].1.append(skill)
            } else {
                out.append((heading, [skill]))
            }
        }
        return out
    }

    private func row(_ skill: Skills.Skill, last: Bool, canWrite: Bool) -> some View {
        SettingRow(title: mark(skill) + "  " + Skills.title(for: skill.name),
                   detail: detail(skill),
                   note: under(skill),
                   last: last) {
            // No switch for the two kinds that cannot take one. Hermes
            // subtracts an essential skill from the key on read, and it
            // only offers a gated one inside an environment this Mac is
            // not in — a button on either would look like it worked.
            if skill.essential || skill.gated {
                Text(skill.essential ? "Always on" : "Not offered here")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
            } else if busy == skill.name {
                ProgressView().controlSize(.small)
            } else {
                PaneButton(title: skill.enabled ? "Switch off" : "Switch on",
                           symbol: skill.enabled ? "circle.slash" : "checkmark",
                           danger: skill.enabled && skill.willMisfire) {
                    flip(skill)
                }
                .disabled(!canWrite)
                .opacity(canWrite ? 1 : 0.4)
            }
        }
    }

    /// The skill's own description, and never a made-up one. Hermes cuts
    /// these at 1,024 characters and some of them use every one; a row is
    /// a row, so this takes the first sentence's worth and leaves the rest
    /// in the file.
    private func detail(_ skill: Skills.Skill) -> String {
        let text = Chats.line(skill.description, limit: 180)
        return text.isEmpty ? Skills.origin(skill) : text
    }

    private func under(_ skill: Skills.Skill) -> String? {
        var parts: [String] = []
        let note = Skills.note(skill)
        if !note.isEmpty { parts.append(note) }
        let origin = Skills.origin(skill)
        // The origin is already the detail line when there is no
        // description, so saying it twice would be a row that repeats
        // itself. Found by rendering.
        if !origin.isEmpty, !skill.description.isEmpty { parts.append(origin) }
        let line = parts.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// A mark rather than a coloured dot: four states, and colour alone
    /// would say "this one is bad" about the one that is merely off on
    /// purpose.
    ///
    /// All four are codepoints whose *default* presentation is emoji.
    /// `⚠` (U+26A0) is not — it needs U+FE0F after it — and one without
    /// the selector rendered as a pale outline beside three solid marks on
    /// the Activity pane until that was measured in a snapshot.
    ///
    /// **Off is `⚪️`, not `⭕️`**, which is the second thing rendering
    /// found: `⭕️` draws as a heavy red ring, so every deliberately
    /// switched-off skill sat under a red mark beside the amber one that
    /// means "this is broken". Being off is not a fault; four of these are
    /// off because Moe turned them off on purpose.
    private func mark(_ skill: Skills.Skill) -> String {
        if skill.willMisfire { return "⚠️" }
        if skill.gated { return "🔒" }
        return skill.enabled ? "✅" : "⚪️"
    }

    // MARK: - Switching

    private func flip(_ skill: Skills.Skill) {
        busy = skill.name
        trouble = ""
        let want = !skill.enabled
        Task {
            let result = await ScriptRunner.offMain { Skills.set(skill.name, on: want) }
            await MainActor.run {
                busy = ""
                guard let result else {
                    // No answer at all — the script could not be found or
                    // it crashed. Different from a refusal, and said
                    // differently: a refusal has words of its own.
                    trouble = "Alfie couldn't reach the part of itself that keeps the skill list."
                    return
                }
                if !result.ok {
                    trouble = result.error.isEmpty
                        ? "Alfie couldn't change that one."
                        : result.error
                    return
                }
                // Re-read rather than patching the row in place. The key
                // is shared with `configure-hermes.py` and with Moe Away,
                // and a local edit that assumed it won would show a switch
                // in a state the file does not have.
                load()
            }
        }
    }

    // MARK: - Loading

    private func load() {
        Task {
            let c = await ScriptRunner.offMain { Skills.catalogue() }
            await MainActor.run {
                // Never nil onward: a reader that gave no answer at all
                // still has to draw something, and an empty list with no
                // words is the one thing it must not be.
                if let c {
                    catalogue = c
                } else {
                    var blank = Skills.Catalogue()
                    blank.error = "Alfie couldn't reach the part of itself that keeps the skill list."
                    catalogue = blank
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
