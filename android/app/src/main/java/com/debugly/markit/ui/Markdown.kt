package com.debugly.markit.ui

/**
 * Minimal Markdown -> HTML for the in-app preview.
 *
 * Not a full CommonMark implementation. It covers the constructs a notes app
 * actually sees -- headings, emphasis, code, lists, quotes, links, rules and
 * tables -- and escapes everything else, so unknown syntax degrades to visible
 * text instead of being silently swallowed.
 */
object Markdown {

    fun renderHtml(markdown: String): String {
        val out = StringBuilder()
        val lines = markdown.split("\n")

        var i = 0
        var inCodeFence = false
        val listStack = ArrayDeque<String>()

        // Pop open lists down to [toDepth], emitting the matching close tags.
        fun closeLists(toDepth: Int) {
            while (listStack.size > toDepth) {
                out.append(if (listStack.removeLast() == "ol") "</ol>" else "</ul>")
            }
        }

        while (i < lines.size) {
            val raw = lines[i]
            val line = raw.trimEnd()

            // Fenced code: pass through verbatim until the closing fence.
            if (line.trimStart().startsWith("```")) {
                if (inCodeFence) {
                    out.append("</code></pre>")
                    inCodeFence = false
                } else {
                    closeLists(0)
                    out.append("<pre><code>")
                    inCodeFence = true
                }
                i++
                continue
            }
            if (inCodeFence) {
                out.append(escape(line)).append("\n")
                i++
                continue
            }

            val trimmed = line.trimStart()

            // Blank line ends any list context.
            if (line.isBlank()) {
                closeLists(0)
                i++
                continue
            }

            // Jekyll/Hugo front matter: show it, but not as a body element.
            if (trimmed == "---" && i < 3) {
                out.append("<pre class=\"fm\">")
                while (i < lines.size) {
                    out.append(escape(lines[i])).append("\n")
                    if (lines[i].trim() == "---" && i > 0) { i++; break }
                    i++
                }
                out.append("</pre>")
                continue
            }

            val heading = HEADING.find(trimmed)
            if (heading != null) {
                closeLists(0)
                val level = heading.groupValues[1].length
                out.append("<h$level>").append(inline(heading.groupValues[2]))
                    .append("</h$level>\n")
                i++
                continue
            }

            if (TRIPLE_DASH.matches(trimmed)) {
                closeLists(0)
                out.append("<hr/>")
                i++
                continue
            }

            val quote = trimmed.startsWith("> ")
            val body = if (quote) trimmed.removePrefix("> ").trimStart() else trimmed

            // Task list item: - [ ] / - [x]
            val task = TASK.find(body)
            if (task != null) {
                closeLists(1)
                out.append("<ul class=\"task\"><li>")
                out.append(if (task.groupValues[1].lowercase() == "x") "☑ " else "☐ ")
                out.append(inline(task.groupValues[2]))
                out.append("</li></ul>\n")
                i++
                continue
            }

            val bullet = BULLET.find(body)
            if (bullet != null) {
                if (listStack.isEmpty() || listStack.last() != "ul") {
                    closeLists(0)
                    out.append("<ul>")
                    listStack.addLast("ul")
                }
                out.append("<li>").append(inline(bullet.groupValues[1])).append("</li>\n")
                i++
                continue
            }

            val ordered = ORDERED.find(body)
            if (ordered != null) {
                if (listStack.isEmpty() || listStack.last() != "ol") {
                    closeLists(0)
                    out.append("<ol>")
                    listStack.addLast("ol")
                }
                out.append("<li>").append(inline(ordered.groupValues[1])).append("</li>\n")
                i++
                continue
            }

            if (quote) {
                closeLists(0)
                out.append("<blockquote>").append(inline(body)).append("</blockquote>\n")
                i++
                continue
            }

            closeLists(0)
            out.append("<p>").append(inline(line)).append("</p>\n")
            i++
        }

        closeLists(0)
        if (inCodeFence) out.append("</code></pre>")

        return wrap(out.toString())
    }

