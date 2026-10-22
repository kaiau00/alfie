import AppKit
import MoeDesign
import SwiftUI

/// First launch. Seven screens, one action each, every one skippable and
/// every one reversible (eight while typing by voice is offered —
/// `Features.dictation`, off since docs/DEFAULTS.md row 4 — when screen 5
/// below is shown between 4 and 6):
///   1. Welcome — the four things Moe does, one line each (five with dictation)
///   2. Microphone — the one permission asked at launch (PRODUCT.md §8.4)
///   3. Something to think with — install the thinking part if it is
///      missing, then four ways in: a Claude plan and a ChatGPT plan
///      recommended equally (docs/DEFAULTS.md row 1), a key, this Mac
///   4. Say hello — the exact key to hold and the exact thing to say, and
///      Accessibility and Screen Recording, one button each (row 33)
///   5. Type what I say — dictation (only while `Features.dictation`)
///   6. Notes in meetings — what it records, where it stays, who is told
///   7. What may I read to learn about you — the sources as switches and
///      the daily pass, one answer, recommended on (LearnStep.swift, row 24)
///   8. Connect your world → Connections: the Mac's apps first, then
///      Google (row 34); start with the Mac, and problem reports (rows 28, 30)
///
/// Row 40: every new ask is folded into a screen that was already here —
/// the count stays seven.
///
/// The rule for every sentence here: it has to be understood by someone who
/// has never heard of a subscription plan, a permission or a key. One short
/// paragraph, then the button. Anything longer belongs in the pane the
/// button leads to, where there is room and a reason to read it.
///
/// The screens are drawn with the app's own design system (MoeDesign.Theme):
/// paper ground, serif display titles, serif prose, pill buttons. They used
/// to be stock SwiftUI, which meant the first thing a person saw of Moe
/// looked like nothing else in it.
///
/// The amber "nudge" glow is named on screen 8, and only because it works:
/// `scripts/install.sh` copies `moe-home/nudge.sh` into ~/.moe and
/// `moe-home/sync.sh` runs it at the end of every sync, so ~/.moe/nudge.json
/// can actually be written. It has an off switch in Settings › Background
/// (`Config.nudges`), which the screen says. If any of that is ever undone,
/// scripts/test-onboarding.sh fails rather than letting the promise stand.
///
/// Nothing here blocks. Every screen has Back and Skip, a declined permission
/// is explained rather than re-asked, and closing the window at any point
/// lands on the main window rather than on nothing.
enum Onboarding {
    // TODO(Config.swift, owned elsewhere): an `onboardingDone` key. Until
    // then a file marker in ~/.moe.
    static var marker: URL { Paths.home.appendingPathComponent(".onboarded") }
    static var done: Bool { FileManager.default.fileExists(atPath: marker.path) }
    static func markDone() {
        try? Data().write(to: marker)
        clearResume()
    }

