import SwiftUI

/// Enter a licence key. `Entitlements` checks it through its
/// `LicenceVerifier`; until a licence server exists every key is turned
/// down with the verifier's reason.
struct LicenceSheet: View {
    var entitlements: Entitlements = .shared

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enter your licence key")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("It's in the email you got after buying Pro.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Licence key").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                TextField("FG-XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.windowCard))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(fieldFocused ? Theme.focus.opacity(0.6) : Theme.hairline, lineWidth: fieldFocused ? 2 : 0.5))
                    .onSubmit(activate)
                    .onChange(of: key) { problem = nil }
                    .accessibilityLabel("Licence key")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.destructive)
                } else {
                    Text("Pasting it from the email works too.")
                        .font(.system(size: 11)).foregroundStyle(Theme.bodyText)
                }
            }

            Text("Activating checks the key once, then now and then to keep it current. Nothing about your activity is sent.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(checking ? "Checking…" : "Activate", action: activate)
                    .buttonStyle(.capsule(.primary, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 26, bottom: 22, trailing: 26))
        .frame(width: 470)
        .background(Theme.windowBackground)
        .onAppear { fieldFocused = true }
    }

    private func activate() {
        guard !checking else { return }
        checking = true
        Task {
            let result = await entitlements.activateLicence(key)
            checking = false
            switch result {
            case .valid: dismiss()
            case .invalid(let reason): problem = reason
            }
        }
    }
}
