// =====================================================================
// DROP-IN REPLACEMENT for the migration section of your Worker.
//
// In your "full replacement" Worker, replace EVERYTHING from
//   // ===  Migration helpers  ===
// down through the end of  async function handleMigrationVerify(...)  { ... }
// with the code below. Keep the rest of the file (CORS_HEADERS, json(),
// dbGet/dbSet/dbPatch, the TURN + /send-push + /send-call-push routes, and
// the `if (url.pathname === "/migration-verify") return handleMigrationVerify(...)`
// line in the main fetch handler) exactly as you have it.
//
// Why the change: the Flutter client (lib/data/migration_service.dart) sends
//   { secret, claimedPhone, candidates:[...], confirmNoPartners:bool,
//     newDeviceId, newOneSignalId }
// and only looks at the JSON body keys `ok` / `reason` / `profile` /
// `required` / `attemptsUntilLock` / `lockedUntil`. Your version read
// `contactNumbers`, required 1–2 always (no precheck), returned
// `{verified,migrated}` (no `ok`/`profile`), used a wrong chat-history path,
// and had no zero-partner path — so the app treated every response as
// "unavailable".
// =====================================================================

// Escalating lockout: every 3rd failed attempt -> 1h, then 24h, then 7d.
const LOCK_TIERS_MS = [
  60 * 60 * 1000,          // 1 hour
  24 * 60 * 60 * 1000,     // 24 hours
  7 * 24 * 60 * 60 * 1000, // 7 days
];
// Min gap between confirmation-only (zero-chat-partner) transfers, so an
// account can't be bounced back and forth.
const NO_PARTNER_COOLDOWN_MS = 10 * 60 * 1000;

// RTDB keys in this project are the raw E.164 (the app writes
// `users/+23276...`, `userChats/+23276...`). Encode for the REST path.
function phoneKey(phone) {
  return encodeURIComponent(String(phone || "").trim());
}

// Last 9 significant digits — tolerant of +/space/format differences
// between what the claimant types and what's stored as `otherUid`.
function looseKey(raw) {
  if (!raw) return null;
  const digits = String(raw).replace(/\D/g, "");
  if (digits.length < 7) return null;
  return digits.slice(-9);
}

// The account's real prior chat partners: userChats/{owner}/{chatId}.otherUid
// (written for both parties by _writeChatSummaries in private_chat_screen.dart).
async function getChatPartnerKeys(env, ownerPhone) {
  const chats = await dbGet(env, `userChats/${phoneKey(ownerPhone)}`);
  const keys = new Set();
  if (chats && typeof chats === "object") {
    for (const chatId of Object.keys(chats)) {
      const k = looseKey(chats[chatId] && chats[chatId].otherUid);
      if (k) keys.add(k);
    }
  }
  return keys;
}

async function getAttemptState(env, claimedPhone) {
  const s = await dbGet(env, `migrationAttempts/${phoneKey(claimedPhone)}`);
  return s || { failCount: 0, lockTier: 0, lockedUntil: 0 };
}

async function recordFailure(env, claimedPhone, state) {
  const failCount = (state.failCount || 0) + 1;
  let lockTier = state.lockTier || 0;
  let lockedUntil = state.lockedUntil || 0;
  if (failCount % 3 === 0) {
    lockedUntil =
      Date.now() + LOCK_TIERS_MS[Math.min(lockTier, LOCK_TIERS_MS.length - 1)];
    lockTier += 1;
  }
  await dbSet(env, `migrationAttempts/${phoneKey(claimedPhone)}`, {
    failCount,
    lockTier,
    lockedUntil,
    updatedAt: Date.now(),
  });
  return { failCount, lockTier, lockedUntil };
}

async function clearAttempts(env, claimedPhone, state) {
  await dbSet(env, `migrationAttempts/${phoneKey(claimedPhone)}`, {
    failCount: 0,
    lockTier: (state && state.lockTier) || 0,
    lockedUntil: 0,
    updatedAt: Date.now(),
  });
}

