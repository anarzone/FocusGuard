import SwiftUI

struct CustomDurationSheet: View {
    @Binding var minutes: Int
    var onDismiss: (Int?) -> Void

    private let minMinutes = 5
    private let maxMinutes = 480

    private var isValid: Bool { minutes >= minMinutes && minutes <= maxMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom session length")
                    .font(.system(size: 17, weight: .semibold))
                Text("Pick a duration in minutes. Sessions stop automatically when reached.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Spacer()
                    TextField("", value: $minutes, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isValid ? .primary : Theme.distraction)
                        .frame(width: 110)
                    Text("min")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                    Stepper("", value: $minutes, in: minMinutes...maxMinutes, step: 5)
                        .labelsHidden()
                    Spacer()
                }
                if !isValid {
                    Text("Pick a value between \(minMinutes) and \(maxMinutes) minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.distraction)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.fill3, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: minutes) { _, newValue in
                // Hard upper cap. Lower bound is left alone while typing so the
                // user can clear the field and start over.
                if newValue > maxMinutes { minutes = maxMinutes }
            }

            // Quick presets
            HStack(spacing: 6) {
                ForEach([15, 45, 75, 120], id: \.self) { preset in
                    Button("\(preset)m") { minutes = preset }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            HStack {
                Button("Cancel") { onDismiss(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isValid ? "Start \(minutes)m session" : "Start session") {
                    if isValid { onDismiss(minutes) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
