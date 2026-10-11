package com.debugly.markit.ui

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.debugly.markit.R

/**
 * Edge-to-edge helpers, applied the same way in every screen.
 *
 * Android 15 (targetSdk 35+) forces edge to edge, so opting out is not possible.
 * Every activity therefore opts in deliberately: content draws behind the
 * status and navigation bars, and each screen decides where its own furniture
 * goes by padding the specific views that need it.
 *
 * Two things to keep in mind when using applyInsets:
 *  - it pads with the inset added to whatever padding the view already has,
 *    so repeated inset passes accumulate rather than reset. Call it once.
 *  - it only touches the edges you pass, so a view can be flush to the screen
 *    on purpose (the editor canvas) while its toolbar is inset.
 */
object Insets {

    /** Lets the window draw behind the system bars and makes them transparent. */
    fun goEdgeToEdge(activity: Activity) {
        WindowCompat.setDecorFitsSystemWindows(activity.window, false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            activity.window.isStatusBarContrastEnforced = false
            activity.window.isNavigationBarContrastEnforced = false
        }

        // Light bars need dark icons; the app draws light chrome in both screens
        // except the editor canvas, which is handled per-view below.
        WindowInsetsControllerCompat(activity.window, activity.window.decorView)
            .isAppearanceLightStatusBars = true
    }

    /**
     * Pads [view] by the system bar insets on the given edges.
     *
     * @param top pad for the status bar
     * @param bottom pad for the navigation bar / gesture handle
     * @param horizontal pad for cutouts in landscape
     */
    fun apply(
        view: View,
        top: Boolean = false,
        bottom: Boolean = false,
        horizontal: Boolean = false
    ) {
        // Capture the layout's own padding once. Calling apply() again on the
        // same view (the editor toggles preview on and off) must not stack the
        // inset on top of the previous result, so the baseline is remembered.
        if (view.getTag(R.id.insets_baseline) == null) {
            view.setTag(R.id.insets_baseline, intArrayOf(
                view.paddingLeft, view.paddingTop, view.paddingRight, view.paddingBottom
            ))
        }
        val base = view.getTag(R.id.insets_baseline) as IntArray
        val initialLeft = base[0]
        val initialTop = base[1]
        val initialRight = base[2]
        val initialBottom = base[3]

        ViewCompat.setOnApplyWindowInsetsListener(view) { v, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
            )
            v.setPadding(
                initialLeft + if (horizontal) bars.left else 0,
                initialTop + if (top) bars.top else 0,
                initialRight + if (horizontal) bars.right else 0,
                initialBottom + if (bottom) bars.bottom else 0
            )
            insets
        }
        ViewCompat.requestApplyInsets(view)
    }

    /**
     * Backgrounds that must stay legible under a transparent system bar. Call on
     * views whose own background is dark, so the status icons flip to light.
     */
    fun useLightIconsOn(window: Activity, view: View, light: Boolean) {
        ViewCompat.setOnApplyWindowInsetsListener(view) { _, insets ->
            val controller = WindowInsetsControllerCompat(window.window, view)
            controller.isAppearanceLightStatusBars = light
            insets
        }
    }
}
