import MoeDesign
import SwiftUI

/// Settings › History: what already happened, in one place — Activity,
/// Usage and Chats, which were three pages in the sidebar until the owner
/// asked for fewer (2026-09-28). Each tab is the page it was, drawn without
/// its own header.
struct HistoryPane: View {
    @ObservedObject var conductor: Conductor
    @State private var tab: MainWindow.Section

    static let tabs: [(MainWindow.Section, String)] = [(.activity, "Activity"), (.usage, "Usage"), (.chats, "Chats")]

    init(conductor: Conductor, start: MainWindow.Section? = nil) {
        self.conductor = conductor
        let wanted = start ?? .activity
        _tab = State(initialValue: Self.tabs.contains { $0.0 == wanted } ? wanted : .activity)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("History")
            HStack {
                PaneTabs(tabs: Self.tabs, selection: $tab)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, Theme.Space.base)
            switch tab {
            case .usage: UsagePane(conductor: conductor, embedded: true)
            case .chats: ChatsPane(conductor: conductor, embedded: true)
            default:     ActivityPane(conductor: conductor, embedded: true)
            }
        }
        .background(Theme.raised)
    }
}
