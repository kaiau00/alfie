import AppKit
import Darwin
import Foundation
import MoeDesign
import SwiftUI

// The secret window: a person types a password or a sign-in code, and Moe
// stores it without seeing it (ticket #17). Same program as the send card —
// same window, same paper, same signature — reached as `moe-secret` (a link
// inside the app, which is what `HERMES_SECRET_PROMPT_CMD` names) or with
// `--secret`. The contract is at the top of MoeDesign/SecretPrompt.swift:
// one JSON object in on stdin, one out on stdout, exit 0 or 1.
//
// What keeps the secret where it belongs:
//   * it is written to stdout once, by `secretAnswer(_:)`, and to nothing else —
//     stderr only ever gets `SecretAnswer.summary`, which names fields, not
//     values;
//   * core dumps are off for this process, so a crash leaves no memory image;
//   * the boxes are SecureFields — masked, not copyable, and Secure Event
//     Input is on while one has the keyboard;
//   * every way out that is not Save — Cancel, Escape, a quit, a signal, the
//     caller going away, five minutes passing — answers `ok: false`.

/// The one exit. Writes the answer whole, then leaves.
func secretAnswer(_ result: SecretAnswer) -> Never {
    FileHandle.standardOutput.write(result.json)
    FileHandle.standardError.write(Data("moe-secret: \(result.summary)\n".utf8))
    exit(result.exitCode)
}

/// A quit is a Cancel, never a Save — and never silence, which would leave
/// Hermes reading an empty stdout.
final class SecretDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        secretAnswer(.declined(.cancelled))
    }
}

/// Keeps the signal sources alive for the life of the process.
private var secretSources: [DispatchSourceProtocol] = []

func runSecretPrompt(arguments: [String]) -> Never {
    // No memory image of this process on disk, crash or not.
    var none = rlimit(rlim_cur: 0, rlim_max: 0)
    setrlimit(RLIMIT_CORE, &none)

    for sig in [SIGTERM, SIGHUP, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { secretAnswer(.declined(.cancelled)) }
        source.resume()
        secretSources.append(source)
    }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    let request: SecretRequest
    switch SecretRequest.parse(data) {
    case .success(let parsed): request = parsed
    case .failure(let problem):
        FileHandle.standardError.write(Data("moe-secret: the request did not parse (\(problem))\n".utf8))
        secretAnswer(.declined(.invalid))
    }
    FileHandle.standardError.write(Data("moe-secret: \(request.logLine)\n".utf8))

    // What was parsed, printed; nothing shown. There is nothing secret in a
    // request, and this is how the words are tested without a window.
    if arguments.contains("--describe") {
        print("headline\t\(request.headline)")
        print("explanation\t\(request.explanation)")
        print("site\t\(request.site)")
        print("fields\t\(request.fields.map(\.rawValue).joined(separator: ","))")
        exit(3)
    }

    // `--snapshot <file.png>`: the window drawn to a picture, never on
    // screen, so it can be looked at without putting it in front of anyone.
    if let at = arguments.firstIndex(of: "--snapshot"), at + 1 < arguments.count {
        let path = arguments[at + 1]
        MainActor.assumeIsolated { snapshotSecretSheet(request, to: path) }
        exit(3)
    }

    // Five minutes, then an answer by itself. And whoever asked going away
    // (the card is re-parented to launchd) is a Cancel: nobody is reading
    // stdout any more.
    let limit = SecretRequest.timeout(environment: ProcessInfo.processInfo.environment)
    let clock = DispatchSource.makeTimerSource(queue: .main)
    clock.schedule(deadline: .now() + limit)
    clock.setEventHandler { secretAnswer(.declined(.timeout)) }
    clock.resume()
    secretSources.append(clock)
    let parent = DispatchSource.makeTimerSource(queue: .main)
    parent.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
    parent.setEventHandler { if getppid() == 1 { secretAnswer(.declined(.cancelled)) } }
    parent.resume()
    secretSources.append(parent)

    // `--wait-test`: everything above — the clock, the signals, the caller
    // going away — with no window, so each way out can be tested on a Mac
    // with a person at it. There are no boxes here, so nothing can answer
    // `ok: true`: it leaves by timing out or being cancelled, or not at all.
    if arguments.contains("--wait-test") { dispatchMain() }

    if CGMainDisplayID() == 0 { secretAnswer(.declined(.unavailable)) }

    let application = NSApplication.shared
    let delegate = SecretDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)

    // ⌘V from a password manager, ⌘A, ⌘Z. No Copy from a SecureField —
    // AppKit refuses that itself — and nothing here can answer the window.
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editItem.submenu = editMenu
    let menu = NSMenu()
    menu.addItem(editItem)
    application.mainMenu = menu

    let sheet = SecretSheet(
        request: request,
        onSave: { values in secretAnswer(request.answer(values)) },
        onCancel: { secretAnswer(.declined(.cancelled)) })
    let hosting = FirstClickHostingView(rootView: sheet)
    let window = ConfirmWindow(contentRect: .zero,
                               styleMask: [.borderless, .fullSizeContentView],
                               backing: .buffered, defer: false)
    window.contentView = hosting
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    // In front when it arrives, like the send card; on every Space, so it is
    // never waiting on a desktop the person has left.
    window.level = .floating
    NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                           object: window, queue: .main) { _ in
        window.level = .normal
    }
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.setContentSize(hosting.fittingSize)
    window.center()
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    application.run()
    secretAnswer(.declined(.cancelled))
}

/// The window, drawn to `<path>.png` and `<path>-dark.png`, in a window
/// that is never ordered on screen. `cacheDisplay` rather than
/// `ImageRenderer`: the text boxes are AppKit controls, which ImageRenderer
/// draws as a placeholder. The password box is shown with dots in it, which
/// is what a person sees once they have typed.
@MainActor
func snapshotSecretSheet(_ request: SecretRequest, to path: String) {
    _ = NSApplication.shared
    for (suffix, name) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        let sheet = SecretSheet(request: request, onSave: { _ in }, onCancel: {},
                                preview: "correct horse").padding(24)
        let hosting = NSHostingView(rootView: sheet)
        hosting.appearance = NSAppearance(named: name)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: name)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let out = (path as NSString).deletingPathExtension + suffix + ".png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print(out)
    }
}
