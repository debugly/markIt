package com.debugly.markit.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The release list parser, against a real payload shape.
 *
 * The live repository has no releases yet, so this is the only way to check
 * the branches that matter: picking the newest, ignoring prereleases, and
 * finding the APK among the assets.
 */
class ParseReleasesTest {

    private fun parse(json: String, current: String): UpdateCheckResult =
        UpdateChecker().parse(json, current)

    private val fixture: String by lazy {
        // Copied next to the test so the classpath is not part of the setup.
        val f = File("src/test/resources/releases.json")
        check(f.exists()) { "fixture missing at ${f.absolutePath}" }
        f.readText()
    }

    @Test
    fun `picks the newest release above the running version`() {
        val result = parse(fixture, "0.4.0")
        assertTrue(result is UpdateCheckResult.Available)
        val update = (result as UpdateCheckResult.Available).update
        assertEquals("0.5.0", update.version)
        // The .zip is listed first; the APK has to be found past it.
        assertTrue(update.apkUrl.endsWith("MarkIt-0.5.0.apk"))
    }

    @Test
    fun `prereleases are ignored even when newer`() {
        // 0.9.0-beta.1 sorts above 0.5.0 but is not what "check for updates" means.
        val result = parse(fixture, "0.5.0")
        assertTrue(result is UpdateCheckResult.UpToDate)
    }

    @Test
    fun `equal version reports up to date`() {
        assertTrue(parse(fixture, "0.5.0") is UpdateCheckResult.UpToDate)
    }

    @Test
    fun `a version ahead of every release reports up to date`() {
        assertTrue(parse(fixture, "1.0.0") is UpdateCheckResult.UpToDate)
    }

    @Test
    fun `an empty list does not crash`() {
        assertTrue(parse("[]", "0.4.0") is UpdateCheckResult.UpToDate)
    }

    @Test
    fun `a release with no apk still offers the release page`() {
        val json = """[{"tag_name":"9.9.9","prerelease":false,"draft":false,
            "body":"x","html_url":"https://example.com/r","assets":[]}]"""
        val result = parse(json, "0.4.0") as UpdateCheckResult.Available
        assertEquals("", result.update.apkUrl)
        assertEquals("https://example.com/r", result.update.releaseUrl)
    }
}
