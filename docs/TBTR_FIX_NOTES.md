# TBTR fix notes: force update, realtime messages, calls, presence

Branch `fix/force-update-realtime-calls`. These are the findings from reading
the code before any change was made.

## How the app is built

| Area | What it actually uses |
|---|---|
| Database | **Firebase Realtime Database** (no Firestore). Disk persistence is already on (`setPersistenceEnabled(true)` in `main()`). Chats are mirrored into a local SQLite store (`LocalChatStore` + `ChatSyncService`), and the feed into `LocalFeedStore`. |
| Push | **OneSignal**, not raw `firebase_messaging`. OneSignal delivers through FCM. The app never holds the OneSignal REST key: it calls the **Cloudflare Worker** (`cloudflare/worker_full.js`, routes `/send-push` and `/send-call-push`), which sends `priority: 10` (FCM high priority). The receiver's push address is `users/{uid}/oneSignalId`. |
| Server code | There are no Firebase Cloud Functions (no `functions/` folder; the project isn't on Blaze). The Worker plays that role. |
| Calls | Flutter **WebRTC** (`flutter_webrtc`) with RTDB signalling at `calls/{callId}`. On Android, a closed app rings through `CallNotificationServiceExtension.kt` (OneSignal's service extension). It posts a `CATEGORY_CALL` full-screen-intent notification, and `CallDeclineReceiver` writes `DECLINED` natively. Missed calls are logged by `MissedCallLog`. |
| Presence | `presence/{uid}` = `{online, lastSeen}` with `onDisconnect()` (`lib/screens/auth/presence_manager.dart`). The chat header already shows "Online" / "Last seen". |
| Force update | `lib/force_update/` uses Remote Config keys `force_update`, `min_version_code`, `latest_version_code`, …, with a saved copy for offline use and a real-time listener. `in_app_update` is a dependency. |
| Startup | Build 29 already removed the network waits (see `docs/RICH_LINKS_INSTANT_RESUME.md`). `main()` awaits only Firebase init and local reads (display names, cached profile, audio-service and notification-plugin setup). |

## What was actually broken

### Force update never fired
1. **Play's own update check only ran after Remote Config had already
   blocked the app.** `InAppUpdate.checkForUpdate()` was called only from
   the "Update now" button on the blocking screen. A new version on Play
   therefore did nothing on its own.
2. **Remote Config might not be published.** `force_update` defaults to
   `false` in the app, so nothing blocks unless
   `remoteconfig.template.json` was deployed. The Firebase CLI on this PC is
   logged in as an account that can't see the TBTR project, so the template
   can't have been deployed from here.
3. **Old installs read different keys.** Builds up to 3.2.1 read
   `min_required_version`, which compares version names like `3.2.2`.
   3.2.2+ reads `min_version_code`, which compares build numbers. Builds made
   before any force-update code existed can't be forced by anything except
   Play's own auto-update.
4. **The build number went down.** The uncommitted `pubspec.yaml` said `+25`,
   but build `+29` had already been made. Play rejects a version code that
   is lower than one already uploaded.

### "Offline" / "Updating…" shown on every start and resume
- These are the chips in the Audio screen's app bar, driven by the RTDB
  `.info/connected` flag. That flag is `false` for the first second or so of
  every launch and resume, even with perfect internet. The chips therefore
  flashed "Offline", then "Updating…" for 3 seconds. They never blocked the
  screen, but they made the app look slow and broken.

### Messages and calls don't arrive when the app is closed
1. **The push address is stale or missing.** `oneSignalId` is written once,
   at registration, and only if OneSignal already had an id at that moment.
   On a fresh install it usually doesn't. A reinstall or cleared data also
   gives a new id that is never saved. In all these cases pushes go to a dead
   or empty id, so a closed app gets nothing.
2. **Tapping a message notification only opens the app.** There's no click
   handler, so the right chat doesn't open.
3. **A closed app "dings" instead of ringing.**
   - The native call notification's channel plays the default notification
     sound once.
   - The looping ringtone only starts after Flutter boots, which happens only
     when the full-screen intent launches the activity.
   - When the phone is unlocked and the user is in another app, Android shows
     a heads-up banner instead of launching the activity. Flutter never
     starts, so there is one ding and no ring.
4. **The Android 14+ full-screen-intent permission is never checked.**
   Without it, the lock-screen ringing UI degrades to a small notification.
5. **The permission onboarding only runs right after registration.** Existing
   users who update never see it.
6. **Nothing opens the Infinix / Transsion auto-start screen.** XOS kills
   the app, and with it FCM delivery.

### Presence
1. `PresenceManager.start()` was only called when a **private chat screen
   opened**. A user who never opened a chat never showed as online.
2. Nothing keeps the process (and its RTDB socket) alive in the background.
   Android freezes or kills it within seconds to minutes, the server times
   out the socket, and `onDisconnect` marks the user offline. This happens
   even while they are just in TikTok.
3. The chat and contact lists don't show presence.

## Decisions

- **Keep OneSignal and the Worker; don't add raw FCM, Cloud Functions or
  `flutter_callkit_incoming`.**
  - The existing stack already sends high-priority pushes and has a native
    full-screen ring with accept / decline / missed.
  - A second FCM token path plus a CallKit plugin would show two
    notifications and play two rings for every message and call.
  - Cloud Functions also need the paid Blaze plan.

  The fixes go into the existing path instead.
- **Keep `presence/{uid}` = `{online, lastSeen}`** rather than renaming it to
  `status/{uid}`. Installed older versions read `presence/`, and the
  database rules already secure it.
- **Native presence service.** Presence is kept alive by a small native
  foreground service (`PresenceService.kt`) that uses the native Firebase
  RTDB SDK. It shares the Flutter plugin's connection, works without the
  Flutter engine, and restarts after reboot and after app update.
