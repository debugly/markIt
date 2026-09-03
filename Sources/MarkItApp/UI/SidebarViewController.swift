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
    private let outlineView = NSOutlineView()
    private let bottomBar = NSView()
    private let bottomDivider = NSBox()

    private let recentGroupIdentifier = "RecentGroup"
    private let folderGroupIdentifier = "FolderGroup"

    private var stylePopover: NSPopover?

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

        let openFolderButton = NSButton()
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        openFolderButton.bezelStyle = .regularSquare
        openFolderButton.isBordered = false
        if #available(macOS 11.0, *) {
            openFolderButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开文件夹")
        }
        openFolderButton.title = " 打开文件夹"
        openFolderButton.imagePosition = .imageLeading
        openFolderButton.font = .systemFont(ofSize: 12, weight: .medium)
        openFolderButton.target = self
        openFolderButton.action = #selector(handleOpenFolder)

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

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        bottomBar.addSubview(openFolderButton)
        bottomBar.addSubview(separator)
        bottomBar.addSubview(settingsButton)
        bottomBar.addSubview(styleButton)

        NSLayoutConstraint.activate([
            openFolderButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 10),
            openFolderButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            openFolderButton.heightAnchor.constraint(equalToConstant: 24),

            styleButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -10),
            styleButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            styleButton.widthAnchor.constraint(equalToConstant: 24),
            styleButton.heightAnchor.constraint(equalToConstant: 24),

            settingsButton.trailingAnchor.constraint(equalTo: styleButton.leadingAnchor, constant: -6),
            settingsButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),

            separator.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -6),
            separator.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 16),
            separator.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func bindState() {
        state.$tree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadDataAndExpand()
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
                self?.syncSelection(url)
            }
            .store(in: &cancellables)
    }

    private func reloadDataAndExpand() {
        outlineView.reloadData()
        outlineView.expandItem(recentGroupIdentifier, expandChildren: false)
        outlineView.expandItem(folderGroupIdentifier, expandChildren: false)
        syncSelection(state.selection)
    }

    private func syncSelection(_ selectedURL: URL?) {
        guard let url = selectedURL else {
            outlineView.deselectAll(nil)
            return
        }

        // Search in recent items and tree
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) {
                if let node = item as? FileNode, node.url == url {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                } else if let recentURL = item as? URL, recentURL == url {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func handleOutlineClick() {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) else { return }

        if let node = item as? FileNode {
            if node.isDirectory {
                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item)
                }
            } else {
                state.openFile(node.url)
            }
        } else if let url = item as? URL {
            state.openFile(url)
        }
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
            var count = 0
            if !state.recentFiles.isEmpty { count += 1 } // Recent group
            if !state.tree.isEmpty || state.recentFiles.isEmpty { count += 1 } // Folders group
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

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let str = item as? String {
            let headerId = NSUserInterfaceItemIdentifier("HeaderCell")
            var headerView = outlineView.makeView(withIdentifier: headerId, owner: self) as? NSTableCellView
            if headerView == nil {
                headerView = NSTableCellView()
                headerView?.identifier = headerId
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                headerView?.addSubview(label)
                headerView?.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: headerView!.leadingAnchor, constant: 4),
                    label.centerYAnchor.constraint(equalTo: headerView!.centerYAnchor)
                ])
            }
            headerView?.textField?.stringValue = (str == recentGroupIdentifier) ? "最近打开" : "文件夹"
            return headerView
        }

        let cellId = NSUserInterfaceItemIdentifier("SidebarRowCell")
        var cellView = outlineView.makeView(withIdentifier: cellId, owner: self) as? SidebarRowCellView
        if cellView == nil {
            cellView = SidebarRowCellView()
            cellView?.identifier = cellId
        }

        if let node = item as? FileNode {
            cellView?.configure(
                title: node.displayName,
                isDirectory: node.isDirectory,
                isSelected: state.selection == node.url
            )
        } else if let url = item as? URL {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            let displayName = (!parentName.isEmpty && parentName != "/") ? "\(parentName)/\(url.lastPathComponent)" : url.lastPathComponent
            cellView?.configure(
                title: displayName,
                isDirectory: false,
                isSelected: state.selection == url
            )
        }

        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return !(item is String)
    }

    // MARK: - Context Menus

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func showDeleteConfirmation(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "确认删除该文件？"
        alert.informativeText = url.lastPathComponent
        alert.alertStyle = .critical
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.state.deleteItem(at: url)
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                state.deleteItem(at: url)
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
        let clickedRow = outlineView.clickedRow

        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) else {
            menu.addItem(withTitle: "打开文件夹...", action: #selector(contextOpenFolder), keyEquivalent: "")
            return
        }

        if let node = item as? FileNode {
            if node.isDirectory {
                menu.addItem(withTitle: "新增文件夹", action: #selector(contextNewFolder), keyEquivalent: "")
                menu.addItem(withTitle: "新增文件", action: #selector(contextNewFile), keyEquivalent: "")
                menu.addItem(withTitle: "修改文件夹名", action: #selector(contextRename), keyEquivalent: "")
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "刷新", action: #selector(contextRefresh), keyEquivalent: "")
                menu.addItem(withTitle: "移除书签", action: #selector(contextRemoveRoot), keyEquivalent: "")
                menu.addItem(withTitle: "在 Finder 中显示", action: #selector(contextRevealInFinder), keyEquivalent: "")
            } else {
                menu.addItem(withTitle: "修改文件名", action: #selector(contextRename), keyEquivalent: "")
                menu.addItem(withTitle: "创建副本", action: #selector(contextDuplicate), keyEquivalent: "")
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "刷新", action: #selector(contextRefresh), keyEquivalent: "")
                menu.addItem(withTitle: "删除", action: #selector(contextDelete), keyEquivalent: "")
                menu.addItem(withTitle: "在 Finder 中显示", action: #selector(contextRevealInFinder), keyEquivalent: "")
            }
        } else if item is URL {
            menu.addItem(withTitle: "移除记录", action: #selector(contextRemoveRecent), keyEquivalent: "")
            menu.addItem(withTitle: "在 Finder 中显示", action: #selector(contextRevealInFinder), keyEquivalent: "")
        }
    }

    private var targetURLFromClickedRow: URL? {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return nil }
        if let node = item as? FileNode { return node.url }
        if let url = item as? URL { return url }
        return nil
    }

    @objc private func contextOpenFolder() {
        state.promptOpenFolder()
    }

    @objc private func contextNewFolder() {
        guard let url = targetURLFromClickedRow else { return }
        NamePromptDialog.show(context: .newFolder(parent: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.createFolder(named: name, in: url)
        }
    }

    @objc private func contextNewFile() {
        guard let url = targetURLFromClickedRow else { return }
        NamePromptDialog.show(context: .newFile(parent: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.createFile(named: name, in: url)
        }
    }

    @objc private func contextRename() {
        guard let url = targetURLFromClickedRow else { return }
        NamePromptDialog.show(context: .rename(target: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.renameItem(at: url, to: name)
        }
    }

    @objc private func contextDuplicate() {
        guard let url = targetURLFromClickedRow else { return }
        NamePromptDialog.show(context: .duplicate(target: url), on: view.window) { [weak self] name in
            guard let name = name else { return }
            self?.state.duplicateFile(at: url, newName: name)
        }
    }

    @objc private func contextRefresh() {
        state.refresh()
    }

    @objc private func contextRemoveRoot() {
        guard let url = targetURLFromClickedRow else { return }
        state.removeRootFolder(url)
    }

    @objc private func contextRemoveRecent() {
        guard let url = targetURLFromClickedRow else { return }
        state.removeRecentFile(url)
    }

    @objc private func contextDelete() {
        guard let url = targetURLFromClickedRow else { return }
        showDeleteConfirmation(for: url)
    }

    @objc private func contextRevealInFinder() {
        guard let url = targetURLFromClickedRow else { return }
        state.revealInFinder(url)
    }
}

private final class SidebarRowCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

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

        addSubview(iconImageView)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(title: String, isDirectory: Bool, isSelected: Bool) {
        label.stringValue = title
        if #available(macOS 11.0, *) {
            let symbolName = isDirectory ? "folder" : "doc.text"
            iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
    }
}
