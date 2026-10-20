import MoeDesign
import SwiftUI
import MoeDictation

/// Where the dictation rewrite runs, and what each choice actually costs.
///
/// The rewrite used to be one hidden call to whatever brain the conversation
/// used, taking ~2 s and sending the transcript off the Mac. Both of those
/// are things a person might reasonably want to change, and neither was
/// visible. This is that choice, made once, in plain words.
///
/// Two rules the copy follows:
///
/// - **Say what each one costs, not what it is.** Nobody is choosing a model
///   architecture; they are choosing between fast, private, and capable. The
///   row names an outcome and the line under it says the trade.
/// - **Never overstate privacy.** `PolishTier.isOnDevice` is the single
///   source for which choices keep the text on the machine, so the badge
///   cannot drift from the truth the way a hand-written sentence would.
///
/// Availability is live and re-checked when the pane appears, because all
/// three of Apple's unavailable states — off, downloading, ready — happened
/// on one Mac in one afternoon, and a pane that said "unavailable" for all of
/// them would have been useless in every one.
struct PolishTierPicker: View {
    @ObservedObject var conductor: Conductor

    /// Nil means "fastest available" — the default, and the right answer for
    /// almost everyone, because it uses the best tier the machine has today
    /// and a better one tomorrow without anybody revisiting this pane.
    private var selected: PolishTier? {
        PolishTier(rawValue: conductor.config.dictationPolishTier)
    }

    private var enabled: Bool {
        conductor.config.dictationEnabled && conductor.config.dictationPolish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            choice(nil, title: "Fastest available",
                   detail: "Uses whichever of the below works on this Mac, quickest first. "
                         + "Picks up a better one on its own if you add it later.")
            ForEach(PolishTier.allCases, id: \.self) { tier in
                choice(tier, title: tier.displayName,
                       detail: conductor.polishTierStatus[tier] ?? "Checking…")
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear { conductor.refreshPolishTiers() }
    }

    private func choice(_ tier: PolishTier?, title: String, detail: String) -> some View {
        let on = selected == tier
        // "Fastest available" is never dimmed: it is a strategy, not a tier,
        // and it always resolves to something (rules, at worst).
        let ready = tier.map { conductor.polishTierReady.contains($0) } ?? true
        return Button {
            conductor.setDictationPolishTier(tier)
            conductor.refreshPolishTiers()
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.small) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Theme.accentDeep : Theme.ink3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.snug) {
                        Text(title)
                            .font(Theme.Typo.ui(13, weight: on ? .semibold : .regular))
                            .foregroundStyle(ready ? Theme.ink : Theme.ink3)
                        if let tier, !tier.isOnDevice {
                            badge("leaves this Mac")
                        }
                    }
                    Text(detail)
                        .font(Theme.Typo.prose(12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.label(9))
            .tracking(Theme.tracking)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.rule, lineWidth: 1)
            )
    }
}
