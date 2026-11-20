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

test('backend: connection option from a saved target type', () => {
  assert.strictEqual(L.whereFromTargetType('docker'), 'docker');
  assert.strictEqual(L.whereFromTargetType('host'), 'this-computer');
  assert.strictEqual(L.whereFromTargetType('lan'), 'lan');
});

test('backend: pasted addresses are parsed; loopback is recognised', () => {
  assert.deepStrictEqual(L.parseBackendAddress('http://127.0.0.1:4119/'), { scheme: 'http', host: '127.0.0.1', port: 4119 });
  assert.deepStrictEqual(L.parseBackendAddress('4119'), { scheme: '', host: '', port: 4119 });
  assert.deepStrictEqual(L.parseBackendAddress('NAS.local'), { scheme: '', host: 'nas.local', port: 0 });
  assert.ok(L.isLoopbackHost('localhost') && L.isLoopbackHost('127.0.0.1') && !L.isLoopbackHost('10.10.0.11'));
});

// Candidates as the resolver returns them for HFS on this PC, typed as 10.10.0.11:80 under "another device".
const ENTERED = { type: 'lan', host: '10.10.0.11', port: 80, protocol: 'http', url: 'http://10.10.0.11:80', role: 'entered', rejected: false };
const GATEWAY = { type: 'host', host: 'host.docker.internal', port: 80, protocol: 'http', url: 'http://host.docker.internal:80', role: 'recommended', rejected: false };
const HFS = { recommended: GATEWAY, suggested: GATEWAY, entered: ENTERED, candidates: [ENTERED, GATEWAY],
  guidance: [{ id: 'own-lan-ip', severity: 'info', category: 'recommendation', action: 'use-recommended', condition: 'own-lan-ip|10.10.0.11|80', about: ENTERED.url },
    { id: 'subnet-overlap', severity: 'warn', category: 'connectivity', action: '', condition: 'subnet-overlap|10.10.0.11|unifi', about: ENTERED.url }] };

test('backend: the question and the three connection options', () => {
  assert.strictEqual(L.BACKEND_QUESTION, 'How should Traefik connect to this application?');
  assert.deepStrictEqual(L.WHERE, ['docker', 'this-computer', 'lan']);
});

test('backend: the address entered stays selected; the recommendation is offered next to it, never forced (HFS 10.10.0.11:80)', () => {
  const r = L.chooseBackend({}, HFS);
  assert.strictEqual(r.source, 'entered'); assert.ok(L.sameTarget(r.target, ENTERED)); assert.strictEqual(r.needsChoice, false);
  const list = L.backendCandidates(HFS);
  assert.deepStrictEqual(list.map((c) => c.label), ['Address you entered', 'Recommended alternative']);
  assert.ok(list[1].isRecommended && !list[0].isRecommended);
});

test('backend: an explicitly chosen non-recommended backend survives a new recommendation', () => {
  const later = { ...HFS, recommended: { ...GATEWAY, port: 81, url: 'http://host.docker.internal:81' } };
  const r = L.chooseBackend({ source: 'chosen', target: ENTERED }, later);
  assert.strictEqual(r.source, 'chosen'); assert.ok(L.sameTarget(r.target, ENTERED));
  const g = L.chooseBackend({ source: 'chosen', target: GATEWAY }, HFS);
  assert.ok(L.sameTarget(g.target, GATEWAY));
});

test('backend: exactly one usable candidate is selected automatically (localhost typed: only the gateway can work)', () => {
  const loop = { ...ENTERED, host: '127.0.0.1', url: 'http://127.0.0.1:80', rejected: true, rejectedReason: 'Traefik itself' };
  const r = L.chooseBackend({}, { recommended: GATEWAY, candidates: [loop, GATEWAY], guidance: [{ id: 'loopback', action: 'use-recommended' }] });
  assert.strictEqual(r.source, 'auto'); assert.ok(L.sameTarget(r.target, GATEWAY)); assert.strictEqual(r.needsChoice, false);
});

test('backend: several discovered paths and nothing typed: a choice is needed, and the message says what to do', () => {
  const a = { type: 'host', host: 'host.docker.internal', port: 8088, url: 'http://host.docker.internal:8088', role: 'recommended' };
  const b = { type: 'docker', host: 'isolated', port: 80, url: 'http://isolated:80', role: 'alternative' };
  const res = { recommended: a, ambiguous: true, guidance: [], candidates: [a, b] };
  const r = L.chooseBackend({}, res);
  assert.strictEqual(r.target, null); assert.ok(r.needsChoice);
  assert.strictEqual(L.backendValidation({ where: 'docker', target: null, backend: { resolution: res } }), 'Select the address Traefik should use to reach your application.');
});

