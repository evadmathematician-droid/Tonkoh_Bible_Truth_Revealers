# Account-migration endpoint — deploy notes

The Flutter app (`lib/data/migration_service.dart`) calls
`POST https://<your-worker>/migration-verify`. Until this is deployed (or if it
errors) the in-app transfer flow shows "Transfer is temporarily unavailable".

## 0. Security update rollout (do these in order)

This release moves the Worker from a shared secret (shipped inside the app)
to Firebase ID tokens, and adds real database rules. Order matters — doing
step 4 before everyone has updated would lock old installs out of chats.

1. **Ship the new app build** (it sends `Authorization: Bearer <ID token>`
   *and* the old secret, and links each account to its login on launch).
2. **Deploy the new Worker** (`cloudflare/worker_full.js`, see section 1).
   Old and new builds both keep working.
3. **Add the admins list** in the Firebase console: Realtime Database →
   Data → add `admins/<your E.164 phone>: true` for each admin (e.g.
   `admins/+23276123456: true`). The admin screen now needs this as well as
   the PIN.
4. **Force everyone onto the new build**: in Remote Config set
   `min_version_code` to this build's version code and `force_update` to
   `true`. Wait a few days so active members open the app (that's when
   their account gets linked).
5. **Deploy the database rules**: `firebase deploy --only database`
   (test first: `firebase emulators:exec --only database --project demo-tbtr
   "node firebase_tests/database_rules.test.mjs"`).
6. **Retire the old secret**: `wrangler secret put ALLOW_LEGACY_SECRET` →
   `false` (or rotate `RELAY_SECRET`), then remove
   `WorkerApi.legacySecret` from `lib/config/worker_api.dart` in a later build.

## 1. Worker

`worker_full.js` is the complete Worker — paste the whole file
(`migration_worker.js` is superseded and kept only for history).

### Env / secrets (`wrangler secret put ...`)

| name | value |
|---|---|
| `FIREBASE_DB_URL` | `https://tonkoh-bible-truth-revea-a7694-default-rtdb.firebaseio.com` |
| `FIREBASE_CLIENT_EMAIL` / `FIREBASE_PRIVATE_KEY` | from a Firebase service-account JSON (prefer this over a legacy DB secret, which grants full admin) |
| `ONESIGNAL_APP_ID` / `ONESIGNAL_REST_API_KEY` | OneSignal |
| `TURN_TOKEN_ID` / `TURN_API_TOKEN` | Cloudflare Realtime TURN |
| `RELAY_SECRET` | legacy shared secret — only for builds older than this release |
| `ALLOW_LEGACY_SECRET` | optional; `false` turns the legacy secret off (step 6) |
| `FIREBASE_PROJECT_ID` | optional; defaults to `tonkoh-bible-truth-revea-a7694` |

## 2. Firebase rules

All rules live in `database.rules.json` at the repo root (it already
includes `migrationAttempts` read-only and `migrationLog` closed — the
Worker's service-account token bypasses rules).

## 2a. Conditional verification (presence gate)

Before asking for chat-partner codes the Worker reads
`presence/{claimedPhone}/lastSeen` (written by `PresenceManager`):

- **offline > 5 min, or no presence record** → legitimate device switch;
  commit the transfer immediately, `{ ok:true, profile, reason:"direct_transfer" }`,
  no codes. (`candidates` are ignored on this path.)
- **online within 5 min** → possible active-session hijack; the chat-partner
  verification below is required.

The escalating lockout is still checked first, as a backstop. Every commit
(direct, no-partners-confirm, or verified) is appended to
`migrationLog/{claimedPhone}/{ts}` with `oldDeviceId`, `newDeviceId`,
`verified`, `reason`, `lastSeenMs`, `offlineMs`.

## 3. Endpoint contract (what the client expects)

`POST /migration-verify` body:
`{ secret, claimedPhone, candidates: [E.164...], confirmNoPartners: bool, newDeviceId, newOneSignalId }`

The client reads only these JSON body keys (HTTP status is ignored):
`ok` (bool), `reason` (`"locked"|"mismatch"|"no_partners"|"need_n"|"bad_secret"|"unavailable"`),
`profile` (object, on `ok:true`), `required` (int, `need_n`),
`attemptsUntilLock` (int, `mismatch`), `lockedUntil` (epoch ms).

- `candidates: []` → precheck: returns `{ ok:false, reason:"need_n", required }`
  where `required` (1 or 2) is just how many partner fields the client shows —
  the user may fill one or both. Also returns `"locked"` / `"no_partners"`.
  **Not counted as a failed attempt.**
- **at least ONE** submitted number matches a real prior chat partner
  (last-9-digit match against `userChats/{claimedPhone}/*/otherUid`) → reassigns
  `users/{claimedPhone}.activeDeviceId` + `oneSignalId`, resets the counter,
  pushes "Account moved" to the old + new device, returns `{ ok:true, profile }`.
- **none** of the submitted numbers match → `failCount++`; every 3rd fail sets
  `lockedUntil = now + [1h,24h,7d]` (escalating, no auto-reset), returns
  `{ ok:false, reason:"mismatch", attemptsUntilLock, lockedUntil? }`.
- `partnerCount === 0` (no chat history at all) → `{ ok:false, reason:"no_partners" }`;
  the client shows a one-tap "Transfer anyway" confirmation and resubmits with
  `confirmNoPartners:true`, which commits directly (10-min cooldown).

## 4. Limits (by design)

- Accounts with **zero** entries under `userChats/{phone}` have no chat history
  to verify against → `reason:"no_partners"`. The app then offers a plain
  confirmation ("this transfers the account here and signs it out everywhere
  else") and retries with `confirmNoPartners:true`, which commits directly.
  A 10-minute server-side cooldown (`NO_PARTNER_COOLDOWN_MS`) between such
  transfers stops the account being bounced back and forth. The "Account moved"
  push still fires, so the previous holder is alerted.
- Message **scrollback doesn't transfer** — the new device re-syncs the chat
  list + previews from `userChats` and receives future messages, but old message
  bodies live only in each device's local DB.
- The old device only drops its session once it's online to observe the
  `users/{uid}/activeDeviceId` change (`auth_gate.dart` watches this).
