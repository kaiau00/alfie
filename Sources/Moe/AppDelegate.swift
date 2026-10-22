import AppKit
import Carbon.HIToolbox
import Combine
import MoeMeeting
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var pushToTalk: PushToTalk?
    private var conductor: Conductor!
    private var island: NotchIsland!
    /// The magenta line around the screen while Moe drives (2026-09-24).
    private var drivingEdge: DrivingEdge?
    private var window: NSWindow?
    private var listeningItem: NSMenuItem?
    /// "Start meeting" in the status menu and the Moe menu; retitled to
    /// "● Recording 12:34 · Stop" while a meeting runs.
    private var meetingItems: [NSMenuItem] = []
    /// "Off the record" / "Back on the record"; hidden unless recording.
    private var meetingPauseItems: [NSMenuItem] = []
    private var meetingHotKey: HotKey?
    /// ⌃⌥S and ⌃⌥R, registered only while a meeting is being recorded.
    private var captureHotKeys: [HotKey] = []
    private var meetingShotItems: [NSMenuItem] = []
    private var meetingClipItems: [NSMenuItem] = []
    private var meetingObservers: Set<AnyCancellable> = []
    /// The "Sign in" items, shown only while the brain is waiting on one.
    private var signInItems: [NSMenuItem] = []
    private var signInWatch: AnyCancellable?
    private var onboarding: OnboardingWindow?
    /// `moe://checkout?…` links that arrived before the app had started — a
    /// cold launch by the payment page. Handed over once `Conductor` exists.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything, including the lock: is this bundle even allowed
        // to BE Moe? A build run out of a worktree's dist/ carries the same
        // identifier as the installed app, so macOS gives it the same Dock
        // icon and menu bar, and for a day and a half one did exactly that
        // while the real Moe sat installed and unopened. It has to quit
        // before it takes the lock, or the real Moe is the one that quits.
        RunningFromHere.enforce()
        // Start watching for the person's own events, so a consent control
        // can tell a live person-press from a lingering one (D9.14,
        // HumanEvent.swift). Cheap, and must be running before any consent
        // control is shown.
        HumanPresence.shared.start()
        // One Moe. A second copy — a debug build someone ran, a double
        // launch — would answer every question beside this one. It brings
        // the running one forward and leaves. See InstanceLock.
        // The installed Moe takes the lock from a workbench build rather
        // than quitting. Before this, Moe Dev holding it at login meant the
        // owner's Moe would not start at all — and said so only in a log
        // line that reads like routine housekeeping.
        if !InstanceLock.acquire(waiting: 3), !InstanceLock.evictLesserHolder() {
            let who = InstanceLock.holderDescription
            Log.write("another Alfie is already running: \(who); this one is quitting")
            FileHandle.standardError.write(Data("Alfie is already running: \(who)\n".utf8))
            if let pid = InstanceLock.holder {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            Log.flush()
            exit(0)
        }
        // Diagnostic: a Space switch mid-action is what makes Moe "click into
        // the wrong app". Timestamped here, it lines up with the tool log.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.write("space changed; front app now \(front)")
        }
        // A REGULAR app: Dock icon, ⌘Q, an app menu, and a window you can
        // close. The first version was `.accessory` (menu-bar only), which is
        // precisely why it couldn't be quit or got rid of.
        NSApp.setActivationPolicy(.regular)

        let firstRun = FirstRun.installHomeIfNeeded()

        // installHomeIfNeeded lays the ~/.moe payload down from the bundle on
        // its way through — connectors, tools, connect scripts, Hermes glue.
        // Synchronous, and deliberately so: the supervisor reads
        // configure-hermes.py a moment from now and the Connections pane
        // resolves its scripts by path. After the first run it is one file
        // read. Payload.swift says why it is a copy and not a bundle path.

        let config = Config.load()
        // A fresh install has no config.json, and Config.load() hands back
        // the defaults without writing them. The app reads those in memory;
        // the scripts cannot — moe-calendar-heads-up.py reads a missing
        // calendarHeadsUpMinutes as off, and configure-hermes.py's
        // delivery_for reads a missing replyLength as Balanced — so rows 21
        // and 5 of docs/DEFAULTS.md were true on screen and false everywhere
        // else. Written here, once, and never over a file that exists. Not
        // inside Config.load(), which every test and headless verb calls.
        Config.writeIfAbsent(config)
        conductor = Conductor(config: config)
        island = NotchIsland(conductor: conductor)
        drivingEdge = DrivingEdge(conductor: conductor)
        // The ⋯ tray's window icon (`IslandTray.openChat`). A click on the
        // island itself opens the island and nothing else (2026-09-24): a
        // held reminder shows its card there, with Play on it, rather than
        // being read aloud by a click that landed on the glow.
        island.onOpenWindow = { [weak self] in self?.showWindow() }

        // Collapse back to the pill rather than vanishing: "hidden" should be
        // something you choose from the menu, not the resting state. Otherwise
        // Moe has no home on screen and feels like it isn't running.
        // The inbox (docs/INBOX.md): a notice opened as a card on screen, the
        // app's Inbox page at one, and the island opened from a card.
        conductor.onOpenNoticeCard = { [weak self] id in
            guard let self else { return }
            NoticeCardWindow.shared.show(id, conductor: self.conductor)
        }
        conductor.onOpenInboxPage = { [weak self] id in
            guard let self else { return }
            self.conductor.inboxFocus = id
            self.showMainWindow(at: .inbox)
        }
        conductor.onOpenIsland = { [weak self] in
            self?.island.show(expanded: true)
        }
        conductor.onWantsIsland = { [weak self] show in
            guard let self else { return }
            // Never auto-expand. The glow is the whole signal during a session;
            // the panel is opt-in, by hovering the notch.
            // Never fully hide: the faint idle glow is how you know Moe is
            // running at all. Dismissing collapses it, it does not switch it off.
            //
            // Two entry points, not one. "Be visible" and "be closed" are
            // different requests, and answering the first with a collapse is
            // what slammed the meeting panel shut mid-sentence every time a
            // wake word or a nudge or a bookmark came through
            // (docs/PANEL-FINDINGS.md §4).
            if show { self.island.reveal() } else { self.island.dismiss() }
        }

        // Moe answered. During a meeting — and anywhere spoken replies are
        // off — the panel is the only place that answer exists, so it opens
        // itself to show you. Without the keyboard, and it folds again after
        // long enough to read. §5 is the signal, §7 is the panel.
        conductor.onReply = { [weak self] _ in
            guard let self else { return }
            // Unless the chat window is already in front with the answer in
            // it. The island exists for the case where there is nowhere else
            // the reply could land — which, during a meeting, is always: Moe
            // is never the active app then.
            if self.window?.isVisible == true, NSApp.isActive { return }
            self.island.revealReply()
        }

        // Before the menus, because the "Check for Updates…" item exists only
        // if this build actually has a feed to check. A checkout build starts
        // nothing and shows nothing — see Updates.swift.
        Updates.start()

        buildMenuBar(config: config)
        buildStatusItem(config: config)
        registerHotKey(config: config)
        wireMeetings(config: config)

        watchSignIn()

        conductor.startUp()
        // A payment page that launched Moe: said now that the starter runs.
        let urls = pendingURLs
        pendingURLs = []
        for url in urls { _ = conductor.cloud.open(url, conductor: conductor) }
        island.show(expanded: false)   // lives under the notch from launch
        // The Hermes inside the app goes into ~/.hermes now, in the
        // background, so a downloaded copy can think without a network step.
        // The gateway above has already tried to start and found nothing;
        // when the seed lands it is started again, which is the difference
        // between a first question that answers and one that says the
        // thinking part is missing. Onboarding's brain screen watches the
        // same object (SeedInstall) and shows "getting ready" meanwhile.
        SeedInstall.shared.startIfNeeded { [weak self] in self?.conductor.restartBrain() }
        // And a Hermes that is already here is brought to the commit this
        // build pins — if, and only if, it is a pristine checkout nobody
        // works in, behind the pin, and this is the real Moe. The check is a
        // handful of local git reads, now; the move waits until a gateway of
        // Moe's own is up, and restarts it afterwards. Refusals go to moe.log
        // and ~/.moe/logs/hermes-upgrades.log, not the island: they are for
        // whoever owns the checkout.
        HermesUpgrade.checkAtLaunch(
            gatewayUp: { [weak self] done in
                guard let self else { done(false, "Alfie is gone"); return }
                self.conductor.whenOwnGatewayUp(done)
            },
            reload: { [weak self] reason in self?.conductor.reloadGateway(reason: reason) })
        conductor.debugEnterFakeMeeting()
        // Onboarding when it hasn't been seen and there's nothing to skip
        // it for: a brand-new home, or an install (scripts/install.sh made
        // ~/.moe already) that has never signed in. Someone with a sign-in
        // already is past it; the marker is written so the keychain isn't
        // asked again.
        if let screen = Onboarding.resumeScreen {
            // Back from the relaunch a permission needed, mid-flow. Before
            // the marker and the sign-in are consulted: by now the home
            // exists and the Claude sign-in is stored, which the branch
            // below reads as "past onboarding" — it is not.
            Onboarding.clearResume()
            showOnboarding(at: screen)
        } else if Onboarding.done {
            showWindow()
            askAboutBackgroundLearning()
        } else if firstRun || !HermesKey.childOAuthTokenExists() {
            showOnboarding()
        } else {
            Onboarding.markDone()
            showWindow()
            askAboutBackgroundLearning()
        }
        // Row 30: Moe as a login item. Registered when the welcome is
        // finished (showOnboarding's onCompleted); here only for a Mac that
        // finished it before that rule, and never on the launch an erase
        // opens. After the onboarding decision, so a Mac marked done just
        // above counts; before afterLaunch(), which consumes the erase note
        // this reads. System Settings › Login Items is the person's switch
        // after the one time. See LoginItem.
        let loginItem = LoginItem.applyOnce(config, at: LoginItem.launchMoment(onboarded: Onboarding.done))
        if loginItem != "already applied" { Log.write("login item at launch: \(loginItem)") }
        // The launch after an erase: what it could not remove, said once.
        EraseLeftoversFlow.afterLaunch()
    }

    /// The one question setup never asked: a daily pass back over everything
    /// you have connected was installed as a side effect of configuring the
    /// brain, and nothing in the app said so.
    ///
    /// Asked once, and only once there is a source it could actually read
    /// (BackgroundLearning.askIfNeeded checks both) — a sheet about reading
    /// nothing is noise. Never during onboarding: that flow owns the screen,
    /// and stacking a modal on it is how people click yes without reading.
    /// The delay lets the main window finish coming up so the sheet has
    /// something to hang off.
    private func askAboutBackgroundLearning() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.onboarding == nil else { return }
            BackgroundLearning.askIfNeeded(over: self.window) { [weak self] shown in
                DispatchQueue.main.async {
                    guard let self, self.onboarding == nil else { return }
                    // One question at a time: after one was just shown, the
                    // one about unanswered sources waits for the next return
                    // to Moe; only then does coming back to Moe ask it.
                    if !shown { BackgroundLearning.ConnectAsk.askPending(over: self.window) }
                    self.watchForPendingAsk()
                }
            }
        }
    }

    private func watchForPendingAsk() {
        guard !watchingForPendingAsk else { return }
        watchingForPendingAsk = true
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.onboarding == nil else { return }
                BackgroundLearning.ConnectAsk.askPending(over: self.window)
            }
        }
    }

    private var watchingForPendingAsk = false

    /// First launch: one small window, one step at a time. It ends on the
    /// Connections pane of the main window.
    private func showOnboarding(at screen: Onboarding.Screen = .welcome) {
        let w = OnboardingWindow(conductor: conductor)
        w.onOpenConnections = { [weak self] in
            self?.showWindow()
            NotificationCenter.default.post(name: .moeShowSection, object: nil,
                                            userInfo: ["section": MainWindow.Section.connections.rawValue])
        }
        // The brain screen's "set it up yourself" paths (a key, a model on
        // this Mac) need the pane that has the fields, not a second copy of
        // them inside a window that is about to close.
        w.onOpenSection = { [weak self] section in
            self?.showWindow()
            NotificationCenter.default.post(name: .moeShowSection, object: nil,
                                            userInfo: ["section": section.rawValue])
        }
        // The end of the welcome — its last screen, which shows "Start Moe
        // when my Mac starts" — is the moment row 30 names for the login
        // item. Read from disk: that switch writes config.json as it moves.
        // Not on an early close; the next launch covers that Mac.
        w.onCompleted = {
            let outcome = LoginItem.applyOnce(Config.load(), at: .welcomeFinished)
            Log.write("login item at the end of the welcome: \(outcome)")
        }
        w.onFinished = { [weak self] in
            Onboarding.markDone()
            self?.onboarding = nil
            // Closed early, or finished: either way the main window is
            // what comes next, never nothing.
            self?.showWindow()
            self?.askAboutBackgroundLearning()
        }
        onboarding = w
        if screen == .welcome {
            w.show()
        } else {
            var pose = OnboardingView.Pose()
            pose.step = screen
            w.show(pose: pose)
        }
    }

    /// Menus get a "Sign in" item exactly while the brain says it needs one.
    private func watchSignIn() {
        signInWatch = conductor.$needsSignIn.receive(on: DispatchQueue.main).sink { [weak self] needs in
            self?.signInItems.forEach { $0.isHidden = !needs }
        }
    }

    private func signInMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Connect an AI…",
                              action: #selector(signIn), keyEquivalent: "")
        item.target = self
        item.isHidden = !conductor.needsSignIn
        signInItems.append(item)
        return item
    }

    /// Settings → Brain, with the sign-in sheet open. Brain lives in the
    /// Settings window now, so this opens that directly rather than routing a
    /// section change through the main window.
    @objc private func signIn() {
        SettingsWindow.show(conductor: conductor, at: .brain)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .moeSignIn, object: nil)
        }
    }

    /// A `moe://` link (build.sh, CFBundleURLTypes). The only ones the app
    /// takes are its cloud's — the payment page coming back, in the official
    /// build (`CloudLink.open`); anything else is ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if conductor == nil {
                pendingURLs.append(url)
            } else {
                _ = conductor.cloud.open(url, conductor: conductor)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A sign-in still waiting on the browser is its own session (setsid);
        // it would outlive the app otherwise.
        ClaudeSignIn.cancel()
        // A Hermes move in flight is stopped and rolled back before the
        // gateway it would have restarted is taken down; nothing new starts.
        HermesUpgrade.cancelForShutdown()
        conductor?.shutDown()
    }

    /// Clicking the Dock icon brings the window back rather than doing nothing.
    /// A reopen while the window is already up (a stray `open -a`, a login
    /// item re-firing) must not steal focus or switch Spaces.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows || window?.isVisible != true { showWindow() }
        return true
    }

    // MARK: - Window

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Someone who reaches Moe from the island opens this window, not
            // the app: ask about unanswered sources here too (re-review N3).
            if watchingForPendingAsk, onboarding == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    BackgroundLearning.ConnectAsk.askPending(over: self?.window)
                }
            }
            return
        }
        let hosting = NSHostingController(rootView: MainWindow(conductor: conductor))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Alfie"
        w.setContentSize(NSSize(width: 900, height: 600))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // No titlebar of its own: the sidebar runs the full height of the
        // window and the traffic lights float over it. MainWindow leaves 34pt
        // of clearance at the top of the sidebar for exactly this.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menus

    private func buildMenuBar(config: Config) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Alfie", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        // Only on a build that was released with an appcast: an item that can
        // only ever fail is worse than no item. Sparkle enables and disables
        // it from here on.
        if let updates = Updates.menuItem() { appMenu.addItem(updates) }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Alfie", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Alfie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let moeItem = NSMenuItem()
        let moeMenu = NSMenu(title: "Alfie")
        let shortcut = HotKey.describe(keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers)
        moeMenu.addItem(withTitle: "Talk to Alfie  (\(shortcut))",
                        action: #selector(talk), keyEquivalent: "").target = self
        moeMenu.addItem(withTitle: "New Conversation", action: #selector(newConversation), keyEquivalent: "n").target = self
        moeMenu.addItem(.separator())
        let meetingItem = NSMenuItem(title: "Start meeting", action: #selector(toggleMeeting), keyEquivalent: "")
        meetingItem.target = self
        moeMenu.addItem(meetingItem)
        meetingItems.append(meetingItem)
        let pauseItem = NSMenuItem(title: "Off the record", action: #selector(toggleMeetingPause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isHidden = true
        moeMenu.addItem(pauseItem)
        meetingPauseItems.append(pauseItem)
        for item in captureMenuItems() { moeMenu.addItem(item) }
        moeMenu.addItem(.separator())
        moeMenu.addItem(signInMenuItem())
        moeMenu.addItem(withTitle: "Show Window", action: #selector(showWindowAction), keyEquivalent: "0").target = self
        moeMenu.addItem(withTitle: "Hide Island", action: #selector(hideIsland), keyEquivalent: "").target = self
        moeItem.submenu = moeMenu
        main.addItem(moeItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// "Take a screenshot" and "Record the screen", hidden unless a meeting
    /// is recording. Built once per menu; retitled by `wireMeetings`.
    private func captureMenuItems() -> [NSMenuItem] {
        let shot = NSMenuItem(title: "Take a screenshot  (⌃⌥S)", action: #selector(takeMeetingScreenshot), keyEquivalent: "")
        shot.target = self
        shot.isHidden = true
        meetingShotItems.append(shot)
        let clip = NSMenuItem(title: "Record the screen  (⌃⌥R)", action: #selector(toggleMeetingClip), keyEquivalent: "")
        clip.target = self
        clip.isHidden = true
        meetingClipItems.append(clip)
        return [shot, clip]
    }

    @objc private func takeMeetingScreenshot() { conductor.captureScreenshot(trigger: .user) }
    @objc private func toggleMeetingClip() { conductor.toggleMeetingClip(trigger: .user) }

    private func buildStatusItem(config: Config) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle",
                                     accessibilityDescription: "Alfie")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let shortcut = HotKey.describe(keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers)
        menu.addItem(withTitle: "Talk to Alfie  (\(shortcut))", action: #selector(talk), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Alfie", action: #selector(showWindowAction), keyEquivalent: "").target = self
        menu.addItem(signInMenuItem())
        menu.addItem(.separator())
        let meetingItem = NSMenuItem(title: "Start meeting", action: #selector(toggleMeeting), keyEquivalent: "")
        meetingItem.target = self
        menu.addItem(meetingItem)
        meetingItems.append(meetingItem)
        let pauseItem = NSMenuItem(title: "Off the record", action: #selector(toggleMeetingPause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isHidden = true
        menu.addItem(pauseItem)
        meetingPauseItems.append(pauseItem)
        for item in captureMenuItems() { menu.addItem(item) }
        menu.addItem(.separator())

        let listening = NSMenuItem(title: "Always Listening  (\u{201C}Hey Alfie\u{201D})",
                                   action: #selector(toggleAlwaysListening), keyEquivalent: "")
        listening.target = self
        listening.state = conductor.alwaysListening ? .on : .off
        menu.addItem(listening)
        listeningItem = listening

        menu.addItem(withTitle: "Hide Island", action: #selector(hideIsland), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alfie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private var escapeMonitor: Any?

    /// Esc stops Moe — only where Esc is Moe's to read: the island's panel or
    /// the chat window has the keyboard. Anywhere else Esc belongs to the app
    /// in front, and the talk key's own hands-free Esc (`TalkChordMachine`)
    /// is untouched. With nothing to stop, Esc does what it did before (the
    /// island's panel folds).
    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            let inMoe = event.window.map { $0 === self.window || self.island?.owns($0) == true } ?? false
            guard inMoe, event.window?.isKeyWindow == true else { return event }
            return self.conductor.escapePressedInMoe() ? nil : event
        }
    }

    private func registerHotKey(config: Config) {
        // Hold ⌃⌥ to talk — the model every shipping app in this category uses.
        let ptt = PushToTalk()
        ptt.onPress = { [weak self] in
            Log.write("hold began")
            self?.conductor.holdBegan()
        }
        ptt.onRelease = { [weak self] in
            Log.write("hold ended")
            self?.conductor.holdEnded()
        }
        ptt.onTap = { [weak self] in
            Log.write("hold ended — a tap")
            self?.conductor.holdEnded(tap: true)
        }
        ptt.onHoldConfirmed = { [weak self] in self?.conductor.holdConfirmed() }
        ptt.onDoubleTap = { [weak self] in
            Log.write("double tap — stopping everything")
            self?.conductor.stopEverything()
        }
        // …unless Moe was idle: then the double-tap listens hands-free, and
        // the next tap sends the turn (release) or Esc drops it (cancel).
        ptt.talkLatchAllowed = { [weak self] in self?.conductor.talkLatchAllowed() ?? false }
        ptt.onTalkLatch = { [weak self] in
            Log.write("double tap — listening hands-free")
            self?.conductor.talkLatchBegan()
        }
        ptt.onTalkUnlatch = { [weak self] reason in
            if reason == .undo { Log.write("double tap then a tap — never mind, nothing sent") }
            self?.conductor.talkLatchEnded(reason)
        }
        watchForEscape()
        conductor.onTalkLatchAbandoned = { [weak self] in self?.pushToTalk?.talkLatchWasAbandoned() }
        // Hold right ⌘ to dictate: same tap, different chord, never the brain.
        ptt.dictationKey = conductor.effectiveDictationKey
        // A key held as part of a shortcut (fn+Delete, right ⌘+Tab) is not a
        // talk press: PushToTalk cancels the hold and Conductor discards what
        // the press had started — no turn, no screenshot, no double-tap credit.
        ptt.onCancel = { [weak self] in
            Log.write("hold cancelled — shortcut")
            self?.conductor.holdCancelled()
        }
        ptt.onDictationPress = { [weak self] in self?.conductor.dictationBegan() }
        ptt.onDictationRelease = { [weak self] in self?.conductor.dictationEnded() }
        ptt.onDictationCancel = { [weak self] in self?.conductor.dictationCancelled() }
        ptt.onDictationLatch = { [weak self] in self?.conductor.dictationLatchBegan() }
        ptt.onDictationUnlatch = { [weak self] reason in self?.conductor.dictationLatchEnded(reason) }
        conductor.onDictationAbandoned = { [weak self] in self?.pushToTalk?.dictationWasAbandoned() }
        conductor.onDictationKeyChanged = { [weak self] key in
            self?.pushToTalk?.dictationKey = key
            Log.write("dictation key: \(key.rawValue)")
        }
        // The key you hold to talk: right ⌥ unless Settings › Voice says
        // otherwise, and changed there without a restart.
        ptt.talkKey = conductor.config.talkKey
        conductor.onTalkKeyChanged = { [weak self] key in
            self?.pushToTalk?.talkKey = key
            Log.write("talk key: \(key.rawValue)")
        }
        if ptt.start() {
            pushToTalk = ptt
            Log.write("push-to-talk armed (hold \(ptt.talkKey.inSentence); double-tap to talk hands-free or stop; "
                      + "dictation on \(ptt.dictationKey.rawValue))")
        } else {
            Log.write("push-to-talk needs Accessibility permission")
            // Arm the moment it is granted. Until now the grant took effect
            // only at the next launch, which is why onboarding had to quit
            // and reopen Moe — and why a person who switched it on and did
            // not relaunch found the key still dead.
            AccessibilityWatch.shared.onGranted.append { [weak self] in
                guard let self, self.pushToTalk == nil else { return }
                // Settings may have changed either key while the tap was
                // unarmed, when there was no `pushToTalk` to hand it to.
                ptt.talkKey = self.conductor.config.talkKey
                ptt.dictationKey = self.conductor.effectiveDictationKey
                guard ptt.start() else { return }
                self.pushToTalk = ptt
                Log.write("push-to-talk armed once Accessibility arrived — no relaunch needed")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.promptForAccessibility()
            }
        }

        // The key combination stays registered as a fallback that needs no
        // permission at all.
        hotKey = HotKey(keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers) { [weak self] in
            Log.write("hotkey fired")
            guard let self else { return }
            // While a meeting is recorded, the shortcut is "note this": a
            // bookmark, not a conversation — the microphone is the
            // meeting's (Conductor.meetingOwnsMic); questions are typed.
            if self.conductor.meeting.isRecording, self.conductor.mode == .idle {
                self.conductor.addMeetingBookmark()
                // `reveal`, not `show`: a bookmark taken with the panel open
                // must not fold the panel. §4.
                self.island.reveal()
                return
            }
            self.talk()
        }
        Log.write(hotKey == nil
            ? "HOTKEY REGISTRATION FAILED (\(config.hotKeyCode)/\(config.hotKeyModifiers)) — another app owns it"
            : "hotkey registered: \(HotKey.describe(keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers))")
        Log.write("accessibility: \(PushToTalk.hasAccessibility ? "granted" : "NOT granted")")
    }

    // MARK: - Meetings

    /// Consent, the indicator and the permission story live here because
    /// they need a window: the confirmation sheet, the denial alert with
    /// its deep link, the menu titles, the status-bar icon.
    private func wireMeetings(config: Config) {
        conductor.onMeetingConsent = { [weak self] proceed in
            guard let self else { proceed(false); return }
            self.confirmMeeting(proceed)
        }
        conductor.onMeetingProblem = { [weak self] message, permission in
            self?.showMeetingProblem(message, permission: permission)
        }
        conductor.onMeetingHotkeyChanged = { [weak self] on in self?.setMeetingHotKey(on) }
        setMeetingHotKey(config.meetingHotkey)
        conductor.onMeetingCaptureProblem = { [weak self] message, permission in
            self?.showCaptureProblem(message, permission: permission)
        }

        // The capture items and shortcuts exist only while recording: a
        // global ⌃⌥S the rest of the time would be a shortcut that does
        // nothing, or worse, one that fights another app's.
        conductor.$meeting.combineLatest(conductor.$meetingClip)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, clip in
                guard let self else { return }
                let recording = state.isRecording
                for item in self.meetingShotItems { item.isHidden = !recording }
                for item in self.meetingClipItems {
                    item.isHidden = !recording
                    item.title = clip ? "Stop recording the screen  (⌃⌥R)" : "Record the screen  (⌃⌥R)"
                }
                self.setCaptureHotKeys(recording && self.conductor.config.meetingCaptureHotkeys)
            }
            .store(in: &meetingObservers)

        conductor.$meeting.combineLatest(conductor.$meetingClock, conductor.$meetingHealth, conductor.$meetingPaused)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, _, _, paused in
                guard let self else { return }
                let title = self.conductor.meetingMenuTitle
                for item in self.meetingItems { item.title = title }
                for item in self.meetingPauseItems {
                    item.isHidden = !state.isRecording
                    item.title = paused ? "Back on the record" : "Off the record (pause)"
                }
                let recording = state.isRecording
                self.statusItem?.button?.image = NSImage(
                    systemSymbolName: recording ? "record.circle.fill" : "waveform.circle",
                    accessibilityDescription: recording ? "Alfie is recording a meeting" : "Alfie")
                self.statusItem?.button?.image?.isTemplate = !recording
                self.statusItem?.button?.contentTintColor = recording ? .systemRed : nil
                // The notes open on the island itself — summary, action
                // items as Reminders, where they went.
                if case .done = state { self.island.show(expanded: true) }
            }
            .store(in: &meetingObservers)

        // "Zoom meeting detected — record it?" and "the call ended — stop?"
        // are asked once, on the island (2026-09-24). They used to be asked
        // twice, there and on a separate card in the top-right corner, in
        // different words with different buttons. The island opens itself
        // for the question, without the keyboard, and the amber glow stays
        // while it is unanswered.
        conductor.$meetingOffer.map { $0 != nil }.removeDuplicates()
            .merge(with: conductor.$meetingEndOffer.map { $0 != nil }.removeDuplicates())
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.island.revealOffer() }
            .store(in: &meetingObservers)
    }

    /// The consent sheet. Nothing records until the answer comes back.
    ///
    /// A designed sheet rather than the `NSAlert` this used to be — see
    /// MeetingConsentSheet for why the copy matters more than the styling.
    /// The window is raised first so the sheet always has a parent to hang
    /// from; the alert remains only as the belt-and-braces path for the case
    /// where there is somehow still no window.
    private func confirmMeeting(_ answer: @escaping (Bool) -> Void) {
        showWindow()
        guard let window else {
            let alert = NSAlert()
            alert.messageText = "Record this meeting?"
            alert.informativeText = """
            Alfie will listen to your microphone and this call's audio, and write notes when it ends. \
            Everything stays on this Mac.

            Alfie can't tell the other people on this call that it's listening — please do that yourself.
            """
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Not now")
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        MeetingConsent.ask(over: window, answer: answer)
    }

    private func showMeetingProblem(_ message: String, permission: Bool) {
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
        Notice.show(over: window,
                    title: permission ? "Alfie can't hear the call" : "Meeting",
                    body: message,
                    confirm: permission ? "Open System Settings" : nil) { confirmed in
            if confirmed { MeetingSession.openAudioCaptureSettings() }
        }
    }

    private func showCaptureProblem(_ message: String, permission: Bool) {
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
        Notice.show(over: window,
                    title: permission ? "Alfie can't see the screen" : "Meeting capture",
                    body: message,
                    confirm: permission ? "Open System Settings" : nil) { confirmed in
            if confirmed { ScreenPermission.openSettings() }
        }
    }

    /// ⌃⌥S (screenshot) and ⌃⌥R (clip), while a meeting records.
    private func setCaptureHotKeys(_ on: Bool) {
        guard on else { captureHotKeys = []; return }
        guard captureHotKeys.isEmpty else { return }
        let mods: UInt32 = 6144   // ⌃⌥, as the meeting hotkey
        captureHotKeys = [
            HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: mods) { [weak self] in
                self?.conductor.captureScreenshot(trigger: .user)
            },
            HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: mods) { [weak self] in
                self?.conductor.toggleMeetingClip(trigger: .user)
            },
        ].compactMap { $0 }
    }

    /// ⌃⌥M, only while the setting is on. Carbon, like the talk shortcut:
    /// no permission needed, and unregistering is just letting it go.
    private func setMeetingHotKey(_ on: Bool) {
        guard on else { meetingHotKey = nil; return }
        guard meetingHotKey == nil else { return }
        meetingHotKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: 6144) { [weak self] in
            Log.write("meeting hotkey fired")
            self?.conductor.requestMeeting()
        }
        Log.write(meetingHotKey == nil ? "MEETING HOTKEY REGISTRATION FAILED — another app owns ⌃⌥M"
                                       : "meeting hotkey registered: ⌃⌥M")
    }

    @objc private func toggleMeeting() {
        conductor.requestMeeting()
    }

    @objc private func toggleMeetingPause() {
        conductor.toggleMeetingPause()
    }

    // MARK: - Actions

    @objc private func talk() {
        Log.write("talk() — mode=\(conductor.mode)")
        // Just wake it. The island glows; it does not unfurl a panel over your
        // screen every time you speak — you asked for a light, not a window.
        // And "wake" never means "fold what is already open" — §4.
        island.reveal()
        conductor.toggle()
    }

    @objc private func showWindowAction() { showWindow() }

    /// Bring the main window up on a particular section. The one way in for a
    /// screen that is *not* in the main window — Settings › Away's welcome
    /// sends people to Connections and Message Moe — because posting
    /// `.moeShowSection` on its own reaches nothing when the window has never
    /// been opened: the listener lives on `MainWindow`'s view. Ordered the way
    /// `showOnboarding` already orders it, window first.
    func showMainWindow(at section: MainWindow.Section) {
        showWindow()
        NotificationCenter.default.post(name: .moeShowSection, object: nil,
                                        userInfo: ["section": section.rawValue])
    }

    @objc private func hideIsland() {
        if island.presentation == .hidden {
            island.show(expanded: false)
        } else {
            island.hide()
        }
    }

    @objc private func openSettings() {
        SettingsWindow.show(conductor: conductor)
    }

    @objc private func newConversation() {
        conductor.newConversation()
        showWindow()
    }

    @objc private func toggleAlwaysListening() {
        let on = !conductor.alwaysListening
        conductor.setAlwaysListening(on)
        listeningItem?.state = on ? .on : .off
        if on { island.reveal() }
    }

    /// The one permission Moe asks for outside a screen the user opened, and
    /// only ever once per launch. Its words come from PermissionGuide so they
    /// match Settings › Permissions and the onboarding screen exactly.
    ///
    /// Never during onboarding: screen 4 already explains this in place, and
    /// a modal over the welcome window is the opposite of one thing at a time
    /// (PRODUCT.md §8.4).
    private func promptForAccessibility() {
        guard Onboarding.done else { return }
        let g = PermissionGuide.accessibility
        showWindow()
        Notice.show(over: window,
                    title: "Let Alfie notice the talk key",
                    body: "\(g.what)\n\n\(g.ifDeclined)",
                    detail: g.steps,
                    confirm: "Open Accessibility settings") { confirmed in
            guard confirmed else { return }
            PushToTalk.requestAccessibility()
            if let url = g.settingsURL { NSWorkspace.shared.open(url) }
        }
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "Alfie"
        alert.informativeText = """
        A personal assistant that runs on this Mac.

        Speech in and out is on-device (Parakeet and Kokoro on the Neural Engine). \
        Thinking runs through Hermes Agent on this Mac, which drives Claude Code \
        on your Claude subscription. Your memory lives in \(Config.homeDir.path) and \
        ~/.hermes as plain markdown you can read and edit.

        Press \(HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)) to talk. ⌘Q to quit.

        Alfie is a fork of Memoe (github.com/memoe-app/memoe) and is not \
        affiliated with or endorsed by Memoe.
        """
        alert.runModal()
    }
}
