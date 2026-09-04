//
//  HTMLPreviewViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/4.
//

import AppKit
import WebKit

final class HTMLPreviewViewController: NSViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private var lastLoadedContent: String?
    private var lastLoadedBaseURL: URL?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // 直接使用原生 webview，不增加任何额外的 js 和样式注入
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        self.view = webView
    }

    func previewHTML(content: String, baseURL: URL?) {
        if lastLoadedContent == content && lastLoadedBaseURL == baseURL {
            return
        }
        lastLoadedContent = content
        lastLoadedBaseURL = baseURL
        webView.loadHTMLString(content, baseURL: baseURL)
    }

    func reload() {
        webView.reload()
    }

    func clear() {
        lastLoadedContent = nil
        lastLoadedBaseURL = nil
        webView.loadHTMLString("", baseURL: nil)
    }
}
