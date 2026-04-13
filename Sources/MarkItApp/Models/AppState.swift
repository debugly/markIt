import AppKit
import Foundation

final class AppState: ObservableObject {
    @Published var rootFolders: [URL] = [] {
        didSet { rebuildTree() }
    }
    @Published var tree: [FileNode] = []
    @Published var selection: FileNode? = nil

    @Published var showSidebar = true
    @Published var showEditor = true
    @Published var showPreview = true
    @Published var showUnsavedAlert = false
    @Published var previewStyle: String = "GitHub.css"

    let document = DocumentModel()
    private let stylesKey = "MarkIt.PreviewStyle"
    private let fileManager = FileManager.default
    private let bookmarksKey = "MarkIt.Bookmarks"
    private let recentFilesKey = "MarkIt.RecentFiles"
    @Published var recentFiles: [URL] = []
    private var lastSelectedFile: FileNode? = nil
    private var isAdjustingSelection = false
    private var pendingSwitchURL: URL? = nil

    init() {
        restoreBookmarks()
        restorePreviewStyle()
        restoreRecentFiles()
        rebuildTree()
    }

    private func restoreRecentFiles() {
        if let data = UserDefaults.standard.data(forKey: recentFilesKey),
           let urls = try? JSONDecoder().decode([URL].self, from: data) {
            recentFiles = urls.filter { fileManager.fileExists(atPath: $0.path) }
        }
    }

    private func saveRecentFiles() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            UserDefaults.standard.set(data, forKey: recentFilesKey)
        }
    }

    func clearRecentFiles() {
        recentFiles = []
        saveRecentFiles()
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        panel.title = "打开文件"
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    private func restorePreviewStyle() {
        previewStyle = UserDefaults.standard.string(forKey: stylesKey) ?? "GitHub.css"
    }

    func setPreviewStyle(_ style: String) {
        previewStyle = style
        UserDefaults.standard.set(style, forKey: stylesKey)
    }

    func addRootFolder(_ url: URL, storeBookmark: Bool = false) {
        guard rootFolders.contains(url) == false else { return }
        rootFolders.append(url)
        if storeBookmark {
            persistBookmark(for: url)
        }
    }

    func removeRootFolder(_ url: URL) {
        rootFolders.removeAll { $0 == url }
        rebuildTree()
        removeBookmark(for: url)
    }

    private func removeBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var existing = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        existing.removeAll { $0 == data }
        UserDefaults.standard.set(existing, forKey: bookmarksKey)
    }

    func rebuildTree() {
        tree = rootFolders.map { FileNodeBuilder.buildTree(for: $0) }
    }

    func refresh() {
        rebuildTree()
    }

    func openFile(_ url: URL) {
        addToRecentFiles(url)
        _ = requestSwitch(to: url)
    }

    private func addToRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        saveRecentFiles()
    }

    func promptOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "打开文件夹"
        if panel.runModal() == .OK {
            panel.urls.forEach { addRootFolder($0, storeBookmark: true) }
        }
    }

    func handleSelection(_ node: FileNode?) {
        guard isAdjustingSelection == false else { return }
        guard let node else { return }
        guard node.isDirectory == false else { return }
        if requestSwitch(to: node.url) {
            lastSelectedFile = node
        }
    }

    func closeWindowIfNeeded() {
        if !showSidebar && !showEditor && !showPreview {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func createFolder(named name: String, in parent: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = uniqueURL(for: parent.appendingPathComponent(trimmed, isDirectory: true))
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            refresh()
        } catch {
            return
        }
    }

    func createFile(named name: String, in parent: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = uniqueURL(for: parent.appendingPathComponent(trimmed, isDirectory: false))
        let created = fileManager.createFile(atPath: target.path, contents: Data())
        if created {
            document.open(url: target)
            refresh()
        }
    }

    func renameItem(at url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: url.hasDirectoryPath)
        guard target != url else { return }
        do {
            try fileManager.moveItem(at: url, to: target)
            if document.url == url {
                document.updateURL(target)
            }
            refresh()
        } catch {
            return
        }
    }

    func duplicateFile(at url: URL, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: false))
        do {
            try fileManager.copyItem(at: url, to: target)
            refresh()
        } catch {
            return
        }
    }

    func deleteItem(at url: URL) {
        do {
            try fileManager.removeItem(at: url)
            if document.url == url {
                document.clear()
            }
            refresh()
        } catch {
            return
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func requestSwitch(to url: URL) -> Bool {
        if document.url != nil {
            _ = document.saveIfDirty()
            document.open(url: url)
            return true
        }

        if document.isDirty {
            pendingSwitchURL = url
            DispatchQueue.main.async { [weak self] in
                self?.showUnsavedAlert = true
            }
            return false
        }

        document.open(url: url)
        return true
    }

    func resolveUnsavedDecision(_ decision: UnsavedDecision) {
        let targetURL = pendingSwitchURL
        pendingSwitchURL = nil
        showUnsavedAlert = false

        switch decision {
        case .save:
            DispatchQueue.main.async { [weak self] in
                self?.beginSavePanel(defaultName: "未命名.md") { [weak self] url in
                    guard let self else { return }
                    if let url, self.document.saveNow(to: url) {
                        self.document.updateURL(url)
                        if let targetURL {
                            self.document.open(url: targetURL)
                            self.updateLastSelectionIfPossible()
                        }
                    } else {
                        self.revertSelection()
                    }
                }
            }
        case .discard:
            document.clear()
            if let targetURL {
                document.open(url: targetURL)
                updateLastSelectionIfPossible()
            }
        case .cancel:
            revertSelection()
        }
    }

    private func uniqueURL(for url: URL) -> URL {
        if fileManager.fileExists(atPath: url.path) == false {
            return url
        }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let suffix = " \(index)"
            let name = ext.isEmpty ? base + suffix : base + suffix + "." + ext
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if fileManager.fileExists(atPath: candidate.path) == false {
                return candidate
            }
            index += 1
        }
    }

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var existing = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
            if existing.contains(data) == false {
                existing.append(data)
                UserDefaults.standard.set(existing, forKey: bookmarksKey)
            }
        } catch {
            return
        }
    }

    private func restoreBookmarks() {
        let stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        var resolved: [URL] = []
        for data in stored {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                resolved.append(url)
            }
        }
        rootFolders = resolved
    }

    private func revertSelection() {
        isAdjustingSelection = true
        selection = lastSelectedFile
        isAdjustingSelection = false
    }

    private func updateLastSelectionIfPossible() {
        if let node = selection, node.isDirectory == false {
            lastSelectedFile = node
        }
    }

    private func beginSavePanel(defaultName: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "保存文件"
        panel.nameFieldStringValue = defaultName
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            let response = panel.runModal()
            completion(response == .OK ? panel.url : nil)
        }
    }
}

