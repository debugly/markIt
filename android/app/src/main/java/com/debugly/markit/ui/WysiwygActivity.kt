package com.debugly.markit.ui

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ImageButton
import android.widget.EditText
import android.widget.TextView
import com.debugly.markit.R
import com.debugly.markit.model.FrontMatterParser
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.sync.SyncRegistry
import java.io.File
import java.util.concurrent.Executors

/**
 * What-you-see-is-what-you-get Markdown editor.
 *
 * Same approach as the macOS build: Tiptap in a WebView, with the page talking
 * back over a JavaScript bridge. The editor template is the one the Mac app
 * uses, so the slash menu, task lists, tables and the Jekyll header card behave
 * identically on both platforms rather than being reimplemented and drifting.
 *
 * What differs is the bridge. WKWebView posts named messages through
 * WKScriptMessageHandler; Android's WebView exposes methods annotated with
 * @JavascriptInterface directly on an object added to the page. The template
 * was rewritten to call those instead, so the two share one template and
 * differ only in the few lines that talk to the host.
 *
 * The toolbar calls back into the page rather than reimplementing any editing
 * logic in Kotlin, so bold on a phone and bold on a Mac produce identical
 * markdown.
 */
class WysiwygActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var sourceEditor: EditText
    /** True while the raw markdown is on screen instead of the rendered note. */
    private var showingSource = false
    private lateinit var statusBar: TextView
    private lateinit var titleText: TextView

    private var path = ""
    private var editorReady = false
    private var dirty = false

    /** Latest markdown reported by the page; what a save writes. */
    private var markdown = ""
    private val io = Executors.newSingleThreadExecutor()
    private var localServer: LocalAssetServer? = null

    private var frontMatterTitle: String = ""
    private var frontMatterDate: String = ""
    private var frontMatterTags: String = ""
    private var hadFrontMatter = false

    private val frontMatterJson: String
        get() = buildString {
            append("{")
            append("\"title\":").append(quote(frontMatterTitle)).append(",")
            append("\"date\":").append(quote(frontMatterDate)).append(",")
            append("\"tags\":").append(quote(frontMatterTags))
            append("}")
        }

    private fun quote(value: String): String = org.json.JSONObject.quote(value)

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_wysiwyg)

        // Android 15 forces edge to edge, so the toolbar and the status strip
        // would otherwise sit under the system bars. This screen carries its own
        // chrome and the editor canvas is meant to run full height between them,
        // so the bars are inset rather than the whole layout.
        Insets.goEdgeToEdge(this)
        Insets.apply(findViewById(R.id.topBar), top = true, horizontal = true)
        Insets.apply(findViewById(R.id.statusBar), bottom = true, horizontal = true)

        path = intent.getStringExtra(EXTRA_PATH).orEmpty()
        titleText = findViewById(R.id.titleText)
        statusBar = findViewById(R.id.statusBar)
        web = findViewById(R.id.editorWeb)
        sourceEditor = findViewById(R.id.sourceEditor)

        titleText.text = intent.getStringExtra(EXTRA_NAME) ?: path.substringAfterLast('/')

        val settings = web.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        // The page is loaded from assets, and a note can reference images that
        // live beside it in the vault. Without file access the editor renders
        // fine but every local image comes out broken.
        settings.allowFileAccess = true
        settings.allowContentAccess = true
        // The page paints its own surface, so the WebView behind it has to match
        // or the two disagree in the moment before the first paint. Resolved from
        // the same theme the rest of the UI uses.
        web.setBackgroundColor(
            androidx.core.content.ContextCompat.getColor(this, R.color.bg_canvas)
        )
        // Note: do not call useLightIconsOn here. setOnApplyWindowInsetsListener
        // replaces whatever listener a view already has, so pointing it at the
        // toolbar would silently swap out the one applying the toolbar's
        // status-bar padding, putting the toolbar back under the clock with
        // nothing logged. goEdgeToEdge sets the icon appearance already.
        // console.log from the page is only visible with this set; without it the
        // editor's own diagnostics go nowhere and a broken page looks identical
        // to a slow one.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT_WATCH) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        web.webViewClient = object : WebViewClient() {
            override fun onReceivedError(
                view: WebView, request: android.webkit.WebResourceRequest,
                error: android.webkit.WebResourceError
            ) {
                // A blank editor with no explanation is the worst failure mode
                // here: the note is intact on disk either way, but the user
                // cannot tell a broken editor from an empty note.
                Log.e(TAG, "page error: ${error.description} for ${request.url}")
                runOnUiThread { statusBar.text = "编辑器加载失败：${error.description}" }
            }

            override fun onPageFinished(view: WebView, url: String) {
                // onPageFinished can land after the page has already signalled
                // ready -- the editor builds itself synchronously, so on a warm
                // cache the two race. Only set the placeholder while it is still
                // loading, or it overwrites the ready state and the screen looks
                // stuck on a working editor.
                if (!editorReady) statusBar.text = "正在初始化编辑器…"
            }
        }
        web.addJavascriptInterface(Bridge(), "MarkItBridge")

        findViewById<View>(R.id.btnBack).setOnClickListener { finish() }
        findViewById<ImageButton>(R.id.btnBold).setOnClickListener { runCommand("toggleBold") }
        findViewById<ImageButton>(R.id.btnItalic).setOnClickListener { runCommand("toggleItalic") }
        findViewById<ImageButton>(R.id.btnHeading).setOnClickListener { runCommand("toggleHeading") }
        findViewById<ImageButton>(R.id.btnList).setOnClickListener { runCommand("toggleBulletList") }
        findViewById<ImageButton>(R.id.btnSource).setOnClickListener { toggleSource() }
        findViewById<ImageButton>(R.id.btnBack).setOnClickListener { leave() }
        sourceEditor.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(e: android.text.Editable?) {
                if (!showingSource) return
                markdown = e?.toString().orEmpty()
                dirty = true
                updateSourceStatus()
            }
        })

        loadTemplate(intent.getStringExtra(EXTRA_CONTENT).orEmpty())
    }

    private fun loadTemplate(content: String) {
        val template = try {
            assets.open("editor_template.html").bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            Log.e(TAG, "could not read editor template: ${e.message}")
            statusBar.text = "编辑器模板加载失败"
            return
        }
        val bundle = try {
            assets.open("tiptap-bundle.js").bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            Log.e(TAG, "could not read tiptap bundle: ${e.message}")
            statusBar.text = "编辑器组件加载失败"
            return
        }

        // The page is served over loopback rather than loaded through
        // loadDataWithBaseURL or file://. Chromium treats both as opaque origins,
        // and an uncaught error in a page loaded that way comes back as an
        // anonymous "Script error." with no file, no line and no message -- which
        // makes a one-character bug in the template indistinguishable from a
        // missing Tiptap bundle. A real origin restores the detail.
        //
        // The bundle goes in as its own file, not inlined into the page's script
        // element. It contains the literal "<!--" inside a comment-matching
        // regex, and the HTML tokenizer opens a legacy script comment on that
        // sequence anywhere in script data: everything after it is swallowed and
        // the page fails with a syntax error at line 1, in a bundle that is
        // perfectly valid JavaScript. The asset ships with the sequence escaped
        // as \x3C!--, which the tokenizer ignores and the JS parser resolves
        // back to "<!--" when it compiles the regex. Wrapping the inline body in
        // <!-- ... --> does not work either -- the bundle also contains "-->" a
        // few kilobytes later, which closes the wrapper early.
        val stagingDir = File(cacheDir, "wysiwyg").apply { mkdirs() }
        File(stagingDir, "tiptap-bundle.js").writeText(bundle)
        val html = template.replace(
            "<!--TIPTAP_BUNDLE-->",
            """<script src="tiptap-bundle.js"></script>"""
        ).replace(
            "<html lang=\"zh-CN\">",
            "<html lang=\"zh-CN\" data-theme=\"${if (isNightMode()) "dark" else "light"}\">"
        )

        // Split the note: Jekyll front matter goes in the header card, the rest
        // is the document. Reassembled on save, so a note that had front matter
        // keeps it and one that did not never gains an empty block.
        val parsed = FrontMatterParser.parse(content)
        hadFrontMatter = parsed != null
        val body = if (hadFrontMatter) {
            content.substringAfter("---", content).trimStart('\n', '-', '\n')
        } else {
            content
        }
        frontMatterTitle = parsed?.title ?: ""
        frontMatterDate = parsed?.date ?: ""
        // Tags come back as a list; the form field takes them comma separated,
        // which is the shape they are written back in.
        frontMatterTags = parsed?.tags?.joinToString(", ") ?: ""

        val bootstrap = """
            (function() {
                var initialMarkdown = ${org.json.JSONObject.quote(body)};
                var frontMatter = $frontMatterJson;
                var hasFrontMatter = ${hadFrontMatter};
                window.__markitInitial = function() {
                    var card = document.getElementById('jekyll-header-card');
                    if (card && hasFrontMatter) card.style.display = 'block';
                    var t = document.getElementById('jekyll-title-input');
                    var d = document.getElementById('jekyll-date-input');
                    var g = document.getElementById('jekyll-tags-input');
                    if (t) t.value = frontMatter.title || '';
                    if (d) d.value = frontMatter.date || '';
                    if (g) g.value = frontMatter.tags || '';
                    if (window.editor && typeof window.editor.commands.setContent === 'function') {
                        window.editor.commands.setContent(initialMarkdown, { contentType: 'markdown' });
                    }
                };
            })();
        """.trimIndent()

        val errorHook = ""

        val pageFile = File(stagingDir, "index.html")
        pageFile.writeText(html.replace("</head>", "$errorHook<script>$bootstrap</script></head>"))

        // Served over loopback rather than loaded from file://. Chromium treats a
        // file: page as an opaque origin, and reports every uncaught error from
        // it as an anonymous "Script error." with no file, line or message --
        // which makes a one-character bug in the template indistinguishable
        // from a missing Tiptap bundle. A real origin restores the detail.
        // Port 0 lets the OS pick a free one, so this cannot collide with
        // anything else on the device.
        val server = LocalAssetServer(requestedPort = 0) { path ->
            File(stagingDir, path.ifEmpty { "index.html" })
        }
        localServer = server
        server.start()

        // TEMP: bisect by removing the bootstrap.
        web.loadUrl("http://127.0.0.1:${server.port}/index.html")

    }

    private fun runCommand(command: String) {
        if (!editorReady) return
        web.evaluateJavascript(
            "window.markitCommand && window.markitCommand('$command');",
            null
        )
    }

    /**
     * Swaps the rendered note for its raw markdown, in this same screen.
     *
     * A separate activity for this meant a second toolbar, title and back
     * button for the same note, and a back stack entry that outlived the view
     * it was opened to look at. Editing the markup is looking at the same
     * document differently, not going somewhere else.
     */
    private fun toggleSource() {
        if (showingSource) {
            // Commit what was typed here before handing it back to the editor,
            // so the rendered note cannot lag behind the source.
            markdown = sourceEditor.text.toString()
            loadTemplate(currentContent())
            showingSource = false
            sourceEditor.visibility = android.view.View.GONE
            web.visibility = android.view.View.VISIBLE
            updateFormattingButtons()
        } else {
            val text = currentContent()
            if (text != sourceEditor.text.toString()) sourceEditor.setText(text)
            showingSource = true
            sourceEditor.visibility = android.view.View.VISIBLE
            web.visibility = android.view.View.GONE
            // Formatting belongs to the rendered view; offering it over raw
            // text would be offering a toolbar that cannot act on what is shown.
            updateFormattingButtons()
            sourceEditor.requestFocus()
        }
    }

    private fun updateFormattingButtons() {
        val on = !showingSource
        findViewById<ImageButton>(R.id.btnBold).visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
        findViewById<ImageButton>(R.id.btnItalic).visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
        findViewById<ImageButton>(R.id.btnHeading).visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
        findViewById<ImageButton>(R.id.btnList).visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
        // The button names where it takes you, not where it came from. The
        // eye means "go look at the rendered note"; a pencil next to a code
        // glyph, or a code glyph next to a rendered note, both leave the user
        // reading the icon twice.
        findViewById<ImageButton>(R.id.btnSource).setImageResource(
            if (showingSource) R.drawable.ic_preview else R.drawable.ic_code
        )
        findViewById<ImageButton>(R.id.btnSource).contentDescription =
            if (showingSource) "切换回所见即所得" else "切换到源码"
        updateSourceStatus()
    }

    private fun updateSourceStatus() {
        if (!showingSource) return
        statusBar.text = "源码模式"
    }

    /** Leaving the screen always writes. The autosave timer cannot be trusted to have fired. */
    private fun leave() {
        if (dirty) save(syncImmediately = true)
        finish()
    }

    /** Rebuilds the note from the page state and the front matter fields. */
    private fun currentContent(): String {
        if (!hadFrontMatter &&
            frontMatterTitle.isEmpty() && frontMatterDate.isEmpty() && frontMatterTags.isEmpty()) {
            return markdown
        }
        return buildString {
            append("---\n")
            append("title: ").append(frontMatterTitle).append("\n")
            append("date: ").append(frontMatterDate).append("\n")
            append("tags: ").append(frontMatterTags).append("\n")
            append("---\n\n")
            append(markdown)
        }
    }

    /**
     * Writes the note, then arranges for it to reach the server.
     *
     * [syncImmediately] is for the exit path, and it has to happen inside the
     * same task as the write: the write and the sync both go through [io], so
     * flushing separately races them and leaves the flush syncing the pre-save
     * state while a fresh idle timer gets armed behind it.
     */
    private fun save(syncImmediately: Boolean = false) {
        val store = resolveStore() ?: return
        val content = currentContent()
        statusBar.text = "保存中…"
        io.execute {
            try {
                store.writeText(path, content)
                if (syncImmediately) SyncRegistry.flushNow(this@WysiwygActivity, store, path)
                else SyncRegistry.requestAutoSync(this@WysiwygActivity, store, path)
                runOnUiThread {
                    dirty = false
                    statusBar.text = "已保存"
                }
            } catch (e: Exception) {
                runOnUiThread { statusBar.text = "保存失败：${e.message}" }
            }
        }
    }

    private fun resolveStore(): DocumentStore? {
        val tree = getSharedPreferences("markit", MODE_PRIVATE).getString("tree_uri", null)
            ?: return null
        return DocumentStore(this, android.net.Uri.parse(tree))
    }

    override fun onBackPressed() {
        // Back always writes. Asking first was a prompt for something the user
        // can only answer one way: the text on screen is the text they meant,
        // and the autosave timer is not something they should have to reason
        // about to avoid losing work. "不保存退出" existed as an escape hatch
        // for an accident the save prevents in the first place.
        if (dirty) save(syncImmediately = true)
        super.onBackPressed()
    }

    /**
     * The page's side of the conversation.
     *
     * Every method here is called from the WebView's JS thread, never the main
     * one, so anything touching views is posted across. The markdown arrives on
     * each keystroke; it is kept as a field and written only when the user
     * saves or when auto-sync asks for it.
     */
    inner class Bridge {

        @JavascriptInterface
        fun onEditorReady() {
            runOnUiThread {
                editorReady = true
                statusBar.text = "所见即所得编辑"
                web.evaluateJavascript("window.__markitInitial && window.__markitInitial();", null)
                applyPreviewStyle()
            }
        }

        @JavascriptInterface
        fun onContentChanged(newMarkdown: String, newHtml: String) {
            markdown = newMarkdown
            dirty = true
        }

        @JavascriptInterface
        fun onJekyllTitle(value: String) {
            frontMatterTitle = value
            dirty = true
        }

        @JavascriptInterface
        fun onJekyllDate(value: String) {
            frontMatterDate = value
            dirty = true
        }

        @JavascriptInterface
        fun onJekyllTags(value: String) {
            frontMatterTags = value
            dirty = true
        }

        @JavascriptInterface
        fun onLog(message: String) {
            Log.d(TAG, "js: $message")
        }

        @JavascriptInterface
        fun onError(message: String) {
            Log.e(TAG, "js error: $message")
            runOnUiThread { statusBar.text = "编辑器报错：$message" }
        }
    }

    /**
     * Hands the chosen stylesheet to the page.
     *
     * The page's own updateStyle replaces the contents of a single style
     * element, which is how the Mac client applies it too. Applied after the
     * initial content so the first paint is already in the chosen style.
     */
    private fun applyPreviewStyle() {
        val css = PreviewStyles.cssOrDefault(this)
        if (css.isEmpty()) return
        val js = "window.updateStyle && window.updateStyle(${PreviewStyles.jsonString(css)});"
        web.evaluateJavascript(js, null)
    }

    override fun onPause() {
        super.onPause()
        // Same reason as the source editor: leaving the note flushes instead of
        // waiting out the idle timer, and syncNow cancels the pending one.
        if (dirty) save(syncImmediately = true)
        else resolveStore()?.let { SyncRegistry.flushNow(this, it, path) }
    }

    /**
     * Whether the app is currently in night mode.
     *
     * Resolved rather than asked of the page, because Android's WebView does not
     * reliably report prefers-color-scheme. Handing the value over as an
     * attribute keeps the editor and the surrounding UI from disagreeing.
     */
    private fun isNightMode(): Boolean {
        val mode = resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK
        return mode == android.content.res.Configuration.UI_MODE_NIGHT_YES
    }

    override fun onDestroy() {
        // Leaving the socket open would keep a port bound for the life of the
        // process and hold the staged page in memory.
        localServer?.stop()
        localServer = null
        web.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MarkItWysiwyg"
        private const val EXTRA_PATH = "path"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_CONTENT = "content"

        fun intent(context: Context, path: String, name: String, content: String): Intent =
            Intent(context, WysiwygActivity::class.java)
                .putExtra(EXTRA_PATH, path)
                .putExtra(EXTRA_NAME, name)
                .putExtra(EXTRA_CONTENT, content)
    }
}
