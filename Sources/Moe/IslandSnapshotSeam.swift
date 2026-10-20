import SwiftUI

// The two accommodations `Moe --panel-snapshot` needs, and nothing else.
// docs/PANEL-FINDINGS.md §9 names both: they are properties of
// `ImageRenderer`, not opinions about the design, and they are declared here
// rather than inside the snapshot tool so that `IslandView` — which is the
// thing being photographed — carries one flag and no fork.
//
// The flag is false everywhere in the app. Read a running Moe's island and
// every line below is dead code with a `false` in front of it.

/// True only while `ImageRenderer` is drawing the island for a snapshot.
///
/// It exists because two AppKit-backed SwiftUI views do not rasterise:
///
///  - **`TextField`** draws through an `NSTextField`, which has no content
///    until it is in a window with a field editor. Rendered offscreen it is
///    a blank hole — and the ask field is the one control the meeting panel
///    exists for, so a snapshot that loses it is a snapshot of the wrong
///    panel. `IslandFieldStandIn` draws the same string in the same box.
///  - **`ScrollView`** on macOS rasterises empty: its clip view has no
///    geometry offscreen, so every row inside it disappears. `IslandScrollBox`
///    lays the same rows over a `Color.clear` that claims the height the
///    scroll view claims, and clips the same way, so what the picture shows
///    is what the panel shows.
///
/// Both stand-ins take the *same* content the real control takes. That is the
/// whole discipline of §9: a preview that can drift from the thing it
/// previews is worse than no preview.
private struct IslandSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandSnapshot: Bool {
        get { self[IslandSnapshotKey.self] }
        set { self[IslandSnapshotKey.self] = newValue }
    }
    /// The Accessibility sentence a snapshot poses, in place of asking the
    /// live `AccessibilityWatch`. The row used to be skipped outright while
    /// snapshotting, so the state that pushed the ask field off the bottom
    /// of the panel — that row under a nudge card — could not be
    /// photographed, and was not.
    var islandPosedAccessibility: String? {
        get { self[IslandPosedAccessibilityKey.self] }
        set { self[IslandPosedAccessibilityKey.self] = newValue }
    }
}

private struct IslandPosedAccessibilityKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// A snapshot with the dropdown's ⋯ tray slid open (`IslandTray`). The
    /// tray is a click's worth of view state, which a still cannot make.
    var islandPosedTrayOpen: Bool {
        get { self[IslandPosedTrayOpenKey.self] }
        set { self[IslandPosedTrayOpenKey.self] = newValue }
    }
}

private struct IslandPosedTrayOpenKey: EnvironmentKey {
    static let defaultValue = false
}

/// What the ask field looks like, drawn as text rather than as an
/// `NSTextField`. Same font, same colours, same box, same placeholder — so
/// the measurements a snapshot is taken to check are the real ones.
struct IslandFieldStandIn: View {
    let placeholder: String
    let text: String

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 12))
            .foregroundStyle(text.isEmpty ? .white.opacity(0.35) : .white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A scroll view that rasterises.
///
/// The real one claims all the height it is offered and shows the tail of its
/// content, clipped at the top. So does this: a greedy `Color.clear` behind
/// bottom-aligned rows, clipped. Anything that overflows the panel in the app
/// overflows it here, which is the point — §9's first catch was content laid
/// out past both ends of the panel because a plain `VStack` claims all the
/// height a `ScrollView` politely claims none of.
struct IslandScrollBox<Content: View>: View {
    @Environment(\.islandSnapshot) private var snapshotting
    /// True where the real scroll view is scrolled to its end on appear (both
    /// transcript boxes), false where it rests at the top (the notes panel).
    /// Which end is cut when the content overruns is the whole question a
    /// snapshot of an overfull panel is asked to answer, so it is not guessed.
    var tail = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        if snapshotting {
            // `overlay`, not `ZStack`: an overlay is sized to its base and
            // takes no part in layout, so the box is exactly the height the
            // `Color.clear` claims — which is the height the `ScrollView`
            // claims — and anything longer is clipped rather than allowed to
            // shove the panel's own edges apart.
            //
            // `ViewThatFits` is the other half of being faithful. A scroll
            // view holds short content at the top with slack under it, and
            // overfull content against whichever end it is scrolled to. The
            // first branch is content plus a zero-ideal `Spacer`, so it is
            // measured at the content's own height and chosen exactly when
            // that fits. The second is the overfull case, pinned to the end
            // the real scroll view shows — a bare `VStack` there overflows
            // *both* ways from its centre, which cuts a line off the top and
            // a line off the bottom and is a picture of nothing.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) { content(); Spacer(minLength: 0) }
                // The overfull case. `fixedSize` first, or the rows accept the
                // short proposal, report the height they were handed and draw
                // past *both* ends — a line lost off the top and a line off
                // the bottom, which is a picture of nothing. Then they ride on
                // the greedy `Color.clear` as an overlay, which is sized to
                // its base and takes no part in layout, so the box stays
                // exactly the height the `ScrollView` claims and the rows are
                // pinned to the end the real one shows.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: tail ? .bottom : .top) {
                        content().fixedSize(horizontal: false, vertical: true)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            ScrollView { content() }
        }
    }
}

/// What `Toggle(.checkbox)` looks like, drawn rather than asked for.
///
/// A third thing that does not rasterise — `ImageRenderer` puts SwiftUI's
/// yellow "unsupported" bar where the control should be, which is worse than
/// useless in a picture taken to judge a layout. Drawn from the *system*
/// colours rather than from the island's palette on purpose: the point
/// docs/PANEL-FINDINGS.md §8 makes about this control is that it is an AppKit
/// control on a black panel and follows the Mac's appearance, not the panel's,
/// so a light-mode snapshot has to show a light box.
struct IslandCheckboxStandIn: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .overlay {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 13, height: 13)
    }
}

extension EnvironmentValues {
    /// A snapshot with one inbox row's Snooze choices open, by notice id.
    var islandPosedSnoozeOpen: String? {
        get { self[IslandPosedSnoozeOpenKey.self] }
        set { self[IslandPosedSnoozeOpenKey.self] = newValue }
    }
}

private struct IslandPosedSnoozeOpenKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
