import AppKit
import MoeDesign
import MoeVoice
import SwiftUI

// MARK: - What the card needs from the microphone

/// Everything `WakeTeachModel` asks of the outside world. The app's is
/// `EngineWakeTeachDriver`; the tests' is a fake that records what it was
/// asked and answers on cue, so the controller's side — which clip file is
/// deleted when, whether the microphone is given back — is tested without
/// a microphone.
@MainActor
protocol WakeTeachDriving: AnyObject {
    /// Open the microphone; nil when it is open, otherwise why not.
    func open(level: @escaping @MainActor (Float) -> Void) async -> WakeTeachFlow.Failure?
    /// Record one line. Nil when cancelled (nothing was saved).
    func record(line: Int, session: String,
                onSpeech: @escaping @MainActor () -> Void) async -> (WakeTeachFlow.ClipResult, URL?)?
    func delete(_ url: URL)
    func close()
    func measure(progress: @escaping @MainActor (Int, Int) -> Void) async
        -> Result<WakeTeachFlow.Outcome, WakeTeachFlow.Failure>
}

/// The real microphone: `VoiceEngine`'s teach hooks, through the conductor.
@MainActor
final class EngineWakeTeachDriver: WakeTeachDriving {
    let conductor: Conductor
    let script = WakeRecorder.shortScript()
    init(conductor: Conductor) { self.conductor = conductor }

    func open(level: @escaping @MainActor (Float) -> Void) async -> WakeTeachFlow.Failure? {
        switch await conductor.openWakeTeach(level: level) {
        case nil: return nil
        case .busy?: return .busy
        case .unavailable(let why)?: return .unavailable(why)
        case .heardNothing?, .done?: return .unavailable("The microphone is unavailable.")
        }
    }

    func record(line: Int, session: String,
                onSpeech: @escaping @MainActor () -> Void) async -> (WakeTeachFlow.ClipResult, URL?)? {
        switch await conductor.recordWakeClip(script[line], number: line + 1, session: session, onSpeech: onSpeech) {
        case nil: return nil
        case .kept(let url, let quiet)?: return (quiet ? .keptQuiet : .kept, url)
        case .rejected(let why)?: return (.rejected(why), nil)
        }
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func close() { conductor.closeWakeTeach() }

    func measure(progress: @escaping @MainActor (Int, Int) -> Void) async
        -> Result<WakeTeachFlow.Outcome, WakeTeachFlow.Failure> {
        switch await conductor.measureWakeTeach(progress: progress) {
        case .done(let pick, let changed): return .success(.init(pick: pick, changed: changed))
        case .heardNothing: return .failure(.heardNothing)
        case .busy: return .failure(.busy)
        case .unavailable(let why): return .failure(.unavailable(why))
        }
    }
}

extension WakeTeachFlow {
    /// The card's lines: the Settings script, `WakeRecorder.shortScript`.
    static func settingsScript() -> WakeTeachFlow {
        WakeTeachFlow(lines: WakeRecorder.shortScript().map {
            .init(say: $0.say, note: $0.note, isName: $0.folder == "positive")
        })
    }
}

// MARK: - The controller

/// Carries out what `WakeTeachFlow` asks for. It decides nothing: every
/// press goes to the flow, and every effect the flow returns is done here,
/// in order.
@MainActor
final class WakeTeachModel: ObservableObject {
    @Published private(set) var flow: WakeTeachFlow
    /// The microphone, 0…1, for the meter.
    @Published private(set) var level: Float = 0
    /// A line under the card's own footer: what "Send" or "Forget" did.
    @Published var note: String?

    private let driver: WakeTeachDriving
    private var recordTask: Task<Void, Never>?
    private var beatTask: Task<Void, Never>?
    /// The file kept for each line this run, so a redo or a cancel can
    /// remove exactly it.
    private(set) var files: [Int: URL] = [:]
    private var session = WakeTeachModel.stamp()
    var onDismiss: () -> Void = {}
    /// How long "Got it ✓" stays up before the next line.
    var beatSeconds: Double = 0.8

    init(flow: WakeTeachFlow = .settingsScript(), driver: WakeTeachDriving, level: Float = 0) {
        self.flow = flow
        self.driver = driver
        self.level = level
    }

