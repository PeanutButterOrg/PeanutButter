package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadBudgetTest {
    private val gb = 1024L * 1024 * 1024

    @Test
    fun budgetIsCappedByDiskSizeAndFreeSpace() {
        assertEquals(10 * gb, DownloadBudget.budget(100 * gb, 50 * gb, 5 * gb))
        assertEquals(4 * gb, DownloadBudget.budget(10 * gb, 5 * gb, 1 * gb))
        // Only 500 MB free: give back enough of what downloads use to reach 2 GB free.
        assertEquals(gb * 3 / 2 + gb, DownloadBudget.budget(100 * gb, gb / 2, 3 * gb + gb / 2 + gb / 2))
    }

    @Test
    fun oldestGoFirstUntilItFits() {
        val entries = listOf(
            DownloadBudget.Entry("new", 4 * gb, 300),
            DownloadBudget.Entry("old", 4 * gb, 100),
            DownloadBudget.Entry("mid", 4 * gb, 200),
        )
        assertEquals(listOf("old"), DownloadBudget.toDelete(entries, 8 * gb).map { it.name })
        assertEquals(listOf("old", "mid"), DownloadBudget.toDelete(entries, 5 * gb).map { it.name })
        assertTrue(DownloadBudget.toDelete(entries, 12 * gb).isEmpty())
    }

    @Test
    fun rangeAtOrPastTheEndIsDetected() {
        assertTrue(rangeStartsPastEnd("bytes=100-", 100))
        assertTrue(rangeStartsPastEnd("bytes=500-600", 100))
        assertFalse(rangeStartsPastEnd("bytes=99-", 100))
        assertFalse(rangeStartsPastEnd("bytes=-10", 100))
        assertFalse(rangeStartsPastEnd(null, 100))
    }
}
