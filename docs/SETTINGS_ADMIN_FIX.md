# Settings screen and Admin PIN

Branch: `fix/settings-admin`, built on `fix/remove-kgp-warnings`, which is built on
`fix/phones-contacts-chat`. Version **3.2.2+26**.

| Commit | |
|---|---|
| `7ba8daf` | macOS plugin registrant regenerated (flutter_contacts 2.6.0) |
| `ca1c98e` | Part 1: Settings screen |
| `bfa6cfc` | Part 2: Admin PIN |
| `3a809e5` | build number 26 |

## Why 2222 stopped working

The PIN itself was never wrong: the app stores SHA-256("2222")
(`edee29f8…995e9`), and entering 2222 matched it. The **Phase 1 security
audit** (commit `32a42cf`) added a second check to the Admin gate: after the
PIN, the account also had to be listed as `admins/{myPhone} = true` in the
database. That `admins` node had never been created, so every correct PIN
ended with "This account is not on the admin list" and the screen stayed
locked.

## What changed

**Admin PIN** (`lib/admin/admin_pin.dart`, `lib/screens/admin_screen.dart`):

- The admin-list check is removed from the gate: the PIN alone opens Admin.
- The PIN is compared as a SHA-256 hash with `config/adminPinHash`, which now exists in the database (= hash of 2222). If the database can't be reached, the app uses the last hash it saw, and failing that a built-in copy of the 2222 hash. The plain "2222" is not in the code.
- A correct PIN is remembered until the app is closed.
- After 5 wrong tries, entry is locked for 30 seconds, with a countdown.
- The PIN field is a 4-digit numeric keypad with hidden dots, a show/hide eye, an **Enter** button, and messages like "Wrong PIN (3 tries left)".
- The Admin panel (audio approval, feedback list) is **unchanged**.
- `admins/+23288236249 = true` was written to the database (the "Prof." account, which is linked to your login and appears as "Pst. Evangelist Bangura" in older data). The approve/reject writes will keep working once `database.rules.json` is deployed. If your number is a different one, add it the same way (see below).
- `database.rules.json` (repo only, not deployed) now allows signed-in users to read `config/`.

**Anyone who knows 2222 can open Admin.** To change the PIN to e.g. 4821:

```powershell
# 1. compute the hash (any SHA-256 tool works)
node -e "console.log(require('crypto').createHash('sha256').update('4821').digest('hex'))"
# 2. store it (Firebase console → Realtime Database → config/adminPinHash, or):
firebase database:set /config/adminPinHash --data '"<hash from step 1>"' --project tonkoh-bible-truth-revea-a7694 --account bubuyacommunityhighschool@gmail.com
```

Phones pick up the new PIN the next time Admin is opened online. After that,
the old PIN no longer works on them, even offline.

To add another admin account:
`firebase database:set /admins/+232XXXXXXXX --data true --project … --account …`

**Settings** (`lib/screens/profile/settings_screen.dart`, `lib/data/profile_settings_repository.dart`):

- **Profile picture.** A large circle with a camera badge. Tap it for Take photo / Choose from gallery / Remove photo. The photo is cropped with the app's existing cropper and shown as a circle, then re-encoded as a JPEG of at most 800×800 (quality 85, typically 30–60 KB), with a progress ring while it works. If camera or photo access is refused, a friendly dialog offers **Open settings**.
- **Account name.** Required, 2–40 characters, extra spaces trimmed, with the error shown under the field.
- **Phone number.** Read-only and formatted (`+232 88 236 249`), with a copy button and the note "This is your T.B.T.R number". **Country** is shown with flag, code and dial code, worked out from the number (🇸🇱 Sierra Leone (SL) +232).
- **Save.** Enabled only when the photo or name changed. It writes **only** `users/{me}/name`, `photoUrl` and `updatedAt` in one multi-path `update()`, so the OneSignal id, auth link, device id and everything else stay untouched. It also refreshes your name/photo in your chat partners' `userChats` rows, which older app versions show. Your cached profile updates at once, so the drawer header, your feed posts and your chats show the change immediately. "Profile saved ✓" on success; on failure the reason is shown, your edits stay, and it retries automatically.
- **Offline.** "Will save when you are online"; the change is sent automatically when the connection returns, or at the next app start.
- **Back with unsaved changes** asks "Discard changes?".
- **Opening** shows the cached profile instantly, then refreshes from the database.
- **Drawer (☰) header** now shows your photo and name, and updates after saving.