    static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "")
    }

    func send(_ event: WakeTeachFlow.Event) {
        if event == .teachAgain || event == .start {
            files = [:]
            session = Self.stamp()
        }
        let effects = flow.send(event)
        perform(effects[...])
    }

    private func perform(_ effects: ArraySlice<WakeTeachFlow.Effect>) {
        guard let first = effects.first else { return }
        let rest = effects.dropFirst()
        switch first {
        case .openMic:
            // Everything after the microphone waits for it: a record
            // started before it is open would listen to nothing.
            Task { [weak self] in
                guard let self else { return }
                if let why = await self.driver.open(level: { [weak self] in self?.level = $0 }) {
                    self.send(.micFailed(why))
                    return
                }
                self.send(.micReady)
                self.perform(rest)
            }
            return
        case .record(let line, let take):
            // A record left over from a batch the flow has since moved
            // past (the microphone failed, the card closed) is not started.
            if flow.take == take, flow.recording { record(line: line, take: take) }
        case .stopRecording:
            recordTask?.cancel()
            recordTask = nil
            level = 0
        case .discard(let line):
            if let url = files.removeValue(forKey: line) { driver.delete(url) }
        case .beat:
            beatTask?.cancel()
            // A quiet clip's note is two lines; give it time to be read.
            let seconds = flow.lastKeptQuiet ? beatSeconds * 3 : beatSeconds
            beatTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.send(.advance)
            }
        case .closeMic:
            driver.close()
            level = 0
        case .measure:
            Task { [weak self] in
                guard let self else { return }
                let result = await self.driver.measure { [weak self] done, total in
                    self?.send(.measuring(done: done, total: total))
                }
                switch result {
                case .success(let o): self.send(.measured(o.pick, changed: o.changed))
                case .failure(let why): self.send(.measureFailed(why))
                }
            }
        case .dismiss:
            beatTask?.cancel()
            onDismiss()
        }
        perform(rest)
    }

    private func record(line: Int, take: Int) {
        recordTask?.cancel()
        let session = session
        recordTask = Task { [weak self] in
            guard let self else { return }
            let got = await self.driver.record(line: line, session: session) { [weak self] in
                self?.send(.speechBegan(take: take))
            }
            guard let (result, url) = got else { return }
            // A take the card has moved past — paused, redone, closed —
            // while it was still saving: its clip is nobody's, so it goes.
            guard self.flow.take == take, self.flow.recording else {
                if let url { self.driver.delete(url) }
                return
            }
            if let url { self.files[line] = url }
            self.send(.clip(take: take, result))
        }
    }
}

// MARK: - The card

/// Settings › Voice › "Teach Moe its name": a sheet over Settings, one
/// step at a time — why and how long, one phrase at a time with a meter
/// and a tick per clip, the measuring, and the result against before.
struct WakeTeachCard: View {
    @ObservedObject var model: WakeTeachModel
    /// Clips already on this Mac from earlier runs; the secondary actions
    /// appear only when there is something for them to act on.
    var clipsOnMac: Int = 0
    /// What the last run found, for the intro.
    var previous: String?
    var send: () -> Void = {}
    var forget: () -> Void = {}

    static let size = CGSize(width: 540, height: 540)

