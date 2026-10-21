'use strict';
// Developer tests for webui\logic.js (Node.js is a development tool only; end users never need it).
//   node tests\ui-logic.test.js
const assert = require('assert');
const L = require('../webui/logic.js');

let passed = 0;
const failures = [];
function test(name, fn) {
  try { fn(); passed++; console.log(`[PASS] ${name}`); } catch (e) { failures.push(name); console.log(`[FAIL] ${name}  ${e.message}`); }
}

test('detail levels: order, normalization, visibility', () => {
  assert.deepStrictEqual(L.LEVELS, ['beginner', 'intermediate', 'advanced', 'expert']);
  assert.strictEqual(L.normalizeLevel('nope'), 'beginner');
  assert.ok(L.isVisibleAt('advanced', 'expert'));
  assert.ok(!L.isVisibleAt('advanced', 'intermediate'));
  assert.ok(L.isVisibleAt(undefined, 'beginner'));
});

test('labels: display names become DNS labels', () => {
  assert.strictEqual(L.suggestLabel('Notflix'), 'notflix');
  assert.strictEqual(L.suggestLabel('Home Assistant!'), 'home-assistant');
  assert.strictEqual(L.suggestLabel('traefik-ext1'), 'traefik-ext1');
  assert.strictEqual(L.suggestLabel('traefik__ext1'), 'traefik-ext1');
  assert.strictEqual(L.suggestLabel('  Café Ünïcode  '), 'cafe-unicode');
  assert.strictEqual(L.suggestLabel('x'.repeat(80)).length, 63);
  assert.strictEqual(L.suggestServiceName('A'.repeat(60)).length, 40);
  assert.strictEqual(L.suggestLabel('---'), '');
});

test('auto naming: follows the source until edited, then keeps the manual value', () => {
  let st = L.autoNameFromSource({ value: '', custom: false }, 'Notflix');
  assert.deepStrictEqual(st, { value: 'notflix', custom: false });
  st = L.autoNameEdit(st, 'movies', 'Notflix');
  assert.deepStrictEqual(st, { value: 'movies', custom: true });
  st = L.autoNameFromSource(st, 'Notflix 2');
  assert.strictEqual(st.value, 'movies', 'a later display-name change must not overwrite the edit');
  st = L.autoNameReset('Notflix 2');
  assert.deepStrictEqual(st, { value: 'notflix-2', custom: false });
  st = L.autoNameEdit(st, 'notflix-2', 'Notflix 2');
  assert.strictEqual(st.custom, false, 'typing the suggestion is not a manual override');
});

test('dashboard hostname suggestion from the instance name', () => {
  assert.strictEqual(L.joinHostname(L.suggestLabel('traefik-ext1'), 'jrtechconsult.com'), 'traefik-ext1.jrtechconsult.com');
  assert.strictEqual(L.joinHostname('', 'example.com'), 'example.com');
});

test('subdomain validation', () => {
  assert.ok(L.isValidSubdomain('movies'));
  assert.ok(L.isValidSubdomain('a.b-c'));
  for (const bad of ['', '-a', 'a-', 'a_b', 'a..b', 'UP', 'a b']) assert.ok(!L.isValidSubdomain(bad), bad);
});

test('hostname splitting uses the longest allowed domain', () => {
  const zones = ['example.com', 'lab.example.com'];
  assert.deepStrictEqual(L.splitHostname('app.lab.example.com', zones), { sub: 'app', domain: 'lab.example.com', allowed: true });
  assert.deepStrictEqual(L.splitHostname('example.com', zones), { sub: '', domain: 'example.com', allowed: true });
  assert.strictEqual(L.splitHostname('x.other.net', zones).allowed, false);
});

test('target detection', () => {
  assert.strictEqual(L.detectTarget('uptime-kuma'), 'docker');
  assert.strictEqual(L.detectTarget('localhost'), 'host');
  assert.strictEqual(L.detectTarget('127.0.0.1'), 'host');
  assert.strictEqual(L.detectTarget('10.10.0.11'), 'lan');
  assert.strictEqual(L.detectTarget('nas.lan'), 'lan');
  assert.strictEqual(L.detectTarget('x', 'host'), 'host');
  assert.ok(L.isPrivateIPv4('192.168.1.2') && !L.isPrivateIPv4('8.8.8.8'));
});

test('fingerprints are stable and order-independent for objects', () => {
  assert.strictEqual(L.fingerprint({ a: 1, b: [1, 2] }), L.fingerprint({ b: [1, 2], a: 1 }));
  assert.notStrictEqual(L.fingerprint({ a: 1 }), L.fingerprint({ a: 2 }));
  assert.notStrictEqual(L.fingerprint([1, 2]), L.fingerprint([2, 1]));
});

test('review state: reviewed, invalidated by changes, reopened', () => {
  const fp1 = L.fingerprint({ port: 8180 });
  const fp2 = L.fingerprint({ port: 8280 });
  let store = {};
  assert.strictEqual(L.reviewState(store, 'local-config', fp1), 'unreviewed');
  store = L.markReviewed(store, 'local-config', fp1);
  assert.strictEqual(L.reviewState(store, 'local-config', fp1), 'reviewed');
  assert.strictEqual(L.reviewState(store, 'local-config', fp2), 'stale', 'a changed configuration invalidates the review');
  store = L.reopenReview(store, 'local-config');
  assert.strictEqual(L.reviewState(store, 'local-config', fp1), 'unreviewed');
});

test('reviewing never changes a validation status', () => {
  // The vocabulary keeps them separate: worstStatus ignores "reviewed".
  assert.strictEqual(L.worstStatus(['failed', 'reviewed']), 'failed');
  assert.strictEqual(L.worstStatus(['validated', 'reviewed']), 'validated');
  assert.strictEqual(L.STATUS.reviewed.tone, 'info');
  assert.strictEqual(L.STATUS.failed.tone, 'err');
});

test('server review items map onto the status vocabulary', () => {
  assert.strictEqual(L.statusFromReview('ok', 'validated'), 'validated');
  assert.strictEqual(L.statusFromReview('ok', 'applied'), 'applied');
  assert.strictEqual(L.statusFromReview('ok', 'verified'), 'healthy');
  assert.strictEqual(L.statusFromReview('failed', 'validated'), 'failed');
  assert.strictEqual(L.worstStatus(['validated', 'warning', 'pending']), 'warning');
});

test('emails and sizes', () => {
  assert.deepStrictEqual(L.splitEmails('a@b.co, c@d.org;\n e@f.net'), ['a@b.co', 'c@d.org', 'e@f.net']);
  assert.ok(L.isEmail('a.b+c@example.com') && !L.isEmail('nope@'));
  assert.strictEqual(L.formatBytes(1536), '1.5 KB');
});

console.log(`\n${passed} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
