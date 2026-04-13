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
                Button {
                    selectedStyle = style
                    state.setPreviewStyle(style)
                } label: {
                    HStack {
                        Text(style)
                            .foregroundStyle(selectedStyle == style ? .blue : .primary)
                        Spacer()
                        if selectedStyle == style {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            let styles = contents
                .filter { $0.hasSuffix(".css") }
                .sorted()
            availableStyles = ["无"] + styles
            selectedStyle = state.previewStyle
        }
    }
}
