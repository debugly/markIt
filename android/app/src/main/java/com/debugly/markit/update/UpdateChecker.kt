package com.debugly.markit.update

import android.content.Context
import com.debugly.markit.BuildConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.util.concurrent.TimeUnit

/**
 * The newest published build, if it is newer than the running one.
 *
 * Reads the repo's releases rather than tags: a tag exists as soon as someone
 * pushes it, but the release is what actually carries the APK. Publishing
 * both from one workflow keeps them in step, and the release endpoint needs no
 * authentication for a public repo.
 */
data class AvailableUpdate(
    val version: String,
    val notes: String,
    val apkUrl: String,
    val releaseUrl: String
)

sealed class UpdateCheckResult {
    data class UpToDate(val current: String) : UpdateCheckResult()
    data class Available(val update: AvailableUpdate) : UpdateCheckResult()
    data class Failed(val reason: String) : UpdateCheckResult()
}

/**
 * Asks GitHub whether a newer version exists.
 *
 * Blocking; call it off the main thread.
 */
class UpdateChecker(
    private val repo: String = DEFAULT_REPO,
    private val client: OkHttpClient = defaultClient()
) {

    fun check(currentVersion: String = BuildConfig.VERSION_NAME): UpdateCheckResult {
        return try {
            val request = Request.Builder()
                .url("https://api.github.com/repos/$repo/releases?per_page=20")
                .header("Accept", "application/vnd.github+json")
                // Unauthenticated requests get a low rate limit that a user
                // sharing one device would exhaust. Naming the client lets
                // GitHub exempt us if anything is misbehaving, and keeps the
                // request identifiable in their logs.
                .header("User-Agent", "MarkIt-Android/${BuildConfig.VERSION_NAME}")
                .build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return UpdateCheckResult.Failed("GitHub 返回 ${response.code}")
                }
                val body = response.body?.string()
                    ?: return UpdateCheckResult.Failed("响应为空")

                parse(body, currentVersion)
            }
        } catch (e: Exception) {
            // The message goes in the dialog, so keep it to something a user can
            // act on rather than a stack trace.
            UpdateCheckResult.Failed(e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * Picks the newest release that is actually a newer version than the one
     * running, skipping prereleases.
     *
     * Comparing versions as tuples of numbers rather than strings: "0.10.0"
     * sorts before "0.9.0" lexically, so a user on 0.9 would be told they had
     * an update available forever.
     */
    internal fun parse(body: String, current: String): UpdateCheckResult {
        val releases = JSONArray(body)
        var best: AvailableUpdate? = null
        var bestParts: List<Int> = emptyList()

        for (i in 0 until releases.length()) {
            val r = releases.optJSONObject(i) ?: continue
            // Betas are published from the same workflow but are not what a
            // user asking to "check for updates" wants to be pushed onto.
            if (r.optBoolean("prerelease", false)) continue
            if (r.optBoolean("draft", false)) continue

            val tag = r.optString("tag_name").removePrefix("v")
            val tagParts = parts(tag)
            if (tagParts.size < 2) continue
            if (bestParts.isNotEmpty() && !compare(tagParts, bestParts)) continue

            val assets = r.optJSONArray("assets")
            val apk = (0 until (assets?.length() ?: 0))
                .mapNotNull { assets!!.optJSONObject(it) }
                .firstOrNull { it.optString("name").endsWith(".apk", ignoreCase = true) }

            best = AvailableUpdate(
                version = tag,
                notes = r.optString("body").take(NOTES_LIMIT),
                apkUrl = apk?.optString("browser_download_url").orEmpty(),
                releaseUrl = r.optString("html_url")
            )
            bestParts = tagParts
        }

        val candidate = best ?: return UpdateCheckResult.UpToDate(current)

        // A build from a sideload or a fork can have a version that is not
        // comparable at all ("dev", or an empty string). Claiming an update
        // against a version we cannot read would be a guess, so report
        // up-to-date instead and let the user decide.
        val currentParts = parts(current)
        if (currentParts.size < 2) return UpdateCheckResult.UpToDate(current)
        if (!compare(bestParts, currentParts)) return UpdateCheckResult.UpToDate(current)

        return UpdateCheckResult.Available(candidate)
    }

    companion object {
        const val DEFAULT_REPO = "debugly/markIt"

        /** Release bodies can be long; the dialog only shows the top. */
        private const val NOTES_LIMIT = 1200

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            // A release check sits behind a tap. Timeouts are short so a dead
            // network reports something instead of leaving the dialog spinning.
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()

        /** Splits "0.4.0" into [0, 4, 0]. Unparseable pieces are dropped, so a
         *  version like "dev" yields an empty list rather than a wrong order. */
        fun parts(version: String): List<Int> =
            version.split('.').mapNotNull { it.toIntOrNull() }

        /**
         * True when [a] sorts strictly after [b].
         *
         * A shorter tuple is older than a longer one that starts with it, so
         * 0.4 predates 0.4.1 rather than comparing equal on the shared prefix.
         */
        fun compare(a: List<Int>, b: List<Int>): Boolean {
            // Nothing sensible can be newer than a version we could not read.
            // Without this, an empty "b" makes every candidate look newer --
            // the loop would hit a missing component in b and conclude a wins.
            if (a.size < 2 || b.size < 2) return false

            for (i in 0 until maxOf(a.size, b.size)) {
                // A missing component in a means a ran out first and b
                // extended it: 0.4.1 is newer than 0.4.
                val x = a.getOrNull(i) ?: return false
                val y = b.getOrNull(i) ?: return true
                if (x != y) return x > y
            }
            return false
        }
    }

}