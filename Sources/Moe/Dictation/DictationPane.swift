import MoeDesign
import MoeDictation
import SwiftUI

/// Dictation's own screen.
///
/// Until now the highest-frequency thing in the app had nowhere to live: its
/// settings were nine toggles inside Voice, its history was a sheet reachable
/// from one of them, and its live text went into `Conductor.turns` — which is
/// why dictating into Slack put your words in Chat. The stream is split now
/// (see `Conductor.dictationPartial`); this is the room it goes to instead.
///
/// What it shows is deliberately "what you said and where it went", not
/// "recognition statistics". A dictation you can find and re-paste is worth
/// more than a confidence score.
struct DictationPane: View {
    @ObservedObject var conductor: Conductor

    @State private var search = ""
    @State private var entries: [DictationHistory.Entry] = []
    @State private var confirmClear = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true   // "Today", "Yesterday"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.rule).frame(height: 1)

            if entries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if search.isEmpty { summary }
                        ForEach(grouped, id: \.0) { day, items in
                            Text(day)
                                .font(Theme.Typo.label(9))
                                .tracking(Theme.tracking)
                                .foregroundStyle(Theme.ink3)
                                .padding(.top, Theme.Space.wide)
                                .padding(.bottom, Theme.Space.small)
                            ForEach(items) { entry in
                                row(entry)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.wide)
                    .padding(.bottom, Theme.Space.wide)
                }
            }
        }
        .background(Theme.raised)
        .onAppear(perform: reload)
        .onChange(of: search) { _, _ in reload() }
        // A dictation lands the moment the key comes up, so the list refreshes
        // when the engine goes back to rest rather than on a timer.
        .onChange(of: conductor.dictation) { _, state in
            if state == .off { reload() }
        }
        .confirmationDialog("Delete everything dictated?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                conductor.clearDictationHistory()
                reload()
            }
        } message: {
            Text("The text is only on this Mac, and this cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.base) {
            Text("Dictation")
                .font(Theme.Typo.heading(19))
                .foregroundStyle(Theme.ink)

            Spacer(minLength: Theme.Space.base)

            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.ui(12))
                    .frame(width: 130)
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .strokeBorder(Theme.rule, lineWidth: 1.5)
            )

            quietButton("Settings") {
                SettingsWindow.show(conductor: conductor, at: .voice)
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.base)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.ui(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, Theme.Space.base)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.ruleStrong, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary
    //
    // Only what the history actually knows. There is no per-dictation timing
    // in the log, so there is no "average polish time" here — an invented
    // number would be worse than a missing one.

    private var summary: some View {
        let today = entries.filter { Calendar.current.isDateInToday($0.at) }
        let words = today.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let polished = today.filter(\.polished).count
        return HStack(alignment: .top, spacing: Theme.Space.section) {
            stat("\(words)", "words today")
            stat("\(today.count)", "dictations")
            stat("\(polished)", "polished")
        }
        .padding(.top, Theme.Space.roomy)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(value)
                .font(Theme.Typo.display(28))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
        }
    }

    // MARK: - Rows

    private func row(_ entry: DictationHistory.Entry) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            Text(Self.time.string(from: entry.at))
                .font(Theme.Typo.data(10))
                .foregroundStyle(Theme.ink3)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                if let app = entry.appName {
                    Text("→ \(app)")
                        .font(Theme.Typo.label(9))
                        .tracking(Theme.tracking)
                        .foregroundStyle(Theme.accentDeep)
                }
                Text(entry.text)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                Text(meta(entry))
                    .font(Theme.Typo.data(9))
                    .foregroundStyle(Theme.ink3)
            }

            Spacer(minLength: Theme.Space.small)

            HStack(spacing: Theme.Space.small) {
                iconButton("arrow.down.doc", help: "Type this at the cursor again") {
                    conductor.pasteAgain(entry.text)
                }
                iconButton("trash", help: "Forget this one") {
                    conductor.deleteDictationHistory(id: entry.id)
                    reload()
                }
            }
            .padding(.top, 1)
        }
        .padding(.vertical, Theme.Space.base)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    private func meta(_ entry: DictationHistory.Entry) -> String {
        let words = entry.text.split(whereSeparator: \.isWhitespace).count
        return entry.polished
            ? "\(words) words · polished"
            : "\(words) words · left as spoken"
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(search.isEmpty ? "Nothing dictated yet" : "No matches")
                .font(Theme.Typo.heading(20))
                .foregroundStyle(Theme.ink)
            if search.isEmpty {
                Text(startHint)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
            }
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Names the key the user actually has bound, never a default we assume.
    private var startHint: String {
        guard conductor.config.dictationEnabled else {
            return "Dictation is switched off. Turn it on in Settings, then hold your dictation key anywhere and talk — the words arrive at the cursor."
        }
        return "Hold \(conductor.effectiveDictationKey.displayName) anywhere and talk. The words arrive at the cursor, and what you said is kept here so you can send it again."
    }

    // MARK: - Data

    /// Newest first, grouped into days. `dictationHistoryEntries` already
    /// sorts and filters; this only cuts it into sections.
    private var grouped: [(String, [DictationHistory.Entry])] {
        var order: [String] = []
        var byDay: [String: [DictationHistory.Entry]] = [:]
        for entry in entries {
            let key = Self.day.string(from: entry.at)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(entry)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    private func reload() {
        entries = conductor.dictationHistoryEntries(matching: search)
    }
}
