import SwiftUI
import AppKit

/// Modal catalog of recommended Shortcuts the user can install. Each row
/// shows what the shortcut does, whether it's already installed, and an
/// Install button that either:
///   • opens an iCloud share link (one click in Shortcuts.app to import), or
///   • opens Shortcuts.app to a blank shortcut and shows the recipe inline,
///     since macOS doesn't let apps create shortcuts silently.
struct StarterPackSheet: View {
    let installed: [String]
    var onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var openRecipeFor: StarterShortcut?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(StarterShortcuts.all) { item in
                        row(item)
                        if item.id != StarterShortcuts.all.last?.id {
                            Divider()
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .sheet(item: $openRecipeFor) { item in
            RecipeSheet(item: item) {
                openRecipeFor = nil
            }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Starter Shortcuts")
                .font(.system(size: 17, weight: .semibold))
            Text("These run when a focus session starts or ends. macOS won't let any app install Shortcuts silently — each one takes ~30s the first time.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Open Shortcuts app") {
                NSWorkspace.shared.open(URL(string: "shortcuts://")!)
            }
            Spacer()
            Button("Done") {
                dismiss()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Row

    private func row(_ item: StarterShortcut) -> some View {
        let isInstalled = installed.contains(item.shortcutName)
        return HStack(alignment: .top, spacing: 12) {
            roleBadge(item.role)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                    if isInstalled {
                        Text("Installed")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Theme.focus)
                            .background(Theme.focusTint, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(item.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Will be saved as “\(item.shortcutName)”.")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button(isInstalled ? "Recipe" : "Install") {
                install(item)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func roleBadge(_ role: StarterShortcut.Role) -> some View {
        let label = role == .start ? "START" : "END"
        let color: Color = role == .start ? Theme.focus : Color.secondary
        return Text(label)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .frame(width: 46, alignment: .center)
            .padding(.top, 2)
    }

    // MARK: - Install action

    private func install(_ item: StarterShortcut) {
        if let url = item.iCloudURL {
            // One-click import path — opens the Shortcuts.app preview.
            NSWorkspace.shared.open(url)
        } else {
            // No iCloud link yet — show the recipe inline + open Shortcuts.app
            // so the user can paste actions in.
            openRecipeFor = item
        }
    }
}

/// Modal that walks the user through assembling a shortcut by hand. Shown when
/// a starter doesn't have an iCloud share URL configured yet.
private struct RecipeSheet: View {
    let item: StarterShortcut
    var onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.title)
                .font(.system(size: 17, weight: .semibold))

            Text("In Shortcuts.app, create a new shortcut with these actions, then name it:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(item.shortcutName)
                    .font(.system(size: 13).monospacedDigit())
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.shortcutName, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy name")
            }
            .padding(8)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))

            Text("Actions")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(item.recipe.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("Open Shortcuts.app") {
                    NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                }
                Spacer()
                Button("Done") { dismiss(); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
