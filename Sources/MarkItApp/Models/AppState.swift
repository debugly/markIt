import AppKit
import Foundation
import UniformTypeIdentifiers

final class AppState: ObservableObject {
    @Published var rootFolders: [URL] = [] {
        didSet { rebuildTree() }
    }
    @Published var tree: [FileNode] = []
    @Published var selection: URL? = nil

    @Published var showSidebar = true
    @Published var showEditor = true
    @Published var showPreview = true
    @Published var showUnsavedAlert = false
    @Published var previewStyle: String = "GitHub.css" {
        didSet { document.previewStyle = previewStyle }
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
        beginAccessingRootFolder(url)
        rootFolders.append(url)
        if storeBookmark {
            persistBookmark(for: url)
        }
    }

    func removeRootFolder(_ url: URL) {
        endAccessingRootFolder(url)
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

    func selectNode(_ node: FileNode) {
        guard isAdjustingSelection == false else { return }

        selection = node.url
        guard node.isDirectory == false else { return }

        if requestSwitch(to: node.url) {
            lastSelectedFileURL = node.url
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
        _ = relocateItem(at: url, to: target)
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

    func moveDroppedItems(from providers: [NSItemProvider], to destinationDirectory: URL) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let matchingProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard matchingProviders.isEmpty == false else { return false }

        for provider in matchingProviders {
            provider.loadDataRepresentation(forTypeIdentifier: fileURLType) { [weak self] data, _ in
                guard let self, let data else { return }
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
        return relocateItem(at: sourceURL, to: targetURL)
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

    private func saveBookmarks() {
        let bookmarks = rootFolders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
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

        let rootsChanged = updatedRootFolders != rootFolders
        if rootsChanged {
            updateSecurityScopedRootAccess(from: rootFolders, to: updatedRootFolders)
            rootFolders = updatedRootFolders
            saveBookmarks()
        } else {
            rebuildTree()
        }

        if let documentURL {
            document.updateURL(documentURL)
        }

        syncSelection(selectionURL: selectionURL ?? selection, lastSelectedURL: lastSelectedURL ?? lastSelectedFileURL)
        return true
    }

    private func syncSelection(selectionURL: URL?, lastSelectedURL: URL?) {
        isAdjustingSelection = true
        selection = selectionURL
        isAdjustingSelection = false
        lastSelectedFileURL = lastSelectedURL
    }

    private func updatedURLAfterMove(for url: URL?, from sourceRoot: URL, to targetRoot: URL) -> URL? {
        guard let url else { return nil }
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
}
