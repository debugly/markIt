import SwiftUI
import AppKit

private enum FormattingAction {
    case bold
    case italic
    case underline
    case inlineCode
    case strikethrough
    case link
    case heading1
    case heading2
    case heading3
    case quote
    case bulletList
    case orderedList
    case taskList
    case codeBlock
}

private struct FormattingToolbarView: View {
    let onAction: (FormattingAction) -> Void
    private let columns = [
        GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            iconToolbarButton(systemName: "bold", title: "加粗", action: .bold)
            iconToolbarButton(systemName: "italic", title: "斜体", action: .italic)
            iconToolbarButton(systemName: "underline", title: "下划线", action: .underline)
            iconToolbarButton(systemName: "strikethrough", title: "删除线", action: .strikethrough)
            iconToolbarButton(systemName: "chevron.left.forwardslash.chevron.right", title: "行内代码", action: .inlineCode)
            iconToolbarButton(systemName: "link", title: "链接", action: .link)
            textToolbarButton("H1", title: "一级标题", action: .heading1)
            textToolbarButton("H2", title: "二级标题", action: .heading2)
            textToolbarButton("H3", title: "三级标题", action: .heading3)
            iconToolbarButton(systemName: "text.quote", title: "引用", action: .quote)
            iconToolbarButton(systemName: "list.bullet", title: "无序列表", action: .bulletList)
            iconToolbarButton(systemName: "list.number", title: "有序列表", action: .orderedList)
            iconToolbarButton(systemName: "checklist", title: "任务列表", action: .taskList)
            iconToolbarButton(systemName: "curlybraces", title: "代码块", action: .codeBlock)
        }
        .padding(10)
    }

    private func iconToolbarButton(systemName: String, title: String, action: FormattingAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(title)
        .accessibilityLabel(Text(title))
    }

    private func textToolbarButton(_ text: String, title: String, action: FormattingAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(title)
        .accessibilityLabel(Text(title))
    }

    private var buttonBackground: some View {
        Color(nsColor: .controlBackgroundColor)
    }
}

struct EditorView: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            MarkdownEditorTextView(text: Binding(
                get: { document.text },
                set: { document.updateText($0) }
            ))
            .background(Color(red: 255 / 255.0, green: 252 / 255.0, blue: 234 / 255.0))
        }
        .frame(minWidth: 500, idealWidth: 500)
    }
}

