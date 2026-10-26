'use strict';
// Pure presentation logic shared by the web UI (window.TPMLogic) and the developer tests (Node: require()).
// No DOM access and no network: everything here is deterministic and unit-tested in tests\ui-logic.test.js.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.TPMLogic = api;
})(typeof self !== 'undefined' ? self : this, () => {
  // --- Detail levels -------------------------------------------------------------------------------------------
  // Presentation only: a level decides what is shown, never what is allowed, validated or sent to the server.
  const LEVELS = ['beginner', 'intermediate', 'advanced', 'expert'];
  const LEVEL_TITLES = { beginner: 'Beginner', intermediate: 'Intermediate', advanced: 'Advanced', expert: 'Expert' };
  const DEFAULT_LEVEL = 'intermediate';

  function normalizeLevel(value) { return LEVELS.includes(value) ? value : DEFAULT_LEVEL; }
  function levelIndex(level) { return LEVELS.indexOf(normalizeLevel(level)); }
  // True when content marked "show from minLevel" is visible at the current level.
  function isVisibleAt(minLevel, current) { return levelIndex(current) >= levelIndex(minLevel || 'beginner'); }

  // --- Naming ----------------------------------------------------------------------------------------------------
  // A DNS label from a display name: "Notflix" -> "notflix", "Home Assistant!" -> "home-assistant".
  function suggestLabel(name, maxLength = 63) {
    let s = String(name || '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '');
    s = s.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').replace(/-{2,}/g, '-');
    if (s.length > maxLength) s = s.slice(0, maxLength).replace(/-+$/g, '');
    return s;
  }
  // Service ids (registry names) are at most 40 characters.
  function suggestServiceName(displayName) { return suggestLabel(displayName, 40); }

  // An auto-named field (a subdomain derived from a name). Once the user edits it, later name changes no longer
  // overwrite it until the user resets automatic naming.
  function autoName(source, current) { return { value: suggestLabel(source), custom: false, ...(current || {}) }; }
  function autoNameFromSource(state, source) { return state.custom ? state : { value: suggestLabel(source), custom: false }; }
  function autoNameEdit(state, value, source) {
    const v = String(value || '').trim().toLowerCase();
    return { value: v, custom: v !== suggestLabel(source) };
  }
  function autoNameReset(source) { return { value: suggestLabel(source), custom: false }; }

  const LABEL_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
  function isValidSubdomain(value) {
    if (!value) return false;
    return String(value).split('.').every((p) => LABEL_RE.test(p)) && String(value).length <= 200;
  }
  function joinHostname(sub, domain) { return sub ? `${sub}.${domain}` : domain; }
  // Splits a hostname into subdomain + the longest matching allowed domain.
  function splitHostname(hostname, domains) {
    const hn = String(hostname || '').toLowerCase();
    const zone = (domains || []).map((d) => (typeof d === 'string' ? d : d.name))
      .filter((z) => hn === z || hn.endsWith(`.${z}`)).sort((a, b) => b.length - a.length)[0];
    if (zone) return { sub: hn === zone ? '' : hn.slice(0, hn.length - zone.length - 1), domain: zone, allowed: true };
    const parts = hn.split('.');
    if (parts.length <= 2) return { sub: '', domain: hn, allowed: false };
    return { sub: parts[0], domain: parts.slice(1).join('.'), allowed: false };
  }

  // --- Targets -------------------------------------------------------------------------------------------------------
  const PRIVATE_RE = /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/;
  // Where a backend runs, from what the user typed: docker (container name), host (this PC) or lan.
  function detectTarget(hostValue, type = 'auto') {
    const v = String(hostValue || '').trim().toLowerCase();
    if (type && type !== 'auto') return type;
    if (/^(localhost|127\.\d+\.\d+\.\d+|host\.docker\.internal|::1)$/.test(v)) return 'host';
    if (/^\d+\.\d+\.\d+\.\d+$/.test(v) || v.includes('.')) return 'lan';
    return 'docker';
  }
  function isPrivateIPv4(v) { return PRIVATE_RE.test(String(v || '')); }

  // --- Backend selection ("How should Traefik connect to this application?") -----------------------------------------
  // The wizard's three connection options and the registry's target types. "this-computer" is Windows itself. The option
  // helps discovery and recommendations; it never restricts the address the user may choose.
  const BACKEND_QUESTION = 'How should Traefik connect to this application?';
  const WHERE = ['docker', 'this-computer', 'lan'];
  function whereFromTargetType(type) { return type === 'docker' ? 'docker' : type === 'host' ? 'this-computer' : 'lan'; }
  function isLoopbackHost(v) { return /^(127\.\d+\.\d+\.\d+|localhost|::1|0\.0\.0\.0)$/.test(String(v || '').trim().toLowerCase()); }
  // "http://127.0.0.1:4119/x" -> { scheme: 'http', host: '127.0.0.1', port: 4119 }; "4119" -> { host: '', port: 4119 }.
  function parseBackendAddress(text) {
    let v = String(text || '').trim();
    let scheme = '';
    const m = /^(https?|h2c):\/\//i.exec(v);
    if (m) { scheme = m[1].toLowerCase(); v = v.slice(m[0].length); }
    v = v.split(/[/?#]/)[0];
    if (/^\d{1,5}$/.test(v)) return { scheme, host: '', port: Number(v) };
    const hp = /^([^:]+):(\d{1,5})$/.exec(v);
    if (hp) return { scheme, host: hp[1].toLowerCase(), port: Number(hp[2]) };
    return { scheme, host: v.toLowerCase(), port: 0 };
  }
  function sameTarget(a, b) { return !!(a && b && a.type === b.type && a.host === b.host && Number(a.port) === Number(b.port)); }
  function targetUrl(t, protocol) { return t ? `${protocol || t.protocol || 'http'}://${t.host}:${t.port}` : ''; }
  // The candidates as the form lists them: one per address, the address the user entered (or their custom address)
  // first, then the recommendation, then other discovered paths. role -> the label shown next to each.
  const ROLE_LABELS = { entered: 'Address you entered', custom: 'Custom address', recommended: 'Recommended alternative', alternative: 'Discovered alternative' };
  function backendCandidates(resolution) {
    const res = resolution || {};
    const rank = { custom: 0, entered: 1, recommended: 2, alternative: 3 };
    const seen = new Set();
    const rec = res.recommended || null;
    return (res.candidates || []).filter((c) => { if (seen.has(c.url)) return false; seen.add(c.url); return true; })
      .map((c) => ({ ...c, role: c.role || 'alternative', isRecommended: !!(rec && c.url === rec.url) }))
      .sort((a, b) => (rank[a.role] ?? 3) - (rank[b.role] ?? 3))
      .map((c) => ({ ...c, label: c.role === 'recommended' && !(res.candidates || []).some((x) => x.role === 'entered' || x.role === 'custom') ? 'Recommended' : ROLE_LABELS[c.role] || ROLE_LABELS.alternative }));
  }
  // Which backend the form uses after the resolver answered. A recommendation never replaces a choice:
  //   - custom address (Advanced/Expert override): kept when it is valid, else nothing is selected;
  //   - an existing service's backend, or one the user picked: kept until the user picks another;
  //   - exactly one usable candidate: selected automatically;
  //   - an address the user typed that can work: selected as typed (the recommendation is offered next to it);
  //   - several discovered paths and nothing typed: the user chooses (needsChoice), each option has a control.
  function chooseBackend(state, resolution) {
    const st = state || {};
    const res = resolution || {};
    if (st.override) return res.override && res.custom && !res.custom.rejected ? { target: res.custom, source: 'override', needsChoice: false } : { target: null, source: 'override', needsChoice: false };
    if ((st.source === 'existing' || st.source === 'chosen') && st.target) return { target: st.target, source: st.source, needsChoice: false };
    const usable = backendCandidates(res).filter((c) => !c.rejected);
    if (!usable.length) return { target: null, source: '', needsChoice: false };
    if (usable.length === 1) return { target: usable[0], source: 'auto', needsChoice: false };
    const entered = usable.find((c) => c.role === 'entered');
    if (entered) return { target: entered, source: 'entered', needsChoice: false };
    if (res.ambiguous) return { target: null, source: '', needsChoice: true };
    return { target: usable.find((c) => c.isRecommended) || usable[0], source: 'auto', needsChoice: false };
  }
  // Notices the user dismissed stay hidden until their condition (what they are about) changes; restrictions always show.
  // ctx { target, verification }: a recommendation already followed is hidden, and connectivity warnings disappear once
  // the selected backend answered a connection test (the problem they warn about did not stop it).
  function visibleGuidance(list, dismissed, ctx) {
    const d = dismissed || {};
    const c = ctx || {};
    const passed = !!(c.verification && (c.verification.state === 'ok' || c.verification.state === 'auth') && c.target && c.verification.targetUrl === targetUrl(c.target, c.verification.target && c.verification.target.protocol));
    return (list || []).filter((g) => {
      if (g.severity === 'error') return true;
      if (d[g.condition]) return false;
      if (g.category === 'connectivity' && passed) return false;
      if (g.category === 'recommendation' && c.recommended && c.target && sameTarget(c.recommended, c.target)) return false;
      return true;
    });
  }
  // A complete backend URL typed by an Advanced or Expert user: scheme, host and port; a path is refused (Traefik sends
  // the request path unchanged) and loopback is refused (inside Traefik it is Traefik).
  function parseBackendUrl(text) {
    const v = String(text || '').trim();
    if (!v) return { ok: false, error: 'Enter a complete backend URL, e.g. http://10.10.0.8:8080.' };
    const m = /^(https?|h2c):\/\/(\[[^\]]+\]|[^/:?#\s]+)(?::(\d{1,5}))?([/?#].*)?$/i.exec(v);
    if (!m) return { ok: false, error: 'Enter a complete backend URL with its protocol, e.g. http://10.10.0.8:8080.' };
    const scheme = m[1].toLowerCase(); const host = m[2].toLowerCase();
    const port = m[3] ? Number(m[3]) : scheme === 'https' ? 443 : 80;
    const path = m[4] && m[4] !== '/' ? m[4] : '';
    if (!(port >= 1 && port <= 65535)) return { ok: false, error: 'The port must be from 1 to 65535.' };
    if (isLoopbackHost(host)) return { ok: false, error: `${host} inside Traefik's container is Traefik itself: use host.docker.internal for an app on this computer.` };
    if (path) return { ok: false, error: 'A base path in the backend URL is not supported: use Path prefix under Advanced routing instead.' };
    return { ok: true, scheme, host, port, path: '', url: `${scheme}://${host}:${port}` };
  }
  // The validation message when no usable backend is selected, or ''.
  function backendValidation(f) {
    const s = f || {};
    if (s.override) { const p = parseBackendUrl(s.custom); if (!p.ok) return p.error; }
    if (s.target) return '';
    const usable = s.backend ? backendCandidates(s.backend.resolution).filter((c) => !c.rejected) : [];
    if (usable.length) return 'Select the address Traefik should use to reach your application.';
    return s.where === 'docker' ? 'Choose the container and its port.' : 'Enter the address and port of the application.';
  }
  // The sentence that heads a connection test result.
  function backendHeadline(v, target) {
    if (!v) return '';
    const where = target ? `${target.host}:${target.port}` : 'the backend';
    if (v.state === 'ok') return 'Traefik successfully connected to the selected application.';
    if (v.state === 'auth') return 'Traefik reached the selected application; it asks for a login.';
    if (['timeout', 'refused', 'dns', 'error'].includes(v.result)) return `Traefik could not connect to ${where}. Test another address or explicitly save the route without verification.`;
    if (v.result === 'host-rejected') return `Traefik reached ${where}, but the application rejected the public hostname.`;
    if (v.state === 'skipped') return 'The connection test could not run.';
    return `Traefik reached ${where}, but the answer needs attention.`;
  }
  // A verification result -> how it is shown. Green only for an application answer (verified, or a redirect to a page
  // that answered); a login is "auth"; everything else is a warning or a failure; no test is neutral.
  function backendStatus(v) {
    if (!v) return { key: 'not-tested', label: 'Not tested', tone: 'neutral', icon: 'minus' };
    const tone = v.state === 'ok' ? 'ok' : v.state === 'auth' ? 'auth' : v.state === 'warning' ? 'warn' : v.state === 'failed' ? 'err' : 'neutral';
    return { key: v.result || 'not-tested', label: v.label || 'Not tested', tone, icon: { ok: 'check', auth: 'lock', warn: 'alert', err: 'x' }[tone] || 'minus' };
  }

  // --- Review state -----------------------------------------------------------------------------------------------
  // A short, stable fingerprint of what the user reviewed. When the content changes, the review is invalidated.
  function stableStringify(value) {
    if (value === null || typeof value !== 'object') return JSON.stringify(value === undefined ? null : value);
    if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`).join(',')}}`;
  }
  function fingerprint(value) {
    const s = stableStringify(value);
    let h1 = 0x811c9dc5, h2 = 0x01000193;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      h1 = Math.imul(h1 ^ c, 16777619) >>> 0;
      h2 = Math.imul(h2 + c, 2246822519) >>> 0;
    }
    return h1.toString(36) + h2.toString(36);
  }
  // reviewed: the user reviewed exactly this content. stale: they reviewed an earlier version. unreviewed: never.
  function reviewState(store, id, fp) {
    if (!store || !Object.prototype.hasOwnProperty.call(store, id)) return 'unreviewed';
    return store[id] === fp ? 'reviewed' : 'stale';
  }
  function markReviewed(store, id, fp) { return { ...(store || {}), [id]: fp }; }
  function reopenReview(store, id) { const next = { ...(store || {}) }; delete next[id]; return next; }

  // --- Status vocabulary ------------------------------------------------------------------------------------------
  // Validated (checked by the app), Reviewed (seen by the user), Applied (executed), Healthy (runtime check passed),
  // Warning, Failed, plus neutral states. Reviewing never changes a validation status.
  const STATUS = {
    validated: { label: 'Validated', tone: 'ok', icon: 'check' },
    reviewed: { label: 'Reviewed', tone: 'info', icon: 'eye' },
    applied: { label: 'Applied', tone: 'ok', icon: 'check-double' },
    healthy: { label: 'Healthy', tone: 'ok', icon: 'pulse' },
    warning: { label: 'Warning', tone: 'warn', icon: 'alert' },
    failed: { label: 'Failed', tone: 'err', icon: 'x' },
    pending: { label: 'Pending', tone: 'neutral', icon: 'clock' },
    info: { label: 'Note', tone: 'neutral', icon: 'info' },
    skipped: { label: 'Skipped', tone: 'neutral', icon: 'minus' },
    unknown: { label: 'Not checked', tone: 'neutral', icon: 'minus' },
    stale: { label: 'Changed since review', tone: 'warn', icon: 'refresh' },
    // Attaching an existing deployment: found in files (detected), confirmed live (verified), absent (missing),
    // credentials to reconnect, newer application files available.
    detected: { label: 'Detected', tone: 'info', icon: 'eye' },
    verified: { label: 'Verified', tone: 'ok', icon: 'check' },
    missing: { label: 'Missing', tone: 'err', icon: 'x' },
    reconnect: { label: 'Needs reconnection', tone: 'warn', icon: 'key' },
    upgrade: { label: 'Upgrade available', tone: 'info', icon: 'download' },
  };
  // Server review items use ok/failed/warning/pending/info; map them onto the vocabulary for a given stage.
  function statusFromReview(state, stage) {
    if (state === 'ok') return stage === 'applied' ? 'applied' : stage === 'verified' ? 'healthy' : 'validated';
    if (state === 'failed') return 'failed';
    if (state === 'warning') return 'warning';
    if (state === 'pending') return 'pending';
    return 'info';
  }
  // The worst status of a list (failed > warning > pending > ok-ish).
  function worstStatus(list) {
    const rank = { failed: 4, missing: 4, warning: 3, stale: 3, reconnect: 3, pending: 2, upgrade: 1, unknown: 1, info: 0, skipped: 0, validated: 0, reviewed: 0, applied: 0, healthy: 0, detected: 0, verified: 0 };
    let worst = 'validated';
    for (const s of list || []) if ((rank[s] || 0) > (rank[worst] || 0)) worst = s;
    return worst;
  }

  // --- Formatting -------------------------------------------------------------------------------------------------
  function formatBytes(n) {
    const v = Number(n) || 0;
    if (v < 1024) return `${v} B`;
    if (v < 1048576) return `${(v / 1024).toFixed(1)} KB`;
    return `${(v / 1048576).toFixed(1)} MB`;
  }
  function splitEmails(text) { return String(text || '').split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean); }
  const EMAIL_RE = /^[A-Za-z0-9._%+'-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}$/;
  function isEmail(v) { return EMAIL_RE.test(String(v || '')); }

  // --- Docker discovery ------------------------------------------------------------------------------------------------
  // An application name for a discovered container: its Compose service, else its name without the Compose project
  // prefix and replica suffix ("media-prowlarr-1" -> "prowlarr"), else the image name.
  function suggestAppName(c) {
    const compose = (c && c.compose) || {};
    let base = compose.service || (c && c.name) || '';
    if (!compose.service && compose.project && base.startsWith(`${compose.project}-`)) base = base.slice(compose.project.length + 1);
    base = base.replace(/[-_]\d+$/, '');
    if (!base && c && c.image) base = String(c.image).split('@')[0].split('/').pop().split(':')[0];
    return suggestLabel(base);
  }
  // "uptime-kuma" -> "Uptime Kuma".
  function displayNameFromLabel(label) { return String(label || '').split('-').filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(' '); }
  // The port to preselect: the best HTTP(S) candidate, else the first TCP port that is not blocked, else none.
  function choosePort(ports) {
    const list = (ports || []).filter((p) => p.proto === 'tcp' && p.guess !== 'blocked');
    return list.find((p) => p.guess === 'http' || p.guess === 'https') || list.find((p) => p.guess === 'unknown') || null;
  }
  // How Traefik will reach a container: over the shared network, or through a port published on this PC.
  function reachOptions(c, port) {
    const pub = (c.published || []).find((p) => p.port === port && p.proto === 'tcp' && p.hostPort > 0);
    if (c.onProxyNetwork) return { default: 'network', options: ['network'], hostPort: pub ? pub.hostPort : 0 };
    return { default: pub && pub.hostIp !== '127.0.0.1' ? 'hostport' : 'attach', options: pub ? ['attach', 'hostport'] : ['attach'], hostPort: pub ? pub.hostPort : 0, loopbackOnly: !!(pub && pub.hostIp === '127.0.0.1') };
  }

  // --- Infrastructure Explorer ---------------------------------------------------------------------------------------
  // A component carries six independent dimensions (true / false / null = not checked). The summary never turns
  // green from configuration alone: "verified" needs a verification, "running" a live observation.
  const DIMENSIONS = [
    ['detected', 'Detected'], ['configured', 'Configured'], ['running', 'Running'],
    ['reachable', 'Reachable'], ['authenticated', 'Authenticated'], ['verified', 'Verified'],
  ];
  const COMPONENT_STATUS = {
    off: { tone: 'off', label: 'Not used', icon: 'minus' },
    failed: { tone: 'err', label: 'Problem', icon: 'x' },
    verified: { tone: 'ok', label: 'Verified', icon: 'check-double' },
    running: { tone: 'live', label: 'Running', icon: 'check' },
    configured: { tone: 'neutral', label: 'Configured', icon: 'clock' },
    detected: { tone: 'neutral', label: 'Detected', icon: 'eye' },
    unknown: { tone: 'neutral', label: 'Not checked', icon: 'minus' },
  };
  function componentStatus(c) {
    if (!c || c.applicable === false) return { key: 'off', ...COMPONENT_STATUS.off };
    const d = c.dims || {};
    const vals = DIMENSIONS.map(([k]) => d[k]);
    if (vals.some((v) => v === false)) return { key: 'failed', ...COMPONENT_STATUS.failed };
    const key = d.verified === true ? 'verified' : d.running === true || d.reachable === true ? 'running'
      : d.configured === true ? 'configured' : d.detected === true ? 'detected' : 'unknown';
    return { key, ...COMPONENT_STATUS[key] };
  }
  // Index (in path order) of the first component that blocks requests, or -1. Components that are not used are skipped.
  function firstBlocked(components, order) {
    const byId = {};
    for (const c of components || []) byId[c.id] = c;
    for (let i = 0; i < order.length; i += 1) { const c = byId[order[i]]; if (c && componentStatus(c).key === 'failed') return i; }
    return -1;
  }

  // --- Identity & Access ------------------------------------------------------------------------------------------
  // States of identity setup steps and components (lib\IdentityProvider.psm1). "Verified" only ever comes from evidence
  // of a real sign-in; "Authentication required" means a login page answered, nobody signed in yet.
  const IDENTITY_STATES = {
    'not-configured': { label: 'Not configured', tone: 'neutral', icon: 'minus' },
    configured: { label: 'Configured', tone: 'info', icon: 'settings' },
    'awaiting-user': { label: 'Awaiting your action', tone: 'warn', icon: 'user' },
    reachable: { label: 'Reachable', tone: 'ok', icon: 'pulse' },
    'auth-required': { label: 'Authentication required', tone: 'auth', icon: 'lock' },
    verified: { label: 'Verified', tone: 'ok', icon: 'check' },
    failed: { label: 'Failed', tone: 'err', icon: 'x' },
    skipped: { label: 'Skipped', tone: 'neutral', icon: 'minus' },
  };
  function identityState(state) { return IDENTITY_STATES[state] || IDENTITY_STATES['not-configured']; }
  // Google's "Authorized redirect URI" for an authentik OAuth source (authentik: /source/oauth/callback/<slug>/).
  function googleRedirectUri(publicUrl, slug = 'google') {
    const base = String(publicUrl || '').trim().replace(/\/+$/, '');
    if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(base) || !/^[a-z0-9][a-z0-9_-]*$/i.test(slug)) return '';
    return `${base.toLowerCase()}/source/oauth/callback/${slug}/`;
  }
  const GOOGLE_CLIENT_ID = /^[0-9]{6,20}-[a-z0-9]{8,64}\.apps\.googleusercontent\.com$/;
  function isGoogleClientId(v) { return GOOGLE_CLIENT_ID.test(String(v || '').trim()); }
  // The Identity & Access wizard: which steps apply to the chosen sign-in path, which are complete (from what the
  // server observed, never from clicks), which can be opened (all earlier required steps complete) and where to resume.
  // d: GET /api/identity.
  function identityWizard(d) {
    const data = d || {};
    const cfg = data.config || {};
    const a = cfg.authentik || {};
    const mode = cfg.authMode || '';
    const google = mode === 'google';
    const inst = data.install;
    const health = data.health || {};
    const running = !!(inst && inst.server && inst.server.state === 'running');
    const tokenOk = !!(data.credential ? data.credential.ok : data.token && data.token.ok);
    const route = data.route;
    const outpost = data.overview && data.overview.outpost;
    const pub = String(a.publicUrl || '').replace(/\/+$/, '');
    const outpostOk = !!(outpost && pub && String(outpost.authentikHost || '').replace(/\/+$/, '') === pub);
    const owner = a.owner || {};
    const protectedOk = (Array.isArray(data.apps) ? data.apps : []).filter((x) => x.protected && x.challenge && x.challenge.State === 'auth').length;
    const steps = [
      { id: 'mode', title: 'Choose how people sign in', done: !!mode && cfg.provider === 'authentik' },
      { id: 'authentik', title: 'Install or connect authentik', done: running && !!health.Ready && health.Setup === 'done' },
      { id: 'connect', title: 'Connect the manager to authentik', done: tokenOk },
      { id: 'address', title: 'Public sign-in address', done: !!(route && route.exists && route.router === 'enabled' && outpostOk) },
      google ? { id: 'google', title: 'Register with Google', done: !!(data.google && data.google.source) } : null,
      google ? { id: 'signin', title: 'Sign-in page', done: !!(a.loginPage && a.loginPage.appliedAt), optional: true } : null,
      { id: 'owner', title: google ? 'Verify the owner with Google' : 'Verify the owner', done: google ? !!(owner.verifiedAt && owner.subject) : !!owner.verifiedAt },
      { id: 'apps', title: 'Protect applications', done: protectedOk > 0, optional: true },
      { id: 'done', title: 'Finished', done: false, final: true },
    ].filter(Boolean);
    let blockedBy = null;
    steps.forEach((s, i) => {
      s.number = i + 1;
      s.available = !blockedBy;
      s.blockedBy = blockedBy ? blockedBy.title : '';
      if (!s.done && !s.optional && !s.final && !blockedBy) blockedBy = s;
    });
    const byId = Object.fromEntries(steps.map((s) => [s.id, s]));
    const saved = cfg.wizardStep && byId[cfg.wizardStep] && byId[cfg.wizardStep].available ? cfg.wizardStep : '';
    const firstOpen = (steps.find((s) => s.available && !s.done && !s.final) || steps[steps.length - 1]).id;
    return { steps, mode, current: saved || firstOpen, firstOpen };
  }
  function wizardNeighbours(wiz, id) {
    const i = wiz.steps.findIndex((s) => s.id === id);
    return { prev: i > 0 ? wiz.steps[i - 1] : null, next: i >= 0 && i < wiz.steps.length - 1 ? wiz.steps[i + 1] : null, index: i };
  }

  // Status of a managed API credential (lib\CredentialManager.psm1). "unreachable" is about the server, not the token.
  const CREDENTIAL_STATUS = {
    valid: { label: 'Connected', tone: 'ok', icon: 'check' },
    insufficient: { label: 'Not usable: missing permissions', tone: 'err', icon: 'x' },
    rejected: { label: 'Rejected by the server', tone: 'err', icon: 'x' },
    expired: { label: 'Expired', tone: 'err', icon: 'x' },
    revoked: { label: 'Revoked', tone: 'err', icon: 'x' },
    unreadable: { label: 'Cannot be decrypted here', tone: 'err', icon: 'x' },
    unreachable: { label: 'Server unreachable', tone: 'warn', icon: 'alert' },
    missing: { label: 'Not connected', tone: 'warn', icon: 'key' },
    unknown: { label: 'Not checked yet', tone: 'neutral', icon: 'minus' },
  };
  function credentialStatus(view) { return CREDENTIAL_STATUS[(view && view.status) || 'missing'] || CREDENTIAL_STATUS.unknown; }

  // The first step that needs the user (or failed), else the first unfinished one.
  function identityNextStep(steps) {
    const list = Array.isArray(steps) ? steps : [];
    return list.find((s) => s.state === 'failed') || list.find((s) => s.state === 'awaiting-user') || null;
  }

  // --- Authentication & Routing ------------------------------------------------------------------------------------------
  // States of one stage of a request path (lib\RoutingModel.psm1). "verified" needs a real request; configuration that
  // exists is only "configured".
  const ROUTING_STATES = {
    verified: { label: 'Verified', tone: 'ok', icon: 'check', text: 'A real request proved this part works.' },
    configured: { label: 'Configured, not tested', tone: 'neutral', icon: 'minus', text: 'The configuration is in place; connectivity was not tested.' },
    warning: { label: 'Warning', tone: 'warn', icon: 'alert', text: 'Works, but not the way it should.' },
    failed: { label: 'Failed', tone: 'err', icon: 'x', text: 'This part does not work; see what to do.' },
    na: { label: 'Not applicable', tone: 'neutral', icon: 'minus', text: 'Not used by this application.' },
  };
  function routingState(state) { return ROUTING_STATES[state] || ROUTING_STATES.configured; }
  const ROUTING_EVIDENCE = { connectivity: 'Proven by a real request', configuration: 'Configuration only, not tested', none: '' };
  function routingEvidence(e) { return ROUTING_EVIDENCE[e] || ''; }
  // Browser endpoints are addresses a visitor's browser opens; internal endpoints are only used between containers.
  const ENDPOINT_AUDIENCE = {
    browser: { label: 'Browser endpoint', tone: 'info', icon: 'globe', text: 'An address your visitors\' browsers open. It must be a public HTTPS hostname.' },
    internal: { label: 'Internal endpoint', tone: 'neutral', icon: 'lock', text: 'Used only between containers inside Docker. Browsers never see it.' },
  };
  function endpointAudience(a) { return ENDPOINT_AUDIENCE[a] || ENDPOINT_AUDIENCE.internal; }
  // Mirrors Get-EndpointKind: which addresses a browser outside this PC can use.
  function endpointKind(url) {
    let u;
    try { u = new URL(url); } catch (e) { return 'invalid'; }
    if (!['http:', 'https:'].includes(u.protocol)) return 'invalid';
    const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
    if (/^(localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|::1|0\.0\.0\.0)$/.test(host) || host.endsWith('.localhost')) return 'loopback';
    if (/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(host) || /^(f[cd][0-9a-f]{2}|fe80):/.test(host)) return 'private';
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':')) return 'public-ip';
    if (!host.includes('.') || /\.(internal|local|lan|home|docker|localdomain|home\.arpa)$/.test(host)) return 'internal-name';
    return 'public';
  }
  // What each stage is, for the "?" next to it: what it does, why it is needed, what the manager configures, what you
  // may manage yourself, and the usual reasons it fails.
  const ROUTING_HELP = {
    'public-url': { title: 'Public address', what: 'The https:// address people type or bookmark, for example https://notflix.example.com.', why: 'It is the only address visitors need. Everything behind it stays private.', dtc: 'Publishes the hostname through Cloudflare when you choose "Publish".', you: 'Choose the hostname under a domain you own in Cloudflare.', fails: 'DNS not created yet (wait a few minutes), the tunnel is down, or a Cloudflare login is in front.' },
    dns: { title: 'DNS at Cloudflare', what: 'A DNS record that points the hostname at your Cloudflare Tunnel (a proxied CNAME).', why: 'Browsers find Cloudflare through DNS; Cloudflare then knows to use your tunnel.', dtc: 'Creates and checks the record with your Cloudflare API token.', you: 'Nothing, unless another record already uses the name.', fails: 'An older A/CNAME record with the same name, the record not proxied, or the domain not in your Cloudflare account.' },
    access: { title: 'Cloudflare Access', what: 'An optional Cloudflare login (Zero Trust) that runs at Cloudflare, before the request reaches your PC.', why: 'Useful for apps without a login. With authentik it is a second login and usually not wanted.', dtc: 'Creates an Access application when you tick "Require Cloudflare Access", and removes the one it created when you turn it off.', you: 'Access applications created by hand in Cloudflare Zero Trust are yours; the manager leaves them alone.', fails: 'A leftover Access application still asks for a Cloudflare login (the "challenge" before your sign-in page).' },
    tunnel: { title: 'Cloudflare Tunnel', what: 'An outbound connection from cloudflared on this PC to Cloudflare. Requests come back through it.', why: 'No port on your router has to be opened, and your home IP address stays hidden.', dtc: 'Adds a route hostname -> http://traefik:80 to the tunnel and runs cloudflared next to Traefik.', you: 'Nothing for routes. Tunnels created elsewhere keep their own settings.', fails: 'cloudflared not running or not connected, or the route pointing at localhost (inside the cloudflared container that is cloudflared itself).' },
    router: { title: 'Traefik router', what: 'A rule in Traefik, the reverse proxy: requests for this hostname go to this application.', why: 'One Traefik serves many applications; the hostname decides which one gets the request.', dtc: 'Writes traefik/dynamic/svc-<name>.yml from the Services page; Traefik loads it within seconds.', you: 'Nothing. Hand edits to generated files are overwritten.', fails: 'The route file is missing or invalid (Traefik answers 404), or the service is disabled.' },
    middlewares: { title: 'Middleware chain', what: 'Steps Traefik runs before passing a request on, in order: the sign-in check, then security headers.', why: 'The sign-in check must come first, so nothing reaches the application unchecked.', dtc: 'Puts the authentik check first when you protect an application.', you: 'Extra middlewares can be added on the Services page (advanced).', fails: 'The sign-in middleware missing or not first in the chain.' },
    forwardauth: { title: 'ForwardAuth (internal)', what: 'For every request Traefik asks authentik\'s outpost, server to server, whether the visitor may pass. The address is internal, like http://authentik-server:9000/...', why: 'Your application does not need to know about sign-in at all; Traefik enforces it.', dtc: 'Writes the ForwardAuth middleware with authentik\'s container name on the shared Docker network. If authentik does not answer, Traefik refuses the request (fails closed).', you: 'Keep authentik running: while it is down, protected applications refuse visitors instead of opening without sign-in.', fails: 'authentik stopped or not on the shared network (HTTP 500), or the address set to localhost, which inside Traefik\'s container is Traefik itself.' },
    authentik: { title: 'authentik application, provider and outpost', what: 'In authentik: an application (what users see), a proxy provider (how it is protected, with the public address) and the embedded outpost that answers Traefik.', why: 'authentik decides who may open what using its users, groups and access rules (policies).', dtc: 'Creates or reuses them once, assigns the provider to the embedded outpost, and starts new applications owner-only.', you: 'Users, groups and who may open which application: in authentik. The manager never overwrites access rules.', fails: 'Provider not assigned to the outpost (404), wrong external address, or the application deleted in authentik.' },
    redirect: { title: 'Redirect to the sign-in page', what: 'When you are not signed in, authentik answers Traefik with a redirect, and your browser opens the sign-in page.', why: 'The browser must be able to open that address from anywhere, so it has to be the public https://auth.<domain> address.', dtc: 'Points authentik\'s embedded outpost at the public sign-in address when you set it up or protect an application.', you: 'Nothing. If you change the outpost in authentik, keep its authentik_host at the public address.', fails: 'The outpost set to http://127.0.0.1:9000 or another local address: it works on the authentik PC only; everywhere else the browser cannot connect.' },
    signin: { title: 'Public sign-in page', what: 'authentik\'s own page, published like any other application (for example https://auth.example.com). Google returns here after you choose your account.', why: 'Visitors and Google both need to reach it from the internet. Traefik still talks to authentik internally.', dtc: 'Publishes it through Cloudflare (without Cloudflare Access) and checks that it answers.', you: 'Sign-in options, branding and flows: in authentik.', fails: 'Not published, Cloudflare Access in front (Google\'s return gets blocked), or authentik not running.' },
    callback: { title: 'Return to the application', what: 'After signing in, authentik sends the browser back to https://<app>/outpost.goauthentik.io/callback, which sets the sign-in cookie and then opens the page you asked for.', why: 'The cookie belongs to the application\'s own hostname, so the return must go through the same public address.', dtc: 'Adds a route for /outpost.goauthentik.io/ on the application\'s hostname and sets the provider to the public https address.', you: 'Nothing, as long as the application keeps its public https address in authentik.', fails: 'No outpost route (404 after signing in), or the provider set to another address (you land on the wrong page or loop).' },
    backend: { title: 'Application backend', what: 'Where Traefik sends authorised requests: a container by its Docker name (http://app:8080) or a program on Windows (http://host.docker.internal:port).', why: 'Only Traefik talks to the application; it is not exposed to the internet directly.', dtc: 'Finds a working address with the backend finder and tests it from inside Traefik\'s container.', you: 'Keep the application running. Some applications need their public URL set in their own settings.', fails: 'Wrong port or scheme, the app stopped, or a container not on the shared network (502/504).' },
    networks: { title: 'Docker networks', what: 'Private networks between containers. Traefik, authentik and container applications meet on one shared network.', why: 'Containers reach each other by name only on a network they share; nothing else on the network is published.', dtc: 'Creates the shared network, attaches Traefik and authentik, and offers to attach applications.', you: 'Containers you manage yourself must stay attached after you recreate them (add the network to their compose file).', fails: 'A recreated container that lost its network attachment.' },
  };
  function routingHelp(id) { return ROUTING_HELP[id] || null; }
  // Journey step path: whose request it is.
  function journeyPath(path) { return path === 'browser' ? { label: 'Browser', tone: 'info', icon: 'globe' } : { label: 'Server to server', tone: 'neutral', icon: 'server' }; }

  return {
    ROUTING_STATES, routingState, routingEvidence, endpointAudience, endpointKind, ROUTING_HELP, routingHelp, journeyPath,
    IDENTITY_STATES, identityState, googleRedirectUri, isGoogleClientId, identityNextStep, identityWizard, wizardNeighbours, CREDENTIAL_STATUS, credentialStatus,
    LEVELS, LEVEL_TITLES, DEFAULT_LEVEL, normalizeLevel, levelIndex, isVisibleAt,
    DIMENSIONS, COMPONENT_STATUS, componentStatus, firstBlocked, suggestAppName, displayNameFromLabel, choosePort, reachOptions,
    suggestLabel, suggestServiceName, autoName, autoNameFromSource, autoNameEdit, autoNameReset, isValidSubdomain, joinHostname, splitHostname,
    detectTarget, isPrivateIPv4,
    BACKEND_QUESTION, WHERE, whereFromTargetType, isLoopbackHost, parseBackendAddress, sameTarget, targetUrl, ROLE_LABELS, backendCandidates, chooseBackend,
    visibleGuidance, parseBackendUrl, backendValidation, backendHeadline, backendStatus,
    stableStringify, fingerprint, reviewState, markReviewed, reopenReview,
    STATUS, statusFromReview, worstStatus,
    formatBytes, splitEmails, isEmail,
  };
});
