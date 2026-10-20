import Testing
@testable import MoeConnectors

/// The Add-an-MCP-server sheet refuses what `connect.sh` would refuse.
/// Keep in step with `valid_name()` and the URL `case` in scripts/connect.sh.
///
/// Swift Testing, not XCTest: this project builds with the Command Line
/// Tools, which ship Testing.framework and no XCTest at all, so an `import
/// XCTest` here does not fail this file — it fails the whole test target and
/// takes all 700-odd tests in the package down with it. See the header of
/// scripts/test.sh. Every assertion below is the original one, ported.
@Suite("MCPAddress")
struct MCPAddressTests {

    @Test("names follow connect.sh's rules")
    func namesFollowConnectShRules() {
        #expect(MCPAddress.isValidName("pulse"))
        #expect(MCPAddress.isValidName("my-server_2"))
        #expect(!MCPAddress.isValidName(""))
        #expect(!MCPAddress.isValidName("-lead"))
        #expect(!MCPAddress.isValidName(".hidden"))
        // The shell would treat these as separate words or paths.
        #expect(!MCPAddress.isValidName("two words"))
        #expect(!MCPAddress.isValidName("a/b"))
        #expect(!MCPAddress.isValidName("rm;ls"))
        #expect(!MCPAddress.isValidName("caf\u{e9}"))
    }

    @Test("addresses are HTTPS, or loopback over http")
    func addressesAreHTTPSOrLoopback() {
        #expect(MCPAddress.isValidAddress("https://venza.example.com/mcp/lean"))
        #expect(MCPAddress.isValidAddress("http://localhost:8000/sse"))
        #expect(MCPAddress.isValidAddress("http://127.0.0.1:9000/mcp"))
        // Plain http to anywhere else would send the credential in clear.
        #expect(!MCPAddress.isValidAddress("http://example.com/mcp"))
        #expect(!MCPAddress.isValidAddress("ftp://example.com"))
        #expect(!MCPAddress.isValidAddress(""))
    }

    @Test("a name is suggested from the host")
    func nameIsSuggestedFromTheHost() {
        #expect(MCPAddress.suggestedName(from: "https://venza.example.com/mcp/lean") == "venza")
        #expect(MCPAddress.suggestedName(from: "https://MCP.Example.COM/x") == "mcp")
        #expect(MCPAddress.suggestedName(from: "http://localhost:8000/sse") == "localhost")
    }

    @Test("no suggestion rather than a wrong one")
    func noSuggestionRatherThanAWrongOne() {
        #expect(MCPAddress.suggestedName(from: "") == "")
        #expect(MCPAddress.suggestedName(from: "not a url") == "")
        // A leading dash would be refused by valid_name, so suggest nothing.
        #expect(MCPAddress.suggestedName(from: "https://-odd.example.com/mcp") == "")
    }
}
