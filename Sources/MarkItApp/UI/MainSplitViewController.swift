//
//  MainSplitViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine

final class MainSplitViewController: NSSplitViewController {
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    private lazy var sidebarVC = SidebarViewController(state: state)
    private lazy var editorContainerVC = EditorContainerViewController(state: state, document: state.document)

    private var sidebarSplitItem: NSSplitViewItem!
    private var editorSplitItem: NSSplitViewItem!

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarSplitItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarSplitItem.minimumThickness = 220
        sidebarSplitItem.maximumThickness = 450
        sidebarSplitItem.canCollapse = true
        sidebarSplitItem.holdingPriority = .defaultLow + 1

        editorSplitItem = NSSplitViewItem(viewController: editorContainerVC)
        editorSplitItem.holdingPriority = .defaultLow

        addSplitViewItem(sidebarSplitItem)
        addSplitViewItem(editorSplitItem)

        bindState()
    }

    private func bindState() {
        state.$showSidebar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                if self.sidebarSplitItem.isCollapsed != !show {
                    self.sidebarSplitItem.animator().isCollapsed = !show
                }
            }
            .store(in: &cancellables)
    }

    func toggleSidebar() {
        state.showSidebar.toggle()
    }
}
