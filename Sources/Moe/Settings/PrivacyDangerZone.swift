import AppKit
import LocalAuthentication
import MoeDesign
import MoeErase
import SwiftUI

// Settings › Privacy, the bottom of the page (docs/CLOUD-REMAINING.md D9.9):
// **Delete my account** (D9.11) and **Erase Memoe from this Mac** (D9.12).
//
// Two entry points, `DeleteAccountFlow.present` (the official build's closed
// half, with the account) and `MacEraseFlow.present`, each opening its own
// small window. The work is elsewhere: the account's deletion in the closed
// half, and `MacErase` (Sources/MoeErase, wired in Sources/Moe/MacErase.swift). This
// file is the words and the order of the steps, and nothing is deleted from
// here until a person has read two warnings and proved who they are.

// MARK: - The words

/// Every sentence the two flows show. D9.11's two steps are the spec's own
/// copy, verbatim; D9.12's warnings are written to it ("two warnings in
/// different words").
enum DangerZoneCopy {
    // D9.11 — exact.
    static let deleteTitle = "Delete my account"
    static let deleteExplain = "This cancels your plan and deletes your cloud computer, everything on it, your connected accounts, your problem reports and your Alfie account. Alfie on this Mac keeps working, signed out."
    /// A free account has no plan and no cloud computer — signing in with
    /// Google made it, for connections — so it is not told they go
    /// (owner, 2026-09-11: "it shows me delete your cloud account even
    /// though I don't have one").
    static let deleteExplainFree = "This deletes your Alfie account: your sign-in with us, the apps and accounts you connected through it, and your problem reports. Alfie on this Mac keeps working, signed out."
    static func deleteExplain(paid: Bool) -> String { paid ? deleteExplain : deleteExplainFree }
    static let deleteConfirm = "This can't be undone. Type DELETE to confirm."
    static let deleteDoneTitle = "Your account is deleted"
    static let deleteDoneBody = "Alfie on this Mac keeps working, signed out."

    // D9.12 — first warning: what goes and what stays. CuaDriver is named as
    // going only when the plan removes it (MacErasePlan.removesCuaDriver):
    // never for Moe Dev, which shares it, and never when it is absent or
    // refused.
    static let eraseTitle = "Erase Alfie from this Mac"
    static let eraseWhatGoes = "Alfie will remove everything it has put on this Mac: what it remembers about you, your conversations, notes and meeting recordings, the apps and accounts you connected, the ways you message it, the voices and models it downloaded, its background jobs, the tool Alfie uses to work your screen, and the permissions you gave it."
    static let eraseWhatGoesDev = "Alfie will remove everything it has put on this Mac: what it remembers about you, your conversations, notes and meeting recordings, the apps and accounts you connected, the ways you message it, the voices and models it downloaded, its background jobs, and the permissions you gave it."
    static let eraseWhatStays = "What stays: the Alfie app itself, which opens again as if it were new, and Claude Code's and ChatGPT's own sign-ins, which belong to them. Your own files are not touched."
    static let alsoDelete = "Delete my account too"
    static let alsoDeleteCaption = "Also cancels your plan and deletes your cloud computer, everything on it, and your Alfie account. Leave this off and your account stays as it is."

