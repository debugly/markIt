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
    @Published private(set) var isDirty = false
    @Published var html: String = ""
    @Published var previewStyle: String = "GitHub.css"

    var plainText: String {
        guard !html.isEmpty else { return "" }
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private var saveTask: Task<Void, Never>?
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

    func updateTextFromWebview(_ newMarkdown: String, rawHtml: String) {
        guard isSettingInitialText == false else { return }
        if text != newMarkdown {
            text = newMarkdown
            html = rawHtml
            isDirty = true
            scheduleSave()
        }
    }

    func open(url: URL) {
        if self.url == url { return }

        saveTask?.cancel()
        self.url = url
        isSettingInitialText = true

        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            text = ""
        }

        isSettingInitialText = false
        isDirty = false
    }

    func updateText(_ newValue: String) {
        text = newValue
        isDirty = true
        scheduleSave()
    }

    func saveIfDirty() -> Bool {
        guard let url else { return false }
        if isDirty {
            return saveNow(to: url)
        }
        return true
    }

    func updateURL(_ newURL: URL) {
        saveTask?.cancel()
        url = newURL
        if isDirty {
            scheduleSave()
        }
    }

    func clear() {
        saveTask?.cancel()
        url = nil
        text = ""
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
        saveTask?.cancel()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
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
        guard let url else { return }

        saveTask?.cancel()
        saveTask = Task { [text] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
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
