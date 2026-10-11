package com.debugly.markit.ui

import android.util.Log
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors

/**
 * Serves the editor page over loopback instead of loading it from file://.
 *
 * Chromium treats a file: URL as an opaque origin, and an uncaught error in a
 * page loaded that way comes back as an anonymous "Script error." with no file,
 * no line and no message. That is unusable: a typo in the editor template and a
 * missing Tiptap bundle look identical, and both look like a note that has not
 * finished loading. Serving over http://127.0.0.1 gives the page a real origin,
 * so errors carry their message and their position.
 *
 * It also matters for notes embedding images from the vault, which file: pages
 * cannot reach.
 *
 * Written on plain sockets because com.sun.net.httpserver does not exist on
 * Android. It answers GET and nothing else -- the editor needs no other verb --
 * and only ever listens on loopback, for the lifetime of one Activity.
 */
class LocalAssetServer(
    private val requestedPort: Int,
    private val resolve: (String) -> File?
) {
    private var socket: ServerSocket? = null
    private var worker: java.util.concurrent.ExecutorService? = null

    val port: Int get() = socket?.localPort ?: -1

    fun start() {
        val server = ServerSocket(requestedPort, 4, InetAddress.getByName("127.0.0.1"))
        val pool = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "markit-editor-http").apply { isDaemon = true }
        }
        socket = server
        worker = pool

        Thread({
            while (!server.isClosed) {
                try {
                    val client = server.accept()
                    pool.execute { serve(client) }
                } catch (e: Exception) {
                    if (!server.isClosed) Log.w(TAG, "accept failed: ${e.message}")
                    return@Thread
                }
            }
        }, "markit-editor-accept").apply { isDaemon = true }.start()
    }

    private fun serve(client: Socket) {
        client.use { connection ->
            val input = connection.getInputStream().bufferedReader()
            val requestLine = input.readLine() ?: return
            // Drain the headers; the request has no body.
            while (true) {
                val line = input.readLine() ?: break
                if (line.isEmpty()) break
            }

            val path = requestLine.split(' ').getOrNull(1)?.substringBefore('?').orEmpty()
            val file = resolve(path.removePrefix("/"))

            connection.soTimeout = 5000
            val out = connection.getOutputStream()
            if (file == null || !file.isFile) {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                out.flush()
                return
            }

            Log.i(TAG, "serving ${file.name} (${file.length()} bytes) for $path")
            val body = file.readBytes()
            // A script served as text/html is refused by the browser, and the
            // resulting failure looks identical to a bundle that failed to parse.
            val contentType = if (path.endsWith(".js")) {
                "application/javascript; charset=utf-8"
            } else {
                "text/html; charset=utf-8"
            }
            val header = buildString {
                append("HTTP/1.1 200 OK\r\n")
                append("Content-Type: ").append(contentType).append("\r\n")
                append("Content-Length: ").append(body.size).append("\r\n")
                // The page is rebuilt on every launch, so a cached copy would keep
                // showing the previous template after a fix.
                append("Cache-Control: no-store\r\n")
                append("Connection: close\r\n\r\n")
            }
            out.write(header.toByteArray())
            out.write(body)
            out.flush()
        }
    }

    fun stop() {
        try {
            socket?.close()
        } catch (e: Exception) {
            // Closing an already-closed socket is not worth reporting.
        }
        socket = null
        worker?.shutdownNow()
        worker = null
    }

    companion object {
        const val TAG = "MarkItEditor"
    }
}
