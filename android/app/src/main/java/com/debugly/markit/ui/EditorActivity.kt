package com.debugly.markit.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.webkit.WebView
import android.widget.EditText
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore
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
        setContentView(R.layout.activity_editor)

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

        // Android 15+ draws edge to edge, so the toolbar sits under the status
        // bar and its buttons are untappable. Pad the top bar by the real inset.
        val topBar = findViewById<View>(R.id.topBar)
        ViewCompat.setOnApplyWindowInsetsListener(topBar) { v, insets ->
            val top = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top
            v.setPadding(v.paddingLeft, top, v.paddingRight, v.paddingBottom)
            insets
        }

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
        } else {
            editor.visibility = android.view.View.VISIBLE
            web.visibility = android.view.View.GONE
            statusBar.text = "源码模式"
        }
        findViewById<ImageButton>(R.id.btnToggleMode)
            .setImageResource(
                if (showingPreview) android.R.drawable.ic_menu_edit
                else android.R.drawable.ic_menu_view
            )
    }

    private fun showMore() {
        val options = arrayOf("保存", "重命名", "在外部应用中打开", "删除")
        AlertDialog.Builder(this)
            .setItems(options) { _, which ->
                when (which) {
                    0 -> save()
                    1 -> AlertDialog.Builder(this)
                        .setMessage("重命名请在文件列表中长按操作。")
                        .show()
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
