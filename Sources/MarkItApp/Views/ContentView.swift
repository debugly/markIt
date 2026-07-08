import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var isPickingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            SharedEditorToolbar(state: state)
            HSplitView {
                if state.showSidebar {
                    SidebarView(state: state)
                }
                EditorPreviewContainer(state: state)
                    .layoutPriority(1)
            }
        }
        .ignoresSafeArea(.container, edges: .top) // 强制忽略顶部安全区域
        .background(.regularMaterial)
        .background {
            ContentGaussianBlurBackground()
                .overlay(Color.white.opacity(0.08))
        }
        .background(WindowButtonAlignmentConfigurator())
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

private struct WindowButtonAlignmentConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            alignWindowButtons(in: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            alignWindowButtons(in: nsView.window)
        }
    }

    private func alignWindowButtons(in window: NSWindow?) {
        guard let window else { return }

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            var frame = button.frame
            frame.origin.y = 4
            button.frame = frame
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
