import SwiftUI

struct OnboardingView: View {
    @Bindable var permissions: PermissionsCoordinator
    var onComplete: () -> Void

    private var grantedCount: Int {
        var n = 0
        if permissions.notifications == .granted { n += 1 }
        if permissions.accessibility == .granted { n += 1 }
        if permissions.screenRecording == .granted { n += 1 }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Welcome to FocusGuard").font(.title2).bold()
                        Spacer()
                        Text("\(grantedCount) of 3")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("FocusGuard needs three permissions to detect distractions and refocus you.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    onComplete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            // Linear progress bar
            ProgressView(value: Double(grantedCount) / 3.0)
                .progressViewStyle(.linear)
                .tint(Theme.focus)

            permissionRow(
                title: "Notifications",
                description: "Show motivational reminders when you drift.",
                status: permissions.notifications,
                action: { Task { await permissions.requestNotifications() } }
            )
            permissionRow(
                title: "Accessibility",
                description: "Read the active browser tab to detect distraction sites.",
                status: permissions.accessibility,
                action: { permissions.requestAccessibility() }
            )
            permissionRow(
                title: "Screen Recording",
                description: "Read window titles for finer-grained tracking.",
                status: permissions.screenRecording,
                action: { permissions.requestScreenRecording() }
            )

            Divider()

            HStack {
                Button("Refresh") { Task { await permissions.refresh() } }
                Spacer()
                Button("Close") { onComplete() }
                Button(permissions.allGranted ? "Continue" : "Skip for now") {
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await permissions.refresh() }
        .task {
            // Poll while visible so a grant in System Settings is picked up
            // without needing to click Refresh.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await permissions.refresh()
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        status: PermissionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(status)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(status == .granted ? "Granted" : "Grant") { action() }
                .disabled(status == .granted)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .notDetermined, .unknown:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}
