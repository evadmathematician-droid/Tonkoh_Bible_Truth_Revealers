#!/usr/bin/env node
/*
 * Repairs malformed phone numbers in the T.B.T.R Realtime Database.
 *
 *   node tools/fix_phone_numbers.js                 # dry run (default)
 *   node tools/fix_phone_numbers.js --apply         # write the fix
 *
 * Options
 *   --project <id>      Firebase project (default: tonkoh-bible-truth-revea-a7694)
 *   --account <email>   firebase-tools login to use (see `firebase login:list`)
 *   --from <file.json>  plan against an export instead of the live database
 *                       (dry run only)
 *   --credentials <sa.json>  use the Firebase Admin SDK with a service-account
 *                       key instead of the firebase CLI (needs
 *                       `npm i firebase-admin` in tools/)
 *
 * Accounts are keyed by strict E.164 (+23231932652). Older app versions
 * saved some numbers wrongly ("+031932652", "+44034909376" for a Sierra
 * Leone number on a UK-locale phone, bare "079150079" in feedback). The
 * rules below mirror lib/util/phone_utils.dart (normalizePhone /
 * repairStoredPhone) — keep the two in step.
 *
 * What it does
 *   * account keys (users, presence, userChats, phoneIndex,
 *     migrationAttempts, migrationLog) are moved to the E.164 key;
 *   * chat ids (privateChats/{a_b}, userChats/{owner}/{a_b}, calls chatId)
 *     are recomputed from the repaired ids, so conversations stay together;
 *   * named phone fields (uid, phone, senderId, senderPhone, otherUid,
 *     callerId, calleeId, feedback phone, authIndex values) are repaired;
 *   * when the wrong key and the correct key both exist the two are MERGED:
 *     every chat message / summary is kept, newest profile fields win;
 *     each merge is logged. Two accounts claimed by two different devices
 *     are NOT merged automatically — they are reported and the run refuses
 *     to apply until a person decides;
 *   * phoneAliases/{oldKey} = E.164 is written for every moved id.
 *
 * All changes go out as ONE multi-path update, which the Realtime Database
 * applies atomically (copy and delete happen together, nothing half-moved).
 * After --apply the database is read back and re-planned: the run only
 * reports success if nothing is left to fix. Running it again changes
 * nothing (idempotent).
 *
 * Legacy records from the very first app version (keyed by anonymous-auth
 * uids, with minified field names a, b, c…) are left untouched: their
 * fields can't be told apart from free text.
 *
 * Every run writes backups/phone_fix_report.json; --apply also writes the
 * exact patch (backups/phone_fix_patch_<time>.json) and a fresh export of
 * the database taken just before writing.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { parsePhoneNumberFromString } = require('libphonenumber-js/max');

const DEFAULT_PROJECT = 'tonkoh-bible-truth-revea-a7694';
const DEFAULT_COUNTRY = 'SL';
const PRIORITY_COUNTRIES = ['SL', 'GN', 'LR', 'GH', 'NG'];
const BACKUP_DIR = path.join(__dirname, '..', 'backups');

// ── phone rules (mirror of lib/util/phone_utils.dart) ─────────────────────

function parse(text, country) {
  try {
    return parsePhoneNumberFromString(text, country) || null;
  } catch (_) {
    return null;
  }
}

function national(digits, country) {
  const p = parse(digits, country);
  if (!p) return null;
  if (p.isValid()) return p.number;
  if (p.country === country && p.isPossible() && !p.nationalNumber.startsWith('0')) {
    return p.number;
  }
  return null;
}

function international(digits, strict) {
  if (!digits || digits.startsWith('0')) return null;
  const p = parse('+' + digits);
  if (!p) return null;
  if (p.isValid() || (!strict && p.isPossible() && !p.nationalNumber.startsWith('0'))) {
    return p.number;
  }
  if (p.nationalNumber.startsWith('0')) {
    const q = parse('+' + p.countryCallingCode + p.nationalNumber.slice(1));
    if (q && q.isValid()) return q.number;
  }
  return null;
}

function normalizePhone(input, defaultCountry = DEFAULT_COUNTRY) {
  const trimmed = String(input || '').trim();
  if (!trimmed) return null;
  const hasPlus = trimmed.startsWith('+') || trimmed.startsWith('＋');
  const digits = trimmed.replace(/\D/g, '');
  if (digits.length < 6 || digits.length > 17) return null;
  if (digits.startsWith('00')) return international(digits.slice(2), false);
  if (hasPlus) {
    if (digits.startsWith('0')) return national(digits, defaultCountry);
    return international(digits, false);
  }
  return national(digits, defaultCountry) || international(digits, true);
}

function repairStoredPhone(stored, defaultCountry = DEFAULT_COUNTRY) {
  const direct = normalizePhone(stored, defaultCountry);
  if (direct) return direct;
  const s = String(stored || '').trim();
  const digits = s.replace(/\D/g, '');
  if (!s.startsWith('+') || digits.length < 8) return null;
  // A wrong country guess left the trunk 0 after the country code
  // ("+44034909376"). libphonenumber-js may keep or drop that 0 itself, so
  // take the national part straight from the digits after the code.
  const p = parse('+' + digits);
  const cc = p ? p.countryCallingCode : null;
  if (!cc || !digits.startsWith(cc)) return null;
  const nsn = digits.slice(cc.length);
  if (!nsn.startsWith('0')) return null;
  for (const country of new Set([defaultCountry, ...PRIORITY_COUNTRIES])) {
    const q = parse(nsn, country);
    if (q && q.isValid()) return q.number;
  }
  return null;
}

const looksLikePhone = (v) =>
  typeof v === 'string' && /^\+?[\d\s\-().]{6,22}$/.test(v.trim());

const countryOf = (e164) => {
  const p = parse(e164);
  return p ? p.country || null : null;
};

// ── planning ──────────────────────────────────────────────────────────────

const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

class Planner {
  constructor(db) {
    this.before = db || {};
    this.after = clone(this.before);
    this.changes = []; // { path, from, to, why }
    this.moves = []; // { node, from, to }
    this.merges = []; // { node, from, to, detail }
    this.conflicts = []; // need a person
    this.unresolved = new Map(); // value -> [paths]
    this.aliases = {}; // oldKey -> e164
  }

  /** Repaired id for a stored phone id, or the value unchanged. */
  canon(value, where) {
    if (!looksLikePhone(value)) return value;
    const fixed = repairStoredPhone(value);
    if (!fixed) {
      const list = this.unresolved.get(value) || [];
      if (list.length < 5) list.push(where);
      this.unresolved.set(value, list);
      return value;
    }
    // Aliases only for malformed "+…" ids — the shape of an account key. A
    // bare national number ("079150079") is never used as an id.
    if (fixed !== value && value.trim().startsWith('+')) this.aliases[value] = fixed;
    return fixed;
  }

  canonCid(cid, where) {
    const parts = String(cid).split('_');
    if (parts.length !== 2) return cid;
    // Only ids made of phone numbers; anonymous-uid chats are legacy.
    if (!parts.every(looksLikePhone)) return cid;
    return parts.map((p) => this.canon(p, where)).sort().join('_');
  }

  fixField(obj, field, where) {
    if (!isObj(obj) || typeof obj[field] !== 'string') return;
    const fixed = this.canon(obj[field], `${where}/${field}`);
    if (fixed !== obj[field]) {
      this.changes.push({ path: `${where}/${field}`, from: obj[field], to: fixed });
      obj[field] = fixed;
    }
  }

  /**
   * Re-keys the children of `parent` (an object) with `keyFn`. When two old
   * keys land on one new key, or the new key already exists, `mergeFn`
   * combines them.
   */
  rekey(parent, node, keyFn, mergeFn) {
    if (!isObj(parent)) return parent;
    const out = {};
    const source = {}; // target key -> original key it came from
    for (const [key, value] of Object.entries(parent)) {
      const target = keyFn(key);
      if (target !== key) this.moves.push({ node, from: key, to: target });
      if (!Object.prototype.hasOwnProperty.call(out, target)) {
        out[target] = value;
        source[target] = key;
        continue;
      }
      // Collision: "a" is the record that was already under the correct
      // key (if either was), "b" the one being folded into it.
      const [a, b, fromKey] = key === target
        ? [value, out[target], source[target]]
        : [out[target], value, key];
      out[target] = mergeFn(a, b, `${node}/${target}`, fromKey);
      source[target] = target;
    }
    return out;
  }

  plan() {
    const db = this.after;

    // users/{phone}: key + uid/phone/country. Non-phone legacy keys untouched.
    if (isObj(db.users)) {
      const presence = isObj(this.before.presence) ? this.before.presence : {};
      db.users = this.rekey(
        db.users,
        'users',
        (k) => (looksLikePhone(k) ? this.canon(k, `users/${k}`) : k),
        (a, b, where, fromKey) => this.mergeUsers(a, b, where, fromKey, presence),
      );
      for (const [k, rec] of Object.entries(db.users)) {
        if (!looksLikePhone(k) || !isObj(rec)) continue;
        if (repairStoredPhone(k) !== k) continue; // unresolvable key, leave
        for (const f of ['uid', 'phone']) {
          if (rec[f] !== undefined && rec[f] !== k) {
            this.changes.push({ path: `users/${k}/${f}`, from: rec[f], to: k });
            rec[f] = k;
          }
        }
        const c = countryOf(k);
        if (rec.uid !== undefined && c && rec.country !== c && this.isMoved('users', k)) {
          this.changes.push({ path: `users/${k}/country`, from: rec.country, to: c });
          rec.country = c;
        }
      }
    }

    // presence/{phone}: keep the most recent lastSeen.
    if (isObj(db.presence)) {
      db.presence = this.rekey(db.presence, 'presence',
        (k) => (looksLikePhone(k) ? this.canon(k, `presence/${k}`) : k),
        (a, b, where, fromKey) => {
          const pick = (b && b.lastSeen || 0) > (a && a.lastSeen || 0) ? b : a;
          this.merges.push({ node: where, from: fromKey, detail: 'kept most recent presence' });
          return pick;
        });
    }

    // userChats/{owner}/{a_b}: owner key, chat ids, otherUid.
    if (isObj(db.userChats)) {
      db.userChats = this.rekey(db.userChats, 'userChats',
        (k) => (looksLikePhone(k) ? this.canon(k, `userChats/${k}`) : k),
        (a, b, where, fromKey) => {
          this.merges.push({ node: where, from: fromKey, detail: 'chat lists combined' });
          return Object.assign({}, b, a);
        });
      for (const [owner, chats] of Object.entries(db.userChats)) {
        if (!isObj(chats)) continue;
        db.userChats[owner] = this.rekey(chats, `userChats/${owner}`,
          (cid) => this.canonCid(cid, `userChats/${owner}/${cid}`),
          (a, b, where, fromKey) => this.mergeSummaries(a, b, where, fromKey));
        for (const [cid, s] of Object.entries(db.userChats[owner])) {
          this.fixField(s, 'otherUid', `userChats/${owner}/${cid}`);
        }
      }
    }

    // privateChats/{a_b}/messages: chat ids + sender fields; merges keep
    // every message.
    if (isObj(db.privateChats)) {
      db.privateChats = this.rekey(db.privateChats, 'privateChats',
        (cid) => this.canonCid(cid, `privateChats/${cid}`),
        (a, b, where, fromKey) => {
          const merged = Object.assign({}, b, a);
          merged.messages = Object.assign({}, (b && b.messages) || {}, (a && a.messages) || {});
          this.merges.push({
            node: where, from: fromKey,
            detail: `messages combined (${Object.keys(merged.messages).length})`,
          });
          return merged;
        });
      for (const [cid, chat] of Object.entries(db.privateChats)) {
        if (!isObj(chat) || !isObj(chat.messages)) continue;
        if (!cid.split('_').every(looksLikePhone)) continue; // legacy chat
        for (const [mid, m] of Object.entries(chat.messages)) {
          this.fixField(m, 'senderId', `privateChats/${cid}/messages/${mid}`);
          this.fixField(m, 'senderPhone', `privateChats/${cid}/messages/${mid}`);
        }
      }
    }

    // calls/{id}: caller / callee / chat id.
    if (isObj(db.calls)) {
      for (const [id, c] of Object.entries(db.calls)) {
        this.fixField(c, 'callerId', `calls/${id}`);
        this.fixField(c, 'calleeId', `calls/${id}`);
        if (isObj(c) && typeof c.chatId === 'string') {
          const fixed = this.canonCid(c.chatId, `calls/${id}/chatId`);
          if (fixed !== c.chatId) {
            this.changes.push({ path: `calls/${id}/chatId`, from: c.chatId, to: fixed });
            c.chatId = fixed;
          }
        }
      }
    }

    // sermons/{status}/{id} (and any loose sermon at sermons/{id}).
    if (isObj(db.sermons)) {
      for (const [k, v] of Object.entries(db.sermons)) {
        const group = ['pending', 'approved', 'rejected'].includes(k) ? v : { [k]: v };
        const base = ['pending', 'approved', 'rejected'].includes(k) ? `sermons/${k}` : 'sermons';
        if (!isObj(group)) continue;
        for (const [id, s] of Object.entries(group)) {
          this.fixField(s, 'senderId', `${base}/${id}`);
          this.fixField(s, 'senderPhone', `${base}/${id}`);
        }
      }
    }

    for (const [node, fields] of [['textMessages', ['senderId', 'senderPhone']], ['feedback', ['phone']]]) {
      if (!isObj(db[node])) continue;
      for (const [id, rec] of Object.entries(db[node])) {
        for (const f of fields) this.fixField(rec, f, `${node}/${id}`);
      }
    }

    if (isObj(db.authIndex)) {
      for (const [authUid, phone] of Object.entries(db.authIndex)) {
        if (typeof phone !== 'string') continue;
        const fixed = this.canon(phone, `authIndex/${authUid}`);
        if (fixed !== phone) {
          this.changes.push({ path: `authIndex/${authUid}`, from: phone, to: fixed });
          db.authIndex[authUid] = fixed;
        }
      }
    }

    // Keyed-by-phone bookkeeping: keep every entry, under the right key.
    for (const node of ['phoneIndex', 'migrationAttempts', 'migrationLog']) {
      if (!isObj(db[node])) continue;
      db[node] = this.rekey(db[node], node,
        (k) => (looksLikePhone(k) ? this.canon(k, `${node}/${k}`) : k),
        (a, b, where, fromKey) => {
          this.merges.push({ node: where, from: fromKey, detail: 'entries combined' });
          return isObj(a) && isObj(b) ? Object.assign({}, b, a) : a;
        });
    }

    // Alias table for every id that moved (never overwrite an existing one).
    const existing = isObj(this.before.phoneAliases) ? this.before.phoneAliases : {};
    db.phoneAliases = Object.assign({}, existing);
    for (const [oldKey, e164] of Object.entries(this.aliases)) {
      if (!isValidRtdbKey(oldKey)) continue;
      if (db.phoneAliases[oldKey] === undefined) db.phoneAliases[oldKey] = e164;
    }
    if (Object.keys(db.phoneAliases).length === 0) delete db.phoneAliases;

    return this;
  }

  isMoved(node, key) {
    return this.moves.some((m) => m.node === node && m.to === key);
  }

  mergeUsers(a, b, where, fromKey, presence) {
    // a = record under the correct key (or first seen), b = the other.
    const devA = isObj(a) ? a.activeDeviceId || '' : '';
    const devB = isObj(b) ? b.activeDeviceId || '' : '';
    if (devA && devB && devA !== devB) {
      this.conflicts.push({
        node: where, from: fromKey,
        reason: 'two accounts for one number are active on different devices',
      });
    }
    const target = where.split('/').pop();
    const seenA = ((presence[target] || {}).lastSeen) || 0;
    const seenB = ((presence[fromKey] || {}).lastSeen) || 0;
    const [older, newer] = seenB > seenA ? [a, b] : [b, a];
    const merged = Object.assign({}, older, newer);
    const created = [a && a.createdAt, b && b.createdAt].filter((x) => typeof x === 'number');
    if (created.length) merged.createdAt = Math.min(...created);
    this.merges.push({ node: where, from: fromKey, detail: 'profile merged, newest fields kept' });
    return merged;
  }

  mergeSummaries(a, b, where, fromKey) {
    const ta = (a && a.lastTimestamp) || 0;
    const tb = (b && b.lastTimestamp) || 0;
    const merged = Object.assign({}, ta >= tb ? b : a, ta >= tb ? a : b);
    merged.unread = Math.max((a && a.unread) || 0, (b && b.unread) || 0);
    merged.lastReadTimestamp = Math.max((a && a.lastReadTimestamp) || 0, (b && b.lastReadTimestamp) || 0);
    this.merges.push({ node: where, from: fromKey, detail: 'chat summaries merged' });
    return merged;
  }

  /** Minimal multi-path update turning `before` into `after`. */
  patch() {
    const out = {};
    const walk = (a, b, p) => {
      if (isObj(a) && isObj(b)) {
        for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
          walk(a[k], b[k], p ? `${p}/${k}` : k);
        }
        return;
      }
      if (JSON.stringify(a) === JSON.stringify(b)) return;
      out[p] = b === undefined ? null : b;
    };
    walk(this.before, this.after, '');
    return out;
  }
}