private struct MarkdownEditorTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(
            calibratedRed: 255 / 255.0,
            green: 252 / 255.0,
            blue: 234 / 255.0,
            alpha: 1
        )

        let textView = MarkdownNSTextView()
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = scrollView.backgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: Typography.editorFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: .max)
        textView.textContainer?.lineFragmentPadding = 0
        textView.defaultParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            return style
        }()
        textView.onBoldShortcut = { context.coordinator.wrapSelection(using: $0, with: "**") }
        textView.onItalicShortcut = { context.coordinator.wrapSelection(using: $0, with: "*") }
        textView.onInlineCodeShortcut = { context.coordinator.wrapSelection(using: $0, with: "`") }
        textView.onCodeBlockShortcut = { context.coordinator.wrapSelectionLinesInCodeBlock(using: $0) }
        textView.onTableShortcut = { context.coordinator.insertTable(using: $0) }
        textView.onFormattingAction = { textView, action in
            switch action {
            case .bold:
                context.coordinator.wrapSelection(using: textView, with: "**")
            case .italic:
                context.coordinator.wrapSelection(using: textView, with: "*")
            case .underline:
                context.coordinator.wrapSelection(using: textView, prefix: "<u>", suffix: "</u>")
            case .inlineCode:
                context.coordinator.wrapSelection(using: textView, with: "`")
            case .strikethrough:
                context.coordinator.wrapSelection(using: textView, with: "~~")
            case .link:
                context.coordinator.insertLink(using: textView)
            case .heading1:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("# ", to: line)
                }
            case .heading2:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("## ", to: line)
                }
            case .heading3:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("### ", to: line)
                }
            case .quote:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("> ", to: line)
                }
            case .bulletList:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("- ", to: line)
                }
            case .orderedList:
                context.coordinator.prefixSelectedLines(using: textView) { index, line in
                    context.coordinator.prepending("\(index + 1). ", to: line)
                }
            case .taskList:
                context.coordinator.prefixSelectedLines(using: textView) { _, line in
                    context.coordinator.prepending("- [ ] ", to: line)
                }
            case .codeBlock:
                context.coordinator.wrapSelectionLinesInCodeBlock(using: textView)
            }
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        guard textView.string != text else { return }

        context.coordinator.isUpdatingFromSwiftUI = true
        let currentSelection = textView.selectedRange()
        textView.string = text
        textView.setSelectedRange(clamp(range: currentSelection, to: textView.string))
        context.coordinator.isUpdatingFromSwiftUI = false
    }

    private func clamp(range: NSRange, to text: String) -> NSRange {
        let maxLocation = (text as NSString).length
        let location = min(range.location, maxLocation)
        let length = min(range.length, maxLocation - location)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var isUpdatingFromSwiftUI = false
        weak var textView: MarkdownNSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard isUpdatingFromSwiftUI == false,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.handleSelectionChange()
        }

        func wrapSelection(using textView: NSTextView, with marker: String) {
            wrapSelection(using: textView, prefix: marker, suffix: marker)
        }

        func wrapSelection(using textView: NSTextView, prefix: String, suffix: String) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let replacement: String
            let newSelection: NSRange

            if selection.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selection)
                replacement = "\(prefix)\(selectedText)\(suffix)"
                newSelection = NSRange(location: selection.location + prefix.count, length: selection.length)
            } else {
                replacement = "\(prefix)\(suffix)"
                newSelection = NSRange(location: selection.location + prefix.count, length: 0)
            }

            guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: selection, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
        }

        func insertLink(using textView: NSTextView) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let selectedText = selection.length > 0
                ? (textView.string as NSString).substring(with: selection)
                : "链接文字"
            let replacement = "[\(selectedText)](url)"
            let newSelection = NSRange(
                location: selection.location + 1 + selectedText.count + 2,
                length: 3
            )

            guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: selection, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
        }

        func prefixSelectedLines(
            using textView: NSTextView,
            transform: (_ index: Int, _ line: String) -> String
        ) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: selection)
            let selectedLines = nsText.substring(with: lineRange)
            let hasTrailingNewline = selectedLines.hasSuffix("\n")
            var lines = selectedLines.components(separatedBy: "\n")

            if hasTrailingNewline, lines.isEmpty == false {
                lines.removeLast()
            }

            let transformed = lines.enumerated().map { index, line in
                transform(index, line)
            }.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")

            guard textView.shouldChangeText(in: lineRange, replacementString: transformed) else { return }
            textView.textStorage?.replaceCharacters(in: lineRange, with: transformed)
            textView.didChangeText()

            let newSelection = NSRange(location: lineRange.location, length: (transformed as NSString).length)
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
        }

        func prepending(_ prefix: String, to line: String) -> String {
            if line.isEmpty {
                return prefix
            }
            return prefix + line
        }

        func insertTable(using textView: NSTextView) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let table = """
            |       |       |       |
            | ----- | ----- | ----- |
            |       |       |       |
            |       |       |       |
            |       |       |       |
            """

            guard textView.shouldChangeText(in: selection, replacementString: table) else { return }
            textView.textStorage?.replaceCharacters(in: selection, with: table)
            textView.didChangeText()

            let newSelection = firstEditableCellRange(in: table, insertionLocation: selection.location)
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
        }

        private func firstEditableCellRange(in table: String, insertionLocation: Int) -> NSRange {
            let nsTable = table as NSString
            let firstLineRange = nsTable.lineRange(for: NSRange(location: 0, length: 0))
            let firstLine = nsTable.substring(with: firstLineRange).trimmingCharacters(in: .newlines)
            guard let firstPipe = firstLine.firstIndex(of: "|"),
                  let secondPipe = firstLine[firstLine.index(after: firstPipe)...].firstIndex(of: "|") else {
                return NSRange(location: insertionLocation, length: 0)
            }

            let contentStart = firstLine.index(after: firstPipe)
            let rawCell = String(firstLine[contentStart..<secondPipe])
            let trimmedCell = rawCell.trimmingCharacters(in: .whitespaces)
            let leadingWhitespaceCount = rawCell.prefix { $0.isWhitespace }.count
            let firstCellStartOffset = firstLine.distance(from: firstLine.startIndex, to: contentStart) + leadingWhitespaceCount

            return NSRange(
                location: insertionLocation + firstCellStartOffset,
                length: trimmedCell.count
            )
        }

        func wrapSelectionLinesInCodeBlock(using textView: NSTextView) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: selection)
            let selectedLines = nsText.substring(with: lineRange)
            let contentNeedsTrailingNewline = selectedLines.hasSuffix("\n") == false
            let replacement = contentNeedsTrailingNewline
                ? "```\n\(selectedLines)\n```"
                : "```\n\(selectedLines)```"

            guard textView.shouldChangeText(in: lineRange, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: lineRange, with: replacement)
            textView.didChangeText()

            let newSelection = NSRange(location: lineRange.location + 4, length: selectedLines.count)
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
        }
    }
}

