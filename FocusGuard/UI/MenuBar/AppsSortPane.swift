import AppKit
import SwiftUI

/// Apps & sites beside the menu. "Sort your apps" puts each app or site used
/// today that no rule covers in front of you, one at a time: Focus, Neutral
/// or Distracting (F, N, D), Skip, ⌘Z to undo. Below, what was used today,
/// in sessions and outside them. "Smart suggestions" (Pro) shows what smart
/// categories sorted on their own and what they left for you.
struct MenuAppsPane: View {
    @Bindable var appState: AppState
    let close: () -> Void
    var entitlements: Entitlements = .shared

    enum Mode: Hashable { case sort, smart }

    @State private var mode: Mode = .sort
    @State private var rows: [UsageRow] = []
    /// Unsorted rows, worked out on the main context (the classifier lives there).
    @State private var unsorted: [UsageRow] = []
    @State private var skipped: Set<String> = []
    /// Sorted or skipped since the pane opened, for "2 of 6".
    @State private var handled = 0
    @State private var lastLine: String?
    @State private var lastSorted: UsageRow?
    @State private var query = ""
    @State private var addFailed = false
    @State private var pickedMode = false

    private var smart: SmartCategories { appState.smartCategories }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Apps & sites", close: close) { EmptyView() }

            if FeatureFlags.smartCategories {
                modeTabs
            }

            switch mode {
            case .sort:
                sortCard
                usedToday
            case .smart:
                MenuSmartView(smart: smart, entitlements: entitlements,
                              sortByHand: { mode = .sort }, changed: reload)
            }

            Spacer(minLength: 0)

