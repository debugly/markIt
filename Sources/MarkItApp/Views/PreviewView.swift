import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    @ObservedObject var document: DocumentModel
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // Add script message handler
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "contentDidChange")
        userContentController.add(context.coordinator, name: "editorReady")
        config.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.navigationDelegate = context.coordinator
        
        // Load the editor HTML page
        let htmlTemplate = getEditorHTMLTemplate()
        webView.loadHTMLString(htmlTemplate, baseURL: nil)
        
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.isEditorReady else { return }
        
        // If the URL has changed or the document text doesn't match the webview text (edited externally in source mode)
        if document.url != context.coordinator.loadedURL || document.text != context.coordinator.lastReceivedText {
            context.coordinator.loadedURL = document.url
            context.coordinator.lastReceivedText = document.text
            let markdown = document.text
            let jsString = "window.setMarkdownContent(\(markdown.jsEscaped));"
            webView.evaluateJavaScript(jsString)
        }
        
        // If the style has changed, update the CSS
        if document.previewStyle != context.coordinator.loadedStyle {
            context.coordinator.loadedStyle = document.previewStyle
            let css = document.loadCSS(for: document.previewStyle)
            let jsString = "window.updateStyle(\(css.jsEscaped));"
            webView.evaluateJavaScript(jsString)
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
                
                // Initial load of content and style
                let markdown = parent.document.text
                let style = parent.document.previewStyle
                let css = parent.document.loadCSS(for: style)
                
                loadedURL = parent.document.url
                loadedStyle = style
                lastReceivedText = markdown
                
                let setContentJS = "window.setMarkdownContent(\(markdown.jsEscaped));"
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
            }
        }
    }
}

private func getEditorHTMLTemplate() -> String {
    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script>
            window.onerror = function(message, source, lineno, colno, error) {
                const errorDiv = document.createElement('div');
                errorDiv.style.color = 'red';
                errorDiv.style.padding = '20px';
                errorDiv.style.background = '#fee2e2';
                errorDiv.style.border = '1px solid #fca5a5';
                errorDiv.style.borderRadius = '6px';
                errorDiv.style.margin = '20px';
                errorDiv.style.fontFamily = 'monospace';
                errorDiv.style.fontSize = '12px';
                errorDiv.style.whiteSpace = 'pre-wrap';
                errorDiv.innerText = 'JS Error: ' + message + '\nAt: ' + source + ':' + lineno + ':' + colno + (error ? '\nStack: ' + error.stack : '');
                document.body.appendChild(errorDiv);
                return false;
            };
            window.addEventListener('unhandledrejection', function(event) {
                const errorDiv = document.createElement('div');
                errorDiv.style.color = 'red';
                errorDiv.style.padding = '20px';
                errorDiv.style.background = '#fee2e2';
                errorDiv.style.border = '1px solid #fca5a5';
                errorDiv.style.borderRadius = '6px';
                errorDiv.style.margin = '20px';
                errorDiv.style.fontFamily = 'monospace';
                errorDiv.style.fontSize = '12px';
                errorDiv.style.whiteSpace = 'pre-wrap';
                errorDiv.innerText = 'Unhandled Rejection: ' + event.reason;
                document.body.appendChild(errorDiv);
            });
        </script>
        <style>
            html, body {
                margin: 0;
                padding: 0;
                width: 100%;
                min-height: 100%;
                background-color: transparent;
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
                border: 1px solid #ddd;
                box-sizing: border-box;
                min-width: 1em;
                padding: 8px 12px;
                position: relative;
                vertical-align: top;
            }
            .tiptap th {
                background-color: #f6f8fa;
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
        </style>
        <style id="theme-style"></style>
    </head>
    <body>
        <div id="editor-container">
            <div id="editor"></div>
        </div>

        <script type="module">
            import { Editor, mergeAttributes } from 'https://esm.sh/@tiptap/core@3';
            import StarterKit from 'https://esm.sh/@tiptap/starter-kit@3?deps=@tiptap/core@3';
            import { Markdown } from 'https://esm.sh/@tiptap/markdown@3?deps=@tiptap/core@3';
            import Heading from 'https://esm.sh/@tiptap/extension-heading@3?deps=@tiptap/core@3';
            import { TableKit } from 'https://esm.sh/@tiptap/extension-table@3?deps=@tiptap/core@3';

            let isUpdatingFromSwift = false;

            const CustomHeading = Heading.extend({
                renderHTML({ node, HTMLAttributes }) {
                    const level = node.attrs.level;
                    let style = '';
                    if (level === 1) {
                        style = 'font-size: 28px; color: black; margin-top: 1.5em; margin-bottom: 1em;';
                    } else if (level === 2) {
                        style = 'font-size: 24px; border-bottom: 1px solid #cccccc; padding-bottom: 0.3em; color: black; margin-top: 1.5em; margin-bottom: 1em;';
                    } else if (level === 3) {
                        style = 'font-size: 18px; margin-top: 1em; margin-bottom: 0.5em;';
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
                }
            });

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

            window.setMarkdownContent = function(markdown) {
                isUpdatingFromSwift = true;
                editor.commands.setContent(markdown, { contentType: 'markdown' });
                isUpdatingFromSwift = false;
                
                // Focus on editor
                editor.commands.focus();
                
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
        .font(.system(size: 14, weight: .regular, design: .monospaced))
        .lineSpacing(4)
        .padding(20)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct PreviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.editMode == .wysiwyg {
                WebView(document: state.document)
                    .background(.white)
            } else {
                SourceEditorView(document: state.document)
            }
        }
        .frame(idealWidth: 500)
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
