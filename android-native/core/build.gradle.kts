plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.peanutbutter.core"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    api("com.squareup.okhttp3:okhttp:4.12.0")
    api("com.google.code.gson:gson:2.11.0")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    // On-device torrent streaming (Flutter LocalTorrentEngine parity).
    api("org.libtorrent4j:libtorrent4j:2.1.0-39")
    api("org.libtorrent4j:libtorrent4j-android-arm64:2.1.0-39")
    api("org.libtorrent4j:libtorrent4j-android-arm:2.1.0-39")
    api("org.libtorrent4j:libtorrent4j-android-x86_64:2.1.0-39")
    // 32-bit x86 emulators (ro.product.cpu.abi=x86) need this — without it
    // playback fails with "On-device torrent streaming isn’t available".
    api("org.libtorrent4j:libtorrent4j-android-x86:2.1.0-39")
}
