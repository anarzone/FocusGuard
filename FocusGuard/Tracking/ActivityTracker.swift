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

/// Runs the always-on tracking loop. On each tick (1 Hz, plus immediate on app
/// switch) it samples the frontmost app + window title and either extends the
/// current `ActivityEvent` or coalesces into a new one when the
/// (bundleId, windowTitle, url) tuple changes.
@MainActor
@Observable
final class ActivityTracker {
    private(set) var currentSnapshot: ActivitySnapshot?

    /// Set by `SessionManager` when a focus session starts/stops. Newly created
    /// `ActivityEvent`s pick up this association at insert time.
    var currentSession: Session?

    /// Optional callback invoked every tick. SessionManager hooks this to
    /// enforce planned-duration auto-stop and to feed the escalation engine.
    var onTick: (() -> Void)?

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

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }

        let appName = app.localizedName ?? bundleId
        let title: String? = optOutCache.isOptedOut(bundleId)
            ? nil
            : inspector.frontmostWindowTitle(forPID: app.processIdentifier)
        let url: String? = BrowserTabReader.isBrowser(bundleIdentifier: bundleId)
            ? browserReader.currentURL(forBundleId: bundleId)
            : nil
        let classification = classifier.classify(bundleId: bundleId, windowTitle: title, url: url)
        let now = Date()

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
