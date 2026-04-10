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
    @ObservedObject var state: AppState
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
        .onChange(of: state.previewStyle) { _ in
            renderMarkdown(document.text)
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
        let customCSS = loadCSS(for: state.previewStyle)

        html = """
        <html>
        <head>
            <meta charset="utf-8">
            \(customCSS)
        </head>
        <body>
            \(rawHtml)
        </body>
        </html>
        """
    }

    private func loadCSS(for style: String) -> String {
        guard let url = Bundle.main.url(forResource: style.replacingOccurrences(of: ".css", with: ""), withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            return "<style></style>"
        }
        return "<style>\(css)</style>"
    }
}