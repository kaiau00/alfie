import Testing
@testable import MoeBrain

/// Every tool name here was taken from `~/.moe/logs/moe.log`. Before this,
/// all twenty MCP tool calls in that log were logged `· not spoken` — Moe was
/// silent for the whole two-minute stretch in which it fetched an email and
/// replied to it, because Composio names actions `TOOLKIT_ACTION` and the
/// switch was written against Moe's own names.
struct SpokenStepToolkitTests {

    private func phrase(_ tool: String) -> String? {
        SpokenStep.phrase(tool: tool, label: tool)
    }

    // MARK: - The calls that were silent

    @Test func fetchingMailNowSaysSo() {
        #expect(phrase("mcp__composio__GMAIL_FETCH_EMAILS") == "Going through your mail")
        #expect(phrase("mcp__composio__GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID") == "Going through your mail")
    }

    @Test func replyingIsAnUnsentSend() {
        // Never "sending": the send gate may still stop and ask, and saying
        // "sending that" while a dialog waits would be a lie.
        #expect(phrase("mcp__composio__GMAIL_REPLY_TO_THREAD") == "Getting that ready to send")
    }

    @Test func otherToolkitsComeForFree() {
        #expect(phrase("mcp__composio__GOOGLECALENDAR_FIND_EVENT") == "Going through your calendar")
        #expect(phrase("mcp__composio__GOOGLEDRIVE_LIST_FILES") == "Going through your Drive")
        #expect(phrase("mcp__composio__SLACK_SEARCH_MESSAGES") == "Going through Slack")
        #expect(phrase("mcp__composio__NOTION_CREATE_PAGE") == "Getting that ready to send")
    }

    // MARK: - What must stay silent

    /// Composio's own plumbing is real work, but not work the person asked
    /// for. Narrating it is how "Moe is being weird" starts.
    @Test func composioPlumbingStaysSilent() {
        #expect(phrase("mcp__composio__COMPOSIO_SEARCH_TOOLS") == nil)
        #expect(phrase("mcp__composio__COMPOSIO_GET_TOOL_SCHEMAS") == nil)
        #expect(phrase("mcp__composio__COMPOSIO_MULTI_EXECUTE_TOOL") == nil)
    }

    /// An action that is neither plainly a read nor plainly a send says
    /// nothing. "Going through your mail" for something that deletes it
    /// would be worse than silence.
    @Test func anUnrecognisedActionStaysSilent() {
        #expect(phrase("mcp__composio__GMAIL_DELETE_MESSAGE") == nil)
        #expect(phrase("mcp__composio__GMAIL_TRASH_THREAD") == nil)
    }

    /// A toolkit Moe has no honest name for says nothing rather than
    /// guessing one.
    @Test func anUnknownToolkitStaysSilent() {
        #expect(phrase("mcp__composio__SOMEVENDOR_FETCH_THINGS") == nil)
    }

    @Test func aBareIdentifierIsStillNotASentence() {
        #expect(phrase("some_unknown_tool") == nil)
        #expect(phrase("mcp__whatever__ToolSearch") == nil)
    }

    // MARK: - Moe's own tools are unchanged

    @Test func moesOwnNamesStillWork() {
        #expect(phrase("gmail_pull") == "Going through your mail")
        #expect(phrase("mcp__moe__gmail_send") == "Getting that ready to send")
        #expect(phrase("web_search") == "Searching the web")
    }
}
