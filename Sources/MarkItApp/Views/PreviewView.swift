import Down
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

    var body: some View {
        VStack(spacing: 0) {
            if document.text.isEmpty {
                PlaceholderView(
                    title: "暂无内容",
                    systemImage: "doc.richtext",
                    message: "开始编辑以查看预览"
                )
            } else {
                WebView(html: html)
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
        let down = Down(markdownString: text)
        html = (try? down.toHTML(.smartUnsafe)) ?? ""
    }
}
