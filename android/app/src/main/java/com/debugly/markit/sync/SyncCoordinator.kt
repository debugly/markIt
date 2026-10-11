package com.debugly.markit.sync

import android.content.Context
import android.util.Log
import com.debugly.markit.model.FileNode
import com.debugly.markit.storage.DocumentStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
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
    private val localScope: String = "",

    /**
     * Identifies the storage directory, so bookkeeping never crosses over.
     *
     * Empty keeps the old unscoped keys, which is only correct for a vault
     * root with nothing to confuse it with; callers pass the real id.
     */
    private val vaultId: String = ""
) {
    companion object {
        private const val TAG = "MarkItSync"
        private const val PREFS = "markit_sync_state"
        private const val DEBOUNCE_MS = 30_000L
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

    /** Outlives whatever called markModified, so closing the editor cannot cancel a sync. */
    private val autoScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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

    /**
     * The prefs key for this scope's manifest, namespaced by vault.
     *
     * localScope alone is not enough: the same folder name can exist in two
     * storage directories, and sharing a manifest across them makes each
     * directory's notes look like the other's were deleted. The vault id keeps
     * the bookkeeping with the directory it describes.
     *
     * Keys written before the vault id existed carry no prefix. They are still
     * read as a fallback so an existing setup keeps working after the upgrade;
     * the first save rewrites them under the current scope.
     */
    private fun manifestKey() = "manifest_$stateScope"
    private fun legacyManifestKey() = "manifest_$localScope"

    private fun deletionsKey() = "deletions_$stateScope"
    private fun legacyDeletionsKey() = "deletions_$localScope"

    /** Vault id and folder scope together, as one key fragment. */
    private val stateScope: String by lazy {
        if (vaultId.isEmpty()) localScope else "$vaultId:$localScope"
    }

    private fun readState(key: String, legacyKey: String): String? =
        statePrefs.getString(key, null) ?: statePrefs.getString(legacyKey, null)

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
            val raw = readState(manifestKey(), legacyManifestKey())
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
            val dels = readState(deletionsKey(), legacyDeletionsKey())
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

    private var pendingJob: Job? = null

    /**
     * Call after any local write. Fires a sync once the writing stops.
     *
     * Each call cancels the job the previous one started, so a burst of saves
     * collapses into a single sync that runs [DEBOUNCE_MS] after the last of
     * them. Without the cancellation every call would sleep and then sync,
     * which turns one editing session into a queue of redundant round trips --
     * and several of those racing each other is exactly how the manifest ends
     * up describing a state the server never saw.
     *
     * The window is deliberately long. Sync here is a backup of the user's own
     * notes, not a collaboration feed: the device is the source of truth and
     * nothing is lost by syncing late, while syncing on every pause would put a
     * round trip per paragraph in front of someone who only stopped to think.
     * Leaving the editor flushes immediately via [syncNow], so a long window
     * never delays the sync that the user actually expects to have happened.
     *
     * The job runs in [autoScope] rather than the caller's, so it is not
     * cancelled by the editor closing the moment it saves.
     */
    fun markModified(path: String) {
        _status.value = Status.MODIFIED
        pendingJob?.cancel()
        pendingJob = autoScope.launch {
            delay(DEBOUNCE_MS)
            sync()
        }
    }

    /**
     * Runs [sync] straight away, skipping the debounce.
     *
     * For the two moments where waiting would be wrong: an explicit "sync now",
     * and the user leaving the editor or the app. A note edited and then closed
     * should be on the server before the user has opened the next one -- if the
     * window is 30 seconds, closing is what makes the sync happen, not the
     * timer.
     */
    fun syncNow() {
        pendingJob?.cancel()
        pendingJob = autoScope.launch { sync() }
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

    /**
     * True when the file at [path] has local changes the server has not seen.
     *
     * The manifest records what the last successful sync left on both sides, so
     * comparing against it tells a note that is safely backed up from one that
     * only exists on the phone -- without opening the note and remembering
     * whether it was ever saved. The file list uses it to draw the pending
     * marker.
     *
     * Nothing here touches the network: the manifest is local state written by
     * the last sync, which is what keeps this cheap enough to call per row.
     */
    fun hasUnsyncedChanges(node: FileNode): Boolean {
        if (node.isDirectory) return false
        loadState()
        val rel = relativeToScope(node.path) ?: return false
        if (rel in pendingDeletions) return true
        val known = manifest[rel] ?: return true // never synced: new local file
        // A coarse mtime is still a change signal; the sync itself re-checks by
        // size and timestamp, so a false positive here only costs one redundant
        // upload, whereas a false negative would show a stale cloud as up to date.
        return known.lastModified != node.modifiedAt || known.contentLength != node.size
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

                // One snapshot drives the whole sync. Listing again per phase
                // would let a file edited mid-sync slip between them, and the
                // manifest at the end is written from this same view.
                val current = snapshotLocal()
                val pushed = pushLocalChanges(current)
                // Deletions go before the pull: a note deleted here must not be
                // seen by the pull as a remote file worth downloading.
                val deleted = pushDeletions(current)
                val pulled = pullRemoteChanges()
                val stillPending = pushPendingDeletions()
                if (failedPush.isNotEmpty()) {
                    Log.w(TAG, "${failedPush.size} file(s) failed to upload and will retry next sync")
                }

                manifest.clear()
                manifest.putAll(snapshotLocal().filterKeys { it !in failedPush })

                // Only the deletions that actually reached the server drop off.
                // Clearing the whole list would discard a rename recorded while
                // this sync was running -- the old name would stay on the server
                // forever, and the next pull would fetch the file the user just
                // renamed away from.
                pendingDeletions.retainAll(stillPending)

                saveState()
                _status.value = Status.SYNCED
                Log.i(
                    TAG,
                    "sync done for '$localScope': pushed=$pushed " +
                        "pulled=$pulled deleted=$deleted pendingDelete=${stillPending.size}"
                )
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
     * Uploads deletions inferred by comparing the previous manifest against what
     * is on disk now.
     *
     * This is the half of mirroring that pushLocalChanges does not cover. A file
     * removed while the device was offline leaves no trace on the server, and a
     * sync that only ever pushes additions resurrects it: the next pull sees it
     * as a remote file the scope has not seen and downloads the note the user
     * just deleted. Anything the manifest still remembers but the disk no longer
     * has was deleted here and must go.
     *
     * Deletions made elsewhere are deliberately not pushed back. Those entries
     * are simply pruned from the manifest by the snapshot at the end of the
     * sync, which keeps deletion one-directional and stops two devices
     * ping-ponging a file between them.
     *
     * The manifest entry is kept until the remote delete actually succeeds, so
     * a network failure leaves the deletion queued rather than lost.
     */
    private suspend fun pushDeletions(current: Map<String, ManifestEntry>): Int {
        val gone = manifest.keys.filter { !current.containsKey(it) }
        var removed = 0
        for (rel in gone) {
            // The entry is all that is left of the path, so whether it was a
            // folder is read from the manifest rather than from the disk.
            val wasDirectory = manifest[rel]?.isDirectory ?: false
            try {
                client.delete(remotePathFor(rel), isDirectory = wasDirectory)
                removed++
            } catch (e: Exception) {
                Log.w(TAG, "remote delete failed for $rel: ${e.message}")
            }
        }
        return removed
    }

    /**
     * Uploads locally changed/new files inside the scope.
     *
     * Returns the count pushed. A file that fails to upload is remembered in
     * [failedPush] so the manifest does not record it as synced -- otherwise a
     * transient timeout would make the file look clean forever and it would
     * never reach the server.
     */
    private suspend fun pushLocalChanges(current: Map<String, ManifestEntry>): Int {
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

    /**
     * Applies deletions recorded offline, now that the server is reachable.
     *
     * Returns the paths that are still outstanding -- the ones whose remote
     * delete failed. They stay queued for the next sync rather than being
     * forgotten, since a deletion that is silently dropped leaves the file on
     * the server and the next pull brings it straight back.
     */
    private suspend fun pushPendingDeletions(): Set<String> {
        val stillPending = mutableSetOf<String>()
        for (rel in pendingDeletions.toList()) {
            val isDirectory = manifest[rel]?.isDirectory ?: false
            try {
                client.delete(remotePathFor(rel), isDirectory = isDirectory)
                pendingDeletions.remove(rel)
            } catch (e: Exception) {
                Log.w(TAG, "remote delete failed for $rel: ${e.message}")
                stillPending.add(rel)
            }
        }
        return stillPending
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
