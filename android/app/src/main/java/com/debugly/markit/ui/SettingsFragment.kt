package com.debugly.markit.ui

import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import com.debugly.markit.R
import com.debugly.markit.storage.DocumentStore

/**
 * Settings: the preview stylesheet, and the few vault-level things worth
 * exposing.
 *
 * Kept deliberately short. The Mac client has two tabs and one of them is a
 * WebView inspector, which has no meaning here; porting its shell rather than
 * its content would have given the user a settings page with nothing in it.
 */
class SettingsFragment : Fragment() {

    private var host: Host? = null
    private lateinit var styleGroup: RadioGroup
    private lateinit var vaultPath: TextView

    interface Host {
        fun onCloseSettings()
        fun onRecentsCleared()
        fun onVaultPicked(uri: Uri)
    }

    private val pickTree =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                runCatching {
                    requireContext().contentResolver.takePersistableUriPermission(
                        uri,
                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                }
                // The Activity owns the SAF grant, so it does the attaching.
                host?.onVaultPicked(uri)
            }
        }

    override fun onAttach(context: android.content.Context) {
        super.onAttach(context)
        host = context as? Host
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?
    ): View {
        val v = inflater.inflate(R.layout.fragment_settings, container, false)

        v.findViewById<View>(R.id.settingsBack).setOnClickListener { host?.onCloseSettings() }

        Insets.apply(v.findViewById(R.id.settingsBar), top = true, horizontal = true)
        Insets.apply(v.findViewById(R.id.settingsScroll), bottom = true, horizontal = true)

        styleGroup = v.findViewById(R.id.styleGroup)
        buildStyleOptions()
        styleGroup.setOnCheckedChangeListener { group, checkedId ->
            val index = group.indexOfChild(group.findViewById(checkedId))
            PreviewStyles.available.getOrNull(index)?.let { PreviewStyles.select(requireContext(), it.file) }
        }

        v.findViewById<View>(R.id.clearRecent).setOnClickListener {
            RecentFiles(requireContext()).clear()
            host?.onRecentsCleared()
        }

        v.findViewById<View>(R.id.changeVault).setOnClickListener { pickTree.launch(null) }

        vaultPath = v.findViewById(R.id.vaultPath)
        return v
    }

    override fun onResume() {
        super.onResume()
        val uri = requireContext()
            .getSharedPreferences("markit", android.content.Context.MODE_PRIVATE)
            .getString("tree_uri", null)
        vaultPath.text = if (uri == null) "尚未选择文件夹" else
            DocumentStore(requireContext(), Uri.parse(uri)).describeRoot()
    }

    /**
     * One radio button per available stylesheet, with the saved one selected.
     *
     * Built from the same list the reader uses, so the two cannot drift apart.
     */
    private fun buildStyleOptions() {
        val selected = PreviewStyles.selected(requireContext())
        styleGroup.removeAllViews()
        PreviewStyles.available.forEach { style ->
            val button = RadioButton(requireContext()).apply {
                id = View.generateViewId()
                text = style.label
                textSize = 15f
                setTextColor(resources.getColor(R.color.fg_default, null))
                isChecked = style.file == selected
            }
            styleGroup.addView(button)
        }
    }

    companion object {
        fun newInstance() = SettingsFragment()
    }
}