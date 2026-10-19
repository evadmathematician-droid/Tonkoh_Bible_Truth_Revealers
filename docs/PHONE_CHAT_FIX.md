# Phone numbers, contact sync, instant chats & chat background

Branch: `fix/phones-contacts-chat` (from `fix/kotlin-gradle-warnings`). Version **3.2.2+25**.

| Commit | |
|---|---|
| `c7132ba` | WIP before phone/chat fixes (ignore `android/.kotlin/`) |
| `0ed55b5` | Phase 1: one strict E.164 phone format everywhere |
| `c7a2b8c` | Phase 2: repair phone numbers in Firebase (`tools/fix_phone_numbers.js`) |
| `a9ed071` | Phase 3: contact sync that matches like WhatsApp |
| `5946dcc` | Phase 4: chats open instantly from the phone (local-first) |
| `4c7aaed`, `e86817d` | Phase 5: "Morning Lilac" chat theme |
| `18ebd48` | Version 3.2.2+25 |

## Status

| Check | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | 219 passed (2 preview renders skipped by design) |
| `node tools/fix_phone_numbers.test.js` | all passed |
| Live database fix | applied and verified (details below) |
| `flutter build apk --debug` / `--release --split-per-abi` / `appbundle --release` | **Not run.** Claude Code stopped the first build because the PC ran low on memory (Android Studio was using about 2.2 GB of 7.4 GB). See "Build" below. |

## Phase 1 — phone numbers

- `lib/util/phone_utils.dart` is now the only place that parses numbers.
  - `normalizePhone()`: default country Sierra Leone, strict E.164.
  - `repairStoredPhone()`: also fixes `+0…` and a wrong country guess.
  - `formatPhoneForDisplay()`: `+232 31 932 652`.
  - All the inputs you listed are covered by 160+ unit tests, plus random spacing and punctuation.
- **Root cause of the wrong numbers:** registration preselected the country from the **phone's language setting**. A phone set to UK English turned `034909376` into `+44034909376`. Older app versions also saved `+031932652` on feed posts. Registration now defaults to Sierra Leone, with a country picker and a live "Your number: +232 …" preview.
- Edit Profile uses the same field. Since the number is the account key, changing it to a different number asks for confirmation first.
- Self-repair on app start: a malformed account id on the phone is moved to E.164 (copy → verify → delete), or adopted if the server fix already moved it. Local chat history is re-keyed to match.
- Feed and chat avatars never show "+": initials come only from letters, otherwise a person icon.
- Every phone touchpoint is listed in `docs/PHONE_AUDIT.md`.

## Phase 2 — Firebase data (done on the live database)

Backups, all in `backups/` (git-ignored, because they hold user data):

- `rtdb_backup_20261019_003639.json`: full export before any change (26 MB)
- `rtdb_before_fix_20261019T011026.json`: export taken immediately before writing
- `phone_fix_patch_20261019T011026.json`: the exact 20-path update that was written
- `phone_fix_report_applied.json` (what changed) and `phone_fix_report.json` (re-check afterwards: 0 changes)

Results:

| | |
|---|---|
| Accounts moved | 1: `users/+44034909376` → `+23234909376` (Mohamed K Dumbuya; country GB → SL) |
| Feed posts | 3 posts with sender `+031932652` → `+23231932652`; 4 bare `088…`/`031…` sender phones fixed |
| textMessages | 1 sender phone fixed |
| feedback | 6 phone fields `07…`/`08…` → E.164 |
| Merges | 0 (no account existed under both a wrong and a correct key) |
| Conflicts | 0 |
| `phoneAliases` | `+44034909376` → `+23234909376`, `+031932652` → `+23231932652` |
| Re-run | second dry run: **0 changes** (idempotent) |
| Left alone | `users/+23200000001`: a leftover diagnostics record (device `diag-A`, no name or phone). To delete it: `firebase database:remove /users/+23200000001 --project tonkoh-bible-truth-revea-a7694 --account bubuyacommunityhighschool@gmail.com` |

Notes:

- The script uses the logged-in firebase CLI (`--account bubuyacommunityhighschool@gmail.com`, the account that owns the project). An Admin SDK mode exists (`--credentials sa.json`) but was not tested, because there is no service-account key on this PC.
- `phoneIndex` was **not** rebuilt. It holds 12 legacy entries mapping numbers to the very first app version's anonymous-auth ids, plus test numbers, and the current app never reads it. Only phone-shaped keys are repaired there. No `publicProfiles` node exists and nothing reads one, so none was created. Contact sync looks numbers up directly as account keys instead (Phase 3).
- **Mohamed K Dumbuya** must update the app. On the old version, his account now looks missing, so he would be sent to registration. The new version follows the alias automatically. After publishing 3.2.2, consider raising `min_version_code` in Remote Config to 25.
- Worker: `/migration-verify` now resolves `claimedPhone` through `phoneAliases` (`cloudflare/worker_full.js`). This **needs a Worker redeploy** to take effect.
- `database.rules.json` (repo only, still not deployed) gains a `phoneAliases` rule: readable by signed-in users; a user can only create an alias pointing to their own account.

## Phase 3 — contact sync

