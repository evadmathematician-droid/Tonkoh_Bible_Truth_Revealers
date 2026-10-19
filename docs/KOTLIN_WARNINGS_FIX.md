# Kotlin Gradle Plugin & Java 8 build warnings — fix report

Branch: `fix/kotlin-gradle-warnings` (from `feature/audit-fixes-contacts-share`)

## Environment

- Flutter 3.44.1 (stable, 2026-05-29), Dart 3.12.1
- AGP 9.0.1, Gradle 9.1.0, Kotlin 2.3.20 (unchanged)
- JDK 21 (Android Studio JBR), Android SDK 36.1.0

## Commits

1. `WIP before Kotlin warning fixes` (on the old branch): tonkoh.txt, tonkoh_prompt.txt
2. `Migrate app module off the Kotlin Gradle Plugin (Built-in Kotlin, step 2)`
3. `Upgrade record (7.1.2) and flutter_foreground_task (11.0.3) to Built-in Kotlin versions`
4. `Silence javac "source/target value 8 is obsolete" warnings from plugins`
5. `Add Kotlin warnings fix report`

## Warnings, before → after

| Warning | Before | After |
|---|---|---|
| App project applies the Kotlin Gradle Plugin | shown | **gone** |
| Plugins applying KGP | 12 plugins | 10 plugins (`flutter_foreground_task`, `record_android` removed) |
| `source/target value 8 is obsolete` (javac) | 5 × 3 lines | expected gone, see "Verification" |

### Why the app migration is only partial (step 2 of the guide)

The official guide has three parts: (1) gradle.properties flags, (2) remove
`kotlin-android` from `app/build.gradle.kts` and use `kotlin { compilerOptions }`,
(3) set `android.builtInKotlin=true`. The guide says step 3 **requires Flutter
3.47 or later**, and this machine has 3.44.1. So:

- `kotlin-android` was removed from the app's `plugins {}` block. The
  `kotlin { compilerOptions { jvmTarget = JVM_17 } }` block was already in the
  new form and stays.
- `android.builtInKotlin=false` stays. With that flag, Flutter 3.44's Gradle
  plugin applies KGP to the app module itself, so `MainActivity.kt` and the
  calls/audio/share Kotlin code still compile. This was checked: 90 Kotlin
  classes were built, and the class files are Java 17 (major version 61).
- KGP remains declared (`apply false`) in `settings.gradle.kts`. It has to stay
  there because Flutter loads it from that classpath.
- No AGP or Gradle upgrade was needed. Both were already on 9.x.

**Later, after upgrading Flutter to 3.47+:** set `android.builtInKotlin=true`
in `android/gradle.properties`. That only works once every plugin below has
been migrated too.

### Plugins that still apply KGP (left as they are)

| Plugin | Current | Latest | Why it was not upgraded |
|---|---|---|---|
| firebase_core / firebase_auth / firebase_database / firebase_remote_config | 4.14.0 / 6.6.1 / 12.5.0 / 6.7.0 | 5.0.0 / 7.0.0 / 13.0.0 / 7.0.0 | Even the latest FlutterFire release still applies `kotlin-android`, so a major upgrade would not remove the warning. |
| flutter_webrtc | 1.6.0 | 1.6.2+hotfix.4 | The latest version still applies KGP. Calls were left untouched. |
| pasteboard | 0.4.0 | 0.5.0 | The latest version still applies KGP. |
| flutter_contacts | 1.1.9+2 | 2.6.0 | 2.2.0+ is Built-in Kotlin, but 2.0 is a complete API rewrite, so contact sync and the contact sheet would need rewriting. |
| share_plus | 11.1.0 | 13.3.1 | 13.2.0+ is Built-in Kotlin, but it needs `win32 ^6`. |
| device_info_plus | 12.4.0 | 13.3.0 | Same `win32 ^6` problem as share_plus. |
| package_info_plus | 9.0.1 | 10.2.2 | Same `win32 ^6` problem as share_plus. |

About the plus_plugins: the app's `file_picker ^9` needs `win32 ^5`. The first
`file_picker` that accepts `win32 6` is 12.0, a federated rewrite. In 12.0,
`FilePicker.platform` and `allowMultiple`/`withData` are removed, and
`FileType.image` now opens the gallery. That would change how audio, image and
video uploads and chat attachments are picked, so it should be its own task,
with share_plus, device_info_plus and package_info_plus upgraded at the same
time.

