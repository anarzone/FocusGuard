import SwiftUI

/// Two date pickers for picking a custom from/to window. Used by Reports.
struct CustomRangeSheet: View {
    @Binding var from: Date
    @Binding var to: Date
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom range")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                DatePicker("To", selection: $to, in: from..., displayedComponents: [.date])
                    .datePickerStyle(.compact)
            }

            Text("Reports will show data between these days, inclusive.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    onApply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