test('backend: no candidates -> no "choose an option" error; a plain instruction instead', () => {
  const r = L.chooseBackend({}, { candidates: [], guidance: [] });
  assert.strictEqual(r.target, null); assert.strictEqual(r.needsChoice, false);
  assert.strictEqual(L.backendValidation({ where: 'lan', target: null, backend: { resolution: { candidates: [] } } }), 'Enter the address and port of the application.');
  assert.strictEqual(L.backendValidation({ where: 'docker', target: null, backend: null }), 'Choose the container and its port.');
  assert.strictEqual(L.backendValidation({ where: 'lan', target: ENTERED }), '');
});

test('backend: an existing service keeps its saved backend; a custom URL is used exactly, an invalid one selects nothing', () => {
  const saved = { type: 'lan', host: '10.10.0.11', port: 4119 };
  assert.ok(L.sameTarget(L.chooseBackend({ source: 'existing', target: saved }, HFS).target, saved));
  const ov = { type: 'lan', host: '10.20.0.5', port: 8080, url: 'http://10.20.0.5:8080', role: 'custom', rejected: false };
  const r = L.chooseBackend({ override: true }, { override: true, custom: ov, recommended: GATEWAY, candidates: [ov, GATEWAY], guidance: [] });
  assert.strictEqual(r.source, 'override'); assert.ok(L.sameTarget(r.target, ov));
  const bad = L.chooseBackend({ override: true }, { override: false, custom: null, recommended: GATEWAY, candidates: [GATEWAY], guidance: [] });
  assert.strictEqual(bad.target, null);
  assert.deepStrictEqual(L.backendCandidates({ candidates: [GATEWAY, ov], recommended: GATEWAY }).map((c) => c.role), ['custom', 'recommended']);
});

test('backend: complete backend URLs (Advanced/Expert): protocol, host, port; no loopback, no base path', () => {
  assert.deepStrictEqual(L.parseBackendUrl('http://10.10.0.8:8080'), { ok: true, scheme: 'http', host: '10.10.0.8', port: 8080, path: '', url: 'http://10.10.0.8:8080' });
  assert.strictEqual(L.parseBackendUrl('https://nas.home.arpa').port, 443);
  assert.ok(!L.parseBackendUrl('10.10.0.8:8080').ok);
  assert.match(L.parseBackendUrl('http://127.0.0.1:80').error, /Traefik itself/);
  assert.match(L.parseBackendUrl('http://10.10.0.8:8080/files').error, /Path prefix/);
  assert.match(L.backendValidation({ override: true, custom: 'http://localhost:1' }), /Traefik itself/);
});

test('backend: notices - dismissed stay hidden, restrictions always show, a followed recommendation hides', () => {
  const g = [{ id: 'loopback', severity: 'warn', condition: 'loopback|127.0.0.1|4119' }, { id: 'private', severity: 'error', condition: 'x' }];
  assert.strictEqual(L.visibleGuidance(g, { 'loopback|127.0.0.1|4119': true, x: true }).length, 1);
  assert.strictEqual(L.visibleGuidance([{ id: 'loopback', severity: 'warn', condition: 'loopback|127.0.0.1|4120' }], { 'loopback|127.0.0.1|4119': true }).length, 1);
  const shown = L.visibleGuidance(HFS.guidance, {}, { target: ENTERED, verification: null, recommended: GATEWAY });
  assert.deepStrictEqual(shown.map((x) => x.id), ['own-lan-ip', 'subnet-overlap']);
  const followed = L.visibleGuidance(HFS.guidance, {}, { target: GATEWAY, verification: null, recommended: GATEWAY });
  assert.deepStrictEqual(followed.map((x) => x.id), ['subnet-overlap']);
});

test('backend: connectivity warnings disappear after the selected backend passes a test, not after a failure', () => {
  const ok = { state: 'ok', result: 'verified', targetUrl: 'http://host.docker.internal:80', target: { protocol: 'http' } };
  assert.deepStrictEqual(L.visibleGuidance(HFS.guidance, {}, { target: GATEWAY, verification: ok, recommended: GATEWAY }).map((x) => x.id), []);
  const fail = { state: 'failed', result: 'timeout', targetUrl: 'http://10.10.0.11:80', target: { protocol: 'http' } };
  assert.ok(L.visibleGuidance(HFS.guidance, {}, { target: ENTERED, verification: fail, recommended: GATEWAY }).some((x) => x.id === 'subnet-overlap'));
});

test('backend: test headlines - success, could not connect (with the address), hostname rejected', () => {
  assert.strictEqual(L.backendHeadline({ state: 'ok', result: 'verified' }, GATEWAY), 'Traefik successfully connected to the selected application.');
  assert.strictEqual(L.backendHeadline({ state: 'failed', result: 'timeout' }, ENTERED), 'Traefik could not connect to 10.10.0.11:80. Test another address or explicitly save the route without verification.');
  assert.match(L.backendHeadline({ state: 'failed', result: 'host-rejected' }, ENTERED), /rejected the public hostname/);
  assert.match(L.backendHeadline({ state: 'auth', result: 'auth' }, ENTERED), /login/);
});