## Files changed

- `android/app/build.gradle.kts`: removed `id("org.jetbrains.kotlin.android")` and updated the comments
- `android/build.gradle.kts`: new `subprojects { tasks.withType<JavaCompile>() … "-Xlint:-options" }` block
- `pubspec.yaml`, `pubspec.lock`: package upgrades below
- `docs/KOTLIN_WARNINGS_FIX.md`: this report

`gradle.properties` was not changed. It still has `-Xmx2G`,
`builtInKotlin=false` and `newDsl=false`. Signing, version (3.2.1+24),
package name and features were not changed either.

## Package versions changed

| Package | Old | New |
|---|---|---|
| flutter_foreground_task | 8.17.0 | 11.0.3 |
| record | 6.2.1 | 7.1.2 |
| record_android | 1.5.2 | 2.2.0 |
| record_platform_interface | 1.6.0 | 2.1.0 |
| record_ios / record_macos | 1.2.1 / 1.2.2 | 2.1.1 / 2.1.1 |
| record_web / record_linux / record_windows | 1.3.0 / 1.3.1 / 1.0.7 | 2.1.3 / 2.1.3 / 2.3.0 |

## App code that uses the upgraded plugins

- **record**: `lib/services/voice_recorder.dart` uses `AudioRecorder.startStream`
  with `RecordConfig(pcm16bits, sampleRate, numChannels: 1)`. record 7 removed
  the Android background recording service and iOS `manageAudioSession`. The
  app uses neither, so no code change was needed. record_android 2.2 also adds
  better Bluetooth SCO handling and clamps the config to what the device
  supports. minSdk 24 matches the app.
- **flutter_foreground_task**: no Dart code uses it, and the manifest has no
  entry for it. It is only registered as a plugin. No change was needed.

## Verification

| Check | Result |
|---|---|
| `flutter clean` + `flutter pub get` | OK (the Windows "enable Developer Mode for symlinks" notice is the same as before) |
| `flutter analyze` | No issues found |
| `flutter test` | All 44 tests passed |
| `flutter build apk --debug` after the app migration and plugin upgrades | OK |
| Final clean `flutter build apk --debug` + `flutter build appbundle --release` with the `-Xlint:-options` change | **Not finished**: Claude Code stopped the build because the PC ran low on memory. Run it again yourself (below). |

Note: after a plugin version changes, the first build can fail with
`Unresolved reference 'AdtsContainer'` in record_android. That error comes from
a stale incremental Kotlin cache in `build/record_android`. Deleting that
folder (or running `flutter clean`) fixes it.

Commands to run (close Android Studio and other heavy apps first):

```powershell
$env:Path += ";E:\APACHE\flutter\bin"
cd E:\APACHE\TonkohApp
flutter clean; flutter pub get
flutter build apk --debug
flutter build appbundle --release
```

Expected result: one KGP warning listing the 10 plugins above, no
"applies the Kotlin Gradle Plugin" line for the app, and no
`source/target value 8 is obsolete` lines. If the `-Xlint` block causes any
problem, revert only that commit: `git revert 5756c63`.

## Phone test checklist (Samsung SM-A175F)

- [ ] App starts; sign-in / existing session works (Firebase is unchanged, just a smoke test)
- [ ] Audio feed loads and plays; background playback notification works
- [ ] Chat: send a text, an image and a file attachment
- [ ] **Voice message**: record, pause/resume, stop and send; playback works; the level meter moves (record 7)
- [ ] Voice message with Bluetooth headset, if available (record_android 2.2 changed SCO handling)
- [ ] Voice and video call: outgoing and incoming, ringtone, hang up (Kotlin call code, now compiled with KGP applied by Flutter)
- [ ] Contacts sync and contact sheet from the audio feed
- [ ] Share out (share_plus) and receive shares from WhatsApp/TikTok/YouTube (Kotlin share code)
- [ ] Push notifications (OneSignal) arrive while the app is in the background or closed
- [ ] Force-update / version check screen still reads the version correctly
- [ ] Release bundle: repeat calls, push, chat, upload and audio (R8 build)

## Merge command

When the builds and the phone test are OK:

```powershell
git checkout feature/audit-fixes-contacts-share
git merge --no-ff fix/kotlin-gradle-warnings
```