    // D9.12 — second warning, in different words.
    static let noUndoTitle = "There's no undo"
    static let noUndoBody = "Nothing goes to the Bin, and there's no copy anywhere to bring it back from. When you confirm, Alfie quits, clears itself off this Mac, and starts again at the welcome screen."
    static let noUndoGoesCuaDriver = "Goes too: CuaDriver, the tool Alfie uses to work your screen, and the screen permissions you gave it. Any other program on this Mac that uses CuaDriver will stop working until it is installed again."
    static let noUndoStays = "Stays on this Mac: the Alfie app, uv and the Python it downloaded (~/.local/share/uv), and Claude Code and ChatGPT — their apps, their commands and their own sign-ins, which belong to them."
    static let noUndoStaysDev = "Stays on this Mac: the Alfie app, CuaDriver (the tool Alfie uses to work your screen, which Alfie Dev shares with Alfie), uv and the Python it downloaded (~/.local/share/uv), and Claude Code and ChatGPT — their apps, their commands and their own sign-ins, which belong to them."
    /// What the plan will do, not what the build would like to: before the
    /// plan has loaded, CuaDriver is not mentioned as going.
    static func whatGoesText(_ plan: MacErasePlan?) -> String {
        plan?.removesCuaDriver == true ? eraseWhatGoes : eraseWhatGoesDev
    }
    static func noUndoStaysText(_ plan: MacErasePlan?) -> String {
        if plan?.removesCuaDriver == true { return noUndoGoesCuaDriver + " " + noUndoStays }
        return plan?.scope.identity.ownsSharedResources == false ? noUndoStaysDev : noUndoStays
    }
    static let noUndoAccount = "Your Alfie account is deleted first: your plan is cancelled and your cloud computer is gone. Type DELETE to confirm."
    static let proveGoogle = "Next, Google asks you to sign in — that's how Alfie knows it's you."
    static let proveLocal = "Next, Touch ID or your Mac's login password confirms it's you."
    static let eraseButton = "Erase this Mac"
    static let showExactly = "Show exactly what will be removed"
    static let localReason = "erase Alfie from this Mac"
}

/// Why this Mac could not ask its owner to prove it is them.
enum OwnerProofError: Error, CustomStringConvertible {
    case cannotAuthenticate(String)

    var description: String {
        switch self {
        case .cannotAuthenticate(let why):
            return "This Mac can't ask for Touch ID or your password: \(why)"
        }
    }
}

// MARK: - The shared engine

enum DangerZone {

    /// Touch ID, or the login password where there is none.
    static func proveOwner() async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw OwnerProofError.cannotAuthenticate(error?.localizedDescription ?? "unavailable")
        }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                             localizedReason: DangerZoneCopy.localReason)
    }

    /// Why it did not work, for a person. The cloud's own errors (a Google
    /// sign-in, the account) are its to word.
    @MainActor
    static func sentence(for error: Error) -> String {
        if let cloud = Cloud.link.eraseFailure(error) { return cloud }
        if let e = error as? OwnerProofError { return e.description }
        if let e = error as? LAError, e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            return "You cancelled."
        }
        return "\(error)"
    }
}

// MARK: - Window

/// One small window at a time, owned here until it closes.
@MainActor
enum DangerWindow {
    static var current: NSWindow?

    static func show<V: View>(_ view: V, over parent: NSWindow?) {
        current?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        if let parent {
            let p = parent.frame, s = window.frame.size
            window.setFrameOrigin(NSPoint(x: p.midX - s.width / 2, y: p.midY - s.height / 2))
        } else {
            window.center()
        }
        current = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        current?.close()
        current = nil
    }
}

// MARK: - D9.12 Erase Memoe from this Mac

enum MacEraseFlow {
    @MainActor
    static func present(conductor: Conductor) { present(over: NSApp.keyWindow, conductor: conductor) }

    @MainActor
    static func present(over parent: NSWindow?, conductor: Conductor) {
        DangerWindow.show(MacEraseView(conductor: conductor, close: { DangerWindow.close() }), over: parent)
    }
}

private struct MacEraseView: View {
    let conductor: Conductor
    let close: () -> Void

    enum Step: Equatable { case whatGoes, noUndo, proving, quitting, failed(String) }
    @State private var step: Step = .whatGoes
    @State private var signedIn = false
    @State private var alsoDeleteAccount = false
    @State private var typed = ""
    @State private var plan: MacErasePlan?
    @State private var planError: String?
    @State private var showExactly = false

