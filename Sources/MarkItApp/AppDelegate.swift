//
//  AppDelegate.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine

@objc protocol UndoRedoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static var sharedDelegate: AppDelegate?

    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        sharedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    let appState = AppState()
    var mainWindowController: MainWindowController!
    private var cancellables = Set<AnyCancellable>()

    private var recentFilesSubmenu: NSMenu?
    private var pendingLaunchURL: URL?
    private var isAppLaunched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[MarkIt Log] applicationDidFinishLaunching started")
        NSApp.setActivationPolicy(.regular)

        setupMainMenu()

        mainWindowController = MainWindowController(state: appState)
        mainWindowController.show()
        NSApp.activate(ignoringOtherApps: true)

        observeRecentFiles()
        SyncCoordinator.shared.syncAll()
        isAppLaunched = true
        print("[MarkIt Log] applicationDidFinishLaunching finished, window is visible: \(mainWindowController.window?.isVisible ?? false)")
        handleLaunchFile()
    }

    private func handleLaunchFile() {
        if let url = pendingLaunchURL {
            pendingLaunchURL = nil
            appState.hasOpenedFileOnLaunch = true
            appState.openFile(url)
        } else if let url = getInitialFileURL() {
            appState.hasOpenedFileOnLaunch = true
            appState.openFile(url)
        } else if !appState.hasOpenedFileOnLaunch && appState.document.url == nil {
            appState.restoreLastOpenedFile()
        }
    }

    private static func getInitialFileURL() -> URL? {
        let args = CommandLine.arguments
        guard args.count > 1 else { return nil }
        for arg in args.dropFirst() {
            if arg.hasPrefix("-") { continue }
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func getInitialFileURL() -> URL? {
        return Self.getInitialFileURL()
    }

    private func handleOpenFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if isAppLaunched {
            if appState.document.url != url {
                appState.openFile(url)
            }
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        } else {
            pendingLaunchURL = url
            appState.hasOpenedFileOnLaunch = true
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        handleOpenFile(url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        handleOpenFile(url)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return appState.document.confirmCloseIfNeeded() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "偏好设置...", action: nil, keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())

        let servicesMenu = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")

        fileMenu.addItem(withTitle: "新建文件", action: #selector(menuNewFile), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "打开文件...", action: #selector(menuOpenFile), keyEquivalent: "o")

        let openFolderItem = fileMenu.addItem(withTitle: "打开文件夹...", action: #selector(menuOpenFolder), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(withTitle: "添加 WebDAV 文件夹...", action: #selector(menuAddWebDAVFolder), keyEquivalent: "")
        let syncAllItem = fileMenu.addItem(withTitle: "立即同步全部 WebDAV", action: #selector(menuSyncAllWebDAV), keyEquivalent: "s")
        syncAllItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(NSMenuItem.separator())

        let exportHTMLItem = fileMenu.addItem(withTitle: "导出 HTML...", action: #selector(menuExportHTML), keyEquivalent: "e")
        exportHTMLItem.keyEquivalentModifierMask = [.command, .shift]

        fileMenu.addItem(NSMenuItem.separator())

        // Recent Files Submenu
        let recentItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
        let recentSubmenu = NSMenu(title: "最近打开")
        recentItem.submenu = recentSubmenu
        self.recentFilesSubmenu = recentSubmenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 3. Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoRedoActions.undo(_:)), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: #selector(UndoRedoActions.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 4. View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")

        let toggleSidebarItem = viewMenu.addItem(withTitle: "显示/隐藏目录", action: #selector(menuToggleSidebar), keyEquivalent: "1")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]

        let toggleEditModeItem = viewMenu.addItem(withTitle: "切换编辑模式 (源码/所见即所得)", action: #selector(menuToggleEditMode), keyEquivalent: "e")
        toggleEditModeItem.keyEquivalentModifierMask = [.command, .option]

        let toggleInspectItem = viewMenu.addItem(withTitle: "切换 Webview 审查", action: #selector(menuToggleInspect), keyEquivalent: "i")
        toggleInspectItem.keyEquivalentModifierMask = [.command, .option]

        viewMenu.addItem(NSMenuItem.separator())
        let fullScreenItem = viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // 6. Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(withTitle: "\(appName) 帮助", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
        updateRecentFilesMenu()
    }

    private func observeRecentFiles() {
        appState.$recentFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRecentFilesMenu()
            }
            .store(in: &cancellables)
    }

    private func updateRecentFilesMenu() {
        guard let recentSubmenu = recentFilesSubmenu else { return }
        recentSubmenu.removeAllItems()

        if appState.recentFiles.isEmpty {
            let item = NSMenuItem(title: "无最近打开记录", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentSubmenu.addItem(item)
            return
        }

        for url in appState.recentFiles {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(handleOpenRecentItem(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            recentSubmenu.addItem(item)
        }

        recentSubmenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "清除最近文件", action: #selector(handleClearRecentFiles), keyEquivalent: "")
        clearItem.target = self
        recentSubmenu.addItem(clearItem)
    }

    @objc private func handleOpenRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        appState.openFile(url)
    }

    @objc private func handleClearRecentFiles() {
        appState.clearRecentFiles()
    }

    // MARK: - Menu Actions

    @objc private func menuNewFile() {
        appState.createNewFile()
    }

    @objc private func menuOpenFile() {
        appState.openFilePanel()
    }

    @objc private func menuOpenFolder() {
        appState.promptOpenFolder()
    }

    private var webdavDialog: WebDAVSetupDialog?

    @objc private func menuAddWebDAVFolder() {
        let dialog = WebDAVSetupDialog(state: appState)
        self.webdavDialog = dialog
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func menuSyncAllWebDAV() {
        SyncCoordinator.shared.syncAll()
    }

    @objc private func menuExportHTML() {
        appState.exportHTML()
    }

    @objc private func menuToggleSidebar() {
        appState.showSidebar.toggle()
    }

    @objc private func menuToggleEditMode() {
        appState.toggleEditMode()
    }

    @objc private func menuToggleInspect() {
        appState.isWebViewInspectEnabled.toggle()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(menuExportHTML) {
            return appState.document.url != nil
        }
        return true
    }
}
