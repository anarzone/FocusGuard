import Foundation

/// The window's pages as last loaded, keyed by what they show. A page opens
/// on its entry and swaps in the fresh copy from `StatsStore` when it comes,
/// so switching pages never shows an empty page or waits on the store.
///
/// Not observed: pages read it while the window builds them, and reading
/// anything observed there would redraw the whole window when it changes.
@MainActor
final class WindowPageCache {
    var today: [Date: TodayPageData] = [:]
    var reports: [String: ReportsModel] = [:]
    var workLog: [Date: WorkLogModel] = [:]
    var apps: [AppsRange: [AppsItem]] = [:]

    static func reportsKey(_ period: ReportPeriod, _ offset: Int) -> String { "\(period.rawValue)-\(offset)" }

    /// Loads the slow pages, Reports and Apps & Sites, in the background
    /// when the window opens: even the first switch to them then shows them
    /// at once. The others load in a few milliseconds when opened.
    func warm(_ appState: AppState, weekendsCount: Bool) async {
        let stats = appState.stats, now = Date.now
        if reports[Self.reportsKey(.week, 0)] == nil {
            reports[Self.reportsKey(.week, 0)] = await stats.reports(
                period: .week, offset: 0, now: now, historyStart: Entitlements.shared.historyStart(),
                weekendsCount: weekendsCount)
        }
        if apps[.week] == nil {
            let rows = await stats.usageRows(from: AppsRange.week.start(now: now), to: now,
                                             limit: AppsModelBuilder.usageLimit)
            apps[.week] = AppsModelBuilder.items(rows: rows, classifier: appState.classifier,
                                                 smart: AppsSitesPage.smart(appState))
        }
    }
}
