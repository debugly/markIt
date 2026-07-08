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
    @StateObject private var findState = FindReplaceState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                MarkdownEditorTextView(
                    text: Binding(
                        get: { document.text },
                        set: { document.updateText($0) }
                    ),
                    findState: findState
                )
                .background(Color(red: 255 / 255.0, green: 252 / 255.0, blue: 234 / 255.0))
            }
            
            if findState.showPanel {
                FindReplacePanel(state: findState)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 10)
                    .padding(.trailing, 20)
                    .zIndex(1)
            }
        }
        .frame(idealWidth: 500)
        .onAppear {
            findState.text = document.text
        }
        .onChange(of: document.text) { newText in
            findState.text = newText
        }
    }
}

private struct MarkdownEditorTextView: NSViewRepresentable {
    @Binding var text: String
    var findState: FindReplaceState

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
        
        textView.onFindShortcut = {
            let selection = textView.selectedRange()
            if selection.location != NSNotFound && selection.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selection)
                findState.findText = selectedText
            }
            findState.showPanel = true
            findState.showReplace = false
        }
        
        textView.onReplaceShortcut = {
            let selection = textView.selectedRange()
            if selection.location != NSNotFound && selection.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selection)
                findState.findText = selectedText
            }
            findState.showPanel = true
            findState.showReplace = true
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.findState = findState
        
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        guard textView.string != text else { return }

        context.coordinator.isUpdatingFromSwiftUI = true
        let currentSelection = textView.selectedRange()
        textView.string = text
        context.coordinator.isUpdatingSelectionProgrammatically = true
        textView.setSelectedRange(clamp(range: currentSelection, to: textView.string))
        context.coordinator.isUpdatingSelectionProgrammatically = false
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
        weak var findState: FindReplaceState? {
            didSet {
                if oldValue !== findState {
                    setupFindStateCallbacks()
                }
            }
        }

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard isUpdatingFromSwiftUI == false,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
            if let findState = findState {
                findState.text = textView.string
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard isUpdatingSelectionProgrammatically == false,
                  NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
                  let textView = notification.object as? NSTextView else { return }
            copySelectionToPasteboard(using: textView)
        }

        private var isSettingUpCallbacks = false

        func setupFindStateCallbacks() {
            guard let findState = findState, !isSettingUpCallbacks else { return }
            isSettingUpCallbacks = true
            
            findState.onUpdateHighlights = { [weak self] in
                self?.applyHighlights()
            }
            findState.onScrollToMatch = { [weak self] range in
                self?.scrollToMatch(range)
            }
            findState.onReplaceCurrent = { [weak self] in
                self?.replaceCurrent()
            }
            findState.onReplaceAll = { [weak self] in
                self?.replaceAll()
            }
            findState.onFocusEditor = { [weak self] in
                guard let textView = self?.textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
            isSettingUpCallbacks = false
            
            if let textView = textView {
                findState.text = textView.string
            }
        }

        func applyHighlights() {
            guard let textView = textView, let findState = findState else { return }
            let layoutManager = textView.layoutManager
            let textLength = (textView.string as NSString).length
            
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textLength))
            
            guard findState.showPanel, !findState.findText.isEmpty else { return }
            
            let matches = findState.matches
            let currentIndex = findState.currentMatchIndex
            
            for (index, range) in matches.enumerated() {
                guard NSMaxRange(range) <= textLength else { continue }
                
                let highlightColor: NSColor
                if index == currentIndex {
                    highlightColor = NSColor.selectedTextBackgroundColor
                } else {
                    highlightColor = NSColor.yellow.withAlphaComponent(0.25)
                }
                layoutManager?.addTemporaryAttributes([.backgroundColor: highlightColor], forCharacterRange: range)
            }
        }

        func scrollToMatch(_ range: NSRange) {
            guard let textView = textView else { return }
            let textLength = (textView.string as NSString).length
            guard NSMaxRange(range) <= textLength else { return }
            
            isUpdatingSelectionProgrammatically = true
            textView.setSelectedRange(range)
            isUpdatingSelectionProgrammatically = false
            textView.scrollRangeToVisible(range)
            applyHighlights()
        }

        private func preserveCase(for match: String, replacement: String) -> String {
            guard !match.isEmpty && !replacement.isEmpty else { return replacement }
            
            let isAllUpper = match.allSatisfy { !$0.isLetter || $0.isUppercase }
            if isAllUpper {
                return replacement.uppercased()
            }
            
            let firstChar = match.prefix(1)
            let isCapitalized = firstChar.allSatisfy { $0.isUppercase } && match.dropFirst().allSatisfy { !$0.isLetter || $0.isLowercase }
            if isCapitalized {
                let firstReplacementChar = replacement.prefix(1).uppercased()
                let restReplacement = replacement.dropFirst().lowercased()
                return firstReplacementChar + restReplacement
            }
            
            return replacement
        }

        func replaceCurrent() {
            guard let textView = textView, let findState = findState else { return }
            let matches = findState.matches
            guard !matches.isEmpty else { return }
            
            let index = findState.currentMatchIndex
            guard index >= 0 && index < matches.count else { return }
            let range = matches[index]
            
            let matchedText = (textView.string as NSString).substring(with: range)
            let replacement = findState.preserveCase ? preserveCase(for: matchedText, replacement: findState.replaceText) : findState.replaceText
            
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                
                let replacementLength = (replacement as NSString).length
                let endOfReplacement = range.location + replacementLength
                
                text = textView.string
                findState.text = textView.string
                
                if !findState.matches.isEmpty {
                    if let nextMatchIndex = findState.matches.firstIndex(where: { $0.location >= endOfReplacement }) {
                        findState.currentMatchIndex = nextMatchIndex
                        scrollToMatch(findState.matches[nextMatchIndex])
                    } else {
                        if let firstSafeMatchIndex = findState.matches.firstIndex(where: { m in
                            let overlaps = (m.location < endOfReplacement) && (NSMaxRange(m) > range.location)
                            return !overlaps
                        }) {
                            findState.currentMatchIndex = firstSafeMatchIndex
                            scrollToMatch(findState.matches[firstSafeMatchIndex])
                        } else {
                            findState.currentMatchIndex = -1
                            applyHighlights()
                        }
                    }
                } else {
                    findState.currentMatchIndex = -1
                    applyHighlights()
                }
            }
        }

        func replaceAll() {
            guard let textView = textView, let findState = findState else { return }
            let matches = findState.matches
            guard !matches.isEmpty else { return }
            
            textView.undoManager?.beginUndoGrouping()
            
            let nsText = textView.string as NSString
            let sortedMatches = matches.sorted(by: { $0.location > $1.location })
            
            for range in sortedMatches {
                let matchedText = nsText.substring(with: range)
                let replacement = findState.preserveCase ? preserveCase(for: matchedText, replacement: findState.replaceText) : findState.replaceText
                
                if textView.shouldChangeText(in: range, replacementString: replacement) {
                    textView.textStorage?.replaceCharacters(in: range, with: replacement)
                }
            }
            
            textView.didChangeText()
            textView.undoManager?.endUndoGrouping()
            
            text = textView.string
            findState.text = textView.string
            findState.currentMatchIndex = 0
            applyHighlights()
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
            isUpdatingSelectionProgrammatically = false
        }

        private func copySelectionToPasteboard(using textView: NSTextView) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.length > 0 else { return }

            let selectedText = (textView.string as NSString).substring(with: selection)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selectedText, forType: .string)
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
    var onFindShortcut: (() -> Void)?
    var onReplaceShortcut: (() -> Void)?
    weak var actionCoordinator: MarkdownEditorTextView.Coordinator?

    private var commandTriggerRange = NSRange(location: NSNotFound, length: 0)
    private var commandTriggerText: String?
    private let slashCommandModel = SlashCommandMenuModel()
    private var slashCommandHostView: NSHostingView<SlashCommandListView>?
    private var localKeyMonitor: Any?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEscapeIfNeeded(for: event) {
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command] && event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFindShortcut?()
            return true
        } else if modifiers == [.command, .option] && event.charactersIgnoringModifiers?.lowercased() == "f" {
            onReplaceShortcut?()
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
            case "f":
                onFindShortcut?()
                return
            default:
                break
            }
        } else if modifiers == [.command, .option] && event.charactersIgnoringModifiers?.lowercased() == "f" {
            onReplaceShortcut?()
            return
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
        closeSlashCommandMenu()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        closeSlashCommandMenu()
        removeLocalKeyMonitorIfNeeded()
        return super.resignFirstResponder()
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

    private func installLocalKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleEscapeIfNeeded(for: event) ? nil : event
        }
    }

    private func removeLocalKeyMonitorIfNeeded() {
        guard slashCommandHostView == nil else { return }
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
        if slashCommandHostView != nil {
            closeSlashCommandMenu()
            return true
        }
        if let findState = actionCoordinator?.findState, findState.showPanel {
            findState.showPanel = false
            return true
        }
        return false
    }
}

