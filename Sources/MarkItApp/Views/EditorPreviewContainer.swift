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
                        .frame(minWidth: 200)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: EditorWidthPreferenceKey.self, value: geo.size.width)
                            }
                        )
                        .onPreferenceChange(EditorWidthPreferenceKey.self) { width in
                            if state.showEditor && !state.isTransitioning && width > 100 {
                                state.editorWidth = width
                            }
                        }
                        .frame(idealWidth: state.editorWidth)
                        .layoutPriority(1)
                }

                if state.showPreview {
                    PreviewView(document: state.document)
                }
            }
        }
    }
}

private struct EditorWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 500
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
