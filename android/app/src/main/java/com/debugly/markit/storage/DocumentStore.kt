package com.debugly.markit.storage

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.debugly.markit.model.FileNode
import com.debugly.markit.model.SupportedFileType

/**
 * SAF-backed file access, replacing the macOS build's FileManager calls.
 *
 * The vault lives in a directory the user picked with ACTION_OPEN_DOCUMENT_TREE,
 * so files stay visible to other apps -- "open externally" depends on that.
 * Everything goes through ContentResolver: on Android there is no filesystem path
 * behind a content:// URI, so the tree URI has to be threaded through every call.
 */
class DocumentStore(private val context: Context, private val treeUri: Uri) {

    /**
     * Memoised document existence. DocumentsProvider queries are Binder round
     * trips; sync would otherwise make several per file and turn a two-file
     * sync into a minute of waiting. Entries are invalidated by listings and by
     * writes, so a cached "missing" cannot outlive a file that was just created.
     */
    private val knownDocuments = mutableMapOf<String, Boolean>()

    private val resolver: ContentResolver get() = context.contentResolver

    /** True when we still hold write permission on the tree. */
    fun hasPermission(): Boolean =
        context.contentResolver.persistedUriPermissions
            .any { it.uri == treeUri && it.isWritePermission }

    /** Builds a document URI for a vault-relative path, or null if unreachable. */
    fun uriFor(path: String): Uri? = try {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        // list() hands back paths that already include the root folder name, so
        // prepending the tree id again would look for MarkIt/MarkIt/....
        val clean = path.trim('/')
        val docId = if (clean.startsWith("$treeId/") || clean == treeId) clean
                    else "$treeId/$clean"
        val candidate = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        if (documentExists(candidate)) candidate else null
    } catch (e: Exception) {
        null
    }

    /**
     * True when [uri] resolves to a real document.
     *
     * Every call here is a Binder round trip to the DocumentsProvider, and
     * sync makes several per file (existence check, read, then the next
     * directory listing). Doing them serially is what made a two-file sync take
     * the better part of a minute, so the results are cached: a document that
     * has been created by this process is known to exist, and entries are
     * dropped whenever a listing refreshes the truth.
     */
    private fun documentExists(uri: Uri): Boolean {
        val key = uri.toString()
        knownDocuments[key]?.let { return it }

        val present = resolver.query(
            uri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null
        )?.use { it.moveToFirst() } == true

        knownDocuments[key] = present
        return present
    }

    /** Forgets cached existence for everything under [dirPath]. */
    private fun invalidateUnder(dirPath: String) {
        val prefix = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            if (dirPath.isBlank()) DocumentsContract.getTreeDocumentId(treeUri)
            else "${DocumentsContract.getTreeDocumentId(treeUri)}/$dirPath"
        ).toString()
        val keep = knownDocuments.keys.filter { !it.startsWith(prefix) }.toSet()
        knownDocuments.keys.retainAll(keep)
    }

