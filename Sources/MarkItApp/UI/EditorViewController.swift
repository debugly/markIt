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

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        wysiwygVC.view.translatesAutoresizingMaskIntoConstraints = false
        sourceVC.view.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(placeholderView)
        view.addSubview(wysiwygVC.view)
        view.addSubview(sourceVC.view)

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
            sourceVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
    }

    private func updateVisibility() {
        let hasDocument = (document.url != nil) || !document.text.isEmpty

        if !hasDocument {
            placeholderView.isHidden = false
            wysiwygVC.view.isHidden = true
            sourceVC.view.isHidden = true
            return
        }

        placeholderView.isHidden = true

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
        switch state.editMode {
        case .wysiwyg:
            wysiwygVC.undo(sender)
        case .source:
            sourceVC.undo(sender)
        }
    }

    @objc func redo(_ sender: Any?) {
        switch state.editMode {
        case .wysiwyg:
            wysiwygVC.redo(sender)
        case .source:
            sourceVC.redo(sender)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(UndoRedoActions.undo(_:)) || menuItem.action == #selector(UndoRedoActions.redo(_:)) {
            return true
        }
        return true
    }
}
