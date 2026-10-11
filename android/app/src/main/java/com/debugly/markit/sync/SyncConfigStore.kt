package com.debugly.markit.sync

import android.content.Context
import com.debugly.markit.storage.VaultId
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-folder WebDAV configuration, keyed by the folder's vault-relative path.
 *
 * Mirrors WebDAVFolderConfig in the macOS app: sync is a property of a folder,
 * not of the app. Two folders can point at two different servers, and a folder
 * with no config is simply not synchronised.
 *
 * Stored as one JSON array under a single key. The list is small -- one entry
 * per folder the user has configured -- so rewriting it wholesale is simpler
 * than a database and keeps the whole config readable when debugging.
 */
data class FolderSyncConfig(
    /**
     * Which storage directory this config belongs to.
     *
     * Folder names are not unique across directories: two of them can each
     * hold a `drafts`. Without this, opening the second one resolves the
     * first one's credentials, diffs it against a manifest describing files it
     * has never seen, and concludes the first directory's notes were deleted --
     * then removes them from the server. Matching on the pair means a folder
     * only ever finds its own configuration.
     *
     * Empty on configs written before this existed; [SyncConfigStore] treats
     * those as belonging to the current directory and stamps them on first
     * write, so upgrading keeps the user's configuration.
     */
    val vaultId: String,
    /** Vault-relative folder path. "" means the vault root. */
    val folderPath: String,
    val serverUrl: String,
    val username: String,
    /** Stored separately from the rest so it can be excluded when logging. */
    val password: String,
    /** Path on the server, appended to the server URL. */
    val remotePath: String,
    val autoSyncEnabled: Boolean = true,
    val lastSyncTime: Long = 0
) {
    val isConfigured: Boolean get() = serverUrl.isNotBlank() && remotePath.isNotBlank()
}

class SyncConfigStore(context: Context) {

    private val prefs = context.getSharedPreferences("markit_sync", Context.MODE_PRIVATE)

    /**
     * Which directory the question is about.
     *
     * Read from the attached vault rather than passed in at every call site:
     * there are a dozen, spread across Activities that each hold their own
     * store, and a caller that forgot the id would silently get another
     * directory's configuration -- which is the failure this is here to
     * prevent. Asking the app what it is attached to cannot drift.
     */
    private val vaultId: String = VaultId.current(context)

    fun all(): List<FolderSyncConfig> {
        val raw = prefs.getString(KEY_CONFIGS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                FolderSyncConfig(
                    vaultId = o.optString("vaultId", ""),
                    folderPath = o.optString("folderPath", ""),
                    serverUrl = o.optString("serverUrl", ""),
                    username = o.optString("username", ""),
                    password = o.optString("password", ""),
                    remotePath = o.optString("remotePath", ""),
                    autoSyncEnabled = o.optBoolean("autoSyncEnabled", true),
                    lastSyncTime = o.optLong("lastSyncTime", 0)
                )
            }
        } catch (e: Exception) {
            // A corrupt blob should not take the file list down with it.
            emptyList()
        }
    }

    /**
     * The config for [folderPath] inside [vaultId].
     *
     * A stored config with no vaultId predates this distinction and is taken
     * as belonging to whichever directory is attached now. That is what keeps
     * an existing setup working across the upgrade, and the first write stamps
     * the id on it so the ambiguity does not last.
     */
    fun forFolder(folderPath: String): FolderSyncConfig? {
        val match = all().firstOrNull {
            it.folderPath == folderPath &&
                (it.vaultId == vaultId || it.vaultId.isEmpty())
        } ?: return null
        if (match.vaultId == vaultId) return match
        // First lookup after the upgrade. Rewrite the legacy entry under the
        // current directory's id now rather than waiting for a config edit,
        // which for a read-only folder may never come -- an unstamped entry
        // stays ambiguous, and would be adopted by whichever directory happens
        // to be attached next.
        val stamped = match.copy(vaultId = vaultId)
        save(stamped)
        return stamped
    }

    fun isSynced(folderPath: String): Boolean =
        forFolder(folderPath)?.isConfigured == true

    fun save(config: FolderSyncConfig) {
        val existing = all().filterNot {
            it.folderPath == config.folderPath &&
                (it.vaultId == config.vaultId || it.vaultId.isEmpty())
        }
        write(existing + config)
    }

    fun remove(folderPath: String) {
        write(all().filterNot {
            it.folderPath == folderPath &&
                (it.vaultId == vaultId || it.vaultId.isEmpty())
        })
    }

    /**
     * Configs for [folderPath] under [vaultId], i.e. what the user would see as
     * "this folder is synchronised" right now.
     *
     * Configs belonging to other directories are kept, not deleted. Switching
     * the directory leaves them inactive because the ids stop matching, and
     * switching back brings them straight back -- including the password and
     * the last sync time. Deleting them would make the return trip mean
     * reconfiguring everything from scratch.
     */
    fun syncedFolders(): Set<String> =
        all().filter { it.isConfigured && it.vaultId == vaultId }.map { it.folderPath }.toSet()

    fun markSynced(folderPath: String, at: Long = System.currentTimeMillis()) {
        val existing = forFolder(folderPath) ?: return
        save(existing.copy(lastSyncTime = at))
    }

    private fun write(list: List<FolderSyncConfig>) {
        val arr = JSONArray()
        for (c in list) {
            arr.put(JSONObject()
                .put("vaultId", c.vaultId)
                .put("folderPath", c.folderPath)
                .put("serverUrl", c.serverUrl)
                .put("username", c.username)
                .put("password", c.password)
                .put("remotePath", c.remotePath)
                .put("autoSyncEnabled", c.autoSyncEnabled)
                .put("lastSyncTime", c.lastSyncTime))
        }
        prefs.edit().putString(KEY_CONFIGS, arr.toString()).apply()
    }

    private companion object {
        const val KEY_CONFIGS = "folder_configs"
    }
}
