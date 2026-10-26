import AppKit
import Foundation
import SwiftData

/// A snapshot of "what the user is currently doing" for the UI to display.
struct ActivitySnapshot: Equatable {
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String?
    let url: String?
    let classification: Classification
    let observedAt: Date
}

extension ActivitySnapshot {
    /// The same moment treated as neutral — used while FocusGuard is frontmost.
    func asNeutral(at date: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleIdentifier, appName: appName, windowTitle: windowTitle,
                         url: url, classification: .neutral, observedAt: date)
    }
}

/// Runs the always-on tracking loop. On each tick (1 Hz, plus immediate on app
/// switch) it samples the frontmost app + window title and either extends the
/// current `ActivityEvent` or coalesces into a new one when the
/// (bundleId, windowTitle, url) tuple changes.
@MainActor
@Observable
final class ActivityTracker {
    private(set) var currentSnapshot: ActivitySnapshot?
    /// Most recent app classified as focus — where "Back to work" returns to.
    private(set) var lastFocusBundleId: String?
    /// True while FocusGuard itself is frontmost. Its own windows aren't
    /// tracked, can't count as drift, and keep the session from looking idle.
    private(set) var isFrontmostSelf = false
    /// True while nobody's at the Mac (no input for `IdleMonitor.awayAfter`
    /// and nothing like a video keeping the display awake). Nothing is
    /// recorded meanwhile.
    private(set) var isAway = false
    /// Last tick with the user at the Mac (any app, FocusGuard included).
    /// Drives idle auto-pause, which `currentSnapshot` can't once FocusGuard
    /// is frontmost (the snapshot keeps showing the last real app).
    private(set) var lastActiveAt: Date?

    /// FocusGuard's own bundle id; time in its windows isn't recorded.
    static let selfBundleId = Bundle.main.bundleIdentifier ?? "com.anar.focusguard"

    /// Set by `SessionManager` when a focus session starts/stops. Newly created
    /// `ActivityEvent`s pick up this association at insert time.
    var currentSession: Session? {
        didSet {
            // Split the in-flight event at the session boundary (start, pause,
            // resume, stop). Otherwise the app you're already in when a
            // session starts keeps extending an event with no session, and
            // that time never counts toward it.
            guard oldValue?.id != currentSession?.id, let event = currentEvent else { return }
            event.endedAt = .now
            currentEvent = nil
        }
    }

    /// Optional callback invoked every tick. SessionManager hooks this to
    /// enforce planned-duration auto-stop and to feed the escalation engine.
    var onTick: (() -> Void)?

    /// The browser extension's report for a browser, nil when none is
    /// connected for it (set by AppState). Used instead of AppleScript when
    /// present: no Automation prompt, and titles without Screen Recording.
    var extensionTab: ((_ bundleId: String) -> ExtensionTab?)?

    /// Called when a new event starts (another app, page or title). Smart
    /// categories watch it for things not sorted yet.
    var onNewEvent: ((ActivityEvent) -> Void)?

    private let context: ModelContext
    private let inspector: WindowInspector
    private let browserReader: BrowserTabReader
    private let optOutCache: TitleOptOutCache
    private let classifier: Classifier

    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var currentEvent: ActivityEvent?
    /// Wall-clock of last `context.save()`. We coalesce saves so we don't
    /// burn through SQLite WAL writes when the user switches apps rapidly.
    private var lastSaveAt: Date = .distantPast

    init(
        context: ModelContext,
        optOutCache: TitleOptOutCache,
        classifier: Classifier,
        inspector: WindowInspector = WindowInspector(),
        browserReader: BrowserTabReader? = nil
    ) {
        self.context = context
        self.optOutCache = optOutCache
        self.classifier = classifier
        self.inspector = inspector
        self.browserReader = browserReader ?? BrowserTabReader()
    }

