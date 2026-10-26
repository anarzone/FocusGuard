import SwiftData
import SwiftUI

/// "Sort your apps": one app or site at a time, most used first. 1, 2 and
/// 3 pick Focus, Neutral and Distracting; space skips. Smart categories'
/// guess (Pro) shows on the card with its reason.
struct SortAppsView: View {
    @Bindable var appState: AppState
    /// Waiting to be sorted, most used first.
    let items: [AppsItem]
    let range: AppsRange
    let onDone: () -> Void
    let onMakeRule: (AppsItem) -> Void

    @State private var queue: [AppsItem] = []
    @State private var started = false
    @State private var done: [(item: AppsItem, picked: Classification)] = []
    @State private var total = 0
    @AppStorage(WindowDefaultsKey.appsSorted) private var appsSorted = false
    @FocusState private var focused: Bool

    private var current: AppsItem? { queue.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Sort your apps",
                       subtitle: "One at a time, most used first. Every choice also fixes past reports.") {
                Button("Done") { finish() }
                    .buttonStyle(.capsule(.primary, height: 32))
            }
            .overlay(alignment: .leading) { EmptyView() }

            WindowSplitRow(weights: [216, 600, 216]) {
                upNext
                centre
                justSorted
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.bottom, 20)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: CharacterSet(charactersIn: "123 ")) { press in
            switch press.characters {
            case "1": pick(.focus)
            case "2": pick(.neutral)
            case "3": pick(.distraction)
            case " ": skip()
            default: return .ignored
            }
            return .handled
        }
        .onAppear { startIfReady(); focused = true }
        .onChange(of: items.count) { startIfReady() }
    }

    private func startIfReady() {
        guard !started, !items.isEmpty else { return }
        started = true
        queue = items
        total = items.count
    }

    // MARK: - Columns

    private var upNext: some View {
        sideCard(title: "Up next", trailing: AnyView(
            Text(queue.count > 1 ? "\(queue.count - 1) more" : "")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        )) {
            ForEach(queue.dropFirst().prefix(12)) { item in
                HStack(spacing: 9) {
                    WindowItemIcon(name: item.name, bundleId: item.row.bundleId, host: item.row.host, size: 22)
                    Text(item.name).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(WindowFormat.hm(item.row.seconds)).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(height: 36)
            }
        }
    }

    private var justSorted: some View {
        sideCard(title: "Just sorted", trailing: AnyView(
            Button("Undo last", action: undo).buttonStyle(.textLink).disabled(done.isEmpty).opacity(done.isEmpty ? 0 : 1)
        )) {
            ForEach(Array(done.reversed().prefix(12).enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 9) {
                    WindowItemIcon(name: entry.item.name, bundleId: entry.item.row.bundleId, host: entry.item.row.host, size: 22)
                    Text(entry.item.name).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(CategoryChip.dot(entry.picked)).frame(width: 6, height: 6)
                        Text(categoryName(entry.picked))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primaryText)
                }
                .frame(height: 36)
            }
        }
    }

    private func sideCard<Content: View>(title: String, trailing: AnyView,
                                         @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Spacer()
                trailing
            }
            .padding(.bottom, 6)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Theme.windowCard.opacity(0.6)))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    @ViewBuilder
    private var centre: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack {
                    Text(total > 0 ? "\(min(total, done.count + 1)) of \(total)" : "")
                    Spacer()
                    Text(timeLeft)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                WindowBar(fraction: total > 0 ? Double(done.count) / Double(total) : 0, height: 4)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Sorting progress")
                    .accessibilityValue("\(done.count) of \(total)")
            }
            Spacer(minLength: 0)
            if let item = current {
                card(for: item)
            } else {
                finished
            }
            Spacer(minLength: 0)
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 20, trailing: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Theme.windowCard))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.06), radius: 15, y: 10)
    }

    private func card(for item: AppsItem) -> some View {
        VStack(spacing: 14) {
            WindowItemIcon(name: item.name, bundleId: item.row.bundleId, host: item.row.host, size: 76)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 8)
            VStack(spacing: 4) {
                Text(item.name)
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(([item.isSite ? "Site" : "App", "\(WindowFormat.hm(item.row.seconds)) \(range.phrase)"]
                      + [item.suggestion?.hours].compactMap { $0 }).joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let suggestion = item.suggestion {
                HStack(spacing: 8) {
                    SmartReasonLine(lead: item.source == .smart
                                        ? "Sorted as \(categoryName(suggestion.suggested).lowercased()) for you."
                                        : "Looks like \(categoryName(suggestion.suggested).lowercased()).",
                                    reason: suggestion.reason)
                    ProBadge()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focus.opacity(0.08)))
            } else if item.source == .builtIn {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb").foregroundStyle(Theme.focus)
                    (Text("FocusGuard guessed \(categoryName(item.row.classification).lowercased()).").fontWeight(.semibold)
                     + Text(" Keep it or pick another."))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focus.opacity(0.08)))
            }
            HStack(spacing: 10) {
                choice(.focus, key: "1", item: item)
                choice(.neutral, key: "2", item: item)
                choice(.distraction, key: "3", item: item)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.name) counts as")
            HStack(spacing: 8) {
                Button(action: skip) {
                    HStack(spacing: 6) {
                        Text("Skip")
                        Text("space").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .buttonStyle(.capsule(.secondary))
                Button("Depends on the window? Make a rule") { onMakeRule(item) }
                    .buttonStyle(.textLink)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func choice(_ c: Classification, key: String, item: AppsItem) -> some View {
        let guessed = item.suggestion.map { $0.suggested == c }
            ?? (item.source == .builtIn && item.row.classification == c)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { pick(c) } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(CategoryChip.dot(c)).frame(width: 9, height: 9)
                    Text(categoryName(c)).font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.primaryText)
                Text(key)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.windowCard))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            .frame(width: 132, height: 76)
            .background(shape.fill(guessed ? Theme.focus.opacity(0.10) : Theme.inset))
            .overlay(shape.strokeBorder(guessed ? Theme.focus : Theme.hairline, lineWidth: guessed ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(categoryName(c))
        .accessibilityHint("Key \(key)")
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.focus)
            Text(total == 0 ? "Nothing left to sort" : "All sorted")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("New apps and sites show up here as you use them. You can change any of them in Apps & Sites.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Back to Apps & Sites") { finish() }
                .buttonStyle(.capsule(.primary, height: 32))
                .padding(.top, 4)
        }
    }

    private var footnote: String {
        if FeatureFlags.smartCategories, Entitlements.shared.isUnlocked(.smartCategories),
           !appState.smartCategories.isModelAvailable {
            return "Smart suggestions: \(OnDeviceAI.unavailableNote). Unsure? Leave it neutral."
        }
        return "Unsure? Leave it neutral. Neutral time is not counted for or against you."
    }

    private var timeLeft: String {
        guard !queue.isEmpty else { return "" }
        let minutes = Int((Double(queue.count) * 4 / 60).rounded(.up))
        return minutes <= 1 ? "about a minute left" : "about \(minutes) minutes left"
    }

    // MARK: - Actions

    private func pick(_ c: Classification) {
        guard let item = current else { return }
        if let guess = item.suggestion, item.source == .none {
            appState.smartCategories.accept(guess, as: c)
        } else if c != item.row.classification || item.source != .user {
            appState.setCategory(c, for: item.row)
        }
        done.append((item, c))
        queue.removeFirst()
        if queue.isEmpty { appsSorted = true }
    }

    private func skip() {
        guard let item = current else { return }
        queue.removeFirst()
        queue.append(item)
        if queue.count == 1 && done.count >= total { appsSorted = true }
    }

    /// Puts the last one back: removes the rule just made, or restores the
    /// category the user had before.
    private func undo() {
        guard let last = done.popLast() else { return }
        let item = last.item
        // Back to the old category first, so past reports go back too.
        appState.setCategory(item.row.classification, for: item.row)
        if item.source != .user, let rule = userRule(for: item) {
            appState.deleteRule(rule)
        }
        // Sorted by smart categories before: their rule comes back.
        if item.source == .smart, let suggestion = item.suggestion {
            appState.smartCategories.restore(suggestion)
        }
        queue.insert(item, at: 0)
    }

    private func userRule(for item: AppsItem) -> AppRule? {
        let pattern = item.target
        let kindRaw = (item.isSite ? RuleMatchKind.host : .bundleId).rawValue
        let descriptor = FetchDescriptor<AppRule>(
            predicate: #Predicate { $0.pattern == pattern && $0.matchKindRaw == kindRaw && $0.priority >= 200 }
        )
        return Persistence.fetch(appState.container.mainContext, descriptor).first
    }

    private func finish() {
        if !done.isEmpty { appsSorted = true }
        onDone()
    }
}