fun list(dirPath: String = ""): List<FileNode> {
        val nodes = mutableListOf<FileNode>()

        val children = try {
            val parentId = if (dirPath.isBlank()) DocumentsContract.getTreeDocumentId(treeUri)
                           else "${DocumentsContract.getTreeDocumentId(treeUri)}/$dirPath"
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        } catch (e: Exception) {
            null
        } ?: return emptyList()

        // A listing is authoritative for its directory, so drop the cached
        // verdicts for anything under it before repopulating.
        invalidateUnder(dirPath)

        resolver.query(children, null, null, null, null)?.use { c ->
            while (c.moveToNext()) nodes.add(toNode(c, dirPath))
        }

        return nodes.sortedWith(
            compareByDescending<FileNode> { it.isDirectory }.thenBy { it.name.lowercase() }
        )
    }

    /**
     * Strips the tree root ("primary:MarkIt/") off a SAF document id so paths
     * stay relative to the picked folder. DocumentStore addresses everything by
     * these relative paths, and uriFor() re-adds the root when it builds a URI.
     */
    private fun relativeToRoot(docId: String): String {
        val name = docId.substringAfterLast(':')
        val root = DocumentsContract.getTreeDocumentId(treeUri)
        val rootName = root.substringAfterLast(':')
        return when {
            name == rootName -> ""
            name.startsWith("$rootName/") -> name.removePrefix("$rootName/")
            else -> name
        }
    }

    private fun toNode(c: Cursor, parentPath: String): FileNode {
        val docId = c.getStringOrNull(DocumentsContract.Document.COLUMN_DOCUMENT_ID).orEmpty()
        val name = c.getStringOrNull(DocumentsContract.Document.COLUMN_DISPLAY_NAME).orEmpty()
        val mime = c.getStringOrNull(DocumentsContract.Document.COLUMN_MIME_TYPE).orEmpty()
        val size = c.getLongOrZero(DocumentsContract.Document.COLUMN_SIZE)
        val modified = c.getLongOrZero(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR

        // Prefer the provider's display name; the doc id is only a fallback.
        val namePart = if (name.isNotEmpty()) name else relativeToRoot(docId).substringAfterLast('/')
        val path = if (parentPath.isBlank()) namePart else "$parentPath/$namePart"

        return FileNode(
            path = path,
            isDirectory = isDir,
            frontMatter = null,
            size = size,
            modifiedAt = modified
        )
    }

    fun readText(path: String): String {
        val uri = uriFor(path) ?: throw StorageException("文件不存在: $path")
        return resolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
    }

    fun readBytes(path: String): ByteArray {
        val uri = uriFor(path) ?: throw StorageException("文件不存在: $path")
        return resolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
    }

    /**
     * SAF has no in-place truncate, so writes go through "wt" (write-truncate).
     * Creates the document when it does not exist yet.
     */
    fun writeText(path: String, content: String) {
        val existing = uriFor(path)
        if (existing != null) {
            resolver.openOutputStream(existing, "wt")?.use {
                it.write(content.toByteArray(Charsets.UTF_8))
            } ?: throw StorageException("无法写入: $path")
            return
        }

        val parentPath = path.substringBeforeLast('/', "")
        val name = path.substringAfterLast('/')
        val parent = uriFor(parentPath)
            ?: DocumentsContract.buildDocumentUriUsingTree(
                treeUri, DocumentsContract.getTreeDocumentId(treeUri)
            )

        val doc = DocumentsContract.createDocument(resolver, parent, mimeFor(name), name)
            ?: throw StorageException("无法创建文件: $path")
        invalidateUnder(parentPath)
        resolver.openOutputStream(doc, "wt")?.use {
            it.write(content.toByteArray(Charsets.UTF_8))
        } ?: throw StorageException("无法写入: $path")
    }

    fun delete(path: String): Boolean {
        invalidateUnder(path.substringBeforeLast('/', ""))
        val uri = uriFor(path) ?: return false
        return try {
            DocumentsContract.deleteDocument(resolver, uri)
        } catch (e: Exception) {
            false
        }
    }

    fun createDirectory(path: String) {
        val parentPath = path.substringBeforeLast('/', "")
        val name = path.substringAfterLast('/')
        val parent = uriFor(parentPath)
            ?: DocumentsContract.buildDocumentUriUsingTree(
                treeUri, DocumentsContract.getTreeDocumentId(treeUri)
            )
        DocumentsContract.createDocument(
            resolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw StorageException("无法创建文件夹: $path")
    }

    fun rename(path: String, newName: String): Boolean {
        val uri = uriFor(path) ?: return false
        return try {
            DocumentsContract.renameDocument(resolver, uri, newName) != null
        } catch (e: Exception) {
            false
        }
    }

    /**
     * The picked folder, for showing in settings.
     *
     * Decoded from the tree id rather than read back through a listing, so the
     * settings screen says which folder is in use without doing SAF work on the
     * main thread just to render a label.
     */
    fun describeRoot(): String = try {
        DocumentsContract.getTreeDocumentId(treeUri).substringAfterLast(':').ifBlank { treeUri.toString() }
    } catch (e: Exception) {
        treeUri.toString()
    }

    /** True when [path] resolves to a document. Cached, so cheap to call. */
    fun exists(path: String): Boolean = uriFor(path) != null

    /**
     * True when [path] is a folder rather than a file.
     *
     * False for anything unreachable, which is what callers want: a path that no
     * longer resolves should not be treated as a file either.
     */
    fun isDirectory(path: String): Boolean {
        val uri = uriFor(path) ?: return false
        return try {
            resolver.query(
                uri, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null
            )?.use { c ->
                if (!c.moveToFirst()) return false
                c.getStringOrNull(DocumentsContract.Document.COLUMN_MIME_TYPE) ==
                    DocumentsContract.Document.MIME_TYPE_DIR
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    /** For "open externally": a shareable uri plus the content type to declare. */
    fun shareInfo(path: String): Pair<Uri, String>? {
        val uri = uriFor(path) ?: return null
        return uri to mimeFor(path.substringAfterLast('/'))
    }

    private fun mimeFor(name: String): String = when (SupportedFileType.detect(name)) {
        SupportedFileType.MARKDOWN -> "text/markdown"
        SupportedFileType.HTML -> "text/html"
        SupportedFileType.TEXT -> "text/plain"
        SupportedFileType.IMAGE -> "image/*"
        SupportedFileType.OTHER -> "application/octet-stream"
    }

    private fun Cursor.getStringOrNull(col: String): String? {
        val i = getColumnIndex(col)
        return if (i >= 0 && !isNull(i)) getString(i) else null
    }

    private fun Cursor.getLongOrZero(col: String): Long {
        val i = getColumnIndex(col)
        return if (i >= 0 && !isNull(i)) getLong(i) else 0L
    }
}

class StorageException(message: String) : Exception(message)
