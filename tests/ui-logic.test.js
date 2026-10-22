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
  assert.strictEqual(L.DEFAULT_LEVEL, 'intermediate'); // new users start at Intermediate (a saved choice wins)
  assert.strictEqual(L.normalizeLevel('nope'), 'intermediate');
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

test('discovery: application names from containers', () => {
  assert.strictEqual(L.suggestAppName({ name: 'docker-compose-prowlarr-1', compose: { project: 'docker-compose', service: 'prowlarr' } }), 'prowlarr');
  assert.strictEqual(L.suggestAppName({ name: 'media-sonarr-2', compose: { project: 'media', service: '' } }), 'sonarr');
  assert.strictEqual(L.suggestAppName({ name: 'Uptime_Kuma', compose: {} }), 'uptime-kuma');
  assert.strictEqual(L.suggestAppName({ name: '', compose: {}, image: 'ghcr.io/hotio/prowlarr:latest' }), 'prowlarr');
  assert.strictEqual(L.displayNameFromLabel('uptime-kuma'), 'Uptime Kuma');
});

test('discovery: port preselection never picks UDP, blocked or database ports first', () => {
  const ports = [{ port: 5432, proto: 'tcp', guess: 'not-http' }, { port: 3478, proto: 'udp', guess: 'not-http' }, { port: 2375, proto: 'tcp', guess: 'blocked' }, { port: 8191, proto: 'tcp', guess: 'unknown' }, { port: 8096, proto: 'tcp', guess: 'http' }];
  assert.strictEqual(L.choosePort(ports).port, 8096);
  assert.strictEqual(L.choosePort(ports.slice(0, 4)).port, 8191);
  assert.strictEqual(L.choosePort(ports.slice(0, 3)), null);
});

test('discovery: reachability options', () => {
  assert.deepStrictEqual(L.reachOptions({ onProxyNetwork: true, published: [] }, 80).options, ['network']);
  const pub = { onProxyNetwork: false, published: [{ port: 8000, proto: 'tcp', hostPort: 8000, hostIp: '0.0.0.0' }] };
  assert.strictEqual(L.reachOptions(pub, 8000).default, 'hostport');
  assert.strictEqual(L.reachOptions(pub, 9000).default, 'attach');
  const loop = { onProxyNetwork: false, published: [{ port: 8000, proto: 'tcp', hostPort: 8000, hostIp: '127.0.0.1' }] };
  assert.strictEqual(L.reachOptions(loop, 8000).default, 'attach');
  assert.ok(L.reachOptions(loop, 8000).loopbackOnly);
});

test('explorer: a component is never green from configuration alone', () => {
  const c = (dims, extra = {}) => ({ id: 'x', applicable: true, dims: { detected: null, configured: null, running: null, reachable: null, authenticated: null, verified: null, ...dims }, ...extra });
  assert.strictEqual(L.componentStatus(c({})).key, 'unknown');
  assert.strictEqual(L.componentStatus(c({ configured: true })).key, 'configured');
  assert.strictEqual(L.componentStatus(c({ configured: true })).tone, 'neutral');
  assert.strictEqual(L.componentStatus(c({ detected: true })).key, 'detected');
  assert.strictEqual(L.componentStatus(c({ configured: true, running: true })).key, 'running');
  assert.notStrictEqual(L.componentStatus(c({ configured: true, running: true })).tone, 'ok');
  assert.strictEqual(L.componentStatus(c({ running: true, verified: true })).key, 'verified');
  assert.strictEqual(L.componentStatus(c({ running: true, verified: true })).tone, 'ok');
  assert.strictEqual(L.componentStatus(c({ configured: true, running: false })).key, 'failed');
  assert.strictEqual(L.componentStatus(c({ verified: true, authenticated: false })).key, 'failed');
  assert.strictEqual(L.componentStatus(c({ running: false }, { applicable: false })).key, 'off');
  assert.strictEqual(L.DIMENSIONS.length, 6);
});

test('explorer: the first failing component in path order blocks the rest', () => {
  const mk = (id, dims, applicable = true) => ({ id, applicable, dims });
  const order = ['a', 'b', 'c', 'd'];
  assert.strictEqual(L.firstBlocked([mk('a', { running: true }), mk('b', { configured: true }), mk('c', { running: true })], order), -1);
  assert.strictEqual(L.firstBlocked([mk('a', { running: true }), mk('b', { running: false }, false), mk('c', { running: false }), mk('d', { running: false })], order), 2);
});

console.log(`\n${passed} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
