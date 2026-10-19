# Kotlin Gradle Plugin (KGP) warnings removed

Branch: `fix/remove-kgp-warnings` (from `fix/phones-contacts-chat`).
Flutter 3.44.1, AGP 9.0.1, Kotlin 2.3.20, `android.builtInKotlin=false`.

## Result

`flutter build apk --debug` on this branch prints **no** KGP warning: neither
"Your Android app project … applies the Kotlin Gradle Plugin" nor "Your app uses the
following plugins that apply Kotlin Gradle Plugin". The complete build output
was:

```
Running Gradle task 'assembleDebug'...
√ Built build\app\outputs\flutter-apk\app-debug.apk
```

Every patched or upgraded plugin's Kotlin code was compiled into the APK. Class
counts from `build/<plugin>/tmp/kotlin-classes`: firebase_auth 76,
firebase_core 12, firebase_database 42, firebase_remote_config 11,
flutter_webrtc 4 (+98 Java), pasteboard 1, device_info_plus 2,
package_info_plus 2, share_plus 9, flutter_contacts 171.

## The 10 plugins

| Plugin | Outcome | Why |
|---|---|---|
| firebase_core 4.14.0 | **patched locally** (C) | The newest FlutterFire release (core 5.0.0, auth 7.0.0, database 13.0.0, remote_config 7.0.0) still applies KGP, so there is no version to upgrade to (A). Replacing Firebase is out of scope. The four are patched as one set at the versions the app already uses, so Firebase behaviour is unchanged. |
| firebase_auth 6.6.1 | **patched locally** (C) | same |
| firebase_database 12.5.0 | **patched locally** (C) | same |
| firebase_remote_config 6.7.0 | **patched locally** (C) | same |
| flutter_webrtc 1.6.0 | **patched locally** (C) | The newest 1.6.2+hotfix.4 still applies KGP. Replacing it is out of scope (calls). |
| pasteboard 0.4.0 | **patched locally** (C) | Used only for "Copy" on an **image** message (`Pasteboard.writeImage`). Flutter's `Clipboard` copies text only (B impossible). The newest 0.5.0 still applies KGP (A impossible). |
| device_info_plus 12.4.0 | **patched locally** (C) | 13.2.0+ no longer applies KGP, but needs `win32 ^6`. The app's `file_picker 9` needs `win32 ^5`. The first file_picker on win32 6 is 12.x, whose new Android picker returns `content://` files with **no file path**; uploads stream large videos to Cloudinary from that path, so that upgrade would break video uploads. B is impossible too: the `vibration` plugin depends on device_info_plus, so it would stay in the build anyway. |
| package_info_plus 9.0.1 | **patched locally** (C) | Same win32 block as device_info_plus. B (own MethodChannel) was considered, but the force-update check reads three values (version, build number, installer store) on Android **and** iOS. A patch keeps both platforms exactly as they are with less risk. |
| share_plus 11.1.0 | **patched locally** (C) | Same win32 block. Sharing (text, images, video, audio files) is too broad to re-implement. |
| flutter_contacts 1.1.9+2 | **upgraded to 2.6.0** (A) | 2.2.0 migrated to Built-in Kotlin, and 2.3.0 also returns every contact the system Contacts app shows (1.x skipped contacts not flagged `IN_VISIBLE_GROUP`, which is common on Samsung). No new Android permissions. |

What "patched locally" means, and how to undo it: `third_party/README.md`.

- The exact published version is copied into `third_party/<plugin>/` and selected with `dependency_overrides` in `pubspec.yaml`.
- Only `android/build.gradle` changed, following Flutter's plugin-author migration guide:
  - no `apply plugin: 'kotlin-android'`; Flutter 3.44 applies KGP itself while `builtInKotlin=false`;
  - no plugin-private KGP on the buildscript classpath, since versions 1.7.22–2.2.0 would clash with the app's 2.3.20;
  - Kotlin options use `kotlin { compilerOptions { jvmTarget = … } }`.
- `third_party/` is excluded from `flutter analyze`.

## Code changed because of upgrades

Only for flutter_contacts 2.6.0:

- `lib/data/contacts_repository.dart`:
  - `requestPermission(readonly: true)` → `permissions.request(PermissionType.read)`;
  - `getContacts(withProperties: true)` → `getAll(properties: {name, phone})`;
  - `displayName` and `normalizedNumber` are now nullable.
- `lib/data/contact_sync_service.dart`: `addListener` → `onDatabaseChange` stream.
- `lib/screens/audio_screen.dart` ("Save contact" from the feed): `openExternalInsert` → `native.showCreator`.

## Commits

| | |
|---|---|
| `c1c3bbc` | FlutterFire patched copies (+ analysis exclude) |
| `ed676be` | flutter_webrtc patched copy |
| `57b0353` | pasteboard patched copy |
| `9827e75` | device_info_plus patched copy |
| `394e95e` | package_info_plus patched copy |
| `9a991c1` | share_plus patched copy, overrides for all five |
| `03b44c1` | flutter_contacts 2.6.0 |

## Notes

- **Builds:** Android Studio was open (≈1.8 GB) and only ~1.3 GB of RAM was free. I asked it to close normally, but it stayed open (probably its own "exit?" confirmation), and I did not force it in case of unsaved work. With that little memory one build takes ~15 minutes, so I built once after all plugin changes instead of after each one. Every change was still committed separately, and `flutter analyze` and `flutter test` (219 passed) ran after each group.
- **Release APK/AAB** are built together with the Settings/Admin work (branch `fix/settings-admin`, see `docs/SETTINGS_ADMIN_FIX.md`).
- **Signing:** `android/key.properties` is still missing and there is no keystore in the project, so release builds are signed with the debug key. Restore `key.properties` before building for Play.

## Phone test checklist (SM-A175F)

1. Sign in / app opens on the feed; the feed loads.
2. Upload an audio from the feed.
3. Open a chat (instant), send a text and a voice note.
4. Long-press a **photo** message → Copy (pasteboard), then paste it in another app. Copy a text message too.
5. Voice call and video call, both directions.
6. Contacts screen shows your contacts (long-press "Contacts" for the counts). "Save contact" from a member's sheet in the feed opens the phone's new-contact screen.
7. Share from WhatsApp/YouTube into the app; share a message or sermon out of the app.
8. Notifications (message, call) with the app closed.
9. App version in the force-update check / in-app update check (package_info_plus); call tips on your phone brand (device_info_plus).
