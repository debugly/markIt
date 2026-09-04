//
//  DocumentModel.swift
//  Markit
//
//  Created by Reach Matt on 2026/4/14.
//
import Foundation
import AppKit

final class DocumentModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published var text: String = ""
    @Published var bodyText: String = ""
    @Published var frontMatterText: String = ""
    @Published private(set) var isDirty = false
    @Published var html: String = ""
    @Published var previewStyle: String = "GitHub.css"

    var plainText: String {
        guard !html.isEmpty else { return "" }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    var jekyllTitle: String {
        get {
            guard !frontMatterText.isEmpty else { return "" }
            let lines = frontMatterText.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title:") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        var val = parts[1].trimmingCharacters(in: .whitespaces)
                        if val.hasPrefix("\"") && val.hasSuffix("\"") {
                            val = String(val.dropFirst().dropLast())
                        } else if val.hasPrefix("'") && val.hasSuffix("'") {
                            val = String(val.dropFirst().dropLast())
                        }
                        return val
                    }
                }
            }
            return ""
        }
        set {
            guard !frontMatterText.isEmpty else { return }
            let lines = frontMatterText.components(separatedBy: .newlines)
            var newLines: [String] = []
            var foundTitle = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title:") {
                    newLines.append("title: \"\(newValue)\"")
                    foundTitle = true
                } else {
                    newLines.append(line)
                }
            }
            if !foundTitle {
                if newLines.count > 0 && newLines[0] == "---" {
                    newLines.insert("title: \"\(newValue)\"", at: 1)
                }
            }
            frontMatterText = newLines.joined(separator: "\n")
            
            // Reconstruct full text
            let combinedText: String
            if frontMatterText.isEmpty {
                combinedText = bodyText
            } else {
                combinedText = frontMatterText + "\n" + bodyText
            }
            
            if text != combinedText {
                text = combinedText
                isDirty = true
                scheduleSave()
            }
        }
    }

    var jekyllDate: String {
        get {
            guard !frontMatterText.isEmpty else { return "" }
            let lines = frontMatterText.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("date:") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        var val = parts[1].trimmingCharacters(in: .whitespaces)
                        if val.hasPrefix("\"") && val.hasSuffix("\"") {
                            val = String(val.dropFirst().dropLast())
                        } else if val.hasPrefix("'") && val.hasSuffix("'") {
                            val = String(val.dropFirst().dropLast())
                        }
                        return val
                    }
                }
            }
            return ""
        }
        set {
            guard !frontMatterText.isEmpty else { return }
            let lines = frontMatterText.components(separatedBy: .newlines)
            var newLines: [String] = []
            var foundDate = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("date:") {
                    newLines.append("date: \(newValue)")
                    foundDate = true
                } else {
                    newLines.append(line)
                }
            }
            if !foundDate {
                if newLines.count > 0 && newLines[0] == "---" {
                    newLines.insert("date: \(newValue)", at: 1)
                }
            }
            frontMatterText = newLines.joined(separator: "\n")
            
            // Reconstruct full text
            let combinedText: String
            if frontMatterText.isEmpty {
                combinedText = bodyText
            } else {
                combinedText = frontMatterText + "\n" + bodyText
            }
            
            if text != combinedText {
                text = combinedText
                isDirty = true
                scheduleSave()
            }
        }
    }

    var jekyllTags: String {
        get {
            guard !frontMatterText.isEmpty else { return "" }
            let lines = frontMatterText.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("tags:") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    if parts.count == 2 {
                        var val = parts[1].trimmingCharacters(in: .whitespaces)
                        if val.hasPrefix("[") && val.hasSuffix("]") {
                            val = String(val.dropFirst().dropLast())
                        }
                        val = val.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                        return val
                    }
                }
            }
            return ""
        }
        set {
            guard !frontMatterText.isEmpty else { return }
            let lines = frontMatterText.components(separatedBy: .newlines)
            var newLines: [String] = []
            var foundTags = false
            
            let cleanedTags = newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            
            let formattedValue = "tags: [\(cleanedTags)]"
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("tags:") {
                    newLines.append(formattedValue)
                    foundTags = true
                } else {
                    newLines.append(line)
                }
            }
            if !foundTags {
                if newLines.count > 0 && newLines[0] == "---" {
                    newLines.insert(formattedValue, at: 1)
                }
            }
            frontMatterText = newLines.joined(separator: "\n")
            
            // Reconstruct full text
            let combinedText: String
            if frontMatterText.isEmpty {
                combinedText = bodyText
            } else {
                combinedText = frontMatterText + "\n" + bodyText
            }
            
            if text != combinedText {
                text = combinedText
                isDirty = true
                scheduleSave()
            }
        }
    }

    private var saveWorkItem: DispatchWorkItem?
    private var isSettingInitialText = false

    func loadCSS(for style: String) -> String {
        guard let url = Bundle.main.url(forResource: style.replacingOccurrences(of: ".css", with: ""), withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return css
    }

    func renderExportHTML(rawHtml: String, style: String) -> String {
        let customCSS = loadCSS(for: style)
        return """
        <html>
        <head>
            <meta charset="utf-8">
            <style>\(customCSS)</style>
        </head>
        <body>
            \(rawHtml)
        </body>
        </html>
        """
    }

    private func splitFrontMatter(_ rawContent: String) -> (frontMatter: String, body: String) {
        guard rawContent.hasPrefix("---") else {
            return ("", rawContent)
        }
        
        let lines = rawContent.components(separatedBy: .newlines)
        guard lines.count > 2 else {
            return ("", rawContent)
        }
        
        var fmBlockLines: [String] = ["---"]
        var bodyLines: [String] = []
        var foundClosing = false
        
        for i in 1..<lines.count {
            let line = lines[i]
            if !foundClosing {
                fmBlockLines.append(line)
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    foundClosing = true
                }
            } else {
                bodyLines.append(line)
            }
        }
        
        if foundClosing {
            let fmText = fmBlockLines.joined(separator: "\n")
            let bodyText = bodyLines.joined(separator: "\n")
            return (fmText, bodyText)
        } else {
            return ("", rawContent)
        }
    }

    func updateTextFromWebview(_ newMarkdown: String, rawHtml: String) {
        guard isSettingInitialText == false else { return }
        
        if html != rawHtml {
            html = rawHtml
        }
        
        if bodyText != newMarkdown {
            bodyText = newMarkdown
            
            // Reconstruct the full text with front-matter
            let combinedText: String
            if frontMatterText.isEmpty {
                combinedText = newMarkdown
            } else {
                combinedText = frontMatterText + "\n" + newMarkdown
            }
            text = combinedText
            
            isDirty = true
            scheduleSave()
        }
    }

    func open(url: URL) {
        if self.url == url { return }

        saveWorkItem?.cancel()
        self.url = url
        isSettingInitialText = true

        let rawContent: String
        do {
            rawContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            rawContent = ""
        }

        let split = splitFrontMatter(rawContent)
        frontMatterText = split.frontMatter
        bodyText = split.body
        text = rawContent

        isSettingInitialText = false
        isDirty = false
    }

    func updateText(_ newValue: String) {
        let split = splitFrontMatter(newValue)
        frontMatterText = split.frontMatter
        bodyText = split.body
        text = newValue
        isDirty = true
        scheduleSave()
    }

    func saveIfDirty() -> Bool {
        guard let url = url else { return false }
        if isDirty {
            return saveNow(to: url)
        }
        return true
    }

    func updateURL(_ newURL: URL) {
        saveWorkItem?.cancel()
        url = newURL
        if isDirty {
            scheduleSave()
        }
    }

    func clear() {
        saveWorkItem?.cancel()
        url = nil
        text = ""
        bodyText = ""
        frontMatterText = ""
        isDirty = false
    }

    func confirmCloseIfNeeded() -> Bool {
        if let currentURL = url {
            if isDirty {
                _ = saveNow(to: currentURL)
            }
            return true
        }

        if isDirty {
            switch promptForUnsavedChanges() {
            case .save:
                return saveViaPanel() != nil
            case .discard:
                return true
            case .cancel:
                return false
            }
        }

        return true
    }

    @discardableResult
    func saveNow(to url: URL) -> Bool {
        saveWorkItem?.cancel()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            SyncCoordinator.shared.markModified(fileOrFolderURL: url)
            return true
        } catch {
            return false
        }
    }

    private func saveViaPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存文件"
        panel.nameFieldStringValue = "未命名.md"
        let response = panel.runModal()
        guard response == .OK, let target = panel.url else { return nil }
        if saveNow(to: target) {
            url = target
            return target
        }
        return nil
    }

    private func promptForUnsavedChanges() -> SaveDecision {
        let alert = NSAlert()
        alert.messageText = "是否保存未命名的文件？"
        alert.informativeText = "你的更改尚未保存。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func scheduleSave() {
        guard isSettingInitialText == false else { return }
        guard let url = url else { return }

        SyncCoordinator.shared.markModified(fileOrFolderURL: url)

        saveWorkItem?.cancel()
        
        let currentText = text
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try currentText.write(to: url, atomically: true, encoding: .utf8)
                self?.isDirty = false
                SyncCoordinator.shared.markModified(fileOrFolderURL: url)
            } catch {
                print("Failed to auto-save file: \(error)")
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

private enum SaveDecision {
    case save
    case discard
    case cancel
}

enum UnsavedDecision {
    case save
    case discard
    case cancel
}

extension String {
    func escapingHTML() -> String {
        var escaped = self
        // 注意：& 必须第一个替换，否则会把后面替换生成的 & 再次转义
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }
}
