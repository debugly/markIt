//
//  MainWindowController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState
    private let splitViewController: MainSplitViewController

    init(state: AppState) {
        self.state = state
        self.splitViewController = MainSplitViewController(state: state)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MarkIt"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        let toolbar = NSToolbar(identifier: "MainWindowToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = splitViewController
        window.minSize = NSSize(width: 800, height: 500)
        var frame = window.frame
        frame.size = NSSize(width: 1080, height: 700)
        window.setFrame(frame, display: true)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        if let window = window {
            var frame = window.frame
            frame.size = NSSize(width: 1080, height: 700)
            window.setFrame(frame, display: true)
            window.center()
            print("[MarkIt Log] Window shown with frame: \(window.frame)")
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return state.document.confirmCloseIfNeeded()
    }
}
