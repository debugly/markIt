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
        .alert("是否保存未命名的文件？", isPresented: $state.showUnsavedAlert) {
            Button("保存") { state.resolveUnsavedDecision(.save) }
            Button("放弃", role: .destructive) { state.resolveUnsavedDecision(.discard) }
            Button("取消", role: .cancel) { state.resolveUnsavedDecision(.cancel) }
        } message: {
            Text("你的更改尚未保存。")
        }
    }
}