    private var flow: WakeTeachFlow { model.flow }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch flow.step {
                case .intro, .starting: intro
                case .listening, .hearing, .gotIt, .retake, .paused: recording
                case .measuring(let done, let total): measuring(done: done, total: total)
                case .result(let outcome): result(outcome)
                case .failed(let why): failed(why)
                case .closed: Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Space.section)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.raised)
        .onChange(of: flow.announcement) { _, line in
            guard let line else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: Theme.Space.base) {
            settingsLabel("TEACH MOE ITS NAME")
            Spacer()
            if let i = flow.index {
                Text("\(i + 1) of \(flow.lines.count)")
                    .font(Theme.Typo.data(11))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityLabel("Phrase \(i + 1) of \(flow.lines.count)")
            }
            Button { model.send(.cancel) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.sunk))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.top, Theme.Space.cosy)
        .padding(.bottom, Theme.Space.small)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: Theme.Space.small) {
                footerLeading
                Spacer(minLength: Theme.Space.base)
                footerTrailing
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
        }
    }

    @ViewBuilder private var footerLeading: some View {
        switch flow.step {
        case .intro, .result, .failed:
            if clipsOnMac > 0 { recordingsMenu }
            if let note = model.note {
                Text(note).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3).lineLimit(2)
            }
        case .listening, .hearing, .retake, .paused:
            if flow.canRedoPrevious {
                PaneButton(title: "Redo the last one", symbol: "arrow.uturn.backward") { model.send(.redoPrevious) }
                    .accessibilityHint("Throws away the last clip and asks for it again")
            }
            if case .retake = flow.step {
                PaneButton(title: "Skip this one") { model.send(.skip) }
            }
            if flow.canFinishEarly {
                PaneButton(title: "Finish with these") { model.send(.finishEarly) }
                    .accessibilityHint("Measures the clips recorded so far")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var footerTrailing: some View {
        switch flow.step {
        case .result:
            PaneButton(title: "Teach again") { model.send(.teachAgain) }
            primaryButton
        case .measuring:
            PaneButton(title: "Close") { model.send(.cancel) }
                .keyboardShortcut(.cancelAction)
                .help("Moe keeps measuring and applies what it finds")
        case .failed:
            PaneButton(title: "Close") { model.send(.cancel) }
                .keyboardShortcut(.cancelAction)
            primaryButton
        default:
            PaneButton(title: "Cancel") { model.send(.cancel) }
                .keyboardShortcut(.cancelAction)
                .help("Stop without changing anything (Esc)")
            primaryButton
        }
    }

    /// The one button Space presses, whatever it is on this step.
    @ViewBuilder private var primaryButton: some View {
        if let primary = flow.primary {
            PaneButton(title: primary.title, prominent: true, large: true) { model.send(primary.event) }
                .keyboardShortcut(KeyEquivalent(" "), modifiers: [])
                .help("\(primary.title) (Space)")
        } else if case .starting = flow.step {
            HStack(spacing: Theme.Space.snug) {
                ProgressView().controlSize(.small)
                Text("Opening the microphone…").font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink2)
            }
        }
    }

    private var recordingsMenu: some View {
        Menu {
            Button("Send them to the Moe team…", action: send)
            Button("Forget my recordings", role: .destructive, action: forget)
        } label: {
            HStack(spacing: Theme.Space.tight) {
                Text("\(clipsOnMac) clip\(clipsOnMac == 1 ? "" : "s") on this Mac")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Your recordings: \(clipsOnMac) clips on this Mac")
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accentTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                Text("Teach Moe how you say its name")
                    .font(Theme.Typo.display(24))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Moe learns how you say “Hey Moe” in this room, so it answers you and not a phrase that only sounds like it.")
                    .font(Theme.Typo.prose(15))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                fact("clock", "About two minutes: “Hey Moe” twelve times, then eight sound-alikes.")
                fact("text.bubble", "One phrase at a time. Say it when it appears — Moe moves on by itself.")
                fact("lock", "The clips stay on this Mac. Nothing is sent anywhere.")
            }
            if let previous {
                Text(previous)
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Recording

    private var recording: some View {
        VStack(spacing: Theme.Space.roomy) {
            dots
                .padding(.top, Theme.Space.small)
            Spacer(minLength: 0)
            if let line = flow.line {
                VStack(spacing: Theme.Space.small) {
                    Text(line.isName ? "SAY" : "NOW A SOUND-ALIKE — SAY")
                        .font(Theme.Typo.label(10))
                        .tracking(Theme.tracking)
                        .foregroundStyle(line.isName ? Theme.ink3 : Theme.warn)
                    Text("“\(line.say)”")
                        .font(Theme.Typo.display(line.say.count > 16 ? 26 : 40))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel("Say: \(line.say)")
                        .accessibilityAddTraits(.isHeader)
                    Text(line.note.prefix(1).uppercased() + line.note.dropFirst())
                        .font(Theme.Typo.prose(14))
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                }
                .opacity(isPaused ? 0.45 : 1)
            }
            meter
            status
                .frame(minHeight: 64, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var isPaused: Bool { if case .paused = flow.step { return true }; return false }

    /// One dot per phrase, a gap between the names and the sound-alikes.
    private var dots: some View {
        let d = flow.dots
        let names = flow.lines.filter(\.isName).count
        return HStack(spacing: 5) {
            ForEach(Array(d.enumerated()), id: \.offset) { i, dot in
                if i == names { Spacer().frame(width: 8) }
                Circle()
                    .fill(fill(dot, isName: flow.lines[i].isName))
                    .overlay(Circle().strokeBorder(dot == .current ? Theme.accent : Color.clear, lineWidth: 2))
                    .frame(width: dot == .current ? 11 : 8, height: dot == .current ? 11 : 8)
            }
        }
        .frame(height: 12)
        .animation(Theme.Motion.easeOut, value: d)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flow.keptCount) of \(flow.lines.count) phrases recorded")
    }

    private func fill(_ dot: WakeTeachFlow.Dot, isName: Bool) -> Color {
        switch dot {
        case .done: return isName ? Theme.accent : Theme.warn
        case .skipped: return Theme.ruleStrong
        case .current: return Theme.raised
        case .pending: return Theme.rule
        }
    }

    /// The microphone, as bars: lit from the middle out, so a voice reads
    /// as a shape rather than a progress bar.
    private var meter: some View {
        let bars = 29
        let lit: Int = {
            switch flow.step {
            case .listening, .hearing: return Int((Double(model.level) * Double(bars)).rounded())
            case .gotIt: return bars
            default: return 0
            }
        }()
        let colour: Color = {
            switch flow.step {
            case .hearing: return Theme.bad
            case .gotIt: return Theme.good
            default: return Theme.accent
            }
        }()
        return HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let fromMiddle = abs(i - bars / 2)
                let on = fromMiddle * 2 < lit
                Capsule()
                    .fill(on ? colour : Theme.rule)
                    .frame(width: 4, height: 8 + CGFloat(max(0, 7 - fromMiddle / 2)) * 3)
            }
        }
        .frame(height: 32)
        .animation(.linear(duration: 0.08), value: lit)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(model.level * 100)) percent")
    }

    @ViewBuilder private var status: some View {
        switch flow.step {
        case .listening:
            statusLine(dot: Theme.ink3, "Listening — say it when you're ready")
        case .hearing:
            statusLine(dot: Theme.bad, "Recording…")
        case .gotIt where flow.lastKeptQuiet:
            VStack(spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Text(WakeTeachFlow.Problem.tooQuiet.title)
                        .font(Theme.Typo.ui(14, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text(WakeTeachFlow.Problem.tooQuiet.advice)
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
            }
        case .gotIt:
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                Text("Got it").font(Theme.Typo.ui(14, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        case .retake(_, let problem):
            VStack(spacing: Theme.Space.tight) {
                HStack(spacing: Theme.Space.snug) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn)
                    Text(problem.title).font(Theme.Typo.ui(13, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text(problem.advice + " Press Space to try again.")
                    .font(Theme.Typo.ui(12))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.cosy)
            .padding(.vertical, Theme.Space.base)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.sidebar))
        case .paused:
            statusLine(dot: Theme.ink3, "Paused — the microphone is off. Carry on when you're ready.")
        default:
            EmptyView()
        }
    }

    private func statusLine(dot: Color, _ text: String) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(Theme.Typo.ui(13)).foregroundStyle(Theme.ink2)
        }
    }

    // MARK: Measuring

    private func measuring(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Spacer(minLength: 0)
            Text("Measuring how Moe hears you")
                .font(Theme.Typo.display(24))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if total > 0 {
                // Drawn, not a ProgressView: the system bar ignores the
                // accent in an inactive sheet and comes out grey.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.rule)
                        Capsule().fill(Theme.accent)
                            .frame(width: g.size.width * CGFloat(done) / CGFloat(total))
                    }
                }
                .frame(height: 8)
                .animation(Theme.Motion.easeOut, value: done)
                .accessibilityElement()
                .accessibilityLabel("Measuring")
                .accessibilityValue("\(done) of \(total) clips")
                Text("Listened to \(done) of \(total) clip\(total == 1 ? "" : "s") on this Mac")
                    .font(Theme.Typo.data(11))
                    .foregroundStyle(Theme.ink3)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                Text("Loading the wake word model…")
                    .font(Theme.Typo.data(11))
                    .foregroundStyle(Theme.ink3)
            }
            Text("The microphone is off. Moe plays every clip back through the wake word and finds the setting that catches your voice and leaves the sound-alikes alone.")
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.small)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Result

    private func result(_ o: WakeTeachFlow.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.base) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.good)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.good.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.title)
                        .font(Theme.Typo.display(22))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(o.headline)
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            compare(title: "Your “Hey Moe”s it catches", better: "more is better",
                    before: o.caughtBefore, now: o.caughtNow, of: o.names)
            if o.soundAlikes > 0 {
                compare(title: "Sound-alikes it answers by mistake", better: "fewer is better",
                        before: o.letThroughBefore, now: o.letThroughNow, of: o.soundAlikes)
            }
            Text(o.changed
                 ? "Moe uses the new setting from now on, on this Mac. Teach it again in another room if it still misses you there."
                 : "The setting Moe had is already the best one for your voice here, so nothing changed.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compare(title: String, better: String, before: Int, now: Int, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.Typo.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text(better).font(Theme.Typo.ui(11)).foregroundStyle(Theme.ink3)
            }
            bar("Before", value: before, of: total, colour: Theme.ink3.opacity(0.55))
            bar("Now", value: now, of: total, colour: Theme.accent)
        }
        .padding(Theme.Space.cosy)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.rule, lineWidth: Theme.Stroke.hair))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(now) of \(total) now, \(before) before")
    }

    private func bar(_ label: String, value: Int, of total: Int, colour: Color) -> some View {
        HStack(spacing: Theme.Space.base) {
            Text(label)
                .font(Theme.Typo.ui(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 46, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule)
                    Capsule().fill(colour)
                        .frame(width: total > 0 ? max(value > 0 ? 8 : 0, g.size.width * CGFloat(value) / CGFloat(total)) : 0)
                }
            }
            .frame(height: 8)
            Text("\(value) of \(total)")
                .font(Theme.Typo.data(11))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 58, alignment: .trailing)
        }
    }

    // MARK: Failed

    private func failed(_ why: WakeTeachFlow.Failure) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.warn)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.warn.opacity(0.14)))
                .accessibilityHidden(true)
            Text("That didn't work this time")
                .font(Theme.Typo.display(22))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(why.text)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing changed: Moe listens for its name the way it did before.")
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Posing, for `--settings-snapshot`