function isValidRtdbKey(k) {
  return typeof k === 'string' && k.length > 0 && !/[.#$\[\]\/]/.test(k);
}

// ── database access ───────────────────────────────────────────────────────

function args(argv) {
  const a = { apply: false, project: DEFAULT_PROJECT, account: null, from: null, credentials: null };
  for (let i = 2; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--apply') a.apply = true;
    else if (v === '--dry-run') a.apply = false;
    else if (['--project', '--account', '--from', '--credentials'].includes(v)) a[v.slice(2)] = argv[++i];
    else throw new Error(`unknown option ${v}`);
  }
  return a;
}

function firebase(a, cliArgs) {
  const extra = ['--project', a.project, ...(a.account ? ['--account', a.account] : [])];
  // Git Bash rewrites a bare "/" argument into a Windows path.
  const env = Object.assign({}, process.env, { MSYS_NO_PATHCONV: '1' });
  return execFileSync('firebase', [...cliArgs, ...extra], {
    env, stdio: ['ignore', 'pipe', 'pipe'], shell: process.platform === 'win32',
    maxBuffer: 1024 * 1024 * 512,
  }).toString();
}

let adminDb = null;
function admin(a) {
  if (adminDb) return adminDb;
  const sdk = require('firebase-admin');
  sdk.initializeApp({
    credential: sdk.credential.cert(require(path.resolve(a.credentials))),
    databaseURL: `https://${a.project}-default-rtdb.firebaseio.com`,
  });
  adminDb = sdk.database();
  return adminDb;
}

async function readDatabase(a, saveTo) {
  if (a.from) return JSON.parse(fs.readFileSync(a.from, 'utf8'));
  if (a.credentials) {
    const v = (await admin(a).ref('/').once('value')).val() || {};
    if (saveTo) fs.writeFileSync(saveTo, JSON.stringify(v));
    return v;
  }
  const file = saveTo || path.join(os.tmpdir(), `rtdb_${Date.now()}.json`);
  firebase(a, ['database:get', '/', '--output', file]);
  const v = JSON.parse(fs.readFileSync(file, 'utf8') || 'null') || {};
  if (!saveTo) fs.unlinkSync(file);
  return v;
}

async function writePatch(a, patch, file) {
  if (a.credentials) return admin(a).ref('/').update(patch);
  firebase(a, ['database:update', '/', file, '--force']);
}

// ── main ──────────────────────────────────────────────────────────────────

function summarize(p, patch) {
  return {
    generatedAt: new Date().toISOString(),
    movedKeys: p.moves,
    fieldChanges: p.changes,
    merges: p.merges,
    conflicts: p.conflicts,
    aliases: p.aliases,
    unresolved: [...p.unresolved.entries()].map(([value, paths]) => ({ value, paths })),
    patchPaths: Object.keys(patch).length,
  };
}

function print(report) {
  console.log(`Moved keys:     ${report.movedKeys.length}`);
  for (const m of report.movedKeys) console.log(`  ${m.node}: ${m.from} → ${m.to}`);
  console.log(`Field changes:  ${report.fieldChanges.length}`);
  for (const c of report.fieldChanges) console.log(`  ${c.path}: ${c.from} → ${c.to}`);
  console.log(`Merges:         ${report.merges.length}`);
  for (const m of report.merges) console.log(`  ${m.node} ← ${m.from}: ${m.detail}`);
  console.log(`Conflicts:      ${report.conflicts.length}`);
  for (const c of report.conflicts) console.log(`  ${c.node} ← ${c.from}: ${c.reason}`);
  console.log(`Unresolved (left as they are): ${report.unresolved.length}`);
  for (const u of report.unresolved) console.log(`  ${u.value}  e.g. ${u.paths[0]}`);
  console.log(`Patch paths:    ${report.patchPaths}`);
}

async function main() {
  const a = args(process.argv);
  if (a.apply && a.from) throw new Error('--apply works on the live database only (drop --from)');
  fs.mkdirSync(BACKUP_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '');

  const snapshotFile = a.apply ? path.join(BACKUP_DIR, `rtdb_before_fix_${stamp}.json`) : null;
  const db = await readDatabase(a, snapshotFile);
  const planner = new Planner(db).plan();
  const patch = planner.patch();
  const report = summarize(planner, patch);
  fs.writeFileSync(path.join(BACKUP_DIR, 'phone_fix_report.json'), JSON.stringify(report, null, 2));

  console.log(a.apply ? '=== APPLY ===' : '=== DRY RUN (nothing written) ===');
  print(report);

  if (!a.apply) return;
  if (report.conflicts.length) {
    console.error('\nRefusing to apply: resolve the conflicts above first.');
    process.exit(2);
  }
  if (report.patchPaths === 0) {
    console.log('\nNothing to fix.');
    return;
  }
  const patchFile = path.join(BACKUP_DIR, `phone_fix_patch_${stamp}.json`);
  fs.writeFileSync(patchFile, JSON.stringify(patch, null, 2));
  console.log(`\nSnapshot: ${snapshotFile}\nPatch:    ${patchFile}\nWriting…`);
  await writePatch(a, patch, patchFile);

  // Verify: read back, re-plan — nothing may be left.
  const after = await readDatabase(a, null);
  const again = new Planner(after).plan();
  const left = Object.keys(again.patch()).length;
  if (left) {
    console.error(`Verification FAILED: ${left} paths still need fixing (see a new --dry-run).`);
    process.exit(3);
  }
  console.log('Verified: a fresh read needs no further changes.');
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e.stderr ? e.stderr.toString() : e.message);
    process.exit(1);
  });
}

module.exports = { normalizePhone, repairStoredPhone, Planner };
