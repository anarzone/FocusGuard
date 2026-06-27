import Foundation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest of
/// the app drives update checks without importing Sparkle everywhere. Owned by
/// `AppState` for the lifetime of the process.
///
/// Constructing it with `startingUpdater: true` also kicks off Sparkle's
/// scheduled background checks — cadence is governed by `SUEnableAutomaticChecks`
/// / `SUScheduledCheckInterval` in Info.plist (we enable automatic checks and
/// leave the interval at Sparkle's 24h default). Updates are fetched from
/// `SUFeedURL` and verified against `SUPublicEDKey`; see scripts/release.sh for
/// how each release zip is EdDSA-signed.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors the updater's `canCheckForUpdates`, so a "Check for Updates…"
    /// button can disable itself while a check is already running.
    @Published private(set) var canCheckForUpdates = false

    /// Reflects Sparkle's automatic-check preference. Drive changes through
    /// `setAutomaticChecks(_:)` — setting this directly won't update Sparkle.
    @Published private(set) var automaticallyChecksForUpdates = true

    private var canCheckObservation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        // `canCheckForUpdates` is KVO-compliant and flips false mid-check.
        // Sparkle mutates it on the main thread; hop back to the main actor
        // anyway to satisfy isolation.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// Shows Sparkle's standard update UI. With no newer version available it
    /// reports "you're up to date".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Toggles Sparkle's scheduled background checks.
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}
