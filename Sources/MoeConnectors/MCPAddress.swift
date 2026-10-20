import Foundation

/// What `connect.sh --url <name> <url>` will accept, decided before the
/// script runs.
///
/// The rules live in the shell (`valid_name()` and the `case` on the URL) and
/// are mirrored here so the Add-an-MCP-server sheet can refuse with the cursor
/// still in the field, instead of spawning a process to be told no. Pure
/// Foundation, so it can be tested without the app.
///
/// Keep in step with `scripts/connect.sh`.
public enum MCPAddress {
    /// `valid_name()`: letters, digits, `_` and `-`, and never leading `-` or `.`.
    public static func isValidName(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("-"), !s.hasPrefix(".") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// https anywhere, plain http only back to this Mac.
    public static func isValidAddress(_ s: String) -> Bool {
        s.hasPrefix("https://") || s.hasPrefix("http://127.0.0.1") || s.hasPrefix("http://localhost")
    }

    /// A first guess at the name from the address, so the common case is one
    /// field: `https://venza.example.com/mcp/lean` → `venza`. Empty when the
    /// address yields nothing usable — the caller then leaves the field alone
    /// rather than filling it with something wrong.
    public static func suggestedName(from address: String) -> String {
        guard let host = URL(string: address)?.host, !host.isEmpty else { return "" }
        let first = host.split(separator: ".").first.map(String.init) ?? ""
        let cleaned = first.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            .lowercased()
        return isValidName(cleaned) ? cleaned : ""
    }
}