    /// Where to pick up after a relaunch in the middle of the flow.
    ///
    /// The accessibility grant only takes effect when Moe starts again, so
    /// screen 4 quits and reopens Moe — and until 2026-09-07 that closed
    /// the window, the close marked onboarding done, and the reopened Moe
    /// went straight to the main window with three screens never shown.
    /// Now the relaunch writes the screen to come back to, the close that
    /// follows marks nothing, and the next launch reads this before it
    /// decides anything. Consumed on read, so a stale marker cannot pin a
    /// Mac to a screen it already passed.
    static var resumeMarker: URL { Paths.home.appendingPathComponent(".onboarding-resume") }
    static var resumeScreen: Screen? {
        guard let raw = try? String(contentsOf: resumeMarker, encoding: .utf8),
              let screen = Screen(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        // A marker from a build that still showed the dictation screen
        // lands on the screen after it, never on one that is not shown.
        return Screen.shown.contains(screen) ? screen : screen.next
    }
    static func markResume(at screen: Screen) {
        try? Data(screen.rawValue.utf8).write(to: resumeMarker)
    }
    static func clearResume() { try? FileManager.default.removeItem(at: resumeMarker) }

    // MARK: - Words the tests hold

    /// "Say hello" (docs/DEFAULTS.md row 33): one plain line each, why.
    static let accessibilityWhy = "So Alfie can hear the talk key in any app and click for you when you ask."
    static let screenRecordingWhy = "So Alfie can see your screen when you ask about it."
    /// The last screen's two rows (rows 30 and 28).
    static let launchAtLoginTitle = "Start Alfie when my Mac starts"
    static let problemReportsTitle = "Let Alfie send problem reports"

    /// The screens, in order — named here rather than only inside the view
    /// so `Moe --onboarding-json` can prove every one has a way past it
    /// (scripts/test-onboarding.sh).
    enum Screen: String, CaseIterable, Identifiable {
        case welcome, microphone, brain, tryIt, dictate, meetings, learn, connect
        var id: String { rawValue }

        /// The screens a person actually sees, in order. `dictate` is in
        /// the flow only while dictation is a feature (`Features.dictation`);
        /// everything that walks the flow — Back, Skip, the dots, the JSON
        /// dump, the snapshot — reads this, never `allCases`.
        static var shown: [Screen] {
            allCases.filter { $0 != .dictate || Features.dictation }
        }

        /// The screen after this one in the shown flow, or nil at the end.
        /// Defined for a hidden screen too, so a stale marker can move on.
        var next: Screen? {
            let after = Screen.allCases.drop { $0 != self }.dropFirst()
            return after.first { Screen.shown.contains($0) }
        }

        /// What the Skip link says here. Every screen has one: skipping is
        /// never a dead end, and the last one's is "Not now".
        var skipLabel: String { self == .connect ? "Not now" : "Skip" }

        /// One line, for the dump: what this screen is for.
        var purpose: String {
            switch self {
            case .welcome:    return Features.dictation ? "What Alfie does, all five of it." : "What Alfie does, all four of it."
            case .microphone: return "The microphone, and what Alfie does with it."
            case .brain:      return "Install the thinking part if it is missing, then choose whose account Alfie borrows — a Claude or ChatGPT plan, recommended equally."
            case .tryIt:      return "Hold the key, say hello, hear an answer — and allow Accessibility and Screen Recording, both skippable."
            case .dictate:    return "Hold the other key and your words land in whatever app you are in."
            case .meetings:   return "Alfie takes the notes, and everyone can see it is recording."
            case .learn:      return "What Alfie may read to learn about you: the sources as switches, and the daily pass, recommended on."
            case .connect:    return "The Mac's own apps first, then Google, then everything else — and whether Alfie starts with your Mac and may send problem reports."
            }
        }
    }

    /// For scripts/test-onboarding.sh: the screens with their skip paths,
    /// the four ways to give Moe a brain, and every provider's words.
    static func dumpJSON() -> String {
        let obj: [String: Any] = [
            "screens": Screen.shown.map {
                ["id": $0.rawValue, "purpose": $0.purpose, "skip": $0.skipLabel] as [String: Any]
            },
            // Where a relaunched Moe would pick the flow up, read from the
            // home the dump runs against — scripts/test-onboarding.sh
            // writes the marker and expects it back here.
            "resume": resumeScreen?.rawValue as Any,
            "paths": BrainPath.all.map(\.json),
            "providers": BrainGuide.all.map(\.json),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private let conductor: Conductor
    private var window: NSWindow?
    var onOpenConnections: (() -> Void)?
    /// Takes them to a Settings pane and closes onboarding — used by the
    /// brain screen's two "set it up yourself" paths.
    var onOpenSection: ((MainWindow.Section) -> Void)?
    var onFinished: (() -> Void)?
    /// The person reached the end of the welcome: Take me to Connections or
    /// Not now on the last screen. Before `onFinished`; never for a close
    /// part-way through, and never in a rehearsal or a snapshot.
    var onCompleted: (() -> Void)?
    /// Set by the accessibility screen's "Quit and reopen Moe": the close
    /// that follows is the relaunch, not the person finishing, and must
    /// not mark onboarding done.
    private var relaunching = false

    /// Tall enough for the brain screen with its install card — the tallest
    /// of the seven — without scrolling. Every screen is top-aligned.
    static let size = NSSize(width: 640, height: 640)

    init(conductor: Conductor) {
        self.conductor = conductor
    }

    func show(pose: OnboardingView.Pose? = nil) {
        let view = OnboardingView(conductor: conductor,
                                  openConnections: { [weak self] in self?.onOpenConnections?() },
                                  openSection: { [weak self] in self?.onOpenSection?($0) },
                                  finish: { [weak self] in self?.close() },
                                  completed: { [weak self] in self?.onCompleted?() },
                                  relaunch: { [weak self] in self?.relaunch(resumingAt: $0) },
                                  pose: pose)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Welcome to Alfie"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.setContentSize(Self.size)
        w.center()
        w.isReleasedWhenClosed = false
        // An ordinary window, not a floating one. The Claude sign-in opens a
        // browser page the person has to read, and a floating 640-point
        // window sat on top of it.
        w.level = .normal
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
    }

    /// Quit and reopen, and come back to `screen`. The marker goes down
    /// before the relaunch starts, so a Moe that dies on the way still
    /// resumes.
    private func relaunch(resumingAt screen: Onboarding.Screen) {
        relaunching = true
        Onboarding.markResume(at: screen)
        Log.write("onboarding: relaunching for a permission; resuming at \(screen.rawValue)")
        Relaunch.now()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if relaunching { return }
        onFinished?()
    }
}

/// True only while `ImageRenderer` is drawing a screen for
/// `Moe --onboarding-snapshot`: a macOS `ScrollView` rasterises empty, so
/// the snapshot lays the same content over a plain stack instead.
private struct OnboardingSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onboardingSnapshot: Bool {
        get { self[OnboardingSnapshotKey.self] }
        set { self[OnboardingSnapshotKey.self] = newValue }
    }
}

struct OnboardingView: View {
    @ObservedObject var conductor: Conductor
    var openConnections: () -> Void
    var openSection: (MainWindow.Section) -> Void
    var finish: () -> Void
    /// Called just before `finish` when the last screen is left forward —
    /// the welcome finished, not abandoned (the login item, row 30).
    var completed: () -> Void

    /// Everything a screen's look depends on that is otherwise read from the
    /// machine — so `Moe --onboarding-snapshot` can pose each state without
    /// changing a permission or installing anything. The app passes nothing
    /// and reads the real answers.
    @MainActor
    struct Pose {
        var step: Onboarding.Screen = .welcome
        var micAsked = false
        var micDenied = false
        var signedIn = false
        var bootstrapDone = Bootstrap.hermesInstalled()
        var claudeReady = ClaudeSignIn.claudePath() != nil
        var accessibility = PushToTalk.hasAccessibility
        /// Screen Recording, asked on "Say hello" (docs/DEFAULTS.md row 33).
        var screenRecording = ScreenPermission.granted
        var installing = false
        var installLine = ""
        /// The bundled Hermes is being laid down (SeedInstall). Posed for a
        /// snapshot; the app reads it from `SeedInstall.shared`.
        var seeding = false
        /// `Moe --onboarding-rehearsal`: every real side effect — the
        /// permission prompts, the download, the sign-in, the Terminal, the
        /// relaunch — is replaced by a timed fake, so a person can walk the
        /// whole flow on their own Mac and see exactly what a stranger sees
        /// without any of it happening. The app never sets this.
        var rehearsal = false
        /// The learn screen's rows, posed: a snapshot or a rehearsal shows
        /// these instead of asking consent.sh what is connected.
        var learnSources: [BackgroundLearning.Source]?
        init() {}

        /// A fresh Mac: nothing granted, nothing installed.
        static var freshMac: Pose {
            var p = Pose()
            p.bootstrapDone = false
            p.seeding = true
            p.claudeReady = false
            p.accessibility = false
            p.screenRecording = false
            p.rehearsal = true
            p.learnSources = posedLearnSources
            return p
        }
    }

    /// Three of the Mac's own sources, as `consent.sh list` would report
    /// them on a Mac that has them: the labels are the manifests' own and
    /// the sentences are learn/consent_list.py's DESCRIBE table, verbatim —
    /// scripts/test-onboarding-learn.sh holds each against that file, so a
    /// picture of this screen can never say something the real one does not.
    static var posedLearnSources: [BackgroundLearning.Source] {
        [
            .init(name: "imessage", state: .unset, connected: true, label: "Messages (iMessage + SMS)",
                  reads: "your iMessage and SMS conversations: who wrote, when, and the full text"),
            .init(name: "calendar", state: .unset, connected: true, label: "Calendar",
                  reads: "your calendar events: titles, times, locations, attendees, and the invite's notes (its agenda, dial-in and any questions)"),
            .init(name: "notes", state: .unset, connected: true, label: "Apple Notes",
                  reads: "your Apple Notes: titles and full text of notes changed in the window"),
        ]
    }

    private typealias Step = Onboarding.Screen
    @State private var step: Step
    @State private var micAsked: Bool
    @State private var micDenied: Bool
    @State private var showSignIn = false
    @State private var signedIn: Bool
    @State private var brainNote = ""
    @State private var bootstrapDone: Bool
    @State private var claudeReady: Bool
    @State private var installing: Bool
    @State private var installLine: String
    @State private var accessibility: Bool
    @State private var accessibilityAsked = false
    @State private var screenRecording: Bool
    @State private var screenAsked = false
    /// The last screen's two rows. Launch at login starts where the config
    /// has it (on — registered when the welcome is finished, row 30);
    /// problem reports where privacy.json has it (off).
    @State private var launchAtLogin: Bool
    @State private var reportsOn: Bool
    @State private var reportsWorking = false
    @State private var reportsNote = ""
    @State private var showReportsDetail = false
    @State private var rehearsalMode: Conductor.Mode = .idle
    @State private var posedSeeding: Bool
    @ObservedObject private var seed = SeedInstall.shared
    @ObservedObject private var ax = AccessibilityWatch.shared
    @StateObject private var flow = ClaudeSignInFlow()
    @StateObject private var chatgptFlow = ChatGPTSignInFlow()
    @StateObject private var learn: LearnStepModel
    @State private var showChatGPT = false
    @Environment(\.onboardingSnapshot) private var snapshot
    private let rehearsal: Bool

    /// Quit and reopen Moe for a permission that only takes effect at
    /// launch, coming back to the given screen.
    private let relaunch: (Onboarding.Screen) -> Void

    @MainActor
    init(conductor: Conductor,
         openConnections: @escaping () -> Void,
         openSection: @escaping (MainWindow.Section) -> Void,
         finish: @escaping () -> Void,
         completed: @escaping () -> Void = {},
         relaunch: @escaping (Onboarding.Screen) -> Void = { _ in },
         pose: Pose? = nil) {
        let pose = pose ?? Pose()
        self.conductor = conductor
        self.openConnections = openConnections
        self.openSection = openSection
        self.finish = finish
        self.completed = completed
        self.relaunch = relaunch
        _step = State(initialValue: pose.step)
        _micAsked = State(initialValue: pose.micAsked)
        _micDenied = State(initialValue: pose.micDenied)
        _signedIn = State(initialValue: pose.signedIn)
        _bootstrapDone = State(initialValue: pose.bootstrapDone)
        _claudeReady = State(initialValue: pose.claudeReady)
        _installing = State(initialValue: pose.installing)
        _installLine = State(initialValue: pose.installLine)
        _accessibility = State(initialValue: pose.accessibility)
        _screenRecording = State(initialValue: pose.screenRecording)
        _launchAtLogin = State(initialValue: conductor.config.launchAtLogin)
        _reportsOn = State(initialValue: pose.rehearsal ? false : (Cloud.link.problemReports?.isOn() ?? false))
        _posedSeeding = State(initialValue: pose.seeding)
        _learn = StateObject(wrappedValue: LearnStepModel(posed: pose.learnSources, recommend: true))
        rehearsal = pose.rehearsal
    }

    /// The bundled Hermes is on its way into ~/.hermes right now. Real in
    /// the app (SeedInstall, started at launch), posed in a snapshot or a
    /// rehearsal.
    private var seeding: Bool {
        if snapshot || rehearsal { return posedSeeding }
        return seed.phase == .running
    }

    /// Runs `body` after `seconds`, on the main actor. The rehearsal's fakes
    /// are all shaped like this: a pause about as long as the real thing
    /// takes, then the state the real thing would leave behind.
    private func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { body() }
    }

    /// The shortcut, as configured. It is a *toggle* (AppDelegate.registerHotKey
    /// hands it to Conductor.toggle), not a hold — the screen used to tell
    /// people to hold it and let go, which is a different key entirely.
    private var shortcut: String {
        HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)
    }

