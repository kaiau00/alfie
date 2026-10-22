import MoeDesign
import SwiftUI

/// Settings › Privacy in a build with no cloud. Nothing leaves this Mac, so
/// there is no switch for what may, no documents agreed to and no account to
/// delete — only the way out. The official build draws its own page
/// (`CloudLink.privacyPage`), whose last row is this one.
struct LocalPrivacyPane: View {
    let conductor: Conductor

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Privacy")
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    SettingGroup(title: "Delete") {
                        SettingRow(title: "Erase Alfie from this Mac",
                                   detail: "Removes everything Alfie put on this Mac — what it knows, your conversations, "
                                       + "its connections and downloads — and starts it again like a new install.",
                                   last: true) {
                            PaneButton(title: "Erase…", danger: true) { MacEraseFlow.present(conductor: conductor) }
                        }
                    }
                }
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
