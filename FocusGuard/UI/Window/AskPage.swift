import SwiftUI

/// Ask, a Pro feature: questions about your own focus, answered on this
/// Mac. The facts come from rules over the store; the on-device model only
/// words them. Locked, it's a faded preview with a card about it.
struct AskPage: View {
    @Bindable var appState: AppState
    let conversation: AskConversation
    var entitlements: Entitlements = .shared

    var body: some View {
        if AskAccess.isOpen(shipped: FeatureFlags.ask, unlocked: entitlements.isUnlocked(.ask)) {
            AskView(appState: appState, conversation: conversation)
        } else {
            AskLocked(entitlements: entitlements)
        }
    }
}

/// Whether Ask is open, and so whether the sidebar shows PRO next to it.
enum AskAccess {
    static func isOpen(shipped: Bool, unlocked: Bool) -> Bool { shipped && unlocked }
}

// MARK: - The page

/// The header, then the first open or the conversation. Holds the draft
/// and hands questions and buttons to the conversation.
private struct AskView: View {
    @Bindable var appState: AppState
    let conversation: AskConversation

    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 12) {
            PageHeader(title: String(localized: "Ask", comment: "The name of the Ask feature: questions about your focus"),
                       subtitle: String(localized: "About your own focus · answered on this Mac")) {
                if !conversation.turns.isEmpty {
                    Button("New question") {
                        conversation.clear()
                        draft = ""
                        typing = true
                    }
                    .buttonStyle(.header)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)

            Group {
                if conversation.turns.isEmpty {
                    AskFirstOpen(draft: $draft, typing: $typing, busy: conversation.isWorking, ask: ask)
                } else {
                    AskThread(turns: conversation.turns, note: conversation.actionNote,
                              suggestions: conversation.suggestions, busy: conversation.isWorking,
                              draft: $draft, typing: $typing, ask: ask) { action, turn in
                        conversation.perform(action, in: turn, appState: appState)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { typing = true }
    }

    private func ask(_ text: String) {
        guard !conversation.isWorking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversation.ask(text, appState: appState)
        draft = ""
    }
}

/// The first open: what Ask does, the question box, six questions to
/// start from, and what it can and can't see.
private struct AskFirstOpen: View {
    @Binding var draft: String
    var typing: FocusState<Bool>.Binding
    let busy: Bool
    let ask: (String) -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.focusTint))
                    .accessibilityHidden(true)
                Text("Ask about your focus")
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                Text("Plain answers from the time FocusGuard tracked, with the numbers behind them, and a change you can make in one click.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AskQuestionBox(text: $draft, typing: typing, large: true, busy: busy) { ask(draft) }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AskSuggestions.all, id: \.self) { question in
                    Button(question) { ask(question) }
                        .buttonStyle(AskChipStyle(large: true))
                }
            }
            .disabled(busy)

            VStack(spacing: 4) {
                Text("It sees which app or site you used, when, and for how long. It can't see what you did inside them.")
                Text("Answers are worked out on this Mac. Nothing leaves it.")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 640)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The conversation, scrolling in its own area, with suggestions and the
/// question box under it.
private struct AskThread: View {
    let turns: [AskConversation.Turn]
    let note: (turn: UUID, text: String)?
    let suggestions: [String]
    let busy: Bool
    @Binding var draft: String
    var typing: FocusState<Bool>.Binding
    let ask: (String) -> Void
    let perform: (AskAction, UUID) -> Void

    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(turns) { turn in
                            AskQuestionBubble(text: turn.question)
                                .padding(.top, turn.id == turns.first?.id ? 0 : 4)
                            if let answer = turn.answer {
                                AskAnswerCard(answer: answer, acted: turn.acted,
                                              note: note?.turn == turn.id ? note?.text : nil,
                                              onAction: { perform($0, turn.id) }, onAsk: ask)
                            } else {
                                AskWorkingCard()
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                // A new question or its answer, not a button used further up.
                .onChange(of: "\(turns.count)-\(turns.last?.answer == nil)") {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)

            ViewThatFits(in: .horizontal) {
                chips(suggestions)
                chips(Array(suggestions.prefix(2)))
                chips(Array(suggestions.prefix(1)))
            }

            AskQuestionBox(text: $draft, typing: typing, large: false, busy: busy) { ask(draft) }

            Text("Answers are worked out on this Mac from the time FocusGuard tracked. Nothing leaves it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }

    private func chips(_ questions: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(questions, id: \.self) { question in
                Button(question) { ask(question) }
                    .buttonStyle(AskChipStyle(large: false))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .disabled(busy)
    }
}

// MARK: - Pieces

/// The question typed, on the right.
private struct AskQuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 160)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                                                   topTrailingRadius: 16, style: .continuous)
                    .fill(Theme.focusTint))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }
}

