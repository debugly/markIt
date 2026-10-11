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

    private val resolver: ContentResolver get() = context.contentResolver

    /** True when we still hold write permission on the tree. */
    fun hasPermission(): Boolean =
        context.contentResolver.persistedUriPermissions
            .any { it.uri == treeUri && it.isWritePermission }

    /** Builds a document URI for a vault-relative path, or null if unreachable. */
    fun uriFor(path: String): Uri? = try {
        val docId = "${DocumentsContract.getTreeDocumentId(treeUri)}/$path"
        val candidate = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        // Query to confirm it exists; buildDocumentUri does not validate.
        if (resolver.query(candidate, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                           null, null, null)?.use { it.moveToFirst() } == true) candidate else null
    } catch (e: Exception) {
        null
    }

    /** Lists one level below [dirPath]. */
    fun list(dirPath: String = ""): List<FileNode> {
        val nodes = mutableListOf<FileNode>()

        val children = try {
            val parentId = if (dirPath.isBlank()) DocumentsContract.getTreeDocumentId(treeUri)
                           else "${DocumentsContract.getTreeDocumentId(treeUri)}/$dirPath"
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        } catch (e: Exception) {
            null
        } ?: return emptyList()

        resolver.query(children, null, null, null, null)?.use { c ->
            while (c.moveToNext()) nodes.add(toNode(c, dirPath))
        }

        return nodes.sortedWith(
            compareByDescending<FileNode> { it.isDirectory }.thenBy { it.name.lowercase() }
        )
    }

    private fun toNode(c: Cursor, parentPath: String): FileNode {
        val docId = c.getStringOrNull(DocumentsContract.Document.COLUMN_DOCUMENT_ID).orEmpty()
        val name = c.getStringOrNull(DocumentsContract.Document.COLUMN_DISPLAY_NAME).orEmpty()
        val mime = c.getStringOrNull(DocumentsContract.Document.COLUMN_MIME_TYPE).orEmpty()
        val size = c.getLongOrZero(DocumentsContract.Document.COLUMN_SIZE)
        val modified = c.getLongOrZero(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR

        val namePart = docId.substringAfterLast(':')
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
        resolver.openOutputStream(doc, "wt")?.use {
            it.write(content.toByteArray(Charsets.UTF_8))
        } ?: throw StorageException("无法写入: $path")
    }

    fun delete(path: String): Boolean {
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
