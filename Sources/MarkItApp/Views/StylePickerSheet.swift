import SwiftUI

struct StylePickerSheet: View {
    @ObservedObject var state: AppState
    @State private var availableStyles: [String] = []
    @State private var selectedStyle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("选择渲染样式")
                .font(.headline)
                .padding()

            List(availableStyles, id: \.self) { style in
                Button(style) {
                    selectedStyle = style
                    state.setPreviewStyle(style)
                }
                .buttonStyle(.plain)
                .frame(height: 34)
                .foregroundStyle(selectedStyle == style ? .blue : .primary)
            }
        }
        .frame(width: 260, height: 350)
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