final class FindReplaceState: ObservableObject {
    @Published var showPanel = false
    @Published var showReplace = false
    @Published var findText = "" {
        didSet {
            updateMatches()
        }
    }
    @Published var replaceText = ""
    @Published var matchCase = false {
        didSet {
            updateMatches()
        }
    }
    @Published var wholeWord = false {
        didSet {
            updateMatches()
        }
    }
    @Published var regex = false {
        didSet {
            updateMatches()
        }
    }
    @Published var preserveCase = false
    
    @Published var matches: [NSRange] = []
    @Published var currentMatchIndex: Int = 0
    
    var text: String = "" {
        didSet {
            if oldValue != text {
                updateMatches()
            }
        }
    }
    
    var onUpdateHighlights: (() -> Void)?
    var onScrollToMatch: ((NSRange) -> Void)?
    var onReplaceCurrent: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onFocusEditor: (() -> Void)?
    
    func updateMatches() {
        matches = findMatches(in: text, findText: findText, matchCase: matchCase, wholeWord: wholeWord, regex: regex)
        if matches.isEmpty {
            currentMatchIndex = 0
        } else {
            if currentMatchIndex >= matches.count {
                currentMatchIndex = 0
            }
        }
        onUpdateHighlights?()
    }
    
    func nextMatch() {
        guard !matches.isEmpty else { return }
        if currentMatchIndex < 0 {
            currentMatchIndex = 0
        } else {
            currentMatchIndex = (currentMatchIndex + 1) % matches.count
        }
        onScrollToMatch?(matches[currentMatchIndex])
    }
    
