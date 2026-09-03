//
//  StylePopoverViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit

final class StylePopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let state: AppState
    private var availableStyles: [String] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    var onStyleSelected: ((String) -> Void)?

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))

        let titleLabel = NSTextField(labelWithString: "选择渲染样式")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("StyleColumn"))
        column.title = "Style"
        column.width = 220
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.action = #selector(handleRowClick)

        scrollView.documentView = tableView

        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadStyles()
    }

    private func loadStyles() {
        guard let url = Bundle.main.url(forResource: "GitHub", withExtension: "css") else {
            availableStyles = ["无", "GitHub.css"]
            tableView.reloadData()
            return
        }
        let directory = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let styles = contents
                .filter { $0.hasSuffix(".css") }
                .sorted()
            availableStyles = ["无"] + styles
        } else {
            availableStyles = ["无", "GitHub.css"]
        }
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return availableStyles.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let style = availableStyles[row]
        let isSelected = (style == state.previewStyle)

        let cellIdentifier = NSUserInterfaceItemIdentifier("StyleCell")
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? StyleTableCellView
        if cellView == nil {
            cellView = StyleTableCellView()
            cellView?.identifier = cellIdentifier
        }

        cellView?.configure(styleName: style, isSelected: isSelected)
        return cellView
    }

    @objc private func handleRowClick() {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0 && clickedRow < availableStyles.count else { return }
        let selected = availableStyles[clickedRow]
        state.setPreviewStyle(selected)
        onStyleSelected?(selected)
        tableView.reloadData()
    }
}

private final class StyleTableCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkmarkImageView = NSImageView()

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
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            checkmarkImageView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        }
        checkmarkImageView.contentTintColor = .controlAccentColor

        addSubview(titleLabel)
        addSubview(checkmarkImageView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkImageView.leadingAnchor, constant: -8),

            checkmarkImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkmarkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkImageView.widthAnchor.constraint(equalToConstant: 14),
            checkmarkImageView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func configure(styleName: String, isSelected: Bool) {
        titleLabel.stringValue = styleName
        titleLabel.textColor = isSelected ? .controlAccentColor : .labelColor
        titleLabel.font = isSelected ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        checkmarkImageView.isHidden = !isSelected
    }
}
