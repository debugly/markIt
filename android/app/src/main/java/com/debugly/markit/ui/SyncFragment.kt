package com.debugly.markit.ui

import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.SyncCoordinator
import com.debugly.markit.sync.WebDAVClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SyncFragment : Fragment() {

    private lateinit var urlField: EditText
    private lateinit var userField: EditText
    private lateinit var passField: EditText
    private lateinit var pathField: EditText
    private lateinit var statusText: TextView

    private val prefs by lazy {
        requireContext().getSharedPreferences("markit_sync", android.content.Context.MODE_PRIVATE)
    }
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, s: Bundle?): View {
        val v = inflater.inflate(R.layout.fragment_sync, container, false)

        urlField = v.findViewById(R.id.davUrl)
        userField = v.findViewById(R.id.davUser)
        passField = v.findViewById(R.id.davPass)
        pathField = v.findViewById(R.id.davPath)
        statusText = v.findViewById(R.id.syncStatus)

        urlField.setText(prefs.getString("url", "") ?: "")
        userField.setText(prefs.getString("user", "") ?: "")
        passField.setText(prefs.getString("pass", "") ?: "")
        pathField.setText(prefs.getString("path", "MarkIt") ?: "MarkIt")

        val last = prefs.getLong("last_sync", 0)
        statusText.text = if (last == 0L) "尚未同步"
                           else "上次同步 ${android.text.format.DateFormat.format("MM-dd HH:mm", last)}"

        v.findViewById<TextView>(R.id.btnTest).setOnClickListener { testConnection() }
        v.findViewById<TextView>(R.id.btnSyncNow).setOnClickListener { runSync() }

        return v
    }

    private fun savePrefs() {
        prefs.edit()
            .putString("url", urlField.text.toString().trim())
            .putString("user", userField.text.toString().trim())
            .putString("pass", passField.text.toString())
            .putString("path", pathField.text.toString().trim())
            .apply()
    }

    private fun buildClient(): WebDAVClient {
        val url = urlField.text.toString().trim()
        if (url.isEmpty()) throw IllegalStateException("请先填写 WebDAV 服务器地址")
        return WebDAVClient(
            url,
            userField.text.toString().trim(),
            passField.text.toString()
        )
    }

    private fun treeUri(): Uri? {
        val s = requireContext().getSharedPreferences("markit", android.content.Context.MODE_PRIVATE)
            .getString("tree_uri", null) ?: return null
        return Uri.parse(s)
    }

    private fun testConnection() {
        savePrefs()
        statusText.text = "正在测试连接…"
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    buildClient().testConnection(pathField.text.toString().trim())
                } catch (e: Exception) {
                    e.message ?: "连接失败"
                }
            }
            if (result is Boolean) {
                statusText.text = if (result) "连接成功" else "连接失败"
            } else {
                AlertDialog.Builder(requireContext())
                    .setTitle("连接失败")
                    .setMessage(result as String)
                    .setPositiveButton("好", null)
                    .show()
                statusText.text = "连接失败"
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

        savePrefs()
        statusText.text = "同步中…"
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                try {
                    val coordinator = SyncCoordinator(
                        requireContext(),
                        DocumentStore(requireContext(), uri),
                        buildClient(),
                        pathField.text.toString().trim()
                    )
                    when (val r = coordinator.sync()) {
                        is SyncCoordinator.Result.Success -> "同步完成"
                        is SyncCoordinator.Result.Failure -> r.message
                    }
                } catch (e: Exception) {
                    e.message ?: "同步失败"
                }
            }
            statusText.text = message
            prefs.edit().putLong("last_sync", System.currentTimeMillis()).apply()
        }
    }
}
