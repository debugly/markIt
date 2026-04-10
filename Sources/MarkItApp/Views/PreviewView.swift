import Ink
import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

struct PreviewView: View {
    @ObservedObject var document: DocumentModel
    @State private var html: String = ""

    private let parser = MarkdownParser()

    var body: some View {
        VStack(spacing: 0) {
            if document.text.isEmpty {
                PlaceholderView(
                    title: "暂无内容",
                    systemImage: "doc.richtext",
                    message: "开始编辑以查看预览"
                )
            } else {
                WebView(html: html).background(.white)
            }
        }
        .frame(minWidth: 500, idealWidth: 500)
        .onChange(of: document.url) { _ in
            delayPreview()
        }
        .onAppear {
            delayPreview()
        }
        .onChange(of: document.text) { newText in
            renderMarkdown(newText)
        }
    }

    private func delayPreview() {
        renderMarkdown(document.text)
    }

    private func renderMarkdown(_ text: String) {
        guard !text.isEmpty else {
            html = ""
            return
        }
       
        let rawHtml = parser.html(from: text)
        
        let gfmCSS = """
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                font-size: 16px;
                line-height: 1.5;
                color: #24292e;
            }
            table {
                border-spacing: 0;
                border-collapse: collapse;
                display: block;
                width: max-content;
                max-width: 100%;
                overflow: auto;
                margin-top: 0;
                margin-bottom: 16px;
            }
            table th {
                font-weight: 600;
                background-color: #f6f8fa;
            }
            table th, table td {
                padding: 10px 13px;
                border: 1px solid #dfe2e5;
            }
            /* 奇偶行交替背景（斑马纹） */
            table tr:nth-child(2n) {
                background-color: #f6f8fa;
            }
            /* 调整表格内图片的默认样式 */
            table img {
                background-color: transparent;
            }
        </style>
        """

        html = """
        <html>
        <head>
            <meta charset="utf-8">
            \(gfmCSS)
        </head>
        <body>
            \(rawHtml)
        </body>
        </html>
        """
    }
}
