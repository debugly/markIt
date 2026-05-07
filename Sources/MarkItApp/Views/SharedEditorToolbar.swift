import SwiftUI

struct SharedEditorToolbar: View {
    @ObservedObject var state: AppState

    private var document: DocumentModel {
        state.document
    }

    private var fileTitle: String {
        document.url?.lastPathComponent ?? "未命名"
    }

    private var statsText: String {
        let text = document.text
        let lines = max(text.split(whereSeparator: \.isNewline).count, text.isEmpty ? 0 : 1)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "\(lines) 行 · \(words) 词"
    }

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 50)

            Button {
                state.showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("显示/隐藏目录")

            Text(fileTitle)
                .font(.headline)

            Spacer()

            Button {
                state.showEditor.toggle()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("显示/隐藏编辑器")

            if document.url != nil {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