**Decisions:**

- **Photos stay Base64 in `users/{me}/photoUrl`, not Cloudinary.** Every avatar in the app reads `photoUrl` as Base64: chats, chat list, contacts, feed, the native call screens and call notifications, and the app versions already on people's phones. A Cloudinary URL there would show blank avatars in all of those. The compressed JPEG is smaller than the photos saved so far.
- **No `publicProfiles` node.** It doesn't exist and nothing in the app reads it. Your name/photo live in `users/{me}`, plus the chat-list rows updated above.
- **The phone number can no longer be changed in Settings** (as requested). Registration still uses the phone field with the country picker.

## Tests

- `test/admin_pin_test.dart`:
  - 2222 is correct and other PINs are wrong;
  - non-4-digit input is rejected;
  - lockout after 5 tries ends after 30 s;
  - a PIN changed in the database replaces 2222, also offline afterwards;
  - built-in fallback.
- `test/profile_settings_test.dart`:
  - name rules;
  - save writes only the leaf paths and keeps `oneSignalId`, `authUid` and device id;
  - photo change and removal;
  - chat-list refresh;
  - offline queue, merge and later send;
  - a rejected write stays queued;
  - widget tests: Save disabled until a change, invalid name disables Save, number and country shown read-only.
- Not done: approving and rejecting a test upload in the Admin panel. That needs the app running on a phone (checklist item 8). The panel's code is untouched.

## Builds

| Step | Result |
|---|---|
| `flutter clean`, `flutter pub get` | OK |
| `flutter analyze` | No issues found |
| `flutter test` | **235 passed** (2 preview renders skipped by design) |
| `flutter build apk --debug` (KGP branch) | OK — **no KGP warning at all** |
| `flutter build apk --release --split-per-abi` | **OK** after 24.5 min (Gradle kept running after its parent shell was stopped for low memory). `app-arm64-v8a-release.apk` 37.6 MB, `app-armeabi-v7a-release.apk` 30.7 MB, `app-x86_64-release.apk` 42.8 MB. **No KGP warning** in the output (`docs/build_logs/release_apk_build.txt`). |
| `flutter build appbundle --release` | **Not run:** its step never started because the parent shell had been stopped. Run it yourself (below). |

Android Studio stayed open during the build: I asked it to close normally,
but it stayed on its own confirmation and I did not force it.

**Signing:** `android/key.properties` is missing and there is no keystore in
the project, so a release build is signed with the **debug key**. That is
fine for installing on your phone, but Play rejects the AAB. Restore
`android/key.properties` before building for Play.

Run these yourself with **Android Studio closed**:

```powershell
$env:Path += ";E:\APACHE\flutter\bin"
cd E:\APACHE\TonkohApp
cd android; .\gradlew --stop; cd ..
flutter build apk --release --split-per-abi
cd android; .\gradlew --stop; cd ..
flutter build appbundle --release
```

- Phone APK: `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk`
- Play AAB: `build\app\outputs\bundle\release\app-release.aab`

## Phone test checklist (SM-A175F)

1. ☰ → Settings: circle photo with camera badge. Take a photo → crop → Save. The photo updates in the drawer header, your feed posts and your chats.
2. Change the photo from the gallery → Save. Try Remove photo → Save.
3. Change the account name → Save. The name updates everywhere. In Firebase, `users/+232…/name` is new and `oneSignalId`, `authUid` and `activeDeviceId` are unchanged.
4. The phone number shows `+232 …` with a copy button; the country shows 🇸🇱 Sierra Leone (SL) +232.
5. Save is disabled until something changes. Press back with unsaved changes: it asks "Discard changes?".
6. Turn off the internet, change the name, Save → "Will save when you are online". Turn the internet on: it saves (check Firebase).
7. ☰ → Admin → 2222 → Admin opens. A wrong PIN shows an error; 5 wrong tries lock for 30 s. Open Admin again in the same session: no PIN asked.
8. Approve and reject a test audio upload in the Admin panel.
9. Discussions, Bible Facts and Feedback work exactly as before.
10. The KGP checklist in docs/KGP_WARNINGS_REMOVED.md: calls both ways, contacts, sharing in and out, copying a photo message, notifications, update check.
