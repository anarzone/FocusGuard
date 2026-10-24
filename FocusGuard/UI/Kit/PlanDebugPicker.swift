#if DEBUG
import SwiftUI

/// Debug builds only: pretend to be on Free, the trial or Pro. Drop it into
/// any settings pane; `-plan.debugOverride pro` at launch does the same.
struct PlanDebugPicker: View {
    var entitlements: Entitlements = .shared

    var body: some View {
        Picker("Plan (debug)", selection: Binding(
            get: { entitlements.debugOverride },
            set: { entitlements.debugOverride = $0 }
        )) {
            Text("Real plan").tag(Entitlements.DebugPlan?.none)
            Text("Free").tag(Entitlements.DebugPlan?.some(.free))
            Text("Trial, 9 days left").tag(Entitlements.DebugPlan?.some(.trial(daysLeft: 9)))
            Text("Trial, 2 days left").tag(Entitlements.DebugPlan?.some(.trial(daysLeft: 2)))
            Text("Pro").tag(Entitlements.DebugPlan?.some(.pro))
        }
    }
}
#endif
