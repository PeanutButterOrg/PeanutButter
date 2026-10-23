package app.peanutbutter.tv.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/** Same fixture as backend/src/updates.rs and frontend/test/app_updater_test.dart. */
class AppUpdaterTest {
    private val key = Base64.getDecoder().decode(AppUpdater.PUBLIC_KEY)
    private val manifest = "{\"schema\":1,\"version\":\"0.0.1\",\"build\":1,\"tag\":\"v0.0.1\",\"assets\":{}}\n"
    private val sig = Base64.getDecoder().decode(
        "Lz4t5lcX/1zacups8J6ny8y15a8z0HAYCjHMt+hzWQqvFE+qzNELo5yte55nORmoqConwMNxZE/9NLGEdnxVAQ==",
    )

    @Test
    fun acceptsReleaseSignedWithUpdateKey() {
        assertTrue(AppUpdater.verifyRaw(key, manifest.toByteArray(), sig))
    }

    @Test
    fun rejectsTamperedManifestAndJunkSignature() {
        val tampered = manifest.replaceFirst("0.0.1", "9.9.9").toByteArray()
        assertFalse(AppUpdater.verifyRaw(key, tampered, sig))
        assertFalse(AppUpdater.verifyRaw(key, manifest.toByteArray(), ByteArray(3)))
    }
}
