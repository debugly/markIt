import AppKit
import Foundation
import UniformTypeIdentifiers
import Combine

final class AppState: ObservableObject {
    @Published var rootFolders: [URL] = [] {
        didSet { rebuildTree() }
    }
    @Published var tree: [FileNode] = []
    @Published var selection: URL? = nil

    @Published var showSidebar = true {
        didSet { startTransitionLock() }
    }
    @Published var showUnsavedAlert = false
    @Published var isTransitioning = false
    @Published var isRestoringLastOpenedFile = false

    enum EditMode {
        case wysiwyg
        case source
    }
    /// Transient "已保存" style feedback, cleared by showTransientStatus.
    @Published var statusMessage: String?

    private var statusClearTask: Task<Void, Never>?

    @Published var editMode: EditMode = .wysiwyg

    func toggleEditMode() {
        editMode = (editMode == .wysiwyg) ? .source : .wysiwyg
    }

    private var transitionWorkItem: DispatchWorkItem?

    func startTransitionLock() {
        isTransitioning = true
        transitionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isTransitioning = false
        }
        transitionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
    @Published var previewStyle: String = "GitHub.css" {
        didSet { document.previewStyle = previewStyle }
    }

    private var defaults: UserDefaults { AppDefaults.store() }

    private let inspectKey = "MarkIt.IsWebViewInspectEnabled"
    @Published var isWebViewInspectEnabled: Bool = false {
        didSet {
            defaults.set(isWebViewInspectEnabled, forKey: inspectKey)
        }
    }

    let document = DocumentModel()
    private let stylesKey = "MarkIt.PreviewStyle"
    private let fileManager = FileManager.default
    private let bookmarksKey = "MarkIt.Bookmarks"
    private let recentFilesKey = "MarkIt.RecentFiles"
    @Published var recentFiles: [URL] = []
    private var activeSecurityScopedRoots: Set<URL> = []
    private var lastSelectedFileURL: URL? = nil
    private var isAdjustingSelection = false
    private var pendingSwitchURL: URL? = nil

    private var cancellables = Set<AnyCancellable>()
    var hasOpenedFileOnLaunch = false
    private let lastOpenedFileBookmarkKey = "MarkIt.LastOpenedFileBookmark"
    private let lastOpenedFileURLKey = "MarkIt.LastOpenedFileURL"