    func previousMatch() {
        guard !matches.isEmpty else { return }
        if currentMatchIndex < 0 {
            currentMatchIndex = matches.count - 1
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        }
        onScrollToMatch?(matches[currentMatchIndex])
    }
    
    func replace() {
        onReplaceCurrent?()
    }
    
    func replaceAll() {
        onReplaceAll?()
    }
    
    private func findMatches(in text: String, findText: String, matchCase: Bool, wholeWord: Bool, regex: Bool) -> [NSRange] {
        guard !findText.isEmpty else { return [] }
        
        var ranges: [NSRange] = []
        let nsText = text as NSString
        
        if regex {
            var options: NSRegularExpression.Options = []
            if !matchCase {
                options.insert(.caseInsensitive)
            }
            guard let regexObj = try? NSRegularExpression(pattern: findText, options: options) else {
                return []
            }
            let matches = regexObj.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                ranges.append(m.range)
            }
        } else {
            var options: NSString.CompareOptions = []
            if !matchCase {
                options.insert(.caseInsensitive)
            }
            
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let foundRange = nsText.range(of: findText, options: options, range: searchRange)
                if foundRange.location == NSNotFound {
                    break
                }
                
                var isMatch = true
                if wholeWord {
                    let wordSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                    
                    if foundRange.location > 0 {
                        let prevChar = nsText.character(at: foundRange.location - 1)
                        if let prevScalar = UnicodeScalar(prevChar), wordSet.contains(prevScalar) {
                            isMatch = false
                        }
                    }
                    let nextLoc = foundRange.location + foundRange.length
                    if nextLoc < nsText.length {
                        let nextChar = nsText.character(at: nextLoc)
                        if let nextScalar = UnicodeScalar(nextChar), wordSet.contains(nextScalar) {
                            isMatch = false
                        }
                    }
                }
                
                if isMatch {
                    ranges.append(foundRange)
                }
                
                searchRange.location = foundRange.location + max(1, foundRange.length)
                searchRange.length = nsText.length - searchRange.location
            }
        }
        
        return ranges
    }
}