/// A driver that does nothing: the snapshot poses the card from events,
/// and nothing is ever recorded.
@MainActor
final class InertWakeTeachDriver: WakeTeachDriving {
    func open(level: @escaping @MainActor (Float) -> Void) async -> WakeTeachFlow.Failure? { nil }
    func record(line: Int, session: String, onSpeech: @escaping @MainActor () -> Void) async -> (WakeTeachFlow.ClipResult, URL?)? { nil }
    func delete(_ url: URL) {}
    func close() {}
    func measure(progress: @escaping @MainActor (Int, Int) -> Void) async -> Result<WakeTeachFlow.Outcome, WakeTeachFlow.Failure> {
        .failure(.heardNothing)
    }
}

extension WakeTeachFlow {
    /// The card in each state worth looking at, reached by sending the
    /// events that lead there — so a pose is a path the flow allows.
    static func poses() -> [(name: String, flow: WakeTeachFlow, level: Float)] {
        func run(_ events: [Event]) -> WakeTeachFlow {
            var f = WakeTeachFlow.settingsScript()
            for e in events {
                switch e {
                // A take number is the flow's, not the caller's.
                case .clip(_, let r): f.send(.clip(take: f.take, r))
                case .speechBegan: f.send(.speechBegan(take: f.take))
                default: f.send(e)
                }
            }
            return f
        }
        let two: [Event] = [.start, .micReady,
                            .clip(take: 0, .kept), .advance,
                            .clip(take: 0, .kept), .advance]
        let names: [Event] = [.start, .micReady] + Array(repeating: [Event.clip(take: 0, .kept), .advance], count: 12).flatMap { $0 }
        let all: [Event] = [.start, .micReady] + Array(repeating: [Event.clip(take: 0, .kept), .advance], count: 20).flatMap { $0 }
        let pick = WakeCalibration.Pick(threshold: 0.24,
                                        after: .init(positives: 12, caught: 11, confusables: 8, falseAccepts: 1),
                                        before: .init(positives: 12, caught: 8, confusables: 8, falseAccepts: 2))
        return [
            ("teach-01-intro", run([]), 0),
            ("teach-02-listening", run(two), 0.08),
            ("teach-03-recording", run(two + [.speechBegan(take: 0)]), 0.72),
            ("teach-04-got-it", run(two + [.speechBegan(take: 0), .clip(take: 0, .kept)]), 0),
            ("teach-05-retake-nothing-heard", run(two + [.clip(take: 0, .rejected(.nothingHeard))]), 0),
            ("teach-05b-got-it-quiet", run(two + [.speechBegan(take: 0), .clip(take: 0, .keptQuiet)]), 0),
            ("teach-06-paused", run(two + [.pause]), 0),
            ("teach-07-sound-alike", run(names + [.speechBegan(take: 0)]), 0.55),
            ("teach-08-measuring", run(all + [.measuring(done: 13, total: 20)]), 0),
            ("teach-09-result", run(all + [.measured(pick, changed: true)]), 0),
            ("teach-10-failed", run([.start, .micFailed(.busy)]), 0),
        ]
    }
}