- Every number of every contact (phone storage, Google/other accounts, SIM, plus Android's normalized copy) goes through `normalizePhone` with your own country as the default. Distinct numbers are then looked up directly as `users/{e164}/uid`, in parallel batches of 40.
- Before, every sync downloaded the whole `users` node (1.4 MB, photos included) and kept the result only in memory. A slow or failed download left the list empty.
- The address book is never uploaded.
- The result is saved on the phone: the Contacts screen opens instantly from it, then refreshes quietly. Sync runs on app start, after the permission is granted, on resume, when contacts change, and on pull-to-refresh. A lookup that fails while offline keeps the person's previous match.
- **Diagnostics:** long-press the "Contacts" title to see "Contacts read: X · Valid numbers: Y · On T.B.T.R: Z · Last sync: time". The yellow debug bar is gone.
- Tested with a fake phone book (`test/contacts_matching_test.dart`) containing your examples: `031932652`, `+031932652`, `0023288236249`, `+232 88 236 249`, a contact with two numbers, foreign and invalid numbers. All match correctly, and duplicates of the same account collapse into one row.
- I could not reproduce "only me" on your phone from here. The diagnostics line will now show where it stops, if it still happens.

## Phase 4 — instant chats

**Cause of the 3–5 s blank chat:**
- Firebase `privateChats` is a delete-on-delivery relay, and messages only reached the phone's database while that chat screen was open. Opening a chat first downloaded every waiting message (base64 voice notes included).
- After each one, the screen re-read the **whole** history from SQLite.

**Now:**
- A background `ChatSyncService` listens to every chat's relay as soon as the app starts. It saves new messages to the phone before you open the chat, then removes them from the relay exactly as before.
- SQLite schema v4 is an additive upgrade, so history survives the Play update (tested from the current v3 database). It adds a send status, a `(chatId, timestamp)` index, a local chat list and saved profile photos.
- Opening a chat draws the newest 50 messages on the first frame: from memory if the chat was opened before, otherwise one indexed read. The list is reversed, so it starts on the newest message with no jump and no spinner. Older pages load when you scroll up.
- Sending is local-first for text, stickers, voice and attachments:
  - clock = waiting (offline or sending)
  - one tick = on the server
  - two grey ticks = the other phone has it
  - two blue ticks = read
  
  Offline messages wait in an outbox and send when the connection returns, also after an app restart.
- Discussions, names and avatars come from the phone instantly; Firebase only refreshes them.
- **Not done as written:**
  - No `startAfter(lastTs)` cursor. The relay only ever holds undelivered messages, and a timestamp cursor would lose a message composed offline with an older timestamp.
  - The "jump back to the last read position" feature was removed, because chats must now open on the newest message.

**Open-time measurements** (1,200-message chat, realistic mix with inline voice notes and photos, on this PC through real SQLite — `test/local_chat_store_test.dart`):

| | before | after |
|---|---|---|
| Local read on open | 43–57 ms (all 1,200 full rows) | 13–15 ms (newest 50) |
| Reopening a chat | same full read again | 0.01 ms (memory) |
| Network before messages appear | waited for the relay download | none (already saved by background sync) |

On the phone, SQLite is several times slower than on this PC, and the old screen also re-read everything after each arriving message. I could not measure on your phone. The app now logs it: with the phone connected, run `flutter logs` and open a long chat to see `[ChatOpen] 50 messages visible after N ms`.

## Phase 5 — chat colours ("Morning Lilac")

All chat colours are defined in `lib/ui/chat_theme.dart` and follow the phone's light/dark setting. The rest of the app has no dark theme, so only the chat switches.

- Background `#ECEAF3`, with a ~5 % pattern of small doves and crosses. It's a static layer, so it costs nothing while scrolling.
- My bubbles `#1E3A5F` with white text; time and ticks `#C9D6EA`; read ticks `#7FD3FF`.
- Their bubbles white with `#1B1B1F` text; time `#6B6B78`.
- Links `#1565C0` on white and `#9CC8FF` on navy. Links are now tappable.
- Date chips `#D9D5E6` with `#3D3A4A` text. The input bar is white with a light top shadow; the send button stays the app's blue.
- Dark: background `#16141D`, mine `#2B4C7E`, theirs `#25232E` with `#ECEAF3` text.
- Reply quotes, voice, audio and file bubbles use the same palette.
- Every text/background pair passes WCAG AA (≥ 4.5:1), checked in `test/chat_theme_test.dart`.

Previews: `docs/chat_colors_light.png`, `docs/chat_colors_dark.png`.

## Build — to run yourself

Close Android Studio first; with it open, only ~1.3 GB of RAM was free.

```powershell
$env:Path += ";E:\APACHE\flutter\bin"
cd E:\APACHE\TonkohApp
flutter build apk --debug
flutter build apk --release --split-per-abi
flutter build appbundle --release
```

- APK for the SM-A175F: `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk` (or `app-debug.apk`)
- AAB for Play: `build\app\outputs\bundle\release\app-release.aab`
- **Signing:** `android/key.properties` is missing and there is no keystore in the project, so release builds are signed with the debug key and Play will reject the AAB. Restore `android/key.properties` (storeFile, storePassword, keyAlias, keyPassword) pointing at your upload keystore before building the AAB.
- New dev-only dependency: `sqflite_common_ffi` (for the store tests). It is not part of the app.

## Phone test checklist (Samsung SM-A175F)

1. Register test accounts with `031932652`, `31932652` and `+23231932652`. The preview must show `+232 31 932 652` each time, and the account must be saved as `+23231932652`. Try a wrong number and check that a clear message appears.
2. Feed: the three old posts by `+031932652` show `+232 31 932 652` (or your saved contact name), and no "+" avatar.
3. Contacts: all your phone contacts who use the app are listed. Long-press "Contacts" and check the counts look right. Pull down to refresh.
4. Open a long chat: messages appear immediately, already at the newest one. Scroll up to load older messages. A message from the other phone arrives live; it also arrives while the chat is closed, and is already there when you open it.
5. Turn on airplane mode, send a message (clock icon), turn airplane mode off: it sends and the tick changes. Repeat, closing the app while offline.
6. Chat background: lilac design, easy to read; switch the phone to dark mode and check again.
7. Calls (voice and video), feed playback, uploads, admin approval, Bible, feedback, notifications all still work.
8. If you have an old chat history: it is still there after installing over the previous version.
