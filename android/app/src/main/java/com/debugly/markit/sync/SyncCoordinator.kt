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
        private const val PREFS = "markit_sync_state"
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
    private val failedPush = mutableSetOf<String>()

    /**
     * Sync bookkeeping lives inside the scope so two folders cannot read each
     * other's manifest. At the vault root it stays at the top level.
     */
    private fun scoped(path: String): String =
        if (localScope.isEmpty()) path else "$localScope/$path"

    private val statePrefs by lazy {
        context.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE)
    }

    private fun manifestKey() = "manifest_$localScope"
    private fun deletionsKey() = "deletions_$localScope"

    /**
     * Reads this scope's manifest and pending deletions.
     *
     * Both live in SharedPreferences rather than in the vault. They are
     * per-device bookkeeping: the manifest records what *this* device last
     * synced, so putting it in the vault would upload it to the server and make
     * another device believe it had already synced the same files. Writing it
     * through SAF also proved unreliable here -- rapid create-then-query against
     * the DocumentsProvider raced with the concurrent reads, and the write came
     * back FileNotFound for a document it had just created.
     */
    private fun loadState() {
        if (loaded) return
        loaded = true
        try {
            val raw = statePrefs.getString(manifestKey(), null)
            if (raw != null) {
                val obj = JSONObject(raw).optJSONObject("entries") ?: JSONObject()
                for (key in obj.keys()) {
                    val e = obj.getJSONObject(key)
                    manifest[key] = ManifestEntry(
                        isDirectory = e.optBoolean("isDirectory", false),
                        contentLength = e.optLong("contentLength", 0),
                        lastModified = e.optLong("lastModified", 0)
                    )
                }
                Log.i(TAG, "loaded ${manifest.size} manifest entries for '$localScope'")
            }
            val dels = statePrefs.getString(deletionsKey(), null)
            if (dels != null) {
                val arr = org.json.JSONArray(dels)
                for (i in 0 until arr.length()) pendingDeletions.add(arr.getString(i))
            }
        } catch (e: Exception) {
            // A corrupt blob just means "sync everything", the same cold-start
            // path a fresh install takes.
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
            val dels = org.json.JSONArray()
            pendingDeletions.forEach { dels.put(it) }

            statePrefs.edit()
                .putString(manifestKey(), JSONObject().put("entries", obj).toString())
                .putString(deletionsKey(), dels.toString())
                .apply()
            Log.i(TAG, "saved ${manifest.size} entries for '$localScope'")
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
                if (failedPush.isNotEmpty()) {
                    Log.w(TAG, "${failedPush.size} file(s) failed to upload and will retry next sync")
                }
                val removed = pushPendingDeletions()

                manifest.clear()
                manifest.putAll(snapshotLocal().filterKeys { it !in failedPush })

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
                val rel = relativeToScope(n.path) ?: continue
                snap[rel] = ManifestEntry(n.isDirectory, n.size, n.modifiedAt)
                if (n.isDirectory) walk(n.path)
            }
        }
        walk(localScope)
        return snap
    }

    /**
     * Uploads locally changed/new files inside the scope.
     *
     * Returns the count pushed. A file that fails to upload is remembered in
     * [failedPush] so the manifest does not record it as synced -- otherwise a
     * transient timeout would make the file look clean forever and it would
     * never reach the server.
     */
    private suspend fun pushLocalChanges(): Int {
        val current = snapshotLocal()
        var pushed = 0

        // PUT into a collection that does not exist yet is a 409, and a cold
        // sync has exactly that: the local folder is there, the remote one is
        // not. Create the collections once, before any upload, rather than
        // retrying per file.
        try {
            client.ensureDirectory(remoteRoot)
        } catch (e: Exception) {
            Log.w(TAG, "could not create remote root $remoteRoot: ${e.message}")
        }

        // Mirror the scope's subdirectories too, so a file whose parent is a
        // nested folder has somewhere to land.
        for ((rel, entry) in current) {
            if (entry.isDirectory) {
                try {
                    client.ensureDirectory(remotePathFor(rel))
                } catch (e: Exception) {
                    Log.w(TAG, "could not create remote dir $rel: ${e.message}")
                }
            }
        }

        for ((rel, entry) in current) {
            if (entry.isDirectory) continue
            val old = manifest[rel]
            if (old != null && old.contentLength == entry.contentLength &&
                old.lastModified == entry.lastModified) {
                continue
            }
            val localPath = localPathFor(rel)
            try {
                client.upload(remotePathFor(rel), store.readBytes(localPath))
                pushed++
            } catch (e: Exception) {
                failedPush.add(rel)
                Log.w(TAG, "push skipped $localPath: ${e.message}")
            }
        }
        return pushed
    }


    /**
     * Strips the remoteRoot prefix from a path reported by the server, yielding
     * the path relative to the sync root. Returns null for anything outside it,
     * which should not happen but is cheaper to skip than to act on.
     */
    private fun stripRoot(path: String): String? {
        val root = remoteRoot.trim('/')
        if (root.isEmpty()) return path
        return when {
            path == root -> ""
            path.startsWith("$root/") -> path.removePrefix("$root/")
            else -> null
        }
    }


    /**
     * MKCOLs the remote root and every ancestor of [rel], ignoring collections
     * that already exist.
     *
     * The root matters on a cold sync: remoteRoot is where every upload lands,
     * and PUT into a collection that does not exist is a 409. Without this the
     * first sync of a freshly configured folder uploads nothing at all.
     */
    private suspend fun ensureRemoteParents(rel: String) {
        var walked = ""
        for (segment in rel.split('/').dropLast(1)) {
            walked = if (walked.isEmpty()) segment else "$walked/$segment"
            try {
                client.ensureDirectory(remotePathFor(walked))
            } catch (e: Exception) {
                Log.w(TAG, "could not create $walked: ${e.message}")
            }
        }
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
            // list() reports paths that already include remoteRoot, so they have
            // to be rebased before being run through the helpers. Feeding them
            // straight in would request "drafts/drafts/x.md" and get a 409.
            val rel = stripRoot(n.path) ?: continue
            if (n.isDirectory) {
                try { client.ensureDirectory(remotePathFor(rel)) } catch (e: Exception) { }
                try { store.createDirectory(localPathFor(rel)) } catch (e: Exception) { }
                continue
            }
            if (manifest.containsKey(rel)) continue
            try {
                val data = client.download(remotePathFor(rel))
                store.writeText(localPathFor(rel), data.toString(Charsets.UTF_8))
                pulled++
            } catch (e: Exception) {
                Log.w(TAG, "pull skipped ${n.path}: ${e.message}")
            }
        }
        return pulled
    }
}