            if mode == .sort {
                searchField
            }
        }
        .task {
            reload()
            // Open on what smart categories did, when there's news.
            if !pickedMode, FeatureFlags.smartCategories, entitlements.isUnlocked(.smartCategories),
               smart.isOn, smart.banner != nil {
                mode = .smart
            }
            pickedMode = true
        }
        .background(KeyWindowRequester())
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search, or add a site like reddit.com", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
                .onSubmit(add)
                .accessibilityLabel("Search or add a site")
            Text(addFailed ? "That doesn't look like a site. Try something like example.com."
                           : "Changing a category also updates past reports.")
                .font(.system(size: 11))
                .foregroundStyle(addFailed ? Theme.destructive : Theme.secondaryText)
                .padding(.horizontal, 2)
        }
    }

    // MARK: - Modes

    private var modeTabs: some View {
        HStack(spacing: 0) {
            modeTab(.sort) {
                Text("Sort your apps")
                if !queue.isEmpty {
                    Text("\(queue.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.focusFill))
                }
            }
            modeTab(.smart) {
                Text("Smart suggestions")
                if entitlements.isUnlocked(.smartCategories), !smart.needsYou.isEmpty {
                    Text("\(smart.needsYou.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.focusFill))
                } else {
                    ProBadge()
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.control))
    }

    private func modeTab<Label: View>(_ value: Mode, @ViewBuilder label: () -> Label) -> some View {
        let on = mode == value
        return Button { mode = value } label: {
            HStack(spacing: 6) { label() }
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.primaryText : Theme.primaryText.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? Theme.segment : .clear)
                    .shadow(color: .black.opacity(on ? 0.15 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Sort your apps

    /// What's left to sort, most time first.
    private var queue: [UsageRow] {
        unsorted.filter { !skipped.contains($0.id) }
    }

    @ViewBuilder private var sortCard: some View {
        if let current = queue.first {
            SortCard(row: current, position: handled + 1, total: handled + queue.count, lastLine: lastLine,
                     suggestion: suggestion(for: current),
                     onSort: { sort(current, as: $0) }, onSkip: { skip(current) })
                .background(undoShortcut)
        } else {
            SortedCard(nothingYet: rows.isEmpty, line: lastLine, canStartOver: !skipped.isEmpty) {
                skipped = []
                handled = 0
                lastLine = nil
            }
            .background(undoShortcut)
        }
    }

    /// ⌘Z: put the last sorted app back in the queue.
    @ViewBuilder private var undoShortcut: some View {
        if lastSorted != nil {
            Button("Undo", action: undoLast)
                .keyboardShortcut("z", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Smart categories' guess for an unsorted app, while they're on.
    private func suggestion(for row: UsageRow) -> SmartRecord? {
        guard FeatureFlags.smartCategories, entitlements.isUnlocked(.smartCategories) else { return nil }
        return smart.suggestion(for: row.id)
    }

    private func sort(_ row: UsageRow, as c: Classification) {
        if let guess = suggestion(for: row) {
            smart.accept(guess, as: c)
        } else {
            appState.setCategory(c, for: row)
        }
        lastSorted = row
        handled += 1
        lastLine = "\(row.name) → \(categoryName(c)). Press ⌘Z to undo."
        reload()
    }

    private func skip(_ row: UsageRow) {
        skipped.insert(row.id)
        handled += 1
        lastSorted = nil
        lastLine = "Skipped \(row.name). It stays neutral for now."
    }

    private func undoLast() {
        guard let row = lastSorted else { return }
        appState.clearCategory(for: row)
        lastSorted = nil
        handled = max(0, handled - 1)
        lastLine = "Put \(row.name) back."
        reload()
    }

    // MARK: - Used today

    private var visibleRows: [UsageRow] {
        rows.filter { $0.bundleId != ActivityTracker.selfBundleId }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var usedToday: some View {
        UsedTodayList(rows: Array(visibleRows.prefix(query.isEmpty ? 6 : 12)), query: query) { row, c in
            appState.setCategory(c, for: row)
            reload()
        }
    }

    // MARK: - Data

    /// Usage builds off the main thread; until it arrives the pane shows the last rows.
    private func reload() {
        if rows.isEmpty, let cached = appState.lastUsageRows, cached.contains(where: { $0.inSession > 0 }) {
            rows = cached
            unsorted = cached.filter(appState.isUnsorted)
        }
        let now = Date.now
        Task {
            let fresh = await appState.stats.appUsage(from: Calendar.current.startOfDay(for: now), to: now, limit: 40)
            rows = fresh
            unsorted = fresh.filter(appState.isUnsorted)
            appState.lastUsageRows = fresh
        }
    }

    private func add() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, visibleRows.isEmpty else { return }
        addFailed = !appState.addSiteRule(text, classification: .distraction)
        if !addFailed {
            lastLine = "\(text) → Distracting."
            query = ""
            reload()
        }
    }
}

// MARK: - Sort card

/// One app or site to sort: its name in full, its time in and outside
/// sessions, and Focus / Neutral / Distracting with their keys.
struct SortCard: View {
    let row: UsageRow
    let position: Int
    let total: Int
    let lastLine: String?
    /// Smart categories' guess, when they weren't sure enough to apply it.
    var suggestion: SmartRecord?
    let onSort: (Classification) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(position) of \(total) · used today, not sorted yet")
                    .monospacedDigit()
                Spacer()
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .keyboardShortcut(.space, modifiers: [])
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)

            HStack(spacing: 12) {
                AppGlyph(kind: row.isSite ? .generic : AppGlyph.kind(forBundleId: row.bundleId, name: row.name),
                         bundleId: row.isSite ? nil : row.bundleId, host: row.host, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    // The whole name, never cut short: long ones wrap.
                    Text(row.name)
                        .font(.system(size: 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.isSite ? "Site" : "App")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            if let suggestion {
                SmartHint(record: suggestion)
            }

            HStack(spacing: 6) {
                timeTile("In sessions", row.inSession)
                timeTile("Outside sessions", row.outsideSession)
            }

            HStack(spacing: 6) {
                sortButton(.focus, key: "f")
                sortButton(.neutral, key: "n")
                sortButton(.distraction, key: "d")
            }

            Text(lastLine ?? "Press F, N or D. Your choice also updates past reports.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    private func timeTile(_ title: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text(formatDuration(seconds))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.control.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }

    private func sortButton(_ c: Classification, key: Character) -> some View {
        Button { onSort(c) } label: {
            VStack(spacing: 4) {
                Text(String(key).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.segment)
                        .shadow(color: .black.opacity(0.12), radius: 0, y: 1))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
                HStack(spacing: 5) {
                    Circle().fill(CategoryChip.dot(c)).frame(width: 7, height: 7)
                    Text(categoryName(c))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint(c)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(suggestion?.suggested == c ? Theme.focus : stroke(c), lineWidth: suggestion?.suggested == c ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
        .accessibilityLabel("Sort \(row.name) as \(categoryName(c))")
    }

    private func tint(_ c: Classification) -> Color {
        switch c {
        case .focus:       return Theme.focusTint.opacity(0.75)
        case .neutral:     return Theme.control.opacity(0.6)
        case .distraction: return Theme.distractionTint.opacity(0.85)
        }
    }

    private func stroke(_ c: Classification) -> Color {
        switch c {
        case .focus:       return Theme.focus.opacity(0.35)
        case .neutral:     return Theme.lockedStroke.opacity(0.7)
        case .distraction: return Theme.distraction.opacity(0.45)
        }
    }
}

/// Nothing left to sort today.
struct SortedCard: View {
    let nothingYet: Bool
    let line: String?
    let canStartOver: Bool
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text(nothingYet ? "Nothing used yet today" : "All sorted for today")
                .font(.system(size: 14, weight: .semibold))
            Text(line ?? (nothingYet ? "Apps and sites show up here as you use them." : "Past reports use your choices too."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if canStartOver {
                PillButton(title: "Start over", action: onStartOver)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
    }
}

/// What was used today, with the time in sessions and outside, and each
/// one's category to change.
struct UsedTodayList: View {
    let rows: [UsageRow]
    var query = ""
    let onCategory: (UsageRow, Classification) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            paneHeading("Used today", note: "in sessions · outside")
            if rows.isEmpty {
                Text(query.isEmpty ? "Nothing tracked yet today." : "No matches. Press Return to add “\(query)” as distracting.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
            }
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    AppGlyph(kind: row.isSite ? .generic : AppGlyph.kind(forBundleId: row.bundleId, name: row.name),
                             bundleId: row.isSite ? nil : row.bundleId, host: row.host, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name)
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(formatDuration(row.inSession)) · \(formatDuration(row.outsideSession))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CategoryChipMenu(current: row.classification) { onCategory(row, $0) }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 5)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(row.name), \(formatDuration(row.inSession)) in sessions, \(formatDuration(row.outsideSession)) outside")
            }
        }
    }
}

// MARK: - Smart suggestions

/// The pane's Pro tab: what smart categories sorted on their own (each
/// with its reason and Undo), the guesses waiting for you, and YouTube
/// video by video. Without Apple Intelligence it says so and points back
/// to sorting by hand.
struct MenuSmartView: View {
    @Bindable var smart: SmartCategories
    var entitlements: Entitlements = .shared
    let sortByHand: () -> Void
    /// Something changed a category: the pane reloads its rows.
    let changed: () -> Void

    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entitlements.isUnlocked(.smartCategories) {
                LockedProRow(feature: .smartCategories, title: "Smart categories",
                             detail: "New apps and sites sorted on this Mac from how you use them, each with a reason. You can undo any of it.",
                             systemImage: "sparkles", onTrialStarted: { smart.turnOn() }, onUpgrade: openUpgrade)
            } else if !smart.isModelAvailable {
                SmartUnavailableCard(sortByHand: sortByHand)
            } else if !smart.isEnabled {
                offCard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let banner = smart.banner {
                            bannerRow(banner)
                        }
                        if smart.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Sorting new apps and sites…")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                        }
                        if !smart.needsYou.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                paneHeading("Needs you", note: "not sure enough to change")
                                ForEach(smart.needsYou) { record in guessCard(record) }
                            }
                        }
                        if !smart.sortedForYou.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                paneHeading("Sorted for you")
                                ForEach(smart.sortedForYou.prefix(12)) { record in sortedRow(record) }
                            }
                        }
                        if smart.banner == nil, smart.needsYou.isEmpty, smart.sortedForYou.isEmpty, !smart.isWorking {
                            nothingNew
                        }
                        if let refused {
                            Text(refused)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }

            videoRow

            if entitlements.isUnlocked(.smartCategories), smart.isModelAvailable {
                HStack {
                    Text("Worked out on this Mac")
                    Spacer()
                    Toggle("Sort on its own", isOn: $smart.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func bannerRow(_ banner: SmartBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { smart.closeBanner() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.focus.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    /// A guess smart categories weren't sure about: take it, pick another,
    /// or leave it.
    private func guessCard(_ record: SmartRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AppGlyph(kind: record.isSite ? .generic : AppGlyph.kind(forBundleId: record.bundleId, name: record.name),
                         bundleId: record.isSite ? nil : record.bundleId, host: record.host, size: 22)
                Text(record.name)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CategoryChip(classification: record.suggested)
            }
            Text(record.reason)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Make it \(categoryName(record.suggested))") { accept(record, as: record.suggested) }
                    .buttonStyle(.capsule(.secondary, height: 24))
                Menu {
                    ForEach([Classification.focus, .neutral, .distraction].filter { $0 != record.suggested }, id: \.self) { c in
                        Button(categoryName(c)) { accept(record, as: c) }
                    }
                } label: {
                    Text("Other…").font(.system(size: 12))
                }
                .menuStyle(.button)
                .buttonStyle(.textLink)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button("Leave it") { smart.dismiss(record) }
                    .buttonStyle(.textLink)
            }
        }
        .paneCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.name), looks like \(categoryName(record.suggested)). \(record.reason)")
    }

    private func sortedRow(_ record: SmartRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AppGlyph(kind: record.isSite ? .generic : AppGlyph.kind(forBundleId: record.bundleId, name: record.name),
                     bundleId: record.isSite ? nil : record.bundleId, host: record.host, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CategoryChip(classification: record.suggested)
            Button("Undo") {
                refused = smart.undo(record) ? nil : "Strict keeps \(record.name) blocked until the session ends."
                changed()
            }
            .buttonStyle(.textLink)
            .accessibilityLabel("Undo \(record.name)")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var nothingNew: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text("Nothing new to sort").font(.system(size: 14, weight: .semibold))
            Text("New apps and sites get sorted here a few minutes after you first use them, never during a session.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .paneCard(padding: EdgeInsets())
    }

    private var offCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart categories are off").font(.system(size: 13, weight: .semibold))
            Text("Turn them on to sort new apps and sites on this Mac, each with a reason.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on") { smart.turnOn() }
                .buttonStyle(.capsule(.primary, height: 26))
        }
        .paneCard()
    }

    /// YouTube video by video: on and off, or locked.
    @ViewBuilder private var videoRow: some View {
        if entitlements.isUnlocked(.youtubePerVideo) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("YouTube video by video").font(.system(size: 12, weight: .semibold))
                        ProBadge()
                    }
                    Text(smart.isModelAvailable
                         ? "Talks and tutorials count as focus, the rest as distracting."
                         : OnDeviceAI.unavailableNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("YouTube video by video", isOn: Binding(get: { smart.perVideo }, set: { smart.setPerVideo($0); changed() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!smart.isModelAvailable && !smart.perVideo)
            }
            .paneCard()
        } else {
            LockedProRow(feature: .youtubePerVideo, title: "YouTube video by video",
                         detail: "Each video judged by its title on this Mac: talks and tutorials count as focus, the rest as distracting.",
                         systemImage: "play.rectangle", onTrialStarted: { smart.setPerVideo(true) }, onUpgrade: openUpgrade)
        }
    }

    private func accept(_ record: SmartRecord, as c: Classification) {
        refused = smart.accept(record, as: c) ? nil : "Strict keeps \(record.name) blocked until the session ends."
        changed()
    }

    private func openUpgrade() {
        (NSApp.delegate as? AppDelegate)?.openMainWindow(tab: .settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .presentWindowSheet, object: WindowSheet.upgrade(.smartCategories))
        }
    }
}

/// "Needs Apple Intelligence (macOS 26)": what to do about it, and back to
/// sorting by hand.
struct SmartUnavailableCard: View {
    let sortByHand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(OnDeviceAI.unavailableNote).font(.system(size: 13, weight: .semibold))
            }
            Text(OnDeviceAI.availability.sortingNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sort by hand", action: sortByHand)
                .buttonStyle(.capsule(.secondary, height: 26))
        }
        .paneCard()
    }
}

extension OnDeviceAI.Availability {
    /// Why smart categories can't sort, and what to do meanwhile.
    var sortingNote: String {
        switch self {
        case .available:   return "New apps and sites get sorted on this Mac."
        case .turnedOff:   return "Turn on Apple Intelligence in System Settings and new apps get sorted here. Until then, sort them by hand."
        case .notReady:    return "Apple Intelligence is still getting ready on this Mac. Until then, sort them by hand."
        case .unsupported: return "Smart categories run on this Mac with Apple Intelligence, on macOS 26. Until then, sort them by hand."
        }
    }
}

/// Smart categories' guess on the sort card: "Looks like focus." and why.
struct SmartHint: View {
    let record: SmartRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            (Text("Looks like \(categoryName(record.suggested).lowercased()). ").fontWeight(.semibold)
             + Text(record.reason))
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.focusTint.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

/// Makes the menu the key window while it's on screen, so the sort keys
/// (F, N, D, ⌘Z) reach it. The menu opens without taking focus otherwise.
private struct KeyWindowRequester: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RequesterView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class RequesterView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
            }
        }
    }
}
