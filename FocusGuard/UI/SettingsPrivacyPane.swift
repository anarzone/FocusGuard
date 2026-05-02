import SwiftUI
import SwiftData
import AppKit

struct SettingsPrivacyPane: View {
    @Bindable var appState: AppState

    @State private var optOuts: [TitleOptOut] = []
    @State private var newBundleId: String = ""
    @State private var showingDeleteConfirm = false
    @State private var stats: DBStats = .zero
    @AppStorage("retentionDays") private var retentionDays: Int = 365

    private var context: ModelContext { appState.container.mainContext }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Privacy")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("All FocusGuard data lives on this Mac. Nothing is sent to a server.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                sectionHeader("Title opt-out list", topPad: 24)
                Text("Window titles are NOT recorded for these apps. Useful for Mail, Messages, password managers — anywhere the title can leak private content.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                groupCard {
                    if optOuts.isEmpty {
                        Text("No apps opted out.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                    } else {
                        ForEach(optOuts, id: \.bundleIdentifier) { entry in
                            optOutRow(entry)
                            if entry.bundleIdentifier != optOuts.last?.bundleIdentifier {
                                Rectangle().fill(Theme.separator).frame(height: 0.5)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("com.example.app", text: $newBundleId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12).monospacedDigit())
                        .frame(maxWidth: 260)
                    Button("Add") { addNew() }
                        .disabled(newBundleId.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
                .padding(.top, 8)

                sectionHeader("Retention")
                groupCard {
                    row(
                        title: "Keep history for",
                        help: "Older sessions and activity events are pruned automatically each day."
                    ) {
                        Picker("", selection: $retentionDays) {
                            ForEach(RetentionPolicy.choices, id: \.days) { choice in
                                Text(choice.label).tag(choice.days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    row(
                        title: "Prune now",
                        help: "Apply the retention policy immediately."
                    ) {
                        Button("Prune") {
                            let count = RetentionPolicy.prune(context: context)
                            Persistence.logger.info("manual prune removed \(count) rows")
                            reload()
                        }
                    }
                }

                sectionHeader("Your data")
                groupCard {
                    row(
                        title: "Stored on this Mac",
                        help: "\(stats.sessionCount) sessions · \(stats.eventCount) activity events · \(stats.fileSizeText)"
                    ) {
                        Button("Reveal in Finder") { revealInFinder() }
                    }
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    row(
                        title: "Delete all data",
                        help: "Removes every session, activity event, and rule. Cannot be undone."
                    ) {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Text("Delete…")
                        }
                        .tint(Theme.distraction)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        .task {
            // Refresh DB stats every 5s while the pane is visible, so the
            // counts stay current as the tracker accumulates events.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                stats = DBStats.compute(context: context)
            }
        }
        .alert("Delete all FocusGuard data?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("Every session, activity event, and rule will be removed. This cannot be undone.")
        }
    }

    // MARK: - Sub-views

    private func optOutRow(_ entry: TitleOptOut) -> some View {
        HStack(spacing: 10) {
            AppGlyph(kind: AppGlyph.kind(forBundleId: entry.bundleIdentifier), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.bundleIdentifier)
                    .font(.system(size: 12).monospacedDigit())
                if let reason = entry.reason {
                    Text(reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                context.delete(entry)
                Persistence.save(context)
                appState.optOutCache.refresh()
                reload()
            } label: {
                Text("Remove")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, topPad: CGFloat = 24) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.top, topPad)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }

    @ViewBuilder
    private func row<Right: View>(
        title: String,
        help: String? = nil,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let help {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            right()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func addNew() {
        let trimmed = newBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Skip duplicates
        if optOuts.contains(where: { $0.bundleIdentifier == trimmed }) { return }
        context.insert(TitleOptOut(bundleIdentifier: trimmed))
        Persistence.save(context)
        appState.optOutCache.refresh()
        newBundleId = ""
        reload()
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/default.store")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteAllData() {
        // Stop tracking first so no new rows land mid-delete.
        appState.tracker.stop()
        defer { appState.tracker.start() }

        try? context.delete(model: ActivityEvent.self)
        try? context.delete(model: Session.self)
        try? context.delete(model: AppRule.self)
        Persistence.save(context)

        // Re-seed defaults so the app remains functional
        DefaultRules.seedIfNeeded(in: context)
        appState.classifier.invalidate()
        reload()
    }

    private func reload() {
        var descriptor = FetchDescriptor<TitleOptOut>()
        descriptor.sortBy = [SortDescriptor(\.bundleIdentifier)]
        optOuts = (try? context.fetch(descriptor)) ?? []
        stats = DBStats.compute(context: context)
    }
}

private struct DBStats {
    let sessionCount: Int
    let eventCount: Int
    let fileSizeText: String

    static let zero = DBStats(sessionCount: 0, eventCount: 0, fileSizeText: "—")

    static func compute(context: ModelContext) -> DBStats {
        let sessions = (try? context.fetchCount(FetchDescriptor<Session>())) ?? 0
        let events   = (try? context.fetchCount(FetchDescriptor<ActivityEvent>())) ?? 0

        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/default.store")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        let sizeText = bytes == 0 ? "—" : formatter.string(fromByteCount: Int64(bytes))

        return DBStats(sessionCount: sessions, eventCount: events, fileSizeText: sizeText)
    }
}
