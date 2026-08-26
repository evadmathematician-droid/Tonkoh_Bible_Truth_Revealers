# Flutter's own engine/JNI keep rules are added automatically by the
# Flutter Gradle plugin — this file only covers this app's OWN extra risk
# points now that minifyEnabled/shrinkResources are on for release.

# Play Core (in_app_update / AppUpdateGate + ForceUpdateScreen): Flutter's
# embedding references com.google.android.play.core.splitcompat/splitinstall
# classes reflectively for deferred-components support even though this app
# doesn't use dynamic feature modules. Without this, R8 fails the release
# build outright with "Missing class com.google.android.play.core...." — a
# well-known Flutter + Play Core + R8 interaction, not specific to this app.
-dontwarn com.google.android.play.core.**

# WebRTC (flutter_webrtc): native/JNI code calls into these Java classes by
# name from C++, which R8's static analysis can't see as "in use" — without
# this they can be stripped/renamed and crash only in release builds.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# OneSignal push notifications — standard vendor-recommended keep.
-keep class com.onesignal.** { *; }
-dontwarn com.onesignal.**

# Firebase Realtime Database POJO mapping (UserProfile, AppContact, etc.
# under com.tbtrapp.data/.calls — used with snapshot.getValue(Class) /
# Gson, both of which deserialize by reflecting over field names). R8 can't
# see that reflection as a real reference, so without this it can rename or
# strip fields and break deserialization silently instead of at compile time.
-keepclassmembers class com.tbtrapp.data.** { *; }
-keepclassmembers class com.tbtrapp.calls.** { *; }
-keepclassmembers class com.tbtrapp.auth.** { *; }
