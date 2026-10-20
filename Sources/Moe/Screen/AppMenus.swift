import AppKit
import ApplicationServices
import Foundation
import MoeBrain

/// Walking an app's menu bar over the Accessibility API.
///
/// The counterpart to `computer_use invoke_menu`, which can fire any menu item
/// by exact path but has no way to discover one. See `MenuMap` for why that
/// gap matters, and for everything here that can be tested without a running
/// app.
///
/// Deliberately not part of the `computer_use` tool: enumerating menus needs
/// no driver, no screenshot and no window, and reads nothing but labels. It is
/// the cheapest question in this whole area and should not sit behind the
/// most expensive machinery.
enum AppMenus {

    /// Deliberately not cached. Measured warm on this Mac: Finder 0.06 s (174
    /// items), Chrome 0.31 s (214), Notes 0.19 s (214) — cheap enough that a
    /// cache would buy little. The stronger reason is that it would buy
    /// something false: whether an item is enabled depends on what is
    /// selected right now, so a cached map would freeze "disabled" into a lie
    /// and answer "why did nothing happen" wrongly. Walk it live.
    ///
    /// Budgets. A menu bar is small compared to a window's tree, but Electron
    /// apps and anything with a long "Recent Items" list can still surprise
    /// you, and this runs while someone is waiting.
    static let maxItems = 600
    static let maxDepth = 6
    static let budget: TimeInterval = 4.0
    /// Per-AX-call ceiling. The system default is seconds long; a menu bar
    /// that needs that is a menu bar we should report as unread, not wait for.
    static let perCallTimeout: TimeInterval = 0.75

    /// Every invocable item in `app`'s menu bar.
    ///
    /// Submenus are followed; separators, the Apple menu, and items with no
    /// title are skipped. Disabled items are kept — see `MenuMap.Item`.
    /// What a walk actually produced, including the ways it can be partial.
    struct Result {
        var items: [MenuMap.Item] = []
        /// An AX read failed. The list is not the menu, it is a fragment.
        var readFailed = false
        /// The budget or the item cap stopped the walk early.
        var truncated = false
        /// No menu bar at all — not an app, or an app without one.
        var noMenuBar = false
        var complete: Bool { !readFailed && !truncated && !noMenuBar }
    }

    @MainActor
    static func items(forPID pid: pid_t) -> Result {
        guard AXIsProcessTrusted() else { return Result(readFailed: true) }
        let app = AXUIElementCreateApplication(pid)
        // Without this, one AXUIElementCopyAttributeValue blocked for 1.3-1.5 s
        // on a quiet Mac and the 2 s budget — only checked BETWEEN items —
        // could not interrupt it. A single run took 5.13 s and returned one
        // item. The budget is only a bound if each call is bounded.
        AXUIElementSetMessagingTimeout(app, Float(perCallTimeout))
        guard let bar = element(of: app, kAXMenuBarAttribute) else {
            return Result(noMenuBar: true)
        }

        var r = Result()
        let deadline = Date().addingTimeInterval(budget)
        let (tops, failed) = children(of: bar)
        r.readFailed = failed
        for top in tops {
            guard let title = string(of: top, kAXTitleAttribute),
                  !MenuMap.isNoise(title) else { continue }
            walk(top, path: [title], into: &r, depth: 1, deadline: deadline)
            if r.items.count >= maxItems || Date() >= deadline {
                r.truncated = true
                break
            }
        }
        return r
    }

    /// Resolve a name — app name, bundle id, or "frontmost" — to a pid.
    @MainActor
    static func pid(for name: String) -> pid_t? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty || wanted.lowercased() == "frontmost" {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let n = pid_t(wanted) { return n }
        let running = NSWorkspace.shared.runningApplications
        // Exact bundle id, then exact name, then a case-insensitive contains —
        // in that order, so asking for "Code" cannot land on "Visual Studio
        // Code" while an app literally called Code is running.
        // The substring rung searches ONLY apps with a normal activation
        // policy. runningApplications is mostly invisible daemons in launch
        // order, so "e" resolved to universalaccessd and "o" to loginwindow —
        // both of which then answered "no menu items matched", which reads as
        // a fact about the app the person asked for.
        return running.first { $0.bundleIdentifier == wanted }?.processIdentifier
            ?? running.first { $0.localizedName == wanted }?.processIdentifier
            ?? running.first {
                $0.activationPolicy == .regular
                    && ($0.localizedName ?? "").localizedCaseInsensitiveContains(wanted)
            }?.processIdentifier
    }

