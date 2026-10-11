package com.debugly.markit.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Version ordering, which is easy to get wrong in a way no compiler catches.
 *
 * Sorting versions as strings says 0.10.0 comes before 0.9.0, so a user on 0.9
 * would be told they had an update available on every single check, forever.
 */
class VersionOrderTest {

    private fun parts(s: String) = UpdateChecker.parts(s)

    private fun newer(candidate: String, current: String) =
        UpdateChecker.compare(parts(candidate), parts(current))

    @Test
    fun `ten sorts after nine`() {
        assertFalse(newer("0.9.0", "0.10.0"))
        assertTrue(newer("0.10.0", "0.9.0"))
    }

    @Test
    fun `same version is not an update`() {
        assertFalse(newer("0.4.0", "0.4.0"))
        assertFalse(newer("1.2.3", "1.2.3"))
    }

    @Test
    fun `patch level decides`() {
        assertTrue(newer("0.4.1", "0.4.0"))
        assertFalse(newer("0.4.0", "0.4.1"))
    }

    @Test
    fun `major beats minor numerically`() {
        assertTrue(newer("1.0.0", "0.9.9"))
        assertFalse(newer("2.0.0", "10.0.0"))
    }

    @Test
    fun `a shorter version is older than its own extension`() {
        // 0.4 came before 0.4.1; treating a missing component as zero would say
        // otherwise.
        assertTrue(newer("0.4.1", "0.4"))
        assertFalse(newer("0.4", "0.4.1"))
    }

    @Test
    fun `unparseable versions are not treated as newer`() {
        // Sideloaded or development builds must not be told they are behind.
        assertFalse(newer("0.5.0", "dev"))
        assertEquals(0, parts("dev").size)
    }
}
