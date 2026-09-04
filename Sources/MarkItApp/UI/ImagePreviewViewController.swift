//
//  ImagePreviewViewController.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/4.
//

import AppKit
import WebKit
import ImageIO

final class ImagePreviewViewController: NSViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private(set) var currentImageURL: URL?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // 透明背景，跟随 HTML 样式
        webView.autoresizingMask = [.width, .height]
        self.view = webView
    }

    func previewImage(at url: URL) {
        if currentImageURL == url {
            return
        }
        currentImageURL = url
        // 立即置空 DOM，防止在新图片尚未渲染完成前闪烁上一张图片
        webView.evaluateJavaScript("document.body.innerHTML = '';", completionHandler: nil)
        let html = generateHTML(for: url)
        let directoryURL = URL(fileURLWithPath: url.deletingLastPathComponent().path, isDirectory: true)
        webView.loadHTMLString(html, baseURL: directoryURL)
    }

    func clear() {
        currentImageURL = nil
        if webView != nil {
            webView.evaluateJavaScript("document.body.innerHTML = '';", completionHandler: nil)
            webView.loadHTMLString("", baseURL: nil)
        }
    }

    private func extractMetadata(from url: URL) -> (hasDimensions: Bool, pills: [String]) {
        var pills: [String] = []
        var hasDimensions = false

        // 1. 文件大小
        let fileSize = SupportedFileType.formattedFileSize(for: url)
        if !fileSize.isEmpty {
            pills.append(fileSize)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (hasDimensions, pills)
        }

        // 2. 图片尺寸（处理 EXIF 旋转）
        var width = properties[kCGImagePropertyPixelWidth] as? Int
        var height = properties[kCGImagePropertyPixelHeight] as? Int
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, [5, 6, 7, 8].contains(orientation) {
            swap(&width, &height)
        }
        if let w = width, let h = height, w > 0, h > 0 {
            pills.append("\(w) × \(h)")
            hasDimensions = true
        }

        // 3. 色彩模型与位深度
        let colorModel = properties[kCGImagePropertyColorModel] as? String
        let depth = properties[kCGImagePropertyDepth] as? Int
        if let depth = depth, depth > 0 {
            if let cm = colorModel {
                pills.append("\(cm) \(depth)-bit")
            } else {
                pills.append("\(depth)-bit")
            }
        }

        // 4. DPI / 分辨率（若非默认 72）
        if let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Int, dpiWidth > 0, dpiWidth != 72 {
            pills.append("\(dpiWidth) DPI")
        }

        // 5. EXIF 拍摄参数
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var cameraParams: [String] = []
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                cameraParams.append(String(format: "ƒ/%.1f", fNumber))
            }
            if let exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double {
                if exposureTime < 1.0 && exposureTime > 0 {
                    cameraParams.append(String(format: "1/%ds", Int(round(1.0 / exposureTime))))
                } else if exposureTime >= 1.0 {
                    cameraParams.append(String(format: "%.1fs", exposureTime))
                }
            }
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArray.first {
                cameraParams.append("ISO \(iso)")
            }
            if let focalLength = exif[kCGImagePropertyExifFocalLength] as? Double {
                cameraParams.append(String(format: "%.0fmm", focalLength))
            }
            if !cameraParams.isEmpty {
                pills.append(cameraParams.joined(separator: " · "))
            }

            // 拍摄时间
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let cleaned = dateStr.replacingOccurrences(of: ":", with: "-", range: dateStr.range(of: ":"))
                    .replacingOccurrences(of: ":", with: "-", range: dateStr.range(of: ":"))
                pills.append(cleaned)
            }
        }

        // 6. 相机机型
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !model.isEmpty {
                if !make.isEmpty && !model.lowercased().contains(make.lowercased()) {
                    pills.append("\(make) \(model)")
                } else {
                    pills.append(model)
                }
            }
        }

        return (hasDimensions, pills)
    }

    private func generateHTML(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "gif": mimeType = "image/gif"
        case "webp": mimeType = "image/webp"
        case "svg": mimeType = "image/svg+xml"
        case "bmp": mimeType = "image/bmp"
        case "ico": mimeType = "image/x-icon"
        case "tiff", "tif": mimeType = "image/tiff"
        case "heic": mimeType = "image/heic"
        case "heif": mimeType = "image/heif"
        case "avif": mimeType = "image/avif"
        case "icns": mimeType = "image/x-icns"
        default: mimeType = "image/\(ext)"
        }

        let imgSrc: String
        if let data = try? Data(contentsOf: url) {
            let base64 = data.base64EncodedString()
            imgSrc = "data:\(mimeType);base64,\(base64)"
        } else {
            let fileName = url.lastPathComponent
            imgSrc = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        }

        let meta = extractMetadata(from: url)
        var pillsHTML = ""
        for pill in meta.pills {
            let escapedPill = pill
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            pillsHTML += "<span class=\"pill\">\(escapedPill)</span>\n"
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            :root {
              --bg-color: #1e1e1e;
              --text-color: #a0a0a0;
              --pill-bg: rgba(255, 255, 255, 0.08);
              --pill-border: rgba(255, 255, 255, 0.08);
              --img-shadow: 0 12px 36px rgba(0, 0, 0, 0.45);
              --img-border: 1px solid rgba(255, 255, 255, 0.08);
            }
            @media (prefers-color-scheme: light) {
              :root {
                --bg-color: #f6f6f8;
                --text-color: #555555;
                --pill-bg: rgba(0, 0, 0, 0.04);
                --pill-border: rgba(0, 0, 0, 0.06);
                --img-shadow: 0 12px 36px rgba(0, 0, 0, 0.14);
                --img-border: 1px solid rgba(0, 0, 0, 0.06);
              }
            }
            * {
              box-sizing: border-box;
            }
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background-color: var(--bg-color);
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              user-select: none;
              -webkit-user-select: none;
            }
            .container {
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              width: 100%;
              height: 100%;
              padding: 24px;
            }
            .image-box {
              position: relative;
              display: flex;
              align-items: center;
              justify-content: center;
              max-width: 100%;
              max-height: calc(100% - 56px);
            }
            img {
              max-width: 100%;
              max-height: calc(100vh - 120px);
              object-fit: contain;
              display: block;
              border-radius: 8px;
              border: var(--img-border);
              box-shadow: var(--img-shadow);
            }
            .metadata {
              margin-top: 16px;
              display: flex;
              flex-wrap: wrap;
              gap: 8px;
              align-items: center;
              justify-content: center;
              max-width: 90%;
            }
            .pill {
              background: var(--pill-bg);
              color: var(--text-color);
              border: 1px solid var(--pill-border);
              padding: 3px 10px;
              border-radius: 6px;
              font-size: 11px;
              font-variant-numeric: tabular-nums;
              letter-spacing: 0.2px;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <div class="image-box">
              <img src="\(imgSrc)" alt="" id="previewImg" />
            </div>
            <div class="metadata" id="metadataContainer">
              \(pillsHTML)
            </div>
          </div>
          <script>
            const img = document.getElementById('previewImg');
            img.onload = function() {
              const hasDim = \(meta.hasDimensions);
              if (!hasDim && img.naturalWidth && img.naturalHeight) {
                const dimSpan = document.createElement('span');
                dimSpan.className = 'pill';
                dimSpan.textContent = img.naturalWidth + ' × ' + img.naturalHeight;
                const container = document.getElementById('metadataContainer');
                if (container) {
                  container.insertBefore(dimSpan, container.children[1] || null);
                }
              }
            };
          </script>
        </body>
        </html>
        """
    }
}
