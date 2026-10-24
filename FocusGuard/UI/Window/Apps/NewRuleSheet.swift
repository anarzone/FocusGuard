import AppKit
import SwiftData
import SwiftUI

/// What the New rule sheet opens with.
struct NewRuleDraft: Identifiable {
    let id = UUID()
    var kind: RuleMatchKind = .host
    var pattern = ""
    /// For an app rule: its bundle id and name.
    var app: (bundleId: String, name: String)?
    var classification: Classification = .distraction

    init() {}

    /// A rule for this app or site.
    init(item: AppsItem) {
        if let host = item.row.host {
            kind = .host
            pattern = host
        } else {
            kind = .bundleId
            app = (item.row.bundleId, item.name)
        }
        classification = item.row.classification
    }

    /// A rule for part of this site, ready for its path.
    init(partOf item: AppsItem) {
        kind = .urlPrefix
        pattern = "\(item.target)/"
        classification = .distraction
    }
}

/// New rule: App, Site, Part of a site or Window title, what it counts
/// as, and (for apps and sites) a daily limit.
struct NewRuleSheet: View {
    @Bindable var appState: AppState
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: RuleMatchKind
    @State private var pattern: String
    @State private var app: (bundleId: String, name: String)?
    @State private var classification: Classification
    @State private var withLimit = false
    @State private var limitMinutes = 30
    @State private var preview: RuleMatchPreview.Result?
    @State private var problem: String?
    @State private var recentApps: [UsageRow] = []
    @FocusState private var fieldFocused: Bool

    init(appState: AppState, draft: NewRuleDraft, onSaved: @escaping () -> Void) {
        self._appState = Bindable(wrappedValue: appState)
        self.onSaved = onSaved
        _kind = State(initialValue: draft.kind)
        _pattern = State(initialValue: draft.pattern)
        _app = State(initialValue: draft.app)
        _classification = State(initialValue: draft.classification)
    }

    private static let kinds: [(RuleMatchKind, String)] = [
        (.bundleId, "App"), (.host, "Site"), (.urlPrefix, "Part of a site"), (.titleRegex, "Window title"),
    ]

