import MoeDesign
import SwiftUI
import MoeConnectors

/// "Add an MCP server" — the way in for a server the catalogue does not
/// know: a company's own, or one nobody has heard of yet.
///
/// It exists because the catalogue is a convenience, not the boundary. Moe
/// is Hermes, so anything Hermes can reach has to be reachable from here
/// too; a person whose work lives behind their own server should not have to
/// find a Terminal to say so.
///
/// Two fields and one choice, because that is all `connect.sh --url` takes.
/// What the server turns out to *contain* is not asked and not curated —
/// whatever tools it carries arrive with it.
struct AddMCPServerSheet: View {
    /// `(name, address, auth)` — auth is the answer `connect.sh` asks for
    /// as `AUTH`: "none" or "oauth".
    var add: (String, String, String) -> Void
    var cancel: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var needsSignIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add a server by address").font(.title3.weight(.semibold))
                Text("Alfie will be able to use everything this server offers, the same as anything else in this list.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Address").font(.caption).foregroundStyle(.secondary)
                    TextField("https://example.com/mcp", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: address) { _, new in
                            if name.isEmpty || name == MCPAddress.suggestedName(from: previousAddress) {
                                name = MCPAddress.suggestedName(from: new)
                            }
                            previousAddress = new
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Call it").font(.caption).foregroundStyle(.secondary)
                    TextField("pulse", text: $name).textFieldStyle(.roundedBorder)
                    Text("Letters, digits, - and _. This is the name you will see it under.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Toggle("This server needs me to sign in", isOn: $needsSignIn)
                    .font(.callout)
                if needsSignIn {
                    Text("Your browser will open once, and Alfie keeps the sign-in from then on.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The same warning connect.sh prints, said where somebody
                // will actually read it: its stdout goes to a log, not a
                // person. Nobody should add one of these without knowing
                // what it can see.
                Label {
                    Text("Nobody has reviewed this server. It sees whatever Alfie hands it, and the words it uses to describe its own tools land in Alfie's thinking. Alfie still asks before sending anything to another person; nothing else about it is checked.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                }

                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A server that wants a key of its own is still a Terminal
                // trip — the engine asks for it on a TTY. Said plainly
                // rather than offered as a button that would hang.
                Text("A server that wants a key instead: run connect.sh --url \(name.isEmpty ? "<name>" : name) \(address.isEmpty ? "<address>" : address) in Terminal.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Add") { add(name, address, needsSignIn ? "oauth" : "none") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(problem != nil || name.isEmpty || address.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    @State private var previousAddress = ""

    /// Nil when the two fields would be accepted. Mirrors `connect.sh`'s own
    /// checks so the refusal happens here, with the cursor still in the
    /// field, rather than as a failed run three seconds later.
    private var problem: String? {
        if !name.isEmpty, !MCPAddress.isValidName(name) {
            return "Names may only use letters, digits, - and _, and may not start with - or a dot."
        }
        if !address.isEmpty, !MCPAddress.isValidAddress(address) {
            return "The address has to be https:// — or http:// on this Mac (localhost)."
        }
        return nil
    }

}
