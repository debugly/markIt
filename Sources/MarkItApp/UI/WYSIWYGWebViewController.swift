//
//  WYSIWYGWebViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import AppKit
import WebKit
import Combine

final class WYSIWYGWebViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    private let document: DocumentModel
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()

    private var webView: WKWebView!
    private(set) var isEditorReady = false
    private var loadedURL: URL?
    private var loadedStyle: String?
    private var lastReceivedText: String = ""

    init(document: DocumentModel, state: AppState) {
        self.document = document
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentController = WKUserContentController()

        // Inject console logging and global error handlers
        let consoleOverrideJS = """
        (function() {
            var oldLog = console.log;
            console.log = function() {
                var args = Array.prototype.slice.call(arguments);
                try {
                    window.webkit.messageHandlers.jsLog.postMessage(args.join(' '));
                } catch(e) {}
                oldLog.apply(console, arguments);
            };
            window.onerror = function(msg, url, lineNo, columnNo, error) {
                try {
                    window.webkit.messageHandlers.jsError.postMessage({
                        message: msg,
                        source: url,
                        lineno: lineNo,
                        colno: columnNo,
                        error: error ? error.stack : ''
                    });
                } catch(e) {}
                return false;
            };
        })();
        """
        let userScript = WKUserScript(source: consoleOverrideJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)

        contentController.add(self, name: "editorReady")
        contentController.add(self, name: "contentDidChange")
        contentController.add(self, name: "jekyllTitleDidChange")
        contentController.add(self, name: "jekyllDateDidChange")
        contentController.add(self, name: "jekyllTagsDidChange")
        contentController.add(self, name: "jsLog")
        contentController.add(self, name: "jsError")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        webView = InspectableWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        updateInspectableState()

        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadHTML()
        bindModel()
    }

    private func updateInspectableState() {
        #if compiler(>=5.8)
        if #available(macOS 13.3, *) {
            webView.isInspectable = state.isWebViewInspectEnabled
            return
        }
        #endif
        webView.configuration.preferences.setValue(state.isWebViewInspectEnabled, forKey: "developerExtrasEnabled")
    }

    private func loadHTML() {
        let htmlTemplate = getEditorHTMLTemplate()
        let baseURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        webView.loadHTMLString(htmlTemplate, baseURL: baseURL)
    }

    private func bindModel() {
        state.$isWebViewInspectEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateInspectableState() }
            .store(in: &cancellables)

        document.$previewStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in self?.updateStyleIfNeeded(newStyle) }
            .store(in: &cancellables)

        document.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newURL in self?.handleURLChange(newURL) }
            .store(in: &cancellables)
    }

    func syncContentFromDocument(forceReload: Bool = false) {
        guard isEditorReady else { return }

        let markdown = document.bodyText
        if forceReload || document.url != loadedURL || markdown != lastReceivedText {
            loadedURL = document.url
            lastReceivedText = markdown

            let jekyllTitle = document.jekyllTitle
            let jekyllDate = document.jekyllDate
            let jekyllTags = document.jekyllTags
            let hasJekyll = !document.frontMatterText.isEmpty

            let jsString = "window.setMarkdownContent(\(markdown.jsEscaped), \(jekyllTitle.jsEscaped), \(jekyllDate.jsEscaped), \(jekyllTags.jsEscaped), \(hasJekyll));"
            webView.evaluateJavaScript(jsString)
        }
    }

    private func handleURLChange(_ newURL: URL?) {
        guard isEditorReady else { return }
        if newURL != loadedURL {
            syncContentFromDocument()
        }
    }

    private func updateStyleIfNeeded(_ style: String) {
        guard isEditorReady else { return }
        if style != loadedStyle {
            loadedStyle = style
            let css = document.loadCSS(for: style)
            let jsString = "window.updateStyle(\(css.jsEscaped));"
            webView.evaluateJavaScript(jsString)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "editorReady":
            isEditorReady = true
            let markdown = document.bodyText
            let style = document.previewStyle
            let css = document.loadCSS(for: style)
            let jekyllTitle = document.jekyllTitle
            let jekyllDate = document.jekyllDate
            let jekyllTags = document.jekyllTags
            let hasJekyll = !document.frontMatterText.isEmpty

            loadedURL = document.url
            loadedStyle = style
            lastReceivedText = markdown

            let setContentJS = "window.setMarkdownContent(\(markdown.jsEscaped), \(jekyllTitle.jsEscaped), \(jekyllDate.jsEscaped), \(jekyllTags.jsEscaped), \(hasJekyll));"
            let setStyleJS = "window.updateStyle(\(css.jsEscaped));"

            webView.evaluateJavaScript(setContentJS)
            webView.evaluateJavaScript(setStyleJS)

        case "contentDidChange":
            guard let body = message.body as? [String: Any],
                  let markdown = body["markdown"] as? String,
                  let html = body["html"] as? String else {
                return
            }
            lastReceivedText = markdown
            DispatchQueue.main.async { [weak self] in
                self?.document.updateTextFromWebview(markdown, rawHtml: html)
            }

        case "jekyllTitleDidChange":
            if let body = message.body as? [String: Any], let title = body["title"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.document.jekyllTitle = title
                }
            }

        case "jekyllDateDidChange":
            if let body = message.body as? [String: Any], let date = body["date"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.document.jekyllDate = date
                }
            }

        case "jekyllTagsDidChange":
            if let body = message.body as? [String: Any], let tags = body["tags"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.document.jekyllTags = tags
                }
            }

        case "jsLog":
            if let log = message.body as? String {
                print("🌐 [Web Log]: \(log)")
            }

        case "jsError":
            if let errorDict = message.body as? [String: Any],
               let msg = errorDict["message"] as? String,
               let line = errorDict["lineno"] as? Int,
               let col = errorDict["colno"] as? Int,
               let source = errorDict["source"] as? String {
                let stack = errorDict["error"] as? String ?? ""
                print("🔴 [Web Error] \(msg) at \(source):\(line):\(col)\nStack: \(stack)")
            }

        default:
            break
        }
    }

    // MARK: - Undo / Redo

    @objc func undo(_ sender: Any?) {
        webView.evaluateJavaScript("if (window.editorUndo) { window.editorUndo(); }", completionHandler: nil)
    }

    @objc func redo(_ sender: Any?) {
        webView.evaluateJavaScript("if (window.editorRedo) { window.editorRedo(); }", completionHandler: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(UndoRedoActions.undo(_:)) || menuItem.action == #selector(UndoRedoActions.redo(_:)) {
            return true
        }
        return true
    }
}

