import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
    id("com.google.devtools.ksp")
    id("dev.flutter.flutter-gradle-plugin")   // must come last
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.tbtrapp"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tbtrapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 22
        versionName = "3.1.1"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // Both were previously unset (i.e. off) — enabling shrinkResources
            // without minifyEnabled is a no-op (resource shrinking only removes
            // resources R8 has proven unreachable from code, so it requires code
            // shrinking to be on first). See proguard-rules.pro for the extra
            // keep rules this needed (Play Core, WebRTC JNI, Firebase POJO
            // reflection) beyond Flutter's own bundled default rules.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    implementation("androidx.media:media:1.7.0")

    // Firebase — BOM 34.x+ no longer publishes -ktx artifacts (KTX APIs were
    // merged into the main modules in July 2025). Use the plain modules.
    implementation(platform("com.google.firebase:firebase-bom:34.4.0"))
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-database")
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-storage")

    // Room
    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    ksp("androidx.room:room-compiler:2.8.4")   // ksp, not kapt

    // Lifecycle — pinned to 2.9.4 to match what the rest of the tree
    // (activity-compose, material3, OneSignal, image-cropper, etc.) already
    // resolves to. 2.9.5 does not exist on Google's Maven or Maven Central.
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.4")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")

    // Play Core
    implementation("com.google.android.play:app-update:2.1.0")
    implementation("com.google.android.play:app-update-ktx:2.1.0")

    // Compose — bumped BOM (2026.06.01 is the latest release still safe on
    // compileSdk 36; 2026.08.00 requires compileSdk 37 + AGP 9.1.1, so hold
    // off on that specific BOM version until you bump compileSdk too)
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.runtime:runtime")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // Activity
    implementation("androidx.activity:activity-compose:1.11.0")

    implementation("com.googlecode.libphonenumber:libphonenumber:8.13.40")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.9.4")

    // Audio/video playback — bumped from 1.6.1 to 1.11.0 (stable as of July
    // 2026). This is one of the two most likely sources of the deprecated
    // LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES warning — Media3's
    // full-screen video UI handles window/cutout insets internally, and
    // 1.6.1 predates the Android 15 edge-to-edge changes.
    implementation("androidx.media3:media3-exoplayer:1.11.0")
    implementation("androidx.media3:media3-ui:1.11.0")

    // Core
    implementation("androidx.core:core-ktx:1.17.0")

    implementation("androidx.appcompat:appcompat:1.7.1")

    // Image cropper — bumped from 4.5.0 to 4.7.0. This is the OTHER most
    // likely source of the deprecated cutout-mode warning: CropImageActivity
    // extends AppCompatActivity and does its own full-screen window setup;
    // 4.7.0 (Nov 2025) is well past the point where CanHub/vanniktech patched
    // their window-insets handling for newer Android versions.
    implementation("com.vanniktech:android-image-cropper:4.7.0")

    // Coil
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("io.coil-kt:coil-video:2.7.0")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.11.0")

    // Cloudinary
    implementation("com.cloudinary:cloudinary-android:3.1.2")

    // OneSignal — push notifications
    implementation("com.onesignal:OneSignal:5.9.4")


    implementation("io.github.webrtc-sdk:android:144.7559.09")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    implementation("me.leolin:ShortcutBadger:1.1.22@aar")
}

flutter {
    source = "../.."
}