test('backend: status tones - green only for an application answer; a login is "auth"; untested is neutral', () => {
  assert.strictEqual(L.backendStatus(null).label, 'Not tested');
  assert.strictEqual(L.backendStatus({ state: 'ok', result: 'verified', label: 'Verified reachable' }).tone, 'ok');
  assert.strictEqual(L.backendStatus({ state: 'auth', result: 'auth', label: 'x' }).tone, 'auth');
  assert.strictEqual(L.backendStatus({ state: 'failed', result: 'host-rejected', label: 'Hostname rejected' }).tone, 'err');
  assert.strictEqual(L.backendStatus({ state: 'warning', result: 'unavailable', label: 'x' }).tone, 'warn');
});

test('identity: state vocabulary; verified and authentication required are distinct', () => {
  assert.strictEqual(L.identityState('verified').label, 'Verified');
  assert.strictEqual(L.identityState('auth-required').label, 'Authentication required');
  assert.strictEqual(L.identityState('auth-required').tone, 'auth');
  assert.strictEqual(L.identityState('awaiting-user').tone, 'warn');
  assert.strictEqual(L.identityState('nonsense').label, 'Not configured');
  for (const s of ['not-configured', 'configured', 'awaiting-user', 'reachable', 'auth-required', 'verified', 'failed', 'skipped']) assert.ok(L.IDENTITY_STATES[s]);
});

test('identity: Google redirect URI from the public URL and source slug (https only, no hard-coded domain)', () => {
  assert.strictEqual(L.googleRedirectUri('https://auth.jrtechconsult.com'), 'https://auth.jrtechconsult.com/source/oauth/callback/google/');
  assert.strictEqual(L.googleRedirectUri('https://Login.Example.org/', 'gws'), 'https://login.example.org/source/oauth/callback/gws/');
  assert.strictEqual(L.googleRedirectUri('http://auth.example.com'), '');
  assert.strictEqual(L.googleRedirectUri('https://auth.example.com/path'), '');
  assert.strictEqual(L.googleRedirectUri('https://auth.example.com', '../x'), '');
});

test('identity: Google client ID shape', () => {
  assert.ok(L.isGoogleClientId('123456789012-abcdefgh12345678.apps.googleusercontent.com'));
  assert.ok(!L.isGoogleClientId('GOCSPX-secret'));
  assert.ok(!L.isGoogleClientId('1234567-x.apps.googleusercontent.com.evil.com'));
});

test('identity: next step is the first failure, else the first step waiting for the user', () => {
  const steps = [{ id: 'install', state: 'reachable' }, { id: 'google', state: 'awaiting-user' }, { id: 'apps', state: 'failed' }];
  assert.strictEqual(L.identityNextStep(steps).id, 'apps');
  assert.strictEqual(L.identityNextStep(steps.slice(0, 2)).id, 'google');
  assert.strictEqual(L.identityNextStep([{ id: 'x', state: 'verified' }]), null);
});

test('credentials: status labels; an unreachable server is a warning, not a token failure', () => {
  assert.strictEqual(L.credentialStatus({ status: 'valid' }).tone, 'ok');
  assert.strictEqual(L.credentialStatus({ status: 'insufficient' }).tone, 'err');
  assert.strictEqual(L.credentialStatus({ status: 'expired' }).label, 'Expired');
  assert.strictEqual(L.credentialStatus({ status: 'unreachable' }).tone, 'warn');
  assert.strictEqual(L.credentialStatus(null).label, 'Not connected');
  assert.strictEqual(L.credentialStatus({ status: 'whatever' }).label, 'Not checked yet');
});

const wizData = (over = {}) => {
  const base = {
    provider: 'authentik',
    config: { provider: 'authentik', authMode: 'local', wizardStep: '', authentik: { publicUrl: 'https://auth.example.com', owner: {}, loginPage: {} } },
    install: { server: { state: 'running' } }, health: { Ready: true, Setup: 'done' }, credential: { ok: true },
    route: { exists: true, router: 'enabled' }, overview: { outpost: { authentikHost: 'https://auth.example.com/' } }, google: { source: null }, apps: [],
  };
  return JSON.parse(JSON.stringify({ ...base, ...over, config: { ...base.config, ...(over.config || {}), authentik: { ...base.config.authentik, ...((over.config || {}).authentik || {}) } } }));
};

