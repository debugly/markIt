package com.debugly.markit.sync

import android.content.Context
import com.debugly.markit.storage.DocumentStore

/**
 * One [SyncCoordinator] per synced folder, for the life of the process.
 *
 * This has to outlive any single Activity. The debounce job and the in-flight
 * sync live on the coordinator, so a fresh instance per call would give every
 * edit its own timer and its own sync -- several of them racing over the same
 * manifest and the same files. Keying by folder keeps each folder's state
 * separate, since each has its own manifest and its own server.
 *
 * Activities share this rather than owning it, which is what lets the editor
 * ask for a sync after saving: it is a different Activity from the file list,
 * and a registry scoped to either one would give the two different views of
 * the same folder.
 */
object SyncRegistry {
    private val coordinators = mutableMapOf<String, SyncCoordinator>()

    @Synchronized
    fun coordinatorFor(
        context: Context,
        store: DocumentStore,
        config: FolderSyncConfig
    ): SyncCoordinator {
        val key = "${config.folderPath}|${config.serverUrl}|${config.remotePath}"
        coordinators[key]?.let { return it }
        return coordinators.getOrPut(key) {
            SyncCoordinator(
                context.applicationContext,
                store,
                WebDAVClient(config.serverUrl, config.username, config.password),
                config.remotePath,
                config.folderPath
            )
        }
    }

    /**
     * The config covering [path], or null when nothing is synced there.
     *
     * Auto-sync has to resolve the config from the folder the note lives in
     * rather than from whatever folder happened to be on screen when the editor
     * launched. A note at the vault root resolves against the root config.
     */
    fun configFor(context: Context, path: String): FolderSyncConfig? {
        val folder = path.substringBeforeLast('/', "")
        return SyncConfigStore(context)
            .forFolder(folder)
            ?.takeIf { it.isConfigured && it.autoSyncEnabled }
    }

    /**
     * Asks for a sync after a local write.
     *
     * Fire and forget on purpose. It is called from write paths that already
     * report their own failures, and the sync failing is not the write failing
     * -- reporting both would alarm the user about a note that is perfectly
     * safe on the device.
     */
    fun requestAutoSync(context: Context, store: DocumentStore, path: String) {
        val config = configFor(context, path) ?: return
        coordinatorFor(context, store, config).markModified(path)
    }

    /** The coordinator for [path]'s folder, if it is synced. Used by the sync screen. */
    /** Drops cached coordinators, e.g. after the credentials or server changed. */
    @Synchronized
    fun invalidate(folderPath: String? = null) {
        if (folderPath == null) coordinators.clear()
        else coordinators.keys.filter { it.startsWith("$folderPath|") }.forEach { coordinators.remove(it) }
    }
}