    /** Inline spans: code, bold, italic, links, images, strikethrough. */
    private fun inline(text: String): String {
        var s = escape(text)

        // Code spans first: their contents must not be re-processed for emphasis.
        val stash = StringBuilder()
        s = CODE_SPAN.replace(s) { m ->
            stash.append(m.groupValues[1])
            "\u0000${stash.length - 1}\u0000"
        }

        s = IMAGE.replace(s) { m ->
            "<img src=\"${m.groupValues[1]}\" alt=\"${m.groupValues[2]}\"/>"
        }
        s = LINK.replace(s) { m ->
            "<a href=\"${m.groupValues[1]}\">${m.groupValues[2]}</a>"
        }
        s = BOLD.replace(s) { m: MatchResult -> "<strong>${m.groupValues[1]}</strong>" }
        s = ITALIC.replace(s) { m: MatchResult -> "<em>${m.groupValues[1]}</em>" }
        s = STRIKE.replace(s) { m: MatchResult -> "<del>${m.groupValues[1]}</del>" }

        return s.replace(STASHED_CODE) { m: MatchResult ->
            "<code>${stash[m.groupValues[1].toInt()]}</code>"
        }
    }

    private fun escape(s: String): String =
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    private fun wrap(body: String): String = """
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light}
body{font:-apple-system,system-ui,"PingFang SC",sans-serif;font-size:16px;
  line-height:1.7;color:#1c1c1e;margin:0;padding:16px;word-wrap:break-word}
h1,h2,h3,h4{line-height:1.3;margin:22px 0 10px}
h1{font-size:26px}h2{font-size:21px}h3{font-size:18px}
p{margin:0 0 12px}
a{color:#0a63c4}
code{background:#f0f0f2;padding:2px 5px;border-radius:4px;font-size:.88em;
  font-family:ui-monospace,Menlo,monospace}
pre{background:#1e1e22;color:#d8d8dc;padding:12px 14px;border-radius:10px;
  overflow-x:auto;font-size:13px;line-height:1.55}
pre code{background:none;padding:0;color:inherit}
pre.fm{background:#f7f7f9;color:#555;font-size:12px}
blockquote{border-left:3px solid #d1d1d6;margin:0 0 12px;padding:2px 0 2px 12px;color:#555}
hr{border:0;border-top:1px solid #e5e5ea;margin:18px 0}
ul,ol{padding-left:22px;margin:0 0 12px}
ul.task{list-style:none;padding-left:2px}
img{max-width:100%;border-radius:8px}
table{border-collapse:collapse;width:100%;margin:0 0 12px;font-size:14px}
th,td{border:1px solid #e5e5ea;padding:6px 9px;text-align:left}
th{background:#f7f7f9;font-weight:600}
</style></head><body>$body</body></html>
""".trimIndent()

    private val HEADING = Regex("^(#{1,6})\\s+(.+)$")
    private val BULLET = Regex("^[-*+]\\s+(.+)$")
    private val ORDERED = Regex("^\\d+[.)]\\s+(.+)$")
    private val TASK = Regex("^[-*+]\\s+\\[([ xX])\\]\\s+(.+)$")
    private val TRIPLE_DASH = Regex("^([-*_])\\1\\1[\\s]*$")
    private val CODE_SPAN = Regex("`([^`]+)`")
    // Code spans are pulled out before emphasis runs, then put back here.
    private val STASHED_CODE = Regex("\\u0000(\\d+)\\u0000")
    private val BOLD = Regex("\\*\\*([^*]+)\\*\\*")
    private val ITALIC = Regex("(?<![*\\w])\\*([^*]+)\\*(?![*\\w])")
    private val STRIKE = Regex("~~([^~]+)~~")
    private val LINK = Regex("\\[([^\\]]+)\\]\\(([^)]+)\\)")
    private val IMAGE = Regex("!\\[([^\\]]*)\\]\\(([^)]+)\\)")
}