test('wizard: the local path has no Google steps; the owner step is next after the address', () => {
  const w = L.identityWizard(wizData());
  assert.deepStrictEqual(w.steps.map((s) => s.id), ['mode', 'authentik', 'connect', 'address', 'owner', 'apps', 'done']);
  assert.strictEqual(w.current, 'owner');
  assert.ok(!w.steps.find((s) => s.id === 'apps').available, 'protecting waits for the owner');
});

test('wizard: the Google path adds Register with Google and the optional sign-in page', () => {
  const w = L.identityWizard(wizData({ config: { authMode: 'google' } }));
  assert.deepStrictEqual(w.steps.map((s) => s.id), ['mode', 'authentik', 'connect', 'address', 'google', 'signin', 'owner', 'apps', 'done']);
  assert.strictEqual(w.current, 'google');
  assert.ok(!w.steps.find((s) => s.id === 'owner').available);
  const w2 = L.identityWizard(wizData({ config: { authMode: 'google' }, google: { source: { Slug: 'google' } } }));
  assert.ok(w2.steps.find((s) => s.id === 'owner').available, 'the optional sign-in page does not block the owner step');
  assert.strictEqual(w2.current, 'signin');
});

test('wizard: steps complete only from observed state; earlier gaps lock later steps', () => {
  const w = L.identityWizard(wizData({ credential: { ok: false }, config: { authMode: 'google' } }));
  assert.strictEqual(w.current, 'connect');
  assert.ok(!w.steps.find((s) => s.id === 'address').available);
  assert.strictEqual(w.steps.find((s) => s.id === 'address').blockedBy, 'Connect the manager to authentik');
  const outpostWrong = L.identityWizard(wizData({ overview: { outpost: { authentikHost: '' } } }));
  assert.strictEqual(outpostWrong.current, 'address', 'the address step needs the outpost pointed at the public URL too');
});

test('wizard: resumes at the saved step if it is reachable, else at the first open step', () => {
  assert.strictEqual(L.identityWizard(wizData({ config: { wizardStep: 'address' } })).current, 'address');
  assert.strictEqual(L.identityWizard(wizData({ config: { wizardStep: 'apps' } })).current, 'owner', 'a locked saved step is not reopened');
  const done = wizData({ config: { authentik: { owner: { verifiedAt: '2026-10-25T10:00:00' } } }, apps: [{ protected: true, challenge: { State: 'auth' } }] });
  assert.strictEqual(L.identityWizard(done).current, 'done');
});

test('wizard: protection step and summary complete from verified ForwardAuth, skips and counts', () => {
  const owner = { config: { authentik: { owner: { verifiedAt: '2026-10-25T10:00:00' } } } };
  const svc = (n) => ({ name: n, isIdentity: false });
  const services = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map(svc).concat([{ name: 'authentik', isIdentity: true }]);
  const app = (n, ch, fa) => ({ service: n, protected: true, authentik: true, enabled: true, challenge: ch === undefined ? { State: 'auth' } : ch, forwardAuth: fa || { configured: true, loaded: true } });
  const all = wizData({ ...owner, services, apps: services.filter((s) => !s.isIdentity).map((s) => app(s.name)) });
  const w = L.identityWizard(all);
  const st = (x, id) => x.steps.find((s) => s.id === id);
  assert.ok(st(w, 'apps').done, 'all eight verified: step 8 complete');
  assert.strictEqual(st(w, 'apps').badge, '8/8 protected');
  assert.ok(st(w, 'done').done && w.complete, 'step 9 complete from verified state');
  assert.strictEqual(w.current, 'done');
  // Not verified yet (no probe), or a failing route: never complete.
  const unchecked = L.identityWizard({ ...all, apps: all.apps.map((x) => ({ ...x, challenge: null })) });
  assert.ok(!st(unchecked, 'apps').done && !unchecked.complete && unchecked.protection.state === 'checking');
  const failing = L.identityWizard({ ...all, apps: all.apps.map((x, i) => (i === 2 ? { ...x, challenge: { State: 'open' } } : x)) });
  assert.ok(!st(failing, 'apps').done && !failing.complete && failing.protection.failing.join() === 'c');
  const noMiddleware = L.identityWizard({ ...all, apps: all.apps.map((x, i) => (i === 0 ? { ...x, forwardAuth: { configured: false, loaded: false } } : x)) });
  assert.strictEqual(noMiddleware.protection.state, 'attention', 'a stored flag without the middleware in the route is not protection');
  // Some protected: complete, with an honest count.
  const some = L.identityWizard({ ...all, apps: all.apps.slice(0, 3) });
  assert.ok(st(some, 'apps').done && some.complete);
  assert.strictEqual(st(some, 'apps').badge, '3/8 protected');
  assert.strictEqual(some.protection.unprotected, 5);
  // Nothing protected: open (blocks the summary) until deliberately skipped; a skip is not shown as done.
  const none = L.identityWizard(wizData({ ...owner, services }));
  assert.ok(!st(none, 'apps').done && !st(none, 'apps').skipped && !none.complete && none.current === 'apps');
  const skipped = L.identityWizard(wizData({ ...owner, services, config: { ...owner.config, protectSkippedAt: '2026-10-26T09:00:00' } }));
  assert.ok(st(skipped, 'apps').skipped && !st(skipped, 'apps').done, 'skipped, not verified');
  assert.strictEqual(st(skipped, 'apps').badge, 'skipped');
  assert.ok(skipped.complete, 'a deliberate skip of the optional step does not block completion');
  // Revisiting a step changes nothing about completion.
  const revisit = L.identityWizard({ ...all, config: { ...all.config, wizardStep: 'apps' } });
  assert.strictEqual(revisit.current, 'apps');
  assert.ok(st(revisit, 'apps').done && revisit.complete);
});

