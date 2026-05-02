import SwiftUI
import SwiftData

struct SettingsRulesPane: View {
    @Bindable var appState: AppState

    @State private var rules: [AppRule] = []
    @State private var search: String = ""
    @State private var filter: Classification? = nil
    @State private var showingAddSheet = false

    private var context: ModelContext { appState.container.mainContext }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Rules")
                    .font(.system(size: 26, weight: .bold))
                    .kerning(-0.5)
                Text("Classify apps and websites as Focus, Neutral, or Distraction. Rules with higher priority win on conflict.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                filterBar.padding(.top, 16)

                if filteredRules.isEmpty {
                    emptyState.padding(.top, 16)
                } else {
                    rulesList.padding(.top, 12)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        .sheet(isPresented: $showingAddSheet) {
            AddRuleSheet { newRule in
                showingAddSheet = false
                if let rule = newRule {
                    context.insert(rule)
                    Persistence.save(context)
                    appState.classifier.invalidate()
                    reload()
                }
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Class filter
            Picker("", selection: $filter) {
                Text("All").tag(Classification?.none)
                Text("Focus").tag(Classification?.some(.focus))
                Text("Neutral").tag(Classification?.some(.neutral))
                Text("Distraction").tag(Classification?.some(.distraction))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 320)

            TextField("Search pattern…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()

            Button {
                showingAddSheet = true
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var filteredRules: [AppRule] {
        rules.filter { rule in
            (filter == nil || rule.classification == filter) &&
            (search.isEmpty || rule.pattern.localizedCaseInsensitiveContains(search))
        }
    }

    // MARK: - List

    private var rulesList: some View {
        VStack(spacing: 0) {
            ForEach(filteredRules, id: \.id) { rule in
                ruleRow(rule)
                if rule.id != filteredRules.last?.id {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }

    private func ruleRow(_ rule: AppRule) -> some View {
        HStack(spacing: 10) {
            classificationDot(rule.classification)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.pattern)
                    .font(.system(size: 13).monospacedDigit())
                Text("\(rule.matchKind.label) · priority \(rule.priority)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { rule.classification },
                set: { newValue in
                    rule.classification = newValue
                    Persistence.save(context)
                    appState.classifier.invalidate()
                }
            )) {
                Text("Focus").tag(Classification.focus)
                Text("Neutral").tag(Classification.neutral)
                Text("Distraction").tag(Classification.distraction)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)

            Button(role: .destructive) {
                context.delete(rule)
                Persistence.save(context)
                appState.classifier.invalidate()
                reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func classificationDot(_ c: Classification) -> some View {
        Circle()
            .fill(color(for: c))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color(for: c).opacity(0.25), lineWidth: 3))
    }

    private func color(for c: Classification) -> Color {
        switch c {
        case .focus: return Theme.focus
        case .neutral: return Theme.neutral
        case .distraction: return Theme.distraction
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No rules match")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }

    // MARK: - Data

    private func reload() {
        var descriptor = FetchDescriptor<AppRule>()
        descriptor.sortBy = [
            SortDescriptor(\.priority, order: .reverse),
            SortDescriptor(\.pattern, order: .forward)
        ]
        rules = (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - AddRuleSheet

struct AddRuleSheet: View {
    var onDismiss: (AppRule?) -> Void

    @State private var pattern: String = ""
    @State private var matchKind: RuleMatchKind = .bundleId
    @State private var classification: Classification = .focus
    @State private var priority: Int = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add rule")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Match")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Picker("", selection: $matchKind) {
                    ForEach(RuleMatchKind.allCases, id: \.self) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Pattern")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $pattern)
                    .textFieldStyle(.roundedBorder)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Classify as")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Picker("", selection: $classification) {
                    Text("Focus").tag(Classification.focus)
                    Text("Neutral").tag(Classification.neutral)
                    Text("Distraction").tag(Classification.distraction)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack {
                Text("Priority")
                Stepper(value: $priority, in: 1...999, step: 50) {
                    Text("\(priority)")
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .font(.system(size: 12))

            HStack {
                Button("Cancel") { onDismiss(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let rule = AppRule(
                        pattern: trimmed,
                        matchKind: matchKind,
                        classification: classification,
                        priority: priority
                    )
                    onDismiss(rule)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var placeholder: String {
        switch matchKind {
        case .bundleId:   return "com.jetbrains.PhpStorm"
        case .host:       return "youtube.com"
        case .titleRegex: return "(?i)slack"
        }
    }

    private var hint: String {
        switch matchKind {
        case .bundleId:   return "Exact bundle identifier."
        case .host:       return "Substring match against the URL host. Matches www subdomains."
        case .titleRegex: return "Case-insensitive regular expression matched against the window title."
        }
    }
}
