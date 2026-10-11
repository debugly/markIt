package com.debugly.markit.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.debugly.markit.R
import com.debugly.markit.model.SupportedFileType
import com.debugly.markit.storage.DocumentStore

/**
 * Viewer for the file types that are not worth putting in the Markdown editor.
 *
 * Images and standalone HTML used to open as source text, which meant tapping a
 * photo in the vault gave you a screen of binary noise, and tapping an .html
 * file rendered it as markup rather than as a page. This mirrors the macOS
 * app's ImagePreviewViewController and HTMLPreviewViewController: both are
 * read-only, both keep the same toolbar and back behaviour as the editor, and
 * neither offers a source/preview toggle because there is nothing to toggle.
 */
class FileViewerActivity : AppCompatActivity() {

    private lateinit var titleText: TextView
    private lateinit var contentView: FrameLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_file_viewer)

        val path = intent.getStringExtra(EXTRA_PATH).orEmpty()
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        val type = SupportedFileType.detect(name)

        titleText = findViewById(R.id.viewerTitle)
        contentView = findViewById(R.id.viewerContent)
        titleText.text = name

        // Same edge-to-edge handling as the editor toolbar.
        Insets.apply(findViewById(R.id.viewerTopBar), top = true, horizontal = true)
        Insets.apply(contentView, bottom = true, horizontal = true)
        findViewById<android.widget.ImageButton>(R.id.viewerBack)
            .setOnClickListener { finish() }

        val store = DocumentStore(this, Uri.parse(intent.getStringExtra(EXTRA_TREE).orEmpty()))
        render(store, path, name, type)
    }

    private fun render(
        store: DocumentStore,
        path: String,
        name: String,
        type: SupportedFileType
    ) {
        try {
            when (type) {
                SupportedFileType.IMAGE -> showImage(store.readBytes(path), name)
                SupportedFileType.HTML -> showHtml(store.readText(path), name)
                else -> showMessage("暂不支持预览此类型的文件")
            }
        } catch (e: Exception) {
            showMessage("无法打开：${e.message ?: "未知错误"}")
        }
    }

    private fun showImage(bytes: ByteArray, name: String) {
        val view = ImageView(this)
        view.setImageBitmap(android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
        // Fit inside the viewport rather than cropping: a preview that hides
        // part of the image is not a preview.
        view.adjustViewBounds = true
        view.scaleType = ImageView.ScaleType.FIT_CENTER
        contentView.removeAllViews()
        contentView.addView(view, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
        status("图片 · ${bytes.size / 1024} KB")
    }

    private fun showHtml(html: String, name: String) {
        val web = WebView(this)
        web.settings.apply {
            javaScriptEnabled = true
            // Allow the page to reference its own assets; block file:// reads of
            // the rest of the vault, which a link on an untrusted page could use
            // to probe for local files.
            allowFileAccess = false
            allowContentAccess = false
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        web.setBackgroundColor(0xFFFFFFFF.toInt())
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView?, req: WebResourceRequest?): Boolean {
                val target = req?.url ?: return true
                // Internal anchors stay in the viewer; anything that wants a new
                // document goes to the system browser.
                return if (target.scheme in setOf("file", "data", "about")) false else {
                    runCatching {
                        startActivity(Intent(Intent.ACTION_VIEW, target))
                    }
                    true
                }
            }

            override fun shouldInterceptRequest(
                v: WebView?, req: WebResourceRequest?
            ): WebResourceResponse? = null
        }
        contentView.removeAllViews()
        contentView.addView(web, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
        web.loadDataWithBaseURL(
            "file:///$name", html, "text/html", "UTF-8", null
        )
        status("HTML · ${html.length} 字符")
    }

    private fun showMessage(text: String) {
        val label = TextView(this).apply {
            this.text = text
            gravity = Gravity.CENTER
            textSize = 14f
            setTextColor(0xFF8A8A8E.toInt())
        }
        contentView.removeAllViews()
        contentView.addView(label, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
    }

    /** Mirrors the editor's status line so both screens read the same. */
    private fun status(text: String) {
        findViewById<TextView>(R.id.viewerStatus).text = text
    }

    companion object {
        private const val EXTRA_PATH = "path"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_TREE = "tree"

        fun intent(context: Context, tree: String, path: String, name: String): Intent =
            Intent(context, FileViewerActivity::class.java).apply {
                putExtra(EXTRA_TREE, tree)
                putExtra(EXTRA_PATH, path)
                putExtra(EXTRA_NAME, name)
            }
    }
}
