package com.debugly.markit.sync

import android.util.Base64
import android.util.Xml
import com.debugly.markit.model.FileNode
import com.debugly.markit.model.FrontMatterParser
import com.debugly.markit.model.JekyllFrontMatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.xmlpull.v1.XmlPullParser
import java.io.StringReader
import java.io.UnsupportedEncodingException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class WebDAVException(message: String) : Exception(message)

/**
 * Ported from Sources/MarkItApp/Sync/WebDAVClient.swift.
 *
 * Deliberately keeps the Mac app's behaviour rather than reinventing it:
 * Depth:1 PROPFIND for listings, MKCOL for directories, PUT/MOVE for writes,
 * and the same 404-means-ok rule on the connection probe (the server answered,
 * the credentials are good, the folder just does not exist yet).
 */
class WebDAVClient(baseUrl: String, username: String, password: String) {

    private val base: String = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val auth: String

    init {
        val raw = "$username:$password"
        auth = "Basic " + try {
            Base64.encodeToString(raw.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        } catch (e: UnsupportedEncodingException) {
            throw WebDAVException("编码认证信息失败")
        }
    }

    private fun makeUrl(remotePath: String, isDirectory: Boolean = false): String {
        val trimmed = remotePath.trim('/')
        if (trimmed.isEmpty()) return base
        var encoded = try {
            URLEncoder.encode(trimmed, "UTF-8").replace("+", "%20")
        } catch (e: Exception) {
            trimmed
        }
        if (isDirectory && !encoded.endsWith("/")) encoded += "/"
        return base + encoded
    }

    private fun request(url: String, method: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.setRequestProperty("Authorization", auth)
        conn.setRequestProperty("User-Agent", "MarkIt/0.4.0 (Android)")
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        return conn
    }

    /** Reads a response body, honouring gzip when the server compresses it. */
    private fun body(conn: HttpURLConnection): String {
        val encoding = conn.getHeaderField("Content-Encoding") ?: ""
        val stream = if (encoding.contains("gzip", true)) {
            java.util.zip.GZIPInputStream(conn.inputStream)
        } else {
            conn.inputStream
        }
        return stream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private fun errorStream(conn: HttpURLConnection): String = try {
        conn.errorStream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
    } catch (e: Exception) {
        ""
    }

    suspend fun testConnection(remotePath: String = ""): Boolean = withContext(Dispatchers.IO) {
        val url = makeUrl(remotePath, isDirectory = true)
        val conn = request(url, "PROPFIND")
        val code: Int
        try {
            conn.setRequestProperty("Depth", "0")
            conn.setRequestProperty("Content-Type", "application/xml; charset=utf-8")
            code = conn.responseCode
        } finally {
            conn.disconnect()
        }

        when (code) {
            401 -> throw WebDAVException("身份验证失败，请检查用户名和密码")
            // Reachable and authenticated; the folder just does not exist yet.
            404 -> return@withContext true
            in 200..299 -> return@withContext true
            // Some servers (notably older Synology) refuse PROPFIND; fall back to
            // OPTIONS and see whether it at least reports WebDAV support.
            405 -> {
                val opt = request(url, "OPTIONS")
                return@withContext try {
                    val dav = opt.getHeaderField("DAV").orEmpty()
                    opt.responseCode in 200..299 || dav.contains("DAV", ignoreCase = true)
                } finally {
                    opt.disconnect()
                }
            }
            else -> throw WebDAVException("服务器错误 ($code)")
        }
    }

    /**
     * Depth:1 listing of [remotePath]. Parsed with XmlPullParser rather than
     * regex: href values are percent-encoded and often contain spaces, which
     * is exactly where a regex parse goes wrong.
     */
    suspend fun list(remotePath: String): List<FileNode> = withContext(Dispatchers.IO) {
        val url = makeUrl(remotePath, isDirectory = true)
        val conn = request(url, "PROPFIND")
        val nodes: MutableList<FileNode> = mutableListOf()

        try {
            conn.setRequestProperty("Depth", "1")
            conn.setRequestProperty("Content-Type", "application/xml; charset=utf-8")
            val code = conn.responseCode
            if (code == 401) throw WebDAVException("身份验证失败，请检查用户名和密码")
            if (code == 404) return@withContext emptyList()
            if (code !in 200..299) {
                throw WebDAVException(
                    "服务器错误 ($code)" + parseErrorHint(code, errorStream(conn))
                )
            }

            val xml = body(conn)
            val parser = Xml.newPullParser()
            parser.setInput(StringReader(xml))

            var href = ""
            var isCollection = false
            var contentLength = 0L
            var lastModified = 0L

            var event = parser.eventType
            var currentTag = ""
            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> {
                        currentTag = parser.name.lowercase()
                        if (currentTag == "response") {
                            href = ""; isCollection = false
                            contentLength = 0L; lastModified = 0L
                        } else if (currentTag == "collection") {
                            isCollection = true
                        }
                    }
                    XmlPullParser.TEXT -> {
                        val text = parser.text?.trim() ?: ""
                        when (currentTag) {
                            "href" -> if (text.isNotEmpty()) href = text
                            "getcontentlength" -> contentLength = text.toLongOrNull() ?: 0L
                            "getlastmodified" -> lastModified = parseHttpDate(text)
                        }
                    }
                    XmlPullParser.END_TAG -> {
                        if (parser.name.equals("response", true)) {
                            addNode(nodes, href, isCollection, contentLength, lastModified, remotePath)
                        }
                        currentTag = ""
                    }
                }
                event = parser.next()
            }
        } finally {
            conn.disconnect()
        }

        nodes.sortedWith(compareByDescending<FileNode> { it.isDirectory }.thenBy { it.name.lowercase() })
    }