final class DocumentModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published var text: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isDirty = false

    private var saveTask: Task<Void, Never>?
    private var isSettingInitialText = false

    func open(url: URL) {
        if self.url == url { return }

        self.url = url
        isLoading = true
        isSettingInitialText = true

        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            text = ""
        }

        isSettingInitialText = false
        isLoading = false
        isDirty = false
    }

    func updateText(_ newValue: String) {
        text = newValue
        isDirty = true
        scheduleSave()
    }

    func saveIfDirty() -> Bool {
        guard let url else { return false }
        if isDirty {
            return saveNow(to: url)
        }
        return true
    }

    func updateURL(_ newURL: URL) {
        url = newURL
    }

    func clear() {
        url = nil
        text = ""
        isDirty = false
    }

    func confirmCloseIfNeeded() -> Bool {
        if let currentURL = url {
            if isDirty {
                _ = saveNow(to: currentURL)
            }
            return true
        }

        if isDirty {
            switch promptForUnsavedChanges() {
            case .save:
                return saveViaPanel() != nil
            case .discard:
                return true
            case .cancel:
                return false
            }
        }

        return true
    }

    @discardableResult
    func saveNow(to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    private func saveViaPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存文件"
        panel.nameFieldStringValue = "未命名.md"
        let response = panel.runModal()
        guard response == .OK, let target = panel.url else { return nil }
        if saveNow(to: target) {
            url = target
            return target
        }
        return nil
    }

    private func promptForUnsavedChanges() -> SaveDecision {
        let alert = NSAlert()
        alert.messageText = "是否保存未命名的文件？"
        alert.informativeText = "你的更改尚未保存。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func scheduleSave() {
        guard isSettingInitialText == false else { return }
        guard let url else { return }

        saveTask?.cancel()
        saveTask = Task { [text] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private enum SaveDecision {
    case save
    case discard
    case cancel
}

enum UnsavedDecision {
    case save
    case discard
    case cancel
}
