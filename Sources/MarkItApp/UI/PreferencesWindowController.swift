//
//  PreferencesWindowController.swift
//  Markit
//

import AppKit

// MARK: - PreferencesWindowController

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState
    /// 窗口关闭后回调，用于让持有者把引用置 nil
    var onClose: (() -> Void)?

    init(state: AppState) {
        self.state = state

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        super.init(window: window)

        window.delegate = self
        window.contentViewController = PreferencesViewController(state: state)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - PreferencesViewController

private final class PreferencesViewController: NSViewController {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        self.view = container

        // --- Toolbar (tab bar) ---
        let toolbar = NSSegmentedControl(
            labels: ["通用", "外观"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleTabChange(_:))
        )
        toolbar.selectedSegment = 0
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // --- Content area ---
        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true

        container.addSubview(toolbar)
        container.addSubview(contentHost)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            toolbar.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            contentHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.contentHost = contentHost
        self.tabControl = toolbar

        showTab(0)
    }

    private var contentHost: NSView!
    private var tabControl: NSSegmentedControl!

    @objc private func handleTabChange(_ sender: NSSegmentedControl) {
        showTab(sender.selectedSegment)
    }

    private func showTab(_ index: Int) {
        // Remove existing child view controllers
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        let vc: NSViewController
        switch index {
        case 0:
            vc = GeneralPrefsView(state: state)
        default:
            vc = AppearancePrefsView(state: state)
        }

        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
    }
}

// MARK: - General Tab

private final class GeneralPrefsView: NSViewController {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        self.view = container

        // WebView inspect toggle
        let inspectCheck = NSButton(checkboxWithTitle: "启用 WebView 审查工具", target: self, action: #selector(handleInspectToggle(_:)))
        inspectCheck.translatesAutoresizingMaskIntoConstraints = false
        inspectCheck.state = state.isWebViewInspectEnabled ? .on : .off

        container.addSubview(inspectCheck)

        NSLayoutConstraint.activate([
            inspectCheck.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            inspectCheck.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32)
        ])
    }

    @objc private func handleInspectToggle(_ sender: NSButton) {
        state.isWebViewInspectEnabled = (sender.state == .on)
    }
}

// MARK: - Appearance Tab (style picker)

private final class AppearancePrefsView: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let state: AppState
    private var availableStyles: [String] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        self.view = container

        // Section label
        let sectionLabel = NSTextField(labelWithString: "预览渲染样式")
        sectionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table inside scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("StyleColumn"))
        column.title = "样式"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .controlBackgroundColor
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.action = #selector(handleRowClick)

        scrollView.documentView = tableView

        container.addSubview(sectionLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            sectionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),

            scrollView.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadStyles()
    }

    private func loadStyles() {
        guard let url = Bundle.main.url(forResource: "GitHub", withExtension: "css") else {
            availableStyles = ["无", "GitHub.css"]
            tableView.reloadData()
            selectCurrentStyle()
            return
        }
        let directory = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            availableStyles = ["无"] + contents.filter { $0.hasSuffix(".css") }.sorted()
        } else {
            availableStyles = ["无", "GitHub.css"]
        }
        tableView.reloadData()
        selectCurrentStyle()
    }

    private func selectCurrentStyle() {
        let current = state.previewStyle
        if let idx = availableStyles.firstIndex(of: current) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { availableStyles.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("StyleCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            let c = NSTableCellView()
            c.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 13)
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            cell = c
        }
        cell.textField?.stringValue = availableStyles[row]
        return cell
    }

    @objc private func handleRowClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < availableStyles.count else { return }
        state.setPreviewStyle(availableStyles[row])
    }
}
