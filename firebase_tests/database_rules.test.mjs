// Database-rules test against the local emulator (never the live DB):
//   firebase emulators:exec --only database --project demo-tbtr "node firebase_tests/database_rules.test.mjs"
// Needs Java on PATH (Android Studio ships one: <Android Studio>/jbr/bin).

const NS = 'demo-tbtr-default-rtdb';
const BASE = 'http://127.0.0.1:9123';

// Requests run as `uid` via the admin token + auth_variable_override, which
// the emulator evaluates against the rules (an unsigned ID token would be
// treated as admin and skip them). uid null = signed out, 'ADMIN' = seeding.
async function req(method, path, uid, body, query = '') {
  const headers = uid === null ? {} : { Authorization: 'Bearer owner' };
  const as = uid === null || uid === 'ADMIN'
    ? ''
    : `&auth_variable_override=${encodeURIComponent(JSON.stringify({ uid }))}`;
  const r = await fetch(`${BASE}/${path}.json?ns=${NS}${query}${as}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return r.status;
}

let fails = 0;
async function expect(desc, want, p) {
  const s = await p;
  const ok = want ? s === 200 : s !== 200;
  if (!ok) fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${desc} -> ${s}`);
}

const A = '+23276000001', B = '+23276000002', C = '+23276000003', ADM = '+23276000009';
const cidAB = [A, B].sort().join('_');
const q = (child, val) => `&orderBy=%22${child}%22&equalTo=%22${encodeURIComponent(val)}%22`;

await req('PUT', '', 'ADMIN', {
  users: {
    [A]: { uid: A, name: 'A', authUid: 'ua' },
    [B]: { uid: B, name: 'B', authUid: 'ub' },
    [ADM]: { uid: ADM, authUid: 'uadm' },
    '+23276000004': { uid: '+23276000004', name: 'legacy' },
  },
  authIndex: { ua: A, ub: B, uadm: ADM, uc: C, ux: A },
  admins: { [ADM]: true },
  sermons: { pending: { p1: { senderId: A, title: 't' } } },
  calls: { c1: { callerId: A, calleeId: B, state: 'RINGING' } },
  feedback: { f1: { message: 'hi' } },
});

// users
await expect('A reads B profile (numbers visible)', true, req('GET', `users/${B}`, 'ua'));
await expect('unauthenticated read users', false, req('GET', 'users', null));
await expect('A updates own profile', true, req('PATCH', `users/${A}`, 'ua', { name: 'A2' }));
await expect('A edits B profile', false, req('PATCH', `users/${B}`, 'ua', { name: 'hacked' }));
await expect('new user registers fresh number', true, req('PUT', `users/${C}`, 'uc', { uid: C, authUid: 'uc' }));
await expect('register with someone else authUid', false, req('PUT', 'users/+23276000005', 'uc', { uid: 'x', authUid: 'ua' }));
await expect('legacy record claimed by link', true, req('PUT', 'users/+23276000004/authUid', 'ul', 'ul'));
// authIndex
await expect('A writes own authIndex', true, req('PUT', 'authIndex/ua', 'ua', A));
await expect('A points authIndex at B', false, req('PUT', 'authIndex/ua', 'ua', B));
await expect('A writes other authIndex', false, req('PUT', 'authIndex/ub', 'ua', A));
// presence
await expect('A sets own presence', true, req('PUT', `presence/${A}`, 'ua', { online: true }));
await expect('A sets B presence', false, req('PUT', `presence/${B}`, 'ua', { online: true }));
await expect('stale index (ux->A) sets A presence', false, req('PUT', `presence/${A}`, 'ux', { online: true }));
// chats
await expect('A writes message in A_B', true, req('POST', `privateChats/${cidAB}/messages`, 'ua', { text: 'hi' }));
await expect('B reads A_B', true, req('GET', `privateChats/${cidAB}`, 'ub'));
await expect('C reads A_B', false, req('GET', `privateChats/${cidAB}`, 'uc'));
await expect('stale login ux reads A_B', false, req('GET', `privateChats/${cidAB}`, 'ux'));
await expect('A updates B userChats for A_B', true, req('PATCH', `userChats/${B}/${cidAB}`, 'ua', { unread: 1, lastMessage: 'hi' }));
await expect('A reads B lastReadTimestamp', true, req('GET', `userChats/${B}/${cidAB}/lastReadTimestamp`, 'ua'));
await expect('A reads B full chat list', false, req('GET', `userChats/${B}`, 'ua'));
await expect('B reads own chat list', true, req('GET', `userChats/${B}`, 'ub'));
await expect('C writes into B userChats A_B', false, req('PATCH', `userChats/${B}/${cidAB}`, 'uc', { unread: 99 }));
// calls
await expect('B queries incoming calls', true, req('GET', 'calls', 'ub', undefined, q('calleeId', B)));
await expect('C queries B calls', false, req('GET', 'calls', 'uc', undefined, q('calleeId', B)));
await expect('B accepts call', true, req('PUT', 'calls/c1/state', 'ub', 'ACCEPTED'));
await expect('C touches call', false, req('PUT', 'calls/c1/state', 'uc', 'ENDED'));
await expect('C starts a call as caller', true, req('PUT', 'calls/c2', 'uc', { callerId: C, calleeId: A, state: 'RINGING' }));
await expect('C starts call pretending to be A', false, req('PUT', 'calls/c3', 'uc', { callerId: A, calleeId: B }));
await expect('A adds ICE candidate', true, req('POST', 'calls/c1/callerCandidates', 'ua', { sdp: 'x' }));
await expect('B removes ended call', true, req('DELETE', 'calls/c1', 'ub'));
// feed
await expect('A posts feed message', true, req('POST', 'textMessages', 'ua', { senderId: A, text: 'x', timestamp: 1 }));
await expect('A posts feed message as B', false, req('POST', 'textMessages', 'ua', { senderId: B, text: 'x', timestamp: 1 }));
await expect('A uploads pending sermon', true, req('PUT', 'sermons/pending/p2', 'ua', { senderId: A }));
await expect('A approves sermon', false, req('PUT', 'sermons/approved/p1', 'ua', { senderId: A }));
await expect('admin approves sermon', true, req('PUT', 'sermons/approved/p1', 'uadm', { senderId: A }));
await expect('admin removes pending', true, req('DELETE', 'sermons/pending/p1', 'uadm'));
await expect('A reacts', true, req('PUT', 'reactions/i1/like', 'ua', 3));
// feedback / admin
await expect('A sends feedback', true, req('POST', 'feedback', 'ua', { message: 'x' }));
await expect('A reads feedback', false, req('GET', 'feedback', 'ua'));
await expect('admin reads feedback', true, req('GET', 'feedback', 'uadm'));
await expect('A makes self admin', false, req('PUT', `admins/${A}`, 'ua', true));
await expect('A reads admin flag', true, req('GET', `admins/${A}`, 'ua'));
await expect('A writes migrationAttempts', false, req('PUT', `migrationAttempts/${A}`, 'ua', { failCount: 0 }));
await expect('random top-level path', false, req('PUT', 'junk', 'ua', 1));

console.log(fails ? `${fails} FAILED` : 'ALL PASSED');
process.exit(fails ? 1 : 0);
