import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Optional real release key. Without android-native/keystore.properties the
// release build keeps using the debug key (same as before), so existing
// installs keep updating. See README "Release signing" before switching:
// a different key means one uninstall/reinstall on each TV.
val releaseKeystore = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
if (releaseKeystore.isEmpty()) {
    logger.warn(
        "PeanutButter TV: release APK is signed with the DEBUG key " +
            "(no android-native/keystore.properties). Anyone with that key can " +
            "publish updates for this app id; see README \"Release signing\".",
    )
}

// Opt-in R8 shrinking: ./gradlew :tv:assembleRelease -Ppb.minify=true
// Off by default until a minified build has been smoke-tested on a TV.
val minifyRelease = (project.findProperty("pb.minify") as String?)?.toBoolean() ?: false

android {
    namespace = "app.peanutbutter.tv"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.peanutbutter.tv"
        minSdk = 24
        targetSdk = 36
        // CI: -Ppb.versionCode=<run number> -Ppb.versionName=<tag version>.
        // Android only installs an update with a higher versionCode.
        versionCode = (project.findProperty("pb.versionCode") as String?)?.toIntOrNull() ?: 1
        versionName = (project.findProperty("pb.versionName") as String?) ?: "0.2.0"
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    // One flavor, "app" (PeanutButter TV). Kept as a flavor so task names
    // (:tv:assembleAppRelease) and APK paths stay as CI expects them.
    flavorDimensions += "mode"
    productFlavors {
        create("app") {
            dimension = "mode"
            // Update platform key (backend/src/updates.rs, scripts/release_manifest.py).
            buildConfigField("String", "UPDATE_PLATFORM", "\"android-tv\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        if (!releaseKeystore.isEmpty()) {
            create("release") {
                storeFile = rootProject.file(
                    requireNotNull(releaseKeystore.getProperty("storeFile")) {
                        "storeFile is missing from keystore.properties"
                    },
                )
                storePassword = releaseKeystore.getProperty("storePassword")
                keyAlias = releaseKeystore.getProperty("keyAlias")
                keyPassword = releaseKeystore.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = minifyRelease
            isShrinkResources = minifyRelease
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (releaseKeystore.isEmpty()) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
        }
    }

    // One APK per CPU type (each ~1/4 of the universal size) plus the
    // universal APK. TV boxes report their type via `ro.product.cpu.abi`
    // (many 64-bit boxes run a 32-bit armeabi-v7a userspace).
    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
            isUniversalApk = true
        }
    }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.leanback:leanback:1.0.0")
    // TV UI in Compose, matching the Flutter apps screen for screen.
    implementation(platform("androidx.compose:compose-bom:2025.01.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.tv:tv-material:1.0.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.github.bumptech.glide:glide:4.16.0")
    implementation("org.videolan.android:libvlc-all:3.6.3")
    implementation("androidx.media3:media3-exoplayer:1.8.0")
    implementation("androidx.media3:media3-ui:1.8.0")
    // Prebuilt FFmpeg decoders used by Jellyfin's Android TV player.
    implementation("org.jellyfin.media3:media3-ffmpeg-decoder:1.8.0+1")
    // Ed25519 verification of signed update manifests (no platform API before 33).
    implementation("org.bouncycastle:bcprov-jdk18on:1.80")
    testImplementation("junit:junit:4.13.2")
}
