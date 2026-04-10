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
            .lineSpacing(4)
            .padding(12)
            .background(Color.init(red: 255/255.0, green: 252/255.0, blue: 234/255.0))
            .clearScrollBackgroundIfAvailable()
        }
        .frame(minWidth: 500, idealWidth: 500)
    }
}