/// An answer: the lead, a sentence or two, one small chart, what it's
/// based on, and at most one button.
private struct AskAnswerCard: View {
    let answer: AskAnswer
    let acted: Bool
    let note: String?
    let onAction: (AskAction) -> Void
    let onAsk: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(answer.lead)
                        .font(.system(size: 15, weight: .semibold))
                        .kerning(-0.15)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(answer.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bodyText)
                        .lineSpacing(3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                if let visual = answer.visual {
                    AskChart(visual: visual)
                        .frame(width: 340)
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 0.5)

            HStack(spacing: 10) {
                Text(answer.basis)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.destructive).lineLimit(1)
                }
                if let action = answer.action {
                    if acted {
                        Label(action.doneTitle, systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    } else {
                        Button(action.title) { onAction(action) }
                            .buttonStyle(AskActionStyle())
                    }
                } else if let suggestion = answer.suggestion {
                    Button("Ask “\(suggestion)”") { onAsk(suggestion) }
                        .buttonStyle(AskActionStyle())
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// While the facts are worked out and worded.
private struct AskWorkingCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Working it out on this Mac…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// The answer's chart: upright bars, or labelled horizontal ones.
private struct AskChart: View {
    let visual: AskVisual

    var body: some View {
        switch visual {
        case let .bars(bars, tone, summary):
            barsChart(bars, tone: tone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
        case let .rows(rows, tone, summary):
            rowsChart(rows, tone: tone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
        }
    }

    private func color(_ tone: AskTone, strong: Bool) -> Color {
        switch tone {
        case .focus: return strong ? Theme.focus : Theme.focusSoft
        case .drift: return strong ? Theme.distraction : Theme.distraction.opacity(0.35)
        }
    }

    private func barsChart(_ bars: [AskBar], tone: AskTone) -> some View {
        let spacing: CGFloat = bars.count > 14 ? 3 : 8
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(bars.indices, id: \.self) { index in
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                        .fill(color(tone, strong: bars[index].highlighted))
                        .frame(height: max(2, 64 * CGFloat(min(1, bars[index].value))))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 64, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            HStack(spacing: spacing) {
                ForEach(bars.indices, id: \.self) { index in
                    Text(bars[index].label ?? " ")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 4)
    }

    private func rowsChart(_ rows: [AskRow], tone: AskTone) -> some View {
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Text(rows[index].name)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 124, alignment: .leading)
                    WindowBar(fraction: rows[index].value, color: color(tone, strong: true), height: 8)
                    Text(rows[index].text)
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 2)
    }
}

/// The question box: a plain field and a round send button.
private struct AskQuestionBox: View {
    @Binding var text: String
    var typing: FocusState<Bool>.Binding
    /// The first open's bigger box.
    let large: Bool
    let busy: Bool
    let onSubmit: () -> Void

    private var canSend: Bool { !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 18 : 16, style: .continuous)
        HStack(spacing: 8) {
            TextField("Ask about your focus…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: large ? 15 : 14))
                .foregroundStyle(Theme.primaryText)
                .focused(typing)
                .onSubmit { if canSend { onSubmit() } }
                .accessibilityLabel("Your question")
            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: large ? 36 : 32, height: large ? 36 : 32)
                    .background(Circle().fill(Theme.focusFill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.45)
            .help("Ask")
            .accessibilityLabel("Ask")
        }
        .padding(.leading, large ? 18 : 16)
        .padding(.trailing, 8)
        .frame(height: large ? 52 : 48)
        .background(shape.fill(Theme.windowCard)
            .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.08), radius: large ? 7 : 4, y: large ? 4 : 2))
        .overlay(shape.strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
    }
}

/// A suggested question: a tile on the first open, a chip after.
private struct AskChipStyle: ButtonStyle {
    let large: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 12 : 14, style: .continuous)
        configuration.label
            .font(.system(size: large ? 13 : 12))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .padding(.horizontal, large ? 14 : 12)
            .frame(maxWidth: large ? .infinity : nil, alignment: .leading)
            .frame(height: large ? 40 : 28)
            .background(shape.fill(Theme.headerControl))
            .overlay(shape.strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The answer's one button, in indigo on a light indigo capsule.
private struct AskActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.link)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Theme.focusTint))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Locked

/// Free: a faded conversation behind a card about Ask, like the work log's.
private struct AskLocked: View {
    let entitlements: Entitlements
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: String(localized: "Ask", comment: "The name of the Ask feature: questions about your focus"),
                       subtitle: String(localized: "Part of FocusGuard Pro")) { EmptyView() }
            ZStack(alignment: .top) {
                AskSkeleton()
                    .opacity(0.45)
                    .blur(radius: 1.5)
                    .saturation(0.6)
                    .accessibilityHidden(true)
                card.padding(.top, 36)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
                ProBadge()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Questions about your own focus")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Ask when you focus best, what pulls you away, or how this week went. FocusGuard answers from the time it tracked.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                point(String(localized: "Plain answers"), String(localized: "With the numbers behind them and a small chart."))
                point(String(localized: "One click to act"), String(localized: "Set a daily limit or plan a session from the answer."))
                point(String(localized: "On this Mac"), String(localized: "Worked out here. Nothing leaves it."))
            }
            VStack(spacing: 8) {
                if entitlements.canStartTrial {
                    Button("Try Pro free for \(Plan.trialDays) days") {
                        entitlements.startTrialIfNeeded(for: .ask)
                    }
                    .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                } else {
                    Button("Get Pro") { openSheet(.upgrade(.ask)) }
                        .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                }
                Button("See everything in Pro") { openSheet(.upgrade(.ask)) }
                    .buttonStyle(.textLink)
                    .frame(height: 32)
            }
            .padding(.top, 4)
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 28, leading: 30, bottom: 24, trailing: 30))
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.18), radius: 30, y: 24)
        .frame(maxWidth: .infinity)
    }

    private var footnote: String {
        entitlements.canStartTrial
            ? String(localized: "Then \(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
            : String(localized: "\(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
    }

    private func point(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.focusFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The faded shapes of a conversation behind the card.
private struct AskSkeleton: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Capsule().fill(Theme.focusTint).frame(width: 180, height: 32)
            }
            WindowCard(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 240, height: 12)
                        Capsule().fill(Theme.track).frame(height: 8)
                        Capsule().fill(Theme.track).frame(width: 200, height: 8)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        let heights: [CGFloat] = [0.6, 0.9, 0.95, 0.85, 0.55, 0.45, 0.5, 0.6]
                        ForEach(heights.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(heights[index] > 0.8 ? Theme.focus : Theme.focusSoft)
                                .frame(width: 22, height: 64 * heights[index])
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Capsule().fill(Theme.focusTint).frame(width: 220, height: 32)
            }
            WindowCard { Color.clear }.frame(height: 130)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }
}
