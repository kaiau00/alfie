import AppKit
import ApplicationServices
import Foundation
import MoeMeeting

/// The instrument, before the feature: what a meeting window actually says
/// about who is talking.
///
/// Every product that puts real names on a multi-person call gets them from
/// the meeting app rather than from the audio — Wispr Flow and Granola both
/// read the participant tiles and the "speaking" marker through the macOS
/// Accessibility API, and Granola's own documentation is careful to say that
/// this reads interface elements and does not record the screen, the camera
/// or the microphone. Diarization is everybody's fallback, and today it is
/// the only thing Moe has: the 14:00 call on 2026-09-08 came out as `them
/// (speaker 1…7)` while Wispr, on the same call, wrote down five names from
/// the first line.
///
/// **This file does not do that yet.** It is the step before it, and the
/// order is the point. Nothing public documents how Google Meet, Zoom or
/// Teams shape their accessibility trees; a parser written from a guess
/// would be a closed loop of invented constants agreeing with itself, which
/// is exactly how a menu reader in this repo shipped three wrong facts in a
/// row with every unit test passing. So: dump the tree from a real call,
/// check the dump in as a fixture, write the tests against the fixture, and
/// only then write the code.
///
///     Moe --ax-dump-meeting [seconds] [out.json]
///
/// It samples the front meeting app's windows once a second and records
/// every node whose text changed, so a two-minute call produces a record of
/// who the tree said was speaking and when — which is the thing a parser
/// has to be checked against.
enum ActiveSpeakerProbe {

    /// Apps worth dumping: the ones that hold a call. A browser counts,
    /// because Meet is a web page and its tiles are in the web area.
    static func meetingApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return CallApps.match(bundleID: id) != nil
        }
    }

    // MARK: - One node of the tree

    struct Node: Codable, Equatable {
        var depth: Int
        var role: String
        var subrole: String?
        var title: String?
        var value: String?
        var help: String?
        var describedBy: String?
        var identifier: String?
        var selected: Bool?
        /// A tile is a rectangle; a speaking marker is often a sibling that
        /// appears and disappears. Both need geometry to be matched up.
        var frame: [Double]?

        /// Everything a human would read off this node, in one string, for
        /// eyeballing a dump without a JSON viewer.
        var line: String {
            var parts = ["\(String(repeating: "  ", count: depth))\(role)"]
            if let subrole { parts.append("[\(subrole)]") }
            for (k, v) in [("title", title), ("value", value), ("desc", describedBy),
                           ("help", help), ("id", identifier)] {
                if let v, !v.isEmpty { parts.append("\(k)=\u{201C}\(v)\u{201D}") }
            }
            if selected == true { parts.append("SELECTED") }
            return parts.joined(separator: " ")
        }
    }

    struct Sample: Codable {
        var at: Double
        var app: String
        var window: String
        var nodes: [Node]
    }

    // MARK: - Reading it

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        if let n = ref as? NSNumber { return n.stringValue }
        // `AXDescribedBy` and friends come back as arrays of elements; take
        // the text off each one, because that is where Meet puts the name
        // that a screen reader announces.
        if let list = ref as? [AnyObject] {
            let texts = list.compactMap { item -> String? in
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return item as? String }
                let child = unsafeBitCast(item, to: AXUIElement.self)
                return string(child, kAXValueAttribute) ?? string(child, kAXTitleAttribute)
            }
            let joined = texts.joined(separator: " · ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private static func frame(_ element: AXUIElement) -> [Double]? {
        var pRef: CFTypeRef?, sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sRef) == .success,
              let pRef, let sRef else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(pRef, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(sRef, to: AXValue.self), .cgSize, &s) else { return nil }
        return [p.x, p.y, s.width, s.height]
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let list = ref as? [AnyObject] else { return [] }
        return list.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }

    /// The whole tree under `root`, breadth-first, bounded.
    ///
    /// Both bounds are real. A Meet call's web area is tens of thousands of
    /// nodes and every attribute read is a synchronous IPC round trip to the
    /// other application, so an unbounded walk of a busy call takes minutes
    /// and blocks on an app that is doing video. `maxNodes` keeps a sample
    /// to about a second; `deadline` stops a hung app taking the probe with
    /// it.
    static func walk(_ root: AXUIElement, maxNodes: Int = 4000, deadline: Date) -> [Node] {
        var out: [Node] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty, out.count < maxNodes, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            let role = string(element, kAXRoleAttribute) ?? "?"
            let node = Node(depth: depth,
                            role: role,
                            subrole: string(element, kAXSubroleAttribute),
                            title: string(element, kAXTitleAttribute),
                            value: string(element, kAXValueAttribute),
                            help: string(element, kAXHelpAttribute),
                            describedBy: string(element, "AXDescription"),
                            identifier: string(element, kAXIdentifierAttribute),
                            selected: bool(element, kAXSelectedAttribute),
                            frame: frame(element))
            out.append(node)
            for child in children(of: element) { queue.append((child, depth + 1)) }
        }
        return out
    }

    // MARK: - The command

    /// `Moe --ax-dump-meeting [seconds] [out.json]`
    static func run(seconds: Double, out: URL) -> Int32 {
        func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

        guard AXIsProcessTrusted() else {
            say("""
                ax-dump-meeting: Alfie is not trusted for Accessibility, so every window
                reads as empty — which is indistinguishable from a meeting app that
                exposes nothing, and that is the whole question here.

                Turn it on: System Settings › Privacy & Security › Accessibility › Alfie.
                It lets Alfie read what is on a window; it does not record the screen.
                """)
            return 2
        }
        let apps = meetingApps()
        guard !apps.isEmpty else {
            say("ax-dump-meeting: no call app is running. Join the call first, then run this.")
            return 3
        }
        say("ax-dump-meeting: watching \(apps.compactMap(\.localizedName).joined(separator: ", ")) "
            + "for \(Int(seconds)) s")

        var samples: [Sample] = []
        let started = Date()
        var lastSignature = ""
        while Date().timeIntervalSince(started) < seconds {
            for app in apps {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let list = windowsRef as? [AnyObject] else { continue }
                for item in list {
                    guard CFGetTypeID(item) == AXUIElementGetTypeID() else { continue }
                    let window = unsafeBitCast(item, to: AXUIElement.self)
                    let nodes = walk(window, deadline: Date().addingTimeInterval(2))
                    // Only when something a person could read has changed —
                    // a sample a second for an hour is a gigabyte of the
                    // same tree, and the interesting thing is the change.
                    let signature = nodes.map { "\($0.role)|\($0.title ?? "")|\($0.value ?? "")|\($0.describedBy ?? "")" }
                        .joined(separator: "\n")
                    guard signature != lastSignature else { continue }
                    lastSignature = signature
                    samples.append(Sample(at: Date().timeIntervalSince(started),
                                          app: app.bundleIdentifier ?? "?",
                                          window: string(window, kAXTitleAttribute) ?? "",
                                          nodes: nodes))
                    say(String(format: "  [%5.1f s] %@ — %d nodes, tree changed",
                               Date().timeIntervalSince(started), app.localizedName ?? "?", nodes.count))
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(samples).write(to: out)
        } catch {
            say("ax-dump-meeting: could not write \(out.path): \(error)")
            return 4
        }
        say("ax-dump-meeting: \(samples.count) sample(s) → \(out.path)")
        if samples.isEmpty {
            say("""
                Nothing changed and nothing was recorded. Either the call was not up, or
                this app exposes no accessibility tree at all — which is itself the
                answer, and worth knowing before any code is written against one.
                """)
        }
        return 0
    }
}
