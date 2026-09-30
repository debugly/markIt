//
//  SourceTextViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import Combine

final class SourceTextViewController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    private let document: DocumentModel
    private var cancellables = Set<AnyCancellable>()
    private var isUpdatingFromSelf = false

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    init(document: DocumentModel) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let customTextView = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        customTextView.minSize = NSSize(width: 0, height: contentSize.height)
        customTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        customTextView.isVerticallyResizable = true
        customTextView.isHorizontallyResizable = false
        customTextView.autoresizingMask = [.width]
        customTextView.textContainerInset = NSSize(width: 36, height: 24)

        // Typography and behavior
        customTextView.font = .monospacedSystemFont(ofSize: 14.5, weight: .regular)
        customTextView.textColor = .textColor
        customTextView.backgroundColor = .textBackgroundColor
        customTextView.drawsBackground = true
        customTextView.isRichText = false
        customTextView.allowsUndo = true
        customTextView.isAutomaticQuoteSubstitutionEnabled = false
        customTextView.isAutomaticDashSubstitutionEnabled = false
        customTextView.isAutomaticTextReplacementEnabled = false
        customTextView.isAutomaticSpellingCorrectionEnabled = false
        customTextView.delegate = self
        customTextView.setAccessibilityIdentifier("sourceEditor")
        customTextView.setAccessibilityLabel("源码编辑器")

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        customTextView.defaultParagraphStyle = paragraphStyle

        scrollView.documentView = customTextView
        scrollView.setAccessibilityIdentifier("sourceEditorScrollView")
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindDocument()
        syncTextFromDocument()
    }

    private func bindDocument() {
        document.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.handleExternalTextChange(newText)
            }
            .store(in: &cancellables)
    }

    private func syncTextFromDocument() {
        guard let customTextView = scrollView.documentView as? NSTextView else { return }
        customTextView.string = document.text
        customTextView.undoManager?.removeAllActions()
    }

    private func handleExternalTextChange(_ newText: String) {
        guard !isUpdatingFromSelf else { return }
        guard let customTextView = scrollView.documentView as? NSTextView else { return }
        guard customTextView.string != newText else { return }

        // Preserve selection range if still within bounds
        let oldRanges = customTextView.selectedRanges
        customTextView.string = newText

        if let firstRange = oldRanges.first as? NSRange,
           firstRange.location + firstRange.length <= newText.utf16.count {
            customTextView.selectedRanges = oldRanges
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let customTextView = notification.object as? NSTextView else { return }
        isUpdatingFromSelf = true
        document.updateText(customTextView.string)
        isUpdatingFromSelf = false
    }

    // MARK: - Undo / Redo

    @objc func undo(_ sender: Any?) {
        if let customTextView = scrollView.documentView as? NSTextView {
            customTextView.undoManager?.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if let customTextView = scrollView.documentView as? NSTextView {
            customTextView.undoManager?.redo()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(UndoRedoActions.undo(_:)) {
            if let customTextView = scrollView.documentView as? NSTextView {
                return customTextView.undoManager?.canUndo ?? false
            }
            return false
        }
        if menuItem.action == #selector(UndoRedoActions.redo(_:)) {
            if let customTextView = scrollView.documentView as? NSTextView {
                return customTextView.undoManager?.canRedo ?? false
            }
            return false
        }
        return true
    }
}