    init() {
        if Self.isUITesting {
            clearPersistedStateForUITest()
        } else {
            restoreBookmarks()
            restoreRecentFiles()
        }
        restorePreviewStyle()
        restoreWebViewInspectEnabled()
        rebuildTree()
        setupDocumentObserver()
        NotificationCenter.default.addObserver(forName: Notification.Name("WebDAVSyncDidComplete"), object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    /// XCUITest 以 `--uitest-reset` 启动时，忽略此前持久化的书签/最近文件/上次打开文件，
    /// 保证每次测试都从确定性的空状态开始。
    private static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-reset")
    }

    private func clearPersistedStateForUITest() {
        // --uitest-reset means "start from a clean state", and on the user's
        // own defaults that instruction reads exactly like "delete their
        // folders and recent files". Isolation via AppDefaults is what actually
        // makes it safe; this guard exists so that a misconfigured runner
        // fails loudly instead of quietly emptying the real store.
        precondition(
            AppDefaults.isIsolated,
            "--uitest-reset must be paired with --uitest-suite <name>; refusing to clear production defaults"
        )
        defaults.removeObject(forKey: bookmarksKey)
        defaults.removeObject(forKey: recentFilesKey)
        defaults.removeObject(forKey: lastOpenedFileBookmarkKey)
        defaults.removeObject(forKey: lastOpenedFileURLKey)
        rootFolders = []
        recentFiles = []
    }

    private func restoreRecentFiles() {
        if let data = defaults.data(forKey: recentFilesKey),
           let urls = try? JSONDecoder().decode([URL].self, from: data) {
            recentFiles = urls.filter { canOpenFile($0) }
        }
    }

    private func saveRecentFiles() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            defaults.set(data, forKey: recentFilesKey)
        }
    }

    func clearRecentFiles() {
        recentFiles = []
        saveRecentFiles()
    }

    func removeRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        saveRecentFiles()
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "打开文件"
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    private func restorePreviewStyle() {
        previewStyle = defaults.string(forKey: stylesKey) ?? "GitHub.css"
    }

    private func restoreWebViewInspectEnabled() {
        if defaults.object(forKey: inspectKey) == nil {
            isWebViewInspectEnabled = true
            defaults.set(true, forKey: inspectKey)
        } else {
            isWebViewInspectEnabled = defaults.bool(forKey: inspectKey)
        }
    }

    func setPreviewStyle(_ style: String) {
        previewStyle = style
        defaults.set(style, forKey: stylesKey)
    }

    func addRootFolder(_ url: URL, storeBookmark: Bool = false) {
        guard rootFolders.contains(url) == false else { return }
        beginAccessingRootFolder(url)
        rootFolders.append(url)
        if storeBookmark {
            persistBookmark(for: url)
        }
        rebuildTree()
    }

    func removeRootFolder(_ url: URL) {
        endAccessingRootFolder(url)
        if let cfg = SyncCoordinator.shared.rootConfig(for: url) {
            SyncCoordinator.shared.removeConfig(id: cfg.id)
        }
        rootFolders.removeAll { $0 == url }
        rebuildTree()
        saveBookmarks()
    }

    func rebuildTree() {
        tree = rootFolders.map { FileNodeBuilder.buildTree(for: $0) }
        if let sel = selection, !fileExists(at: sel) {
            selection = nil
            if let docURL = document.url, docURL == sel {
                document.clear()
            }
        }
    }

    func refresh() {
        rebuildTree()
    }

    func openFile(_ url: URL) {
        guard canOpenFile(url) else { return }
        let fileType = SupportedFileType.detect(url: url)
        if fileType == .text {
            editMode = .source
        } else if fileType == .html {
            editMode = .wysiwyg
        }
        addToRecentFiles(url)
        selection = url
        _ = requestSwitch(to: url)
    }

    func openDroppedFiles(from providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard matchingProviders.isEmpty == false else { return false }

        for provider in matchingProviders {
            provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { [weak self] data, _ in
                guard let self = self, let data = data else { return }
                guard let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    self.openFile(url)
                }
            }
        }

        return true
    }

    func createNewFile() {
        if let firstFolder = rootFolders.first {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileName = "新建文件 \(timestamp).md"
            let url = firstFolder.appendingPathComponent(fileName)
            if fileManager.createFile(atPath: url.path, contents: Data()) {
                document.open(url: url)
                refresh()
            }
        } else {
            promptOpenFolder()
        }
    }

    func exportHTML() {
        guard let url = document.url else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "导出 HTML"
        savePanel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".html"
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            try? document.html.write(to: targetURL, atomically: true, encoding: .utf8)
        }
    }

    private func addToRecentFiles(_ url: URL) {
        guard recentFiles.contains(url) == false else { return }

        recentFiles.insert(url, at: 0)
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        saveRecentFiles()
    }

    func canOpenFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return true
    }

    private func canOpenMarkdownFile(_ url: URL) -> Bool {
        guard canOpenFile(url) else { return false }
        let fileExtension = url.pathExtension.lowercased()
        return fileExtension == "md" || fileExtension == "markdown"
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

    func selectNode(_ node: FileNode) {
        guard isAdjustingSelection == false else { return }

        selection = node.url
        guard node.isDirectory == false else { return }

        if requestSwitch(to: node.url) {
            lastSelectedFileURL = node.url
        }
    }

    func closeWindowIfNeeded() {
        if !showSidebar && document.url == nil {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func createFolder(named name: String, in parent: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = uniqueURL(for: parent.appendingPathComponent(trimmed, isDirectory: true))
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            SyncCoordinator.shared.markModified(fileOrFolderURL: target)
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
            SyncCoordinator.shared.markModified(fileOrFolderURL: target)
            document.open(url: target)
            refresh()
        }
    }

    func renameItem(at url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: url.hasDirectoryPath)
        guard target != url else { return }
        if relocateItem(at: url, to: target) {
            SyncCoordinator.shared.recordDeletion(fileOrFolderURL: url)
            SyncCoordinator.shared.markModified(fileOrFolderURL: target)
        }
    }

    func duplicateFile(at url: URL, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let target = uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: false))
        do {
            try fileManager.copyItem(at: url, to: target)
            SyncCoordinator.shared.markModified(fileOrFolderURL: target)
            refresh()
            selection = target
            if requestSwitch(to: target) {
                lastSelectedFileURL = target
            }
        } catch {
            return
        }
    }

    @discardableResult
    func deleteItem(at url: URL) -> Bool {
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            SyncCoordinator.shared.recordDeletion(fileOrFolderURL: url)

            let stdURL = url.standardizedFileURL
            let isAffected: (URL) -> Bool = { target in
                let targetStd = target.standardizedFileURL
                return targetStd == stdURL || targetStd.path.hasPrefix(stdURL.path + "/")
            }

            if let docURL = document.url, isAffected(docURL) {
                document.clear()
            }
            if let sel = selection, isAffected(sel) {
                selection = nil
            }
            if let last = lastSelectedFileURL, isAffected(last) {
                lastSelectedFileURL = nil
            }

            recentFiles.removeAll { isAffected($0) }
            saveRecentFiles()

            refresh()
            return true
        } catch {
            print("[AppState] 移动到废纸篓失败: \(error)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "无法将项目移到废纸篓"
                alert.informativeText = "\(url.lastPathComponent)：\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
            return false
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveDroppedItems(from providers: [NSItemProvider], to destinationDirectory: URL) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard matchingProviders.isEmpty == false else { return false }

        for provider in matchingProviders {
            provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { [weak self] data, _ in
                guard let self = self, let data = data else { return }
                guard let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                DispatchQueue.main.async {
                    self.moveItem(at: url, toDirectory: destinationDirectory)
                }
            }
        }

        return true
    }

    @discardableResult
    func moveItem(at sourceURL: URL, toDirectory destinationDirectory: URL) -> Bool {
        guard fileExists(at: sourceURL) else { return false }
        guard isDirectory(at: destinationDirectory) else { return false }
        guard sourceURL != destinationDirectory else { return false }

        if sourceURL.hasDirectoryPath, isSameOrDescendant(destinationDirectory, of: sourceURL) {
            return false
        }

        let targetURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: sourceURL.hasDirectoryPath)
        let success = relocateItem(at: sourceURL, to: targetURL)
        if success {
            SyncCoordinator.shared.recordDeletion(fileOrFolderURL: sourceURL)
            SyncCoordinator.shared.markModified(fileOrFolderURL: targetURL)
        }
        return success
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
                    guard let self = self else { return }
                    if let url = url, self.document.saveNow(to: url) {
                        self.document.updateURL(url)
                        if let targetURL = targetURL {
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
            if let targetURL = targetURL {
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
            let data: Data
            if let secData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                data = secData
            } else {
                data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            var existing = defaults.array(forKey: bookmarksKey) as? [Data] ?? []
            if existing.contains(data) == false {
                existing.append(data)
                defaults.set(existing, forKey: bookmarksKey)
            }
        } catch {
            return
        }
    }

    private func saveBookmarks() {
        let bookmarks = rootFolders.compactMap { url -> Data? in
            if let secData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                return secData
            }
            return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmarks, forKey: bookmarksKey)
    }

    private func restoreBookmarks() {
        let stored = defaults.array(forKey: bookmarksKey) as? [Data] ?? []
        var resolved: [URL] = []
        for data in stored {
            var isStale = false
            var resolvedURL: URL? = nil
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedURL = url
            } else if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedURL = url
            }
            if let url = resolvedURL {
                beginAccessingRootFolder(url)
                resolved.append(url)
            }
        }
        rootFolders = resolved
    }

    private func revertSelection() {
        isAdjustingSelection = true
        selection = lastSelectedFileURL
        isAdjustingSelection = false
    }

    private func updateLastSelectionIfPossible() {
        if let url = selection, let node = findNode(matching: url, in: tree), node.isDirectory == false {
            lastSelectedFileURL = url
        }
    }

    /// Saves the open document, for Cmd+S.
    ///
    /// Separate from the switch path's saveIfDirty because a deliberate save
    /// has to be honest about failure. saveIfDirty returning false during a
    /// switch is covered by the unsaved-changes prompt, but Cmd+S is the user
    /// saying "put this on disk now", and a write that fails there has to be
    /// reported rather than silently doing nothing.
    ///
    /// A document with no URL is a new file and still needs the save panel.
    func saveCurrentDocument() {
        guard let url = document.url else {
            // A brand new document has nowhere to go yet, so this needs the
            // panel before anything can be written.
            beginSavePanel(defaultName: "未命名.md") { [weak self] target in
                guard let self = self, let target = target else { return }
                if self.document.saveNow(to: target) {
                    self.document.updateURL(target)
                    SyncCoordinator.shared.flushPendingSync(for: target)
                    self.showTransientStatus("已保存")
                }
            }
            return
        }

        guard document.isDirty else {
            // Already on disk. Doing nothing is right, but saying so beats
            // leaving the keypress looking like it was swallowed.
            showTransientStatus("已是最新，无需保存")
            return
        }

        guard document.saveNow(to: url) else {
            let alert = NSAlert()
            alert.messageText = "无法保存"
            alert.informativeText = "\(url.lastPathComponent) 写入失败，可能没有写入权限。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        // Only after a real write. An unsynced cloud badge means "there are
        // local changes waiting to go up", and this is where they go up --
        // rather than leaving the user watching an orange cloud for 30
        // seconds after asking the app to save.
        SyncCoordinator.shared.flushPendingSync(for: url)

        showTransientStatus("已保存")
    }

    /// A short confirmation, cleared on its own.
    ///
    /// Autosave means a manual save is usually a no-op, and without any
    /// response the keypress reads as broken rather than as "already done".
    private func showTransientStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self = self, self.statusMessage == message else { return }
            self.statusMessage = nil
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

    private func beginAccessingRootFolder(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard activeSecurityScopedRoots.contains(normalizedURL) == false else { return }
        if normalizedURL.startAccessingSecurityScopedResource() {
            activeSecurityScopedRoots.insert(normalizedURL)
        }
    }

    private func endAccessingRootFolder(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard activeSecurityScopedRoots.contains(normalizedURL) else { return }
        normalizedURL.stopAccessingSecurityScopedResource()
        activeSecurityScopedRoots.remove(normalizedURL)
    }

    private func updateSecurityScopedRootAccess(from oldRoots: [URL], to newRoots: [URL]) {
        let oldSet = Set(oldRoots.map(\.standardizedFileURL))
        let newSet = Set(newRoots.map(\.standardizedFileURL))

        for url in oldSet.subtracting(newSet) {
            endAccessingRootFolder(url)
        }

        for url in newSet.subtracting(oldSet) {
            beginAccessingRootFolder(url)
        }
    }

    @discardableResult
    private func relocateItem(at sourceURL: URL, to targetURL: URL) -> Bool {
        guard fileExists(at: sourceURL) else { return false }
        guard targetURL != sourceURL else { return false }
        guard fileExists(at: targetURL) == false else { return false }

        if let documentURL = document.url, isSameOrDescendant(documentURL, of: sourceURL) {
            _ = document.saveIfDirty()
        }

        let selectionURL = updatedURLAfterMove(for: selection, from: sourceURL, to: targetURL)
        let lastSelectedURL = updatedURLAfterMove(for: lastSelectedFileURL, from: sourceURL, to: targetURL)
        let documentURL = updatedURLAfterMove(for: document.url, from: sourceURL, to: targetURL)
        let updatedRecentFiles = recentFiles.map { updatedURLAfterMove(for: $0, from: sourceURL, to: targetURL) ?? $0 }
        let updatedRootFolders = rootFolders.map { updatedURLAfterMove(for: $0, from: sourceURL, to: targetURL) ?? $0 }

        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        } catch {
            return false
        }

        recentFiles = updatedRecentFiles.filter { fileExists(at: $0) }
        saveRecentFiles()

        // 在重建目录树之前，先把 document.url / selection / lastSelectedFileURL
        // 更新到移动后的新路径。否则 rebuildTree() 会发现旧的 selection 已不存在，
        // 且 document.url == 旧 selection，进而调用 document.clear() 清空编辑器，
        // 导致拖拽/重命名后预览变成白板。
        if let documentURL = documentURL {
            document.updateURL(documentURL)
        }

        syncSelection(selectionURL: selectionURL ?? selection, lastSelectedURL: lastSelectedURL ?? lastSelectedFileURL)

        let rootsChanged = updatedRootFolders != rootFolders
        if rootsChanged {
            updateSecurityScopedRootAccess(from: rootFolders, to: updatedRootFolders)
            rootFolders = updatedRootFolders
            saveBookmarks()
        } else {
            rebuildTree()
        }
        return true
    }

    private func syncSelection(selectionURL: URL?, lastSelectedURL: URL?) {
        isAdjustingSelection = true
        selection = selectionURL
        isAdjustingSelection = false
        lastSelectedFileURL = lastSelectedURL
    }

    private func updatedURLAfterMove(for url: URL?, from sourceRoot: URL, to targetRoot: URL) -> URL? {
        guard let url = url else { return nil }
        guard let relativePath = relativePath(of: url, from: sourceRoot) else { return nil }
        guard relativePath.isEmpty == false else { return targetRoot }
        return relativePath.reduce(targetRoot) { partialResult, component in
            partialResult.appendingPathComponent(component)
        }
    }

    private func relativePath(of url: URL, from baseURL: URL) -> [String]? {
        let normalizedURL = url.standardizedFileURL
        let normalizedBase = baseURL.standardizedFileURL
        let urlComponents = normalizedURL.pathComponents
        let baseComponents = normalizedBase.pathComponents

        guard urlComponents.count >= baseComponents.count else { return nil }
        guard Array(urlComponents.prefix(baseComponents.count)) == baseComponents else { return nil }
        return Array(urlComponents.dropFirst(baseComponents.count))
    }

    private func isSameOrDescendant(_ url: URL, of baseURL: URL) -> Bool {
        relativePath(of: url, from: baseURL) != nil
    }

    private func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func findNode(matching url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url {
                return node
            }

            if let children = node.children, let match = findNode(matching: url, in: children) {
                return match
            }
        }

        return nil
    }

    private func setupDocumentObserver() {
        document.$url
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self = self else { return }
                print("[MarkIt Log] setupDocumentObserver: document.url changed to \(url?.path ?? "nil")")
                if let url = url {
                    self.saveLastOpenedFile(url)
                } else {
                    self.clearLastOpenedFile()
                }
            }
            .store(in: &cancellables)
    }

    private func saveLastOpenedFile(_ url: URL) {
        if selection != url {
            selection = url
        }
        
        print("[MarkIt Log] saveLastOpenedFile called for URL: \(url.path)")
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmarkData, forKey: lastOpenedFileBookmarkKey)
            print("[MarkIt Log] saveLastOpenedFile: Saved security-scoped bookmark data successfully.")
        } catch {
            print("[MarkIt Log] saveLastOpenedFile: Failed to create security-scoped bookmark. Error: \(error). Trying raw URL...")
            if let urlData = try? JSONEncoder().encode(url) {
                defaults.set(urlData, forKey: lastOpenedFileURLKey)
                print("[MarkIt Log] saveLastOpenedFile: Saved raw URL data successfully.")
            } else {
                print("[MarkIt Log] saveLastOpenedFile: Failed to encode raw URL.")
            }
        }
    }

    private func clearLastOpenedFile() {
        print("[MarkIt Log] clearLastOpenedFile called.")
        defaults.removeObject(forKey: lastOpenedFileBookmarkKey)
        defaults.removeObject(forKey: lastOpenedFileURLKey)
    }

    func restoreLastOpenedFile() {
        print("[MarkIt Log] restoreLastOpenedFile called. hasOpenedFileOnLaunch: \(hasOpenedFileOnLaunch), document.url: \(document.url?.path ?? "nil")")
        guard !hasOpenedFileOnLaunch else { 
            print("[MarkIt Log] restoreLastOpenedFile: Skipped because a file is already being opened on launch.")
            return 
        }
        guard document.url == nil else { 
            print("[MarkIt Log] restoreLastOpenedFile: Skipped because document.url is already non-nil.")
            return 
        }

        isRestoringLastOpenedFile = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.isRestoringLastOpenedFile = false
            }
        }

        if let bookmarkData = defaults.data(forKey: lastOpenedFileBookmarkKey) {
            print("[MarkIt Log] restoreLastOpenedFile: Found bookmarkData.")
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                print("[MarkIt Log] restoreLastOpenedFile: Resolved security-scoped URL: \(url.path), isStale: \(isStale)")
                _ = url.startAccessingSecurityScopedResource()
                if canOpenFile(url) {
                    print("[MarkIt Log] restoreLastOpenedFile: Opening resolved security-scoped URL.")
                    openFile(url)
                    return
                } else {
                    print("[MarkIt Log] restoreLastOpenedFile: resolved security-scoped URL exists but cannot open it (file missing or incorrect extension).")
                }
            } else {
                print("[MarkIt Log] restoreLastOpenedFile: Failed to resolve security-scoped bookmark.")
            }
            
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                print("[MarkIt Log] restoreLastOpenedFile: Resolved standard URL: \(url.path)")
                if canOpenFile(url) {
                    print("[MarkIt Log] restoreLastOpenedFile: Opening resolved standard URL.")
                    openFile(url)
                    return
                }
            } else {
                print("[MarkIt Log] restoreLastOpenedFile: Failed to resolve standard bookmark.")
            }
        } else {
            print("[MarkIt Log] restoreLastOpenedFile: No bookmarkData found in UserDefaults.")
        }

        if let urlData = defaults.data(forKey: lastOpenedFileURLKey),
           let url = try? JSONDecoder().decode(URL.self, from: urlData) {
            print("[MarkIt Log] restoreLastOpenedFile: Found raw URL: \(url.path)")
            if canOpenFile(url) {
                print("[MarkIt Log] restoreLastOpenedFile: Opening raw URL.")
                openFile(url)
            } else {
                print("[MarkIt Log] restoreLastOpenedFile: Raw URL exists but cannot open it.")
            }
        } else {
            print("[MarkIt Log] restoreLastOpenedFile: No raw URL data found in UserDefaults.")
        }
    }
}
