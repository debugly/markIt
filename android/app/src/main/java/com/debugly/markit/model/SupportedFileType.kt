package com.debugly.markit.model

import java.util.Locale

/**
 * Ported from Sources/MarkItApp/Models/SupportedFileType.swift.
 * The extension whitelists are deliberately identical to the Mac app so the
 * same vault shows the same icons and the same "open externally" behaviour on
 * both platforms.
 */
enum class SupportedFileType {
    MARKDOWN, HTML, TEXT, IMAGE, OTHER;

    companion object {
        private val markdownExtensions = setOf("md", "markdown")
        private val htmlExtensions = setOf("html", "htm", "xhtml")
        private val imageExtensions = setOf(
            "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico",
            "tiff", "tif", "heic", "heif", "avif", "icns"
        )
        // Strictly excludes .ts so it cannot be confused with an MPEG-TS stream,
        // same reasoning as the Swift version.
        private val textExtensions = setOf(
            "txt", "text", "log", "csv", "tsv", "diff", "patch",
            "json", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "plist", "properties",
            "css", "scss", "sass", "less",
            "js", "jsx", "tsx", "mjs", "cjs",
            "swift", "c", "h", "cpp", "hpp", "cc", "cxx", "m", "mm",
            "py", "rb", "go", "rs", "java", "kt", "kts",
            "sh", "bash", "zsh", "fish", "sql", "lua", "r", "dart",
            "php", "scala", "clj", "cljs", "elixir", "ex", "exs", "erl", "hrl", "hs", "lhs",
            "vue", "svelte", "graphql", "gql", "proto", "gradle"
        )
        private val textFilenames = setOf(
            "dockerfile", "makefile", "podfile", "gemfile", "license", "readme"
        )

        fun detect(fileName: String): SupportedFileType {
            val lower = fileName.lowercase(Locale.ROOT)
            val ext = lower.substringAfterLast('.', "")
            val base = if ('.' in lower) lower.substringBeforeLast('.') else lower

            if (ext in markdownExtensions) return MARKDOWN
            if (ext in htmlExtensions) return HTML
            if (ext in imageExtensions) return IMAGE
            if (ext in textExtensions || base in textFilenames) return TEXT
            return OTHER
        }

        fun formattedFileSize(bytes: Long): String {
            if (bytes < 1024) return "$bytes B"
            val kb = bytes / 1024.0
            if (kb < 1024) return String.format(Locale.ROOT, "%.1f KB", kb)
            val mb = kb / 1024.0
            if (mb < 1024) return String.format(Locale.ROOT, "%.1f MB", mb)
            return String.format(Locale.ROOT, "%.1f GB", mb / 1024.0)
        }
    }
}