    private var canLimit: Bool { kind == .bundleId || kind == .host }
    private var limitAllowed: Bool { LimitGate.canAdd(existing: appState.limits.statuses.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New rule")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                label("Match")
                Picker("Match", selection: $kind) {
                    ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                label(fieldTitle)
                if kind == .bundleId {
                    appPicker
                } else {
                    TextField(placeholder, text: $pattern)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: kind == .titleRegex ? .default : .monospaced))
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.windowCard))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(fieldFocused ? Theme.focus.opacity(0.6) : Theme.hairline, lineWidth: fieldFocused ? 2 : 0.5))
                        .onSubmit(save)
                }
                Text(previewLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Counts as")
                HStack(spacing: 8) {
                    ForEach([Classification.focus, .neutral, .distraction], id: \.self) { c in
                        countsAs(c)
                    }
                }
            }

            if canLimit {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            label("Daily limit")
                            Text(limitAllowed ? "Allow a little each day, then pause it" : "Free keeps one daily limit; this would be another, a Pro feature")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                        if withLimit { LimitStepper(minutes: limitMinutes) { limitMinutes = $0 } }
                        Toggle("Daily limit", isOn: $withLimit)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(!limitAllowed)
                    }
                    if !limitAllowed && appState.sessionManager.currentSession == nil {
                        LockedProRow(feature: .unlimitedLimits, title: "Daily limits for any site",
                                     detail: "Pro sets a daily limit for every app and site.",
                                     systemImage: "hourglass",
                                     onTrialStarted: { withLimit = true })
                    }
                }
            }

            if kind == .urlPrefix || kind == .host {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.focus)
                    Text("Tracking and the pause screen work on every plan. To stop these pages loading at all, turn on Block in the browser (Pro) in Settings › Blocking.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focus.opacity(0.07)))
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button("Add rule", action: save)
                    .buttonStyle(.capsule(.primary, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 500)
        .background(Theme.windowBackground)
        .task {
            let now = Date.now
            recentApps = MenuInsightsBuilder.usageRows(context: appState.container.mainContext,
                                                       from: AppsRange.month.start(now: now), to: now, limit: 120)
                .filter { $0.host == nil }
        }
        .task(id: "\(kind.rawValue)|\(pattern)|\(app?.bundleId ?? "")") {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            preview = RuleMatchPreview.preview(kind: kind, pattern: kind == .bundleId ? (app?.bundleId ?? "") : pattern,
                                               context: appState.container.mainContext)
        }
        .onChange(of: kind) { problem = nil; if !canLimit { withLimit = false } }
        .onAppear { fieldFocused = kind != .bundleId }
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
    }

    private var fieldTitle: String {
        switch kind {
        case .bundleId:   return "App"
        case .host:       return "Site"
        case .urlPrefix:  return "Address starts with"
        case .titleRegex: return "Window title contains"
        }
    }

    private var placeholder: String {
        switch kind {
        case .host:       return "x.com"
        case .urlPrefix:  return "youtube.com/shorts"
        case .titleRegex: return "PR #"
        case .bundleId:   return ""
        }
    }

    private var previewLine: String {
        guard let preview else {
            switch kind {
            case .host:       return "Covers the site and its subdomains."
            case .urlPrefix:  return "Wins over a rule for the whole site."
            case .titleRegex: return "Any app whose window title has this text. Case doesn't matter."
            case .bundleId:   return "Pick one you've used, or any app on this Mac."
            }
        }
        if preview.visits == 0 { return "No matches in the last 7 days yet." }
        return "Matched \(WindowFormat.count(preview.visits, "visit")) in the last 7 days, \(WindowFormat.hm(preview.seconds)) in total."
    }

    private var appPicker: some View {
        Menu {
            ForEach(recentApps) { row in
                Button(row.name) { app = (row.bundleId, row.name) }
            }
            if !recentApps.isEmpty { Divider() }
            Button("Other app…") { chooseApp() }
        } label: {
            HStack(spacing: 8) {
                if let app {
                    WindowItemIcon(name: app.name, bundleId: app.bundleId, host: nil, size: 18)
                    Text(app.name).foregroundStyle(Theme.primaryText)
                } else {
                    Text("Choose an app").foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.windowCard))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func countsAs(_ c: Classification) -> some View {
        let picked = classification == c
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { classification = c } label: {
            HStack(spacing: 6) {
                Circle().fill(CategoryChip.dot(c)).frame(width: 7, height: 7)
                Text(categoryName(c)).font(.system(size: 12, weight: picked ? .semibold : .regular))
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(shape.fill(picked ? CategoryChip.dot(c).opacity(0.14) : Theme.windowCard))
            .overlay(shape.strokeBorder(picked ? CategoryChip.dot(c) : Theme.hairline, lineWidth: picked ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        app = (bundleId, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }

    // MARK: - Saving

    private var cleanPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        switch kind {
        case .bundleId:   return app != nil
        case .host:       return DailyLimitsEngine.siteTarget(cleanPattern) != nil
        case .urlPrefix:  return Self.prefix(cleanPattern) != nil
        case .titleRegex: return !cleanPattern.isEmpty
        }
    }

    /// "youtube.com/shorts" from what was typed, without the scheme or "www.".
    static func prefix(_ input: String) -> String? {
        var text = input.lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        while text.hasSuffix("/") { text.removeLast() }
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0].contains("."), !parts[1].isEmpty, !text.contains(" ") else { return nil }
        return text
    }

    private func save() {
        guard isValid else { return }
        let classifier = appState.classifier
        var saved = true
        switch kind {
        case .bundleId:
            guard let app else { return }
            saved = classifier.setOverride(bundleId: app.bundleId, classification: classification)
            if saved && withLimit && limitAllowed {
                _ = appState.limits.addLimit(target: app.bundleId, isSite: false, name: app.name, minutes: limitMinutes)
            }
        case .host:
            guard let host = DailyLimitsEngine.siteTarget(cleanPattern) else { return }
            saved = classifier.setOverride(host: host, classification: classification)
            if saved && withLimit && limitAllowed {
                _ = appState.limits.addLimit(target: host, isSite: true, minutes: limitMinutes)
            }
        case .urlPrefix:
            guard let prefix = Self.prefix(cleanPattern) else { return }
            saved = classifier.setOverride(urlPrefix: prefix, classification: classification)
        case .titleRegex:
            let context = appState.container.mainContext
            context.insert(AppRule(pattern: TitleRule.pattern(containing: cleanPattern), matchKind: .titleRegex,
                                   classification: classification, priority: 300))
            Persistence.save(context)
            classifier.invalidate()
        }
        guard saved else {
            problem = "Strict keeps blocked apps and sites blocked until this session ends."
            return
        }
        onSaved()
        dismiss()
    }
}
