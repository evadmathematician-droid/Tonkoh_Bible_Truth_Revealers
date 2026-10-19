# Phone number audit

Every place the app creates, saves, compares or displays a phone number.
**One rule:** accounts are keyed by strict E.164 (`+23231932652`). Numbers are
normalized only by `lib/util/phone_utils.dart`. tools/fix_phone_numbers.js
uses the same rules (libphonenumber-js) to repair server data.

| Helper | What it does |
|---|---|
| `normalizePhone(input, {defaultCountry = 'SL'})` | Typed or phone-book input → E.164, or null when invalid |
| `repairStoredPhone(stored)` | Stored data → E.164; also fixes a wrong country guess (`+44034909376` → `+23234909376`) |
| `canonicalUserId(id)` | Account id from old data → repaired E.164 (non-phone legacy ids unchanged) |
| `resolveUserId(id)` (`lib/data/phone_aliases.dart`) | `phoneAliases/{old}` from the server, otherwise `canonicalUserId` |
| `formatPhoneForDisplay(value)` | E.164 → `+232 31 932 652` (re-exported by `display_names.dart`) |
| `loosePhoneKey(phone)` | Last-9-digit key, only for collapsing duplicate chat rows |

## Where numbers are created (user input)

| Place | Before | Now |
|---|---|---|
| `screens/profile/profile_setup_screen.dart`, registration | `intl_phone_field`, with the country preselected from the **phone locale**. A UK-locale phone turned `034909376` into `+44034909376` | `PhoneNumberField`: country picker defaulting to Sierra Leone, any input format accepted, live "Your number: +232 …" preview. Only E.164 is saved |
| `screens/profile/edit_profile_screen.dart` | Free-text phone plus a free-text 2-letter country code, saved as typed | `PhoneNumberField`. Changing to a different number asks for confirmation, because the number is the account key |
| `screens/auth/auth_manager.dart` `saveProfile` | `normalizePhone(phone, iso)` (old helper) | `normalizePhone(phone, defaultCountry: iso)`. Country is taken from the number itself |
| `screens/profile/account_migration_screen.dart`, chat-partner numbers | old helper | `normalizePhone(…, defaultCountry:)` |
| `data/feedback_repository.dart`, feedback phone | saved as typed (`079150079`) | E.164 when valid, otherwise as typed |
| `data/contacts_repository.dart`, phone-book numbers | per-region guessing + last-9/8-digit keys | `normalizePhone` with the user's own country (default SL), exact E.164 lookup (Phase 3) |

## Where numbers are stored (Firebase)

All of these are written from the cached profile (`uid` = `phone` = E.164) or
from another user's id. They are correct as long as the profile is correct,
which registration, the self-repair and the data fix now guarantee.

| Node | Phone field(s) | Written by |
|---|---|---|
| `users/{phone}` | key, `uid`, `phone`, `country` | `AuthManager.saveProfile`, `AccountSelfRepair`, Worker `/migration-verify` |
| `authIndex/{authUid}` | value | `AuthManager._writeAuthIndex`, Worker |
| `presence/{phone}` | key | `PresenceManager` |
| `userChats/{phone}/{chatId}` | key, chat id, `otherUid` | `private_chat_screen`, `share_sender`, `missed_call` |
| `privateChats/{a_b}/messages/*` | chat id, `senderId`, `senderPhone` | `private_chat_screen`, `share_sender`, `missed_call` |
| `calls/{callId}` | `callerId`, `calleeId` | `call_initiator`, `call_signaling_repository`, native `CallSignaling.kt` |
| `sermons/{pending,approved,rejected}/*` | `senderId`, `senderPhone` | `upload_sheet`, admin approval (copies the record) |
| `textMessages/*` | `senderId`, `senderPhone` | `audio_feed_provider` |
| `feedback/*` | `phone` | `feedback_repository` |
| `migrationAttempts/{phone}`, `migrationLog/{phone}` | key | Worker only |
| `phoneAliases/{oldKey}` *(new)* | key and value | `tools/fix_phone_numbers.js`, `AccountSelfRepair` |
| `phoneIndex/{phone}` | key → legacy auth uid | old app versions only; the current app never reads it (see PHONE_CHAT_FIX.md) |

## Where numbers are compared or used as ids

| Place | Now |
|---|---|
| `screens/chat/chat_helpers.dart` `privateChatId(a, b)` | sorted `a_b`. Both ids are E.164 (the other id is resolved first) |
| `screens/chat/private_chat_screen.dart` | `_otherUid = resolveUserId(widget.otherUid)` |
| `screens/audio/audio_feed_list.dart`, post sender | `resolveUserId(senderId)` for the name, photo and chat link |
| `calls/start_call.dart` | `resolveUserId(calleeUid)` |
| `data/display_names.dart` `resolveDisplayName` | looks up the id and its resolved form |
| `data/chat_summary.dart` `dedupeByPerson` | `loosePhoneKey`, only to merge legacy duplicate rows |
| `navigation/auth_gate.dart` | runs `AccountSelfRepair` after sign-in, and when the account record disappears (moved by the data fix) |
| `data/local_chat_store.dart` `renameUser` | re-keys local history when the account id is repaired |
| `cloudflare/worker_full.js` `/migration-verify` | `claimedPhone` and candidates resolved through `phoneAliases` (needs a Worker redeploy) |

## Where numbers are displayed

| Place | Now |
|---|---|
| Names everywhere (`DisplayNames.nameFor`) | saved contact name, otherwise `formatPhoneForDisplay` |
| `components/contact_action_sheet.dart`, `components/contact_row.dart` | `formatPhoneForDisplay` |
| `share/share_target_screen.dart` | `formatPhoneForDisplay` |
| `screens/chat/private_chat_screen.dart`, profile sheet | `formatPhoneForDisplay` |
| Avatars (`ProfileAvatar`, chat `AvatarView`) | initials only from letters, otherwise a person icon (never "+") |
| Native notifications (`ContactDisplayNames.kt`) | saved name, otherwise `+232 31 932 652` grouping |
