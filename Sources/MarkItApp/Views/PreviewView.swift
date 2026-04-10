import MarkdownUI
import SwiftUI

struct PreviewView: View {
    @ObservedObject var document: DocumentModel
    @State private var isReady = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if !isReady {
                    ProgressView("正在加载预览…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if document.text.isEmpty {
                    PlaceholderView(
                        title: "暂无内容",
                        systemImage: "doc.richtext",
                        message: "开始编辑以查看预览"
                    )
                } else {
                    Markdown(document.text)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .background(Color.white)
            .clearScrollBackgroundIfAvailable()
        }
        .frame(minWidth: 500, idealWidth: 500)
        .onChange(of: document.url) { _ in
            delayPreview()
        }
        .onAppear {
            delayPreview()
        }
    }

    private func delayPreview() {
        isReady = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            isReady = true
        }
    }
}
