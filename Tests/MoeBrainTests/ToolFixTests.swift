import Foundation
import Testing
@testable import MoeBrain

/// docs/FIXABLE-FAILURES.md slice 3: reading the `fix` a Hermes tool-progress
/// frame carries.
///
/// The frame below is not typed from memory. It is the `completed` event the
/// fork's own api_server wrote in `tests/gateway/test_api_server_fix_frame.py`
/// (fork branch `fixable-app-s3`, run with `MOE_FIX_FRAME_OUT`), after the
/// failure went through the real chain: `fix_error` → the MCP bridge's
/// `to_mcp_content` → the Claude Code child's `tool_result` → `_TurnProjector`
/// → `make_claude_code_event_bridge` → `_on_tool_complete` → SSE.
/// Saved verbatim as Tests/fixtures/fixable/completed-frame.sse.
struct ToolFixTests {

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fixable/completed-frame.sse")
    }

    /// The `data:` payload of the saved SSE event, decoded the way
    /// HermesBrain's `handleEvent` decodes one.
    static func fixtureFrame() throws -> [String: Any] {
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        try #require(lines.first == "event: hermes.tool.progress", "not an SSE tool-progress event: \(lines)")
        let data = try #require(lines.first { $0.hasPrefix("data: ") }).dropFirst(6)
        return try #require(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
    }

    @Test func theForkFrameParses() throws {
        let fix = try #require(ToolFix.parse(progressFrame: try Self.fixtureFrame()))
        #expect(fix.code == .tccAppData)
        #expect(fix.owner == .app)
        #expect(fix.pane == "Privacy_AllFiles")
        #expect(fix.subject == "Google Chrome")
        #expect(fix.retry)
        #expect(fix.extras["path"] == "/Users/x/Library/Application Support/Google/Chrome")
    }

    @Test func aFrameWithoutAFixIsAPlainFinish() throws {
        var frame = try Self.fixtureFrame()
        frame["fix"] = nil
        #expect(ToolFix.parse(progressFrame: frame) == nil)
        frame["fix"] = "tcc_app_data"            // not an object
        #expect(ToolFix.parse(progressFrame: frame) == nil)
    }

    /// A code the app does not know is nothing (made-up codes: every real
    /// one is in `FixCode`, which ToolFixVocabularyTests holds to the pin).
    @Test func anUnknownCodeIsNothing() throws {
        var frame = try Self.fixtureFrame()
        var fix = try #require(frame["fix"] as? [String: Any])
        for code in ["printer_out_of_ink", "ENOENT", "", "TCC_APP_DATA"] {
            fix["code"] = code
            frame["fix"] = fix
            #expect(ToolFix.parse(progressFrame: frame) == nil, "\(code)")
        }
    }

    /// A pane outside the fork's `PANES` is never kept, so it can never be opened.
    @Test func anUnknownPaneIsDropped() {
        let fix = ToolFix.parse(fields: ["code": "tcc_files", "owner": "app", "pane": "Privacy_Everything",
                                         "subject": "Desktop", "retry": true])
        #expect(fix?.code == .tccFiles)
        #expect(fix?.pane == nil)
    }

    @Test func theCodeSpecificFieldsArrive() {
        let driver = ToolFix.parse(fields: ["code": "tcc_driver_accessibility", "owner": "driver",
                                            "pane": "Privacy_Accessibility", "subject": "CuaDriver",
                                            "retry": true, "restart": "driver", "also_pane": "Privacy_ScreenCapture"])
        #expect(driver?.owner == .driver)
        #expect(driver?.restart == "driver")
        #expect(driver?.alsoPane == "Privacy_ScreenCapture")
        let ae = ToolFix.parse(fields: ["code": "tcc_automation", "owner": "app", "pane": "Privacy_Automation",
                                        "subject": "Notes", "retry": true, "consent": "not_asked", "ae_error": -1744])
        #expect(ae?.consent == "not_asked")
        #expect(ae?.extras["ae_error"] == "-1744")
    }
}
