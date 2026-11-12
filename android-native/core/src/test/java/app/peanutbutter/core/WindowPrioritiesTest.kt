package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test
import org.libtorrent4j.Priority

class WindowPrioritiesTest {
    // A season pack: this episode is pieces 10..109 of 200.
    private fun prios(from: Int, head: Int = 0, tail: Int = 0) =
        windowPriorities(total = 200, first = 10, last = 109, from = from, window = 16, headPieces = head, tailPieces = tail)

    @Test
    fun nextPiecesAreTopAndPriorityFallsWithDistance() {
        val p = prios(from = 10)
        assertEquals(Priority.TOP_PRIORITY, p[10])
        assertEquals(Priority.TOP_PRIORITY, p[11])
        assertEquals(Priority.SIX, p[12])
        assertEquals(Priority.FIVE, p[14])
        assertEquals(Priority.DEFAULT, p[10 + 12])
        assertEquals(Priority.LOW, p[10 + 16])
    }

    @Test
    fun otherEpisodesAndPiecesBehindTheReaderAreNotDownloaded() {
        val p = prios(from = 50)
        assertEquals(Priority.IGNORE, p[0])
        assertEquals(Priority.IGNORE, p[150])
        assertEquals(Priority.IGNORE, p[49])
        assertEquals(Priority.TOP_PRIORITY, p[50])
    }

    @Test
    fun startKeepsTheHeadTopAndTheIndexJustBelow() {
        val p = prios(from = 60, head = 1, tail = 1)
        assertEquals(Priority.TOP_PRIORITY, p[10])
        assertEquals(Priority.SIX, p[109])
        // The tail never outranks the pieces the player needs next.
        assertEquals(Priority.TOP_PRIORITY, p[60])
    }

    @Test
    fun whileStartingNothingPastTheWindowIsWanted() {
        val p = windowPriorities(total = 200, first = 10, last = 109, from = 10, window = 16, fillBeyond = false)
        assertEquals(Priority.DEFAULT, p[10 + 12])
        assertEquals(Priority.IGNORE, p[10 + 16])
        assertEquals(Priority.IGNORE, p[60])
    }

    @Test
    fun startUpWantsOnlyWhatOpensTheFile() {
        // One play piece, one head piece, one index piece at the end.
        val p = windowPriorities(total = 200, first = 10, last = 109, from = 10, window = 1, headPieces = 1, tailPieces = 1, fillBeyond = false)
        assertEquals(Priority.TOP_PRIORITY, p[10])
        assertEquals(Priority.IGNORE, p[11])
        assertEquals(Priority.SIX, p[109])
        assertEquals(1, p.count { it == Priority.TOP_PRIORITY })
    }
}
