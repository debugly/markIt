package com.debugly.markit.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.util.Log
import android.webkit.WebView
import android.widget.EditText
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.SyncCoordinator
import com.debugly.markit.sync.WebDAVClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

/**
 * Editor for a single file. Source and rendered preview share one screen and are
 * swapped by the icon in the top-right, matching the layout agreed on for the
 * Android build.
 */
class EditorActivity : AppCompatActivity() {

    private lateinit var editor: EditText
    private lateinit var web: WebView
    private lateinit var titleText: TextView
    private lateinit var statusBar: TextView

    private var path: String = ""
    private var showingPreview = false
    private var dirty = false

    private val io = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Insets.goEdgeToEdge(this)
        setContentView(R.layout.activity_editor)

        // Toolbar and status line are inset; the editor canvas and the preview
        // stay flush so text runs edge to edge in reading mode.
        Insets.apply(findViewById(R.id.topBar), top = true, horizontal = true)
        Insets.apply(findViewById(R.id.statusBar), bottom = true, horizontal = true)

        path = intent.getStringExtra(EXTRA_PATH).orEmpty()
        val content = intent.getStringExtra(EXTRA_CONTENT).orEmpty()

        editor = findViewById(R.id.editorText)
        web = findViewById(R.id.previewWeb)
        titleText = findViewById(R.id.titleText)
        statusBar = findViewById(R.id.statusBar)

        titleText.text = intent.getStringExtra(EXTRA_NAME) ?: path.substringAfterLast('/')
        editor.setText(content)