private final class InspectableWKWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command] && key == "z" {
            undo(nil)
            return true
        }
        if flags == [.command, .shift] && key == "z" {
            redo(nil)
            return true
        }
        if flags == [.command] && key == "y" {
            redo(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func undo(_ sender: Any?) {
        evaluateJavaScript("if (window.editorUndo) { window.editorUndo(); }", completionHandler: nil)
    }

    @objc func redo(_ sender: Any?) {
        evaluateJavaScript("if (window.editorRedo) { window.editorRedo(); }", completionHandler: nil)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(UndoRedoActions.undo(_:)) || item.action == #selector(UndoRedoActions.redo(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        #if compiler(>=5.8)
        if #available(macOS 13.3, *) {
            if isInspectable {
                let hasInspectElement = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }
                if !hasInspectElement {
                    menu.addItem(NSMenuItem.separator())
                    let inspectItem = NSMenuItem(
                        title: "审查元素 (Inspect Element)",
                        action: #selector(triggerInspectElement),
                        keyEquivalent: "i"
                    )
                    inspectItem.keyEquivalentModifierMask = [.command, .option]
                    inspectItem.target = self
                    menu.addItem(inspectItem)
                }
            }
        }
        #endif
    }

    @objc private func triggerInspectElement() {
        let js = "console.log('Inspect Element requested from menu');"
        evaluateJavaScript(js, completionHandler: nil)
    }
}

private func loadTiptapBundle() -> String {
    let candidateURLs: [URL?] = [
        Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js"),
        Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js", subdirectory: "JS"),
        Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js", subdirectory: "Resources/JS"),
        Bundle.main.resourceURL?.appendingPathComponent("tiptap-bundle.js"),
        Bundle.main.resourceURL?.appendingPathComponent("JS/tiptap-bundle.js"),
        Bundle.main.resourceURL?.appendingPathComponent("Resources/JS/tiptap-bundle.js")
    ]
    for candidate in candidateURLs {
        if let url = candidate, let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
            return content
        }
    }
    NSLog("❌ [MarkIt] Failed to locate or read tiptap-bundle.js in Bundle.main")
    return ""
}

