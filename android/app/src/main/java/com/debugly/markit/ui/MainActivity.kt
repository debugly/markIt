package com.debugly.markit.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentManager
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.debugly.markit.R
import com.debugly.markit.model.FileNode
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.SyncConfigStore
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.floatingactionbutton.FloatingActionButton
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private lateinit var listView: RecyclerView
    private lateinit var adapter: FileListAdapter
    private lateinit var searchField: EditText
    private lateinit var emptyState: TextView
    private var fab: FloatingActionButton? = null

    private var store: DocumentStore? = null
    private var currentPath: String = ""
    private var allNodes: List<FileNode> = emptyList()
    private var filter: String = ""

    // Listing the vault must stay off the main thread.
    private val io = Executors.newSingleThreadExecutor()
    private val syncConfigs by lazy { SyncConfigStore(this) }

    private val pickTree = registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri != null) attachTree(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Insets.goEdgeToEdge(this)
        setContentView(R.layout.activity_main)

        // The list canvas stays flush to the screen; only the chrome is inset.
        Insets.apply(findViewById(R.id.searchBar), top = true, horizontal = true)
        Insets.apply(findViewById(R.id.bottomBar), bottom = true, horizontal = true)

        listView = findViewById(R.id.fileList)
        searchField = findViewById(R.id.searchField)
        emptyState = findViewById(R.id.emptyState)
        fab = findViewById(R.id.fabNew)

        adapter = FileListAdapter(onClick = ::openNode, onLongClick = ::showNodeActions)
        listView.layoutManager = LinearLayoutManager(this)
        listView.adapter = adapter

        searchField.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                filter = s?.toString().orEmpty()
                rebuildRows()
            }
        })

        findViewById<BottomNavigationView>(R.id.bottomBar).setOnItemSelectedListener { item ->
            when (item.itemId) {
                R.id.nav_files -> { showFiles(); true }
                R.id.nav_settings -> { showSettings(); true }
                else -> false
            }
        }

        fab?.setOnClickListener { showCreateSheet() }
        Insets.apply(fab ?: findViewById(R.id.fabNew), horizontal = true)


        // Re-attach to the previously granted tree, otherwise ask for one.
        val saved = getSharedPreferences("markit", MODE_PRIVATE).getString("tree_uri", null)
        if (saved != null) attachTree(Uri.parse(saved)) else pickTree.launch(null)
    }

    private fun attachTree(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (e: SecurityException) {
            // Not every provider offers persistable grants; the session grant
            // still works for this run.
        }

        store = DocumentStore(this, uri)
        getSharedPreferences("markit", MODE_PRIVATE).edit()
            .putString("tree_uri", uri.toString()).apply()

        currentPath = ""
        load()
    }

    /** Returns to the vault. Public so the sync screen's back button can call it. */
    fun showFiles() {
        supportFragmentManager.popBackStack(null, FragmentManager.POP_BACK_STACK_INCLUSIVE)
        showChrome(true)
        load()
    }

    private fun showSync(folderPath: String) {
        supportFragmentManager.beginTransaction()
            .replace(R.id.rootContainer, SyncFragment.forFolder(folderPath))
            .addToBackStack("sync")
            .commitAllowingStateLoss()
        showChrome(false)
    }

    /** The file list owns the search bar, FAB and tab bar; other screens hide them. */
    private fun showChrome(visible: Boolean) {
        val v = if (visible) View.VISIBLE else View.GONE
        findViewById<View>(R.id.searchBar).visibility = v
        findViewById<BottomNavigationView>(R.id.bottomBar).visibility = v
        fab?.visibility = v
    }

    private fun showSettings() {
        showFiles()
        AlertDialog.Builder(this)
            .setTitle("设置")
            .setMessage("预览样式、编辑器字体等选项将随设置页一并提供。")
            .setPositiveButton("好", null)
            .show()
    }

    private fun load() {
        val s = store ?: run {
            emptyState.text = "未选择文件夹"
            emptyState.visibility = View.VISIBLE
            return
        }
        io.execute {
            val nodes = try { s.list(currentPath) } catch (e: Exception) { emptyList() }
            runOnUiThread {
                allNodes = nodes
                emptyState.text = "此文件夹为空"
                emptyState.visibility = if (nodes.isEmpty()) View.VISIBLE else View.GONE
                rebuildRows()
            }
        }
    }

    private fun rebuildRows() {
        val shown = if (filter.isBlank()) allNodes
                    else allNodes.filter { it.name.contains(filter, ignoreCase = true) }

        val rows = mutableListOf<Row>()
        val dirs = shown.filter { it.isDirectory }
        val files = shown.filter { !it.isDirectory }

        if (dirs.isNotEmpty() && filter.isBlank()) {
            rows.add(Row.Section("目录"))
            dirs.forEach { rows.add(Row.Entry(it, null, syncConfigs.isSynced(it.path))) }
        }
        if (files.isNotEmpty()) {
            rows.add(Row.Section(if (filter.isBlank()) "文件" else "匹配 ${files.size} 项"))
            files.forEach { rows.add(Row.Entry(it, null)) }
        }
        adapter.submit(rows)
    }

    private fun openNode(node: FileNode) {
        if (node.isDirectory) {
            currentPath = node.path
            load()
        } else {
            val s = store ?: return
            val name = node.name
            io.execute {
                val content = try { s.readText(node.path) } catch (e: Exception) { "" }
                runOnUiThread {
                    startActivity(EditorActivity.intent(this@MainActivity, node.path, name, content))
                }
            }
        }
    }

    private fun showNodeActions(node: FileNode) {
        // Sync is a folder-level concern, so it only appears on directories. A
        // folder that already has a config says so in the label and can remove it.
        val options = if (node.isDirectory) {
            val configured = syncConfigs.isSynced(node.path)
            arrayOf("重命名", "删除", if (configured) "同步设置（已开启）" else "同步设置")
        } else {
            arrayOf("重命名", "删除", "在外部应用中打开")
        }

        AlertDialog.Builder(this)
            .setTitle(node.name)
            .setItems(options) { _, which ->
                when (which) {
                    0 -> promptRename(node)
                    1 -> confirmDelete(node)
                    2 -> if (node.isDirectory) showSync(node.path) else openExternally(node)
                }
            }
            .show()
    }

    private fun promptRename(node: FileNode) {
        val input = EditText(this).apply {
            setText(node.name)
            setSelection(node.name.length)
        }
        AlertDialog.Builder(this)
            .setTitle("重命名")
            .setView(input)
            .setPositiveButton("确定") { _, _ ->
                val newName = input.text.toString().trim()
                val s = store ?: return@setPositiveButton
                if (newName.isEmpty() || newName == node.name) return@setPositiveButton
                io.execute {
                    s.rename(node.path, newName)
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun confirmDelete(node: FileNode) {
        AlertDialog.Builder(this)
            .setTitle("删除 ${node.name}？")
            .setMessage("将从本地和 WebDAV 一并删除。")
            .setPositiveButton("删除") { _, _ ->
                val s = store ?: return@setPositiveButton
                io.execute {
                    s.delete(node.path)
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun openExternally(node: FileNode) {
        val s = store ?: return
        io.execute {
            val info = s.shareInfo(node.path)
            runOnUiThread {
                val pair = info ?: return@runOnUiThread
                try {
                    startActivity(Intent(Intent.ACTION_VIEW)
                        .setDataAndType(pair.first, pair.second)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                } catch (e: Exception) {
                    AlertDialog.Builder(this)
                        .setMessage("没有可以打开 ${node.name} 的应用")
                        .show()
                }
            }
        }
    }

    private fun showCreateSheet() {
        AlertDialog.Builder(this)
            .setTitle("新建")
            .setItems(arrayOf("新建 Markdown", "新建文件夹")) { _, which ->
                if (which == 0) promptNewFile() else promptNewFolder()
            }
            .show()
    }

    private fun promptNewFile() {
        val input = EditText(this).apply { hint = "文件名.md" }
        AlertDialog.Builder(this)
            .setTitle("新建 Markdown")
            .setView(input)
            .setPositiveButton("创建") { _, _ ->
                val raw = input.text.toString().trim()
                if (raw.isEmpty()) return@setPositiveButton
                val name = if (raw.endsWith(".md") || raw.endsWith(".markdown")) raw else "$raw.md"
                val path = if (currentPath.isEmpty()) name else "$currentPath/$name"
                val s = store ?: return@setPositiveButton
                io.execute {
                    s.writeText(path, "")
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun promptNewFolder() {
        val input = EditText(this).apply { hint = "文件夹名" }
        AlertDialog.Builder(this)
            .setTitle("新建文件夹")
            .setView(input)
            .setPositiveButton("创建") { _, _ ->
                val name = input.text.toString().trim()
                if (name.isEmpty()) return@setPositiveButton
                val path = if (currentPath.isEmpty()) name else "$currentPath/$name"
                val s = store ?: return@setPositiveButton
                io.execute {
                    s.createDirectory(path)
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }
}