import Foundation
import UniformTypeIdentifiers

enum SupportedFileType: Equatable {
    case markdown
    case html
    case text
    case image
    case other

    // MARK: - 白名单定义

    /// Markdown 文件白名单
    static let markdownExtensions: Set<String> = [
        "md", "markdown"
    ]

    /// HTML 网页白名单
    static let htmlExtensions: Set<String> = [
        "html", "htm", "xhtml"
    ]

    /// 图片类型白名单（浏览器与系统均能稳定作为图片预览）
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico",
        "tiff", "tif", "heic", "heif", "avif", "icns"
    ]

    /// 文本类型白名单（严格限制纯文本/代码，排除 .ts 等与音视频流冲突的后缀）
    static let textExtensions: Set<String> = [
        // 纯文本与文档
        "txt", "text", "log", "csv", "tsv", "diff", "patch",
        // 配置文件与数据
        "json", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "plist", "properties",
        // 样式文件
        "css", "scss", "sass", "less",
        // 源代码与脚本（严格排除 ts，避免与 MPEG-TS 视频流冲突）
        "js", "jsx", "tsx", "mjs", "cjs",
        "swift", "c", "h", "cpp", "hpp", "cc", "cxx", "m", "mm",
        "py", "rb", "go", "rs", "java", "kt", "kts",
        "sh", "bash", "zsh", "fish", "sql", "lua", "r", "dart",
        "php", "scala", "clj", "cljs", "elixir", "ex", "exs", "erl", "hrl", "hs", "lhs",
        "vue", "svelte", "graphql", "gql", "proto", "gradle"
    ]

    /// 常见无后缀纯文本文件名白名单
    static let textFilenames: Set<String> = [
        "dockerfile", "makefile", "podfile", "gemfile", "license", "readme"
    ]

    static func detect(url: URL) -> SupportedFileType {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        // 1. Markdown 白名单
        if markdownExtensions.contains(ext) {
            return .markdown
        }

        // 2. HTML 白名单
        if htmlExtensions.contains(ext) {
            return .html
        }

        // 3. 图片白名单
        if imageExtensions.contains(ext) {
            return .image
        }

        // 4. 文本白名单（含特定无后缀文本文件）
        if textExtensions.contains(ext) || textFilenames.contains(filename) {
            return .text
        }

        // 其余未知或不确定类型一律按外部文件处理
        return .other
    }

    static func formattedFileSize(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    static func localizedTypeDescription(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let desc = utType.localizedDescription {
            return desc
        }
        if ext.isEmpty {
            return "文件"
        }
        return "\(ext.uppercased()) 文件"
    }
}
