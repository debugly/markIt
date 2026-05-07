import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var isPickingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            SharedEditorToolbar(document: state.document)
            HSplitView {
                if state.showSidebar {
                    SidebarView(state: state)
                }
                EditorPreviewContainer(state: state)
            }
        }
        .ignoresSafeArea(.container, edges: .top) // 强制忽略顶部安全区域
        .background(.regularMaterial)
        .background {
            ContentGaussianBlurBackground()
                .overlay(Color.white.opacity(0.08))
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            state.openDroppedFiles(from: providers)
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

private struct ContentGaussianBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.blendingMode = .behindWindow
        nsView.material = .underWindowBackground
        nsView.state = .active
    }
}