// Reassign users/{key} to the new device (activeDeviceId change is what
// signs every other device out — auth_gate.dart watches it), and push the
// "Account moved" security alert to the old + new device.
async function commitMigration(env, claimedPhone, newDeviceId, newOneSignalId) {
  const key = phoneKey(claimedPhone);
  const oldProfile = (await dbGet(env, `users/${key}`)) || {};

  await dbPatch(env, `users/${key}`, {
    activeDeviceId: newDeviceId || "",
    oneSignalId: newOneSignalId || "",
    migratedAt: Date.now(),
  });

  const targets = [oldProfile.oneSignalId, newOneSignalId].filter(Boolean);
  if (targets.length) {
    await fetch("https://api.onesignal.com/notifications", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Key ${env.ONESIGNAL_REST_API_KEY}`,
      },
      body: JSON.stringify({
        app_id: env.ONESIGNAL_APP_ID,
        include_subscription_ids: targets,
        content_available: true,
        priority: 10,
        headings: { en: "Account moved" },
        contents: {
          en: "Your account was just transferred to a new device. If this wasn't you, contact support immediately.",
        },
        data: { type: "account_migrated", phone: claimedPhone },
      }),
    });
  }

  return (await dbGet(env, `users/${key}`)) || {};
}

async function handleMigrationVerify(request, env) {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, reason: "bad_request" }, 400);
  }

  try {
    const {
      secret,
      claimedPhone,
      candidates,
      confirmNoPartners,
      newDeviceId,
      newOneSignalId,
    } = body ?? {};

    if (secret !== env.RELAY_SECRET) {
      return json({ ok: false, reason: "bad_secret" }, 200);
    }
    if (!claimedPhone || !newDeviceId) {
      return json({ ok: false, reason: "bad_request" }, 400);
    }

    const cands = Array.isArray(candidates)
      ? candidates.map((s) => String(s).trim()).filter(Boolean)
      : [];
    const now = Date.now();

    // 1) lockout
    const state = await getAttemptState(env, claimedPhone);
    if (state.lockedUntil && now < state.lockedUntil) {
      return json({ ok: false, reason: "locked", lockedUntil: state.lockedUntil }, 200);
    }

    // 2) this account's real chat partners
    const partnerKeys = await getChatPartnerKeys(env, claimedPhone);
    const partnerCount = partnerKeys.size;

    // 2a) zero partners -> nothing to verify against -> confirmation-only transfer
    if (partnerCount === 0) {
      if (confirmNoPartners !== true) {
        return json({ ok: false, reason: "no_partners" }, 200);
      }
      const prof = (await dbGet(env, `users/${phoneKey(claimedPhone)}`)) || {};
      const last = Number(prof.migratedAt) || 0;
      if (last && now - last < NO_PARTNER_COOLDOWN_MS) {
        return json(
          { ok: false, reason: "locked", lockedUntil: last + NO_PARTNER_COOLDOWN_MS },
          200
        );
      }
      const profile = await commitMigration(env, claimedPhone, newDeviceId, newOneSignalId);
      return json({ ok: true, profile }, 200);
    }

    const required = Math.min(2, partnerCount);

    // 3) precheck / wrong count -> NOT a failed attempt
    if (cands.length !== required) {
      return json({ ok: false, reason: "need_n", required, lockedUntil: null }, 200);
    }

    // 4) verify every submitted number is a real prior partner
    const allMatch = cands.every((c) => partnerKeys.has(looseKey(c)));
    if (!allMatch) {
      const r = await recordFailure(env, claimedPhone, state);
      return json(
        {
          ok: false,
          reason: "mismatch",
          attemptsUntilLock: (3 - (r.failCount % 3)) % 3,
          lockedUntil: r.lockedUntil || null,
        },
        200
      );
    }

    // 5) success — reset counter, reassign, notify
    await clearAttempts(env, claimedPhone, state);
    const profile = await commitMigration(env, claimedPhone, newDeviceId, newOneSignalId);
    return json({ ok: true, profile }, 200);
  } catch (err) {
    return json({ ok: false, reason: "unavailable", detail: String(err) }, 200);
  }
}
