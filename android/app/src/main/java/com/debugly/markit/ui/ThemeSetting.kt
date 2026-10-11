package com.debugly.markit.ui

import android.content.Context
import androidx.appcompat.app.AppCompatDelegate
/**
 * Whether the app follows the system theme, or is pinned to light or dark.
 *
 * Manual selection has to be applied through AppCompatDelegate.setDefaultNightMode
 * rather than by touching the configuration: the theme resources are resolved
 * per Activity, and a configuration override only affects the Activity that
 * applied it, so the picker would light up the screen it was pressed on and
 * leave the rest of the app unchanged.
 */
object ThemeSetting {

    private const val PREFS = "markit_settings"
    private const val KEY = "theme_mode"

    const val SYSTEM = "system"
    const val LIGHT = "light"
    const val DARK = "dark"

    /** Display order is system first, since that is what most people want. */
    val options: List<Pair<String, String>> = listOf(
        SYSTEM to "跟随系统",
        LIGHT to "浅色",
        DARK to "深色"
    )

    fun labelFor(mode: String): String =
        options.firstOrNull { it.first == mode }?.second ?: "跟随系统"

    fun get(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, SYSTEM) ?: SYSTEM

    fun set(context: Context, mode: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, mode).apply()
        apply(mode)
    }

    /**
     * Pushes [mode] to every screen, recreating what is already on the back
     * stack.
     *
     * setDefaultNightMode handles that itself: it recreates the active
     * Activities, which is the only way a colour change reaches a fragment
     * that was already inflated.
     */
    fun apply(mode: String) {
        AppCompatDelegate.setDefaultNightMode(
            when (mode) {
                LIGHT -> AppCompatDelegate.MODE_NIGHT_NO
                DARK -> AppCompatDelegate.MODE_NIGHT_YES
                else -> AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM
            }
        )
    }

    /** Call once at startup, before the first Activity is created. */
    fun applyStored(context: Context) = apply(get(context))
}