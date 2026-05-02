import AppKit
import CoreGraphics

struct WindowInspector {
    /// Returns the window title of the frontmost on-screen window for the given pid,
    /// or nil if Screen Recording permission isn't granted, the app has no titled
    /// window, or the title is empty.
    func frontmostWindowTitle(forPID pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is ordered front-to-back. We want the first normal-layer window
        // owned by this pid that has a non-empty title.
        for window in windows {
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? -1
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            guard ownerPID == pid, layer == 0 else { continue }
            if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
