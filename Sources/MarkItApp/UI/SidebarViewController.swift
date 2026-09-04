//
//  SidebarViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine
import UniformTypeIdentifiers

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSDraggingSource {
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = NSScrollView()
    private let outlineView = SidebarOutlineView()
    private let bottomBar = NSView()
    private let bottomDivider = NSBox()

    private let recentGroupIdentifier = "RecentGroup"
    private let folderGroupIdentifier = "FolderGroup"

    private var stylePopover: NSPopover?
    private var webdavDialog: WebDAVSetupDialog?
    private var lastClickedNodeURL: URL?
    private var expandedFolderURLs = Set<URL>()
    private var isRecentGroupExpanded = true
    private var isFolderGroupExpanded = true
    private var isPerformingLocalTreeUpdate = false

    private enum SelectionSource {
        case folderTree
        case recentFiles
    }
    private var selectionSource: SelectionSource = .recentFiles
    private var lastClickedSidebarURL: URL?

    private func isURLInTree(_ url: URL) -> Bool {
        let stdPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        for root in state.rootFolders {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            if stdPath == rootPath || stdPath.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }

    private func isItemRowSelected(item: Any) -> Bool {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0, let selectedItem = outlineView.item(atRow: selectedRow) else {
            return false
        }
        if let node = item as? FileNode {
            guard !node.isDirectory, selectionSource == .folderTree else { return false }
            return (selectedItem as? FileNode)?.url.standardizedFileURL == node.url.standardizedFileURL
        } else if let url = item as? URL {
            guard selectionSource == .recentFiles else { return false }
            return (selectedItem as? URL)?.standardizedFileURL == url.standardizedFileURL
        }
        return false
    }

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        // Translucent sidebar background extending all the way to the top behind traffic lights
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .followsWindowActiveState
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(visualEffectView)

        setupOutlineView()
        setupBottomBar()

        container.addSubview(scrollView)
        container.addSubview(bottomDivider)
        container.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: container.topAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Start outline view content right below traffic lights
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 40)
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindState()
        reloadDataAndExpand()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadDataAndExpand()
    }

    private func setupOutlineView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = "Sidebar"
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.backgroundColor = .clear
        outlineView.target = self
        outlineView.action = #selector(handleOutlineClick)
        outlineView.menu = makeContextMenu()

        // Drag and drop registration
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView
    }

    private func setupBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomDivider.boxType = .separator

        let settingsButton = NSButton()
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.isBordered = false
        if #available(macOS 11.0, *) {
            settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        }
        settingsButton.toolTip = "设置"
        settingsButton.target = self
        settingsButton.action = #selector(handleSettings)

        let styleButton = NSButton()
        styleButton.translatesAutoresizingMaskIntoConstraints = false
        styleButton.bezelStyle = .regularSquare
        styleButton.isBordered = false
        if #available(macOS 11.0, *) {
            styleButton.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "样式")
        }
        styleButton.toolTip = "样式"
        styleButton.target = self
        styleButton.action = #selector(handleStylePicker(_:))

        bottomBar.addSubview(settingsButton)
        bottomBar.addSubview(styleButton)

        NSLayoutConstraint.activate([
            styleButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -10),
            styleButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            styleButton.widthAnchor.constraint(equalToConstant: 24),
            styleButton.heightAnchor.constraint(equalToConstant: 24),

            settingsButton.trailingAnchor.constraint(equalTo: styleButton.leadingAnchor, constant: -6),
            settingsButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func bindState() {
        state.$tree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isPerformingLocalTreeUpdate { return }
                self.reloadDataAndExpand()
            }
            .store(in: &cancellables)

        state.$recentFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadDataAndExpand()
            }
            .store(in: &cancellables)

        state.$selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self = self else { return }
                if let lastClicked = self.lastClickedSidebarURL, lastClicked == url {
                    self.lastClickedSidebarURL = nil
                } else if let url = url {
                    if self.state.isRestoringLastOpenedFile {
                        self.selectionSource = .recentFiles
                    } else {
                        self.selectionSource = self.isURLInTree(url) ? .folderTree : .recentFiles
                    }
                }
                self.syncSelection(url)
            }
            .store(in: &cancellables)

        SyncCoordinator.shared.$syncStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadVisibleRows()
            }
            .store(in: &cancellables)
    }

    private func reloadVisibleRows() {
        let rowRange = outlineView.rows(in: outlineView.visibleRect)
        guard rowRange.length > 0 else {
            outlineView.reloadData()
            return
        }
        for row in rowRange.location..<(rowRange.location + rowRange.length) {
            guard let item = outlineView.item(atRow: row),
                  let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCellView else {
                continue
            }
            if let node = item as? FileNode {
                let isWebDAVRoot = SyncCoordinator.shared.rootConfig(for: node.url) != nil
                let syncStatus = SyncCoordinator.shared.syncStatus(for: node.url, isDirectory: node.isDirectory)
                let isSelected = isItemRowSelected(item: node)
                cellView.configure(
                    title: node.displayName,
                    isDirectory: node.isDirectory,
                    isSelected: isSelected,
                    url: node.url,
                    isWebDAVRoot: isWebDAVRoot,
                    syncStatus: syncStatus
                )
            } else if let url = item as? URL {
                let parentName = url.deletingLastPathComponent().lastPathComponent
                let displayName = (!parentName.isEmpty && parentName != "/") ? "\(parentName)/\(url.lastPathComponent)" : url.lastPathComponent
                let isSelected = isItemRowSelected(item: url)
                let syncStatus = SyncCoordinator.shared.syncStatus(for: url, isDirectory: false)
                cellView.configure(
                    title: displayName,
                    isDirectory: false,
                    isSelected: isSelected,
                    url: url,
                    isWebDAVRoot: false,
                    syncStatus: syncStatus
                )
            }
        }
    }

    private func reloadDataAndExpand() {
        // 1. Snapshot all currently expanded folder URLs from the outline view
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, node.isDirectory, outlineView.isItemExpanded(node) {
                expandedFolderURLs.insert(node.url)
            }
        }

        outlineView.reloadData()

        // 2. Expand groups according to user preference
        if isRecentGroupExpanded {
            outlineView.expandItem(recentGroupIdentifier, expandChildren: false)
        }
        if isFolderGroupExpanded {
            outlineView.expandItem(folderGroupIdentifier, expandChildren: false)
        }

        // 3. Restore all previously expanded folders
        restoreExpandedItems(for: state.tree)

        // 4. Ensure current selection's ancestors are expanded
        if selectionSource != .recentFiles, let currentURL = state.selection {
            expandAncestors(of: currentURL, in: state.tree)
        }

        syncSelection(state.selection)
    }

    private func restoreExpandedItems(for nodes: [FileNode]) {
        for node in nodes {
            if node.isDirectory {
                if expandedFolderURLs.contains(node.url) {
                    outlineView.expandItem(node, expandChildren: false)
                    if let children = node.children {
                        restoreExpandedItems(for: children)
                    }
                }
            }
        }
    }

    private func expandAncestors(of targetURL: URL, in nodes: [FileNode]) {
        let targetPath = targetURL.standardizedFileURL.path
        for node in nodes {
            if node.isDirectory, let children = node.children {
                let nodePath = node.url.standardizedFileURL.path
                if targetPath == nodePath || targetPath.hasPrefix(nodePath + "/") {
                    expandedFolderURLs.insert(node.url)
                    outlineView.expandItem(node, expandChildren: false)
                    expandAncestors(of: targetURL, in: children)
                }
            }
        }
    }

    private func syncSelection(_ selectedURL: URL?) {
        guard let url = selectedURL else {
            outlineView.deselectAll(nil)
            return
        }

        let stdURL = url.standardizedFileURL

        if selectionSource == .recentFiles {
            var recentRow: Int? = nil
            for row in 0..<outlineView.numberOfRows {
                guard let item = outlineView.item(atRow: row) else { continue }
                if let recentURL = item as? URL, recentURL.standardizedFileURL == stdURL {
                    recentRow = row
                    break
                }
            }

            if let row = recentRow {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            } else {
                outlineView.deselectAll(nil)
            }
            return
        }

        expandAncestors(of: stdURL, in: state.tree)

        // Prioritize selecting the FileNode in the folder tree so the user stays oriented in their directory structure
        var treeRow: Int? = nil
        var recentRow: Int? = nil

        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) else { continue }
            if let node = item as? FileNode, node.url.standardizedFileURL == stdURL {
                treeRow = row
                break // Found node in folder tree!
            } else if recentRow == nil, let recentURL = item as? URL, recentURL.standardizedFileURL == stdURL {
                recentRow = row
            }
        }

        let targetRow: Int?
        if selectionSource == .folderTree {
            // 当来源是文件夹树时，严格只在文件夹树中匹配行；如果文件在树中已不存在，绝不能 fallback 到最近打开列表中
            targetRow = treeRow
        } else {
            targetRow = treeRow ?? recentRow
        }

        if let row = targetRow {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    // MARK: - Actions

    @objc private func handleOutlineClick() {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) else { return }

        if let str = item as? String {
            if str == folderGroupIdentifier {
                toggleFolderGroup()
            } else if str == recentGroupIdentifier {
                toggleRecentGroup()
            }
            return
        }

        if let node = item as? FileNode {
            if node.isDirectory {
                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                    expandedFolderURLs.remove(node.url)
                } else {
                    outlineView.expandItem(item)
                    expandedFolderURLs.insert(node.url)
                }
                syncSelection(state.selection)
            } else {
                lastClickedSidebarURL = node.url
                selectionSource = .folderTree
                state.openFile(node.url)
                syncSelection(node.url)
            }
        } else if let url = item as? URL {
            lastClickedSidebarURL = url
            selectionSource = .recentFiles
            state.openFile(url)
            syncSelection(url)
        }
    }

    private func toggleFolderGroup() {
        if outlineView.isItemExpanded(folderGroupIdentifier) {
            outlineView.collapseItem(folderGroupIdentifier, collapseChildren: false)
            isFolderGroupExpanded = false
        } else {
            outlineView.expandItem(folderGroupIdentifier, expandChildren: false)
            isFolderGroupExpanded = true
        }
        updateFolderGroupHeader()
    }

    private func toggleRecentGroup() {
        if outlineView.isItemExpanded(recentGroupIdentifier) {
            outlineView.collapseItem(recentGroupIdentifier, collapseChildren: false)
            isRecentGroupExpanded = false
        } else {
            outlineView.expandItem(recentGroupIdentifier, expandChildren: false)
            isRecentGroupExpanded = true
        }
        updateRecentGroupHeader()
    }

    private func updateFolderGroupHeader() {
        let row = outlineView.row(forItem: folderGroupIdentifier)
        guard row >= 0, let headerCell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCellView else { return }
        let isExpanded = outlineView.isItemExpanded(folderGroupIdentifier)
        headerCell.setExpanded(isExpanded)
    }

    private func updateRecentGroupHeader() {
        let row = outlineView.row(forItem: recentGroupIdentifier)
        guard row >= 0, let headerCell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCellView else { return }
        let isExpanded = outlineView.isItemExpanded(recentGroupIdentifier)
        headerCell.setExpanded(isExpanded)
    }

    @objc private func handleOpenFolder() {
        state.promptOpenFolder()
    }

    @objc private func handleSettings() {
        // Reserved for future settings panel
    }

    @objc private func handleStylePicker(_ sender: NSButton) {
        if let popover = stylePopover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let styleVC = StylePopoverViewController(state: state)
        styleVC.onStyleSelected = { [weak popover] _ in
            popover?.performClose(nil)
        }
        popover.contentViewController = styleVC
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        self.stylePopover = popover
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            var count = 1 // Folders group is always present
            if !state.recentFiles.isEmpty { count += 1 } // Recent group
            return count
        }

        if let str = item as? String {
            if str == recentGroupIdentifier {
                return state.recentFiles.count
            } else if str == folderGroupIdentifier {
                return state.tree.count
            }
        }

        if let node = item as? FileNode {
            return node.children?.count ?? 0
        }

        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if !state.recentFiles.isEmpty {
                return index == 0 ? recentGroupIdentifier : folderGroupIdentifier
            }
            return folderGroupIdentifier
        }

        if let str = item as? String {
            if str == recentGroupIdentifier {
                return state.recentFiles[index]
            } else if str == folderGroupIdentifier {
                return state.tree[index]
            }
        }

        if let node = item as? FileNode {
            return node.children?[index] ?? FileNode(url: URL(fileURLWithPath: "/"), isDirectory: false)
        }

        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let str = item as? String {
            return str == recentGroupIdentifier || str == folderGroupIdentifier
        }
        if let node = item as? FileNode {
            return node.isDirectory && (node.children?.count ?? 0) > 0
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let str = item as? String {
            return str == recentGroupIdentifier || str == folderGroupIdentifier
        }
        return false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowId = NSUserInterfaceItemIdentifier("SidebarTableRowView")
        var rowView = outlineView.makeView(withIdentifier: rowId, owner: self) as? SidebarTableRowView
        if rowView == nil {
            rowView = SidebarTableRowView()
            rowView?.identifier = rowId
        }
        if let node = item as? FileNode {
            rowView?.isDirectory = node.isDirectory
        } else {
            rowView?.isDirectory = false
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if rowView.isGroupRowStyle {
            for subview in rowView.subviews {
                if let button = subview as? NSButton {
                    let id = button.identifier?.rawValue ?? ""
                    if id.contains("ShowHide") || id.contains("Disclosure") ||
                       button.identifier == NSOutlineView.showHideButtonIdentifier ||
                       button.identifier == NSOutlineView.disclosureButtonIdentifier {
                        button.isHidden = true
                        button.frame = .zero
                        button.alphaValue = 0
                    }
                }
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let str = item as? String {
            let headerId = NSUserInterfaceItemIdentifier("HeaderCell")
            var headerView = outlineView.makeView(withIdentifier: headerId, owner: self) as? SidebarHeaderCellView
            if headerView == nil {
                headerView = SidebarHeaderCellView()
                headerView?.identifier = headerId
            }
            let isFolder = (str == folderGroupIdentifier)
            let isExpanded = outlineView.isItemExpanded(str)
            headerView?.configure(
                title: isFolder ? "文件夹" : "最近打开",
                isExpanded: isExpanded,
                showAddButton: isFolder
            )
            headerView?.onChevronClicked = { [weak self] in
                if isFolder {
                    self?.toggleFolderGroup()
                } else {
                    self?.toggleRecentGroup()
                }
            }
            headerView?.onActionClicked = { [weak self] in
                self?.handleOpenFolder()
            }
            return headerView
        }

        let cellId = NSUserInterfaceItemIdentifier("SidebarRowCell")
        var cellView = outlineView.makeView(withIdentifier: cellId, owner: self) as? SidebarRowCellView
        if cellView == nil {
            cellView = SidebarRowCellView()
            cellView?.identifier = cellId
        }

        if let node = item as? FileNode {
            let isWebDAVRoot = SyncCoordinator.shared.rootConfig(for: node.url) != nil
            let syncStatus = SyncCoordinator.shared.syncStatus(for: node.url, isDirectory: node.isDirectory)
            let isSelected = isItemRowSelected(item: node)
            cellView?.configure(
                title: node.displayName,
                isDirectory: node.isDirectory,
                isSelected: isSelected,
                url: node.url,
                isWebDAVRoot: isWebDAVRoot,
                syncStatus: syncStatus
            )
        } else if let url = item as? URL {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            let displayName = (!parentName.isEmpty && parentName != "/") ? "\(parentName)/\(url.lastPathComponent)" : url.lastPathComponent
            let isSelected = isItemRowSelected(item: url)
            let syncStatus = SyncCoordinator.shared.syncStatus(for: url, isDirectory: false)
            cellView?.configure(
                title: displayName,
                isDirectory: false,
                isSelected: isSelected,
                url: url,
                isWebDAVRoot: false,
                syncStatus: syncStatus
            )
        }

        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if item is String { return false }
        if let node = item as? FileNode, node.isDirectory { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        var validIndexes = IndexSet()
        for idx in proposedSelectionIndexes {
            guard let item = outlineView.item(atRow: idx) else { continue }
            if item is String { continue }
            if let node = item as? FileNode, node.isDirectory { continue }
            validIndexes.insert(idx)
        }
        return validIndexes.isEmpty ? outlineView.selectedRowIndexes : validIndexes
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        lastClickedNodeURL = nil
        let selectedRow = outlineView.selectedRow
        if selectedRow >= 0, let item = outlineView.item(atRow: selectedRow) {
            if item is URL {
                selectionSource = .recentFiles
            } else if let node = item as? FileNode, !node.isDirectory {
                selectionSource = .folderTree
            }
        }
        reloadVisibleRows()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        if let str = item as? String {
            if str == recentGroupIdentifier {
                isRecentGroupExpanded = true
                updateRecentGroupHeader()
            } else if str == folderGroupIdentifier {
                isFolderGroupExpanded = true
                updateFolderGroupHeader()
            }
        } else if let node = item as? FileNode, node.isDirectory {
            expandedFolderURLs.insert(node.url)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        if let str = item as? String {
            if str == recentGroupIdentifier {
                isRecentGroupExpanded = false
                updateRecentGroupHeader()
            } else if str == folderGroupIdentifier {
                isFolderGroupExpanded = false
                updateFolderGroupHeader()
            }
        } else if let node = item as? FileNode, node.isDirectory {
            expandedFolderURLs.remove(node.url)
        }
    }

    // MARK: - Context Menus

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func showDeleteConfirmation(for url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        let alert = NSAlert()
        alert.messageText = isDir.boolValue ? "确认将该文件夹移到废纸篓？" : "确认将该文件移到废纸篓？"
        alert.informativeText = isDir.boolValue
            ? "\(url.lastPathComponent)\n该文件夹及其包含的所有内容将被移到废纸篓。"
            : "\(url.lastPathComponent)\n该文件将被移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")

        let performDelete = { [weak self] in
            guard let self = self else { return }
            if self.state.deleteItem(at: url) {
                self.expandedFolderURLs = self.expandedFolderURLs.filter { !$0.path.hasPrefix(url.path) }
                if let sel = self.state.selection, sel == url || sel.path.hasPrefix(url.path + "/") {
                    self.outlineView.deselectAll(nil)
                }
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    performDelete()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                performDelete()
            }
        }
    }

    // MARK: - Drag and Drop Support

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if let node = item as? FileNode {
            return node.url as NSURL
        }
        if let url = item as? URL {
            return url as NSURL
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if let node = item as? FileNode, node.isDirectory {
            return .move
        }
        if item == nil {
            return .copy
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let board = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !board.isEmpty else {
            return false
        }

        if let node = item as? FileNode, node.isDirectory {
            var success = true
            for url in board {
                if !state.moveItem(at: url, toDirectory: node.url) {
                    success = false
                }
            }
            return success
        } else if item == nil {
            board.forEach { state.addRootFolder($0, storeBookmark: true) }
            return true
        }

        return false
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rightRow = outlineView.rightClickedRow
        let clickedRow = rightRow >= 0 ? rightRow : (outlineView.clickedRow >= 0 ? outlineView.clickedRow : -1)

        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) else {
            lastClickedNodeURL = nil
            menu.addItem(withTitle: "打开本地文件夹...", action: #selector(contextOpenFolder), keyEquivalent: "")
            menu.addItem(withTitle: "添加 WebDAV 同步文件夹...", action: #selector(handleAddWebDAVFolder), keyEquivalent: "")
            return
        }

        let targetURL: URL?
        if let node = item as? FileNode {
            targetURL = node.url
            lastClickedNodeURL = node.url
        } else if let url = item as? URL {
            targetURL = url
            lastClickedNodeURL = url
        } else {
            targetURL = nil
            lastClickedNodeURL = nil
        }

        func addItem(title: String, action: Selector, keyEquivalent: String = "") {
            let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
            mi.representedObject = targetURL
        }

        if let str = item as? String, str == folderGroupIdentifier {
            addItem(title: "打开本地文件夹...", action: #selector(contextOpenFolder))
            addItem(title: "添加 WebDAV 同步文件夹...", action: #selector(handleAddWebDAVFolder))
            if !SyncCoordinator.shared.configs.isEmpty {
                menu.addItem(NSMenuItem.separator())
                addItem(title: "立即同步全部 WebDAV", action: #selector(contextSyncAll))
            }
            return
        }

        if let node = item as? FileNode {
            if node.isDirectory {
                let isRootFolder = state.rootFolders.contains { $0.standardizedFileURL == node.url.standardizedFileURL }
                if SyncCoordinator.shared.config(for: node.url) != nil {
                    addItem(title: "立即同步", action: #selector(contextSyncNow))
                    if SyncCoordinator.shared.rootConfig(for: node.url) != nil {
                        addItem(title: "WebDAV 设置...", action: #selector(contextEditWebDAV))
                        addItem(title: "取消 WebDAV 同步", action: #selector(contextUnlinkWebDAV))
                    }
                    menu.addItem(NSMenuItem.separator())
                } else if isRootFolder {
                    addItem(title: "配置 WebDAV", action: #selector(contextConfigureWebDAV))
                    menu.addItem(NSMenuItem.separator())
                }
                addItem(title: "新增文件夹", action: #selector(contextNewFolder))
                addItem(title: "新增文件", action: #selector(contextNewFile))
                addItem(title: "修改文件夹名", action: #selector(contextRename))
                menu.addItem(NSMenuItem.separator())
                addItem(title: "刷新", action: #selector(contextRefresh))
                if isRootFolder {
                    addItem(title: "移除书签", action: #selector(contextRemoveRoot))
                } else {
                    addItem(title: "移到废纸篓", action: #selector(contextDelete), keyEquivalent: "\u{08}")
                }
                addItem(title: "在 Finder 中显示", action: #selector(contextRevealInFinder))
            } else {
                addItem(title: "修改文件名", action: #selector(contextRename))
                addItem(title: "创建副本", action: #selector(contextDuplicate))
                menu.addItem(NSMenuItem.separator())
                addItem(title: "刷新", action: #selector(contextRefresh))
                addItem(title: "移到废纸篓", action: #selector(contextDelete), keyEquivalent: "\u{08}")
                addItem(title: "在 Finder 中显示", action: #selector(contextRevealInFinder))
            }
        } else if item is URL {
            addItem(title: "移除记录", action: #selector(contextRemoveRecent))
            addItem(title: "在 Finder 中显示", action: #selector(contextRevealInFinder))
        }
    }

    private func targetURL(from sender: Any?) -> URL? {
        if let menuItem = sender as? NSMenuItem, let url = menuItem.representedObject as? URL {
            return url
        }
        return targetURLFromClickedRow
    }

    private var targetURLFromClickedRow: URL? {
        if let last = lastClickedNodeURL {
            return last
        }
        let rightRow = outlineView.rightClickedRow
        let row = rightRow >= 0 ? rightRow : (outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow)
        if row >= 0, let item = outlineView.item(atRow: row) {
            if let node = item as? FileNode { return node.url }
            if let url = item as? URL { return url }
        }
        return nil
    }

    @objc private func contextOpenFolder() {
        state.promptOpenFolder()
    }

    @objc private func contextNewFolder(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        let parentDir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        NamePromptDialog.show(context: .newFolder(parent: parentDir), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.expandedFolderURLs.insert(parentDir)
            self?.state.createFolder(named: name, in: parentDir)
        }
    }

    @objc private func contextNewFile(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        let parentDir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        NamePromptDialog.show(context: .newFile(parent: parentDir), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.expandedFolderURLs.insert(parentDir)
            self?.state.createFile(named: name, in: parentDir)
        }
    }

    @objc private func contextRename(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        NamePromptDialog.show(context: .rename(target: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.renameItem(at: url, to: name)
        }
    }

    @objc private func contextDuplicate(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        NamePromptDialog.show(context: .duplicate(target: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.duplicateFile(at: url, newName: name)
        }
    }

    @objc private func contextRefresh() {
        state.refresh()
    }

    @objc private func contextRemoveRoot(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        removeRootBookmark(url)
    }

    private func removeRootBookmark(_ url: URL) {
        let stdURL = url.standardizedFileURL
        guard let index = state.rootFolders.firstIndex(where: { $0.standardizedFileURL == stdURL }) else {
            state.removeRootFolder(url)
            return
        }

        // Clean up expanded state for the removed root folder and all its descendants
        expandedFolderURLs = expandedFolderURLs.filter { !$0.path.hasPrefix(url.path) }

        // Clear selection if the selected file was within this folder
        if let currentURL = state.selection, currentURL.path.hasPrefix(url.path) {
            outlineView.deselectAll(nil)
        }

        // Mark local update so Combine $tree publisher won't trigger reloadDataAndExpand()
        isPerformingLocalTreeUpdate = true
        state.removeRootFolder(url)

        // Remove only this row and its children under folderGroupIdentifier
        outlineView.removeItems(at: IndexSet(integer: index), inParent: folderGroupIdentifier, withAnimation: .effectFade)

        DispatchQueue.main.async { [weak self] in
            self?.isPerformingLocalTreeUpdate = false
        }
    }

    @objc private func contextRemoveRecent(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        state.removeRecentFile(url)
    }

    @objc private func contextDelete(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        showDeleteConfirmation(for: url)
    }

    func deleteSelectedItem() {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let node = item as? FileNode {
            let isRoot = state.rootFolders.contains { $0.standardizedFileURL == node.url.standardizedFileURL }
            if !isRoot {
                showDeleteConfirmation(for: node.url)
            }
        }
    }

    @objc private func contextRevealInFinder(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        state.revealInFinder(url)
    }

    @objc func handleAddWebDAVFolder() {
        let dialog = WebDAVSetupDialog(state: state)
        self.webdavDialog = dialog
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func contextSyncNow(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        Task {
            await SyncCoordinator.shared.syncFolder(url: url)
        }
    }

    @objc private func contextSyncAll() {
        SyncCoordinator.shared.syncAll()
    }

    @objc private func contextUnlinkWebDAV(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender),
              let cfg = SyncCoordinator.shared.rootConfig(for: url) else { return }
        SyncCoordinator.shared.removeConfig(id: cfg.id)
        outlineView.reloadData()
    }

    @objc private func contextEditWebDAV(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender),
              let cfg = SyncCoordinator.shared.rootConfig(for: url) ?? SyncCoordinator.shared.config(for: url) else { return }
        let dialog = WebDAVSetupDialog(state: state, existingConfig: cfg)
        self.webdavDialog = dialog
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func contextConfigureWebDAV(_ sender: Any? = nil) {
        guard let url = targetURL(from: sender) else { return }
        let dialog = WebDAVSetupDialog(state: state, preselectedLocalURL: url)
        self.webdavDialog = dialog
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
    }
}

private final class SidebarRowCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let statusImageView = NSImageView()
    private let statusIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentTintColor = .secondaryLabelColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13.5)
        label.lineBreakMode = .byTruncatingTail

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.style = .spinning
        statusIndicator.controlSize = .small
        statusIndicator.isDisplayedWhenStopped = false

        addSubview(iconImageView)
        addSubview(label)
        addSubview(statusImageView)
        addSubview(statusIndicator)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            statusImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 16),
            statusImageView.heightAnchor.constraint(equalToConstant: 16),

            statusIndicator.centerXAnchor.constraint(equalTo: statusImageView.centerXAnchor),
            statusIndicator.centerYAnchor.constraint(equalTo: statusImageView.centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 14),
            statusIndicator.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: statusImageView.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(
        title: String,
        isDirectory: Bool,
        isSelected: Bool,
        url: URL? = nil,
        isWebDAVRoot: Bool = false,
        syncStatus: FolderSyncStatus = .synced
    ) {
        label.stringValue = title
        iconImageView.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        if #available(macOS 11.0, *) {
            let symbolName: String
            if isWebDAVRoot {
                symbolName = "network"
                iconImageView.toolTip = "WebDAV 同步文件夹"
            } else if isDirectory {
                symbolName = "folder"
                iconImageView.toolTip = nil
            } else if let url = url {
                let type = SupportedFileType.detect(url: url)
                switch type {
                case .markdown:
                    symbolName = "doc.text"
                case .html:
                    symbolName = "globe"
                case .text:
                    symbolName = "doc.plaintext"
                case .image:
                    symbolName = "photo"
                case .other:
                    let ext = url.pathExtension.lowercased()
                    if ["webm", "mp4", "mov", "mkv", "avi", "m4v", "ts"].contains(ext) {
                        symbolName = "film"
                    } else {
                        symbolName = "doc"
                    }
                }
                iconImageView.toolTip = nil
            } else {
                symbolName = "doc.text"
                iconImageView.toolTip = nil
            }
            iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }

        switch syncStatus {
        case .syncing(let msg):
            statusImageView.isHidden = true
            statusIndicator.isHidden = false
            statusIndicator.startAnimation(nil)
            statusIndicator.toolTip = msg
        case .error(let msg):
            statusIndicator.stopAnimation(nil)
            statusIndicator.isHidden = true
            statusImageView.isHidden = false
            if #available(macOS 11.0, *) {
                statusImageView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "同步错误")
            }
            statusImageView.contentTintColor = .systemRed
            statusImageView.toolTip = "同步失败: \(msg)"
        case .modified:
            statusIndicator.stopAnimation(nil)
            statusIndicator.isHidden = true
            statusImageView.isHidden = false
            if #available(macOS 11.0, *) {
                statusImageView.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "待同步")
            }
            statusImageView.contentTintColor = .systemOrange
            statusImageView.toolTip = "有未同步的本地改动"
        case .synced:
            statusIndicator.stopAnimation(nil)
            statusIndicator.isHidden = true
            statusImageView.isHidden = true
            statusImageView.toolTip = nil
        }
    }
}

// MARK: - Custom Views for Sidebar

final class HoverIconButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        contentTintColor = .secondaryLabelColor
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class SidebarHeaderCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronButton = HoverIconButton()
    private let actionButton = HoverIconButton()

    var onChevronClicked: (() -> Void)?
    var onActionClicked: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.bezelStyle = .regularSquare
        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.target = self
        chevronButton.action = #selector(handleChevronAction)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .regularSquare
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.target = self
        actionButton.action = #selector(handleActionButton)
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            actionButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "打开文件夹")?.withSymbolConfiguration(config)
        }
        actionButton.toolTip = "打开文件夹"

        addSubview(titleLabel)
        addSubview(chevronButton)
        addSubview(actionButton)
        self.textField = titleLabel

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 16),
            chevronButton.heightAnchor.constraint(equalToConstant: 16),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 18),
            actionButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            var newFrame = newValue
            if let superview = superview {
                newFrame.origin.x = 0
                newFrame.size.width = superview.bounds.width
            }
            super.frame = newFrame
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let superview = superview {
            size.width = superview.bounds.width
        }
        super.setFrameSize(size)
    }

    @objc private func handleChevronAction() {
        onChevronClicked?()
    }

    @objc private func handleActionButton() {
        onActionClicked?()
    }

    func configure(title: String, isExpanded: Bool, showAddButton: Bool) {
        titleLabel.stringValue = title
        setExpanded(isExpanded)
        actionButton.isHidden = !showAddButton
    }

    func setExpanded(_ isExpanded: Bool) {
        if #available(macOS 11.0, *) {
            let symbolName = isExpanded ? "chevron.down" : "chevron.right"
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            chevronButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: isExpanded ? "折叠" : "展开")?.withSymbolConfiguration(config)
        }
    }
}

final class SidebarTableRowView: NSTableRowView {
    var isDirectory: Bool = false {
        didSet {
            if oldValue != isDirectory {
                needsDisplay = true
            }
        }
    }

    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get {
            if isDirectory { return .none }
            return super.selectionHighlightStyle
        }
        set {
            super.selectionHighlightStyle = newValue
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isDirectory {
            return
        }
        super.drawSelection(in: dirtyRect)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        hideBuiltinGroupDisclosure(subview)
    }

    override func layout() {
        super.layout()
        if isGroupRowStyle {
            for subview in subviews {
                if let cellView = subview as? SidebarHeaderCellView {
                    cellView.frame = bounds
                } else if let button = subview as? NSButton {
                    let id = button.identifier?.rawValue ?? ""
                    if id.contains("ShowHide") || id.contains("Disclosure") ||
                       button.identifier == NSOutlineView.showHideButtonIdentifier ||
                       button.identifier == NSOutlineView.disclosureButtonIdentifier {
                        button.isHidden = true
                        button.frame = .zero
                        button.alphaValue = 0
                        button.removeFromSuperview()
                    }
                }
            }
        }
    }

    private func hideBuiltinGroupDisclosure(_ subview: NSView) {
        guard isGroupRowStyle else { return }
        if let button = subview as? NSButton {
            let id = button.identifier?.rawValue ?? ""
            if id.contains("ShowHide") || id.contains("Disclosure") ||
               button.identifier == NSOutlineView.showHideButtonIdentifier ||
               button.identifier == NSOutlineView.disclosureButtonIdentifier {
                button.isHidden = true
                button.frame = .zero
                button.alphaValue = 0
                button.removeFromSuperview()
            }
        }
    }
}

final class SidebarOutlineView: NSOutlineView {
    private(set) var rightClickedRow: Int = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        rightClickedRow = row(at: point)
        return super.menu(for: event)
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if identifier == NSOutlineView.showHideButtonIdentifier ||
           identifier.rawValue == "NSOutlineViewShowHideButtonKey" {
            let emptyView = NSView(frame: .zero)
            emptyView.isHidden = true
            return emptyView
        }
        return super.makeView(withIdentifier: identifier, owner: owner)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        guard row >= 0, let item = item(atRow: row) as? String,
              (item == "RecentGroup" || item == "FolderGroup") else {
            return super.frameOfOutlineCell(atRow: row)
        }
        return .zero
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0, let item = item(atRow: clickedRow) {
            if let node = item as? FileNode, node.isDirectory {
                if isItemExpanded(item) {
                    collapseItem(item)
                } else {
                    expandItem(item)
                }
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifierFlags == .command && event.keyCode == 51 { // Cmd+Delete (Backspace)
            if let controller = delegate as? SidebarViewController {
                controller.deleteSelectedItem()
                return
            }
        }
        super.keyDown(with: event)
    }
}

