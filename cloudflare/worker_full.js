// =====================================================================
// Cloudflare Worker — FULL FILE (paste this whole thing as the worker)
// Same routes as before. DB auth uses a Firebase service-account
// (Google OAuth2 JWT Bearer flow).
//
// Updates in this version:
//   * Callers are authorised by their Firebase ID token
//     (Authorization: Bearer ...) on /send-push, /send-call-push and
//     /migration-verify. The old body `secret` is still accepted while
//     ALLOW_LEGACY_SECRET is not "false" (transition for older builds).
//   * /migration-verify moves users/{phone}/authUid + authIndex to the new
//     device's Firebase uid (database.rules.json relies on this link).
//   * migration verify: pass if AT LEAST ONE submitted number matches a
//     real prior chat partner (was: all must match). Client sends 1 or 2.
//   * up-front env-var check in /migration-verify so a missing secret
//     reports its name instead of a cryptic crash.
//   * /send-call-push: added ttl / android_ttl_seconds = 45 (a call push is
//     only relevant briefly; don't ring minutes late after the device comes
//     back online) and android_visibility = 1 (lock-screen visible). This
//     pairs with the app's re-enabled OneSignal NotificationServiceExtension,
//     which turns the call push into a full-screen incoming-call UI even
//     when the app is fully killed.
//   * /migration-verify: CONDITIONAL verification. Reads
//     presence/{claimedPhone}/lastSeen. If the account has been offline for
//     > 5 min (PRESENCE_GRACE_MS) the transfer is committed directly with no
//     chat-partner codes (legit device switch). Within 5 min the existing
//     chat-partner verification is required (active-session hijack risk).
//     The escalating lockout still applies as a backstop. Every transfer is
//     written to migrationLog/{claimedPhone}/{ts} with old/new device id,
//     whether it was verified, the reason, and the offline duration.
//     Firebase rules — also add (Worker-only, like migrationAttempts):
//       "migrationLog": { "$phone": { ".read": false, ".write": false } }
//     and make sure "presence" is readable by the Worker's token (it is,
//     via the service account).
//
// Required secrets:
//   RELAY_SECRET            legacy shared secret (transition only — see
//                           ALLOW_LEGACY_SECRET)
//   ALLOW_LEGACY_SECRET     optional; set to "false" once all installs send
//                           a Firebase ID token
//   FIREBASE_PROJECT_ID     optional; defaults to tonkoh-bible-truth-revea-a7694
//   TURN_TOKEN_ID           Cloudflare Realtime TURN key id
//   TURN_API_TOKEN          Cloudflare Realtime TURN API token
//   ONESIGNAL_APP_ID        OneSignal app id
//   ONESIGNAL_REST_API_KEY  OneSignal REST API key
//   FIREBASE_DB_URL         https://tonkoh-bible-truth-revea-a7694-default-rtdb.firebaseio.com
//   FIREBASE_CLIENT_EMAIL   from the service account JSON ("client_email")
//   FIREBASE_PRIVATE_KEY    from the service account JSON ("private_key", keep the \n)
//
// Realtime Database rules: see database.rules.json in the app repo.
// =====================================================================

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

const DEFAULT_FIREBASE_PROJECT_ID = "tonkoh-bible-truth-revea-a7694";

// =====================================================================
// Caller authentication — Firebase ID token
// The app sends `Authorization: Bearer <Firebase ID token>` (anonymous
// sign-in is enough). The token is an RS256 JWT signed by Google's
// securetoken service; verify signature, audience, issuer and expiry.
// =====================================================================

const SECURETOKEN_JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

let cachedJwks = null;
let cachedJwksExpiry = 0;

async function getSecuretokenKeys() {
  const now = Date.now();
  if (cachedJwks && cachedJwksExpiry > now) return cachedJwks;
  const res = await fetch(SECURETOKEN_JWKS_URL);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const body = await res.json();
  const maxAge = /max-age=(\d+)/.exec(res.headers.get("Cache-Control") || "");
  cachedJwks = body.keys || [];
  cachedJwksExpiry = now + (maxAge ? Number(maxAge[1]) * 1000 : 3600 * 1000);
  return cachedJwks;
}

