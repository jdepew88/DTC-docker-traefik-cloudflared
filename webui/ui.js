'use strict';
// Design-system components for the web UI (window.TPMUI). Everything is built with DOM nodes, never innerHTML.
// Browser storage holds per-viewer conveniences only (detail level, theme, review marks); the app works without it.
(() => {
  const L = window.TPMLogic;

  // --- DOM helpers ----------------------------------------------------------------------------------------------------
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const arr = (v) => (Array.isArray(v) ? v : v === null || v === undefined ? [] : [v]);
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k === 'dataset') Object.assign(el.dataset, v);
        else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v === true ? '' : String(v));
      }
    }
    append(el, children);
    return el;
  }
  function append(el, children) {
    for (const c of arr(children).flat(Infinity)) {
      if (c === null || c === undefined || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function fill(el, ...nodes) { clear(el); return append(el, nodes); }

  // --- Icons (24x24 stroke icons) ----------------------------------------------------------------------------------------
  const ICONS = {
    network: ['M9 2h6v5H9z', 'M2 17h6v5H2z', 'M16 17h6v5h-6z', 'M12 7v5', 'M5 17v-2a3 3 0 0 1 3-3h8a3 3 0 0 1 3 3v2'], layers: ['m12 2 10 5-10 5L2 7z', 'm2 12 10 5 10-5', 'm2 17 10 5 10-5'],
    pause: ['M8 5v14', 'M16 5v14'], play: ['m7 4 13 8-13 8z'], wrench: ['M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z'],
    check: ['M20 6 9 17l-5-5'], 'check-double': ['M18 6 7 17l-5-5', 'm22 10-7.5 7.5L13 16'], x: ['M18 6 6 18', 'M6 6l12 12'],
    alert: ['M12 9v4', 'M12 17h.01', 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z'],
    info: ['M12 16v-4', 'M12 8h.01', 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0z'], clock: ['M12 6v6l4 2', 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0z'],
    minus: ['M5 12h14'], eye: ['M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0z'],
    refresh: ['M23 4v6h-6', 'M1 20v-6h6', 'M3.5 9a9 9 0 0 1 14.8-3.4L23 10M1 14l4.6 4.4A9 9 0 0 0 20.5 15'],
    pulse: ['M22 12h-4l-3 9L9 3l-3 9H2'], chevron: ['m9 18 6-6-6-6'], 'chevron-down': ['m6 9 6 6 6-6'],
    cloud: ['M18 10h-1.3A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z'], shield: ['M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'],
    lock: ['M5 11h14v10H5z', 'M8 11V7a4 4 0 0 1 8 0v4'], globe: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0z', 'M2 12h20', 'M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z'],
    user: ['M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2', 'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0z'],
    box: ['M21 16V8a2 2 0 0 0-1-1.7l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.7l7 4a2 2 0 0 0 2 0l7-4a2 2 0 0 0 1-1.7z', 'M3.3 7 12 12l8.7-5', 'M12 22V12'],
    server: ['M2 3h20v7H2z', 'M2 14h20v7H2z', 'M6 6.5h.01', 'M6 17.5h.01'], monitor: ['M2 3h20v14H2z', 'M8 21h8', 'M12 17v4'],
    route: ['M6 19a3 3 0 1 0 0-6 3 3 0 0 0 0 6z', 'M18 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6z', 'M9 16h5a4 4 0 0 0 4-4v-1'],
    tunnel: ['M3 21V11a9 9 0 0 1 18 0v10', 'M7 21v-9a5 5 0 0 1 10 0v9'], home: ['M3 10.5 12 3l9 7.5V21H3z', 'M9 21v-6h6v6'],
    list: ['M8 6h13', 'M8 12h13', 'M8 18h13', 'M3 6h.01', 'M3 12h.01', 'M3 18h.01'], gauge: ['M12 14l4-4', 'M3.3 19a10 10 0 1 1 17.4 0z'],
    archive: ['M21 8v13H3V8', 'M1 3h22v5H1z', 'M10 12h4'], terminal: ['m4 17 6-6-6-6', 'M12 19h8'],
    settings: ['M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z', 'M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z'],
    book: ['M4 19.5A2.5 2.5 0 0 1 6.5 17H20', 'M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z'],
    rocket: ['M4.5 16.5c-1.5 1.3-2 5-2 5s3.7-.5 5-2c.7-.8.7-2.1-.1-2.9a2.2 2.2 0 0 0-2.9-.1z', 'M12 15l-3-3a22 22 0 0 1 2-3.9A12.9 12.9 0 0 1 22 2c0 2.7-.8 7.5-6 11a22.4 22.4 0 0 1-4 2z', 'M9 12H4s.6-3 2-4c1.6-1.1 5 0 5 0', 'M12 15v5s3-.6 4-2c1.1-1.6 0-5 0-5'],
    plus: ['M12 5v14', 'M5 12h14'], download: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'M7 10l5 5 5-5', 'M12 15V3'],
    upload: ['M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4', 'M17 8l-5-5-5 5', 'M12 3v12'], external: ['M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6', 'M15 3h6v6', 'M10 14 21 3'],
    edit: ['M12 20h9', 'M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z'], key: ['M21 2l-2 2m-7.6 7.6a5.5 5.5 0 1 1-7.8 7.8 5.5 5.5 0 0 1 7.8-7.8zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4'],
    folder: ['M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z'], help: ['M9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3', 'M12 17h.01', 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0z'],
  };
  function icon(name, cls = '') {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('class', `icon ${cls}`.trim()); s.setAttribute('aria-hidden', 'true'); s.setAttribute('focusable', 'false');
    for (const d of ICONS[name] || ICONS.info) { const p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', d); s.append(p); }
    return s;
  }

  // --- Status chips -----------------------------------------------------------------------------------------------------
  // status: a key of TPMLogic.STATUS (validated, reviewed, applied, healthy, warning, failed, pending, ...).
  function chip(status, label) {
    const m = L.STATUS[status] || L.STATUS.info;
    return h('span', { class: `chip ${m.tone}` }, icon(m.icon), label || m.label);
  }
  function plainChip(text, tone = 'neutral') { return h('span', { class: `chip ${tone}` }, text); }
  const TONE_OF = { ok: 'ok', failed: 'err', warning: 'warn', pending: 'neutral', info: 'neutral', skipped: 'neutral', auth: 'auth' };
  const ICON_OF = { ok: 'check', err: 'x', warn: 'alert', neutral: 'minus', auth: 'lock' };
  // One line of a check list: state ok | warn | err | neutral | auth (a login page answered: reachable, sign-in not tested).
  function checkItem(state, label, message, why) {
    const tone = TONE_OF[state] || state;
    return h('li', null, h('span', { class: `ci ${tone}` }, icon(ICON_OF[tone] || 'minus'), h('span', { class: 'sr-only' }, ({ ok: 'Passed', err: 'Failed', warn: 'Warning', neutral: 'Not checked', auth: 'Authentication required' })[tone] || '')),
      h('span', null, h('strong', null, label), message ? h('span', { class: 'msg' }, message) : null, why ? h('span', { class: 'why', 'data-min-level': 'beginner' }, why) : null));
  }

  // --- Feedback ---------------------------------------------------------------------------------------------------------
  let toastTimer = null;
  function toast(message, isError = false) {
    const t = $('#toast');
    t.textContent = message;
    t.className = isError ? 'toast err' : 'toast';
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, isError ? 9000 : 4500);
  }

  // --- API ------------------------------------------------------------------------------------------------------------------
  const session = { csrf: '', onSignedOut: null };
  async function api(method, path, body) {
    const opts = { method, headers: { Accept: 'application/json' }, credentials: 'same-origin' };
    if (method !== 'GET') { opts.headers['Content-Type'] = 'application/json'; opts.headers['X-CSRF-Token'] = session.csrf; opts.body = JSON.stringify(body || {}); }
    let res;
    try { res = await fetch(path, opts); } catch (e) { throw new Error('The web UI server is not reachable. Is webui.ps1 still running?'); }
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (res.status === 401 && session.onSignedOut) session.onSignedOut();
    if (!res.ok) { const err = new Error((data && data.error) || `Request failed (HTTP ${res.status}).`); err.status = res.status; err.data = data || {}; throw err; }
    return data;
  }
  async function withBusy(button, fn) {
    if (button) { button.disabled = true; button.setAttribute('aria-busy', 'true'); }
    try { return await fn(); } catch (e) { if (e.status !== 401) toast(e.message, true); return undefined; } finally { if (button) { button.disabled = false; button.removeAttribute('aria-busy'); } }
  }
  async function download(path, fallbackName) {
    const res = await fetch(path, { credentials: 'same-origin' });
    if (!res.ok) { let msg = ''; try { msg = (await res.json()).error; } catch (e) { msg = ''; } throw new Error(msg || `Download failed (HTTP ${res.status}).`); }
    const blob = await res.blob();
    const m = /filename="([^"]+)"/.exec(res.headers.get('Content-Disposition') || '');
    const a = h('a', { href: URL.createObjectURL(blob), download: m ? m[1] : fallbackName, hidden: true });
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    toast(`Saved ${m ? m[1] : fallbackName}.`);
  }

  // --- Per-viewer preferences (browser storage, optional) -------------------------------------------------------------------
  function store(key, value) { try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch (e) { /* storage unavailable */ } return null; }
  function storeJson(key, value) {
    if (value === undefined) { try { return JSON.parse(store(key) || 'null'); } catch (e) { return null; } }
    store(key, JSON.stringify(value)); return value;
  }
  const levelListeners = [];
  function getLevel() { return L.normalizeLevel(document.body.dataset.level || store('tpm.level')); }
  function setLevel(level) {
    const v = L.normalizeLevel(level);
    document.body.dataset.level = v;
    store('tpm.level', v);
    $$('input[name="detail-level"]').forEach((i) => { i.checked = i.value === v; });
    levelListeners.forEach((fn) => fn(v));
  }
  function onLevelChange(fn) { levelListeners.push(fn); }
  function atLeast(level) { return L.levelIndex(getLevel()) >= L.levelIndex(level); }
  function getTheme() { return store('tpm.theme') || 'dark'; }
  function setTheme(theme) {
    const t = ['dark', 'light', 'system'].includes(theme) ? theme : 'dark';
    store('tpm.theme', t);
    const resolved = t === 'system' ? (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark') : t;
    document.documentElement.dataset.theme = resolved;
  }
  // Content shown only from a detail level up (hidden by CSS, so switching levels needs no re-render).
  function gate(minLevel, ...children) { return h('div', { 'data-min-level': minLevel }, children); }
  function gateSpan(minLevel, ...children) { return h('span', { 'data-min-level': minLevel }, children); }
  function beginnerOnly(...children) { return h('div', { 'data-only-level': 'beginner' }, children); }

  // --- Contextual help (learning catalog) ------------------------------------------------------------------------------------
  const catalog = { topics: [], categories: [], byId: {} };
  async function loadCatalog() {
    try {
      const res = await fetch('/learn.json', { credentials: 'same-origin' });
      const data = await res.json();
      catalog.topics = arr(data.topics); catalog.categories = arr(data.categories);
      catalog.byId = Object.fromEntries(catalog.topics.map((t) => [t.id, t]));
    } catch (e) { /* help stays empty */ }
    return catalog;
  }
  function topicLinks(t) {
    const links = arr(t.links);
    if (!links.length) return null;
    return h('ul', null, links.map((l) => h('li', null, h('a', { href: l.url, target: '_blank', rel: 'noopener noreferrer' }, l.title, ' ', icon('external')))));
  }
  // A small "?" button; clicking it shows the topic's short explanation (and links) right below the host element.
  function help(topicId, label) {
    const btn = h('button', { type: 'button', class: 'help-btn', 'aria-expanded': 'false', 'aria-label': `Help: ${label || topicId}`, title: 'What is this?' }, '?');
    let panel = null;
    btn.addEventListener('click', (e) => {
      e.preventDefault(); e.stopPropagation();
      const open = btn.getAttribute('aria-expanded') === 'true';
      if (open) { if (panel) panel.remove(); panel = null; btn.setAttribute('aria-expanded', 'false'); return; }
      const t = catalog.byId[topicId];
      panel = h('div', { class: 'help-panel', role: 'note' },
        t ? [h('p', null, h('strong', null, t.title), ' — ', t.summary), topicLinks(t), h('p', { class: 'small' }, h('a', { href: `#help/${t.id}` }, 'More in Help and Learning'))] : h('p', null, 'No help for this item yet.'));
      const host = btn.closest('[data-help-host]') || btn.parentElement;
      host.append(panel);
      btn.setAttribute('aria-expanded', 'true');
    });
    return btn;
  }
  // A form field: label (+ help), control, hint. minLevel hides the whole field below that detail level.
  function field({ id, label, control, hint, helpId, minLevel, extra }) {
    // The label points at the form control itself, also when the control sits in a row with a button.
    const target = control && !['INPUT', 'SELECT', 'TEXTAREA'].includes(control.tagName) ? control.querySelector('input, select, textarea') : control;
    if (target && id && !target.id) target.id = id;
    return h('div', { class: 'field', 'data-help-host': '', 'data-min-level': minLevel || null },
      h('label', { for: id }, label, helpId ? help(helpId, label) : null, extra || null), control, hint ? h('p', { class: 'hint', id: `${id}-hint` }, hint) : null);
  }

  // --- Code, diff, key/value --------------------------------------------------------------------------------------------------
  function output(lines, label = 'Output') { return h('pre', { class: 'output', tabindex: '0', 'aria-label': label }, arr(lines).join('\n') || '(no output)'); }
  function diffBlock(lines) {
    return h('div', { class: 'diff', role: 'region', 'aria-label': 'Line changes', tabindex: '0' },
      arr(lines).map((l) => h('div', { class: l.startsWith('+ ') ? 'add' : l.startsWith('- ') ? 'del' : '' }, l)));
  }
  function kv(pairs) {
    return h('dl', { class: 'kv' }, pairs.filter(Boolean).map(([k, v, min]) => [h('dt', { 'data-min-level': min || null }, k), h('dd', { 'data-min-level': min || null }, v === '' || v === null || v === undefined ? '—' : v)]));
  }
  function technical(lines, title = 'Technical output', minLevel = null) {
    const list = arr(lines);
    if (!list.length) return null;
    return h('details', { class: 'tech', 'data-min-level': minLevel, open: getLevel() === 'expert' ? true : null }, h('summary', null, title), output(list, title));
  }

  // --- Review panels ----------------------------------------------------------------------------------------------------------
  // Collapsible review section with a validation status (set by the app) and a separate review mark (set by the user).
  // Marking reviewed collapses it to its summary; when its content (fingerprint) changes, the mark is invalidated.
  let reviewScope = 'default';
  const expanded = {};
  function setReviewScope(scope) { reviewScope = scope || 'default'; }
  function reviewStore(next) {
    const all = storeJson('tpm.reviews') || {};
    if (next === undefined) return all[reviewScope] || {};
    all[reviewScope] = next; storeJson('tpm.reviews', all); return next;
  }
  function reviewPanel(opts) {
    const fp = L.fingerprint(opts.fingerprint === undefined ? [opts.title, opts.status, opts.summary] : opts.fingerprint);
    const render = () => {
      const rs = L.reviewState(reviewStore(), opts.id, fp);
      const open = Object.prototype.hasOwnProperty.call(expanded, opts.id) ? expanded[opts.id]
        : rs === 'reviewed' ? false : opts.defaultOpen !== undefined ? opts.defaultOpen : opts.reviewable !== false || ['failed', 'warning'].includes(opts.status);
      const bodyId = `rv-body-${opts.id}`;
      const toggle = h('button', { type: 'button', class: 'rv-toggle', 'aria-expanded': String(open), 'aria-controls': bodyId },
        icon('chevron', 'chev'), opts.icon ? icon(opts.icon) : null, h('span', null, opts.title));
      const reviewChip = rs === 'reviewed' ? chip('reviewed') : rs === 'stale' ? chip('stale') : null;
      const panel = h('section', { class: `rv ${opts.status || ''} ${rs === 'stale' ? 'stale' : ''}`, id: `rv-${opts.id}`, 'aria-label': opts.title },
        h('div', { class: 'rv-head' }, toggle, opts.status ? chip(opts.status, opts.statusLabel) : null, reviewChip,
          opts.summary ? h('p', { class: 'rv-summary' }, opts.summary) : null));
      const body = h('div', { class: 'rv-body', id: bodyId, hidden: !open });
      if (open) {
        append(body, typeof opts.content === 'function' ? opts.content() : opts.content);
        if (arr(opts.diff).length) append(body, h('details', { class: 'tech' }, h('summary', null, 'View differences'), diffBlock(opts.diff)));
        append(body, technical(opts.technical, opts.technicalTitle || 'Show technical output'));
        const acts = h('div', { class: 'rv-actions' });
        if (opts.onEdit) acts.append(h('button', { type: 'button', class: 'btn small', onclick: opts.onEdit }, icon('edit'), opts.editLabel || 'Edit settings'));
        if (opts.reviewable !== false) {
          acts.append(rs === 'reviewed'
            ? h('button', { type: 'button', class: 'btn small ghost', onclick: () => { reviewStore(L.reopenReview(reviewStore(), opts.id)); expanded[opts.id] = true; rerender(); } }, icon('refresh'), 'Reopen review')
            : h('button', { type: 'button', class: 'btn small', onclick: () => { reviewStore(L.markReviewed(reviewStore(), opts.id, fp)); delete expanded[opts.id]; rerender(); if (opts.onReviewed) opts.onReviewed(); } }, icon('eye'), 'Mark reviewed'));
        }
        body.append(acts);
      }
      panel.append(body);
      toggle.addEventListener('click', () => { expanded[opts.id] = !open; rerender(); });
      return panel;
    };
    let node = render();
    function rerender() { const next = render(); node.replaceWith(next); node = next; const t = $('.rv-toggle', node); if (t) t.focus(); }
    return node;
  }
  function isReviewed(id, fingerprintData) { return L.reviewState(reviewStore(), id, L.fingerprint(fingerprintData)) === 'reviewed'; }

  // --- Topology --------------------------------------------------------------------------------------------------------------
  // nodes: [{ title, sub, icon, state: ok|warn|err|off|neutral }]; links (between consecutive nodes): [{ label, state }].
  function topology(nodes, links, ariaLabel = 'How requests reach your applications') {
    const wrap = h('div', { class: 'topology', role: 'list', 'aria-label': ariaLabel });
    nodes.forEach((n, i) => {
      const state = n.state || 'neutral';
      wrap.append(h('div', { class: `topo-node ${state}`, role: 'listitem' },
        h('div', { class: 'topo-icon' }, icon(n.icon || 'box'), state !== 'neutral' && state !== 'off' ? h('span', { class: `dot ${state}` }) : null),
        h('div', null, h('strong', null, n.title), n.sub ? h('span', null, n.sub) : null,
          h('span', { class: 'sr-only' }, `, status: ${({ ok: 'healthy', warn: 'needs attention', err: 'failing', off: 'not used', neutral: 'not checked' })[state]}`))));
      if (i < nodes.length - 1) {
        const l = (links || [])[i] || {};
        wrap.append(h('div', { class: `topo-link ${l.state || ''}`, 'aria-hidden': 'true' }, h('span', { class: 'line' }), l.label ? h('span', null, l.label) : null));
      }
    });
    return h('div', null, wrap, h('div', { class: 'topo-legend', 'aria-hidden': 'true' },
      h('span', null, h('span', { class: 'dot ok' }), 'healthy'), h('span', null, h('span', { class: 'dot warn' }), 'needs attention'),
      h('span', null, h('span', { class: 'dot err' }), 'failing'), h('span', null, h('span', { class: 'dot' }), 'not checked')));
  }

  // --- Dialogs ---------------------------------------------------------------------------------------------------------------
  function openDialog(dlg) {
    if (!dlg.open) dlg.showModal();
    const f = dlg.querySelector('[autofocus], .dialog-scroll input, .dialog-foot .btn.primary') || dlg.querySelector('.icon-btn');
    if (f) f.focus();
  }
  function wireDialogs() { $$('dialog').forEach((dlg) => dlg.addEventListener('click', (e) => { if (e.target.closest('[data-close]')) dlg.close('cancel'); })); }
  function confirmDialog({ title, body, okText = 'Confirm', danger = false, checkbox = null }) {
    const dlg = $('#confirm-dialog');
    $('#confirm-title').textContent = title;
    const content = fill($('#confirm-content'), arr(body).map((b) => (typeof b === 'string' ? h('p', null, b) : b)));
    const ok = $('#confirm-ok');
    ok.textContent = okText; ok.className = danger ? 'btn danger' : 'btn primary';
    if (checkbox) {
      const box = h('input', { type: 'checkbox', id: 'confirm-check' });
      content.append(h('label', { class: 'check' }, box, h('span', null, checkbox)));
      ok.disabled = true; box.addEventListener('change', () => { ok.disabled = !box.checked; });
    } else ok.disabled = false;
    return new Promise((resolve) => {
      const onOk = () => { cleanup(); dlg.close('ok'); resolve(true); };
      const onClose = () => { cleanup(); resolve(false); };
      function cleanup() { ok.removeEventListener('click', onOk); dlg.removeEventListener('close', onClose); }
      ok.addEventListener('click', onOk); dlg.addEventListener('close', onClose);
      openDialog(dlg);
    });
  }

  window.TPMUI = {
    $, $$, arr, h, append, clear, fill, icon, chip, plainChip, checkItem, toast, session, api, withBusy, download, store, storeJson,
    getLevel, setLevel, onLevelChange, atLeast, getTheme, setTheme, gate, gateSpan, beginnerOnly,
    catalog, loadCatalog, topicLinks, help, field, output, diffBlock, kv, technical,
    setReviewScope, reviewPanel, isReviewed, topology, openDialog, wireDialogs, confirmDialog,
  };
})();
