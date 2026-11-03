import SwiftUI

/// A month in review (Pro): a headline, what changed against the month
/// before, how the coach's experiments went, and, for the month that ended
/// last, two things to try next.
struct MonthReviewSheet: View {
    let monthStart: Date
    var reviewer: MonthReviewer = .shared

    @Environment(\.dismiss) private var dismiss

    private var month: DateInterval {
        reviewer.calendar.dateInterval(of: .month, for: monthStart) ?? DateInterval(start: monthStart, duration: 30 * 86_400)
    }

    private var name: String { monthStart.formatted(.dateTime.month(.wide)) }
    private var isLatest: Bool { reviewer.lastFinishedMonth?.start == month.start }

    var body: some View {
        let review = reviewer.review(for: month)
        return VStack(alignment: .leading, spacing: 16) {
            header
            if let review {
                if review.hasData {
                    content(review)
                } else {
                    Text("Too little was tracked in \(name) for a review.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bodyText)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at \(name)…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            footer(review)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 640)
        .background(Theme.windowBackground)
        .task { await reviewer.load(month) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                        .accessibilityHidden(true)
                    Text("\(name) in review")
                        .font(.system(size: 17, weight: .bold))
                        .kerning(-0.17)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    ProBadge()
                }
                Text("\(range) · worked out on this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.bodyText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    /// "1–31 October".
    private var range: String {
        (month.start..<month.end.addingTimeInterval(-1)).formatted(.interval.day().month(.wide))
    }

    // MARK: - The review

    @ViewBuilder private func content(_ review: MonthReview) -> some View {
        Text(review.headline)
            .font(.system(size: 16, weight: .semibold))
            .kerning(-0.16)
            .lineSpacing(2)
            .foregroundStyle(Theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)

        if !review.changes.isEmpty {
            section(String(localized: "What changed")) {
                ForEach(review.changes, id: \.self) { CoachPointRow(point: $0, size: 13) }
            }
        }

        section(String(localized: "Your experiments")) { experiments }

        if isLatest && !review.suggestions.isEmpty {
            section(reviewer.tryHeading) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(review.suggestions) { suggestion in
                        SuggestionCard(suggestion: suggestion, reviewer: reviewer)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let problem = reviewer.coach.monthProblem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    @ViewBuilder private var experiments: some View {
        let lines = reviewer.trials(in: month)
        if lines.isEmpty {
            Text("No coach experiments ran in \(name). The weekly coach suggests one each Monday.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(lines) { line in
                HStack(spacing: 10) {
                    Text(line.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.result)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(line.improved ? Theme.link : Theme.secondaryText)
                        .lineLimit(1)
                    Text(line.status)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 120, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: - Footer

    private func footer(_ review: MonthReview?) -> some View {
        HStack(spacing: 8) {
            Text(review?.onDevice == true
                 ? "Every number comes from your tracked time. Apple Intelligence on this Mac wrote the headline."
                 : "Every number comes from your tracked time.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .buttonStyle(.capsule(.primary, height: 30))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// One of "Try in November": the experiment, the pattern behind it, and
/// "Try it" (or, once tried, until when and "Undo").
private struct SuggestionCard: View {
    let suggestion: MonthSuggestion
    let reviewer: MonthReviewer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.experiment.title())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(suggestion.reason)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let trial = reviewer.trial(for: suggestion) {
                HStack(spacing: 8) {
                    Text("On until \(trial.week.end.addingTimeInterval(-1).formatted(.dateTime.day().month(.wide))).")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .help(suggestion.experiment.effect())
                    Button("Undo") { reviewer.undo(suggestion) }.buttonStyle(.textLink)
                }
                .padding(.top, 2)
            } else {
                Button("Try it") { reviewer.tryIt(suggestion) }
                    .buttonStyle(.capsule(.primary, height: 26))
                    .help(suggestion.experiment.effect())
                    .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Theme.focusTint.opacity(0.7)))
        .overlay(shape.strokeBorder(Theme.focus.opacity(0.28), lineWidth: 0.5))
    }
}