private final class MarkdownNSTextView: NSTextView {
    var onBoldShortcut: ((NSTextView) -> Void)?
    var onItalicShortcut: ((NSTextView) -> Void)?
    var onInlineCodeShortcut: ((NSTextView) -> Void)?
    var onCodeBlockShortcut: ((NSTextView) -> Void)?
    var onTableShortcut: ((NSTextView) -> Void)?
    var onFormattingAction: ((NSTextView, FormattingAction) -> Void)?

    private var selectionAtMouseDown = NSRange(location: NSNotFound, length: 0)
    private var popoverSelection = NSRange(location: NSNotFound, length: 0)
    private var pendingSelectionToShow = NSRange(location: NSNotFound, length: 0)
    private lazy var formattingPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 290, height: 110)
        popover.contentViewController = NSHostingController(
            rootView: FormattingToolbarView { [weak self] action in
                self?.applyFormattingAction(action)
            }
        )
        return popover
    }()

    override func keyDown(with event: NSEvent) {
        closeFormattingToolbar()

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                onBoldShortcut?(self)
                return
            case "i":
                onItalicShortcut?(self)
                return
            case "k":
                onInlineCodeShortcut?(self)
                return
            case "t":
                onTableShortcut?(self)
                return
            default:
                break
            }
        } else if modifiers == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCodeBlockShortcut?(self)
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        closeFormattingToolbar()
        selectionAtMouseDown = selectedRange()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        closeFormattingToolbar()
        return super.resignFirstResponder()
    }

    private func showFormattingToolbar(for selection: NSRange) {
        guard let window else { return }

        popoverSelection = selection
        if formattingPopover.isShown {
            formattingPopover.close()
        }

        let screenRect = firstRect(forCharacterRange: selection, actualRange: nil)
        let anchorInWindow = window.convertFromScreen(screenRect)
        let anchorInView = convert(anchorInWindow, from: nil)
        formattingPopover.show(relativeTo: anchorInView, of: self, preferredEdge: .maxY)
    }

    private func closeFormattingToolbar() {
        if formattingPopover.isShown {
            formattingPopover.close()
        }
        popoverSelection = NSRange(location: NSNotFound, length: 0)
        pendingSelectionToShow = NSRange(location: NSNotFound, length: 0)
    }

    private func applyFormattingAction(_ action: FormattingAction) {
        window?.makeFirstResponder(self)

        if popoverSelection.location != NSNotFound {
            setSelectedRange(popoverSelection)
        }

        onFormattingAction?(self, action)
        closeFormattingToolbar()
    }

    func handleSelectionChange() {
        let selection = selectedRange()

        guard window?.firstResponder === self,
              selection.location != NSNotFound,
              selection.length > 0,
              selection != selectionAtMouseDown else {
            if selection.length == 0 {
                closeFormattingToolbar()
            }
            return
        }

        pendingSelectionToShow = selection
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingSelectionToShow == self.selectedRange() else { return }
            self.showFormattingToolbar(for: self.pendingSelectionToShow)
        }
    }
}
