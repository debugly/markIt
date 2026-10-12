package com.debugly.markit.ui

import android.content.Intent
import android.util.Log
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
import com.debugly.markit.model.SupportedFileType
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.FolderSyncConfig
import com.debugly.markit.sync.SyncConfigStore
import com.debugly.markit.sync.SyncCoordinator
import com.debugly.markit.sync.SyncRegistry
import com.debugly.markit.sync.WebDAVClient
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.floatingactionbutton.FloatingActionButton
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity(), BrowseFragment.Host, SettingsFragment.Host {

    private lateinit var listView: RecyclerView
    private lateinit var adapter: FileListAdapter
    private lateinit var searchField: EditText
    private lateinit var emptyState: TextView
    private lateinit var rootTitle: TextView
    private var fab: FloatingActionButton? = null

    private var store: DocumentStore? = null
    private lateinit var recentFiles: RecentFiles
    private var currentPath: String = ""
    private var allNodes: List<FileNode> = emptyList()
    private var filter: String = ""

    // Listing the vault must stay off the main thread.
    private val io = Executors.newSingleThreadExecutor()
    /**
     * Rebuilt rather than cached: SyncConfigStore resolves the attached
     * directory once, so an instance made before a switch keeps answering for
     * the directory the user just left.
     */
    private val syncConfigs get() = SyncConfigStore(this)

    /** Manifests and pending deletions, scoped to whichever vault is attached. */
    private fun syncStatePrefs() = getSharedPreferences("markit_sync_state", MODE_PRIVATE)

    private val pickTree = registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri != null) confirmAttachTree(uri)
    }

    /**
     * Asks before switching the storage directory, because the result surprises
     * people in two ways that are not obvious from the tap.
     *
     * Nothing is copied or deleted -- the notes in the old directory stay
     * exactly where they are, and this app no longer has permission to see
     * them. But the file list does empty out, which reads as data loss until
     * you know otherwise.
     *
     * Sync configurations stop applying -- including the saved passwords, which
     * described the old directory's folders. They are kept rather than deleted,
     * so returning to the previous directory brings them back intact.
     */
    private fun confirmAttachTree(uri: android.net.Uri) {
        val switching = store != null
        val message = if (switching) {
            "MarkIt 将改为读写你选择的新目录。\n\n" +
                "原目录中的文件不会被删除或移动，仍完整保留在原处，只是 MarkIt 将不再访问它。\n\n" +
                "同步会暂停：新目录里的文件夹不会同步，原目录的同步设置会保留但暂时停用。" +
                "换回原来的目录后，同步设置会自动恢复，包括已保存的服务器密码。"
        } else {
            "MarkIt 将读写你选择的目录，笔记会保存在其中，不会复制到 App 内部。"
        }
        AlertDialog.Builder(this)
            .setTitle(if (switching) "更换存储目录？" else "选择存储目录")
            .setMessage(message)
            .setPositiveButton(if (switching) "更换" else "选择") { _, _ -> attachTree(uri, switching) }
            .setNegativeButton("取消", null)
            .show()
    }

    // ---- BrowseFragment.Host -------------------------------------------------
    // The SAF tree grant lives on the Activity, so a pushed level asks for the
    // store rather than holding its own.

    override fun storeFor(fragment: BrowseFragment): DocumentStore? = store

    override fun onOpenFile(node: FileNode) {
        val name = node.name
        val type = SupportedFileType.detect(name)
        if (type == SupportedFileType.IMAGE || type == SupportedFileType.HTML) {
            val tree = getSharedPreferences("markit", MODE_PRIVATE)
                .getString("tree_uri", null) ?: return
            startActivity(FileViewerActivity.intent(this, tree, node.path, name))
            return
        }
        val s = store ?: return
        io.execute {
            val content = try { s.readText(node.path) } catch (e: Exception) { "" }
            runOnUiThread {
                startActivity(EditorActivity.intent(this@MainActivity, node.path, name, content))
            }
        }
    }

    override fun onNodeLongPress(node: FileNode) = showNodeActions(node)

    override fun onOpenSyncSettings(folderPath: String) = showSync(folderPath)

    /**
     * Brings the root listing back once a pushed level is gone.
     *
     * A pushed folder hides the root's own list and search field, since two
     * lists sharing the screen would show two search boxes. Restoring them from
     * the back stack rather than from each level's lifecycle matters because
     * replace() shows the incoming fragment and hides the outgoing one, so a
     * newly pushed level is also "becoming visible" and would hand the screen
     * straight back.
     */
    // ---- SettingsFragment.Host ----------------------------------------------

    /** No-op: the tab bar is the way out now. Kept so the fragment can keep
     *  asking without caring how the Activity decides to leave. */
    override fun onCloseSettings() = showFiles()

    /** The settings screen delegates the folder picker here, so it gets the
     *  same confirmation and the same state handling as the startup path. */
    override fun onRequestVaultPick() = pickTree.launch(null)

    override fun onRecentsCleared() {
        // The recent list is a section of the root listing, so it has to be
        // rebuilt or the entries stay on screen until the next reload.
        load()
    }

    override fun onBrowseLevelClosed() {
        supportFragmentManager.addOnBackStackChangedListener(
            object : FragmentManager.OnBackStackChangedListener {
                override fun onBackStackChanged() {
                    if (supportFragmentManager.backStackEntryCount == 0) {
                        setRootChromeVisible(true)
                    }
                }
            }
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super, because the theme decides which colour resources the
        // whole Activity inflates with. Applying it later leaves the first frame
        // in the system theme and then recreates the Activity.
        ThemeSetting.applyStored(this)
        super.onCreate(savedInstanceState)
        Insets.goEdgeToEdge(this)
        setContentView(R.layout.activity_main)

        // The list canvas stays flush to the screen; only the chrome is inset.
        Insets.apply(findViewById(R.id.searchBar), top = true, horizontal = true)
        Insets.apply(findViewById(R.id.bottomBar), bottom = true, horizontal = true)

        listView = findViewById(R.id.fileList)
        searchField = findViewById(R.id.searchField)
        recentFiles = RecentFiles(this)
        emptyState = findViewById(R.id.emptyState)
        rootTitle = findViewById(R.id.rootTitle)
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
        // Reattaching on launch is not a switch: there is no previous directory
        // to lose, so it skips the confirmation.
        if (saved != null) attachTree(Uri.parse(saved), switching = false) else pickTree.launch(null)
    }

    /**
     * Points the app at [uri], optionally discarding what belonged to the
     * directory it was leaving.
     */
    private fun attachTree(uri: Uri, switching: Boolean) {
        if (switching) {
            // Sync configuration and manifest are *not* deleted. They stop
            // applying because the vault id no longer matches, and come back
            // intact -- password, last sync time and all -- if the user returns
            // to this directory. The recents list is a different matter: it is
            // only ever a shortcut to files in the directory just left, so those
            // rows would all fail to open.
            RecentFiles(this).clear()
            SyncRegistry.invalidate()
        }
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

        // The settings screen is still on the back stack and its fragment is
        // what is in the container. Without this the switch leaves a blank
        // screen: the settings fragment draws over a list it knows nothing
        // about, and load() writes into views that are not on screen.
        supportFragmentManager.popBackStack(null, FragmentManager.POP_BACK_STACK_INCLUSIVE)
        showChrome(true)
        currentPath = ""
        load()
    }

    /** Returns to the vault. Public so the sync screen's back button can call it. */
    fun showFiles() {
        // Pop first: pushed screens (folder levels, sync) sit on top. The
        // settings fragment is not among them -- it is a tab, replaced rather
        // than pushed -- so it is cleared here too, or it keeps drawing over
        // the file list.
        supportFragmentManager.popBackStack(null, FragmentManager.POP_BACK_STACK_INCLUSIVE)
        if (supportFragmentManager.findFragmentById(R.id.rootContainer) is SettingsFragment) {
            supportFragmentManager.beginTransaction()
                .remove(supportFragmentManager.findFragmentById(R.id.rootContainer)!!)
                .commitAllowingStateLoss()
        }
        showChrome(true)
        showTabBar(true)
        load()
    }

    private fun showSync(folderPath: String) {
        supportFragmentManager.beginTransaction()
            .replace(R.id.rootContainer, SyncFragment.forFolder(folderPath))
            .addToBackStack("sync")
            .commitAllowingStateLoss()
        showChrome(false)
        showTabBar(false)
    }

    /**
     * The file list owns the search bar, list, FAB and tab bar; other screens
     * take the whole area.
     *
     * The list and its empty state are hidden too, not just the chrome. Leaving
     * them behind shows the folder being set up underneath the screen that
     * replaced it.
     */
    private fun showChrome(visible: Boolean) {
        val v = if (visible) View.VISIBLE else View.GONE
        findViewById<View>(R.id.rootTitle).visibility = v
        findViewById<View>(R.id.searchBar).visibility = v
        findViewById<View>(R.id.fileList).visibility = v
        findViewById<View>(R.id.emptyState).visibility = v
        fab?.visibility = v
        findViewById<View>(R.id.browseContainer).visibility = v
    }

    /**
     * The tab bar.
     *
     * Separate from [showChrome] because the settings screen is a tab, not a
     * place navigated to: hiding the bar that got you there leaves no way back
     * except the tab you pressed, and a screen that came from a tab should keep
     * it. Only the pushed screens -- folder browsing, sync, the settings
     * fragment before it was promoted to a tab -- take it away.
     */
    private fun showTabBar(visible: Boolean) {
        findViewById<View>(R.id.bottomBar).visibility =
            if (visible) View.VISIBLE else View.GONE
    }

        /**
     * The settings tab.
     *
     * Not pushed on the back stack: a tab is a peer of the file list, not a
     * step forward from it, so it has no back button to offer and Back should
     * leave the app rather than undo the tap.
     */
    private fun showSettings() {
        supportFragmentManager.beginTransaction()
            .replace(R.id.rootContainer, SettingsFragment.newInstance())
            .commitAllowingStateLoss()
        showChrome(false)
        showTabBar(true)
    }

    private fun load() {
        val s = store ?: run {
            rootTitle.visibility = View.GONE
            emptyState.text = "未选择文件夹"
            emptyState.visibility = View.VISIBLE
            return
        }
        // Name the vault. Two vaults holding folders of the same name are
        // indistinguishable otherwise, and which one is open is the first
        // thing worth knowing on this screen.
        // describeRoot() hands back the full document id path; only the last
        // segment is the folder the user chose. "Download/MarkIt" reads as a
        // location the app picked rather than the one it was given.
        rootTitle.text = s.describeRoot().substringAfterLast('/')
        rootTitle.visibility = View.VISIBLE
        io.execute {
            val nodes = try { s.list(currentPath) } catch (e: Exception) { emptyList() }
            runOnUiThread {
                allNodes = nodes
                rebuildRows()
            }
        }
    }

    private fun rebuildRows() {
        val shown = if (filter.isBlank()) allNodes
                    else allNodes.filter { it.name.contains(filter, ignoreCase = true) }

        val rows = mutableListOf<Row>()
        val dirs = shown.filter { it.isDirectory }
        // The second section is what the user last worked on rather than an
        // alphabetical listing of the folder. Browsing the full tree is still
        // what entering a directory is for, so nothing is lost by dropping the
        // flat file list from here.
        val recents = recentEntries()

        if (dirs.isNotEmpty() && filter.isBlank()) {
            rows.add(Row.Section("目录"))
            dirs.forEach { rows.add(Row.Entry(it, null, syncConfigs.isSynced(it.path))) }
        }
        if (recents.isNotEmpty()) {
            rows.add(Row.Section(if (filter.isBlank()) "最近打开" else "匹配 ${recents.size} 项"))
            recents.forEach { rows.add(Row.Entry(it, null, isPendingSync = isPendingSync(it))) }
        }
        adapter.submit(rows)

        // rebuildRows is also the path a filter takes, and load() is not called
        // again, so the empty state has to be updated here too. Without it a
        // filter matching nothing left a blank screen with no indication that
        // the app was alive and simply had no match.
        updateEmptyState(dirs.isEmpty() && recents.isEmpty())
    }

    /**
     * Shows the placeholder when there is nothing to list.
     *
     * The wording distinguishes an empty folder from an empty search: "no
     * files" and "nothing matched" call for different actions from the user,
     * and showing the wrong one sends them looking for files that are there.
     */
    private fun updateEmptyState(nothingToShow: Boolean) {
        if (!nothingToShow) {
            emptyState.visibility = View.GONE
            return
        }
        emptyState.text = if (filter.isBlank()) "此文件夹为空" else "没有匹配「$filter」的文件"
        emptyState.visibility = View.VISIBLE
    }

    /**
     * The recent notes to list, as nodes.
     *
     * Paths that no longer resolve are dropped rather than listed: a note
     * deleted or renamed through another app would otherwise sit in the list as
     * a row that cannot be opened. Inside a folder the list is also narrowed to
     * what that folder holds, so opening a subfolder does not show a recent
     * section full of notes from elsewhere in the vault.
     */
    private fun recentEntries(): List<FileNode> {
        val st = store ?: return emptyList()
        val scope = currentPath
        val recent = recentFiles.resolvable(st)
        return recent
            .filter { scope.isBlank() || it == scope || it.startsWith("$scope/") }
            .map { path ->
                // Metadata comes from the listing when the file is in view; the
                // recents list otherwise has to resolve the node itself to show
                // anything beyond the name.
                allNodes.firstOrNull { it.path == path } ?: FileNode(path, false)
            }
            .filter { filter.isBlank() || it.name.contains(filter, ignoreCase = true) }
    }

    /**
     * Whether [node] has edits the server has not received, for the cloud marker.
     *
     * Read from the manifest the last sync left locally, so it is a lookup
     * rather than a network call -- which is what makes it safe to do per row on
     * every rebuild. Notes outside a synced folder simply have no marker.
     */
    private fun isPendingSync(node: FileNode): Boolean {
        val st = store ?: return false
        return SyncRegistry.hasUnsyncedChanges(this, st, node)
    }

    private fun setRootChromeVisible(visible: Boolean) {
        val on = if (visible) android.view.View.VISIBLE else android.view.View.GONE
        findViewById<View>(R.id.searchBar).visibility = on
        findViewById<View>(R.id.fileList).visibility = on
        findViewById<View>(R.id.emptyState).visibility =
            if (visible && allNodes.isEmpty()) View.VISIBLE else View.GONE
        findViewById<View>(R.id.fabNew).visibility = on
        findViewById<View>(R.id.browseContainer).visibility =
            if (visible) View.GONE else View.VISIBLE
    }

    private fun openNode(node: FileNode) {
        if (node.isDirectory) {
            // Root is the only level this activity owns; everything below is a
            // pushed fragment.
            // The root's list and search field step aside; the pushed level
            // brings its own. Two lists in one screen would show two search
            // boxes stacked on each other.
            setRootChromeVisible(false)
            supportFragmentManager.beginTransaction()
                .replace(R.id.browseContainer, BrowseFragment.forPath(node.path))
                .addToBackStack(node.path)
                .commitAllowingStateLoss()
            return
        }

        val name = node.name
        val type = SupportedFileType.detect(name)

        // Recorded before the type branches: the viewer is just as much of a
        // place the user works as the editor, and both should show up in the
        // recent list.
        recentFiles.record(node.path)

        // Images and HTML have no useful source view, so they go straight to the
        // read-only viewer. Opening a .png as text showed a screen of binary
        // noise, and opening a .html file rendered its markup instead of the
        // page it describes.
        if (type == SupportedFileType.IMAGE || type == SupportedFileType.HTML) {
            val tree = getSharedPreferences("markit", MODE_PRIVATE)
                .getString("tree_uri", null) ?: return
            startActivity(FileViewerActivity.intent(this, tree, node.path, name))
            return
        }

        val s = store ?: return
        io.execute {
            val content = try { s.readText(node.path) } catch (e: Exception) { "" }
            runOnUiThread {
                startActivity(EditorActivity.intent(this@MainActivity, node.path, name, content))
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
        // Resolved up front: this runs inside an io.execute below, where a dialog
        // is long gone and the folder on screen may be a different one.
        val folder = if (node.isDirectory) node.path else node.path.substringBeforeLast('/', "")
        val config = syncConfigs.forFolder(folder)?.takeIf { it.isConfigured }
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
                    // rename() reports failure by returning false rather than
                    // throwing, and DocumentsProvider.renameDocument fails
                    // routinely -- some providers refuse the call outright.
                    // Ignoring it left the row showing the new name while the
                    // file on disk kept the old one, which reads as the rename
                    // having worked when nothing moved.
                    if (!s.rename(node.path, newName)) {
                        runOnUiThread {
                            AlertDialog.Builder(this)
                                .setTitle("重命名失败")
                                .setMessage("无法重命名「${node.name}」，请换一个名字再试。")
                                .show()
                        }
                        return@execute
                    }
                    val newPath = if (node.path.contains('/')) {
                        node.path.substringBeforeLast('/') + "/" + newName
                    } else {
                        newName
                    }
                    // The old path has to be marked deleted, or the sync treats
                    // the new name as a fresh file and the server ends up holding
                    // both. recordDeletion does that; the auto-sync then uploads
                    // the new name and deletes the old one in one pass.
                    config?.let { recordDeletionForSync(node.path, it) }
                    requestAutoSync(newPath)
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun confirmDelete(node: FileNode) {
        // Only claim the remote copy goes too when a sync config actually covers
        // this file. Otherwise the dialog would promise a deletion that nothing
        // is going to perform.
        val folder = if (node.isDirectory) node.path else node.path.substringBeforeLast('/', "")
        val config = syncConfigs.forFolder(folder)
        val synced = config?.isConfigured == true
        val scopeHint = if (synced) "将从本地和 WebDAV 一并删除。" else "将从本地删除。"

        AlertDialog.Builder(this)
            .setTitle("删除 ${node.name}？")
            .setMessage(scopeHint)
            .setPositiveButton("删除") { _, _ ->
                val s = store ?: return@setPositiveButton
                io.execute {
                    s.delete(node.path)
                    // Otherwise the row stays in the recent list until the next
                    // resolve pass drops it, and a folder delete would leave one
                    // stale entry per file inside it.
                    dropFromRecent(node)
                    // A delete is inferred remotely from the file going missing,
                    // so record it explicitly. Otherwise the next pull would see
                    // it absent locally and push it straight back.
                    if (synced && config != null) {
                        recordDeletionForSync(node.path, config)
                    }
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /**
     * Removes [node] from the recent list after it is deleted.
     *
     * A folder drops itself and everything under it. Leaving the children behind
     * would mean deleting a folder produces a recent section full of entries
     * that resolve to nothing.
     */
    private fun dropFromRecent(node: FileNode) {
        val scope = node.path
        val st = store
        recentFiles.paths().forEach { path ->
            val hit = if (node.isDirectory) {
                path == scope || path.startsWith("$scope/")
            } else {
                path == scope
            }
            if (hit) recentFiles.remove(path)
        }
        // A folder delete can leave the folder's own subfolder entries behind
        // when the store no longer resolves them, so re-resolve what is left.
        if (st != null) {
            val keep = recentFiles.resolvable(st)
            recentFiles.paths().filter { it !in keep }.forEach { recentFiles.remove(it) }
        }
    }

    private fun coordinatorFor(config: FolderSyncConfig): SyncCoordinator? {
        val st = store ?: return null
        return SyncRegistry.coordinatorFor(this, st, config)
    }

    /** Records a local deletion so the next sync removes it from the server. */
    private fun recordDeletionForSync(path: String, config: FolderSyncConfig) {
        coordinatorFor(config)?.recordDeletion(path)
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
                    requestAutoSync(path)
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
                    requestAutoSync(path)
                    runOnUiThread { load() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }
    private fun requestAutoSync(path: String) {
        val st = store ?: return
        try {
            SyncRegistry.requestAutoSync(this, st, path)
        } catch (e: Exception) {
            Log.w("MarkIt", "auto-sync request failed for $path: ${e.message}")
        }
    }

}