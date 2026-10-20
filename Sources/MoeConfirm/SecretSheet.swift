import MoeDesign
import SwiftUI

/// The little window a person types a password or a sign-in code into
/// (SecretMain.swift; the contract is MoeDesign/SecretPrompt.swift).
///
/// The same paper, ink and periwinkle as the send card, so it is
/// recognisably Moe's — the one thing a person has to go on when a window
/// asks for a password. The site is the loudest thing on it, for the same
/// reason the recipient is the loudest thing on the send card: it is the one
/// fact that decides whether typing here is fine or a disaster, and it comes
/// from the request's origin, never from anything a page or a model wrote.
struct SecretSheet: View {
    let request: SecretRequest
    let onSave: ([SecretRequest.Field: String]) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var password: String
    @State private var code: String
    @FocusState private var focus: SecretRequest.Field?

    @Environment(\.colorScheme) private var scheme

    init(request: SecretRequest,
         onSave: @escaping ([SecretRequest.Field: String]) -> Void,
         onCancel: @escaping () -> Void,
         preview: String = "") {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _username = State(initialValue: request.username)
        // `--snapshot` only: what is in the masked box, so a picture of the
        // window shows it as a person sees it after typing. Never set when
        // the window is on screen.
        _password = State(initialValue: preview)
        _code = State(initialValue: preview.isEmpty ? "" : "482913")
    }

    private var values: [SecretRequest.Field: String] {
        [.username: username, .password: password, .code: code]
    }

    private var ready: Bool { request.canSubmit(values) }

    private func submit() {
        guard ready else { return }
        onSave(values)
    }

    /// The first box with nothing in it: the password when the username came
    /// prefilled, the username otherwise.
    private var firstEmpty: SecretRequest.Field? {
        request.fields.first { (values[$0] ?? "").isEmpty } ?? request.fields.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .overlay(WindowDragStrip())
            Rectangle().fill(Theme.rule).frame(height: Theme.Stroke.hair)
            fieldsBlock
            Rectangle().fill(Theme.rule).frame(height: Theme.Stroke.hair)
            footer
        }
        .frame(width: 420)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.edge)
        )
        .onAppear { focus = firstEmpty }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("MOE WILL NOT SEE WHAT YOU TYPE")
                    .font(Theme.Typo.label(9))
                    .tracking(Theme.tracking)
                    .foregroundStyle(Theme.ink3)
            }
            Text(request.headline)
                .font(Theme.Typo.heading(22))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(request.explanation)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if request.siteHasForeignLetters {
                Text("This address uses letters from another alphabet. Check it is the site you meant before you type.")
                    .font(Theme.Typo.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.top, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The boxes

    private var fieldsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            if !request.label.isEmpty || !request.message.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !request.label.isEmpty {
                        Text(request.label)
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    if !request.message.isEmpty {
                        Text(request.message)
                            .font(Theme.Typo.ui(12))
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(request.fields, id: \.self) { field in
                box(field)
            }
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunk)
    }

    private func binding(_ field: SecretRequest.Field) -> Binding<String> {
        switch field {
        case .username: return $username
        case .password: return $password
        case .code: return $code
        }
    }

    @ViewBuilder
    private func box(_ field: SecretRequest.Field) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(request.title(of: field).uppercased())
                .font(Theme.Typo.label(9))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            Group {
                // SecureField is an NSSecureTextField: masked, never copied
                // out, and it turns on Secure Event Input while it has the
                // keyboard, so no other app on the Mac can read the keys.
                if field.isSecret {
                    SecureField("", text: binding(field))
                } else {
                    TextField("", text: binding(field))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
            .font(field == .code ? Theme.Typo.data(16) : Theme.Typo.ui(14))
            .foregroundStyle(Theme.ink)
            .focused($focus, equals: field)
            .onSubmit(submit)
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, Theme.Space.small)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(focus == field ? Theme.accent : Theme.rule,
                                          lineWidth: Theme.Stroke.hair)
                    )
            )
        }
    }

    // MARK: - The decision

    private var footer: some View {
        HStack(spacing: Theme.Space.cosy) {
            Button(action: onCancel) {
                HStack(spacing: Theme.Space.snug) {
                    Text("Cancel")
                        .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                    Text("esc")
                        .font(Theme.Typo.data(10))
                        .opacity(0.75)
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, Theme.Space.roomy)
                .padding(.vertical, Theme.Space.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: submit) {
                HStack(spacing: Theme.Space.snug) {
                    Text(request.kind == .code ? "Enter code" : request.kind == .unlock ? "Unlock" : "Save")
                        .font(Theme.Typo.ui(13, weight: Theme.weight(.semibold, for: scheme)))
                    Text("↩")
                        .font(Theme.Typo.ui(11))
                        .opacity(0.7)
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, Theme.Space.roomy)
                .padding(.vertical, Theme.Space.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .fill(Theme.accent)
                )
                .opacity(ready ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            // Return saves. Unlike the send card, nothing leaves the Mac on
            // this button — it hands what the person typed to Moe's vault —
            // so the key people press when they finish typing is the one
            // that finishes.
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.wide)
        .padding(.vertical, Theme.Space.cosy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