    /// The hold key as configured (`Config.talkKey`, right ⌥ to start with),
    /// which is exactly what PushToTalk.isCleanPress tests for.
    private var holdKey: String { conductor.config.talkKey.inSentence }

    private var dictationKey: String { conductor.effectiveDictationKey.displayName }

    var body: some View {
        VStack(spacing: 0) {
            if snapshot {
                screen.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) { screen }
            }
            footer
        }
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
        .background(Theme.paper)
        .sheet(isPresented: $showSignIn) {
            ClaudeSignInSheet(flow: flow) { ok in
                showSignIn = false
                signedIn = ok
                if ok { step = .tryIt }
            }
        }
        .onAppear {
            flow.rehearsal = rehearsal
            flow.onStored = { if !rehearsal { conductor.restartBrain() } }
        }
        .onChange(of: conductor.turns.count) { _, _ in
            // They actually said something: that screen is done, move on.
            guard step == .tryIt else { return }
            if conductor.turns.contains(where: { $0.role == .you }), let next = step.next { step = next }
        }
        // Coming back from System Settings: the grant may have changed.
        .onChange(of: step) { _, _ in
            if !snapshot { accessibility = PushToTalk.hasAccessibility }
            if !snapshot, !rehearsal { screenRecording = ScreenPermission.granted }
        }
        // …and while this screen is up: the card goes the moment it is on.
        .onChange(of: ax.granted) { _, now in if !snapshot, !rehearsal { accessibility = now } }
    }

    private var screen: some View {
        Group {
            switch step {
            case .welcome:    welcome
            case .microphone: microphone
            case .brain:      brain
            case .tryIt:      tryIt
            case .dictate:    dictate
            case .meetings:   meetings
            case .learn:      learnScreen
            case .connect:    connect
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.generous)
        .padding(.top, Theme.Space.generous + Theme.Space.small)
        .padding(.bottom, Theme.Space.cosy)
    }

    // MARK: - 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Hi, I'm Alfie.")
            prose("I live in the little pill at the top of your screen. Here is what I can do.")
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                bullet("bubble.left.and.bubble.right", "Answer out loud.", "Hold a key, ask, let go.")
                if Features.dictation {
                    bullet("text.cursor", "Type what you say.", "In any app, right where your cursor is.")
                }
                bullet("waveform.circle", "Take meeting notes.", "Both sides of the call, kept on this Mac.")
                bullet("brain", "Remember you.", "In plain writing you can read and change.")
                bullet("link", "Reach your things.", "Mail, calendar, files, apps — only what you connect.")
            }
            // You are early, said once, on the first screen — warmly, and
            // not again on the other six. A person who has just opened an
            // app has not earned a warning; what they have earned is
            // knowing where they stand and what to do when it wobbles.
            prose("One thing first: I'm in beta. You'll meet bugs and rough corners — and when you do, just tell me, out loud or in writing. It reaches the one person building me, and it is the most useful thing you can do.")
            small("\(Step.shown.count - 1 == 7 ? "Seven" : "Six") short steps. Skip any of them — nothing here is permanent.")
            primary("Let's go") { step = .microphone }
        }
    }

    // MARK: - 2. Microphone

    private var microphone: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Can I hear you?")
            prose("I listen only while you hold the talk key. Your voice is turned into words here on this Mac and is never sent anywhere.")
            if micDenied {
                card {
                    PermissionExplainer(guide: .microphone,
                                        lead: "You said no — that's fine, and Alfie still works.",
                                        showWhat: false)
                }
                primary("Next") { step = .brain }
            } else if micAsked {
                done("The microphone is on.")
                primary("Next") { step = .brain }
            } else {
                small("macOS will ask you to confirm.")
                primary("Turn on the microphone") {
                    if rehearsal {
                        // Stands in for the macOS prompt: a beat, then yes.
                        later(1.2) { micAsked = true; step = .brain }
                        return
                    }
                    Task {
                        let ok = await VoiceEngine.requestMicrophone()
                        micAsked = true
                        micDenied = !ok
                        if ok { step = .brain }
                    }
                }
            }
        }
    }

    // MARK: - 3. Something to think with

    /// Four rows, not eleven: the question a person can answer is "what do
    /// you already pay for?" (BrainPath). A Claude plan and a ChatGPT plan
    /// are the recommendation, equally (docs/DEFAULTS.md row 1): the first
    /// two rows, both badged, both filled buttons. Keys and local models
    /// sit below them.
    private var brain: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Give me something to think with")
            prose("Alfie costs you nothing and has no account of its own. Pick the one you already use — the account, and any bill, stay with them.")

            // Before any of the four paths can work, the part that runs them
            // has to exist. On a Mac that only downloaded Moe it does not —
            // so that is the whole screen until it does. One thing at a time:
            // four dimmed choices under an install button read as five things
            // to do, and did not fit the window.
            if !bootstrapDone, seeding {
                // A downloaded copy: the thinking part ships inside the app
                // and is being copied out since launch. Nothing to press.
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Getting ready")
                        cardText("Setting up the part of me that thinks. It's already inside the app, so nothing is downloaded — this takes a few seconds. Then you'll pick whose account I borrow.")
                        progressLine("Almost there…")
                    }
                }
            } else if !bootstrapDone {
                // No seed in this build, or it failed: the network installer,
                // behind one button, with the honest size.
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("One thing first")
                        cardText("The part of me that does the thinking isn't on this Mac yet. Alfie can download it — about a gigabyte, once — and you don't have to do anything while it runs. Then you'll pick whose account I borrow.")
                        if installing {
                            progressLine(installLine)
                        } else {
                            HStack(spacing: Theme.Space.base) {
                                PillButton(title: "Set it up", action: runBootstrap)
                                if !installLine.isEmpty { progressText(installLine) }
                            }
                        }
                    }
                }
            } else if signedIn {
                // The choice is made: the four cards would only be a list of
                // things not chosen, and with the confirmation and the
                // button they did not fit the window.
                done("Signed in with Claude. " + capabilityLine)
                small("Change this any time in Settings › Brain.")
                primary("Next") { step = .tryIt }
            } else {
            VStack(spacing: Theme.Space.small) {
                pathRow(.claude, filled: true) {
                    if claudeReady {
                        showSignIn = true
                    } else if rehearsal {
                        installing = true
                        installLine = "Getting the sign-in tool…"
                        later(1.5) { installLine = "✓ Claude Code installed" }
                        later(2.5) { installing = false; claudeReady = true; showSignIn = true }
                    } else {
                        // Signing in needs the tool that does the signing.
                        // Moe fetches it here, at the moment it is chosen.
                        installing = true
                        installLine = "Getting the sign-in tool…"
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = Bootstrap.installClaudeCLI { line in
                                DispatchQueue.main.async { installLine = line }
                            }
                            DispatchQueue.main.async {
                                installing = false
                                claudeReady = ClaudeSignIn.claudePath() != nil
                                if ok && claudeReady { showSignIn = true }
                            }
                        }
                    }
                }
                pathRow(.chatgpt, filled: true) {
                    // In the app, not in Terminal: the sheet shows the code
                    // and the link, and opens the page itself.
                    chatgptFlow.rehearsal = rehearsal
                    // Signing in is choosing: the old Terminal flow ended on
                    // "back in Moe, choose ChatGPT and press Apply", a step
                    // onboarding never showed anyone.
                    chatgptFlow.onStored = {
                        Task {
                            let (written, sel) = await Task.detached(priority: .userInitiated) {
                                // A model this account offers, not a guess.
                                let sel = BrainSelection(provider: .codex,
                                                         model: BrainSetup.startingModel(for: .codex),
                                                         reasoningEffort: "")
                                return (BrainSetup.apply(sel, baseURL: "", key: nil), sel)
                            }.value
                            if case .failure(let f) = written { brainNote = f.message; return }
                            conductor.applyBrain(sel, baseURL: "", polishModel: "", restartGateway: true)
                        }
                    }
                    showChatGPT = true
                }
                .sheet(isPresented: $showChatGPT) {
                    ChatGPTSignInSheet(flow: chatgptFlow) { ok in
                        showChatGPT = false
                        if ok { brainNote = "Signed in with ChatGPT. " + capabilityLine }
                    }
                }
                pathRow(.key, filled: false) { leaveForBrainPane() }
                pathRow(.onThisMac, filled: false) { leaveForBrainPane() }
            }
            .disabled(installing)
            .opacity(installing ? 0.45 : 1)

            if installing {
                progressLine(installLine)
            } else if !brainNote.isEmpty {
                progressText(brainNote)
            }

            small(Features.dictation
                  ? "Not sure? Skip it. Dictation still types what you say and meetings still get their notes. Only answering a question needs this — Settings › Brain, whenever you like."
                  : "Not sure? Skip it. Meetings still get their notes. Only answering a question needs this — Settings › Brain, whenever you like.")
            }
        }
        // The answer changes underneath this screen: the user may have set it
        // up from Settings, or come back after an install finished.
        .onAppear(perform: refreshBootstrap)
        // The seed landed while this screen was up: the card gives way to
        // the four choices without anyone pressing anything.
        .onChange(of: seed.phase) { _, phase in
            if phase == .done, !snapshot, !rehearsal { bootstrapDone = Bootstrap.hermesInstalled() }
        }
    }

    /// Whether the Python side is on this Mac yet. Checked when the screen
    /// appears rather than held in a config value, because the answer changes
    /// underneath us. Not in a snapshot, which is posing a state on purpose.
    private func refreshBootstrap() {
        guard !snapshot else { return }
        if rehearsal {
            // A downloaded copy's first launch: the seed lands a few seconds
            // after the screen is reached, and the choices appear.
            if !bootstrapDone, posedSeeding {
                later(4.0) { posedSeeding = false; bootstrapDone = true }
            }
            return
        }
        bootstrapDone = Bootstrap.hermesInstalled()
        claudeReady = ClaudeSignIn.claudePath() != nil
    }

    /// Runs the installer the app carries, streaming its own ✓/✗ lines.
    /// Off the main thread: it is a download of about a gigabyte, and the
    /// window has to keep drawing. Skip stays on the screen throughout.
    private func runBootstrap() {
        installing = true
        installLine = "Starting…"
        if rehearsal {
            // The real thing prints these lines over about ninety seconds.
            let script = ["› Setting up the part of Alfie that thinks. This takes a minute or two.",
                          "✓ uv 0.12.7 installed (sha256 verified)",
                          "✓ Python installed: Python 3.14",
                          "✓ hermes-agent cloned",
                          "✓ venv synced: 212 packages",
                          "✓ Ready. Now choose how Alfie should think."]
            for (i, line) in script.enumerated() { later(Double(i) * 0.9) { installLine = line } }
            later(Double(script.count) * 0.9) { installing = false; bootstrapDone = true; installLine = "" }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Bootstrap.installHermes { line in
                DispatchQueue.main.async { installLine = line }
            }
            DispatchQueue.main.async {
                installing = false
                bootstrapDone = ok || Bootstrap.hermesInstalled()
                if bootstrapDone { installLine = "" }
            }
        }
    }

    /// What the chosen provider's own default model can and can't do, from
    /// the capability table rather than from an assumption that they are all
    /// the same (BrainCapabilityTable.lookup).
    private var capabilityLine: String {
        let cfg = conductor.config
        if let cost = BrainGuide.capabilityCost(provider: cfg.brainProvider, model: cfg.brainModel) {
            return cost
        }
        return "I can see your screen when you ask, and use everything you connect."
    }

    private func pathRow(_ path: BrainPath, filled: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.cosy) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.small) {
                    Text(path.title)
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if path.recommended {
                        Text("Recommended")
                            .font(Theme.Typo.label(9))
                            .tracking(Theme.tracking)
                            .foregroundStyle(Theme.accentDeep)
                            .padding(.horizontal, Theme.Space.small)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentTint))
                    }
                }
                Text(path.whatItIs)
                    .font(Theme.Typo.prose(13))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.base)
            // The two recommendations are the filled buttons on the screen —
            // that, the badge, and being first, is the whole of "recommended".
            if filled {
                PillButton(title: path.action, action: action)
            } else {
                PaneButton(title: path.action, action: action)
            }
        }
        .padding(Theme.Space.cosy)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(filled ? Theme.accent.opacity(0.5) : Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
        )
    }

    // MARK: - 4. Say hello

    /// True when a question asked right now would get an answer: the
    /// thinking part is installed, and — for the Claude path — a sign-in is
    /// stored. Anything else is told on the screen rather than discovered as
    /// a failed first question.
    private var brainReady: Bool {
        guard bootstrapDone else { return false }
        if conductor.config.brainProvider == .claudeCode {
            return signedIn || (!snapshot && HermesKey.childOAuthTokenExists())
        }
        return true
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Say hello")
            prose("Hold \(holdKey) — \(conductor.config.talkKey.whereItIs) — say “what can you do?”, and let go. I answer out loud.")
            small("Or double-tap that key and just talk, nothing held — tap it again to send. Double-tap while I'm talking or working to stop me. \(shortcut) starts and stops me too.")

            if !brainReady {
                note("I can hear you, but nothing is thinking for me yet, so I can't answer. Go back a step, or set it up later in Settings › Brain.")
            }

            if !accessibility {
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Accessibility")
                        cardText(Onboarding.accessibilityWhy)
                        small("No rush — \(shortcut) and the button below work right now. Skip it and nothing breaks.")
                        if accessibilityAsked {
                            cardText("Switched it on? Quit and reopen Alfie so it takes effect.")
                            HStack(spacing: Theme.Space.base) {
                                PillButton(title: "Quit and reopen Alfie") {
                                    // In rehearsal the relaunch is the grant taking effect.
                                    // Back on this screen afterwards: the
                                    // grant is now in force and the key
                                    // can be tried; Skip is still here.
                                    if rehearsal { accessibility = true } else { relaunch(.tryIt) }
                                }
                                PaneButton(title: "Open Accessibility settings") {
                                    if !rehearsal { openPane(.accessibility) }
                                }
                            }
                            // Came back from the relaunch and it is still off.
                            // Most often Moe is ON in System Settings — an
                            // entry left by an earlier copy, signed
                            // differently, that macOS shows and refuses. The
                            // owner met exactly this on 2026-09-10 and had no
                            // way out but a terminal.
                            if !rehearsal, !snapshot, ax.staleSuspected {
                                cardText("Already switched on, and still not working? macOS is remembering an older copy of Alfie. Reset clears it — then switch Alfie on once more.")
                                PaneButton(title: "Reset and ask again") { ax.fix() }
                            }
                        } else {
                            PillButton(title: "Allow it") {
                                accessibilityAsked = true
                                // The system prompt adds Moe to the list and
                                // offers to open the pane itself — one click,
                                // no "+". macOS shows it once; if it was
                                // declined before, the button that opens the
                                // pane is on the next line.
                                if !rehearsal { PushToTalk.requestAccessibility() }
                            }
                        }
                    }
                }
            }

            // docs/DEFAULTS.md row 33: asked here, not on first use, so a
            // first "what's on my screen?" does not fail. One button, the
            // same ask-then-open-the-list path Settings › Permissions takes
            // (ScreenPermission.allow). Skippable; nothing waits on it.
            if !screenRecording {
                card {
                    VStack(alignment: .leading, spacing: Theme.Space.small) {
                        cardTitle("Screen Recording")
                        cardText(Onboarding.screenRecordingWhy)
                        if screenAsked {
                            cardText("Switched it on? It takes effect the next time Alfie opens. Rather not? Skip it — Alfie asks again the first time you want it to look.")
                            PaneButton(title: "Open Screen Recording settings") {
                                if !rehearsal { ScreenPermission.openSettings() }
                            }
                        } else {
                            PillButton(title: "Allow it") {
                                screenAsked = true
                                if rehearsal { screenRecording = true; return }
                                // Asking is what puts Moe on the list at all.
                                // Only ask: CGRequestScreenCaptureAccess
                                // returns false while its own first-time
                                // alert is still on screen, and opening
                                // System Settings on that answer put the list
                                // on top of the alert. After a refusal the
                                // ask shows nothing — the card now offers
                                // the list, one press away.
                                if ScreenPermission.request() { screenRecording = true }
                            }
                        }
                    }
                }
            }

            HStack(spacing: Theme.Space.cosy) {
                primary("Talk to me") {
                    if rehearsal {
                        // Listen, think, answer, move on — the shape of a
                        // real first exchange, with nobody talking.
                        rehearsalMode = .listening
                        later(2.5) { rehearsalMode = .thinking }
                        later(4.0) { rehearsalMode = .speaking }
                        later(6.0) { rehearsalMode = .idle; if let next = step.next { step = next } }
                    } else {
                        conductor.toggle()
                    }
                }
                // A spinner that is always spinning tells you nothing. This
                // one runs only while Moe is actually doing something.
                if mode != .idle {
                    progressLine(listeningLine).padding(.top, Theme.Space.tight)
                }
            }
        }
    }

    private var mode: Conductor.Mode { rehearsal ? rehearsalMode : conductor.mode }

    private var listeningLine: String {
        switch mode {
        case .listening: return "I'm listening — say anything."
        case .thinking:  return "Thinking…"
        case .speaking:  return "Answering…"
        case .idle:      return ""
        }
    }

    private func openPane(_ guide: PermissionGuide) {
        if let url = guide.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// A key or a local model is set up in Settings › Brain, which has the
    /// fields; onboarding closes and that pane opens. In rehearsal there is
    /// no main window to open, so it says what would have happened.
    private func leaveForBrainPane() {
        if rehearsal {
            brainNote = "Rehearsal: this closes onboarding and opens Settings › Brain, where the key or the address goes."
            return
        }
        openSection(.brain)
        finish()
    }

    // MARK: - 5. Dictation

    /// Shown only while `Features.dictation` (docs/DEFAULTS.md row 4); kept
    /// whole for when it comes back. On by default then
    /// (Config.dictationEnabled), a different key from the talk key on
    /// purpose, and it needs the same Accessibility grant to put the words
    /// where the cursor is (TextInserter.insert).
    private var dictate: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("I'll type what you say")
            prose("Hold \(dictationKey) in any app, say your sentence, and let go. The words appear where your cursor is — tidied up, ums taken out, and I never answer them.")
            small("Double-tap the key to keep listening with nothing held down. Escape stops.")
            if conductor.config.dictationPolish {
                small("The last bit of tidying asks your AI to read the sentence. Turn that off in Settings › Voice if you'd rather nothing you dictate leaves this Mac.")
            }
            HStack(spacing: Theme.Space.base) {
                Text("Key to hold")
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if snapshot {
                    // An AppKit menu does not rasterise; the snapshot draws
                    // the value the way the menu's label draws it.
                    Text(conductor.config.dictationKey.displayName)
                        .font(Theme.Typo.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                } else {
                    SettingMenu(value: conductor.config.dictationKey.displayName) {
                        Picker("", selection: Binding(
                            get: { conductor.config.dictationKey },
                            set: { conductor.setDictationKey($0) })) {
                                ForEach(DictationKey.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().pickerStyle(.inline)
                    }
                }
            }
            if !accessibility {
                note("Until you allow Accessibility (the step before this one), I can't put the words in for you. They go to your clipboard instead — press ⌘V.")
            }
            primary("Got it") { step = .meetings }
        }
    }

    // MARK: - 6. Meetings

    /// Checked against Sources/MoeMeeting: the consent sheet
    /// (AppDelegate.confirmMeeting, on by default via
    /// Config.meetingAskBeforeStart), the red ring (IslandView.meetingRing),
    /// the two audio streams (MicCapture and ProcessTap), the folder
    /// (Paths.meetings) and the audio deletion default
    /// (Config.meetingDeleteRecordings).
    private var meetings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("I'll take the notes")
            prose("Start a meeting from the Meetings tab. I hear both sides of the call, and when you stop I write the notes and the action items.")
            prose("It all stays on this Mac. I ask before I start, and the ring around the notch stays red the whole time — so tell the room.")
            HStack(spacing: Theme.Space.base) {
                if snapshot {
                    // An AppKit switch does not rasterise; a snapshot draws
                    // the off state it is in by default.
                    Capsule().fill(Theme.ruleStrong).frame(width: 26, height: 15)
                        .overlay(alignment: .leading) {
                            Circle().fill(Theme.raised).frame(width: 13, height: 13).padding(1)
                        }
                } else {
                    Toggle("", isOn: Binding(
                        get: { conductor.config.meetingHotkey },
                        set: { conductor.setMeetingHotkey($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start and stop a meeting with ⌃⌥M")
                        .font(Theme.Typo.ui(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("Off unless you switch it on — a key that records other people should be your choice.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            primary("Next") { step = .learn }
        }
    }

    // MARK: - 7. What may I read to learn about you

    /// The front door to the daily pass. The switches, the sentence and the
    /// writer are LearnStep.swift's; this screen is the chrome around them.
    /// Next records what was ticked and moves on; Skip (the footer) records
    /// nothing at all — see BackgroundLearning.stepWrites.
    private var learnScreen: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title(LearnStepCopy.title)
            prose(LearnStepCopy.lead)
            LearnStepBody(model: learn, snapshot: snapshot)
            small(LearnStepCopy.detail)
            primary(learn.hasChoice ? LearnStepCopy.save : LearnStepCopy.next) {
                if rehearsal || snapshot { step = .connect; return }
                Task {
                    // Wait for the file: the sheet that asks about the pass
                    // reads it two seconds after onboarding closes, and a
                    // write still in flight would read as "never asked".
                    if await learn.save() { step = .connect }
                }
            }
            .disabled(learn.saving)
        }
        .onAppear { learn.load() }
    }

    // MARK: - 8. Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            title("Connect your world")
            // Two screens now, and this used to promise both on one. It sent
            // people to Connections saying "messages", and the messaging apps
            // had moved to the screen below it — the only automatic way into
            // this part of the app, landing one row short of what it named.
            prose("Mail, files, the apps you work in — one button each on the next screen. Beside it, Message Alfie: set up Telegram or WhatsApp and you can text me from your phone. Nothing is connected until you say so, and before I send anything for you I show you the words and wait for a yes.")
            // docs/DEFAULTS.md row 34 (slice 13): what to connect first, in
            // the order the Connections list now draws it
            // (ConnectionsCatalog.firstMac, then firstGoogle).
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                bullet("desktopcomputer", "Start with this Mac.",
                       ConnectionsCatalog.firstMacWords + " — the apps already here. macOS asks you once for each.")
                bullet("envelope", "Then Google.",
                       ConnectionsCatalog.firstGoogleWords + " — one sign-in covers all three.")
                bullet("ellipsis.circle", "Then anything else.",
                       "Messages and hundreds more are in the list under them.")
            }
            prose("When there's something worth knowing — a meeting soon, a message from someone you know — I glow amber. Tap the glow and I'll tell you. Settings › Background switches the nudge off.")
            small("What I remember about you is in the Memory tab, in plain writing. Change a line, or throw the lot out. And all of this runs on this Mac: while it sleeps, I sleep.")
            // Rows 30 and 28, folded into this screen (row 40). Above the
            // button, not under it: the button closes the welcome, so rows
            // drawn below it were rows most people never saw.
            Rectangle().fill(Theme.rule).frame(height: 1)
            switchRow(title: Onboarding.launchAtLoginTitle,
                      detail: "On, so I'm here under the notch when you sign in. System Settings › General › Login Items has the same switch.",
                      isOn: Binding(get: { launchAtLogin }, set: { on in
                          launchAtLogin = on
                          // The rehearsal and the snapshot touch no login item.
                          if !rehearsal, !snapshot { conductor.setLaunchAtLogin(on) }
                      }))
            problemReportsRow
            primary("Take me to Connections") {
                openConnections()
                completeWelcome()
                finish()
            }
        }
    }

    /// "Let Moe send problem reports": off, and the switch is the real one —
    /// the same call Settings › Privacy makes, which records the yes with the
    /// Moe team on a signed-in Mac and fails closed when it cannot. Reports
    /// go to Memoe's cloud, so a build without one has no row.
    @ViewBuilder
    private var problemReportsRow: some View {
        if let reports = Cloud.link.problemReports {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            switchRow(title: Onboarding.problemReportsTitle,
                      detail: "Off unless you switch it on. When something breaks and you ask me to report it, this is what lets the report reach the one person building me.",
                      isOn: Binding(get: { reportsOn }, set: { setReports($0) }),
                      enabled: !reportsWorking,
                      control: "onboarding-problem-reports")
            Button(action: { showReportsDetail.toggle() }) {
                Text(reportsDetailLabel)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.accentDeep)
            }
            .buttonStyle(.plain)
            if showReportsDetail {
                // The audited text, one copy, shared with Settings › Privacy.
                small(reports.disclosure)
            }
            switchRow(title: reports.anonymousTitle,
                      detail: reports.anonymousDetail,
                      isOn: reports.anonymousBinding(conductor, posed: rehearsal || snapshot))
            if !reportsNote.isEmpty { note(reportsNote) }
        }
        }
    }

    private var reportsDetailLabel: String {
        showReportsDetail ? "Hide what is sent" : (Cloud.link.problemReports?.disclosureLabel ?? "")
    }

    private func setReports(_ on: Bool) {
        guard !reportsWorking else { return }
        if rehearsal || snapshot { reportsOn = on; return }
        guard let reports = Cloud.link.problemReports else { return }
        reportsWorking = true
        reportsNote = ""
        Task {
            let outcome = await reports.turn(on, conductor: conductor)
            reportsOn = outcome.on
            reportsWorking = false
            reportsNote = outcome.problem ?? ""
        }
    }

    /// A switch with its title and one line under it. An AppKit switch does
    /// not rasterise, so a snapshot draws a still one in its state.
    /// `control` makes it a switch only a person can flip — the same
    /// `HumanLever` Settings › Privacy uses for the same setting, so an
    /// accessibility press or a posted event cannot turn problem reports on
    /// here either. A rehearsal records nothing, so it keeps a plain switch.
    private func switchRow(title: String, detail: String, isOn: Binding<Bool>,
                           enabled: Bool = true, control: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            Group {
                if snapshot {
                    Capsule().fill(isOn.wrappedValue ? Theme.accent : Theme.ruleStrong)
                        .frame(width: 26, height: 15)
                        .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                            Circle().fill(Theme.raised).frame(width: 13, height: 13).padding(1)
                        }
                } else if let control, !rehearsal {
                    HumanLever(control: control, value: isOn, enabled: enabled)
                } else {
                    Toggle("", isOn: isOn)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                        .disabled(!enabled)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    // MARK: - Chrome

    /// Back and Skip on every screen, and the dots. Nobody is ever stuck.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: Theme.Space.base) {
                Button("Back") { back() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .disabled(step == .welcome)
                    .opacity(step == .welcome ? 0 : 1)
                Spacer()
                dots
                Spacer()
                Button(step.skipLabel) { skip() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
        }
        .background(Theme.sidebar)
    }

    /// The last screen's way out — Take me to Connections, or Not now. Tells
    /// the window the welcome was finished (the login item, row 30). Not for
    /// the brain screen's early exit, and never in a rehearsal or snapshot.
    private func completeWelcome() {
        guard !rehearsal, !snapshot else { return }
        completed()
    }

    private func back() {
        guard let i = Step.shown.firstIndex(of: step), i > 0 else { return }
        step = Step.shown[i - 1]
    }

    private func skip() {
        if step == .learn {
            // Skipped, not refused: nothing recorded, and the rows it
            // showed are asked about again in a week (LearnStepModel).
            learn.markShownOff(all: true)
        }
        guard let i = Step.shown.firstIndex(of: step), i + 1 < Step.shown.count else {
            if step == .connect { completeWelcome() }
            finish(); return
        }
        step = Step.shown[i + 1]
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.display(30))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.prose(15))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    /// Something the person should know before pressing the button: shown
    /// in the warn colour, never as a blocker.
    private func note(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warn)
            Text(text)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Theme.measure, alignment: .leading)
    }

    private func done(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.good)
            Text(text)
                .font(Theme.Typo.ui(13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: Theme.Space.small) {
            if snapshot {
                // A spinner does not rasterise; the snapshot draws a still one.
                Circle().stroke(Theme.ink3, lineWidth: 1.5).frame(width: 12, height: 12)
            } else {
                ProgressView().controlSize(.small)
            }
            progressText(text)
        }
    }

    private func progressText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(12))
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(Theme.accentDeep)
            Text(lead)
                .font(Theme.Typo.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            + Text(" " + rest)
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.cosy)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
            )
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.ui(13, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }

    private func cardText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.prose(13))
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ label: String, action: @escaping () -> Void) -> some View {
        PillButton(title: label, large: true, action: action)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Theme.Space.tight)
    }

    private var dots: some View {
        HStack(spacing: Theme.Space.snug) {
            ForEach(Step.shown) { s in
                Circle()
                    .fill(s == step ? Theme.accent : Theme.ruleStrong)
                    .frame(width: 6, height: 6)
            }
        }
    }
}
