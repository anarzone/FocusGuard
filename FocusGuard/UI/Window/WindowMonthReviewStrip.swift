import SwiftUI

/// Reports › Month, at the top: "Month in review · October is ready", one
/// line like the weekly coach's, opening the review. On the current month
/// it's for the month that ended last; on an earlier one, for that month.
/// Free users see a dashed row that starts the trial.
struct WindowMonthReviewStrip: View {
    let month: DateInterval
    /// The month that ended last: "October is ready."
    let isLatest: Bool
    var reviewer: MonthReviewer = .shared
    var entitlements: Entitlements = .shared
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        Group {
            if entitlements.isUnlocked(.monthlyReview) {
                card
            } else {
                locked
            }
        }
        .task(id: "\(month.start.timeIntervalSinceReferenceDate)-\(entitlements.isUnlocked(.monthlyReview))") {
            await reviewer.load(month)
        }
    }

    private var name: String { month.start.formatted(.dateTime.month(.wide)) }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let review = reviewer.review(for: month)
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.focus)
                    .accessibilityHidden(true)
                Text("Month in review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                ProBadge()
            }
            .fixedSize()
            summary(review)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(review?.headline ?? "")
            Spacer(minLength: 8)
            if review?.hasData != false {
                Button("Open") { openSheet(.monthReview(month.start)) }
                    .buttonStyle(.capsule(.primary, height: 26))
                    .fixedSize()
                    .accessibilityLabel("Open \(name) in review")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(shape.fill(Theme.windowCard))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    /// "October is ready. Mornings got stronger. Before noon rose from 78% to 91%."
    private func summary(_ review: MonthReview?) -> Text {
        let lead = Text(isLatest ? "\(name) is ready." : "\(name).").fontWeight(.semibold).foregroundColor(Theme.primaryText)
        guard let review else {
            return reviewer.isLoading(month)
                ? lead + Text(verbatim: " ") + Text("Looking at the month…").foregroundColor(Theme.bodyText)
                : lead
        }
        guard review.hasData else {
            return Text("Too little was tracked in \(name) for a review.").foregroundColor(Theme.bodyText)
        }
        let teaser = review.changes.first?.sentence ?? review.headline
        return lead + Text(verbatim: " \(teaser)").foregroundColor(Theme.bodyText)
    }

    private var locked: some View {
        HStack(spacing: 10) {
            ProBadge()
            Text("Month in review: what changed, how your experiments went, and two things to try next.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(1)
            Spacer(minLength: 8)
            if entitlements.canStartTrial {
                Button("Try Pro free") {
                    entitlements.startTrialIfNeeded(for: .monthlyReview)
                    Task { await reviewer.load(month) }
                }
                .buttonStyle(.textLink)
            } else {
                Button("See Pro") { openSheet(.upgrade(.monthlyReview)) }.buttonStyle(.textLink)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.lockedFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
}