function base64urlToBytes(s) {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeJwtPart(s) {
  return JSON.parse(new TextDecoder().decode(base64urlToBytes(s)));
}

// Returns the token's claims (`sub` is the Firebase uid) or null.
async function verifyFirebaseIdToken(request, env) {
  const header = request.headers.get("Authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) return null;
  try {
    const [h, p, sig] = match[1].split(".");
    if (!h || !p || !sig) return null;
    const head = decodeJwtPart(h);
    const claims = decodeJwtPart(p);
    if (head.alg !== "RS256" || !head.kid) return null;

    const projectId = env.FIREBASE_PROJECT_ID || DEFAULT_FIREBASE_PROJECT_ID;
    const nowSec = Math.floor(Date.now() / 1000);
    if (claims.aud !== projectId) return null;
    if (claims.iss !== `https://securetoken.google.com/${projectId}`) return null;
    if (!claims.sub || typeof claims.sub !== "string") return null;
    if (!(claims.exp > nowSec)) return null;
    if (claims.iat && claims.iat > nowSec + 300) return null;

    const jwk = (await getSecuretokenKeys()).find((k) => k.kid === head.kid);
    if (!jwk) return null;
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      base64urlToBytes(sig),
      new TextEncoder().encode(`${h}.${p}`)
    );
    return valid ? claims : null;
  } catch (_) {
    return null;
  }
}

// TRANSITION: builds released before the token change only send the shared
// `secret` in the body. Keep accepting it until every install has updated
// (force-update can push them), then set ALLOW_LEGACY_SECRET=false.
function legacySecretAllowed(env, secret) {
  return (
    env.ALLOW_LEGACY_SECRET !== "false" &&
    !!env.RELAY_SECRET &&
    secret === env.RELAY_SECRET
  );
}

// { claims } for a verified Firebase user, { legacy: true } for the old
// shared secret, or null when the caller isn't authorised.
async function authorize(request, env, secret) {
  const claims = await verifyFirebaseIdToken(request, env);
  if (claims) return { claims };
  if (legacySecretAllowed(env, secret)) return { legacy: true };
  return null;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// =====================================================================
// Google OAuth2 service-account token (JWT Bearer flow)
// Cached in-memory per Worker isolate for its lifetime (~tokens last 1h).
// =====================================================================

let cachedToken = null;
let cachedTokenExpiry = 0;

function base64url(bytes) {
  let str = btoa(String.fromCharCode(...new Uint8Array(bytes)));
  return str.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlFromString(str) {
  return base64url(new TextEncoder().encode(str));
}

function pemToArrayBuffer(pem) {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function getAccessToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedTokenExpiry - 60 > now) {
    return cachedToken;
  }

  const privateKeyPem = env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, "\n");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const header = { alg: "RS256", typ: "JWT" };
  const claimSet = {
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const unsigned = `${base64urlFromString(JSON.stringify(header))}.${base64urlFromString(JSON.stringify(claimSet))}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned)
  );
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`OAuth2 token exchange failed: ${res.status} ${errText}`);
  }

  const data = await res.json();
  cachedToken = data.access_token;
  cachedTokenExpiry = now + (data.expires_in || 3600);
  return cachedToken;
}

// =====================================================================
// Realtime Database REST helpers (now using OAuth2 access_token)
// =====================================================================

async function dbGet(env, path) {
  const token = await getAccessToken(env);
  const res = await fetch(
    `${env.FIREBASE_DB_URL}/${path}.json?access_token=${token}`
  );
  if (!res.ok) throw new Error(`RTDB GET ${path} failed: ${res.status}`);
  return res.json();
}

async function dbSet(env, path, value) {
  const token = await getAccessToken(env);
  const res = await fetch(
    `${env.FIREBASE_DB_URL}/${path}.json?access_token=${token}`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(value),
    }
  );
  if (!res.ok) throw new Error(`RTDB PUT ${path} failed: ${res.status}`);
  return res.json();
}

async function dbPatch(env, path, value) {
  const token = await getAccessToken(env);
  const res = await fetch(
    `${env.FIREBASE_DB_URL}/${path}.json?access_token=${token}`,
    {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(value),
    }
  );
  if (!res.ok) throw new Error(`RTDB PATCH ${path} failed: ${res.status}`);
  return res.json();
}

// =====================================================================
// Account migration
// Client sends: { secret, claimedPhone, candidates:[E.164...],
//   confirmNoPartners:bool, newDeviceId, newOneSignalId }
// Client reads only body keys: ok, reason, profile, required,
//   attemptsUntilLock, lockedUntil.
// =====================================================================

const LOCK_TIERS_MS = [
  60 * 60 * 1000,
  24 * 60 * 60 * 1000,
  7 * 24 * 60 * 60 * 1000,
];
const NO_PARTNER_COOLDOWN_MS = 10 * 60 * 1000;

// If the account has NOT been online within this window, a transfer to a new
// device is treated as a legitimate device switch (lost/replaced phone,
// reinstall) and committed directly — no chat-partner verification. Within
// the window it's a possible active-session hijack, so full verification is
// required. The escalating lockout still applies as a backstop either way.
const PRESENCE_GRACE_MS = 5 * 60 * 1000;

async function getLastSeenMs(env, phone) {
  try {
    const p = await dbGet(env, `presence/${phoneKey(phone)}`);
    if (!p || typeof p !== "object") return 0;
    // `lastSeen` is a ServerValue.timestamp (epoch ms) written by
    // PresenceManager on connect and by onDisconnect on drop.
    return Number(p.lastSeen) || 0;
  } catch (_) {
    return 0;
  }
}

async function logTransfer(env, phone, entry) {
  try {
    const logId = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    await dbSet(env, `migrationLog/${phoneKey(phone)}/${logId}`, {
      at: Date.now(),
      ...entry,
    });
  } catch (_) {
    // auditing is best-effort — never block a transfer on it
  }
}

function phoneKey(phone) {
  return encodeURIComponent(String(phone || "").trim());
}

function looseKey(raw) {
  if (!raw) return null;
  const digits = String(raw).replace(/\D/g, "");
  if (digits.length < 7) return null;
  return digits.slice(-9);
}

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

async function commitMigration(
  env,
  claimedPhone,
  newDeviceId,
  newOneSignalId,
  meta = {}
) {
  const key = phoneKey(claimedPhone);
  const oldProfile = (await dbGet(env, `users/${key}`)) || {};
  const oldDeviceId = oldProfile.activeDeviceId || "";

  // Move the account's login link (see database.rules.json) to the new
  // device's Firebase uid. A legacy-secret caller has no verified uid, so
  // the link is cleared instead and the new device claims it on launch
  // (AuthManager.linkAuthUid).
  await dbPatch(env, `users/${key}`, {
    activeDeviceId: newDeviceId || "",
    oneSignalId: newOneSignalId || "",
    authUid: meta.authUid || null,
    migratedAt: Date.now(),
  });
  if (oldProfile.authUid && oldProfile.authUid !== meta.authUid) {
    try {
      await dbSet(env, `authIndex/${encodeURIComponent(oldProfile.authUid)}`, null);
    } catch (_) {
      // stale index entry is harmless: the rules check both directions
    }
  }
  if (meta.authUid) {
    await dbSet(env, `authIndex/${encodeURIComponent(meta.authUid)}`, claimedPhone);
  }

  // Security audit trail: who moved this account, when, and whether chat
  // verification was required.
  await logTransfer(env, claimedPhone, {
    oldDeviceId,
    newDeviceId: newDeviceId || "",
    verified: meta.verified === true,
    reason: meta.reason || "verified",
    lastSeenMs: meta.lastSeenMs || 0,
    offlineMs: meta.offlineMs == null ? null : meta.offlineMs,
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
    return new Response("Method not allowed", {
      status: 405,
      headers: CORS_HEADERS,
    });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, reason: "bad_request" }, 400);
  }

  try {
    const missing = [
      "FIREBASE_DB_URL",
      "FIREBASE_CLIENT_EMAIL",
      "FIREBASE_PRIVATE_KEY",
      "ONESIGNAL_APP_ID",
      "ONESIGNAL_REST_API_KEY",
    ].filter((k) => !env[k]);
    if (missing.length) {
      return json(
        {
          ok: false,
          reason: "unavailable",
          detail:
            "Worker missing env var(s): " +
            missing.join(", ") +
            " — set them on this Worker and redeploy.",
        },
        200
      );
    }

    const {
      secret,
      claimedPhone,
      candidates,
      confirmNoPartners,
      newDeviceId,
      newOneSignalId,
    } = body ?? {};

    const caller = await authorize(request, env, secret);
    if (!caller) {
      return json({ ok: false, reason: "bad_secret" }, 200);
    }
    const authUid = caller.claims ? caller.claims.sub : null;
    if (!claimedPhone || !newDeviceId) {
      return json({ ok: false, reason: "bad_request" }, 400);
    }

    const cands = Array.isArray(candidates)
      ? candidates.map((s) => String(s).trim()).filter(Boolean)
      : [];
    const now = Date.now();

    const state = await getAttemptState(env, claimedPhone);
    if (state.lockedUntil && now < state.lockedUntil) {
      return json(
        { ok: false, reason: "locked", lockedUntil: state.lockedUntil },
        200
      );
    }

    // ── Conditional verification, gated on how recently the account was
    // online. Offline > 5 min  → legitimate device switch, transfer directly.
    // Online within 5 min      → possible active-session hijack, verify.
    const lastSeenMs = await getLastSeenMs(env, claimedPhone);
    const offlineMs = lastSeenMs > 0 ? now - lastSeenMs : Infinity;

    if (offlineMs > PRESENCE_GRACE_MS) {
      const profile = await commitMigration(
        env,
        claimedPhone,
        newDeviceId,
        newOneSignalId,
        {
          verified: false,
          reason: lastSeenMs > 0 ? "offline_direct" : "no_presence_direct",
          authUid,
          lastSeenMs,
          offlineMs: Number.isFinite(offlineMs) ? offlineMs : null,
        }
      );
      await clearAttempts(env, claimedPhone, state);
      return json({ ok: true, profile, reason: "direct_transfer" }, 200);
    }

    const partnerKeys = await getChatPartnerKeys(env, claimedPhone);
    const partnerCount = partnerKeys.size;

    // No chat history at all → never ask for verification numbers; a one-tap
    // "Transfer anyway" (confirmNoPartners:true) commits directly.
    if (partnerCount === 0) {
      if (confirmNoPartners !== true) {
        return json({ ok: false, reason: "no_partners" }, 200);
      }
      const prof = (await dbGet(env, `users/${phoneKey(claimedPhone)}`)) || {};
      const last = Number(prof.migratedAt) || 0;
      if (last && now - last < NO_PARTNER_COOLDOWN_MS) {
        return json(
          {
            ok: false,
            reason: "locked",
            lockedUntil: last + NO_PARTNER_COOLDOWN_MS,
          },
          200
        );
      }
      const profile = await commitMigration(
        env,
        claimedPhone,
        newDeviceId,
        newOneSignalId,
        {
          verified: false,
          reason: "no_partners_confirm",
          lastSeenMs,
          offlineMs,
          authUid,
        }
      );
      return json({ ok: true, profile }, 200);
    }

    // How many partner fields the client should show (1 or 2). The user may
    // fill one or both — passing needs only ONE submitted number to match a
    // real prior chat partner.
    const required = Math.min(2, partnerCount);

    // Precheck / nothing submitted yet.
    if (cands.length === 0) {
      return json(
        { ok: false, reason: "need_n", required, lockedUntil: null },
        200
      );
    }

    // At least ONE submitted number must be a real prior chat partner.
    const anyMatch = cands.some((c) => partnerKeys.has(looseKey(c)));
    if (!anyMatch) {
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

    await clearAttempts(env, claimedPhone, state);
    const profile = await commitMigration(
      env,
      claimedPhone,
      newDeviceId,
      newOneSignalId,
      {
        verified: true,
        reason: "chat_partner_verified",
        lastSeenMs,
        offlineMs,
        authUid,
      }
    );
    return json({ ok: true, profile }, 200);
  } catch (err) {
    return json({ ok: false, reason: "unavailable", detail: String(err) }, 200);
  }
}

// =====================================================================
// Main fetch handler (unchanged)
// =====================================================================

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    if (url.pathname === "/" || url.pathname === "/turn-credentials") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", {
          status: 405,
          headers: CORS_HEADERS,
        });
      }
      try {
        const resp = await fetch(
          `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_TOKEN_ID}/credentials/generate`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${env.TURN_API_TOKEN}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ ttl: 86400 }),
          }
        );
        if (!resp.ok) {
          const errText = await resp.text();
          return json(
            { error: "Failed to generate TURN credentials", detail: errText },
            502
          );
        }
        const data = await resp.json();
        return json(data);
      } catch (err) {
        return json({ error: "Worker exception", detail: String(err) }, 500);
      }
    }

    if (url.pathname === "/send-push") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", {
          status: 405,
          headers: CORS_HEADERS,
        });
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid_json" }, 400);
      }

      const {
        secret,
        subscriptionIds,
        oneSignalId,
        segments,
        heading,
        content,
        data,
        smallIcon,
        largeIcon,
      } = body ?? {};

      if (!(await authorize(request, env, secret))) {
        return json({ error: "unauthorized" }, 401);
      }

      const ids = subscriptionIds ?? (oneSignalId ? [oneSignalId] : []);
      const hasIds = Array.isArray(ids) && ids.length > 0;
      const hasSegments = Array.isArray(segments) && segments.length > 0;

      if (!hasIds && !hasSegments) {
        return json({ error: "missing_subscription_ids_or_segments" }, 400);
      }
      if (!heading || !content) {
        return json({ error: "missing_heading_or_content" }, 400);
      }

      const onesignalBody = {
        app_id: env.ONESIGNAL_APP_ID,
        content_available: true,
        priority: 10,
        headings: { en: heading },
        contents: { en: content },
        data: data ?? {},
      };

      if (hasIds) {
        onesignalBody.include_subscription_ids = ids;
      } else {
        onesignalBody.included_segments = segments;
      }

      if (smallIcon) onesignalBody.small_icon = smallIcon;
      if (largeIcon) onesignalBody.large_icon = largeIcon;

      const onesignalRes = await fetch(
        "https://api.onesignal.com/notifications",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Key ${env.ONESIGNAL_REST_API_KEY}`,
          },
          body: JSON.stringify(onesignalBody),
        }
      );

      if (!onesignalRes.ok) {
        const errText = await onesignalRes.text();
        return json({ error: "onesignal_failed", detail: errText }, 502);
      }
      return json({ ok: true });
    }

    if (url.pathname === "/send-call-push") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", {
          status: 405,
          headers: CORS_HEADERS,
        });
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid_json" }, 400);
      }
      const {
        secret,
        oneSignalId,
        callId,
        callerId,
        callerName,
        callerPhoto,
        callType,
        chatId,
      } = body ?? {};

      if (!(await authorize(request, env, secret))) {
        return json({ error: "unauthorized" }, 401);
      }
      if (!oneSignalId || !callId || !callerId) {
        return json({ error: "missing_fields" }, 400);
      }

      const onesignalRes = await fetch(
        "https://api.onesignal.com/notifications",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Key ${env.ONESIGNAL_REST_API_KEY}`,
          },
          body: JSON.stringify({
            app_id: env.ONESIGNAL_APP_ID,
            include_subscription_ids: [oneSignalId],
            content_available: true,
            priority: 10,
            // FCM: deliver even in Doze, and don't ring minutes late if the
            // device was offline — a call is only relevant for ~45s.
            android_ttl_seconds: 45,
            ttl: 45,
            // Show on the lock screen (the native extension re-posts its own
            // full-screen notification, but this keeps OneSignal's own
            // delivery lock-screen-visible as a fallback).
            android_visibility: 1,
            headings: { en: `Incoming ${callType || "voice"} call` },
            contents: { en: `${callerName || "Someone"} is calling you` },
            data: {
              type: "incoming_call",
              callId,
              callerId,
              callerName,
              callType,
              chatId,
            },
          }),
        }
      );

      if (!onesignalRes.ok) {
        const errText = await onesignalRes.text();
        return json({ error: "onesignal_failed", detail: errText }, 502);
      }
      return json({ ok: true });
    }

    if (url.pathname === "/migration-verify") {
      return handleMigrationVerify(request, env);
    }

    return new Response("Not found", { status: 404, headers: CORS_HEADERS });
  },
};
