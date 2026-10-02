# Account-migration endpoint — deploy notes

The Flutter app (`lib/data/migration_service.dart`) calls
`POST https://<your-worker>/migration-verify`. Until this is deployed (or if it
errors) the in-app transfer flow shows "Transfer is temporarily unavailable".

## 1. Worker

`migration_worker.js` is a **drop-in replacement for the migration section of
your existing full-replacement Worker** — replace your `// Migration helpers`
block through the end of `handleMigrationVerify(...)` with it. Keep the rest
(the `json()` helper, `dbGet`/`dbSet`/`dbPatch`, the TURN / `/send-push` /
`/send-call-push` routes, and the `if (url.pathname === "/migration-verify")
return handleMigrationVerify(request, env);` line) as-is.

### Env / secrets (must be set — `wrangler secret put ...`)

| name | value |
|---|---|
| `RELAY_SECRET` | same shared secret `/send-push` checks — must equal `_secret` in `lib/data/migration_service.dart` (currently `test-relay-secret-123`) |
| `FIREBASE_DB_URL` | `https://tonkoh-bible-truth-revea-a7694-default-rtdb.firebaseio.com` — **NEW, referenced by your `dbGet`/`dbSet`/`dbPatch`** |
| `FIREBASE_DB_SECRET` | Realtime Database access token — a **legacy DB secret** (grants admin, bypasses rules) is simplest; or a service-account OAuth token (then swap `?auth=` → `?access_token=`). **NEW.** |
| `ONESIGNAL_APP_ID` / `ONESIGNAL_REST_API_KEY` | already used by your other routes |

## 2. Firebase rules

Merge `firebase_rules_migration.json` into the database rules:
`migrationAttempts` must be `.read: true`, `.write: false` so only the Worker
(via its token) can touch the counter. Also add `migrationLog` as
`.read: false, .write: false` (the Worker's service-account token bypasses
rules) — it holds the transfer audit trail.

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
