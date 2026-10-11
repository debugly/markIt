package com.debugly.markit.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.debugly.markit.R
import com.debugly.markit.model.FileNode
import com.debugly.markit.model.SupportedFileType
import java.text.DateFormat
import java.util.Date

/** One row: either a section header or a file/folder. */
sealed class Row {
    data class Section(val title: String) : Row()
    data class Entry(val node: FileNode, val badge: String?) : Row()
}

class FileListAdapter(
    private val onClick: (FileNode) -> Unit,
    private val onLongClick: (FileNode) -> Unit
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    private var rows: List<Row> = emptyList()

    fun submit(newRows: List<Row>) {
        rows = newRows
        notifyDataSetChanged()
    }

    override fun getItemCount() = rows.size

    override fun getItemViewType(position: Int) =
        if (rows[position] is Row.Section) TYPE_SECTION else TYPE_ENTRY

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return if (viewType == TYPE_SECTION) {
            SectionHolder(inflater.inflate(R.layout.item_section, parent, false))
        } else {
            EntryHolder(inflater.inflate(R.layout.item_file, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val row = rows[position]) {
            is Row.Section -> (holder as SectionHolder).bind(row.title)
            is Row.Entry -> (holder as EntryHolder).bind(row.node, row.badge)
        }
    }

    private companion object {
        const val TYPE_SECTION = 0
        const val TYPE_ENTRY = 1
    }

    class SectionHolder(view: View) : RecyclerView.ViewHolder(view) {
        private val title: TextView = view.findViewById(R.id.sectionTitle)
        fun bind(text: String) {
            title.text = text
        }
    }

    inner class EntryHolder(view: View) : RecyclerView.ViewHolder(view) {
        private val icon: TextView = view.findViewById(R.id.fileIcon)
        private val name: TextView = view.findViewById(R.id.fileName)
        private val meta: TextView = view.findViewById(R.id.fileMeta)
        private val badge: TextView = view.findViewById(R.id.syncBadge)
        private val chevron: TextView = view.findViewById(R.id.chevron)

        fun bind(node: FileNode, badgeText: String?) {
            icon.text = iconFor(node)
            name.text = node.displayName
            meta.text = metaFor(node)

            badge.visibility = if (badgeText != null) View.VISIBLE else View.GONE
            badge.text = badgeText

            chevron.visibility = if (node.isDirectory) View.VISIBLE else View.GONE

            itemView.setOnClickListener { onClick(node) }
            itemView.setOnLongClickListener {
                onLongClick(node)
                true
            }
        }

        private fun iconFor(node: FileNode): String = when {
            node.isDirectory -> "📁"
            else -> when (SupportedFileType.detect(node.name)) {
                SupportedFileType.MARKDOWN -> "M"
                SupportedFileType.IMAGE -> "🖼"
                SupportedFileType.HTML -> "◈"
                SupportedFileType.TEXT -> "≡"
                SupportedFileType.OTHER -> "?"
            }
        }

        private fun metaFor(node: FileNode): String {
            if (node.isDirectory) return ""
            val date = if (node.modifiedAt > 0) {
                DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(node.modifiedAt))
            } else null
            val size = if (node.size > 0) SupportedFileType.formattedFileSize(node.size) else null
            return listOfNotNull(date, size).joinToString(" · ")
        }
    }
}
