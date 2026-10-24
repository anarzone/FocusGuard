import SwiftUI
import WidgetKit

/// FocusGuard's desktop widgets and, on macOS 26, its Control Center
/// control. They read what the app writes to the shared App Group folder
/// (see `SurfaceStore`) and send their taps back to it.
@main
struct FocusGuardWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        StartWidget()
        if #available(macOS 26.0, *) {
            FocusControl()
        }
    }
}
