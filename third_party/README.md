# Locally patched plugins

Flutter 3.44 warns about every plugin that applies the Kotlin Gradle Plugin
(KGP) itself ("Future versions of Flutter will fail to build if your app uses
plugins that apply KGP"). For the plugins below, no published version without
KGP could be used (see docs/KGP_WARNINGS_REMOVED.md for why), so the exact
version the app already used is copied here and pointed to with
`dependency_overrides` in `pubspec.yaml`.

**Only the Android Gradle build file was changed**, following
<https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors>:
the `kotlin-android` plugin is no longer applied by the plugin (with
`android.builtInKotlin=false` the Flutter Gradle plugin applies it), and Kotlin
options use the `kotlin { compilerOptions { … } }` form. Dart, Kotlin/Java,
iOS and all other files are byte-for-byte the published package. Each patched
file carries a `T.B.T.R local patch` comment.

| Plugin | Version copied | Change in `android/build.gradle` |
|---|---|---|
| firebase_core | 4.14.0 | removed the conditional `apply plugin: 'kotlin-android'` (its `kotlin { compilerOptions }` block was already there) |
| firebase_auth | 6.6.1 | same |
| firebase_database | 12.5.0 | same |
| firebase_remote_config | 6.7.0 | same |

## Removing a patch

When the official package ships "Migrates to built-in Kotlin" in its
changelog (check with `flutter pub outdated`):

1. delete its entry under `dependency_overrides` in `pubspec.yaml` and raise
   its version under `dependencies` (FlutterFire: all four together);
2. delete `third_party/<plugin>/`;
3. `flutter pub get`, `flutter build apk --debug` and check the KGP warning
   does not list it.
