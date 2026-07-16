import SwiftUI

struct NamePromptSheet: View {
    let title: String
    let message: String
    let confirmLabel: String
    let initialValue: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("名称", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                Button(confirmLabel) {
                    onConfirm(text)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            text = initialValue
        }
    }
}
