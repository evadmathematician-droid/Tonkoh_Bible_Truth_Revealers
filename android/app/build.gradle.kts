@file:Suppress("DEPRECATION")

import java.util.Properties

plugins {
    id("com.android.application")
    // No kotlin-android here (Built-in Kotlin migration). While
    // android.builtInKotlin=false (Flutter < 3.47), the Flutter Gradle plugin
    // applies KGP to this module itself; the kotlin { } block below still
    // configures it.
    id("com.google.gms.google-services")
    id("org.jetbrains.kotlin.plugin.compose")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing reads android/key.properties (git-ignored):
//   storeFile=<path to the .jks, relative to android/app>
//   storePassword=...
//   keyAlias=...
//   keyPassword=...
// Without it, release builds fall back to the debug key so local builds keep
// working — but Google Play rejects debug-signed bundles.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.tbtrapp"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.tbtrapp"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: android/key.properties not found — release build " +
                        "is signed with the DEBUG key and cannot be uploaded to Play."
                )
                signingConfigs.getByName("debug")
            }

            // R8 shrinking, optimization and obfuscation (Google Play's DEX
            // optimization requirement). A missing keep rule only shows up
            // at runtime, so do an on-device pass of calls, OneSignal push,
            // chat, photo upload and audio playback on every release build.
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

    // Only libraries the native Kotlin code in src/main/kotlin uses. Flutter
    // plugins bring their own native dependencies.
    implementation(platform("com.google.firebase:firebase-bom:34.4.0"))
    implementation("com.google.firebase:firebase-database")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.runtime:runtime")

    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.activity:activity-compose:1.11.0")

    implementation("androidx.core:core-ktx:1.17.0")

    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    implementation("com.onesignal:OneSignal:5.9.4")

    implementation("io.github.webrtc-sdk:android:144.7559.09")
}

flutter {
    source = "../.."
}