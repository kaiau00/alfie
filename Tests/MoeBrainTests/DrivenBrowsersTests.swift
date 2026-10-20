import Foundation
import Testing
@testable import MoeBrain

/// The sweep that runs when Moe stops the gateway must find the browser Hermes
/// drives and nothing else on the Mac.
struct DrivenBrowsersTests {

    static let home = "/Users/x/Library/Application Support/Moe/hermes"

    /// A `ps -axo pid=,command=` table shaped like the real one on 2026-09-20:
    /// the person's Chrome (no user-data-dir), a driven Chrome for Testing on
    /// the copy with its helper processes, a driven browser under a different
    /// home, and an unrelated Chrome that happens to name a user-data-dir.
    static let table = """
      19815 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      19940 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/153/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU) --type=gpu-process
      17867 /Users/x/.agent-browser/browsers/chrome-153.0.8010.47/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --user-data-dir=\(home)/browser-profile/chrome --remote-debugging-port=0 --headless=new --use-mock-keychain
      17870 /Users/x/.agent-browser/browsers/chrome-153.0.8010.47/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome for Testing Framework.framework/Versions/153/Helpers/Google Chrome for Testing Helper (Renderer).app/Contents/MacOS/Google Chrome for Testing Helper (Renderer) --type=renderer --user-data-dir=\(home)/browser-profile/chrome
      22001 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/x/other-home/browser-profile/chrome --headless=new
      22002 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/Users/x/Documents/scratch --headless=new
      96444 /Users/x/.hermes/hermes-agent/.venv/bin/python /Users/x/.local/bin/hermes gateway --accept-hooks run
    """

    @Test func findsOnlyTheDrivenBrowserProcess() {
        #expect(DrivenBrowsers.pids(inProcessTable: Self.table, hermesHome: Self.home) == [17867])
    }

    @Test func thePersonsBrowserNeverMatches() {
        let onlyTheirs = """
          19815 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          20001 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=9222
        """
        #expect(DrivenBrowsers.pids(inProcessTable: onlyTheirs, hermesHome: Self.home).isEmpty)
    }

    @Test func aTrailingSlashOnTheHomeIsTheSameHome() {
        #expect(DrivenBrowsers.pids(inProcessTable: Self.table, hermesHome: Self.home + "/") == [17867])
    }

    @Test func helpersAreLeftToTheirBrowser() {
        let helperOnly = "  17870 /x/Google Chrome for Testing Helper (Renderer) --type=renderer --user-data-dir=\(Self.home)/browser-profile/chrome\n"
        #expect(DrivenBrowsers.pids(inProcessTable: helperOnly, hermesHome: Self.home).isEmpty)
    }

    @Test func anEmptyTableFindsNothing() {
        #expect(DrivenBrowsers.pids(inProcessTable: "", hermesHome: Self.home).isEmpty)
    }
}
