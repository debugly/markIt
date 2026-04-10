import SwiftUI

struct EditorView: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(
                get: { document.text },
                set: { document.updateText($0) }
            ))
            .font(.system(.body, design: .monospaced))
            .padding(12)
        }
        .frame(minWidth: 320)
    }
}
