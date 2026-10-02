# ============================================================================
#  R8 / ProGuard keep rules for the TBTR release build.
#
#  STATUS: staged, NOT active. `isMinifyEnabled` is false in build.gradle.kts,
#  so these rules do nothing yet. Turning minification on is a separate,
#  device-regression-tested change — flip the two flags in the release
#  buildType and do a full pass (calls, OneSignal push, chat, photo upload,
#  audio playback + notification) on a real device before shipping.
#
#  The Flutter Gradle plugin contributes its own Flutter/Dart keep rules
#  automatically when minification is on; everything below is for the native
#  third-party SDKs this app bundles, which use reflection / JNI / native
#  callbacks that R8 can't see.
# ============================================================================

# ---- Kotlin / coroutines -----------------------------------------------------
-dontwarn kotlinx.coroutines.**
-keepclassmembers class kotlin.Metadata { *; }

# ---- Gson (reflective serialization) ---------------------------------------
-keep class com.google.gson.** { *; }
-keepattributes Signature, *Annotation*, EnclosingMethod, InnerClasses
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
# Model classes serialized/deserialized by Gson in this app live in
# com.tbtrapp.** — keep their members so field names survive.
-keepclassmembers class com.tbtrapp.** { <fields>; }

# ---- Firebase (Auth / Database / Firestore / Storage) ----------------------
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**
# Firestore/RTDB map POJOs onto model classes by reflection.
-keepclassmembers class com.tbtrapp.** {
    <init>();
}

# ---- OneSignal ------------------------------------------------------------
-keep class com.onesignal.** { *; }
-dontwarn com.onesignal.**

# ---- WebRTC (io.github.webrtc-sdk) --------------------------------------------
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# ---- AndroidX Room (kapt-generated + entities) -----------------------------
-keep class * extends androidx.room.RoomDatabase { *; }
-keep @androidx.room.Entity class * { *; }
-dontwarn androidx.room.paging.**

# ---- Media3 / ExoPlayer ----------------------------------------------------
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---- Coil (io.coil-kt) ---------------------------------------------------------
-keep class coil.** { *; }
-dontwarn coil.**

# ---- Cloudinary ----------------------------------------------------------------
-keep class com.cloudinary.** { *; }
-dontwarn com.cloudinary.**

# ---- vanniktech android-image-cropper ------------------------------------------
-keep class com.canhub.cropper.** { *; }
-keep class com.vanniktech.** { *; }
-dontwarn com.canhub.cropper.**

# ---- OkHttp / Okio -----------------------------------------------------------
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**

# ---- audio_service (com.ryanheise) -------------------------------------------
-keep class com.ryanheise.audioservice.** { *; }

# ---- Our own platform-channel classes (referenced only from the manifest /
#      Flutter, so R8 sees them as unused) ----------------------------------
-keep class com.tbtrapp.MainActivity { *; }
-keep class com.tbtrapp.platform.** { *; }
-keep class com.tbtrapp.calls.** { *; }
-keep class com.tbtrapp.audio.** { *; }

# ---- ShortcutBadger --------------------------------------------------------
-keep class me.leolin.shortcutbadger.** { *; }
-dontwarn me.leolin.shortcutbadger.**

# ---- Play Core (in-app updates) -------------------------------------------
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**
