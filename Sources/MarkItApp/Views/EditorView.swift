import SwiftUI
import AppKit

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

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard isUpdatingFromSwiftUI == false,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func wrapSelection(using textView: NSTextView, with marker: String) {
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let replacement: String
            let newSelection: NSRange

            if selection.length > 0 {
                let selectedText = (textView.string as NSString).substring(with: selection)
                replacement = "\(marker)\(selectedText)\(marker)"
                newSelection = NSRange(location: selection.location + marker.count, length: selection.length)
            } else {
                replacement = "\(marker)\(marker)"
                newSelection = NSRange(location: selection.location + marker.count, length: 0)
            }

            guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: selection, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
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

    override func keyDown(with event: NSEvent) {
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
}
