import SwiftUI
import AppKit

/// Modal shown when a planned-duration session completes. Lets the user pick
/// between taking a break (default), starting another session, or just
/// stopping. Hosts itself in a free-floating panel so it works whether the
/// main window is open or not.
@MainActor
final class SessionEndChoiceController {
    private var window: NSWindow?

    func present(
        completedLabel: String?,
        focusMinutes: Int,
        suggestedBreakMinutes: Int,
        suggestedNextSessionMinutes: Int,
        onTakeBreak: @escaping (Int) -> Void,
        onStartNew: @escaping (Int, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard window == nil else { return }

        let view = SessionEndChoiceView(
            completedLabel: completedLabel,
            focusMinutes: focusMinutes,
            suggestedBreakMinutes: suggestedBreakMinutes,
            suggestedNextSessionMinutes: suggestedNextSessionMinutes,
            onTakeBreak: { [weak self] minutes in
                self?.close()
                onTakeBreak(minutes)
            },
            onStartNew: { [weak self] minutes, label in
                self?.close()
                onStartNew(minutes, label)
            },
            onDismiss: { [weak self] in
                self?.close()
                onDismiss()
            }
        )

        let host = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Session complete"
        win.titlebarAppearsTransparent = true
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    /// Defer orderOut to the next runloop turn so the in-flight button action
    /// (which lives inside the hosted SwiftUI view) finishes before AppKit
    /// tears down the window's view hierarchy.
    func close() {
        let win = window
        window = nil
        DispatchQueue.main.async {
            win?.orderOut(nil)
        }
    }
}

private struct SessionEndChoiceView: View {
    let completedLabel: String?
    let focusMinutes: Int
    let suggestedBreakMinutes: Int
    let suggestedNextSessionMinutes: Int
    var onTakeBreak: (Int) -> Void
    var onStartNew: (Int, String?) -> Void
    var onDismiss: () -> Void

    @State private var breakMinutes: Int
    @State private var nextSessionMinutes: Int
    @State private var nextLabel: String

    init(
        completedLabel: String?,
        focusMinutes: Int,
        suggestedBreakMinutes: Int,
        suggestedNextSessionMinutes: Int,
        onTakeBreak: @escaping (Int) -> Void,
        onStartNew: @escaping (Int, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.completedLabel = completedLabel
        self.focusMinutes = focusMinutes
        self.suggestedBreakMinutes = suggestedBreakMinutes
        self.suggestedNextSessionMinutes = suggestedNextSessionMinutes
        self.onTakeBreak = onTakeBreak
        self.onStartNew = onStartNew
        self.onDismiss = onDismiss
        self._breakMinutes = State(initialValue: suggestedBreakMinutes)
        self._nextSessionMinutes = State(initialValue: suggestedNextSessionMinutes)
        self._nextLabel = State(initialValue: completedLabel ?? "Deep work")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session complete")
                    .font(.system(size: 22, weight: .semibold))
                Text("Great work. \(focusMinutes) min of focus" + (completedLabel.map { " on \($0)" } ?? "") + ".")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            // Take a break section
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(Theme.focus)
                    Text("Take a break").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(breakMinutes) min")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                    Stepper("", value: $breakMinutes, in: 1...60, step: 1)
                        .labelsHidden()
                        .fixedSize()
                }
                Button {
                    onTakeBreak(breakMinutes)
                } label: {
                    Text("Start \(breakMinutes)-min break")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.focus)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Start another session section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Or skip the break and start another session")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                HStack(spacing: 10) {
                    TextField("Label", text: $nextLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Text("\(nextSessionMinutes) min")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                    Stepper("", value: $nextSessionMinutes, in: 5...240, step: 5)
                        .labelsHidden()
                        .fixedSize()
                    Spacer()
                    Button("Start") {
                        onStartNew(nextSessionMinutes, nextLabel.isEmpty ? nil : nextLabel)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            HStack {
                Spacer()
                Button("Done for now") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
    }
}
