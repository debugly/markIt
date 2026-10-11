package com.debugly.markit.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.debugly.markit.R
import com.debugly.markit.model.FileNode
import com.debugly.markit.model.SupportedFileType
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.SyncConfigStore
import com.debugly.markit.sync.SyncRegistry
import java.util.concurrent.Executors

/**
 * One folder in the tree, pushed onto the back stack as the user descends.
 *
 * Each level is its own fragment rather than one activity tracking a current
 * folder, so going back is the back stack's job and the parent level's scroll
 * position, filter text and loading state are still there when the user returns
 * to it. Doing it with a single mutable "current folder" meant every level
 * clobbered the last one, and back had nothing to restore.
 */
class BrowseFragment : Fragment() {

    private var path: String = ""
    private var filter: String = ""

    private lateinit var listView: RecyclerView
    private lateinit var adapter: FileListAdapter
    private lateinit var searchField: EditText
    private lateinit var emptyState: TextView
    private lateinit var breadcrumb: TextView

    private var nodes: List<FileNode> = emptyList()

    private val io = Executors.newSingleThreadExecutor()
    private val syncConfigs by lazy { SyncConfigStore(requireContext()) }
    private var recentFiles: RecentFiles? = null

    /** Provided by the host, since the SAF tree grant lives in the Activity. */
    private var host: Host? = null

    interface Host {
        fun storeFor(fragment: BrowseFragment): DocumentStore?
        fun onOpenFile(node: FileNode)
        fun onNodeLongPress(node: FileNode)
        fun onOpenSyncSettings(folderPath: String)

        /** A pushed level went away; the host restores the root listing. */
        fun onBrowseLevelClosed()
    }

    override fun onAttach(context: android.content.Context) {
        super.onAttach(context)
        host = context as? Host
        recentFiles = RecentFiles(context)
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?
    ): View {
        val v = inflater.inflate(R.layout.fragment_browse, container, false)
        listView = v.findViewById(R.id.fileList)
        searchField = v.findViewById(R.id.searchField)
        emptyState = v.findViewById(R.id.emptyState)
        breadcrumb = v.findViewById(R.id.breadcrumb)

        path = arguments?.getString(ARG_PATH).orEmpty()
        breadcrumb.text = buildBreadcrumb()

        adapter = FileListAdapter(onClick = ::onClick, onLongClick = ::onLongClick)
        listView.layoutManager = LinearLayoutManager(requireContext())
        listView.adapter = adapter

        searchField.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                filter = s?.toString().orEmpty()
                rebuildRows()
            }
        })
        return v
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        // The fragment draws its own chrome inside the container, so it handles
        // the status bar inset itself rather than relying on the activity's.
        Insets.apply(view.findViewById(R.id.searchBar), top = true, horizontal = true)
        // Restore the filter across a rotation or a return from a deeper level.
        savedInstanceState?.getString(STATE_FILTER)?.let {
            filter = it
            searchField.setText(it)
        }
        load()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(STATE_FILTER, filter)
    }

    /**
     * The trail from the vault root to here.
     *
     * Each segment is a tap target, so the breadcrumb doubles as the way back
     * several levels at once -- re-entering folders one by one to climb out of a
     * deep path is tedious enough that people give up and leave.
     */
    private fun buildBreadcrumb(): String =
        if (path.isBlank()) "MarkIt"
        else "MarkIt / " + path.split('/').joinToString(" / ")

    private fun load() {
        val s = store() ?: run {
            showEmpty("未选择文件夹")
            return
        }
        io.execute {
            val listed = try { s.list(path) } catch (e: Exception) { emptyList() }
            if (!isAdded) return@execute
            requireActivity().runOnUiThread {
                nodes = listed
                rebuildRows()
            }
        }
    }

    private fun rebuildRows() {
        val shown = if (filter.isBlank()) nodes
                    else nodes.filter { it.name.contains(filter, ignoreCase = true) }
        val dirs = shown.filter { it.isDirectory }
        val files = shown.filter { !it.isDirectory }

        val rows = mutableListOf<Row>()
        if (dirs.isNotEmpty()) {
            rows.add(Row.Section(if (filter.isBlank()) "目录" else "匹配 ${dirs.size} 项"))
            dirs.forEach { rows.add(Row.Entry(it, null, syncConfigs.isSynced(it.path))) }
        }
        if (files.isNotEmpty()) {
            rows.add(Row.Section(if (filter.isBlank()) "文件" else "匹配 ${files.size} 项"))
            files.forEach { rows.add(Row.Entry(it, null, isPendingSync = isPendingSync(it))) }
        }
        adapter.submit(rows)
        showEmpty(
            when {
                dirs.isNotEmpty() || files.isNotEmpty() -> null
                filter.isNotBlank() -> "没有匹配「$filter」的文件"
                else -> "此文件夹为空"
            }
        )
    }

    private fun showEmpty(message: String?) {
        emptyState.text = message.orEmpty()
        emptyState.visibility = if (message == null) View.GONE else View.VISIBLE
    }

    private fun isPendingSync(node: FileNode): Boolean {
        val st = store() ?: return false
        return SyncRegistry.hasUnsyncedChanges(requireContext(), st, node)
    }

    private fun store(): DocumentStore? = host?.storeFor(this)

    private fun onClick(node: FileNode) {
        if (node.isDirectory) {
            // A new fragment per level: the back stack becomes the folder tree.
            // Descending hides the root listing, since two lists sharing one area
            // would show two search boxes.
            setRootVisible(false)
            parentFragmentManager.beginTransaction()
                .replace(R.id.browseContainer, forPath(node.path))
                .addToBackStack(node.path)
                .commitAllowingStateLoss()
            return
        }
        recentFiles?.record(node.path)
        host?.onOpenFile(node)
    }

    /**
     * Shows or hides the activity's root listing.
     *
     * Going back to the root has to restore it, and a back stack callback is the
     * only thing that knows when that happened -- onResume would fire on every
     * level change, including descending, where the root must stay hidden.
     */
    private fun setRootVisible(visible: Boolean) {
        val a = activity ?: return
        val on = if (visible) View.VISIBLE else View.GONE
        // The root's list, its search field and the empty state live side by side
        // in the activity's layout, so they step aside together.
        a.findViewById<View>(R.id.searchBar).visibility = on
        a.findViewById<View>(R.id.fileList).visibility = on
        a.findViewById<View>(R.id.emptyState).visibility =
            if (visible && emptyState.text.isNotEmpty()) View.VISIBLE else View.GONE
        a.findViewById<View>(R.id.fabNew).visibility = on
        a.findViewById<View>(R.id.browseContainer).visibility =
            if (visible) View.GONE else View.VISIBLE
    }

    private fun onLongClick(node: FileNode) {
        host?.onNodeLongPress(node)
    }

    override fun onDestroyView() {
        super.onDestroyView()
        // Leaving a level behind leaves the activity's chrome hidden; the host
        // restores it once the stack unwinds to the root.
        host?.onBrowseLevelClosed()
    }

    companion object {
        private const val ARG_PATH = "path"
        private const val STATE_FILTER = "filter"

        fun forPath(path: String): BrowseFragment = BrowseFragment().apply {
            arguments = Bundle().apply { putString(ARG_PATH, path) }
        }
    }
}