    /// The app's own name, for saying which one was actually read.
    @MainActor
    static func name(forPID pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// Whether the app is frontmost, which decides what "(disabled)" means.
    @MainActor
    static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: - Walking

    @MainActor
    private static func walk(_ node: AXUIElement, path: [String],
                             into out: inout Result, depth: Int,
                             deadline: Date) {
        guard depth <= maxDepth else { return }
        if out.items.count >= maxItems || Date() >= deadline {
            out.truncated = true
            return
        }
        // A menu-bar item owns one AXMenu child; that menu owns the items.
        let (menus, menusFailed) = children(of: node)
        if menusFailed { out.readFailed = true }
        for menu in menus {
            let (entries, entriesFailed) = children(of: menu)
            if entriesFailed { out.readFailed = true }
            for item in entries {
                if out.items.count >= maxItems || Date() >= deadline {
                    out.truncated = true
                    return
                }
                guard let title = string(of: item, kAXTitleAttribute),
                      !MenuMap.isNoise(title) else { continue }
                let itemPath = path + [title]
                let (kids, kidsFailed) = children(of: item)
                if kidsFailed { out.readFailed = true }
                if kids.isEmpty {
                    out.items.append(MenuMap.Item(
                        path: itemPath,
                        shortcut: MenuMap.shortcut(
                            key: string(of: item, "AXMenuItemCmdChar"),
                            modifiers: int(of: item, "AXMenuItemCmdModifiers"),
                            virtualKey: int(of: item, "AXMenuItemCmdVirtualKey")),
                        enabled: bool(of: item, kAXEnabledAttribute) ?? true))
                } else {
                    // A submenu. Its parent is a container, not an invocable
                    // item, so it is not emitted on its own.
                    walk(item, path: itemPath, into: &out,
                         depth: depth + 1, deadline: deadline)
                }
            }
        }
    }

    // MARK: - AX accessors

    @MainActor
    private static func element(of parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    /// Children, and whether the read itself failed.
    ///
    /// The distinction is the whole point. Collapsing every non-success into
    /// `[]` made "the app was busy" and "this menu is empty" the same value,
    /// and the CLI then printed a partial list — or "no menu items matched" —
    /// with exit 0. Reproduced against Preview: three runs in a row answered
    /// "no menu items matched print" while `File > Print… [⌘P]` was plainly
    /// there. The model is told to reach for this first in an unknown app, so
    /// that is the worst possible wrong answer: a confident absence.
    ///
    /// `kAXErrorCannotComplete` (-25204) is the one seen under load.
    @MainActor
    private static func children(of element: AXUIElement) -> (items: [AXUIElement], failed: Bool) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
        if err == .noValue || err == .attributeUnsupported { return ([], false) }
        guard err == .success else { return ([], true) }
        return (ref as? [AXUIElement] ?? [], false)
    }

    @MainActor
    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        guard let text = ref as? String, !text.isEmpty else { return nil }
        return text
    }

    @MainActor
    private static func int(of element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    @MainActor
    private static func bool(of element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    // MARK: - CLI

    /// `Moe --app-menus <app|bundle id|pid|frontmost> [query] [--json]`
    @MainActor
    static func main(_ args: ArraySlice<String>) -> Never {
        var rest = Array(args)
        let json = rest.contains("--json")
        rest.removeAll { $0 == "--json" }
        let target = rest.first ?? "frontmost"
        let query = rest.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        guard AXIsProcessTrusted() else {
            FileHandle.standardError.write(Data(
                ("needs-setup: Accessibility is not granted, so menus cannot be read. "
                 + "System Settings › Privacy & Security › Accessibility.\n").utf8))
            exit(2)
        }
        guard let pid = pid(for: target) else {
            FileHandle.standardError.write(Data(
                "no running app matched \(target.isEmpty ? "frontmost" : target)\n".utf8))
            exit(2)
        }
        let app = name(forPID: pid)
        let result = items(forPID: pid)

        // An app with no menu bar is not the same as an app with no matching
        // item, and neither is a failed read. A pid that is not an app used to
        // print "no menu items matched" and exit 0.
        if result.noMenuBar {
            FileHandle.standardError.write(Data(
                "\(app) (pid \(pid)) has no menu bar — not an app, or not one with menus\n".utf8))
            exit(2)
        }
        if result.readFailed && result.items.isEmpty {
            FileHandle.standardError.write(Data(
                ("could not read \(app)'s menus (the accessibility read failed; "
                 + "the app may be busy or starting). Try again.\n").utf8))
            exit(2)
        }

        var found = result.items
        if !query.isEmpty { found = MenuMap.search(found, for: query) }

        if json {
            var payload: [String: Any] = [
                "app": app, "pid": Int(pid),
                "frontmost": isFrontmost(pid),
                "complete": result.complete,
                "items": found.map { item -> [String: Any] in
                    var o: [String: Any] = ["path": item.path, "enabled": item.enabled]
                    if let s = item.shortcut { o["shortcut"] = s }
                    // Ambiguity is counted over the WHOLE listing, not the
                    // search subset — see MenuMap.render.
                    if let n = MenuMap.ambiguousPaths(result.items)[
                        item.path.joined(separator: " > ")] {
                        o["ambiguous"] = n
                    }
                    return o
                },
            ]
            if result.readFailed { payload["partial_reason"] = "accessibility read failed" }
            else if result.truncated { payload["partial_reason"] = "hit the item or time budget" }
            let data = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.prettyPrinted, .sortedKeys])
            print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
            exit(result.complete ? 0 : 1)
        }

        // Name the app that was actually read: a wrong resolution otherwise
        // looks exactly like an empty menu.
        print("\(app) (pid \(pid))"
              + (isFrontmost(pid) ? "" : " — not frontmost, so most items show as disabled"
                 + " even though they would work once it is focused"))
        if !result.complete {
            print(result.readFailed
                  ? "  ⚠︎ PARTIAL: an accessibility read failed; items may be missing"
                  : "  ⚠︎ PARTIAL: hit the item or time budget; items may be missing")
        }
        if found.isEmpty {
            print(query.isEmpty ? "no menu items" : "no menu items matched \(query)")
        } else {
            print(MenuMap.render(found, ambiguityFrom: result.items))
        }
        exit(result.complete ? 0 : 1)
    }
}
