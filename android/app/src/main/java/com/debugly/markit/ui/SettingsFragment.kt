package com.debugly.markit.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.fragment.app.Fragment
import com.debugly.markit.BuildConfig
import com.debugly.markit.R
import java.util.concurrent.Executors
import com.debugly.markit.storage.DocumentStore
import com.debugly.markit.update.UpdateCheckResult
import com.debugly.markit.update.UpdateChecker

/**
 * Settings: appearance, the preview stylesheet, and the few vault-level things
 * worth exposing.
 *
 * Kept deliberately short. The Mac client has two tabs and one of them is a
 * WebView inspector, which has no meaning here; porting its shell rather than
 * its content would have given the user a settings page with nothing in it.
 */
class SettingsFragment : Fragment() {

    private var host: Host? = null

    interface Host {
        fun onCloseSettings()
        fun onRecentsCleared()
        /** Shows the system folder picker. The Activity confirms and attaches. */
        fun onRequestVaultPick()
    }

    override fun onAttach(context: android.content.Context) {
        super.onAttach(context)
        host = context as? Host
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?
    ): View {
        val v = inflater.inflate(R.layout.fragment_settings, container, false)

        // Top inset only: there is no toolbar of our own, and the Activity's
        // chrome already handles the tab bar at the bottom.
        Insets.apply(v, top = true, horizontal = true)

        setUpThemeSpinner(v.findViewById(R.id.themeRow))
        setUpStyleSpinner(v.findViewById(R.id.styleRow))

        v.findViewById<View>(R.id.clearRecent).setOnClickListener {
            RecentFiles(requireContext()).clear()
            host?.onRecentsCleared()
        }

        // The Activity owns the picker: it is the only place that holds the SAF
        // grant and decides what a switch does to stored state, so a second
        // picker here would quietly bypass both.
        v.findViewById<View>(R.id.changeVault).setOnClickListener { host?.onRequestVaultPick() }
        val vaultPath = v.findViewById<TextView>(R.id.vaultPath)

        v.findViewById<TextView>(R.id.versionText).text =
            "版本 ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

        v.findViewById<View>(R.id.checkUpdate).setOnClickListener { checkForUpdate() }

        val uri = requireContext()
            .getSharedPreferences("markit", android.content.Context.MODE_PRIVATE)
            .getString("tree_uri", null)
        vaultPath.text = if (uri == null) "尚未选择文件夹" else
            DocumentStore(requireContext(), Uri.parse(uri)).describeRoot()

        return v
    }

    /**
     * Theme picker: follow the system, light, or dark.
     *
     * The initial setSelection fires onItemSelected, so a plain listener would
     * re-apply the stored value on the way in. For the theme that is not
     * harmless: setDefaultNightMode recreates the Activity, and doing it while
     * the picker is still binding is a loop.
     */
    private fun setUpThemeSpinner(row: View) {
        row.findViewById<TextView>(R.id.spinnerLabel).text = "主题"
        val spinner = row.findViewById<Spinner>(R.id.spinner)
        val modes = ThemeSetting.options.map { it.first }
        spinner.adapter = ArrayAdapter(
            requireContext(), android.R.layout.simple_spinner_dropdown_item,
            ThemeSetting.options.map { it.second }
        )

        var binding = true
        spinner.setSelection(modes.indexOf(ThemeSetting.get(requireContext())).coerceAtLeast(0))
        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (binding) return
                ThemeSetting.set(requireContext(), modes[position])
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        binding = false
    }

    private fun setUpStyleSpinner(row: View) {
        row.findViewById<TextView>(R.id.spinnerLabel).text = "预览渲染样式"
        val spinner = row.findViewById<Spinner>(R.id.spinner)
        val styles = PreviewStyles.available
        spinner.adapter = ArrayAdapter(
            requireContext(), android.R.layout.simple_spinner_dropdown_item,
            styles.map { it.label }
        )

        var binding = true
        spinner.setSelection(
            styles.indexOfFirst { it.file == PreviewStyles.selected(requireContext()) }
                .coerceAtLeast(0)
        )
        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (binding) return
                styles.getOrNull(position)?.let { PreviewStyles.select(requireContext(), it.file) }
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        binding = false
    }

    /**
     * Asks GitHub for the newest release and reports what it found.
     *
     * The dialog is what the user is waiting on, so the network call runs off
     * the main thread and every outcome -- up to date, an update, or a failure
     * -- comes back as a dialog. A silent failure here looks identical to an
     * app that does not work.
     */
    private fun checkForUpdate() {
        val progress = AlertDialog.Builder(requireContext())
            .setMessage("正在检查…")
            .setCancelable(false)
            .create()
        progress.show()

        val executor = Executors.newSingleThreadExecutor()
        executor.execute {
            val result = try {
                UpdateChecker().check()
            } catch (e: Exception) {
                UpdateCheckResult.Failed(e.message ?: e.javaClass.simpleName)
            }
            // The result is produced on the IO thread; the dialog has to be
            // built on the main one.
            activity?.runOnUiThread {
                if (!isAdded) return@runOnUiThread
                progress.dismiss()
                showUpdateResult(result)
            }
        }
    }

    private fun showUpdateResult(result: UpdateCheckResult) {
        val builder = AlertDialog.Builder(requireContext())

        when (result) {
            is UpdateCheckResult.UpToDate ->
                builder.setTitle("已是最新版本")
                    .setMessage("当前版本 ${result.current} 已是最新。")

            is UpdateCheckResult.Available -> {
                val update = result.update
                builder.setTitle("发现新版本 ${update.version}")
                    .setMessage(
                        buildString {
                            append("当前版本 ${BuildConfig.VERSION_NAME}。\n\n")
                            if (update.notes.isNotBlank()) {
                                append(update.notes.trim())
                                append("\n\n")
                            }
                            append("是否打开浏览器下载安装包？")
                        }
                    )
                    .setPositiveButton("下载") { _, _ -> openInBrowser(update.apkUrl) }
                    .setNeutralButton("稍后", null)
                    // A release whose APK failed to upload should still be
                    // reachable, so the release page is the fallback.
                    .setNegativeButton("查看发布页") { _, _ -> openInBrowser(update.releaseUrl) }
            }

            is UpdateCheckResult.Failed ->
                builder.setTitle("检查失败")
                    .setMessage("无法获取最新版本信息：${result.reason}")
        }

        // Only the non-update outcomes need a dismiss button. Setting it on an
        // update dialog would overwrite the 下载 action set above it.
        if (result !is UpdateCheckResult.Available) {
            builder.setPositiveButton("好", null)
        }
        builder.show()
    }

    /**
     * Hands the URL to the system browser rather than downloading in-app.
     *
     * Installing an APK needs the user to approve an unknown source, which is
     * a system dialog this app cannot show on its own behalf. Sending them to
     * the browser keeps the install where Android expects it, and avoids
     * reimplementing a download manager for one file.
     */
    private fun openInBrowser(url: String) {
        if (url.isBlank()) return
        runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        }.onFailure {
            Toast.makeText(requireContext(), "无法打开浏览器", Toast.LENGTH_SHORT).show()
        }
    }

    companion object {
        fun newInstance() = SettingsFragment()
    }
}