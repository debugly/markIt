import SwiftUI

struct StylePickerSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var availableStyles: [String] = []
    @State private var selectedStyle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("选择预览样式")
                .font(.headline)
                .padding()

            List(availableStyles, id: \.self) { style in
                Button(style) {
                    selectedStyle = style
                    state.setPreviewStyle(style)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedStyle == style ? .blue : .primary)
            }

            Spacer()

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 300, height: 400)
        .onAppear {
            loadStyles()
        }
    }

    private func loadStyles() {
        guard let url = Bundle.main.url(forResource: "GitHub", withExtension: "css") else {
            return
        }
        let directory = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            availableStyles = contents
                .filter { $0.hasSuffix(".css") }
                .sorted()
            selectedStyle = state.previewStyle
        }
    }
}