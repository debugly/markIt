import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @ObservedObject var document: DocumentModel
    var isInspectEnabled: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // On older macOS versions (pre-13.3), developer extras MUST be enabled on preferences before webView initialization
        if #available(macOS 13.3, *) {
            // Already handled via isInspectable on macOS 13.3+
        } else {
            config.preferences.setValue(isInspectEnabled, forKey: "developerExtrasEnabled")
        }
        
        // Add script message handler
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "contentDidChange")
        userContentController.add(context.coordinator, name: "editorReady")
        userContentController.add(context.coordinator, name: "jekyllTitleDidChange")
        userContentController.add(context.coordinator, name: "jekyllDateDidChange")
        userContentController.add(context.coordinator, name: "jekyllTagsDidChange")
        
        // Inject JS log/error forwarding scripts to print debugging logs directly to Xcode / build.sh console
        let consoleBridgeScript = WKUserScript(
            source: """
            window.onerror = function(message, source, lineno, colno, error) {
                window.webkit.messageHandlers.jsError.postMessage({
                    message: message,
                    source: source,
                    lineno: lineno,
                    colno: colno,
                    error: error ? error.stack : ""
                });
                return false;
            };
            console.log = function() {
                window.webkit.messageHandlers.jsLog.postMessage(Array.from(arguments).join(" "));
            };
            console.error = function() {
                window.webkit.messageHandlers.jsLog.postMessage("ERROR: " + Array.from(arguments).join(" "));
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(consoleBridgeScript)
        userContentController.add(context.coordinator, name: "jsLog")
        userContentController.add(context.coordinator, name: "jsError")
        
        config.userContentController = userContentController
        
        let webView = InspectableWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.navigationDelegate = context.coordinator
        
        let htmlTemplate = getEditorHTMLTemplate()
        let baseURL: URL?
        if #available(macOS 13.0, *) {
            baseURL = Bundle.main.bundleURL
        } else {
            baseURL = URL(string: "https://markit.local/")
        }
        webView.loadHTMLString(htmlTemplate, baseURL: baseURL)
        
        setInspectEnabled(isInspectEnabled, on: webView)
        
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        setInspectEnabled(isInspectEnabled, on: webView)
        
        guard context.coordinator.isEditorReady else { return }
        
        // If the style has changed, update the CSS
        if document.previewStyle != context.coordinator.loadedStyle {
            context.coordinator.loadedStyle = document.previewStyle
            let css = document.loadCSS(for: document.previewStyle)
            let jsString = "window.updateStyle(\(css.jsEscaped));"
            webView.evaluateJavaScript(jsString)
        }
        
        // If the active document URL has changed, force reload the markdown content in the WebView
        if document.url != context.coordinator.loadedURL {
            context.coordinator.loadedURL = document.url
            context.coordinator.lastReceivedText = document.bodyText
            
            let markdown = document.bodyText
            let jekyllTitle = document.jekyllTitle
            let jekyllDate = document.jekyllDate
            let jekyllTags = document.jekyllTags
            let hasJekyll = !document.frontMatterText.isEmpty
            let jsString = "window.setMarkdownContent(\(markdown.jsEscaped), \(jekyllTitle.jsEscaped), \(jekyllDate.jsEscaped), \(jekyllTags.jsEscaped), \(hasJekyll));"
            webView.evaluateJavaScript(jsString)
        }
    }
    
    private func setInspectEnabled(_ enabled: Bool, on webView: WKWebView) {
        #if compiler(>=5.8)
        if #available(macOS 13.3, *) {
            webView.isInspectable = enabled
            return
        }
        #endif
        
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.setValue(enabled, forKey: "inspectable")
        } else {
            webView.configuration.preferences.setValue(enabled, forKey: "developerExtrasEnabled")
        }
    }
    
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        var isEditorReady = false
        var loadedURL: URL?
        var loadedStyle: String?
        var lastReceivedText: String?
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "editorReady" {
                isEditorReady = true
                
                let document = parent.document
                // Initial load of content and style
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
                
                message.webView?.evaluateJavaScript(setContentJS)
                message.webView?.evaluateJavaScript(setStyleJS)
            } else if message.name == "contentDidChange" {
                guard let body = message.body as? [String: Any],
                      let markdown = body["markdown"] as? String,
                      let html = body["html"] as? String else {
                    return
                }
                
                self.lastReceivedText = markdown
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Update text in document model
                    self.parent.document.updateTextFromWebview(markdown, rawHtml: html)
                }
            } else if message.name == "jekyllTitleDidChange" {
                guard let body = message.body as? [String: Any],
                      let title = body["title"] as? String else {
                    return
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.parent.document.jekyllTitle = title
                }
            } else if message.name == "jekyllDateDidChange" {
                guard let body = message.body as? [String: Any],
                      let date = body["date"] as? String else {
                    return
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.parent.document.jekyllDate = date
                }
            } else if message.name == "jekyllTagsDidChange" {
                guard let body = message.body as? [String: Any],
                      let tags = body["tags"] as? String else {
                    return
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.parent.document.jekyllTags = tags
                }
            } else if message.name == "jsLog" {
                if let log = message.body as? String {
                    print("🌐 [Web Log]: \(log)")
                }
            } else if message.name == "jsError" {
                if let errorDict = message.body as? [String: Any],
                   let msg = errorDict["message"] as? String,
                   let line = errorDict["lineno"] as? Int,
                   let col = errorDict["colno"] as? Int,
                   let source = errorDict["source"] as? String {
                    let stack = errorDict["error"] as? String ?? ""
                    print("🔴 [Web Error] \(msg) at \(source):\(line):\(col)\nStack: \(stack)")
                    
                    // Show native macOS alert dialog
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "网页渲染/脚本错误 (Web Error)"
                        alert.informativeText = """
                        错误信息: \(msg)
                        
                        文件: \(source)
                        行: \(line), 列: \(col)
                        
                        堆栈信息 (Stack Trace):
                        \(stack)
                        """
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "确定 (OK)")
                        alert.runModal()
                    }
                }
            }
        }
    }
}

private func loadTiptapBundle() -> String {
    // 1. Try finding in the flattened bundle root
    if let url = Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js") {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
    }
    // 2. Try finding under JS subdirectory (Standard SwiftPM copy structure)
    if let url = Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js", subdirectory: "JS") {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
    }
    // 3. Try finding under Resources/JS subdirectory (Custom folder copy structure)
    if let url = Bundle.main.url(forResource: "tiptap-bundle", withExtension: "js", subdirectory: "Resources/JS") {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
    }
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
            /* Add task list checkboxes styling in editor */
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
            /* Add table styling in editor */
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
                        <label for="jekyll-tags-input">文章标签 (逗号分隔)</label>
                        <input type="text" id="jekyll-tags-input" class="jekyll-input-field" placeholder="如: apple, swift, ios" />
                    </div>
                </div>
            </div>
            <div id="editor"></div>
        </div>

        <script type="module">
            let Tiptap = window.Tiptap;
            if (!Tiptap) {
                console.warn("Local Tiptap bundle not found. Falling back to esm.sh CDN...");
                try {
                    const [core, starterKit, markdown, heading, table] = await Promise.all([
                        import('https://esm.sh/@tiptap/core@3'),
                        import('https://esm.sh/@tiptap/starter-kit@3?deps=@tiptap/core@3'),
                        import('https://esm.sh/@tiptap/markdown@3?deps=@tiptap/core@3'),
                        import('https://esm.sh/@tiptap/extension-heading@3?deps=@tiptap/core@3'),
                        import('https://esm.sh/@tiptap/extension-table@3?deps=@tiptap/core@3')
                    ]);
                    Tiptap = {
                        Editor: core.Editor,
                        mergeAttributes: core.mergeAttributes,
                        StarterKit: starterKit.default,
                        Markdown: markdown.Markdown,
                        Heading: heading.default,
                        TableKit: table.TableKit
                    };
                } catch (err) {
                    const errorDiv = document.createElement('div');
                    errorDiv.style.color = 'red';
                    errorDiv.style.padding = '20px';
                    errorDiv.innerText = 'Failed to load Tiptap editor: ' + err.message;
                    document.body.appendChild(errorDiv);
                    throw err;
                }
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
                                console.log("onUpdate trigger: opening slash menu at pos", triggerPos);
                                openSlashMenu();
                            }
                        }
                    } else {
                        if (currentPos <= triggerPos) {
                            closeSlashMenu("onUpdate-pos-less-equal (current: " + currentPos + ", trigger: " + triggerPos + ")");
                            return;
                        }
                        
                        const text = editor.state.doc.textBetween(triggerPos, currentPos);
                        const triggerChar = text[0];
                        if (triggerChar !== String.fromCharCode(92) && triggerChar !== '/' && triggerChar !== '、') {
                            closeSlashMenu("onUpdate-invalid-char (char: " + triggerChar + ")");
                            return;
                        }
                        
                        const query = text.slice(1).toLowerCase();
                        if (query.includes(' ') || query.includes(String.fromCharCode(10))) {
                            closeSlashMenu("onUpdate-space-or-newline (query: " + query + ")");
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
                    // Auto-close if selection jumps outside trigger bounds
                    if (currentPos <= triggerPos || currentPos > triggerPos + 15) {
                        closeSlashMenu("selection-update-out-of-bounds");
                    }
                }
            });

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
                const sel = window.getSelection();
                if (!sel.rangeCount) return { top: 0, left: 0, height: 20 };
                const range = sel.getRangeAt(0).cloneRange();
                let rect = range.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) {
                    const span = document.createElement('span');
                    span.appendChild(document.createTextNode('\\u200b'));
                    range.insertNode(span);
                    rect = span.getBoundingClientRect();
                    const parent = span.parentNode;
                    parent.removeChild(span);
                    parent.normalize();
                }
                return {
                    top: rect.bottom + window.scrollY,
                    left: rect.left + window.scrollX,
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
                
                // 1. Save all current active marks (at the cursor/slash character)
                const previousMarks = state.storedMarks || selection.$from.marks() || [];
                
                // 2. Delete the slash trigger character (which clears storedMarks)
                editor.chain().focus().deleteRange({ from: triggerPos, to: end }).run();
                
                // 3. Restore the saved marks to storedMarks
                if (previousMarks.length > 0) {
                    let tr = editor.view.state.tr;
                    previousMarks.forEach(mark => {
                        tr = tr.addStoredMark(mark);
                    });
                    editor.view.dispatch(tr);
                }
                
                // 4. Run the slash menu command (which will toggle/apply the selected option)
                item.command(editor);
                
                closeSlashMenu("selectSlashItem");
            }

            function openSlashMenu() {
                slashMenuOpen = true;
                filteredItems = [...menuItems];
                activeIndex = 0;
                renderSlashMenu();
                
                // Temporarily display block offscreen/hidden to measure its real dimensions
                slashMenu.style.visibility = 'hidden';
                slashMenu.style.display = 'block';
                
                const menuWidth = slashMenu.offsetWidth || 200;
                const menuHeight = slashMenu.offsetHeight || 240;
                
                const coords = getCaretCoordinates();
                
                // Webview viewport bounds
                const viewportWidth = window.innerWidth;
                const viewportHeight = window.innerHeight;
                
                // Calculate optimal left (horizontal boundary safety)
                let left = coords.left;
                if (left + menuWidth > viewportWidth - 12) {
                    left = viewportWidth - menuWidth - 12; // Shift left
                }
                if (left < 12) {
                    left = 12;
                }
                
                // Calculate optimal top (vertical boundary safety and auto flip-up)
                let top = coords.top + 6; // Default is below caret
                if (top + menuHeight > viewportHeight - 12) {
                    // If overflows bottom edge, try positioning ABOVE caret
                    const topAbove = coords.top - coords.height - menuHeight - 6;
                    if (topAbove > 12) {
                        top = topAbove; // Flip up!
                    } else {
                        // If no room above either, align to bottom edge
                        top = viewportHeight - menuHeight - 12;
                    }
                }
                
                // Apply resolved safe coordinates and make visible
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
                        // If no slash menu is open, pressing Esc clears all active inline marks (bold, italic, etc.)
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
                console.log("closeSlashMenu triggered. Reason:", reason);
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
                
                // 1. Remove all ProseMirror trailing break helper elements completely
                const trailingBreaks = container.querySelectorAll('.ProseMirror-trailingBreak');
                trailingBreaks.forEach(br => br.remove());
                
                // 2. Process all elements to strip other ProseMirror specific classes and data attributes
                const allElements = container.querySelectorAll('*');
                allElements.forEach(el => {
                    // Strip class list from any ProseMirror-related classes
                    const classes = Array.from(el.classList);
                    classes.forEach(c => {
                        if (c.startsWith('ProseMirror')) {
                            el.classList.remove(c);
                        }
                    });
                    if (el.classList.length === 0) {
                        el.removeAttribute('class');
                    }
                    
                    // Strip data attributes and other editing helpers
                    const attrs = Array.from(el.attributes);
                    attrs.forEach(attr => {
                        if (attr.name.startsWith('data-') || attr.name === 'contenteditable') {
                            el.removeAttribute(attr.name);
                        }
                    });
                });
                
                // 3. Keep inline styles on Heading elements (H1, H2, H3) and Tables (from previous steps)
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
                
                // 4. Set custom clean HTML and normal plain text to clipboard
                e.clipboardData.setData('text/html', container.innerHTML);
                e.clipboardData.setData('text/plain', selection.toString());
                e.preventDefault();
            });

            window.setMarkdownContent = function(markdown, jekyllTitle, jekyllDate, jekyllTags, hasJekyll) {
                isUpdatingFromSwift = true;
                editor.commands.setContent(markdown, { contentType: 'markdown' });
                isUpdatingFromSwift = false;
                
                // Focus on editor
                editor.commands.focus();
                
                // Handle Jekyll header card visibility and value
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

            // Set up Jekyll title, date, and tags input listeners
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

            // Notify Swift that the editor is ready
            window.webkit.messageHandlers.editorReady.postMessage({});
        </script>
    </body>
    </html>
    """
}

