import SwiftUI
import AppKit

private enum FormattingGlyph {
    case icon(String)
    case text(String)
}

private enum FormattingAction: CaseIterable, Hashable {
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

    static let allCases: [FormattingAction] = [
        .bold,
        .italic,
        .underline,
        .strikethrough,
        .inlineCode,
        .link,
        .heading1,
        .heading2,
        .heading3,
        .quote,
        .bulletList,
        .orderedList,
        .taskList,
        .codeBlock,
    ]

    var title: String {
        switch self {
        case .bold: return "加粗"
        case .italic: return "斜体"
        case .underline: return "下划线"
        case .inlineCode: return "行内代码"
        case .strikethrough: return "删除线"
        case .link: return "链接"
        case .heading1: return "一级标题"
        case .heading2: return "二级标题"
        case .heading3: return "三级标题"
        case .quote: return "引用"
        case .bulletList: return "无序列表"
        case .orderedList: return "有序列表"
        case .taskList: return "任务列表"
        case .codeBlock: return "代码块"
        }
    }

    var glyph: FormattingGlyph {
        switch self {
        case .bold: return .icon("bold")
        case .italic: return .icon("italic")
        case .underline: return .icon("underline")
        case .inlineCode: return .icon("chevron.left.forwardslash.chevron.right")
        case .strikethrough: return .icon("strikethrough")
        case .link: return .icon("link")
        case .heading1: return .text("H1")
        case .heading2: return .text("H2")
        case .heading3: return .text("H3")
        case .quote: return .icon("text.quote")
        case .bulletList: return .icon("list.bullet")
        case .orderedList: return .icon("list.number")
        case .taskList: return .icon("checklist")
        case .codeBlock: return .icon("curlybraces")
        }
    }
}

private struct FormattingGlyphView: View {
    let action: FormattingAction
    let size: CGFloat

    var body: some View {
        Group {
            switch action.glyph {
            case .icon(let systemName):
                Image(systemName: systemName)
                    .font(.system(size: size * 0.43, weight: .semibold))
            case .text(let text):
                Text(text)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct FormattingToolbarView: View {
    let onAction: (FormattingAction) -> Void
    private let columns = [
        GridItem(.adaptive(minimum: 30, maximum: 30), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FormattingAction.allCases, id: \.self) { action in
                toolbarButton(for: action)
            }
        }
        .padding(10)
    }

    private func toolbarButton(for action: FormattingAction) -> some View {
        Button {
            onAction(action)
        } label: {
            FormattingGlyphView(action: action, size: 30)
        }
        .buttonStyle(.plain)
        .background(buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(action.title)
        .accessibilityLabel(Text(action.title))
    }

    private var buttonBackground: some View {
        Color(nsColor: .controlBackgroundColor)
    }
}

private struct SlashCommandListView: View {
    @ObservedObject var model: SlashCommandMenuModel
    let onAction: (FormattingAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(FormattingAction.allCases.enumerated()), id: \.element) { index, action in
                    Button {
                        onAction(action)
                    } label: {
                        HStack(spacing: 10) {
                            FormattingGlyphView(action: action, size: 22)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            Text(action.title)
                                .font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index == model.highlightedIndex ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(action.title))
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        )
        .frame(width: 220, height: 280)
    }
}

private final class SlashCommandMenuModel: ObservableObject {
    @Published var highlightedIndex = 0

    var highlightedAction: FormattingAction {
        let actions = FormattingAction.allCases
        guard actions.isEmpty == false else { return .bold }
        return actions[max(0, min(highlightedIndex, actions.count - 1))]
    }

    func reset() {
        highlightedIndex = 0
    }

    func moveUp() {
        guard FormattingAction.allCases.isEmpty == false else { return }
        highlightedIndex = max(0, highlightedIndex - 1)
    }

    func moveDown() {
        let maxIndex = FormattingAction.allCases.count - 1
        guard maxIndex >= 0 else { return }
        highlightedIndex = min(maxIndex, highlightedIndex + 1)
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
        textView.actionCoordinator = context.coordinator
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
        context.coordinator.isUpdatingSelectionProgrammatically = true
        textView.setSelectedRange(clamp(range: currentSelection, to: textView.string))
        DispatchQueue.main.async {
            context.coordinator.isUpdatingSelectionProgrammatically = false
        }
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
        var isUpdatingSelectionProgrammatically = false
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
            guard isUpdatingSelectionProgrammatically == false else { return }
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
            setSelection(newSelection, in: textView)
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
            setSelection(newSelection, in: textView)
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
            setSelection(newSelection, in: textView)
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
            setSelection(newSelection, in: textView)
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
            setSelection(newSelection, in: textView)
            textView.scrollRangeToVisible(newSelection)
        }

        private func setSelection(_ range: NSRange, in textView: NSTextView) {
            isUpdatingSelectionProgrammatically = true
            textView.setSelectedRange(range)
            DispatchQueue.main.async { [weak self] in
                self?.isUpdatingSelectionProgrammatically = false
            }
        }

        func apply(_ action: FormattingAction, using textView: NSTextView) {
            switch action {
            case .bold:
                wrapSelection(using: textView, with: "**")
            case .italic:
                wrapSelection(using: textView, with: "*")
            case .underline:
                wrapSelection(using: textView, prefix: "<u>", suffix: "</u>")
            case .inlineCode:
                wrapSelection(using: textView, with: "`")
            case .strikethrough:
                wrapSelection(using: textView, with: "~~")
            case .link:
                insertLink(using: textView)
            case .heading1:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("# ", to: line)
                }
            case .heading2:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("## ", to: line)
                }
            case .heading3:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("### ", to: line)
                }
            case .quote:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("> ", to: line)
                }
            case .bulletList:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("- ", to: line)
                }
            case .orderedList:
                prefixSelectedLines(using: textView) { index, line in
                    self.prepending("\(index + 1). ", to: line)
                }
            case .taskList:
                prefixSelectedLines(using: textView) { _, line in
                    self.prepending("- [ ] ", to: line)
                }
            case .codeBlock:
                wrapSelectionLinesInCodeBlock(using: textView)
            }
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
    weak var actionCoordinator: MarkdownEditorTextView.Coordinator?

