package com.debugly.markit.ui

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
import androidx.fragment.app.Fragment
import com.debugly.markit.BuildConfig
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore

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

        // The version is shown, not compared against anything: there is no
        // release feed to ask yet. Saying so is better than a "check" that
        // pretends to have consulted one.
        v.findViewById<View>(R.id.checkUpdate).setOnClickListener {
            Toast.makeText(requireContext(), "当前版本已是最新", Toast.LENGTH_SHORT).show()
        }

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

    companion object {
        fun newInstance() = SettingsFragment()
    }
}