        editor.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                dirty = true
                updateStatus()
            }
        })

        web.settings.javaScriptEnabled = false



        findViewById<ImageButton>(R.id.btnBack).setOnClickListener { finish() }
        findViewById<ImageButton>(R.id.btnToggleMode).setOnClickListener { toggleMode() }
        findViewById<ImageButton>(R.id.btnMore).setOnClickListener { showMore() }

        updateStatus()
    }

    private fun toggleMode() {
        android.util.Log.i("MarkItEditor", "toggleMode, was showingPreview=$showingPreview")
        showingPreview = !showingPreview
        if (showingPreview) {
            // Commit any in-flight edit before rendering, so the preview cannot
            // lag behind the text.
            val text = editor.text.toString()
            web.loadDataWithBaseURL(
                null,
                Markdown.renderHtml(text),
                "text/html", "UTF-8", null
            )
            editor.visibility = android.view.View.GONE
            web.visibility = android.view.View.VISIBLE
            statusBar.text = "阅读模式 · 左右滑动调节字号"

            // The toolbar stays visible in both modes, so the page only has to
            // clear the navigation bar -- not the status bar, which the toolbar
            // already handles.
            Insets.apply(web, bottom = true, horizontal = true)
        } else {
            editor.visibility = android.view.View.VISIBLE
            web.visibility = android.view.View.GONE
            statusBar.text = "源码模式"

            Insets.apply(web, bottom = true, horizontal = true)
        }
        findViewById<ImageButton>(R.id.btnToggleMode)
            .setImageResource(
                if (showingPreview) R.drawable.ic_edit
                else R.drawable.ic_preview
            )
    }

    private fun showMore() {
        val options = arrayOf("保存", "重命名", "在外部应用中打开", "删除")
        AlertDialog.Builder(this)
            .setItems(options) { _, which ->
                when (which) {
                    0 -> save()
                    1 -> promptRename()
                    2 -> openExternally()
                    3 -> confirmDelete()
                }
            }
            .show()
    }

    private fun save() {
        val store = resolveStore() ?: return
        val text = editor.text.toString()
        io.execute {
            try {
                store.writeText(path, text)
                runOnUiThread {
                    dirty = false
                    statusBar.text = "已保存"
                }
            } catch (e: Exception) {
                runOnUiThread {
                    AlertDialog.Builder(this)
                        .setTitle("保存失败")
                        .setMessage(e.message ?: "未知错误")
                        .show()
                }
            }
        }
    }

    /**
     * Renames the open file. The rename has to survive a sync, so the old path is
     * recorded as a pending deletion: otherwise the next pull sees it missing
     * locally, concludes it was deleted, and recreates the old name on the server
     * alongside the new one.
     */
    private fun promptRename() {
        val store = resolveStore() ?: return
        val current = path.substringAfterLast('/')
        val parent = path.substringBeforeLast('/', "")

        val input = android.widget.EditText(this).apply {
            setText(current)
            setSelection(current.length)
        }
        AlertDialog.Builder(this)
            .setTitle("重命名")
            .setView(input)
            .setPositiveButton("确定") { _, _ ->
                val newName = input.text.toString().trim()
                if (newName.isEmpty() || newName == current) return@setPositiveButton

                val newPath = if (parent.isEmpty()) newName else "$parent/$newName"

                // Flush pending edits first so the renamed file is not carrying
                // stale contents.
                val text = editor.text.toString()
                io.execute {
                    try {
                        store.writeText(path, text)
                        if (!store.rename(path, newName)) {
                            runOnUiThread { showRenameFailed("无法重命名 $newName") }
                            return@execute
                        }
                        recordRenameForSync(path)
                        runOnUiThread {
                            path = newPath
                            titleText.text = newName
                            dirty = false
                            statusBar.text = "已重命名为 $newName"
                        }
                    } catch (e: Exception) {
                        runOnUiThread { showRenameFailed(e.message ?: "未知错误") }
                    }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun showRenameFailed(reason: String) {
        AlertDialog.Builder(this)
            .setTitle("重命名失败")
            .setMessage(reason)
            .setPositiveButton("好", null)
            .show()
    }

    /** Tells the sync layer the old path is gone so the server copy is deleted. */
    private fun recordRenameForSync(oldPath: String) {
        val uri = getSharedPreferences("markit", MODE_PRIVATE).getString("tree_uri", null)
            ?: return
        val prefs = getSharedPreferences("markit_sync", MODE_PRIVATE)
        val url = prefs.getString("url", null) ?: return
        val remoteRoot = prefs.getString("path", "MarkIt") ?: "MarkIt"

        CoroutineScope(Dispatchers.IO).launch {
            try {
                SyncCoordinator(
                    this@EditorActivity,
                    DocumentStore(this@EditorActivity, android.net.Uri.parse(uri)),
                    WebDAVClient(
                        url,
                        prefs.getString("user", "") ?: "",
                        prefs.getString("pass", "") ?: ""
                    ),
                    remoteRoot
                ).recordDeletion(oldPath)
            } catch (e: Exception) {
                Log.w("MarkItEditor", "could not record rename: ${e.message}")
            }
        }
    }

    private fun openExternally() {
        val store = resolveStore() ?: return
        io.execute {
            val info = store.shareInfo(path)
            runOnUiThread {
                if (info == null) return@runOnUiThread
                val (uri, mime) = info
                try {
                    startActivity(Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, mime)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                } catch (e: Exception) {
                    AlertDialog.Builder(this)
                        .setMessage("没有可以打开该文件的应用")
                        .show()
                }
            }
        }
    }

    private fun confirmDelete() {
        AlertDialog.Builder(this)
            .setTitle("删除文件？")
            .setPositiveButton("删除") { _, _ ->
                val store = resolveStore() ?: return@setPositiveButton
                io.execute {
                    store.delete(path)
                    runOnUiThread { finish() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun resolveStore(): DocumentStore? {
        val uri = getSharedPreferences("markit", MODE_PRIVATE).getString("tree_uri", null)
            ?: return null
        return DocumentStore(this, android.net.Uri.parse(uri))
    }

    private fun updateStatus() {
        if (showingPreview) return
        statusBar.text = if (dirty) "未保存的更改" else "已保存"
    }

    override fun onBackPressed() {
        if (showingPreview) {
            toggleMode()
            return
        }
        super.onBackPressed()
    }

    override fun onPause() {
        super.onPause()
        if (dirty) save()
    }

    companion object {
        private const val EXTRA_PATH = "path"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_CONTENT = "content"

        fun intent(context: Context, path: String, name: String, content: String): Intent =
            Intent(context, EditorActivity::class.java)
                .putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_NAME, name)
                .putExtra(EXTRA_CONTENT, content)
    }
}