    var body: some View {
        DangerCard {
            switch step {
            case .whatGoes:
                DangerText(title: DangerZoneCopy.eraseTitle,
                           body: DangerZoneCopy.whatGoesText(plan))
                DangerText(title: nil, body: DangerZoneCopy.eraseWhatStays)
                if signedIn {
                    Toggle(isOn: $alsoDeleteAccount) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DangerZoneCopy.alsoDelete).font(Theme.Typo.ui(13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(DangerZoneCopy.alsoDeleteCaption).font(Theme.Typo.ui(12))
                                .foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if let planError {
                    DangerText(title: nil, body: "This copy of Alfie can't erase itself: \(planError)", small: true)
                }
                DangerButtons(cancel: close, confirm: "Continue", destructive: false,
                              enabled: planError == nil) { step = .noUndo }
            case .noUndo:
                DangerText(title: DangerZoneCopy.noUndoTitle, body: DangerZoneCopy.noUndoBody)
                DangerText(title: nil, body: DangerZoneCopy.noUndoStaysText(plan), small: true)
                if alsoDeleteAccount {
                    DangerText(title: nil, body: DangerZoneCopy.noUndoAccount)
                    DeleteField(text: $typed)
                }
                DangerText(title: nil, body: signedIn ? DangerZoneCopy.proveGoogle : DangerZoneCopy.proveLocal, small: true)
                DisclosureGroup(DangerZoneCopy.showExactly, isExpanded: $showExactly) {
                    PlanList(plan: plan)
                }
                .font(Theme.Typo.ui(12))
                DangerButtons(cancel: close, confirm: DangerZoneCopy.eraseButton, destructive: true,
                              enabled: plan != nil && (!alsoDeleteAccount || typed == "DELETE")) { start() }
            case .proving:
                DangerText(title: DangerZoneCopy.eraseTitle,
                           body: signedIn ? "Sign in with Google in your browser to confirm it's you. Alfie waits here."
                                          : "Confirm it's you.")
                ProgressView().controlSize(.small)
            case .quitting:
                DangerText(title: "Erasing", body: "Alfie is quitting to clear itself off this Mac. It opens again at the welcome screen.")
                ProgressView().controlSize(.small)
            case .failed(let why):
                DangerText(title: "Nothing was erased", body: why)
                DangerButtons(cancel: close, confirm: "Back", destructive: false) { typed = ""; step = .whatGoes }
            }
        }
        .task { await load() }
    }

    private func load() async {
        signedIn = await conductor.cloud.accountSignedIn()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<MacErasePlan, Error> in
            Result { try MacEraseRun.plan() }
        }.value
        switch result {
        case .success(let p): plan = p
        case .failure(let e): planError = "\(e)"
        }
    }

    private func start() {
        guard plan != nil, !alsoDeleteAccount || typed == "DELETE" else { return }
        step = .proving
        Task { @MainActor in
            do {
                if signedIn {
                    // The account's proof — and, with `alsoDeleteAccount`,
                    // the deletion first, whose sign-in is also this erase's
                    // proof — is the cloud's (`CloudLink.proveForErase`).
                    try await conductor.cloud.proveForErase(deleteAccount: alsoDeleteAccount)
                } else {
                    try await DangerZone.proveOwner()
                }
            } catch {
                let why = DangerZone.sentence(for: error)
                step = .failed(alsoDeleteAccount ? "Your account was not deleted, so nothing was erased. \(why)" : why)
                return
            }
            do {
                step = .quitting
                try await MacEraseRun.eraseAfterQuit()
            } catch {
                step = .failed("Alfie couldn't start the erase: \(error)")
            }
        }
    }
}

// MARK: - After an erase: what could not be removed

/// The launch after an erase. Shows, once, what the erase could not remove
/// (MacEraseNote, left in the fresh home), with Show in Finder, and logs it.
/// AppDelegate calls this once it has decided about onboarding; the note file
/// is thinned as it is read, so it is never shown twice.
enum EraseLeftoversFlow {
    @MainActor
    static func afterLaunch() {
        guard let note = MacEraseNote.take(from: Config.homeDir, onboarded: Onboarding.done) else { return }
        for line in note.leftovers {
            Log.write("erase: not removed — \(line.kind) \(line.target): \(line.sentence)")
        }
        if MacEraseNote.holdsDriverInstall(note, onboarded: Onboarding.done) {
            Log.write("erase: CuaDriver was removed; it is not installed again until setup is finished")
        }
        guard !note.leftovers.isEmpty else { return }
        Task { @MainActor in
            // After the onboarding window is up, so the note sits on top of it.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            DangerWindow.show(EraseLeftoversView(note: note, close: { DangerWindow.close() }), over: nil)
        }
    }
}

private struct EraseLeftoversView: View {
    let note: MacEraseNote
    let close: () -> Void