    /** Drops the collection itself and anything outside [parentPath]. */
    private fun addNode(
        into: MutableList<FileNode>,
        href: String,
        isCollection: Boolean,
        size: Long,
        modified: Long,
        parentPath: String
    ) {
        var name = href.trim()
        if (name.endsWith("/")) name = name.dropLast(1)
        name = name.substringAfterLast('/')
        if (name.isEmpty()) return
        name = percentDecode(name)

        // The collection for the path we asked about is the one to skip.
        val parentName = parentPath.trim('/').substringAfterLast('/')
        if (isCollection && name == parentName) return

        val path = if (parentPath.trim('/').isEmpty()) name
                   else "${parentPath.trim('/')}/$name"

        val node = if (isCollection) {
            FileNode(path, true, size = size, modifiedAt = modified)
        } else {
            FileNode(path, false, frontMatter = null, size = size, modifiedAt = modified)
        }
        into.add(node)
    }

    private fun percentDecode(s: String): String = try {
        java.net.URLDecoder.decode(s, "UTF-8")
    } catch (e: Exception) {
        s
    }

    private fun parseHttpDate(raw: String): Long {
        val formats = listOf(
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        for (f in formats) {
            try {
                val fmt = java.text.SimpleDateFormat(f, java.util.Locale.US)
                fmt.timeZone = java.util.TimeZone.getTimeZone("GMT")
                return fmt.parse(raw)?.time ?: continue
            } catch (e: Exception) { }
        }
        return 0L
    }

    /** Synology returns 405 on MKCOL at the share root; the Mac app has the same hint. */
    private fun parseErrorHint(code: Int, body: String): String {
        if (code == 405 && body.isNotBlank() && !body.contains("method not allowed", true)) {
            return " | $body"
        }
        return ""
    }

    suspend fun download(remotePath: String): ByteArray = withContext(Dispatchers.IO) {
        val conn = request(makeUrl(remotePath), "GET")
        try {
            when (val c = conn.responseCode) {
                401 -> throw WebDAVException("身份验证失败")
                404 -> throw WebDAVException("未找到文件: $remotePath")
                in 200..299 -> conn.inputStream.use { it.readBytes() }
                else -> throw WebDAVException("下载失败 ($c): $remotePath")
            }
        } finally {
            conn.disconnect()
        }
    }

    suspend fun upload(remotePath: String, data: ByteArray, contentType: String = "text/markdown; charset=utf-8") =
        withContext(Dispatchers.IO) {
        val conn = request(makeUrl(remotePath), "PUT")
        try {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", contentType)
            conn.setFixedLengthStreamingMode(data.size)
            conn.outputStream.use { it.write(data) }
            val code = conn.responseCode
            if (code !in 200..299) {
                throw WebDAVException("上传失败 ($code): $remotePath" + parseErrorHint(code, errorStream(conn)))
            }
        } finally {
            conn.disconnect()
        }
    }

    suspend fun createDirectory(remotePath: String) = withContext(Dispatchers.IO) {
        val conn = request(makeUrl(remotePath, isDirectory = true), "MKCOL")
        try {
            val code = conn.responseCode
            // 405 here is the documented Synology case, not a hard failure.
            if (code in 200..299 || code == 405) return@withContext
            throw WebDAVException("创建目录失败 ($code): $remotePath")
        } finally {
            conn.disconnect()
        }
    }

    /** Creates every missing segment of [remotePath]. */
    suspend fun ensureDirectory(remotePath: String) {
        val segments = remotePath.trim('/').split('/').filter { it.isNotEmpty() }
        var acc = ""
        for (seg in segments) {
            acc = if (acc.isEmpty()) seg else "$acc/$seg"
            createDirectory(acc)
        }
    }

    suspend fun delete(remotePath: String) = withContext(Dispatchers.IO) {
        val conn = request(makeUrl(remotePath, isDirectory = true), "DELETE")
        try {
            val code = conn.responseCode
            if (code == 404) return@withContext   // already gone
            if (code !in 200..299) {
                throw WebDAVException("删除失败 ($code): $remotePath")
            }
        } finally {
            conn.disconnect()
        }
    }

    suspend fun move(from: String, to: String) = withContext(Dispatchers.IO) {
        val conn = request(makeUrl(from), "MOVE")
        try {
            conn.setRequestProperty("Destination", makeUrl(to, isDirectory = false))
            conn.setRequestProperty("Overwrite", "T")
            val code = conn.responseCode
            if (code !in 200..299) {
                throw WebDAVException("移动失败 ($code): $from -> $to")
            }
        } finally {
            conn.disconnect()
        }
    }
}
