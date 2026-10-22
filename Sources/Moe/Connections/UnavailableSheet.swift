import AppKit
import MoeDesign
import SwiftUI

/// What "Not available yet" actually means for one connection, and what would
/// change it.
///
/// The reason was always on the row — `call-recordings` says *no "Call
/// Recordings" folder in Notes*, `drive-docs` says it is not configured — but
/// it sat in a two-line grey caption under a red "Unavailable" pill, so the
/// screen read as "this is broken" with no way forward. Nothing here is new
/// information about the system; it is the information the row already had,
/// given the room to be a sentence.
struct UnavailableSheet: View {
    let row: Connection
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(row.label)
                .font(Theme.Typo.heading(24))
                .foregroundStyle(Theme.ink)

            Text(row.blurb.isEmpty ? "A source Alfie can read once it is available." : row.blurb)
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Why it isn't available")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                Text(reason)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.sunk)
            )

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("What would change it")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
                Text(remedy)
                    .font(Theme.Typo.prose(14))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.cosy) {
                Button(action: close) {
                    Text("Close")
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                if let url = URL(string: row.docs), !row.docs.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Text("Read more")
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, Theme.Space.wide)
                            .padding(.vertical, Theme.Space.small)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                    .fill(Theme.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Theme.Space.small)
        }
        .padding(Theme.Space.section)
        .frame(width: 440)
        .background(Theme.raised)
    }

    /// The connector's own words where it has any — every status script
    /// already prints a reason — and a plain sentence where it does not.
    private var reason: String {
        if !row.detail.isEmpty { return row.detail }
        return "Alfie checked for it on this Mac and didn't find it."
    }

    /// Written per connector where the answer is specific, because "check the
    /// documentation" is not an answer. Everything else falls back to the
    /// honest general case.
    private var remedy: String {
        switch row.name {
        case "call-recordings":
            return """
            Recorded calls come from a folder called “Call Recordings” in Notes. \
            It appears once you record a call on an iPhone signed in to the same \
            Apple account, with Notes syncing to iCloud. Alfie reads the transcripts \
            from there and never the audio. If your folder has a different name, \
            set MOE_CALL_FOLDER to it.
            """
        case "drive-docs", "drive-docs-pick":
            return """
            This one needs a Google sign-in client that isn't in your build — the \
            file is deliberately not committed, so a checkout can't ship someone \
            else's credentials. With it in place, connecting opens Google's own \
            picker and Alfie can read only the documents you tick, over the one \
            scope Google classes non-sensitive.
            """
        case "chrome":
            return """
            Alfie reads Chrome's history and bookmarks from a copy of the profile \
            on this Mac, so Chrome has to be installed and to have been used at \
            least once. It is off until you switch it on, and switching it off \
            stops both the reading and the crawl.
            """
        case "imessage", "mail", "calls":
            return """
            This reads a database inside your Library folder, which macOS keeps \
            sealed until Alfie has Full Disk Access. Settings → Permissions shows \
            whether that grant is live, and the row there deep-links to the exact \
            System Settings pane.
            """
        case "notes", "reminders", "calendar":
            return """
            Alfie asks macOS for this the first time it needs it. If you said no, \
            the grant is in Settings → Permissions, which shows whether it is \
            currently allowed and links to the pane that changes it.
            """
        default:
            return """
            Nothing is broken — this source isn't present on this Mac yet. When \
            whatever it reads exists, Alfie picks it up on the next check, and \
            “Check again” at the bottom of this screen forces one now.
            """
        }
    }
}