    var body: some View {
        DangerCard {
            DangerText(title: nil, body: note.text)
            if note.reveal.isEmpty {
                DangerButtons(cancel: nil, confirm: "OK", destructive: false) { close() }
            } else {
                DangerButtons(cancel: close, confirm: "Show in Finder", destructive: false, cancelLabel: "OK") {
                    NSWorkspace.shared.activateFileViewerSelecting(note.reveal)
                }
            }
        }
    }
}

// MARK: - Pieces

private struct PlanList: View {
    let plan: MacErasePlan?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let plan {
                    ForEach(Array(plan.remove.enumerated()), id: \.offset) { _, item in
                        Text("• " + Self.describe(item, home: plan.scope.userHome))
                    }
                    if !plan.left.isEmpty {
                        Text("Left alone").font(Theme.Typo.ui(12, weight: .semibold)).padding(.top, 6)
                        ForEach(Array(plan.left.enumerated()), id: \.offset) { _, line in Text("• " + line) }
                    }
                } else {
                    Text("Working out what's there…")
                }
            }
            .font(Theme.Typo.ui(11))
            .foregroundStyle(Theme.ink3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
    }

    static func describe(_ item: MacEraseItem, home: URL) -> String {
        let target = item.target.hasPrefix(home.path + "/")
            ? "~/" + item.target.dropFirst(home.path.count + 1) : item.target
        switch item {
        case .keychain: return "Keychain: \(target)"
        case .launchd: return "Background job: \(target)"
        case .defaults: return "Preferences: \(target)"
        case .tcc: return "Permissions for \(target)"
        case .loginItem: return "Login item: Alfie opening when you log in"
        case .process(_, let command):
            return "Stop: \((command as NSString).lastPathComponent), running from what is being erased"
        case .cuaDriverApp: return "CuaDriver, the tool Alfie uses to work your screen: \(target)"
        case .path, .legacyLink, .cuaDriverLink: return target
        }
    }
}

struct DangerCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) { content() }
            .padding(Theme.Space.section)
            .frame(width: 440)
            .background(Theme.paper)
    }
}

struct DangerText: View {
    let title: String?
    let body_: String
    var small = false

    init(title: String?, body: String, small: Bool = false) {
        self.title = title
        self.body_ = body
        self.small = small
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            if let title {
                Text(title).font(Theme.Typo.heading(22)).foregroundStyle(Theme.ink)
            }
            Text(body_)
                .font(small ? Theme.Typo.ui(12) : Theme.Typo.prose(14))
                .foregroundStyle(small ? Theme.ink3 : Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DeleteField: View {
    @Binding var text: String
    var body: some View {
        TextField("DELETE", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.Typo.ui(13, weight: .semibold))
            .autocorrectionDisabled()
            .frame(maxWidth: 200)
    }
}

// The destructive button ("Delete my account", "Erase this Mac") is a
// HumanOnlyButton (D9.14): a press no person made -- an accessibility press, a
// posted event -- runs nothing and asks the person to confirm it is them.
// Behind it are still the two warnings, typing DELETE where the account is
// included, and the Google / Touch ID proof; nothing erases before all of them.
struct DangerButtons: View {
    let cancel: (() -> Void)?
    let confirm: String
    let destructive: Bool
    var enabled = true
    var cancelLabel = "Cancel"
    let action: () -> Void

    private var confirmLabel: some View {
        Text(confirm)
            .font(Theme.Typo.ui(13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                    .fill(destructive ? Theme.bad : Theme.accent)
            )
            .opacity(enabled ? 1 : 0.4)
    }

    var body: some View {
        HStack(spacing: Theme.Space.cosy) {
            if let cancel {
                Button(action: cancel) {
                    Text(cancelLabel).font(Theme.Typo.ui(13, weight: .semibold)).foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if destructive {
                HumanOnlyButton(control: "danger-" + confirm.lowercased(), action: action) { confirmLabel }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                // Enter never erases: the destructive button has no default key.
            } else {
                Button(action: action) { confirmLabel }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, Theme.Space.small)
    }
}
