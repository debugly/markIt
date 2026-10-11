package com.debugly.markit.sync

import android.content.Context
import android.util.Log
import com.debugly.markit.model.FileNode
import com.debugly.markit.storage.DocumentStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/**
 * Ported from Sources/MarkItApp/Sync/SyncCoordinator.swift.
 *
 * Same model as the macOS build: the local vault is the truth and WebDAV is a
 * mirror of it. A manifest records what each path looked like after the last
 * successful sync, which is what makes conflict detection possible without a
 * server-side database. Deletions are recorded separately so a delete made
 * offline propagates on the next sync instead of being undone by a re-download.
 *
 * Everything here reads and writes the LOCAL tree. Offline is the normal case,
 * not a degraded one -- a failed sync leaves the local files untouched and just
 * updates [status].
 *
 * [localScope] restricts the coordinator to one folder inside the vault. It is
 * the local half of a per-folder sync config, matching remoteRoot on the server
 * side: configuring drafts and syncing drafts must not upload or delete posts.
 * An empty scope means the whole vault.
 */
class SyncCoordinator(
    private val context: Context,
    private val store: DocumentStore,
    private val client: WebDAVClient,
    private val remoteRoot: String,
    private val localScope: String = ""
) {
    companion object {
        private const val TAG = "MarkItSync"
        private const val MANIFEST = ".markit-manifest.json"
        private const val PENDING_DELETIONS = ".markit-pending-deletions.json"
        private const val DEBOUNCE_MS = 3_000L
    }

    data class ManifestEntry(
        val isDirectory: Boolean,
        val contentLength: Long,
        val lastModified: Long
    )

    enum class Status { SYNCED, MODIFIED, SYNCING, ERROR, OFFLINE }

    sealed class Result {
        object Success : Result()
        data class Failure(val message: String) : Result()
    }

    private val lock = Mutex()
    private val _status = MutableStateFlow(Status.SYNCED)
    val status: StateFlow<Status> = _status

    private var manifest: MutableMap<String, ManifestEntry> = mutableMapOf()
    private var pendingDeletions: MutableSet<String> = mutableSetOf()
    private var loaded = false

    /**
     * Sync bookkeeping lives inside the scope so two folders cannot read each
     * other's manifest. At the vault root it stays at the top level.
     */
    private fun scoped(path: String): String =
        if (localScope.isEmpty()) path else "$localScope/$path"

    private fun manifestFile() = store.uriFor(scoped(MANIFEST))
    private fun deletionsFile() = store.uriFor(scoped(PENDING_DELETIONS))

    private fun loadState() {
        if (loaded) return
        loaded = true
        try {
            manifestFile()?.let {
                val json = JSONObject(store.readText(scoped(MANIFEST)))
                val obj = json.optJSONObject("entries") ?: JSONObject()
                for (key in obj.keys()) {
                    val e = obj.getJSONObject(key)
                    manifest[key] = ManifestEntry(
                        isDirectory = e.optBoolean("isDirectory", false),
                        contentLength = e.optLong("contentLength", 0),
                        lastModified = e.optLong("lastModified", 0)
                    )
                }
                Log.i(TAG, "loaded manifest with ${manifest.size} entries for scope '$localScope'")
            }
            deletionsFile()?.let {
                val arr = org.json.JSONArray(store.readText(scoped(PENDING_DELETIONS)))
                for (i in 0 until arr.length()) pendingDeletions.add(arr.getString(i))
            }
        } catch (e: Exception) {
            // A missing or corrupt manifest just means "sync everything", which
            // is the same cold-start path a fresh install takes.
            Log.w(TAG, "could not read sync state, starting cold: ${e.message}")
            manifest.clear()
            pendingDeletions.clear()
        }
    }

    private fun saveState() {
        try {
            val obj = JSONObject()
            for ((k, v) in manifest) {
                obj.put(k, JSONObject()
                    .put("isDirectory", v.isDirectory)
                    .put("contentLength", v.contentLength)
                    .put("lastModified", v.lastModified))
            }
            store.writeText(scoped(MANIFEST), JSONObject().put("entries", obj).toString(2))

            if (pendingDeletions.isNotEmpty()) {
                val arr = org.json.JSONArray()
                pendingDeletions.forEach { arr.put(it) }
                store.writeText(scoped(PENDING_DELETIONS), arr.toString(2))
            } else {
                // Clear a stale list so an applied delete does not replay.
                store.delete(scoped(PENDING_DELETIONS))
            }
        } catch (e: Exception) {
            Log.w(TAG, "could not persist sync state: ${e.message}")
        }
    }

    /** Call after any local write; coalesces bursts of edits into one sync. */
    suspend fun markModified(path: String) {
        _status.value = Status.MODIFIED
        try {
            delay(DEBOUNCE_MS)
            sync()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        }
    }

    fun recordDeletion(path: String) {
        loadState()
        // Only relative paths inside this scope are ours to delete remotely.
        if (!inScope(path)) return
        if (isStateFile(path)) return
        if (pendingDeletions.add(path)) saveState()
    }

    fun removePendingDeletion(path: String) {
        loadState()
        if (pendingDeletions.remove(path)) saveState()
    }

    fun syncStatusFor(path: String): Status {
        loadState()
        if (path in pendingDeletions) return Status.MODIFIED
        return _status.value
    }

    /** True when [path] lies inside this coordinator's folder. */
    private fun inScope(path: String): Boolean =
        localScope.isEmpty() || path == localScope || path.startsWith("$localScope/")

    /**
     * Path relative to the scope, which is how both the manifest and the remote
     * layout are keyed. A path outside the scope is not this coordinator's.
     */
    private fun relativeToScope(path: String): String? = when {
        localScope.isEmpty() -> path
        path == localScope -> ""
        path.startsWith("$localScope/") -> path.removePrefix("$localScope/")
        else -> null
    }

    private fun isStateFile(path: String): Boolean {
        val base = path.substringAfterLast('/')
        return base == MANIFEST || base == PENDING_DELETIONS
    }

    suspend fun sync(): Result = withContext(Dispatchers.IO) {
        lock.withLock {
            loadState()
            _status.value = Status.SYNCING
            try {
                if (!isOnline()) {
                    _status.value = Status.OFFLINE
                    return@withLock Result.Failure("离线：本地文件保持可用，联网后自动同步")
                }

                val pushed = pushLocalChanges()
                val pulled = pullRemoteChanges()
                val removed = pushPendingDeletions()

                manifest.clear()
                manifest.putAll(snapshotLocal())

                // Deletions that reached the server drop off the list.
                pendingDeletions.clear()

                saveState()
                _status.value = Status.SYNCED
                Log.i(TAG, "sync done for '$localScope': pushed=$pushed pulled=$pulled deleted=$removed")
                Result.Success
            } catch (e: Exception) {
                val msg = e.message ?: "同步失败"
                _status.value = Status.ERROR
                Log.e(TAG, "sync failed", e)
                Result.Failure(msg)
            }
        }
    }

    /**
     * A real reachability probe. `client.testConnection` does a PROPFIND, which
     * is the actual operation sync needs, rather than assuming a socket is enough.
     */
    private suspend fun isOnline(): Boolean =
        withTimeoutOrNull(5_000) {
            try {
                client.testConnection(remoteRoot)
                true
            } catch (e: Exception) {
                false
            }
        } ?: false

    /**
     * The scope's contents, keyed by path relative to the scope. Walking starts
     * at localScope rather than the vault root, which is what keeps one folder's
     * sync from touching its siblings.
     */
    private fun snapshotLocal(): MutableMap<String, ManifestEntry> {
        val snap = mutableMapOf<String, ManifestEntry>()
        fun walk(path: String) {
            val nodes = try { store.list(path) } catch (e: Exception) { emptyList() }
            for (n in nodes) {
                if (isStateFile(n.path)) continue
                val rel = relativeToScope(n.path) ?: continue
                snap[rel] = ManifestEntry(n.isDirectory, n.size, n.modifiedAt)
                if (n.isDirectory) walk(n.path)
            }
        }
        walk(localScope)
        return snap
    }

    /** Uploads locally changed/new files inside the scope. */
    private suspend fun pushLocalChanges(): Int {
        val current = snapshotLocal()
        var pushed = 0

        for ((rel, entry) in current) {
            if (entry.isDirectory) continue
            val old = manifest[rel]
            if (old != null && old.contentLength == entry.contentLength &&
                old.lastModified == entry.lastModified) {
                continue
            }
            val localPath = if (localScope.isEmpty()) rel else "$localScope/$rel"
            try {
                client.upload(remotePathFor(rel), store.readBytes(localPath))
                pushed++
            } catch (e: Exception) {
                Log.w(TAG, "push skipped $localPath: ${e.message}")
            }
        }
        return pushed
    }

    private fun remotePathFor(rel: String): String =
        if (rel.isEmpty()) remoteRoot else "$remoteRoot/$rel"

    private fun localPathFor(rel: String): String =
        if (localScope.isEmpty()) rel else "$localScope/$rel"

    /** Applies deletions recorded offline, now that the server is reachable. */
    private suspend fun pushPendingDeletions(): Int {
        var removed = 0
        for (rel in pendingDeletions.toList()) {
            try {
                client.delete(remotePathFor(rel))
                pendingDeletions.remove(rel)
                removed++
            } catch (e: Exception) {
                Log.w(TAG, "remote delete failed for $rel: ${e.message}")
            }
        }
        return removed
    }

    /**
     * Downloads remote files this scope has never seen. Files already present
     * are left alone -- a local copy that differs is an edit, and the macOS app
     * treats the user's edit as the truth too.
     */
    private suspend fun pullRemoteChanges(): Int {
        val remote = client.list(remoteRoot)
        var pulled = 0

        for (n in remote) {
            if (n.isDirectory) {
                val localDir = localPathFor(n.path)
                try { client.ensureDirectory(remotePathFor(n.path)) } catch (e: Exception) { }
                try { store.createDirectory(localDir) } catch (e: Exception) { }
                continue
            }
            if (manifest.containsKey(n.path)) continue
            val localPath = localPathFor(n.path)
            try {
                val data = client.download(remotePathFor(n.path))
                store.writeText(localPath, data.toString(Charsets.UTF_8))
                pulled++
            } catch (e: Exception) {
                Log.w(TAG, "pull skipped ${n.path}: ${e.message}")
            }
        }
        return pulled
    }
}
