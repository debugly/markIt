import SwiftUI

struct EditorPreviewContainer: View {
    @ObservedObject var state: AppState

    private var hasContent: Bool {
        state.showEditor || state.showPreview
    }

    var body: some View {
        if hasContent {
            VStack(spacing: 0) {
                SharedEditorToolbar(document: state.document)
                HSplitView {
                    if state.showEditor {
                        EditorView(document: state.document)
                    }

                    if state.showPreview {
                        PreviewView(document: state.document)
                    }
                }
            }.ignoresSafeArea(.container, edges: .top) // 强制忽略顶部安全区域
        }
    }
}
