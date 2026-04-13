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

    var body: some View {
        VStack(spacing: 0) {
            if document.text.isEmpty {
                PlaceholderView(
                    title: "暂无内容",
                    systemImage: "doc.richtext",
                    message: "开始编辑以查看预览"
                )
            } else {
                WebView(html: document.html).background(.white)
            }
        }
        .frame(minWidth: 500, idealWidth: 500)
    }
}