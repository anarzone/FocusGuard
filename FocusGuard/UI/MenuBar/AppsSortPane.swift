import AppKit
import SwiftUI

/// Apps & sites beside the menu. "Sort your apps" puts each app or site used
/// today that no rule covers in front of you, one at a time: Focus, Neutral
/// or Distracting (F, N, D), Skip, ⌘Z to undo. Below, what was used today,
/// in sessions and outside them.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Apps & sites", close: close) { EmptyView() }

            if FeatureFlags.proAI {
                modeTabs
            }

            switch mode {
            case .sort:  sortCard
            case .smart: SmartSuggestionsView(entitlements: entitlements)
            }

            usedToday

            Spacer(minLength: 0)

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
        .task { reload() }
        .background(KeyWindowRequester())
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
                ProBadge()
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

    private func sort(_ row: UsageRow, as c: Classification) {
        appState.setCategory(c, for: row)
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
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(stroke(c), lineWidth: 0.5))
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
