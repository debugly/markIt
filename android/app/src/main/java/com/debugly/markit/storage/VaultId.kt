package com.debugly.markit.storage

import android.content.Context
import android.net.Uri
import java.security.MessageDigest

/**
 * A stable name for the directory MarkIt is attached to.
 *
 * Folder names repeat across directories, so anything keyed by folder name --
 * the sync configuration, the manifest -- has to say which directory it means.
 * The id is derived from the SAF tree URI, which is the one value that changes
 * exactly when the directory does.
 *
 * Hashed rather than stored raw. The URI carries the user's home directory and
 * folder names, and this id ends up as a SharedPreferences *key*, where it
 * would be readable in a plain-text backup. A digest says the same thing
 * without writing their paths to disk.
 *
 * Shortened because it is a key prefix, not a security boundary; the full
 * SHA-256 is far more than enough to keep two directories apart.
 */
object VaultId {

    private const val PREFS = "markit"

    /** The id for the directory currently attached, or "" before one is. */
    fun current(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("tree_uri", null)
            ?.let { of(it) }
            .orEmpty()

    fun of(treeUri: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(treeUri.toByteArray())
        return digest.take(8).joinToString("") { "%02x".format(it) }
    }

    fun of(treeUri: Uri): String = of(treeUri.toString())
}
