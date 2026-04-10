import MarkdownUI
import SwiftUI

struct PreviewView: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if document.text.isEmpty {
                    PlaceholderView(
                        title: "暂无内容",
                        systemImage: "doc.richtext",
                        message: "开始编辑以查看预览"
                    )
                } else {
                    Markdown(document.text)
                        .markdownTheme(.gitHub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .frame(minWidth: 320)
    }
}
