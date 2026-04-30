import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var state: AppState
    @State private var prompt: PromptContext? = nil
    @State private var deleteTarget: URL? = nil
    @State private var isPickingFolder = false
    @State private var showingStylePicker = false
    @State private var dropTargetURL: URL? = nil
    @State private var expandedDirectories: Set<URL> = []
    @State private var knownDirectoryURLs: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.tree) { node in
                        SidebarTreeNodeView(
                            state: state,
                            node: node,
                            depth: 0,
                            expandedDirectories: $expandedDirectories,
                            dropTargetURL: $dropTargetURL,
                            openPrompt: openPrompt,
                            deleteTarget: $deleteTarget
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .animation(nil, value: state.tree)
            .contextMenu {
                Button("打开文件夹") { state.promptOpenFolder() }
            }
            .onAppear {
                syncExpandedDirectories(with: state.tree)
            }
            .onChange(of: state.tree) { newTree in
                syncExpandedDirectories(with: newTree)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    isPickingFolder = true
                } label: {
                    Label("打开文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .focusable(false)

                Spacer()

                Divider()
                    .frame(height: 16)

                Button {
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("设置")

                Button {
                    showingStylePicker = true
                } label: {
                    Image(systemName: "paintpalette")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("样式")
                .popover(isPresented: $showingStylePicker) {
                    StylePickerSheet(state: state)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 280, idealWidth: 280, maxWidth: 320)
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
        .sheet(item: $prompt) { context in
            NamePromptSheet(
                title: context.title,
                message: context.message,
                confirmLabel: context.confirmLabel,
                initialValue: context.initialValue,
                onCancel: { prompt = nil },
                onConfirm: { input in
                    handlePrompt(context, input: input)
                    prompt = nil
                }
            )
        }
        .alert("确认删除该文件？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    state.deleteItem(at: target)
                }
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text(target.lastPathComponent)
            }
        }
    }

    private func openPrompt(_ context: PromptContext) {
        prompt = context
    }

    private func handlePrompt(_ context: PromptContext, input: String) {
        switch context {
        case .newFolder(let parent):
            state.createFolder(named: input, in: parent)
        case .newFile(let parent):
            state.createFile(named: input, in: parent)
        case .rename(let target):
            state.renameItem(at: target, to: input)
        case .duplicate(let target):
            state.duplicateFile(at: target, newName: input)
        }
    }

    private func syncExpandedDirectories(with tree: [FileNode]) {
        let allDirectories = collectDirectoryURLs(in: tree)
        let newDirectories = allDirectories.subtracting(knownDirectoryURLs)

        expandedDirectories.formIntersection(allDirectories)
        if knownDirectoryURLs.isEmpty {
            expandedDirectories.formUnion(allDirectories)
        } else {
            expandedDirectories.formUnion(newDirectories)
        }

        knownDirectoryURLs = allDirectories
    }

    private func collectDirectoryURLs(in nodes: [FileNode]) -> Set<URL> {
        nodes.reduce(into: Set<URL>()) { partialResult, node in
            if node.isDirectory {
                partialResult.insert(node.url)
                if let children = node.children {
                    partialResult.formUnion(collectDirectoryURLs(in: children))
                }
            }
        }
    }
}

private struct SidebarTreeNodeView: View {
    @ObservedObject var state: AppState
    let node: FileNode
    let depth: Int
    @Binding var expandedDirectories: Set<URL>
    @Binding var dropTargetURL: URL?
    let openPrompt: (PromptContext) -> Void
    @Binding var deleteTarget: URL?

    var body: some View {
        VStack(spacing: 0) {
            row

            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    SidebarTreeNodeView(
                        state: state,
                        node: child,
                        depth: depth + 1,
                        expandedDirectories: $expandedDirectories,
                        dropTargetURL: $dropTargetURL,
                        openPrompt: openPrompt,
                        deleteTarget: $deleteTarget
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        let content = HStack(spacing: 0) {
            Color.clear
                .frame(width: CGFloat(depth) * 14)

            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 26)
            } else {
                Color.clear
                    .frame(width: 18, height: 26)
            }

            SidebarRowLabel(node: node)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .onTapGesture {
                handleRowTap()
            }
            .onDrag { NSItemProvider(object: node.url as NSURL) }
            .contextMenu {
                contextMenuContent
            }

        if node.isDirectory {
            content.onDrop(
                of: [UTType.fileURL],
                delegate: SidebarDropDelegate(
                    state: state,
                    destinationURL: node.url,
                    dropTargetURL: $dropTargetURL
                )
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if node.isDirectory {
            Button("新增文件夹") { openPrompt(.newFolder(parent: node.url)) }
            Button("新增文件") { openPrompt(.newFile(parent: node.url)) }
            Button("修改文件夹名") { openPrompt(.rename(target: node.url)) }
            Divider()
            Button("刷新") { state.refresh() }
            Button("移除书签") { state.removeRootFolder(node.url) }
            Button("在 Finder 中显示") { state.revealInFinder(node.url) }
        } else {
            Button("修改文件名") { openPrompt(.rename(target: node.url)) }
            Button("创建副本") { openPrompt(.duplicate(target: node.url)) }
            Divider()
            Button("刷新") { state.refresh() }
            Button("删除", role: .destructive) { deleteTarget = node.url }
            Button("在 Finder 中显示") { state.revealInFinder(node.url) }
        }
    }

    private var isExpanded: Bool {
        node.isDirectory && expandedDirectories.contains(node.url)
    }

    private var backgroundColor: Color {
        if dropTargetURL == node.url {
            return Color.accentColor.opacity(0.18)
        }

        if state.selection == node.url {
            return Color.accentColor.opacity(0.12)
        }

        return .clear
    }

    private func toggleExpanded() {
        guard node.isDirectory else { return }
        if isExpanded {
            expandedDirectories.remove(node.url)
        } else {
            expandedDirectories.insert(node.url)
        }
    }

    private func handleRowTap() {
        state.selectNode(node)
        if node.isDirectory {
            toggleExpanded()
        }
    }
}

private struct SidebarRowLabel: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 0) {
            Label(node.displayName, systemImage: node.isDirectory ? "folder" : "doc.text")
            Spacer(minLength: 0)
        }
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarDropDelegate: DropDelegate {
    @ObservedObject var state: AppState
    let destinationURL: URL
    @Binding var dropTargetURL: URL?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        dropTargetURL = destinationURL
    }

    func dropExited(info: DropInfo) {
        if dropTargetURL == destinationURL {
            dropTargetURL = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetURL = nil
        return state.moveDroppedItems(from: info.itemProviders(for: [UTType.fileURL]), to: destinationURL)
    }
}

private enum PromptContext: Identifiable {
    case newFolder(parent: URL)
    case newFile(parent: URL)
    case rename(target: URL)
    case duplicate(target: URL)

    var id: String {
        switch self {
        case .newFolder(let parent): return "newFolder-\(parent.path)"
        case .newFile(let parent): return "newFile-\(parent.path)"
        case .rename(let target): return "rename-\(target.path)"
        case .duplicate(let target): return "duplicate-\(target.path)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: return "新增文件夹"
        case .newFile: return "新增文件"
        case .rename: return "修改名称"
        case .duplicate: return "创建副本"
        }
    }

    var message: String {
        switch self {
        case .newFolder: return "请输入新的文件夹名称"
        case .newFile: return "请输入新的文件名称"
        case .rename: return "请输入新的名称"
        case .duplicate: return "请输入副本名称"
        }
    }

    var confirmLabel: String {
        switch self {
        case .newFolder, .newFile: return "创建"
        case .rename: return "保存"
        case .duplicate: return "创建"
        }
    }

    var initialValue: String {
        switch self {
        case .newFolder: return "新建文件夹"
        case .newFile: return "未命名.md"
        case .rename(let target): return target.lastPathComponent
        case .duplicate(let target): return target.deletingPathExtension().lastPathComponent + " 副本" + (target.pathExtension.isEmpty ? "" : ".\(target.pathExtension)")
        }
    }
}
