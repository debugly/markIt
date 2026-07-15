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
        </style>
        <style id="theme-style"></style>
    </head>
    <body>
        <div id="editor-container">
            <div id="editor"></div>
        </div>

        <script type="module">
            import { Editor } from 'https://esm.sh/@tiptap/core@3';
            import StarterKit from 'https://esm.sh/@tiptap/starter-kit@3';
            import { Markdown } from 'https://esm.sh/@tiptap/markdown@3';

            let isUpdatingFromSwift = false;

            const editor = new Editor({
                element: document.querySelector('#editor'),
                extensions: [
                    StarterKit,
                    Markdown
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
            if state.document.url == nil {
                PlaceholderView(
                    title: "未打开文件",
                    systemImage: "doc.richtext",
                    message: "在左侧新建或打开一个 Markdown 文件开始编辑"
                )
            } else {
                if state.editMode == .wysiwyg {
                    WebView(document: state.document)
                        .background(.white)
                } else {
                    SourceEditorView(document: state.document)
                }
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