test('wizard: adding Google later only adds steps; the owner then also has to sign in with Google', () => {
  const local = wizData({ config: { authentik: { owner: { verifiedAt: '2026-10-25T10:00:00' } } } });
  const g = L.identityWizard({ ...local, config: { ...local.config, authMode: 'google' } });
  assert.ok(!g.steps.find((s) => s.id === 'owner').done, 'a local verification does not count as a Google sign-in');
  const gv = L.identityWizard({ ...local, config: { ...local.config, authMode: 'google', authentik: { ...local.config.authentik, owner: { verifiedAt: 'x', subject: '1098' } } } });
  assert.ok(gv.steps.find((s) => s.id === 'owner').done);
  assert.strictEqual(g.current, 'google');
  const nb = L.wizardNeighbours(g, 'google');
  assert.strictEqual(nb.prev.id, 'address'); assert.strictEqual(nb.next.id, 'signin');
});

test('routing: browser endpoints versus local, LAN and Docker-only addresses (same rules as the server)', () => {
  assert.strictEqual(L.endpointKind('http://127.0.0.1:9000/application/o/authorize/'), 'loopback');
  assert.strictEqual(L.endpointKind('http://localhost:9000'), 'loopback');
  assert.strictEqual(L.endpointKind('http://192.168.1.20:9000'), 'private');
  assert.strictEqual(L.endpointKind('http://172.25.0.11:9000'), 'private');
  assert.strictEqual(L.endpointKind('http://authentik-server:9000'), 'internal-name');
  assert.strictEqual(L.endpointKind('http://host.docker.internal:4119'), 'internal-name');
  assert.strictEqual(L.endpointKind('https://203.0.113.7/'), 'public-ip');
  assert.strictEqual(L.endpointKind('https://auth.example.com/'), 'public');
  assert.strictEqual(L.endpointKind('not a url'), 'invalid');
});

test('routing: stage states never call configuration "verified"; every stage has five-part help', () => {
  assert.strictEqual(L.routingState('verified').label, 'Verified');
  assert.strictEqual(L.routingState('configured').label, 'Configured, not tested');
  assert.strictEqual(L.routingState('unknown-state').label, 'Configured, not tested');
  assert.strictEqual(L.routingEvidence('configuration'), 'Configuration only, not tested');
  assert.strictEqual(L.endpointAudience('browser').label, 'Browser endpoint');
  assert.strictEqual(L.endpointAudience('internal').label, 'Internal endpoint');
  const ids = ['public-url', 'dns', 'access', 'tunnel', 'router', 'middlewares', 'forwardauth', 'authentik', 'redirect', 'signin', 'callback', 'backend', 'networks'];
  for (const id of ids) {
    const t = L.routingHelp(id);
    assert.ok(t, `help for ${id}`);
    for (const k of ['what', 'why', 'dtc', 'you', 'fails']) assert.ok(t[k] && t[k].length > 20, `${id}.${k}`);
  }
  assert.ok(/127\.0\.0\.1:9000/.test(L.routingHelp('redirect').fails));
  assert.strictEqual(L.journeyPath('browser').label, 'Browser');
  assert.strictEqual(L.journeyPath('server').label, 'Server to server');
});