private enum FindReplaceFocusField: Hashable {
    case find
    case replace
}

struct FindReplacePanel: View {
    @ObservedObject var state: FindReplaceState
    @FocusState private var focusField: FindReplaceFocusField?
    @State private var escapeMonitor: Any? = nil
    
    var body: some View {
        VStack(spacing: 8) {
            // Row 1: Find Row
            HStack(spacing: 6) {
                // Toggle Replace arrow
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.showReplace.toggle()
                    }
                } label: {
                    Image(systemName: state.showReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(state.showReplace ? "隐藏替换" : "显示替换")
                
                // Find input + match options inside
                HStack(spacing: 4) {
                    TextField("查找", text: $state.findText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focusField, equals: .find)
                        .onSubmit {
                            state.nextMatch()
                        }
                    
                    // Inside-input buttons
                    HStack(spacing: 2) {
                        // Match Case: "Aa"
                        Button {
                            state.matchCase.toggle()
                        } label: {
                            Text("Aa")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(state.matchCase ? Color.accentColor.opacity(0.2) : Color.clear)
                                .foregroundColor(state.matchCase ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("区分大小写")
                        
                        // Whole Word: "ab"
                        Button {
                            state.wholeWord.toggle()
                        } label: {
                            Text("ab")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(state.wholeWord ? Color.accentColor.opacity(0.2) : Color.clear)
                                .foregroundColor(state.wholeWord ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("全字匹配")
                        
                        // Regex: ".*"
                        Button {
                            state.regex.toggle()
                        } label: {
                            Text(".*")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(state.regex ? Color.accentColor.opacity(0.2) : Color.clear)
                                .foregroundColor(state.regex ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("使用正则表达式")
                    }
                    .padding(.trailing, 2)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .frame(width: 200)
                
                // Match Count / Info
                Text(matchCountText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .leading)
                    .lineLimit(1)
                
                // Navigation / Action buttons
                HStack(spacing: 2) {
                    // Previous match
                    Button {
                        state.previousMatch()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("上一个匹配项 (Shift+Enter)")
                    
                    // Next match
                    Button {
                        state.nextMatch()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("下一个匹配项 (Enter)")
                    
                    // Close button
                    Button {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            state.showPanel = false
                            state.onFocusEditor?()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("关闭 (Esc)")
                }
            }
            
            // Row 2: Replace Row
            if state.showReplace {
                HStack(spacing: 6) {
                    // Alignment spacer matching the arrow's width (16pt)
                    Spacer()
                        .frame(width: 16)
                    
                    // Replace input + preserve case inside
                    HStack(spacing: 4) {
                        TextField("替换", text: $state.replaceText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focusField, equals: .replace)
                            .onSubmit {
                                state.replace()
                            }
                        
                        // AB (Preserve Case) button
                        Button {
                            state.preserveCase.toggle()
                        } label: {
                            Text("AB")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(state.preserveCase ? Color.accentColor.opacity(0.2) : Color.clear)
                                .foregroundColor(state.preserveCase ? .accentColor : .secondary)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("保留大小写")
                        .padding(.trailing, 2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .frame(width: 200)
                    
                    // Spacer matching matchCountText width (65pt)
                    Spacer()
                        .frame(width: 65)
                    
                    // Replace actions
                    HStack(spacing: 2) {
                        // Replace current
                        Button {
                            state.replace()
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("替换")
                        
                        // Replace All
                        Button {
                            state.replaceAll()
                        } label: {
                            Image(systemName: "arrow.right.to.line")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("全部替换")
                        
                        // Placeholder matching the close button from find row (20pt)
                        Spacer()
                            .frame(width: 20)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            if focusField == nil {
                focusField = .find
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    if state.showPanel {
                        state.showPanel = false
                        state.onFocusEditor?()
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
        }
        .onChange(of: state.showPanel) { show in
            if show {
                focusField = .find
            }
        }
        .onChange(of: state.showReplace) { show in
            if show {
                focusField = .replace
            } else {
                focusField = .find
            }
        }
    }
    
    private var matchCountText: String {
        guard !state.findText.isEmpty else {
            return "无结果"
        }
        let count = state.matches.count
        if count == 0 {
            return "无结果"
        } else {
            return "\(state.currentMatchIndex + 1) / \(count)"
        }
    }
}
