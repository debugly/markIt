import SwiftUI

struct EditorView: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(
                get: { document.text },
                set: { document.updateText($0) }
            ))
            .font(.system(size: Typography.editorFontSize, weight: .regular, design: .monospaced))
            .padding(12)
            .background(Color.clear)
            .clearScrollBackgroundIfAvailable()
        }
        .frame(minWidth: 500, idealWidth: 500)
    }
}
