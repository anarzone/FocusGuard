import SwiftUI
import WidgetKit

/// A small widget that's mostly a button: start a session of the usual
/// length, or end the one running.
struct StartWidget: Widget {
    static let kind = "com.anar.focusguard.start"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            StartWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Start a Session")
        .description("Start a focus session of your usual length in one click.")
        .supportedFamilies([.systemSmall])
    }
}

struct StartWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { Palette(scheme: scheme) }

    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    ShieldMark(color: palette.focus)
                    Text(heading(s)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                content(s)
                Spacer(minLength: 4)
                button(s)
            }
        } else {
            OpenAppNote(palette: palette)
        }
    }

    private func heading(_ s: SurfaceSnapshot) -> String {
        switch s.phase {
        case .ready:             return "FocusGuard"
        case .focusing, .paused: return s.session?.name ?? "Focusing"
        case .onBreak:           return "Break"
        }
    }

    @ViewBuilder
    private func content(_ s: SurfaceSnapshot) -> some View {
        switch s.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 2) {
                Text(SurfaceWords.duration(s.today.focused)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text("focused today").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .focusing, .paused:
            VStack(alignment: .leading, spacing: 2) {
                SessionClock(snapshot: s, date: entry.date).font(.system(size: 22, weight: .semibold))
                Text(caption(s)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .onBreak:
            VStack(alignment: .leading, spacing: 2) {
                BreakClock(snapshot: s, date: entry.date).font(.system(size: 22, weight: .semibold))
                if let end = s.onBreak?.endsAt {
                    Text("back at \(SurfaceWords.clock(end))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func caption(_ s: SurfaceSnapshot) -> String {
        if s.phase == .paused { return "paused" }
        return s.sessionEndsAt.map { "ends \(SurfaceWords.clock($0))" } ?? "so far"
    }

    @ViewBuilder
    private func button(_ s: SurfaceSnapshot) -> some View {
        switch s.phase {
        case .ready:
            Button(intent: WidgetStartIntent(minutes: s.usualMinutes)) {
                PillLabel(title: "Start \(s.usualMinutes) min", prominent: true, palette: palette)
            }
            .buttonStyle(.plain)
        case .focusing, .paused:
            SessionButtons(paused: s.phase == .paused, palette: palette)
        case .onBreak:
            BreakButtons(canEnd: s.onBreak?.canEndEarly ?? true, palette: palette)
        }
    }
}
