import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center control: on starts a session of the usual length,
/// off ends it (or the break). It shows the shield's state and the time
/// left. People pick its size in Control Center.
@available(macOS 26.0, *)
struct FocusControl: ControlWidget {
    static let kind = "com.anar.focusguard.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: FocusControlProvider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: ControlSessionIntent()) {
                Label(value.title, systemImage: value.symbol)
            } valueLabel: { _ in
                Text(value.detail)
            }
            .tint(Color(hex: 0x6155F5))
        }
        .displayName("FocusGuard")
        .description("Start or end a focus session, and see the time left.")
    }
}

@available(macOS 26.0, *)
struct FocusControlProvider: ControlValueProvider {
    var previewValue: FocusControlValue {
        FocusControlValue.from(nil, at: .now)
    }

    func currentValue() async throws -> FocusControlValue {
        let now = Date()
        return FocusControlValue.from(SurfaceStore.shared?.readSnapshot()?.projected(to: now), at: now)
    }
}
