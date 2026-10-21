import AppKit
import SwiftUI

/// Whether to tone motion down: the system's Reduce motion, or FocusGuard's
/// own toggle in Settings › Appearance. Either one is enough.
enum Motion {
    static func isReduced(system: Bool, app: Bool) -> Bool { system || app }

    /// For AppKit code that can't read the SwiftUI environment.
    @MainActor
    static var isReduced: Bool {
        isReduced(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  app: UserDefaults.standard.bool(forKey: SettingsKeys.reduceMotion))
    }

    /// `transition`, or a plain cross-fade when motion is reduced.
    static func transition(_ transition: AnyTransition, reduced: Bool) -> AnyTransition {
        reduced ? .opacity : transition
    }
}

/// `Motion.isReduced` for SwiftUI views, kept live as either setting changes.
@propertyWrapper
struct ReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @AppStorage(SettingsKeys.reduceMotion) private var app = false

    var wrappedValue: Bool { Motion.isReduced(system: system, app: app) }
}
