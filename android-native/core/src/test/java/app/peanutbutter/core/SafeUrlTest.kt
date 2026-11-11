package app.peanutbutter.core

import org.junit.Assert.assertEquals
import org.junit.Test

class SafeUrlTest {
    @Test
    fun dropsTheDeviceKeyAndOtherQueryTokens() {
        assertEquals(
            "http://192.168.1.5:3001/files/abc",
            AppLog.safeUrl("http://192.168.1.5:3001/files/abc?key=pbk_0123456789abcdef"),
        )
        assertEquals("https://cdn.example/v.mp4", AppLog.safeUrl("https://cdn.example/v.mp4#t=10"))
        assertEquals("http://127.0.0.1:5555/stream", AppLog.safeUrl("http://127.0.0.1:5555/stream"))
        assertEquals("", AppLog.safeUrl(null))
    }
}
