//
//  TopToolbarView.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine

final class TopToolbarView: NSView {
    private let state: AppState
    private let document: DocumentModel
    private var cancellables = Set<AnyCancellable>()

    private let sidebarButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "未命名")
    private let pathControl = RightClickPathControl()
    private let modeButton = NSButton()
    private let statsLabel = NSTextField(labelWithString: "")
    private let dividerBox = NSBox()
    private var sidebarButtonLeadingConstraint: NSLayoutConstraint?

    var onToggleSidebar: (() -> Void)?

    init(state: AppState, document: DocumentModel) {
        self.state = state
        self.document = document
        super.init(frame: .zero)
        setupUI()
        bindState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Background visual effect view
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .headerView
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .followsWindowActiveState
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)

        // Sidebar Toggle Button
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarButton.bezelStyle = .regularSquare
        sidebarButton.isBordered = false
        sidebarButton.focusRingType = .none
        sidebarButton.refusesFirstResponder = true
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "显示/隐藏目录")
        sidebarButton.imageScaling = .scaleProportionallyDown
        sidebarButton.toolTip = "显示/隐藏目录"
        sidebarButton.target = self
        sidebarButton.action = #selector(handleToggleSidebar)
        sidebarButton.setAccessibilityIdentifier("sidebarToggleButton")
        sidebarButton.setAccessibilityLabel("显示/隐藏目录")

        // Title Label (used when document.url == nil)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("titleLabel")

        // Path Control (used when document.url != nil)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .popUp
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: 13, weight: .medium)
        pathControl.focusRingType = .none
        pathControl.refusesFirstResponder = true
        pathControl.isEditable = false
        pathControl.setAccessibilityIdentifier("pathControl")
        pathControl.setAccessibilityLabel("文件路径")
        pathControl.target = self
        pathControl.action = #selector(handlePathControlAction(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Mode Button (WYSIWYG <-> Source)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.bezelStyle = .regularSquare
        modeButton.isBordered = false
        modeButton.focusRingType = .none
        modeButton.refusesFirstResponder = true
        modeButton.imageScaling = .scaleProportionallyDown
        modeButton.target = self
        modeButton.action = #selector(handleToggleMode)
        modeButton.setAccessibilityIdentifier("editModeButton")
        modeButton.setAccessibilityLabel("切换编辑模式")

        // Stats Label
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .systemFont(ofSize: 13)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.setAccessibilityIdentifier("statsLabel")

        // Bottom Divider
        dividerBox.translatesAutoresizingMaskIntoConstraints = false
        dividerBox.boxType = .separator

        addSubview(sidebarButton)
        addSubview(titleLabel)
        addSubview(pathControl)
        addSubview(modeButton)
        addSubview(statsLabel)
        addSubview(dividerBox)

        let leadingConstraint = sidebarButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: state.showSidebar ? 14 : 86)
        sidebarButtonLeadingConstraint = leadingConstraint

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            leadingConstraint,
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 24),
            sidebarButton.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -16),

            pathControl.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 12),
            pathControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: modeButton.leadingAnchor, constant: -16),

            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            modeButton.trailingAnchor.constraint(equalTo: statsLabel.leadingAnchor, constant: -8),
            modeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 24),
            modeButton.heightAnchor.constraint(equalToConstant: 24),

            dividerBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            dividerBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerBox.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerBox.heightAnchor.constraint(equalToConstant: 1)
        ])

        updateUI()
    }

    private func bindState() {
        state.$showSidebar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                self.sidebarButtonLeadingConstraint?.constant = show ? 14 : 86
                self.needsLayout = true
            }
            .store(in: &cancellables)

        document.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateUI() }
            .store(in: &cancellables)

        document.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStats() }
            .store(in: &cancellables)

        document.$html
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStats() }
            .store(in: &cancellables)

        document.$fileType
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateUI() }
            .store(in: &cancellables)

        state.$editMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateModeButton() }
            .store(in: &cancellables)
    }

    private func updateUI() {
        if let url = document.url {
            pathControl.url = url
            pathControl.isHidden = false
            titleLabel.isHidden = true
            modeButton.isHidden = (document.fileType != .markdown && document.fileType != .html)
            statsLabel.isHidden = false
        } else {
            titleLabel.stringValue = "未命名"
            titleLabel.isHidden = false
            pathControl.isHidden = true
            modeButton.isHidden = true
            statsLabel.isHidden = true
        }
        updateModeButton()
        updateStats()
    }

    private func updateModeButton() {
        guard document.fileType == .markdown || document.fileType == .html else {
            modeButton.isHidden = true
            return
        }
        modeButton.isHidden = false
        if document.fileType == .html {
            if state.editMode == .wysiwyg {
                modeButton.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
                modeButton.toolTip = "网页预览模式"
            } else {
                modeButton.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                modeButton.toolTip = "源码编辑模式"
            }
        } else {
            if state.editMode == .wysiwyg {
                modeButton.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
                modeButton.toolTip = "所见即所得模式"
            } else {
                modeButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                modeButton.toolTip = "文本编辑模式"
            }
        }
    }

    private func updateStats() {
        guard let url = document.url else {
            statsLabel.stringValue = ""
            return
        }
        switch document.fileType {
        case .markdown, .text, .html:
            let text = document.text
            let lines = max(text.split(whereSeparator: \.isNewline).count, text.isEmpty ? 0 : 1)
            let characters = document.plainText.filter { !$0.isWhitespace && !$0.isNewline }.count
            statsLabel.stringValue = "\(lines) 行 · \(characters) 字"
        case .image, .other:
            let sizeStr = SupportedFileType.formattedFileSize(for: url)
            statsLabel.stringValue = sizeStr
        }
    }

    @objc private func handleToggleSidebar() {
        onToggleSidebar?()
    }

    @objc private func handleToggleMode() {
        state.toggleEditMode()
    }

    @objc private func handlePathControlAction(_ sender: NSPathControl) {
        let url = sender.clickedPathItem?.url ?? sender.url
        guard let url = url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private final class RightClickPathControl: NSPathControl {
    override func mouseDown(with event: NSEvent) {
        // Suppress default left click action or let it pop up
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        performClick(nil)
    }
}
