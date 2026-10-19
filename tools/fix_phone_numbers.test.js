// node tools/fix_phone_numbers.test.js — planner checks on synthetic data.
'use strict';
const assert = require('assert');
const { normalizePhone, repairStoredPhone, Planner } = require('./fix_phone_numbers');

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log('ok   ', name);
  } catch (e) {
    failed++;
    console.log('FAIL ', name, '\n     ', e.message);
  }
}

test('same rules as lib/util/phone_utils.dart', () => {
  for (const s of ['031932652', '31932652', '(031) 932652', '23231932652',
    '+23231932652', '0023231932652', '+232 31 932 652', '+031932652']) {
    assert.strictEqual(normalizePhone(s), '+23231932652', s);
  }
  assert.strictEqual(normalizePhone('+44 7911 123456'), '+447911123456');
  assert.strictEqual(normalizePhone('12'), null);
  assert.strictEqual(repairStoredPhone('+44034909376'), '+23234909376');
});

const db = () => ({
  users: {
    '+031932652': { uid: '+031932652', phone: '+031932652', name: 'Old', createdAt: 100, activeDeviceId: 'dev1' },
    '+23231932652': { uid: '+23231932652', phone: '+23231932652', name: 'New', createdAt: 200, activeDeviceId: 'dev1' },
    'LegacyAnonUid000000000000001': { a: 'x', b: '079150079' },
  },
  presence: { '+031932652': { lastSeen: 50 }, '+23231932652': { lastSeen: 90 } },
  userChats: {
    '+031932652': { '+031932652_+23276123456': { otherUid: '+23276123456', lastTimestamp: 10, unread: 2 } },
    '+23276123456': { '+031932652_+23276123456': { otherUid: '+031932652', lastTimestamp: 10 } },
  },
  privateChats: {
    '+031932652_+23276123456': { messages: { m1: { senderId: '+031932652', senderPhone: '+031932652', text: 'hi' } } },
    '+23231932652_+23276123456': { messages: { m2: { senderId: '+23276123456', text: 'yo' } } },
  },
  sermons: { approved: { s1: { senderId: '+031932652', senderPhone: '031932652' } } },
  feedback: { f1: { phone: '079150079' } },
  migrationLog: { '+23278060026': { '1788509793467_ab': { at: 1 } } },
});

test('merges a wrong key into the existing correct key, keeping every message', () => {
  const p = new Planner(db()).plan();
  const after = p.after;
  assert.deepStrictEqual(Object.keys(after.users).sort(),
    ['+23231932652', 'LegacyAnonUid000000000000001']);
  assert.strictEqual(after.users['+23231932652'].name, 'New'); // newer presence wins
  assert.strictEqual(after.users['+23231932652'].createdAt, 100); // earliest kept
  const msgs = after.privateChats['+23231932652_+23276123456'].messages;
  assert.deepStrictEqual(Object.keys(msgs).sort(), ['m1', 'm2']);
  assert.strictEqual(msgs.m1.senderId, '+23231932652');
  assert.strictEqual(after.privateChats['+031932652_+23276123456'], undefined);
  assert.strictEqual(after.userChats['+23276123456']['+23231932652_+23276123456'].otherUid, '+23231932652');
  assert.ok(after.userChats['+23231932652']['+23231932652_+23276123456']);
  assert.strictEqual(after.sermons.approved.s1.senderPhone, '+23231932652');
  assert.strictEqual(after.feedback.f1.phone, '+23279150079');
  assert.strictEqual(after.phoneAliases['+031932652'], '+23231932652');
  assert.strictEqual(p.conflicts.length, 0);
  assert.ok(p.merges.length >= 3);
});

test('legacy records and timestamp keys are left alone', () => {
  const after = new Planner(db()).plan().after;
  assert.strictEqual(after.users.LegacyAnonUid000000000000001.b, '079150079');
  assert.ok(after.migrationLog['+23278060026']['1788509793467_ab']);
});

test('idempotent: planning the fixed data changes nothing', () => {
  const once = new Planner(db()).plan().after;
  const again = new Planner(once).plan();
  assert.deepStrictEqual(again.patch(), {});
});

test('two devices on one number is a conflict, not an automatic merge', () => {
  const d = db();
  d.users['+031932652'].activeDeviceId = 'other-device';
  const p = new Planner(d).plan();
  assert.strictEqual(p.conflicts.length, 1);
});

test('patch deletes the old key and writes the new one atomically', () => {
  const patch = new Planner(db()).plan().patch();
  assert.strictEqual(patch['users/+031932652'], null);
  assert.strictEqual(patch['privateChats/+031932652_+23276123456'], null);
  assert.ok(patch['privateChats/+23231932652_+23276123456/messages/m1']);
});

if (failed) {
  console.log(`\n${failed} failed`);
  process.exit(1);
}
console.log('\nall passed');
