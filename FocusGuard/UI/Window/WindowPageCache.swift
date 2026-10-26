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
    /// when the window opens, what each opens on first: even the first
    /// switch to them, or to Month, then shows at once. The others load in
    /// a few milliseconds when opened.
    func warm(_ appState: AppState, weekendsCount: Bool) async {
        // What each page opens on first, then the other choices.
        await warmReport(.week, appState, weekendsCount: weekendsCount)
        await warmApps(.week, appState)
        await warmReport(.month, appState, weekendsCount: weekendsCount)
        await warmApps(.today, appState)
        await warmApps(.month, appState)
    }

    private func warmReport(_ period: ReportPeriod, _ appState: AppState, weekendsCount: Bool) async {
        let key = Self.reportsKey(period, 0)
        guard reports[key] == nil else { return }
        reports[key] = await appState.stats.reports(period: period, offset: 0, now: .now,
                                                    historyStart: Entitlements.shared.historyStart(),
                                                    weekendsCount: weekendsCount)
    }

    private func warmApps(_ range: AppsRange, _ appState: AppState) async {
        guard apps[range] == nil else { return }
        let now = Date.now
        let rows = await appState.stats.usageRows(from: range.start(now: now), to: now, limit: AppsModelBuilder.usageLimit)
        apps[range] = AppsModelBuilder.items(rows: rows, classifier: appState.classifier, smart: AppsSitesPage.smart(appState))
    }
}
