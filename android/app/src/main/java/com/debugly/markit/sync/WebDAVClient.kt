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
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

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
    private val USER_AGENT = "MarkIt/0.4.0 (Android)"
    private val auth: String

    /**
     * The client's host, parsed once so the proxy decision can be made before
     * any request is built.
     */
    private val baseHost: String by lazy {
        try {
            base.trimEnd('/').substringAfter("://").substringBefore('/')
                .substringBefore(':')
        } catch (e: Exception) {
            ""
        }
    }

    private val http: OkHttpClient = buildClient()

    private fun buildClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
        builder.connectTimeout(15, TimeUnit.SECONDS)
        builder.readTimeout(60, TimeUnit.SECONDS)
        builder.writeTimeout(60, TimeUnit.SECONDS)
        // A WebDAV server on the user's own LAN sits behind whatever system
        // proxy or VPN the device is configured with, so a proxied request either
        // stalls or comes back as a gateway error. Bypass it for private hosts.
        // Public hosts stay on OkHttp's default, which honours the system
        // selector -- what a user who set up a proxy deliberately expects.
        if (isPrivateHost(baseHost)) {
            builder.proxy(java.net.Proxy.NO_PROXY)
        }
        return builder.build()
    }

    init {
        val raw = "$username:$password"
        auth = "Basic " + try {
            Base64.encodeToString(raw.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        } catch (e: UnsupportedEncodingException) {

            throw WebDAVException("编码认证信息失败")
        }
    }

    /**
     * Joins [remotePath] onto the base URL, escaping each segment but keeping
     * the separators.
     *
     * The whole path must NOT go through URLEncoder: that escapes "/" as "%2F",
     * so "notes/sub" would ask the server for a single directory literally named
     * "notes%2Fsub" and every request 404s. Segment-wise escaping leaves the
     * hierarchy intact while still escaping spaces and non-ASCII in folder names.
     */
    private fun makeUrl(remotePath: String, isDirectory: Boolean = false): String {
        val trimmed = remotePath.trim('/')
        if (trimmed.isEmpty()) return base
        var encoded = trimmed.split('/').joinToString("/") { segment -> percentEncodePathSegment(segment) }
        if (isDirectory && !encoded.endsWith("/")) encoded += "/"
        return base + encoded
    }


    /**
     * Percent-encodes one path segment the way URLSession does with
     * .urlPathAllowed: unreserved characters and the sub-delimiters legal in a
     * path survive, everything else becomes %XX. Form encoding (URLEncoder) is
     * the wrong tool here -- it escapes "/" and turns a directory path into a
     * single nonsense segment.
     */
    private fun percentEncodePathSegment(segment: String): String {
        val sb = StringBuilder(segment.length + 8)
        for (b in segment.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt().toChar()
            when {
                c.isLetterOrDigit() && b >= 0 -> sb.append(c)
                c in "-._~!$&'()*+,;=:@" -> sb.append(c)
                c == '/' -> sb.append('/')
                else -> sb.append('%').append("%02X".format(b.toInt() and 0xFF))
            }
        }
        return sb.toString()
    }


    /**
     * True for loopback and RFC1918 literals, i.e. hosts reachable only from
     * inside the LAN a proxy cannot see.
     */
    private fun isPrivateHost(host: String): Boolean {
        if (host == "localhost") return true
        val parts = host.split('.')
        if (parts.size != 4) return host.endsWith(".local")
        val n = parts.mapNotNull { it.toIntOrNull() }
        if (n.size != 4) return false
        return when {
            n[0] == 127 -> true
            n[0] == 10 -> true
            n[0] == 192 && n[1] == 168 -> true
            n[0] == 172 && n[1] in 16..31 -> true
            n[0] == 169 && n[1] == 254 -> true
            else -> false
        }
    }


    /**
     * Runs one WebDAV request on the shared OkHttp client.
     *
     * Everything goes through here rather than through HttpURLConnection. The
     * two stacks share a connection pool and a DNS cache but not a timeout
     * policy, and mixing them meant an upload could complete while the next
     * PROPFIND was already timing out against the old 30s read timeout. OkHttp
     * also accepts arbitrary verbs natively, which HttpURLConnection does not:
     * its setRequestMethod rejects PROPFIND, MKCOL, MOVE and PROPPATCH unless the
     * private method field is poked with reflection.
     */
    private fun execute(
        remotePath: String,
        method: String,
        isDirectory: Boolean = false,
        headers: Map<String, String> = emptyMap(),
        body: okhttp3.RequestBody? = null
    ): okhttp3.Response {
        val builder = okhttp3.Request.Builder()
            .url(makeUrl(remotePath, isDirectory))
            .method(method, body)
            .header("Authorization", auth)
            .header("User-Agent", USER_AGENT)
        headers.forEach { (k, v) -> builder.header(k, v) }
        return http.newCall(builder.build()).execute()
    }

    suspend fun testConnection(remotePath: String = ""): Boolean = withContext(Dispatchers.IO) {
        execute(
            remotePath, "PROPFIND", isDirectory = true,
            headers = mapOf("Depth" to "0", "Content-Type" to "application/xml; charset=utf-8")
        ).use { response ->
            when (val code = response.code) {
                401, 403 -> throw WebDAVException("身份验证失败，请检查用户名和密码")
                // Reachable and authenticated; the folder just does not exist yet.
                404 -> true
                in 200..299 -> true
                // Some servers (notably older Synology) refuse PROPFIND; fall
                // back to OPTIONS and see whether it reports WebDAV support.
                405 -> execute(remotePath, "OPTIONS", isDirectory = true).use { opt ->
                    opt.code in 200..299 ||
                        (opt.header("DAV") ?: "").contains("DAV", ignoreCase = true)
                }
                else -> throw WebDAVException("服务器错误 ($code)")
            }
        }
    }

    /**
     * Depth:1 listing of [remotePath]. Parsed with XmlPullParser rather than
     * regex: href values are percent-encoded and often contain spaces, which
     * is exactly where a regex parse goes wrong.
     */
    suspend fun list(remotePath: String): List<FileNode> = withContext(Dispatchers.IO) {
        val nodes: MutableList<FileNode> = mutableListOf()

        execute(
            remotePath, "PROPFIND", isDirectory = true,
            headers = mapOf("Depth" to "1", "Content-Type" to "application/xml; charset=utf-8")
        ).use { response ->
            when (val code = response.code) {
                401, 403 -> throw WebDAVException("身份验证失败，请检查用户名和密码")
                // A folder that does not exist yet is empty, not an error.
                404 -> return@withContext emptyList()
                !in 200..299 -> throw WebDAVException(
                    "服务器错误 ($code)" + parseErrorHint(code, response.body?.string().orEmpty())
                )
            }

            val xml = response.body?.string().orEmpty()
            val parser = Xml.newPullParser()
            parser.setInput(StringReader(xml))

            var href = ""
            var isCollection = false
            var contentLength = 0L
            var lastModified = 0L
            var currentTag = ""

            var event = parser.eventType
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
        execute(remotePath, "GET").use { response ->
            when (response.code) {
                401, 403 -> throw WebDAVException("身份验证失败")
                404 -> throw WebDAVException("未找到文件: $remotePath")
                in 200..299 -> response.body?.bytes() ?: ByteArray(0)
                else -> throw WebDAVException("下载失败 (${response.code}): $remotePath")
            }
        }
    }

    suspend fun upload(remotePath: String, data: ByteArray, contentType: String = "text/markdown; charset=utf-8") =
        withContext(Dispatchers.IO) {
        val request = okhttp3.Request.Builder()
            .url(makeUrl(remotePath))
            .put(data.toRequestBody(contentType.toMediaType()))
            .header("Authorization", auth)
            .header("User-Agent", USER_AGENT)
            // OkHttp attaches "Expect: 100-continue" to any request carrying a
            // body and then waits for the server to invite the body before
            // writing a single byte. Plenty of servers never answer that interim
            // response -- wsgidav behind wsgiref does not, and that is a very
            // common home-lab setup -- so the upload sat there until writeTimeout
            // fired and the PUT timed out with the body never having left the
            // device. Sending it straight away is what curl does, and it costs
            // nothing on servers that would have replied 100.
            .header("Expect", "")
            .build()

        http.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw WebDAVException(
                    "上传失败 (${response.code}): $remotePath" +
                        parseErrorHint(response.code, body)
                )
            }
        }
    }

    suspend fun createDirectory(remotePath: String) = withContext(Dispatchers.IO) {
        val request = okhttp3.Request.Builder()
            .url(makeUrl(remotePath, isDirectory = true))
            .method("MKCOL", null)
            .header("Authorization", auth)
            .header("User-Agent", USER_AGENT)
            .build()

        http.newCall(request).execute().use { response ->
            // 405 is the documented "already exists" case, notably on Synology.
            if (response.isSuccessful || response.code == 405) return@use
            throw WebDAVException("创建目录失败 (${response.code}): $remotePath")
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

    /**
     * Removes a file or a collection.
     *
     * The trailing slash is not cosmetic: RFC 4918 requires it to identify a
     * collection, and several servers refuse a DELETE of a collection without
     * one. Callers therefore say which they mean rather than having the path
     * guessed from its shape.
     */
    suspend fun delete(remotePath: String, isDirectory: Boolean = false) = withContext(Dispatchers.IO) {
        execute(remotePath, "DELETE", isDirectory = isDirectory).use { response ->
            when (val code = response.code) {
                404 -> Unit   // already gone
                in 200..299 -> Unit
                else -> throw WebDAVException("删除失败 ($code): $remotePath")
            }
        }
    }

    suspend fun move(from: String, to: String) = withContext(Dispatchers.IO) {
        execute(
            from, "MOVE",
            headers = mapOf(
                "Destination" to makeUrl(to, isDirectory = false),
                "Overwrite" to "T"
            )
        ).use { response ->
            val code = response.code
            if (code !in 200..299) {
                throw WebDAVException("移动失败 ($code): $from -> $to")
            }
        }
    }
}
