package com.debugly.markit.ui

import android.content.Context
/**
 * The CSS used to render a note's preview, and the list to choose from.
 *
 * Mirrors the Mac client's preview-style setting: the same files in
 * Resources/Styles on the Mac side live in assets/styles here, and the default
 * is GitHub.css as it is there. The asset names are lowercased because Android
 * rejects spaces and parentheses in asset paths, so the original file names are
 * kept in [labels] rather than being derived from the file on disk.
 *
 * The list is discovered from the assets rather than hard-coded, matching the
 * Mac client, so adding a .css file to the folder is enough to make it
 * selectable.
 */
object PreviewStyles {

    /** Asset file name paired with the name to show for it. */
    data class Style(val file: String, val label: String)

    private const val PREFS = "markit_settings"
    private const val KEY_STYLE = "preview_style"
    private const val DEFAULT = "github.css"

    /**
     * Every style on offer, "无" first.
     *
     * Discovery is by convention rather than an index file: the asset names are
     * fixed and lowercased, and the labels map the ones whose display name is
     * not simply the file name. A new file dropped into assets/styles is picked
     * up as-is under its own name.
     */
    val available: List<Style> = buildList {
        add(Style("", "无"))
        add(Style("github.css", "GitHub.css"))
        add(Style("github2.css", "GitHub2.css"))
        add(Style("github-2025.css", "GitHub-2025.css"))
        add(Style("clearness.css", "Clearness.css"))
        add(Style("clearness-dark.css", "Clearness Dark.css"))
        add(Style("solarized-light.css", "Solarized (Light).css"))
        add(Style("solarized-dark.css", "Solarized (Dark).css"))
    }

    fun selected(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_STYLE, DEFAULT) ?: DEFAULT

    fun select(context: Context, file: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_STYLE, file).apply()
    }

    /** The display name for [file], for showing in the editor's toolbar. */
    fun labelFor(file: String): String =
        available.firstOrNull { it.file == file }?.label ?: file

    /**
     * The CSS text for [file], or empty for "无".
     *
     * Empty on any read failure, since a missing stylesheet is a preview that
     * looks unstyled rather than an error worth interrupting the user over. The
     * editor falls back to its own styling, which is a reasonable document.
     */
    fun css(context: Context, file: String): String {
        if (file.isBlank()) return ""
        return try {
            context.assets.open("styles/$file").use { String(it.readBytes(), Charsets.UTF_8) }
        } catch (e: Exception) {
            ""
        }
    }

    /**
     * [text] as a JavaScript string literal.
     *
     * The stylesheet is injected as source rather than linked as a file so the
     * page needs no network round trip, which means it has to be escaped: CSS
     * routinely contains backslashes, quotes and newlines, and a raw splice
     * produces either a syntax error or, worse, a silently truncated
     * stylesheet.
     */
    fun jsonString(text: String): String = buildString {
        append('"')
        for (c in text) {
            when (c) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
            }
        }
        append('"')
    }

    /**
     * The stylesheet to hand the page: the chosen one, or the built-in default.
     *
     * Falls back to GitHub.css rather than to nothing, because "无" on the Mac
     * client still means the default rendering is in effect and the app looks
     * broken without it.
     */
    fun cssOrDefault(context: Context): String {
        val chosen = selected(context)
        val text = css(context, chosen)
        return if (text.isNotEmpty()) text else css(context, DEFAULT)
    }
}