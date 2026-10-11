package com.debugly.markit.ui

import android.content.Context
import com.debugly.markit.storage.DocumentStore
import org.json.JSONArray

/**
 * The notes the user opened most recently, newest first.
 *
 * Mirrors the Mac client's recent-files list so the two behave the same: the
 * same cap, the same newest-first order, and the same rule that a file already
 * in the list keeps its position rather than jumping to the top.
 *
 * Paths are stored, not URIs. A URI from a previous SAF grant stops resolving
 * once the user revokes access to the vault, so a URI-based list accumulates
 * entries that quietly fail to open. Re-resolving from the vault path each time
 * means a revoked grant drops out of the list instead of sitting there.
 */
class RecentFiles(context: Context) {

    private val prefs = context.getSharedPreferences("markit_recent", Context.MODE_PRIVATE)

    /** Vault-relative paths, newest first, capped at [LIMIT]. */
    fun paths(): List<String> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getString(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Records [path] as the most recently opened file.
     *
     * A file already in the list keeps its original position, matching the Mac
     * client. Reopening the same note repeatedly should not shuffle the list --
     * the order is there to answer "what was I just looking at", and that
     * answer is already correct.
     */
    fun record(path: String) {
        val current = paths().toMutableList()
        if (current.remove(path)) return
        current.add(0, path)
        while (current.size > LIMIT) current.removeAt(current.size - 1)
        save(current)
    }

    fun remove(path: String) {
        val current = paths()
        if (!current.contains(path)) return
        save(current.filter { it != path })
    }

    fun clear() {
        prefs.edit().remove(KEY).apply()
    }

    /**
     * The stored paths that still resolve to a file in the vault.
     *
     * A note deleted or renamed elsewhere leaves a path behind; showing it would
     * offer a row that cannot be opened, so entries that no longer resolve are
     * dropped and the stored list is rewritten to match.
     */
    fun resolvable(store: DocumentStore): List<String> =
        paths().filter { store.exists(it) && !store.isDirectory(it) }

    private fun save(list: List<String>) {
        val arr = JSONArray()
        list.forEach { arr.put(it) }
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    private companion object {
        const val KEY = "recent_paths"
        const val LIMIT = 10
    }
}