    private var selectionAtMouseDown = NSRange(location: NSNotFound, length: 0)
    private var popoverSelection = NSRange(location: NSNotFound, length: 0)
    private var pendingSelectionToShow = NSRange(location: NSNotFound, length: 0)
    private var commandTriggerRange = NSRange(location: NSNotFound, length: 0)
    private var commandTriggerText: String?
    private let slashCommandModel = SlashCommandMenuModel()
    private var slashCommandHostView: NSHostingView<SlashCommandListView>?
    private var localKeyMonitor: Any?
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEscapeIfNeeded(for: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)),
           closeFloatingUIIfNeeded() {
            return
        }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        if handleEscapeIfNeeded(for: event) {
            return
        }

        closeFormattingToolbar()

        if slashCommandHostView != nil {
            switch Int(event.keyCode) {
            case 125:
                slashCommandModel.moveDown()
                return
            case 126:
                slashCommandModel.moveUp()
                return
            case 36, 76:
                applySlashCommand(slashCommandModel.highlightedAction)
                return
            default:
                break
            }
        }

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

        let insertedText = event.characters ?? ""
        let shouldTriggerWithSlash = modifiers.isEmpty && insertedText == "\\"
        let shouldTriggerWithControlChineseComma =
            modifiers == [.control] &&
            (insertedText == "、" || event.charactersIgnoringModifiers == "、")

        if (shouldTriggerWithSlash || shouldTriggerWithControlChineseComma),
           selectedRange().length == 0 {
            super.keyDown(with: event)
            let triggerText = insertedText.isEmpty
                ? (shouldTriggerWithControlChineseComma ? "、" : "\\")
                : insertedText
            showSlashCommandMenu(triggerText: triggerText)
            return
        }

        if slashCommandHostView != nil {
            closeSlashCommandMenu()
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        closeFormattingToolbar()
        closeSlashCommandMenu()
        selectionAtMouseDown = selectedRange()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        closeFormattingToolbar()
        closeSlashCommandMenu()
        removeLocalKeyMonitorIfNeeded()
        return super.resignFirstResponder()
    }

    private func showFormattingToolbar(for selection: NSRange) {
        guard let window else { return }

        popoverSelection = selection
        if formattingPopover.isShown {
            formattingPopover.close()
        }
        installLocalKeyMonitorIfNeeded()

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
        removeLocalKeyMonitorIfNeeded()
    }

    private func showSlashCommandMenu(triggerText: String) {
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return }

        closeSlashCommandMenu()
        commandTriggerRange = NSRange(location: selection.location - triggerText.count, length: triggerText.count)
        commandTriggerText = triggerText
        slashCommandModel.reset()
        installLocalKeyMonitorIfNeeded()

        let anchorRange = NSRange(location: selection.location, length: 0)
        let caretRect = firstRect(forCharacterRange: anchorRange, actualRange: nil)
        let anchorInWindow = window?.convertFromScreen(caretRect) ?? .zero
        let anchorInView = convert(anchorInWindow, from: nil)
        let hostView = NSHostingView(
            rootView: SlashCommandListView(model: slashCommandModel) { [weak self] action in
                self?.applySlashCommand(action)
            }
        )
        let panelSize = NSSize(width: 220, height: 280)
        let x = min(max(8, anchorInView.minX - 6), bounds.width - panelSize.width - 8)
        let y = max(8, anchorInView.minY - panelSize.height - 6)
        hostView.frame = NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
        hostView.autoresizingMask = []
        addSubview(hostView)
        slashCommandHostView = hostView
    }

    private func closeSlashCommandMenu() {
        if let hostView = slashCommandHostView {
            hostView.removeFromSuperview()
        }
        slashCommandHostView = nil
        commandTriggerRange = NSRange(location: NSNotFound, length: 0)
        commandTriggerText = nil
        slashCommandModel.reset()
        removeLocalKeyMonitorIfNeeded()
    }

    private func applyFormattingAction(_ action: FormattingAction) {
        window?.makeFirstResponder(self)

        if popoverSelection.location != NSNotFound {
            setSelectedRange(popoverSelection)
        }

        onFormattingAction?(self, action)
        closeFormattingToolbar()
    }

    private func applySlashCommand(_ action: FormattingAction) {
        window?.makeFirstResponder(self)

        removeSlashTriggerIfNeeded()

        closeSlashCommandMenu()
        actionCoordinator?.apply(action, using: self)
    }

    private func removeSlashTriggerIfNeeded() {
        guard let textStorage else { return }

        let nsText = string as NSString
        let currentSelection = selectedRange()
        let triggerText = commandTriggerText
        let candidateLocations = [
            commandTriggerRange.location,
            currentSelection.location - 1
        ].filter { $0 != NSNotFound && $0 >= 0 && $0 < nsText.length }

        for location in candidateLocations {
            let candidateTexts = [triggerText, "\\", "、"].compactMap { $0 }
            let matchedText = candidateTexts.first { text in
                let range = NSRange(location: location, length: (text as NSString).length)
                guard NSMaxRange(range) <= nsText.length else { return false }
                return nsText.substring(with: range) == text
            }
            guard let matchedText else { continue }

            let candidateRange = NSRange(location: location, length: (matchedText as NSString).length)
            guard shouldChangeText(in: candidateRange, replacementString: "") else { continue }

            textStorage.replaceCharacters(in: candidateRange, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: location, length: 0))
            return
        }
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

    private func installLocalKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleEscapeIfNeeded(for: event) ? nil : event
        }
    }

    private func removeLocalKeyMonitorIfNeeded() {
        guard formattingPopover.isShown == false, slashCommandHostView == nil else { return }
        guard let localKeyMonitor else { return }

        NSEvent.removeMonitor(localKeyMonitor)
        self.localKeyMonitor = nil
    }

    private func handleEscapeIfNeeded(for event: NSEvent) -> Bool {
        guard Int(event.keyCode) == 53 else { return false }
        return closeFloatingUIIfNeeded()
    }

    @discardableResult
    private func closeFloatingUIIfNeeded() -> Bool {
        guard formattingPopover.isShown || slashCommandHostView != nil else { return false }
        closeFormattingToolbar()
        closeSlashCommandMenu()
        return true
    }
}
