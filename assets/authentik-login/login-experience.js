/*
 * DTC sign-in experience for authentik (Deployment Manager).
 *
 * Runs on authentik's own sign-in page (inlined by the template override custom-templates/if/flow.html) and in the
 * offline preview (assets/authentik-login/preview.html). It does two things, both of which only START sign-in:
 *   1. Personalizes authentik's own Google button ("Continue as <owner>").
 *   2. Picture shortcut: tapping the configured landmarks of the background picture in order presses that same button.
 * Google and authentik still decide who signs in and what they may open. Nothing here talks to Google, reads cookies or
 * stores anything: the one Google action is authentik's source button (GET /source/oauth/login/<slug>/), which builds
 * the Google request (state, login_hint, scopes) on the server.
 *
 * The configuration comes from the brand attribute "dtc_login" (rendered by the template as JSON) or, in the preview,
 * from an inline JSON block. In Node (tests\authentik-login.test.js) only the pure functions are exported.
 *
 * Do not write two consecutive curly braces or a curly brace followed by a percent sign or hash anywhere in this file:
 * it is included by a Django template.
 */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) { module.exports = api; return; }
  root.DtcLogin = api;
  if (root.document && !root.DTC_LOGIN_NO_BOOT) { api.boot(root); }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var LIMITS = { minPoints: 2, maxPoints: 6, minTimeoutMs: 1500, maxTimeoutMs: 30000, minRadiusPx: 22, maxRadiusPx: 80 };
  var DEFAULTS = {
    ownerEmail: '',
    sourceSlug: 'google',
    buttonLabel: 'Continue as {email}',
    pictureShortcut: { enabled: true, tapTimeoutMs: 6000, minTargetRadiusPx: 28, points: [] }
  };
  var EMAIL = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$/;
  var SLUG = /^[a-z0-9][a-z0-9_-]{0,49}$/;

  function num(v) { return typeof v === 'number' && isFinite(v) ? v : NaN; }

  // Validates and fills in a configuration. Returns { ok, config, errors }. Invalid points disable only the shortcut.
  function normalizeConfig(raw) {
    var errors = [];
    var src = raw && typeof raw === 'object' ? raw : {};
    var cfg = {
      ownerEmail: typeof src.ownerEmail === 'string' ? src.ownerEmail.trim() : '',
      sourceSlug: typeof src.sourceSlug === 'string' && SLUG.test(src.sourceSlug) ? src.sourceSlug : DEFAULTS.sourceSlug,
      buttonLabel: typeof src.buttonLabel === 'string' && src.buttonLabel.trim() ? src.buttonLabel.trim().slice(0, 80) : DEFAULTS.buttonLabel,
      pictureShortcut: null
    };
    if (cfg.ownerEmail && !EMAIL.test(cfg.ownerEmail)) { errors.push('ownerEmail is not an email address.'); cfg.ownerEmail = ''; }
    var ps = src.pictureShortcut && typeof src.pictureShortcut === 'object' ? src.pictureShortcut : {};
    var shortcut = {
      enabled: ps.enabled !== false,
      tapTimeoutMs: Math.round(num(ps.tapTimeoutMs)),
      minTargetRadiusPx: Math.round(num(ps.minTargetRadiusPx)),
      points: []
    };
    if (!(shortcut.tapTimeoutMs >= LIMITS.minTimeoutMs && shortcut.tapTimeoutMs <= LIMITS.maxTimeoutMs)) {
      if (ps.tapTimeoutMs !== undefined) { errors.push('tapTimeoutMs must be between ' + LIMITS.minTimeoutMs + ' and ' + LIMITS.maxTimeoutMs + '.'); }
      shortcut.tapTimeoutMs = DEFAULTS.pictureShortcut.tapTimeoutMs;
    }
    if (!(shortcut.minTargetRadiusPx >= LIMITS.minRadiusPx && shortcut.minTargetRadiusPx <= LIMITS.maxRadiusPx)) {
      if (ps.minTargetRadiusPx !== undefined) { errors.push('minTargetRadiusPx must be between ' + LIMITS.minRadiusPx + ' and ' + LIMITS.maxRadiusPx + '.'); }
      shortcut.minTargetRadiusPx = DEFAULTS.pictureShortcut.minTargetRadiusPx;
    }
    var pts = Array.isArray(ps.points) ? ps.points : [];
    var bad = false;
    pts.forEach(function (p, i) {
      var x = num(p && p.x), y = num(p && p.y), r = p && p.r !== undefined ? num(p.r) : 0.035;
      if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1)) { errors.push('Point ' + (i + 1) + ': x and y must be numbers from 0 to 1 (fractions of the picture).'); bad = true; return; }
      if (!(r > 0 && r <= 0.25)) { errors.push('Point ' + (i + 1) + ': r must be a number above 0 and at most 0.25 (fraction of the picture width).'); bad = true; return; }
      shortcut.points.push({ name: typeof p.name === 'string' ? p.name.slice(0, 60) : 'Point ' + (i + 1), x: x, y: y, r: r });
    });
    if (shortcut.enabled && !bad && (shortcut.points.length < LIMITS.minPoints || shortcut.points.length > LIMITS.maxPoints)) {
      errors.push('The picture shortcut needs ' + LIMITS.minPoints + ' to ' + LIMITS.maxPoints + ' points.'); bad = true;
    }
    if (bad) { shortcut.enabled = false; }
    cfg.pictureShortcut = shortcut;
    return { ok: errors.length === 0, config: cfg, errors: errors };
  }

  function buttonLabelFor(cfg) {
    if (!cfg.ownerEmail) { return ''; }
    return cfg.buttonLabel.split('{email}').join(cfg.ownerEmail);
  }

  // CSS length (px or %) against a reference size; 'auto' and anything else -> null.
  function cssLength(token, reference) {
    if (typeof token !== 'string') { return null; }
    var t = token.trim();
    if (/^-?[0-9.]+px$/.test(t)) { return parseFloat(t); }
    if (/^-?[0-9.]+%$/.test(t)) { return parseFloat(t) / 100 * reference; }
    if (t === '0') { return 0; }
    return null;
  }

  // Where the picture is drawn, in client pixels, for an element box (left, top, width, height), the picture's natural
  // size and the computed background-size / background-position (first layer). Handles cover, contain, explicit sizes
  // and percentage / pixel / keyword positions, so a resized or cropped picture maps back to the same landmarks.
  function backgroundRect(box, natural, size, position) {
    var iw = natural.width, ih = natural.height;
    if (!(iw > 0 && ih > 0 && box.width > 0 && box.height > 0)) { return null; }
    var s = String(size || 'auto').split(',')[0].trim();
    var w, h;
    if (s === 'cover' || s === 'contain') {
      var scale = s === 'cover' ? Math.max(box.width / iw, box.height / ih) : Math.min(box.width / iw, box.height / ih);
      w = iw * scale; h = ih * scale;
    } else {
      var parts = s.split(/\s+/);
      var pw = cssLength(parts[0], box.width), ph = cssLength(parts[1] || 'auto', box.height);
      if (pw === null && ph === null) { w = iw; h = ih; }
      else if (ph === null) { w = pw; h = pw * ih / iw; }
      else if (pw === null) { h = ph; w = ph * iw / ih; }
      else { w = pw; h = ph; }
    }
    var pos = String(position || '50% 50%').split(',')[0].trim()
      .replace(/\bleft\b/, '0%').replace(/\bright\b/, '100%').replace(/\btop\b/, '0%').replace(/\bbottom\b/, '100%').split(/\s+/);
    if (pos.length === 1) { pos.push('50%'); }
    pos = pos.map(function (p) { return p === 'center' ? '50%' : p; });
    function offset(tok, free) {
      var t = tok.trim();
      if (/%$/.test(t)) { return parseFloat(t) / 100 * free; }
      var px = cssLength(t, free);
      return px === null ? free / 2 : px;
    }
    return { left: box.left + offset(pos[0], box.width - w), top: box.top + offset(pos[1], box.height - h), width: w, height: h };
  }

  // Screen position and hit radius of each point for a drawn picture rectangle.
  function targetsFor(points, rect, minRadiusPx) {
    return points.map(function (p) {
      return { name: p.name, x: rect.left + p.x * rect.width, y: rect.top + p.y * rect.height, r: Math.max(minRadiusPx, p.r * rect.width) };
    });
  }

  function hitIndexes(targets, x, y) {
    var out = [];
    targets.forEach(function (t, i) { var dx = x - t.x, dy = y - t.y; if (dx * dx + dy * dy <= t.r * t.r) { out.push(i); } });
    return out;
  }

  // The tap sequence: taps must hit the points in order, each within timeoutMs of the previous correct tap. A wrong
  // tap resets quietly (a tap on the first point starts over at step 1); onComplete runs exactly once.
  function createSequence(opts) {
    var count = opts.count, timeoutMs = opts.timeoutMs, onComplete = opts.onComplete;
    var state = { step: 0, lastAt: 0, done: false };
    function reset() { state.step = 0; state.lastAt = 0; }
    return {
      state: state,
      reset: reset,
      expired: function (now) { return state.step > 0 && now - state.lastAt > timeoutMs; },
      tap: function (hits, now) {
        if (state.done) { return 'ignored'; }
        if (state.step > 0 && now - state.lastAt > timeoutMs) { reset(); }
        if (hits.indexOf(state.step) !== -1) {
          state.step += 1; state.lastAt = now;
          if (state.step === count) { state.done = true; onComplete(); return 'complete'; }
          return 'advance';
        }
        reset();
        if (count > 0 && hits.indexOf(0) !== -1) { state.step = 1; state.lastAt = now; return 'restart'; }
        return 'reset';
      }
    };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Browser part.

  function deepQuery(rootNode, selector) {
    var found = rootNode.querySelector(selector);
    if (found) { return found; }
    var all = rootNode.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].shadowRoot) { var f = deepQuery(all[i].shadowRoot, selector); if (f) { return f; } }
    }
    return null;
  }

  function readConfig(doc) {
    var el = doc.getElementById('dtc-login-config');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent || 'null'); } catch (e) { return null; }
  }

  // The element that draws the background picture (the theme uses body::before) and its computed geometry.
  function findBackground(win) {
    var doc = win.document;
    var candidates = [[doc.body, '::before'], [doc.body, null], [doc.documentElement, null]];
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i][0], pseudo = candidates[i][1];
      if (!el) { continue; }
      var cs = win.getComputedStyle(el, pseudo);
      var m = /url\(["']?([^"')]+)["']?\)/.exec(cs.backgroundImage || '');
      if (!m || cs.display === 'none' || (pseudo && cs.content === 'none')) { continue; }
      var box;
      if (pseudo) {
        box = { left: parseFloat(cs.left) || 0, top: parseFloat(cs.top) || 0, width: parseFloat(cs.width), height: parseFloat(cs.height) };
        if (!(box.width > 0)) { box = { left: 0, top: 0, width: win.innerWidth, height: win.innerHeight }; }
      } else {
        box = cs.backgroundAttachment === 'fixed' ? { left: 0, top: 0, width: win.innerWidth, height: win.innerHeight } : el.getBoundingClientRect();
      }
      return { url: m[1], box: box, size: cs.backgroundSize, position: cs.backgroundPosition };
    }
    return null;
  }

  // Taps on the sign-in card, its controls, the language menu or our own panels are not picture taps.
  function isUiTap(path) {
    for (var i = 0; i < path.length; i++) {
      var n = path[i];
      if (!n || n.nodeType !== 1) { continue; }
      var tag = n.tagName.toLowerCase();
      if (/^(a|button|input|select|textarea|label|option|summary|details)$/.test(tag)) { return true; }
      if (n.getAttribute('role') === 'button' || n.hasAttribute('data-dtc-ui')) { return true; }
      var cls = typeof n.className === 'string' ? n.className : '';
      if (/\b(pf-c-login__main|pf-c-login__footer|pf-c-login__header|pf-c-alert)\b/.test(cls)) { return true; }
      if (/^ak-(locale-select|brand-links|flow-inspector|flow-inspector-button|message-container)$/.test(tag)) { return true; }
    }
    return false;
  }

  function boot(win) {
    var doc = win.document;
    var raw = readConfig(doc);
    if (!raw) { return; }
    var result = normalizeConfig(raw);
    var cfg = result.config;
    if (result.errors.length && win.console) { win.console.warn('DTC sign-in: ' + result.errors.join(' ')); }
    var calibrate = /(^|[#&])dtc-calibrate\b/.test(win.location.hash || '');
    var label = buttonLabelFor(cfg);
    var buttonSelector = 'button[name="source-' + cfg.sourceSlug + '"]';
    var started = false;
    var natural = null;
    var api = win.DtcLogin;
    doc.documentElement.setAttribute('data-dtc-login', calibrate ? 'calibrate' : 'on');

    function nativeButton() { return deepQuery(doc, buttonSelector) || deepQuery(doc, 'button.source-button-promoted'); }

    // The single Google action, shared by the button and the picture: authentik's own source button.
    function startGoogleSignIn(origin) {
      if (started) { return false; }
      var btn = nativeButton();
      if (!btn || btn.disabled) { return false; }
      started = true;
      try { doc.dispatchEvent(new win.CustomEvent('dtc-login:start', { detail: { origin: origin } })); } catch (e) { /* old browsers */ }
      btn.click();
      return true;
    }
    if (api) { api.startGoogleSignIn = startGoogleSignIn; }

    // Personalize authentik's button (its click handler and keyboard behaviour stay authentik's own).
    function personalize() {
      var btn = nativeButton();
      if (!btn) { return; }
      var card = btn.closest ? btn.closest('ak-flow-card') : null;
      var host = btn.getRootNode && btn.getRootNode().host;
      if (host && !host.hasAttribute('data-dtc-login')) { host.setAttribute('data-dtc-login', ''); }
      if (card && !card.hasAttribute('data-dtc-login')) { card.setAttribute('data-dtc-login', ''); }
      var exec = deepQuery(doc, 'ak-flow-executor');
      if (exec && !exec.hasAttribute('data-dtc-login')) { exec.setAttribute('data-dtc-login', ''); }
      if (!label) { return; }
      if (btn.getAttribute('data-dtc-continue') !== label) { btn.setAttribute('data-dtc-continue', label); }
      if (btn.getAttribute('aria-label') !== label) { btn.setAttribute('aria-label', label); }
      if (btn.getAttribute('title') !== 'Sign in with Google as ' + cfg.ownerEmail) { btn.setAttribute('title', 'Sign in with Google as ' + cfg.ownerEmail); }
      for (var i = 0; i < btn.childNodes.length; i++) {
        var n = btn.childNodes[i];
        if (n.nodeType === 3 && n.data.trim()) { if (n.data.trim() !== label) { n.data = label; } return; }
      }
    }
    personalize();
    win.setInterval(personalize, 400);

    // Picture geometry: computed at tap time from the element that really draws the picture.
    function currentTargets() {
      var bg = findBackground(win);
      if (!bg || !natural || natural.url !== bg.url) {
        if (bg && (!natural || natural.url !== bg.url)) { loadNatural(bg.url); }
        return null;
      }
      var rect = backgroundRect(bg.box, natural, bg.size, bg.position);
      return rect ? targetsFor(cfg.pictureShortcut.points, rect, cfg.pictureShortcut.minTargetRadiusPx) : null;
    }
    function loadNatural(url) {
      var img = new win.Image();
      img.onload = function () {
        natural = { url: url, width: img.naturalWidth, height: img.naturalHeight };
        doc.documentElement.style.setProperty('--dtc-picture-aspect', String(img.naturalWidth / img.naturalHeight));
        if (calibrate) { drawCalibration(); }
      };
      img.src = url;
    }
    var first = findBackground(win);
    if (first) { loadNatural(first.url); }
    else { win.addEventListener('load', function () { var b = findBackground(win); if (b) { loadNatural(b.url); } }); }

    if (!cfg.pictureShortcut.enabled && !calibrate) { return; }

    var seq = createSequence({ count: cfg.pictureShortcut.points.length, timeoutMs: cfg.pictureShortcut.tapTimeoutMs, onComplete: function () {
      if (!startGoogleSignIn('picture')) { seq.state.done = false; seq.reset(); }
    } });
    var timer = null;
    var down = null;
    win.addEventListener('pointerdown', function (e) {
      down = (e.isPrimary === false || e.button > 0) ? null : { x: e.clientX, y: e.clientY, t: Date.now(), ui: isUiTap(e.composedPath ? e.composedPath() : []) };
    }, true);
    win.addEventListener('pointerup', function (e) {
      var d = down; down = null;
      if (!d || d.ui || e.isPrimary === false) { return; }
      if (Math.abs(e.clientX - d.x) > 12 || Math.abs(e.clientY - d.y) > 12 || Date.now() - d.t > 1200) { return; }
      var targets = currentTargets();
      if (!targets) { return; }
      var hits = hitIndexes(targets, e.clientX, e.clientY);
      if (calibrate) { showCalibration(e.clientX, e.clientY, hits); return; }
      var outcome = seq.tap(hits, Date.now());
      if (timer) { win.clearTimeout(timer); timer = null; }
      if (outcome === 'advance' || outcome === 'restart') {
        timer = win.setTimeout(function () { seq.reset(); }, cfg.pictureShortcut.tapTimeoutMs + 50);
      }
      try { doc.dispatchEvent(new win.CustomEvent('dtc-login:tap', { detail: { outcome: outcome, step: seq.state.step } })); } catch (err) { /* old browsers */ }
    }, true);
    // Read-only hooks for the browser tests (tests\Test-AuthentikLoginBrowser.ps1).
    if (api) { api.currentTargets = currentTargets; api.sequenceStep = function () { return seq.state.step; }; }

    // Calibration (#dtc-calibrate): shows the targets and the picture coordinates of each click. Never signs in.
    var overlay = null, panel = null;
    function drawCalibration() {
      var targets = currentTargets();
      if (!targets) { return; }
      if (!overlay) {
        overlay = doc.createElement('div');
        overlay.setAttribute('data-dtc-ui', '');
        overlay.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646';
        doc.body.appendChild(overlay);
        panel = doc.createElement('div');
        panel.id = 'dtc-calibration';
        panel.setAttribute('data-dtc-ui', '');
        panel.setAttribute('role', 'status');
        panel.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;max-width:min(92vw,420px);padding:10px 12px;border-radius:10px;background:rgba(0,0,0,.78);color:#fff;font:13px/1.4 system-ui,sans-serif;user-select:text';
        doc.body.appendChild(panel);
        panel.textContent = 'Calibration: click the picture to read its coordinates. Sign-in is disabled here. Remove #dtc-calibrate from the address to leave.';
        win.addEventListener('resize', drawCalibration);
      }
      overlay.innerHTML = '';
      targets.forEach(function (t, i) {
        var c = doc.createElement('div');
        c.style.cssText = 'position:absolute;border-radius:50%;border:2px solid #ffd54a;background:rgba(255,213,74,.18);color:#ffd54a;font:bold 14px system-ui;display:flex;align-items:center;justify-content:center;'
          + 'left:' + (t.x - t.r) + 'px;top:' + (t.y - t.r) + 'px;width:' + (2 * t.r) + 'px;height:' + (2 * t.r) + 'px';
        c.textContent = String(i + 1);
        overlay.appendChild(c);
      });
    }
    function showCalibration(x, y, hits) {
      var bg = findBackground(win);
      var rect = bg && natural ? backgroundRect(bg.box, natural, bg.size, bg.position) : null;
      if (!rect || !panel) { return; }
      var px = Math.round((x - rect.left) / rect.width * 1000) / 1000, py = Math.round((y - rect.top) / rect.height * 1000) / 1000;
      panel.textContent = '{ "name": "My landmark", "x": ' + px + ', "y": ' + py + ', "r": 0.035 }' + (hits.length ? '   (inside point ' + (hits[0] + 1) + ')' : '');
      drawCalibration();
    }
  }

  return {
    LIMITS: LIMITS, DEFAULTS: DEFAULTS, normalizeConfig: normalizeConfig, buttonLabelFor: buttonLabelFor, backgroundRect: backgroundRect,
    targetsFor: targetsFor, hitIndexes: hitIndexes, createSequence: createSequence, isUiTap: isUiTap, boot: boot
  };
});