test('installed apps: lifecycle groups, termination and health wording', () => {
  const lc = { services: [
    { service: 'rocketchat', lifecycle: 'long-running', state: 'running', exitCode: null, health: 'healthy' },
    { service: 'nats', lifecycle: 'long-running', state: 'running', exitCode: null, health: 'none' },
    { service: 'mongodb-init', lifecycle: 'run-once', state: 'exited', exitCode: 0, expectedToExit: true, health: 'none' },
    { service: 'tool', lifecycle: 'unknown', state: 'exited', exitCode: 0, expectedToExit: null, health: 'none' },
  ] };
  assert.deepStrictEqual(L.serviceGroups(lc).map((g) => `${g.id}:${g.items.length}`), ['long-running:2', 'run-once:1', 'unknown:1']);
  assert.deepStrictEqual(L.serviceGroups({ services: [lc.services[0]] }).map((g) => g.id), ['long-running']);
  assert.strictEqual(L.terminationText(lc.services[0]), 'Running');
  assert.strictEqual(L.terminationText(lc.services[2]), 'Exit code 0 (expected)');
  assert.strictEqual(L.terminationText(lc.services[3]), 'Exit code 0 (not known whether expected)');
  assert.strictEqual(L.terminationText({ state: 'exited', exitCode: 137, expectedToExit: false }), 'Exit code 137 (not expected)');
  assert.strictEqual(L.healthText(lc.services[1]), 'No health check');
  assert.strictEqual(L.healthText(lc.services[0]), 'Health check: healthy');
  assert.strictEqual(L.deploymentState('running').tone, 'ok');
  assert.strictEqual(L.deploymentState('failed').tone, 'err');
  assert.strictEqual(L.deploymentState('prepared').label, 'Prepared, not started');
  assert.strictEqual(L.deploymentState('nope').tone, 'neutral');
  assert.strictEqual(L.statusTone({ tone: 'warn' }), 'warn');
  assert.strictEqual(L.statusTone({ tone: '<script>' }), 'neutral');
  assert.strictEqual(L.roleSource('inferred'), 'inferred from its restart policy');
});

test('installed apps: images, catalog install state and instance titles', () => {
  const d = 'a'.repeat(64);
  assert.strictEqual(L.shortImage(`registry.rocket.chat/rocketchat/rocket.chat:8.9.0@sha256:${d}`), 'registry.rocket.chat/rocketchat/rocket.chat:8.9.0 @ sha256:aaaaaaaaaaaa…');
  assert.strictEqual(L.shortImage('nats:2.11-alpine'), 'nats:2.11-alpine');
  assert.deepStrictEqual(L.catalogInstallState({ instances: [] }), { installed: false, text: '' });
  assert.strictEqual(L.catalogInstallState({ instances: [{ project: 'a' }] }).text, 'Installed');
  assert.strictEqual(L.catalogInstallState({ instances: [{ project: 'a' }, { project: 'b' }] }).text, 'Installed: 2 instances');
  assert.strictEqual(L.instanceTitle({ name: 'Rocket.Chat', label: 'Testing' }), 'Rocket.Chat (Testing)');
  assert.strictEqual(L.instanceTitle({ name: 'Rocket.Chat', label: '' }), 'Rocket.Chat');
});

