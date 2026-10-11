package com.debugly.markit.ui

import android.net.Uri
import android.os.Bundle
import android.text.format.DateFormat
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.FolderSyncConfig
import com.debugly.markit.sync.SyncConfigStore
import com.debugly.markit.sync.SyncCoordinator
import com.debugly.markit.sync.WebDAVClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * WebDAV settings for one folder, reached from the folder's overflow menu.
 *
 * The folder arrives as an argument rather than being read from global state:
 * sync is a property of a folder, the same way it is in the macOS app. Two
 * folders can point at different servers, and a folder with no saved config is
 * simply not synchronised.
 *
 * It has its own toolbar rather than borrowing the file list's chrome: the
 * search field and FAB mean nothing here, and the title needs a back button to
 * return to the vault.
 */
class SyncFragment : Fragment() {

    private var folderPath: String = ""

    private lateinit var urlField: EditText
    private lateinit var userField: EditText
    private lateinit var passField: EditText
    private lateinit var pathField: EditText
    private lateinit var statusText: TextView
    private lateinit var titleText: TextView
    private lateinit var removeButton: TextView
    private var backCallback: androidx.activity.OnBackPressedCallback? = null

    private val configs by lazy { SyncConfigStore(requireContext()) }
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        folderPath = arguments?.getString(ARG_FOLDER) ?: ""
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?, s: Bundle?
    ): View {
        val v = inflater.inflate(R.layout.fragment_sync, container, false)

        urlField = v.findViewById(R.id.davUrl)
        userField = v.findViewById(R.id.davUser)
        passField = v.findViewById(R.id.davPass)
        pathField = v.findViewById(R.id.davPath)
        statusText = v.findViewById(R.id.syncStatus)
        titleText = v.findViewById(R.id.syncTitle)
        removeButton = v.findViewById(R.id.btnRemoveSync)

        val name = folderPath.substringAfterLast('/').ifEmpty { "根目录" }
        titleText.text = name

        val existing = configs.forFolder(folderPath)
        urlField.setText(existing?.serverUrl ?: "")
        userField.setText(existing?.username ?: "")
        passField.setText(existing?.password ?: "")
        pathField.setText(existing?.remotePath ?: name)

        statusText.text = when {
            existing == null -> "此文件夹未设置同步"
            existing.lastSyncTime == 0L -> "尚未同步"
            else -> "上次同步 ${DateFormat.format("MM-dd HH:mm", existing.lastSyncTime)}"
        }
        removeButton.visibility = if (existing?.isConfigured == true) View.VISIBLE else View.GONE

        // Same edge-to-edge handling as the other screens.
        Insets.apply(v.findViewById(R.id.syncTopBar), top = true, horizontal = true)
        Insets.apply(v.findViewById(R.id.syncScroll), bottom = true, horizontal = true)

        v.findViewById<ImageButton>(R.id.syncBack).setOnClickListener { goBack() }
        v.findViewById<TextView>(R.id.btnTest).setOnClickListener { testConnection() }
        v.findViewById<TextView>(R.id.btnSyncNow).setOnClickListener { runSync() }
        removeButton.setOnClickListener { confirmRemove() }

        return v
    }

    override fun onStart() {
        super.onStart()
        backCallback = object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { goBack() }
        }
        requireActivity().onBackPressedDispatcher.addCallback(backCallback!!)
    }

    override fun onStop() {
        super.onStop()
        backCallback?.remove()
        backCallback = null
        // Save on the way out as well as on a successful test. Requiring a
        // reachable server would mean a user on a laptop that is offline, or
        // pointing at a server that is temporarily down, could never keep the
        // settings they just typed.
        if (::urlField.isInitialized) {
            val config = formConfig()
            if (config.isConfigured) {
                persist(config)
                removeButton.visibility = View.VISIBLE
            }
        }
    }

    private fun goBack() {
        (activity as? MainActivity)?.showFiles()
    }

    /**
     * Reads the form into a config. Callers decide whether to persist it, so a
     * failed connection test does not overwrite a working saved config.
     */
    private fun formConfig(): FolderSyncConfig {
        val existing = configs.forFolder(folderPath)
        return FolderSyncConfig(
            folderPath = folderPath,
            serverUrl = urlField.text.toString().trim(),
            username = userField.text.toString().trim(),
            password = passField.text.toString(),
            remotePath = pathField.text.toString().trim(),
            autoSyncEnabled = existing?.autoSyncEnabled ?: true,
            lastSyncTime = existing?.lastSyncTime ?: 0
        )
    }

    private fun persist(config: FolderSyncConfig) = configs.save(config)

    private fun confirmRemove() {
        val name = folderPath.substringAfterLast('/').ifEmpty { "此文件夹" }
        AlertDialog.Builder(requireContext())
            .setTitle("停止同步 $name？")
            .setMessage("将移除此文件夹的同步设置。本地文件和服务器上的文件都会保留。")
            .setPositiveButton("停止同步") { _, _ ->
                configs.remove(folderPath)
                goBack()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun treeUri(): Uri? {
        val s = requireContext()
            .getSharedPreferences("markit", android.content.Context.MODE_PRIVATE)
            .getString("tree_uri", null) ?: return null
        return Uri.parse(s)
    }

    private fun testConnection() {
        val config = formConfig()
        if (config.serverUrl.isEmpty()) {
            statusText.text = "请先填写 WebDAV 服务器地址"
            return
        }
        statusText.text = "正在测试连接…"
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                try {
                    val client = WebDAVClient(config.serverUrl, config.username, config.password)
                    if (client.testConnection(config.remotePath)) "连接成功"
                    else "连接失败"
                } catch (e: Exception) {
                    e.message ?: "连接失败"
                }
            }
            statusText.text = message
            // Only a config that actually connected is worth keeping.
            if (message == "连接成功") {
                persist(config)
                removeButton.visibility = View.VISIBLE
            } else {
                AlertDialog.Builder(requireContext())
                    .setTitle("连接失败")
                    .setMessage(message)
                    .setPositiveButton("好", null)
                    .show()
            }
        }
    }

    private fun runSync() {
        val uri = treeUri()
        if (uri == null) {
            AlertDialog.Builder(requireContext())
                .setTitle("尚未选择文件夹")
                .setMessage("请先在「文件」页选择本地文件夹，MarkIt 会在该目录与 WebDAV 之间同步。")
                .setPositiveButton("好", null)
                .show()
            return
        }

        val config = formConfig()
        if (!config.isConfigured) {
            statusText.text = "请先填写服务器地址和远程路径"
            return
        }

        statusText.text = "同步中…"
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                try {
                    val coordinator = SyncCoordinator(
                        requireContext(),
                        DocumentStore(requireContext(), uri),
                        WebDAVClient(config.serverUrl, config.username, config.password),
                        config.remotePath
                    )
                    when (val r = coordinator.sync()) {
                        is SyncCoordinator.Result.Success -> {
                            persist(config.copy(lastSyncTime = System.currentTimeMillis()))
                            "同步完成"
                        }
                        is SyncCoordinator.Result.Failure -> r.message
                    }
                } catch (e: Exception) {
                    e.message ?: "同步失败"
                }
            }
            statusText.text = message
        }
    }

    companion object {
        private const val ARG_FOLDER = "folder"

        fun forFolder(folderPath: String): SyncFragment =
            SyncFragment().apply {
                arguments = Bundle().apply { putString(ARG_FOLDER, folderPath) }
            }
    }
}
