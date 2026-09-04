//
//  EditorViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine

final class EditorViewController: NSViewController, NSMenuItemValidation {
    private let state: AppState
    private let document: DocumentModel
    private var cancellables = Set<AnyCancellable>()

    private let placeholderView = PlaceholderView(
        title: "无打开的文件",
        systemImageName: "doc.text",
        message: "在左侧边栏选择或新建 Markdown 文件"
    )
    private lazy var wysiwygVC = WYSIWYGWebViewController(document: document, state: state)
    private lazy var sourceVC = SourceTextViewController(document: document)
    private lazy var imagePreviewVC = ImagePreviewViewController()
    private lazy var htmlPreviewVC = HTMLPreviewViewController()
    private lazy var externalOpenVC = ExternalOpenViewController()

    private var activeMode: AppState.EditMode?

    init(state: AppState, document: DocumentModel) {
        self.state = state
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChildControllers()
        bindState()
        updateVisibility()
    }

    private func setupChildControllers() {
        // Add children
        addChild(wysiwygVC)
        addChild(sourceVC)
        addChild(imagePreviewVC)
        addChild(htmlPreviewVC)
        addChild(externalOpenVC)

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        wysiwygVC.view.translatesAutoresizingMaskIntoConstraints = false
        sourceVC.view.translatesAutoresizingMaskIntoConstraints = false
        imagePreviewVC.view.translatesAutoresizingMaskIntoConstraints = false
        htmlPreviewVC.view.translatesAutoresizingMaskIntoConstraints = false
        externalOpenVC.view.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(placeholderView)
        view.addSubview(wysiwygVC.view)
        view.addSubview(sourceVC.view)
        view.addSubview(imagePreviewVC.view)
        view.addSubview(htmlPreviewVC.view)
        view.addSubview(externalOpenVC.view)

        NSLayoutConstraint.activate([
            placeholderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: view.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            wysiwygVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wysiwygVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wysiwygVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            wysiwygVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            sourceVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sourceVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sourceVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            sourceVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imagePreviewVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imagePreviewVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imagePreviewVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            imagePreviewVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            htmlPreviewVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            htmlPreviewVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            htmlPreviewVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            htmlPreviewVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            externalOpenVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            externalOpenVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            externalOpenVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            externalOpenVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func bindState() {
        state.$editMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        document.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        document.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        document.$fileType
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
    }

    private func updateVisibility() {
        guard let url = document.url else {
            imagePreviewVC.clear()
            htmlPreviewVC.clear()
            if !document.text.isEmpty {
                showMarkdownEditor()
            } else {
                showPlaceholder()
            }
            return
        }

        placeholderView.isHidden = true

        // 切换到非图片文件时，立即清理图片预览，避免切回图片时短暂闪烁上一张图片
        if document.fileType != .image {
            imagePreviewVC.clear()
        }
        if document.fileType != .html {
            htmlPreviewVC.clear()
        }

        switch document.fileType {
        case .markdown:
            imagePreviewVC.view.isHidden = true
            htmlPreviewVC.view.isHidden = true
            externalOpenVC.view.isHidden = true
            showMarkdownEditor()

        case .html:
            imagePreviewVC.view.isHidden = true
            externalOpenVC.view.isHidden = true
            wysiwygVC.view.isHidden = true

            switch state.editMode {
            case .wysiwyg:
                // 网页预览模式：直接使用 webview 加载，不增加额外 js 和样式
                sourceVC.view.isHidden = true
                htmlPreviewVC.view.isHidden = false
                htmlPreviewVC.previewHTML(content: document.text, baseURL: url.deletingLastPathComponent())
            case .source:
                // 源码编辑模式
                htmlPreviewVC.view.isHidden = true
                sourceVC.view.isHidden = false
            }

        case .text:
            imagePreviewVC.view.isHidden = true
            htmlPreviewVC.view.isHidden = true
            externalOpenVC.view.isHidden = true
            wysiwygVC.view.isHidden = true
            sourceVC.view.isHidden = false

        case .image:
            wysiwygVC.view.isHidden = true
            sourceVC.view.isHidden = true
            htmlPreviewVC.view.isHidden = true
            externalOpenVC.view.isHidden = true
            imagePreviewVC.view.isHidden = false
            imagePreviewVC.previewImage(at: url)

        case .other:
            wysiwygVC.view.isHidden = true
            sourceVC.view.isHidden = true
            imagePreviewVC.view.isHidden = true
            htmlPreviewVC.view.isHidden = true
            externalOpenVC.view.isHidden = false
            externalOpenVC.configure(with: url)
        }
    }

    private func showPlaceholder() {
        imagePreviewVC.clear()
        htmlPreviewVC.clear()
        placeholderView.isHidden = false
        wysiwygVC.view.isHidden = true
        sourceVC.view.isHidden = true
        imagePreviewVC.view.isHidden = true
        htmlPreviewVC.view.isHidden = true
        externalOpenVC.view.isHidden = true
    }

    private func showMarkdownEditor() {
        placeholderView.isHidden = true
        imagePreviewVC.view.isHidden = true
        htmlPreviewVC.view.isHidden = true
        externalOpenVC.view.isHidden = true

        let targetMode = state.editMode
        if targetMode != activeMode {
            if targetMode == .wysiwyg {
                wysiwygVC.syncContentFromDocument(forceReload: true)
            }
            activeMode = targetMode
        }

        switch targetMode {
        case .wysiwyg:
            wysiwygVC.view.isHidden = false
            sourceVC.view.isHidden = true
        case .source:
            wysiwygVC.view.isHidden = true
            sourceVC.view.isHidden = false
        }
    }

    // MARK: - Undo / Redo

    @objc func undo(_ sender: Any?) {
        guard document.fileType == .markdown || document.fileType == .text || document.fileType == .html else { return }
        if document.fileType == .text || document.fileType == .html {
            sourceVC.undo(sender)
        } else {
            switch state.editMode {
            case .wysiwyg:
                wysiwygVC.undo(sender)
            case .source:
                sourceVC.undo(sender)
            }
        }
    }

    @objc func redo(_ sender: Any?) {
        guard document.fileType == .markdown || document.fileType == .text || document.fileType == .html else { return }
        if document.fileType == .text || document.fileType == .html {
            sourceVC.redo(sender)
        } else {
            switch state.editMode {
            case .wysiwyg:
                wysiwygVC.redo(sender)
            case .source:
                sourceVC.redo(sender)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(UndoRedoActions.undo(_:)) || menuItem.action == #selector(UndoRedoActions.redo(_:)) {
            return true
        }
        return true
    }
}
