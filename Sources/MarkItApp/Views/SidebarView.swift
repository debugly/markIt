import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var state: AppState
    @State private var prompt: PromptContext? = nil
    @State private var deleteTarget: URL? = nil
    @State private var isPickingFolder = false
    @State private var showingStylePicker = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                OutlineGroup(state.tree, children: \.children) { node in
                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                        .tag(node)
                        .contextMenu {
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
                }
            }
            .listStyle(.sidebar)
            .animation(nil, value: state.tree)
            .contextMenu {
                Button("打开文件夹") { state.promptOpenFolder() }
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    isPickingFolder = true
                } label: {
                    Label("打开文件夹", systemImage: "folder.badge.plus")
                }

                Spacer()

                Button {
                    state.showSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("显示/隐藏目录")

                Button {
                    state.showEditor.toggle()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("显示/隐藏编辑器")

                Button {
                    state.showPreview.toggle()
                } label: {
                    Image(systemName: "doc.richtext")
                }
                .help("显示/隐藏预览")

                Divider()
                    .frame(height: 16)

                Button {
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置")

                Button {
                    showingStylePicker = true
                } label: {
                    Image(systemName: "paintpalette")
                }
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