struct SourceEditorView: View {
    @ObservedObject var document: DocumentModel
    
    var body: some View {
        TextEditor(text: Binding(
            get: { document.text },
            set: { document.updateText($0) }
        ))
        .font(.system(size: 14.5, weight: .regular, design: .monospaced))
        .lineSpacing(6)
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(Color(.textBackgroundColor))
    }
}

struct PreviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.editMode == .wysiwyg {
                WebView(document: state.document, isInspectEnabled: state.isWebViewInspectEnabled)
                    .background(Color(.textBackgroundColor))
            } else {
                SourceEditorView(document: state.document)
            }
        }
    }
}

class InspectableWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        
        for item in menu.items {
            if let action = item.action {
                let actionStr = NSStringFromSelector(action)
                if actionStr.contains("reload") || actionStr.contains("Reload") {
                    menu.removeItem(item)
                    continue
                }
            }
            if item.title.contains("Reload") || item.title.contains("重新加载") {
                menu.removeItem(item)
            }
        }
    }
}

extension String {
    var jsEscaped: String {
        guard let data = try? JSONSerialization.data(withJSONObject: [self], options: []),
              let jsonStr = String(data: data, encoding: .utf8),
              jsonStr.count >= 2 else {
            return "\"\""
        }
        let startIndex = jsonStr.index(jsonStr.startIndex, offsetBy: 1)
        let endIndex = jsonStr.index(jsonStr.endIndex, offsetBy: -1)
        return String(jsonStr[startIndex..<endIndex])
    }
}
