import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var isPickingFolder = false

    var body: some View {
        HSplitView {
            if state.showSidebar {
                SidebarView(state: state)
            }

            EditorPreviewContainer(state: state)
        }
        .background(.regularMaterial)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    isPickingFolder = true
                } label: {
                    Label("添加目录", systemImage: "folder.badge.plus")
                }

                Divider()

                Button {
                    state.showSidebar.toggle()
                } label: {
                    Label("目录", systemImage: "sidebar.leading")
                }

                Button {
                    state.showEditor.toggle()
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }

                Button {
                    state.showPreview.toggle()
                } label: {
                    Label("预览", systemImage: "doc.richtext")
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [UTType.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach { state.addRootFolder($0, storeBookmark: true) }
            case .failure:
                break
            }
        }
        .onChange(of: state.selection) { newValue in
            state.handleSelection(newValue)
        }
        .onChange(of: state.showSidebar) { _ in state.closeWindowIfNeeded() }
        .onChange(of: state.showEditor) { _ in state.closeWindowIfNeeded() }
        .onChange(of: state.showPreview) { _ in state.closeWindowIfNeeded() }
    }
}
