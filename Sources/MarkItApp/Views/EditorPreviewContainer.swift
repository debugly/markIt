import SwiftUI

struct EditorPreviewContainer: View {
    @ObservedObject var state: AppState

    private var hasContent: Bool {
        state.showEditor || state.showPreview
    }

    var body: some View {
        if hasContent {
            HSplitView {
                if state.showEditor {
                    EditorView(document: state.document)
                }

                if state.showPreview {
                    PreviewView(document: state.document)
                }
            }
        }
    }
}
