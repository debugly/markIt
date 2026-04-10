import SwiftUI

struct SharedEditorToolbar: View {
    @ObservedObject var document: DocumentModel

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
            Text(fileTitle)
                .font(.headline)
            Spacer()
            if document.url != nil {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
