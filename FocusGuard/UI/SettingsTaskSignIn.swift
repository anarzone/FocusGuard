import AppKit
import SwiftUI

// Settings › Integrations › Tasks as session goals: signing in to GitHub and
// Linear, under their switches, once their apps are registered. "Use a token
// instead" goes back to the token field, for companies that block third-party
// apps.

/// A source's Connect row: what it does, or what went wrong, and the button.
private struct SignInOffer: View {
    let title: String
    let detail: String
    var failed = false
    var busy = false
    let connect: () -> Void
    let useToken: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Theme.distraction : Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use a token instead", action: useToken)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small)
            }
            Button("Connect", action: connect)
                .buttonStyle(.capsule(.secondary, height: 26))
                .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// GitHub's device flow: Connect shows a code to enter on GitHub's page, and
/// polling stops with this row. The stack stays put as the phase changes, so
/// only the row going away counts as disappearing.
struct GitHubSignInRow: View {
    let signIn: GitHubSignIn
    /// GitHub ended the last sign-in.
    let signedOut: Bool
    let useToken: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .showing(let code) = signIn.phase {
                codeRow(code)
            } else {
                SignInOffer(title: String(localized: "Connect your GitHub account"), detail: detail, failed: failed,
                            busy: signIn.phase == .asking, connect: {
                                copied = false
                                signIn.start()
                            }, useToken: useToken)
            }
        }
        .onDisappear { signIn.cancel() }
    }

    private var failed: Bool {
        if case .failed = signIn.phase { return true }
        return signedOut
    }

    private var detail: String {
        switch signIn.phase {
        case .asking:              return String(localized: "Asking GitHub for a code…")
        case .failed(.expired):    return String(localized: "That code ran out. Connect to get a new one.")
        case .failed(.unavailable): return String(localized: "GitHub sign-in isn't available right now. Try again, or use a token instead.")
        case .failed(.unreachable): return String(localized: "Couldn't reach \(TaskSource.github.name). Check your connection and try again.")
        default:
            return signedOut
                ? String(localized: "\(TaskSource.github.name) signed FocusGuard out. Connect again")
                : String(localized: "Opens GitHub to sign in. FocusGuard can reach your issues, not your code. Kept in your Keychain.")
        }
    }

    private func codeRow(_ code: GitHubDeviceFlow.Code) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enter this code on GitHub")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                Text(code.userCode)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                Text("Waiting for you to finish in your browser")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open GitHub") { signIn.openURL(code.pageURL) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                copied = true
            }
            .buttonStyle(.capsule(.secondary, height: 26))
            Button("Cancel") { signIn.cancel() }
                .buttonStyle(.capsule(.secondary, height: 26))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Linear's sign-in: Connect opens the browser, which comes back to the app.
/// A wait outlives this row, since the user may close Settings to go to the
/// browser; the listener gives up by itself.
struct LinearSignInRow: View {
    let signIn: LinearSignIn
    /// Linear ended the last sign-in.
    let signedOut: Bool
    let useToken: () -> Void

    var body: some View {
        if signIn.phase == .waiting {
            HStack(spacing: 12) {
                Text("Finish in your browser, then come back here")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView().controlSize(.small)
                Button("Cancel") { signIn.cancel() }
                    .buttonStyle(.capsule(.secondary, height: 26))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        } else {
            SignInOffer(title: String(localized: "Connect your Linear account"), detail: detail,
                        failed: signIn.phase == .failed || signedOut, connect: { signIn.start() }, useToken: useToken)
        }
    }

    private var detail: String {
        if signIn.phase == .failed { return String(localized: "\(TaskSource.linear.name) didn't connect. Try again") }
        return signedOut
            ? String(localized: "\(TaskSource.linear.name) signed FocusGuard out. Connect again")
            : String(localized: "Opens Linear to sign in. FocusGuard reads your issues and moves the ones you finish. Kept in your Keychain.")
    }
}

/// Under a GitHub sign-in that reaches no repository, which is what it gets
/// until the app is installed. Looks again whenever the user comes back from
/// the browser, and reads the issues once it can see some.
struct GitHubAccessRow: View {
    let integrations: IntegrationsCoordinator
    let installURL: URL?

    @State private var access = RepositoryAccess.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if access == .noRepositories {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("FocusGuard can't see any repositories yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                    Text("Its GitHub app has to be installed on them first")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let installURL {
                        Link("Install on your repositories", destination: installURL)
                            .font(.system(size: 11))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        let before = access
        let now = await integrations.githubRepositoryAccess()
        access = now
        if before == .noRepositories && now == .reachable { await integrations.refreshTasks() }
    }
}
