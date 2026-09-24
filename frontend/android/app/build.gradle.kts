plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.peanutbutter.peanutbutter"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.peanutbutter.peanutbutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // flutter_vlc_player + media_kit both ship native libs — keep first.
    packaging {
        jniLibs {
            pickFirsts += listOf(
                "lib/**/libc++_shared.so",
                "lib/**/libvlc.so",
                "lib/**/libvlcjni.so",
                "lib/**/libmla.so",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Same LibVLC as flutter_vlc_player — used by NativeVlcPlayer (SurfaceView
    // behind Flutter). PlatformViews from the Dart plugin do not attach on
    // Realtek rtd285o boxes.
    implementation("org.videolan.android:libvlc-all:3.6.3")
}

