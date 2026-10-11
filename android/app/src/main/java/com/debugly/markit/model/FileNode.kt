package com.debugly.markit.model

/**
 * Ported from Sources/MarkItApp/Models/FileNode.swift. [path] is the
 * vault-relative POSIX path; on the Mac app it was a file URL.
 */
data class FileNode(
    val path: String,
    val isDirectory: Boolean,
    val frontMatter: JekyllFrontMatter? = null,
    val children: List<FileNode>? = null,
    val size: Long = 0,
    val modifiedAt: Long = 0
) {
    val name: String get() = path.substringAfterLast('/')
    val displayName: String get() = frontMatter?.title?.takeIf { it.isNotBlank() } ?: name
    val id: String get() = path
}

/** Jekyll/Hugo style `---` delimited front matter. */
data class JekyllFrontMatter(
    val title: String? = null,
    val date: String? = null,
    val tags: List<String>? = null,
    val categories: List<String>? = null,
    val layout: String? = null,
    val rawData: Map<String, String> = emptyMap()
)

object FrontMatterParser {
    private val dateFormats = listOf(
        "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"
    )

    /**
     * Returns null when [content] does not open with a `---` block. Values keep
     * their raw text in [JekyllFrontMatter.rawData] so unknown keys survive a
     * round trip -- the Mac app does the same and callers read rawData for
     * anything the typed fields do not cover.
     */
    fun parse(content: String): JekyllFrontMatter? {
        if (!content.startsWith("---")) return null
        val lines = content.split("\n")
        if (lines.size < 3) return null

        val raw = LinkedHashMap<String, String>()
        var title: String? = null
        var date: String? = null
        var tags: List<String>? = null
        var categories: List<String>? = null
        var layout: String? = null

        for (i in 1 until lines.size) {
            val line = lines[i].trim()
            if (line == "---") break
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val key = line.substring(0, colon).trim().lowercase()
            var value = line.substring(colon + 1).trim()
            if (value.length >= 2 &&
                ((value.startsWith("\"") && value.endsWith("\"")) ||
                 (value.startsWith("'") && value.endsWith("'")))) {
                value = value.substring(1, value.length - 1)
            }
            raw[key] = value
            when (key) {
                "title" -> title = value
                "date" -> date = value
                "tags" -> tags = parseList(value)
                "categories" -> categories = parseList(value)
                "layout" -> layout = value
            }
        }

        return JekyllFrontMatter(title, date, tags, categories, layout, raw)
    }

    private fun parseList(value: String): List<String> {
        val v = value.trim()
        if (v.startsWith("[") && v.endsWith("]")) {
            return v.removeSurrounding("[", "]")
                .split(",")
                .map { it.trim().trim('"', '\'', ' ') }
                .filter { it.isNotEmpty() }
        }
        if (v.startsWith("'") && v.endsWith("'")) {
            return v.removeSurrounding("'", "'")
                .split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }
        return if (v.isEmpty()) emptyList() else listOf(v)
    }
}
