# ============================================================================
#  R8 keep rules for the TBTR release build (minify + resource shrinking ON).
#
#  Only rules R8 cannot work out for itself belong here. Firebase, Play
#  services, OneSignal, OkHttp, coroutines and AndroidX ship their own
#  consumer rules inside their AARs, and the Flutter Gradle plugin adds the
#  Flutter/Dart rules. Blanket `-keep class some.library.** { *; }` rules
#  switch R8 off for that whole library and count against Google Play's
#  code-optimization coverage, so don't add them back without a reason.
#
#  Classes declared in AndroidManifest.xml (activities, services, receivers)
#  are kept automatically by AAPT-generated rules.
# ============================================================================

# ---- WebRTC ------------------------------------------------------------------
# The native libwebrtc calls back into these Java classes through JNI by name
# (observers, video frames, audio device module). R8 can't see JNI callers.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# ---- Firebase Realtime Database model --------------------------------------
# Read with DataSnapshot.getValue(IceCandidateModel::class.java), which maps
# fields onto the class by reflection and needs the no-arg constructor.
-keep class com.tbtrapp.calls.IceCandidateModel { *; }

# ---- OneSignal notification extension ---------------------------------------
# Instantiated by OneSignal from the class name in the manifest <meta-data>
# value "com.onesignal.NotificationServiceExtension"; R8 doesn't read
# meta-data values, so it would otherwise rename or remove the class.
-keep class com.tbtrapp.calls.CallNotificationServiceExtension { <init>(); *; }

# ---- Play Core (Flutter deferred components) -------------------------------
# The Flutter engine references Play Core split-install classes that this
# app doesn't ship (it doesn't use deferred components).
-dontwarn com.google.android.play.core.**