    func start() {
        guard timer == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to the main actor; the closure itself is a Sendable boundary.
            Task { @MainActor in self?.tick() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        tick()  // sample immediately on start
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObserver = nil
        flush()
    }

    /// Persist the current event. Call before quitting or before reading totals.
    func flush() {
        guard context.hasChanges else { return }
        Persistence.save(context)
        lastSaveAt = .now
    }

    /// System processes that take frontmost focus when the Mac is locked,
    /// asleep, or showing the screensaver. Counting time on these as
    /// activity inflates "neutral" for hours of actual idle time.
    private static let idleProcessBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.WindowManager",
    ]

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }

        // Skip ticks when the Mac is locked / asleep / on screensaver. We
        // also need to flush any in-flight event so its endedAt doesn't
        // stretch through the lock period — otherwise a 9-hour overnight
        // lock looks like 9 hours of activity in the last app you used.
        if Self.idleProcessBundleIds.contains(bundleId) {
            isFrontmostSelf = false
            if currentEvent != nil {
                Persistence.save(context)
                currentEvent = nil
            }
            return
        }

        // Away from the Mac: end the event in progress at the last input, so
        // the idle stretch isn't counted, and record nothing until they're back.
        // `lastActiveAt` points at the last input so idle auto-pause fires on time.
        let idleSeconds = IdleMonitor.secondsSinceInput()
        if idleSeconds >= IdleMonitor.awayAfter,
           IdleMonitor.isAway(idleSeconds: idleSeconds, displayKeptAwake: IdleMonitor.displayKeptAwake()) {
            let lastInput = Date().addingTimeInterval(-idleSeconds)
            isAway = true
            isFrontmostSelf = false
            lastActiveAt = lastInput
            if let event = currentEvent {
                event.endedAt = max(event.startedAt, min(event.endedAt, lastInput))
                Persistence.save(context)
                currentEvent = nil
            }
            onTick?()
            return
        }
        isAway = false

        // FocusGuard's own menu/window: close the event in progress and
        // record nothing. The user is still here, so stay "active".
        isFrontmostSelf = bundleId == Self.selfBundleId
        lastActiveAt = Date()
        if isFrontmostSelf {
            if currentEvent != nil {
                Persistence.save(context)
                currentEvent = nil
            }
            onTick?()
            return
        }

        let appName = app.localizedName ?? bundleId
        let extensionTab = extensionTab?(bundleId)
        let title: String? = optOutCache.isOptedOut(bundleId)
            ? nil
            : extensionTab?.title ?? inspector.frontmostWindowTitle(forPID: app.processIdentifier)
        let url: String?
        if let extensionTab {
            url = extensionTab.url
        } else if BrowserTabReader.isBrowser(bundleIdentifier: bundleId) {
            url = browserReader.currentURL(forBundleId: bundleId)
        } else {
            url = nil
        }
        let classification = classifier.classify(bundleId: bundleId, windowTitle: title, url: url)
        let now = Date()
        if classification == .focus {
            lastFocusBundleId = bundleId
        }

        currentSnapshot = ActivitySnapshot(
            bundleIdentifier: bundleId,
            appName: appName,
            windowTitle: title,
            url: url,
            classification: classification,
            observedAt: now
        )

        if let event = currentEvent,
           event.bundleIdentifier == bundleId,
           event.windowTitle == title,
           event.url == url {
            // Same activity; just extend the window.
            event.endedAt = now
        } else {
            let new = ActivityEvent(
                startedAt: now,
                endedAt: now,
                bundleIdentifier: bundleId,
                appName: appName,
                windowTitle: title,
                url: url,
                session: currentSession
            )
            new.classification = classification
            context.insert(new)
            currentEvent = new
            onNewEvent?(new)
        }

        // Coalesced save: hold pending mutations in the context for up to
        // `saveCoalesceInterval` seconds, then flush. `flush()` and
        // `applicationWillTerminate` always force a save.
        if Date().timeIntervalSince(lastSaveAt) >= Constants.Tracking.saveCoalesceInterval {
            Persistence.save(context)
            lastSaveAt = .now
        }

        onTick?()
    }
}