private func getEditorHTMLTemplate() -> String {
    let bundleJS = loadTiptapBundle()
    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script>
            \(bundleJS)
        </script>
        <style>
            :root {
                --text-color: #1e293b;
                --heading-color: #0f172a;
                --border-color: #e2e8f0;
                --table-th-bg: #f6f8fa;
                --card-bg: linear-gradient(135deg, #fdfbfb 0%, #f6f7f9 100%);
                --input-bg: #ffffff;
                --input-border: #cbd5e1;
                --input-text: #1e293b;
                --badge-bg: #fff1f2;
                --badge-text: #e11d48;
                --label-color: #64748b;
            }
            @media (prefers-color-scheme: dark) {
                :root {
                    --text-color: #e2e8f0;
                    --heading-color: #f1f5f9;
                    --border-color: #334155;
                    --table-th-bg: #1e293b;
                    --card-bg: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
                    --input-bg: #1e293b;
                    --input-border: #475569;
                    --input-text: #f1f5f9;
                    --badge-bg: #4c0519;
                    --badge-text: #fda4af;
                    --label-color: #94a3b8;
                }
            }
            html, body {
                margin: 0 !important;
                padding: 0 !important;
                width: 100% !important;
                min-height: 100% !important;
                background-color: transparent;
                color: var(--text-color);
                overflow-x: hidden;
            }
            #editor-container {
                width: 100%;
                box-sizing: border-box;
                padding: 24px 40px;
            }
            .tiptap {
                min-height: 100%;
                outline: none;
            }
            .tiptap ul[data-type="taskList"] {
                list-style: none;
                padding: 0;
            }
            .tiptap ul[data-type="taskList"] li {
                display: flex;
                align-items: flex-start;
                margin-bottom: 0.25em;
            }
            .tiptap ul[data-type="taskList"] li > label {
                margin-right: 0.5em;
                user-select: none;
            }
            .tiptap ul[data-type="taskList"] li > div {
                flex: 1;
            }
            .tiptap table {
                border-collapse: collapse;
                table-layout: fixed;
                width: 100%;
                margin: 1.5em 0;
                overflow: hidden;
            }
            .tiptap td, .tiptap th {
                border: 1px solid var(--border-color);
                box-sizing: border-box;
                min-width: 1em;
                padding: 8px 12px;
                position: relative;
                vertical-align: top;
            }
            .tiptap th {
                background-color: var(--table-th-bg);
                font-weight: bold;
                text-align: left;
            }
            .tiptap .selectedCell:after {
                background: rgba(200, 200, 255, 0.4);
                content: "";
                left: 0; right: 0; top: 0; bottom: 0;
                pointer-events: none;
                position: absolute;
                z-index: 2;
            }
            .tiptap .column-resize-handle {
                background-color: #3b82f6;
                bottom: -2px;
                position: absolute;
                right: -2px;
                top: 0;
                width: 4px;
                z-index: 20;
                pointer-events: none;
            }
            
            #jekyll-header-card {
                background: var(--card-bg);
                border: 1px solid var(--border-color);
                border-radius: 12px;
                padding: 16px 20px;
                margin-bottom: 24px;
                box-shadow: 0 4px 12px rgba(0, 0, 0, 0.02);
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            }
            .jekyll-badge {
                display: inline-flex;
                align-items: center;
                background-color: var(--badge-bg);
                color: var(--badge-text);
                font-size: 11px;
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.5px;
                padding: 4px 8px;
                border-radius: 6px;
                margin-bottom: 12px;
            }
            .jekyll-icon {
                margin-right: 4px;
            }
            .jekyll-fields-grid {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 16px;
            }
            .jekyll-field {
                display: flex;
                flex-direction: column;
                gap: 6px;
            }
            .jekyll-field.full-width {
                grid-column: span 2;
            }
            .jekyll-field label {
                font-size: 12px;
                font-weight: 500;
                color: var(--label-color);
            }
            .jekyll-input-field {
                font-size: 14px;
                font-weight: 500;
                color: var(--input-text);
                border: 1px solid var(--input-border);
                border-radius: 8px;
                padding: 8px 12px;
                outline: none;
                transition: border-color 0.2s, box-shadow 0.2s;
                background-color: var(--input-bg);
            }
            .jekyll-input-field:focus {
                border-color: #e11d48;
                box-shadow: 0 0 0 3px rgba(225, 29, 72, 0.15);
            }
            #jekyll-title-input {
                font-size: 18px;
                font-weight: 600;
            }
        </style>
        <style id="theme-style"></style>
    </head>
    <body>
        <div id="editor-container">
            <div id="jekyll-header-card" style="display: none;">
                <div class="jekyll-badge">
                    <span class="jekyll-icon">✍️</span> Jekyll 文章配置
                </div>
                <div class="jekyll-fields-grid">
                    <div class="jekyll-field full-width">
                        <label for="jekyll-title-input">文章标题</label>
                        <input type="text" id="jekyll-title-input" class="jekyll-input-field" placeholder="请输入博客标题..." />
                    </div>
                    <div class="jekyll-field">
                        <label for="jekyll-date-input">发布日期</label>
                        <input type="text" id="jekyll-date-input" class="jekyll-input-field" placeholder="如: 2026-07-15 15:30:00 +0800" />
                    </div>
                    <div class="jekyll-field">
                        <label for="jekyll-date-tags">文章标签 (逗号分隔)</label>
                        <input type="text" id="jekyll-tags-input" class="jekyll-input-field" placeholder="如: apple, swift, ios" />
                    </div>
                </div>
            </div>
            <div id="editor"></div>
        </div>

        <script>
            (function() {
                var Tiptap = window.Tiptap;
                if (!Tiptap) {
                    var errorMsg = "Local Tiptap bundle not found.";
                    console.error(errorMsg);
                    try {
                        window.webkit.messageHandlers.jsError.postMessage({
                            message: errorMsg,
                            source: "WYSIWYGTemplate",
                            lineno: 0,
                            colno: 0,
                            error: ""
                        });
                    } catch(e) {}
                    var errorDiv = document.createElement('div');
                    errorDiv.style.color = 'red';
                    errorDiv.style.padding = '20px';
                    errorDiv.innerText = 'Failed to load Tiptap editor: ' + errorMsg;
                    document.body.appendChild(errorDiv);
                    return;
                }

                const { Editor, mergeAttributes, StarterKit, Markdown, Heading, TableKit } = Tiptap;

            let isUpdatingFromSwift = false;

            const CustomHeading = Heading.extend({
                renderHTML({ node, HTMLAttributes }) {
                    const level = node.attrs.level;
                    let style = '';
                    if (level === 1) {
                        style = 'font-size: 28px; color: var(--heading-color); margin-top: 1.5em; margin-bottom: 1em;';
                    } else if (level === 2) {
                        style = 'font-size: 24px; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; color: var(--heading-color); margin-top: 1.5em; margin-bottom: 1em;';
                    } else if (level === 3) {
                        style = 'font-size: 18px; color: var(--heading-color); margin-top: 1em; margin-bottom: 0.5em;';
                    }
                    
                    return [
                        `h${level}`,
                        mergeAttributes(this.options.HTMLAttributes, HTMLAttributes, { style }),
                        0
                    ];
                }
            });

            function containsMarkdownTable(text) {
                if (!text || typeof text !== 'string') return false;
                const lines = text.trim().split(/\\r?\\n/);
                if (lines.length < 2) return false;
                const delimiterPattern = /^\\s*\\|?(\\s*:?-+:?\\s*\\|)+\\s*:?-+:?\\s*\\|?\\s*$|^\\s*\\|\\s*:?-+:?\\s*\\|\\s*$/;
                for (let i = 1; i < lines.length; i++) {
                    if (delimiterPattern.test(lines[i])) {
                        const prevLine = lines[i - 1].trim();
                        if (prevLine.includes('|')) {
                            return true;
                        }
                    }
                }
                return false;
            }

            const editor = new Editor({
                element: document.querySelector('#editor'),
                extensions: [
                    StarterKit.configure({
                        heading: false
                    }),
                    Markdown,
                    CustomHeading,
                    TableKit.configure({
                        table: {
                            resizable: true,
                            HTMLAttributes: {
                                style: 'border-collapse: collapse; margin: 1.5em 0; width: 100%; border: 1px solid #ddd;',
                            }
                        },
                        tableHeader: {
                            HTMLAttributes: {
                                style: 'border: 1px solid #ddd; padding: 8px 12px; background-color: #f6f8fa; font-weight: bold; text-align: left;',
                            }
                        },
                        tableCell: {
                            HTMLAttributes: {
                                style: 'border: 1px solid #ddd; padding: 8px 12px; vertical-align: top;',
                            }
                        }
                    })
                ],
                content: '',
                contentType: 'markdown',
                editorProps: {
                    handlePaste(view, event, slice) {
                        if (event.target && (event.target.tagName === 'INPUT' || event.target.tagName === 'TEXTAREA')) {
                            return false;
                        }
                        if (editor.isActive('codeBlock') || editor.isActive('table')) {
                            return false;
                        }
                        const html = event.clipboardData?.getData('text/html');
                        if (html && /<table[\\s>]/i.test(html)) {
                            return false;
                        }
                        const text = event.clipboardData?.getData('text/plain');
                        if (text && containsMarkdownTable(text)) {
                            editor.commands.insertContent(text.trim(), { contentType: 'markdown' });
                            return true;
                        }
                        return false;
                    }
                },
                onUpdate({ editor }) {
                    if (isUpdatingFromSwift) return;
                    const markdown = editor.getMarkdown();
                    const html = editor.getHTML();
                    window.webkit.messageHandlers.contentDidChange.postMessage({
                        markdown: markdown,
                        html: html
                    });

                    // Synchronous, robust, native Tiptap-driven trigger and search
                    const { selection } = editor.state;
                    const currentPos = selection.from;

                    if (!slashMenuOpen) {
                        if (currentPos > 0) {
                            const text = editor.state.doc.textBetween(currentPos - 1, currentPos);
                            if (text === String.fromCharCode(92) || text === '/' || text === '、') {
                                triggerPos = currentPos - 1;
                                openSlashMenu();
                            }
                        }
                    } else {
                        if (currentPos <= triggerPos) {
                            closeSlashMenu("onUpdate-pos-less-equal");
                            return;
                        }
                        
                        const text = editor.state.doc.textBetween(triggerPos, currentPos);
                        const triggerChar = text[0];
                        if (triggerChar !== String.fromCharCode(92) && triggerChar !== '/' && triggerChar !== '、') {
                            closeSlashMenu("onUpdate-invalid-char");
                            return;
                        }
                        
                        const query = text.slice(1).toLowerCase();
                        if (query.includes(' ') || query.includes(String.fromCharCode(10))) {
                            closeSlashMenu("onUpdate-space-or-newline");
                            return;
                        }
                        
                        filteredItems = menuItems.filter(item => 
                            item.title.toLowerCase().includes(query) || 
                            item.id.toLowerCase().includes(query)
                        );
                        
                        activeIndex = 0;
                        renderSlashMenu();
                    }
                },
                onSelectionUpdate({ editor }) {
                    if (!slashMenuOpen) return;
                    const { selection } = editor.state;
                    const currentPos = selection.from;
                    if (currentPos <= triggerPos || currentPos > triggerPos + 15) {
                        closeSlashMenu("selection-update-out-of-bounds");
                    }
                }
            });
            window.editor = editor;

            // --- SLASH / BACKSLASH COMMAND MENU SYSTEM ---
            const slashStyle = document.createElement('style');
            slashStyle.textContent = `
                .slash-menu-item {
                    display: flex;
                    align-items: center;
                    padding: 6px 8px;
                    border-radius: 6px;
                    cursor: pointer;
                    font-size: 13px;
                    color: var(--text-color);
                    transition: background 0.1s, transform 0.1s;
                }
                .slash-menu-item.active {
                    background: var(--border-color) !important;
                }
                .slash-menu-item:active {
                    transform: scale(0.98);
                }
            `;
            document.head.appendChild(slashStyle);

            const menuItems = [
                { id: 'heading1', title: '一级标题 (H1)', icon: 'H1', command: (editor) => editor.chain().focus().toggleHeading({ level: 1 }).run() },
                { id: 'heading2', title: '二级标题 (H2)', icon: 'H2', command: (editor) => editor.chain().focus().toggleHeading({ level: 2 }).run() },
                { id: 'heading3', title: '三级标题 (H3)', icon: 'H3', command: (editor) => editor.chain().focus().toggleHeading({ level: 3 }).run() },
                { id: 'bold', title: '加粗 (Bold)', icon: 'B', command: (editor) => editor.chain().focus().toggleBold().run() },
                { id: 'italic', title: '斜体 (Italic)', icon: 'I', command: (editor) => editor.chain().focus().toggleItalic().run() },
                { id: 'blockquote', title: '引用 (Quote)', icon: '❝', command: (editor) => editor.chain().focus().toggleBlockquote().run() },
                { id: 'bulletList', title: '无序列表 (Bullet)', icon: '•', command: (editor) => editor.chain().focus().toggleBulletList().run() },
                { id: 'orderedList', title: '有序列表 (Number)', icon: '1.', command: (editor) => editor.chain().focus().toggleOrderedList().run() },
                { id: 'taskList', title: '任务列表 (Todo)', icon: '☑', command: (editor) => editor.chain().focus().toggleTaskList().run() },
                { id: 'codeBlock', title: '代码块 (Code)', icon: '<>', command: (editor) => editor.chain().focus().toggleCodeBlock().run() },
                { id: 'table', title: '表格 (Table)', icon: '田', command: (editor) => editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() }
            ];

            let slashMenuOpen = false;
            let activeIndex = 0;
            let filteredItems = [...menuItems];
            let triggerPos = null;

            const slashMenu = document.createElement('div');
            slashMenu.id = 'slash-menu';
            slashMenu.style.cssText = `
                position: absolute;
                display: none;
                width: 200px;
                max-height: 240px;
                overflow-y: auto;
                background: var(--input-bg);
                border: 1px solid var(--border-color);
                border-radius: 10px;
                box-shadow: 0 10px 25px rgba(0,0,0,0.1);
                z-index: 99999;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                padding: 4px;
            `;
            document.body.appendChild(slashMenu);

            function getCaretCoordinates() {
                try {
                    const { selection } = editor.state;
                    const coords = editor.view.coordsAtPos(selection.from);
                    if (coords) {
                        return {
                            top: coords.bottom + window.scrollY,
                            left: coords.left + window.scrollX,
                            height: (coords.bottom - coords.top) || 20
                        };
                    }
                } catch (e) {}
                const sel = window.getSelection();
                if (!sel || !sel.rangeCount) return { top: 0, left: 0, height: 20 };
                const rect = sel.getRangeAt(0).getBoundingClientRect();
                return {
                    top: (rect.bottom || 0) + window.scrollY,
                    left: (rect.left || 0) + window.scrollX,
                    height: rect.height || 20
                };
            }

            function renderSlashMenu() {
                slashMenu.innerHTML = '';
                if (filteredItems.length === 0) {
                    const empty = document.createElement('div');
                    empty.innerText = '未找到匹配格式';
                    empty.style.cssText = 'padding: 8px; color: var(--label-color); text-align: center; font-size: 13px;';
                    slashMenu.appendChild(empty);
                    return;
                }

                filteredItems.forEach((item, index) => {
                    const el = document.createElement('div');
                    el.className = 'slash-menu-item' + (index === activeIndex ? ' active' : '');
                    
                    const iconEl = document.createElement('span');
                    iconEl.innerText = item.icon;
                    iconEl.style.cssText = `
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        width: 20px;
                        height: 20px;
                        background: var(--table-th-bg);
                        border-radius: 4px;
                        margin-right: 8px;
                        font-weight: bold;
                        font-size: 10px;
                        color: var(--label-color);
                    `;
                    el.appendChild(iconEl);

                    const titleEl = document.createElement('span');
                    titleEl.innerText = item.title;
                    el.appendChild(titleEl);

                    el.addEventListener('mouseenter', () => {
                        activeIndex = index;
                        const children = slashMenu.querySelectorAll('.slash-menu-item');
                        children.forEach((c, idx) => {
                            if (idx === index) {
                                c.classList.add('active');
                            } else {
                                c.classList.remove('active');
                            }
                        });
                    });
                    
                    el.addEventListener('mousedown', (e) => {
                        e.preventDefault();
                        selectSlashItem(item);
                    });

                    slashMenu.appendChild(el);
                });
            }

            function selectSlashItem(item) {
                const { state } = editor;
                const { selection } = state;
                const end = selection.from;
                
                const previousMarks = state.storedMarks || selection.$from.marks() || [];
                
                editor.chain().focus().deleteRange({ from: triggerPos, to: end }).run();
                
                if (previousMarks.length > 0) {
                    let tr = editor.view.state.tr;
                    previousMarks.forEach(mark => {
                        tr = tr.addStoredMark(mark);
                    });
                    editor.view.dispatch(tr);
                }
                
                item.command(editor);
                closeSlashMenu("selectSlashItem");
            }

            function openSlashMenu() {
                slashMenuOpen = true;
                filteredItems = [...menuItems];
                activeIndex = 0;
                renderSlashMenu();
                
                slashMenu.style.visibility = 'hidden';
                slashMenu.style.display = 'block';
                
                const menuWidth = slashMenu.offsetWidth || 200;
                const menuHeight = slashMenu.offsetHeight || 240;
                
                const coords = getCaretCoordinates();
                
                const viewportWidth = window.innerWidth;
                const viewportHeight = window.innerHeight;
                
                let left = coords.left;
                if (left + menuWidth > viewportWidth - 12) {
                    left = viewportWidth - menuWidth - 12;
                }
                if (left < 12) {
                    left = 12;
                }
                
                let top = coords.top + 6;
                if (top + menuHeight > viewportHeight - 12) {
                    const topAbove = coords.top - coords.height - menuHeight - 6;
                    if (topAbove > 12) {
                        top = topAbove;
                    } else {
                        top = viewportHeight - menuHeight - 12;
                    }
                }
                
                slashMenu.style.left = left + 'px';
                slashMenu.style.top = top + 'px';
                slashMenu.style.visibility = 'visible';
                
                document.addEventListener('mousedown', clickOutsideHandler);
            }

            function scrollActiveItemIntoView() {
                const activeEl = slashMenu.querySelector('.slash-menu-item.active');
                if (activeEl) {
                    activeEl.scrollIntoView({ block: 'nearest' });
                }
            }

            const editorEl = document.querySelector('#editor');
            editorEl.addEventListener('keydown', function(event) {
                if (slashMenuOpen) {
                    if (event.key === 'ArrowDown') {
                        event.preventDefault();
                        activeIndex = (activeIndex + 1) % filteredItems.length;
                        renderSlashMenu();
                        scrollActiveItemIntoView();
                        return;
                    }
                    if (event.key === 'ArrowUp') {
                        event.preventDefault();
                        activeIndex = (activeIndex - 1 + filteredItems.length) % filteredItems.length;
                        renderSlashMenu();
                        scrollActiveItemIntoView();
                        return;
                    }
                    if (event.key === 'Enter') {
                        event.preventDefault();
                        if (filteredItems[activeIndex]) {
                            selectSlashItem(filteredItems[activeIndex]);
                        }
                        return;
                    }
                    if (event.key === 'Escape') {
                        event.preventDefault();
                        closeSlashMenu("escapeKey");
                        return;
                    }
                } else {
                    if (event.key === 'Escape') {
                        const activeMarks = editor.state.storedMarks || editor.state.selection.$from.marks();
                        if (activeMarks && activeMarks.length > 0) {
                            event.preventDefault();
                            editor.chain().focus().unsetAllMarks().run();
                            editor.view.dispatch(editor.view.state.tr.setStoredMarks([]));
                        }
                    }
                }
            }, true);

            function closeSlashMenu(reason) {
                slashMenuOpen = false;
                slashMenu.style.display = 'none';
                document.removeEventListener('mousedown', clickOutsideHandler);
            }

            function clickOutsideHandler(event) {
                if (!slashMenu.contains(event.target)) {
                    closeSlashMenu("clickOutside");
                }
            }

            document.addEventListener('copy', function(e) {
                const selection = window.getSelection();
                if (!selection.rangeCount) return;
                
                const container = document.createElement('div');
                for (let i = 0; i < selection.rangeCount; i++) {
                    container.appendChild(selection.getRangeAt(i).cloneContents());
                }
                
                const trailingBreaks = container.querySelectorAll('.ProseMirror-trailingBreak');
                trailingBreaks.forEach(br => br.remove());
                
                const allElements = container.querySelectorAll('*');
                allElements.forEach(el => {
                    const classes = Array.from(el.classList);
                    classes.forEach(c => {
                        if (c.startsWith('ProseMirror')) {
                            el.classList.remove(c);
                        }
                    });
                    if (el.classList.length === 0) {
                        el.removeAttribute('class');
                    }
                    
                    const attrs = Array.from(el.attributes);
                    attrs.forEach(attr => {
                        if (attr.name.startsWith('data-') || attr.name === 'contenteditable') {
                            el.removeAttribute(attr.name);
                        }
                    });
                });
                
                const h2s = container.querySelectorAll('h2');
                h2s.forEach(h2 => {
                    h2.setAttribute('style', 'font-size: 24px; border-bottom: 1px solid #cccccc; padding-bottom: 0.3em; color: black; margin-top: 1.5em; margin-bottom: 1em;');
                });
                const h1s = container.querySelectorAll('h1');
                h1s.forEach(h1 => {
                    h1.setAttribute('style', 'font-size: 28px; color: black; margin-top: 1.5em; margin-bottom: 1em;');
                });
                const tables = container.querySelectorAll('table');
                tables.forEach(table => {
                    table.setAttribute('style', 'border-collapse: collapse; margin: 1.5em 0; width: 100%; border: 1px solid #ddd;');
                });
                const ths = container.querySelectorAll('th');
                ths.forEach(th => {
                    th.setAttribute('style', 'border: 1px solid #ddd; padding: 8px 12px; background-color: #f6f8fa; font-weight: bold; text-align: left;');
                });
                const tds = container.querySelectorAll('td');
                tds.forEach(td => {
                    td.setAttribute('style', 'border: 1px solid #ddd; padding: 8px 12px; vertical-align: top;');
                });
                
                e.clipboardData.setData('text/html', container.innerHTML);
                e.clipboardData.setData('text/plain', selection.toString());
                e.preventDefault();
            });

            window.setMarkdownContent = function(markdown, jekyllTitle, jekyllDate, jekyllTags, hasJekyll) {
                isUpdatingFromSwift = true;
                editor.commands.setContent(markdown, { contentType: 'markdown' });
                isUpdatingFromSwift = false;
                
                const card = document.getElementById('jekyll-header-card');
                const titleInput = document.getElementById('jekyll-title-input');
                const dateInput = document.getElementById('jekyll-date-input');
                const tagsInput = document.getElementById('jekyll-tags-input');
                if (hasJekyll) {
                    card.style.display = 'block';
                    titleInput.value = jekyllTitle || '';
                    dateInput.value = jekyllDate || '';
                    tagsInput.value = jekyllTags || '';
                } else {
                    card.style.display = 'none';
                    titleInput.value = '';
                    dateInput.value = '';
                    tagsInput.value = '';
                }
                
                const html = editor.getHTML();
                window.webkit.messageHandlers.contentDidChange.postMessage({
                    markdown: markdown,
                    html: html
                });
            };

            window.updateStyle = function(cssText) {
                const styleEl = document.getElementById('theme-style');
                if (styleEl) {
                    styleEl.textContent = cssText;
                }
            };

            document.getElementById('jekyll-title-input').addEventListener('input', function(e) {
                window.webkit.messageHandlers.jekyllTitleDidChange.postMessage({
                    title: e.target.value
                });
            });
            
            document.getElementById('jekyll-date-input').addEventListener('input', function(e) {
                window.webkit.messageHandlers.jekyllDateDidChange.postMessage({
                    date: e.target.value
                });
            });
            
            document.getElementById('jekyll-tags-input').addEventListener('input', function(e) {
                window.webkit.messageHandlers.jekyllTagsDidChange.postMessage({
                    tags: e.target.value
                });
            });

            window.editorUndo = function() {
                const activeEl = document.activeElement;
                if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
                    document.execCommand('undo');
                    return true;
                }
                if (window.editor && window.editor.can().undo()) {
                    window.editor.chain().focus().undo().run();
                    return true;
                }
                return false;
            };

            window.editorRedo = function() {
                const activeEl = document.activeElement;
                if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
                    document.execCommand('redo');
                    return true;
                }
                if (window.editor && window.editor.can().redo()) {
                    window.editor.chain().focus().redo().run();
                    return true;
                }
                return false;
            };

            window.addEventListener('keydown', function(event) {
                if ((event.metaKey || event.ctrlKey) && (event.key === 'z' || event.key === 'Z')) {
                    const activeEl = document.activeElement;
                    if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
                        return;
                    }
                    if (event.shiftKey) {
                        if (window.editorRedo && window.editorRedo()) {
                            event.preventDefault();
                            event.stopPropagation();
                        }
                    } else {
                        if (window.editorUndo && window.editorUndo()) {
                            event.preventDefault();
                            event.stopPropagation();
                        }
                    }
                } else if ((event.metaKey || event.ctrlKey) && (event.key === 'y' || event.key === 'Y')) {
                    const activeEl = document.activeElement;
                    if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.tagName === 'TEXTAREA')) {
                        return;
                    }
                    if (window.editorRedo && window.editorRedo()) {
                        event.preventDefault();
                        event.stopPropagation();
                    }
                }
            }, true);

            window.webkit.messageHandlers.editorReady.postMessage({});
        })();
        </script>
    </body>
    </html>
    """
}

extension String {
    var jsEscaped: String {
        guard let data = try? JSONSerialization.data(withJSONObject: [self]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return "\"\""
    }
}
