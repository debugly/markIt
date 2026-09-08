//
//  EditorContainerViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit

final class EditorContainerViewController: NSViewController {
    private let state: AppState
    private let document: DocumentModel

    private lazy var toolbarView = TopToolbarView(state: state, document: document)
    private lazy var editorVC = EditorViewController(state: state, document: document)

    init(state: AppState, document: DocumentModel) {
        self.state = state
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = EditorContainerBackgroundView()
        container.autoresizingMask = [.width, .height]

        toolbarView.onToggleSidebar = { [weak self] in
            guard let self = self else { return }
            self.state.showSidebar.toggle()
        }

        addChild(editorVC)
        editorVC.view.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbarView)
        container.addSubview(editorVC.view)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: container.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 52),

            editorVC.view.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            editorVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
    }
}

private final class EditorContainerBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