test('new app: step completion from the draft, acknowledgements, access and sign-in; untested stages never count as passed', () => {
  const findings = [{ id: 'socket:web', severity: 'high' }, { id: 'registry:web', severity: 'review' }, { id: 'unverified', severity: 'info' }, { id: 'x', severity: 'block' }];
  assert.deepStrictEqual(L.provisionAckIds(findings), ['socket:web', 'registry:web']);
  const draft = { deployable: true, findings };
  const S = (w, id) => w.steps.find((x) => x.id === id);
  let w = L.provisionWizard({});
  assert.strictEqual(w.current, 'container');
  assert.deepStrictEqual(w.steps.map((x) => x.id), ['container', 'stack', 'storage', 'proxy', 'auth', 'publish', 'review', 'verify'], 'one wizard, eight stages');
  assert.ok(!S(w, 'proxy').available && !S(w, 'stack').available, 'routing and the stack view are locked without a draft');
  w = L.provisionWizard({ draft, acknowledged: ['socket:web'] });
  assert.ok(!S(w, 'container').done); assert.deepStrictEqual(w.pendingAcks, ['registry:web']); assert.match(S(w, 'container').missing, /1 item/);
  assert.ok(S(w, 'stack').available && !S(w, 'stack').done && !S(w, 'proxy').available, 'the stack and storage can be inspected before the source is complete; routing cannot');
  w = L.provisionWizard({ draft: { deployable: false, findings: [] } });
  assert.ok(!S(w, 'container').done, 'an undeployable draft never completes step 1');
  const acked = { draft, acknowledged: ['socket:web', 'registry:web'] };
  w = L.provisionWizard({ ...acked, access: 'local', auth: 'none' });
  assert.deepStrictEqual(w.steps.map((x) => x.done), [true, true, true, true, true, true, false, false]); assert.strictEqual(w.current, 'review');
  w = L.provisionWizard({ ...acked, access: 'public', hostname: 'not a host', auth: 'authentik' });
  assert.ok(!S(w, 'proxy').done); assert.match(S(w, 'proxy').missing, /host name/);
  w = L.provisionWizard({ ...acked, access: 'public', hostname: 'notes.example.com', auth: 'none' });
  assert.ok(S(w, 'proxy').done && !S(w, 'auth').done && !S(w, 'publish').available, "a public address never completes with 'no sign-in'");
  const verified = { ok: true, journal: { verification: [{ stage: 'backend', status: 'passed' }, { stage: 'router', status: 'passed' }] } };
  w = L.provisionWizard({ ...acked, access: 'public', hostname: 'notes.example.com', auth: 'authentik', result: verified });
  assert.ok(w.steps.every((x) => x.done));
  w = L.provisionWizard({ ...acked, access: 'public', hostname: 'notes.example.com', auth: 'authentik', result: { ok: true, journal: { verification: [{ stage: 'backend', status: 'passed' }, { stage: 'authorized-access', status: 'not-tested' }] } } });
  assert.ok(S(w, 'review').done && !S(w, 'verify').done && w.current === 'verify', 'a deployment with untested checks is not "verified"');
  w = L.provisionWizard({ ...acked, access: 'local', auth: 'authentik' });
  assert.ok(!S(w, 'auth').done, 'authentik needs a route');
  const pr = L.provisionProgress({ ok: true, journal: { stages: [{ stage: 'install', status: 'passed' }, { stage: 'backend', status: 'passed' }, { stage: 'route', status: 'passed' }, { stage: 'authentication', status: 'failed' }],
    verification: [{ stage: 'containers', status: 'passed' }, { stage: 'dependencies', status: 'passed' }, { stage: 'backend', status: 'passed' }] } }, { access: 'lan', auth: 'authentik' });
  const ps = Object.fromEntries(pr.items.map((x) => [x.id, x.state]));
  assert.deepStrictEqual(ps, { planned: 'done', installing: 'done', running: 'done', healthy: 'done', routed: 'done', authenticated: 'failed', published: 'skipped', verified: 'failed' });
  assert.ok(pr.failed);
  const run = L.provisionProgress({ ok: true, journal: { stages: [{ stage: 'install', status: 'passed' }], verification: [{ stage: 'containers', status: 'passed' }] } }, { access: 'local', auth: 'none' });
  assert.strictEqual(run.items.find((x) => x.id === 'healthy').state, 'pending', 'a running container is not healthy until its checks pass');
  assert.strictEqual(L.provisionComposeFile('database'), 'compose.database.yaml'); assert.strictEqual(L.provisionComposeFile('app'), 'compose.yaml'); assert.strictEqual(L.provisionComposeFile('init'), 'compose.setup.yaml');
  const v = L.provisionVerdict([{ status: 'passed' }, { status: 'not-tested' }, { status: 'not-applicable' }]);
  assert.deepStrictEqual(v.counts, { passed: 1, failed: 0, notTested: 1, notApplicable: 1 }); assert.strictEqual(v.state, 'partial');
  assert.strictEqual(L.provisionVerdict([{ status: 'passed' }, { status: 'failed' }]).state, 'attention');
  assert.strictEqual(L.provisionVerdict([{ status: 'passed' }, { status: 'not-applicable' }]).state, 'verified');
  assert.strictEqual(L.suggestProvisionHostname('Uptime Kuma', ['example.com']), 'uptime-kuma.example.com');
  assert.strictEqual(L.suggestProvisionHostname('x', []), '');
});

test('launcher: default deployment, start notices and autostart text', () => {
  assert.ok(L.samePath('C:\\Users\\me\\proxy\\', 'c:\\users\\ME\\proxy'));
  assert.ok(!L.samePath('C:\\a', 'C:\\ab') && !L.samePath('', ''));
  const l = { available: true, startMode: 'default', notice: '', defaultDeployment: { path: 'C:\\p\\traefik-proxy', usable: true } };
  const proj = (path, kind = 'manager', usable = true) => ({ summary: { path, kind, usable } });
  assert.strictEqual(L.launcherDefaultAction(l, proj('c:\\p\\traefik-proxy\\')), 'is-default');
  assert.strictEqual(L.launcherDefaultAction(l, proj('C:\\p\\other')), 'make-default');
  assert.strictEqual(L.launcherDefaultAction(l, proj('C:\\p\\draft', 'draft', true)), 'none', 'only installed deployments can be the default');
  assert.strictEqual(L.launcherDefaultAction({ available: false }, proj('C:\\p\\other')), 'none', 'not started by the launcher');
  assert.strictEqual(L.launcherNotice(l), null);
  const rec = L.launcherNotice({ ...l, startMode: 'recovery', notice: 'Recovery mode: no deployment was opened.' });
  assert.strictEqual(rec.title, 'Recovery mode');
  assert.strictEqual(rec.text, 'No deployment was opened.', 'the title is not repeated in the text');
  assert.strictEqual(L.launcherNotice({ ...l, notice: 'gone', defaultDeployment: { path: 'C:\\gone', usable: false } }).tone, 'warn');
  assert.strictEqual(L.launcherNotice({ ...l, notice: 'Port 8190 is in use' }).tone, 'info');
  assert.strictEqual(L.autostartText(null).text, 'Off');
  assert.strictEqual(L.autostartText({ enabled: true, allowedByWindows: false, pointsHere: true }).tone, 'warn');
  assert.strictEqual(L.autostartText({ enabled: true, allowedByWindows: true, pointsHere: false }).tone, 'warn');
  assert.strictEqual(L.autostartText({ enabled: true, allowedByWindows: true, pointsHere: true, windowless: true }).tone, 'ok');
});

