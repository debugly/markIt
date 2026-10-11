package com.debugly.markit.sync

import android.content.Context
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

    fun all(): List<FolderSyncConfig> {
        val raw = prefs.getString(KEY_CONFIGS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                FolderSyncConfig(
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

    fun forFolder(folderPath: String): FolderSyncConfig? =
        all().firstOrNull { it.folderPath == folderPath }

    fun isSynced(folderPath: String): Boolean =
        forFolder(folderPath)?.isConfigured == true

    fun save(config: FolderSyncConfig) {
        val existing = all().filterNot { it.folderPath == config.folderPath }
        write(existing + config)
    }

    fun remove(folderPath: String) {
        write(all().filterNot { it.folderPath == folderPath })
    }

    fun markSynced(folderPath: String, at: Long = System.currentTimeMillis()) {
        val existing = forFolder(folderPath) ?: return
        save(existing.copy(lastSyncTime = at))
    }

    private fun write(list: List<FolderSyncConfig>) {
        val arr = JSONArray()
        for (c in list) {
            arr.put(JSONObject()
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
