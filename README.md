# TBTR App — Tonkoh Bible Truth Revealers

Flutter app for the Tonkoh Bible Truth Revealers community: a shared gospel
audio feed, private chat, and voice/video calls between members.

- **Android** is the main target (native Kotlin layer for calls, audio
  services and SIM contacts under `android/app/src/main/kotlin`).
- **Backend:** Firebase Realtime Database + anonymous Auth + Remote Config,
  OneSignal push, Cloudinary media, and a Cloudflare Worker
  (`cloudflare/worker_full.js`) for push relay, TURN credentials and account
  transfer.

## Build

```sh
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
```

### Release signing

Create an upload keystore once (keep it and its passwords safe — losing it
means you can't update the app on Play):

```sh
keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias upload
```

Then create `android/key.properties` (git-ignored):

```properties
storeFile=upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Without it, release builds fall back to the debug key and Play will reject
them (Gradle prints a warning).

## Database rules

`database.rules.json` holds the Realtime Database rules (accounts are tied to
the owning Firebase login via `users/{phone}/authUid` ⇄ `authIndex/{authUid}`;
admins are listed under `admins/{phone}: true`). Test them locally — never
against the live database:

```sh
firebase emulators:exec --only database --project demo-tbtr \
  "node firebase_tests/database_rules.test.mjs"
```

(The emulator needs Java; Android Studio ships one in `<Android Studio>/jbr`.)

Deploy with `firebase deploy --only database` — see the rollout order in
`cloudflare/README_migration.md` first.

## Sharing into the app

On Android, "Share → TBTR App" from TikTok, WhatsApp, YouTube, the gallery
etc. lands in `ShareReceiverActivity` (copies the content, brings the app
forward) and opens the "Share to…" screen (`lib/share/`), where it can be
posted to the audio feed and/or sent to private chats.

iOS isn't wired yet. It needs a **Share Extension** target in Xcode
(`ios/`), an App Group shared between the extension and the app, the
extension writing the shared items into the group container and opening the
app via a custom URL scheme, and `AppDelegate` answering the same
`com.tbtrapp/share` channel (`ready` / `onShare`, same map shape as
`ShareInbox.Payload.toMap`).

## Cloudflare Worker

`cloudflare/worker_full.js` is the whole Worker. Secrets and deploy steps are
listed at the top of the file and in `cloudflare/README_migration.md`.