test('app catalog: access, sign-in fit, host compatibility, findings and backups', () => {
  assert.strictEqual(L.catalogAccessText({ access: { localUrl: 'http://127.0.0.1:3001/', hostnames: [] } }).text, 'This PC only');
  assert.strictEqual(L.catalogAccessText({ prepared: true, access: {} }).text, 'Prepared, not started');
  assert.strictEqual(L.catalogAccessText({ access: { hostnames: ['a.example.com'], public: true, protected: false } }).tone, 'warn', 'public without sign-in is flagged');
  assert.match(L.catalogAccessText({ access: { hostnames: ['a.example.com'], public: true, protected: true } }).text, /sign-in required/);
  assert.match(L.catalogAccessText({ access: { hostnames: ['a.lan'], public: false } }).text, /^Routed: a\.lan/);
  assert.strictEqual(L.authFitText({ forwardAuth: 'caution' }).tone, 'warn');
  assert.strictEqual(L.authFitText(null).text, 'Sign-in: not assessed');
  assert.strictEqual(L.compatSummary([{ label: 'CPU architecture', state: 'ok', message: 'ok' }]).tone, 'ok');
  assert.strictEqual(L.compatSummary([{ label: 'CPU architecture', state: 'ok' }, { label: 'GPU', state: 'warning', message: 'x' }]).text, 'Limited: GPU');
  assert.strictEqual(L.compatSummary([{ label: 'CPU architecture', state: 'failed', message: 'arm only' }, { label: 'GPU', state: 'warning' }]).tone, 'err');
  assert.deepStrictEqual(L.sortFindings([{ level: 'ok' }, { level: 'error' }, { level: 'warning' }]).map((f) => f.level), ['error', 'warning', 'ok']);
  assert.strictEqual(L.findingTone('error'), 'err');
  assert.strictEqual(L.backupTitle({ id: '20261116-201500', reason: 'before-update', volumes: [{ sizeMB: 1.5 }, { sizeMB: 2 }] }), '2026-11-16 20:15 · Before an update · 2 volumes (3.5 MB)');
});

test('catalog: one state per card (managed, detected, unsupported, manual setup, available) and the state filter', () => {
  const ok = { installable: true, platform: { support: 'supported', installable: true }, compatibility: [{ label: 'CPU architecture', state: 'ok' }] };
  assert.strictEqual(L.catalogStatus(ok).key, 'available');
  assert.strictEqual(L.catalogStatus({ ...ok, instances: [{ project: 'a' }], detected: [{ project: 'b' }] }).key, 'managed', 'a managed instance wins');
  const det = L.catalogStatus({ ...ok, detected: [{ project: 'docker-compose' }] });
  assert.strictEqual(det.key, 'detected'); assert.ok(det.installed, 'detected counts as already installed');
  assert.strictEqual(L.catalogStatus({ ...ok, compatibility: [{ label: 'CPU architecture', state: 'failed' }] }).key, 'unsupported');
  assert.strictEqual(L.catalogStatus({ installable: false, installNote: 'x', platform: { support: 'supported', installable: false } }).key, 'manual');
  assert.strictEqual(L.catalogStatus({ installable: true, platform: { support: 'unsupported', installable: false } }).key, 'unsupported');
  assert.ok(L.catalogStatus({ ...ok, manualSetup: ['Claim the server'] }).manualSteps);
  assert.ok(L.catalogStatusMatches({ ...ok, detected: [{ project: 'x' }] }, 'installed'));
  assert.ok(!L.catalogStatusMatches(ok, 'installed'));
  assert.ok(L.catalogStatusMatches({ ...ok, manualSetup: ['x'] }, 'manual'), 'installable apps with setup steps appear under manual setup');
  assert.ok(L.catalogStatusMatches(ok, ''));
  assert.strictEqual(L.verificationText({ static: 'passed', live: 'passed', date: '2026-11-17' }).text, 'Live-tested 2026-11-17');
  assert.strictEqual(L.verificationText({ static: 'passed', live: 'not-run' }).tone, 'warn');
  assert.match(L.verificationText({ static: 'passed', live: 'not-run' }).text, /not live-tested/);
  assert.strictEqual(L.verificationText(null).text, 'Verification: not recorded');
});

console.log(`\n${passed} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
