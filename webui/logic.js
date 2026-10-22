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

  return {
    LEVELS, LEVEL_TITLES, DEFAULT_LEVEL, normalizeLevel, levelIndex, isVisibleAt,
    DIMENSIONS, COMPONENT_STATUS, componentStatus, firstBlocked,
    suggestLabel, suggestServiceName, autoName, autoNameFromSource, autoNameEdit, autoNameReset, isValidSubdomain, joinHostname, splitHostname,
    detectTarget, isPrivateIPv4,
    stableStringify, fingerprint, reviewState, markReviewed, reopenReview,
    STATUS, statusFromReview, worstStatus,
    formatBytes, splitEmails, isEmail,
  };
});
