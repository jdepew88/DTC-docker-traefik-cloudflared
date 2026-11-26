'use strict';
// Developer tests for assets\authentik-login\login-experience.js (the DTC sign-in picture shortcut and button).
//   node tests\authentik-login.test.js
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const L = require('../assets/authentik-login/login-experience.js');

let passed = 0;
const failures = [];
function test(name, fn) {
  try { fn(); passed++; console.log(`[PASS] ${name}`); } catch (e) { failures.push(name); console.log(`[FAIL] ${name}  ${e.message}`); }
}
const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} != ${b}`);
const defaults = JSON.parse(fs.readFileSync(path.join(__dirname, '../assets/authentik-login/login-experience.default.json'), 'utf8'));

test('config: shipped defaults are valid and have three ordered points', () => {
  const r = L.normalizeConfig(Object.assign({}, defaults, { ownerEmail: 'joeydepew@gmail.com' }));
  assert.deepStrictEqual(r.errors, []);
  assert.strictEqual(r.config.pictureShortcut.enabled, true);
  assert.deepStrictEqual(r.config.pictureShortcut.points.map(p => p.name), ['Left snowfield', 'Right spire', 'Red cliff']);
  assert.strictEqual(L.buttonLabelFor(r.config), 'Continue as joeydepew@gmail.com');
});

test('config: four points are accepted; one or seven are not', () => {
  const four = { pictureShortcut: { points: [{ x: .1, y: .1 }, { x: .2, y: .2 }, { x: .3, y: .3 }, { x: .4, y: .4 }] } };
  assert.strictEqual(L.normalizeConfig(four).config.pictureShortcut.points.length, 4);
  assert.strictEqual(L.normalizeConfig(four).config.pictureShortcut.enabled, true);
  const one = L.normalizeConfig({ pictureShortcut: { points: [{ x: .5, y: .5 }] } });
  assert.strictEqual(one.config.pictureShortcut.enabled, false);
  const seven = L.normalizeConfig({ pictureShortcut: { points: Array.from({ length: 7 }, (_, i) => ({ x: i / 10, y: .5 })) } });
  assert.strictEqual(seven.config.pictureShortcut.enabled, false);
});

test('config: bad points, timeout, radius and email disable only what is wrong', () => {
  const r = L.normalizeConfig({ ownerEmail: 'not-an-email', pictureShortcut: { tapTimeoutMs: 50, minTargetRadiusPx: 500, points: [{ x: 1.2, y: .1 }, { x: .2, y: .2 }] } });
  assert.ok(r.errors.length >= 3);
  assert.strictEqual(r.config.ownerEmail, '');
  assert.strictEqual(L.buttonLabelFor(r.config), '', 'no label without a valid owner (authentik keeps its own text)');
  assert.strictEqual(r.config.pictureShortcut.enabled, false);
  assert.strictEqual(r.config.pictureShortcut.tapTimeoutMs, 6000);
  assert.strictEqual(r.config.pictureShortcut.minTargetRadiusPx, 28);
  assert.strictEqual(L.normalizeConfig({ sourceSlug: '../x' }).config.sourceSlug, 'google');
  assert.strictEqual(L.normalizeConfig(null).config.pictureShortcut.enabled, false);
});

test('geometry: cover on a wide screen crops top and bottom', () => {
  const r = L.backgroundRect({ left: 0, top: 0, width: 1440, height: 900 }, { width: 2560, height: 1708 }, 'cover', '50% 50%');
  close(r.width, 1440); close(r.height, 1708 * 1440 / 2560);
  close(r.top, (900 - r.height) / 2); close(r.left, 0);
});

test('geometry: cover on a tall screen crops the sides', () => {
  const r = L.backgroundRect({ left: 0, top: 0, width: 390, height: 844 }, { width: 1500, height: 1000 }, 'cover', 'center');
  close(r.height, 844); close(r.width, 1266); close(r.left, (390 - 1266) / 2);
});

test('geometry: phone layout (100% auto, top) and pseudo-element offsets', () => {
  const r = L.backgroundRect({ left: -10, top: -10, width: 410, height: 864 }, { width: 1500, height: 1000 }, '100% auto', '50% 0%');
  close(r.width, 410); close(r.height, 410 / 1.5); close(r.left, -10); close(r.top, -10);
  const c = L.backgroundRect({ left: 0, top: 0, width: 1000, height: 1000 }, { width: 1500, height: 1000 }, 'contain', 'left top');
  close(c.width, 1000); close(c.left, 0); close(c.top, 0);
  const px = L.backgroundRect({ left: 0, top: 0, width: 800, height: 600 }, { width: 400, height: 300 }, '400px 300px', '10px 20px');
  close(px.left, 10); close(px.top, 20);
});

test('geometry: a landmark maps to the same picture spot after a resize', () => {
  const pts = [{ name: 'a', x: .765, y: .215, r: .035 }];
  const nat = { width: 2560, height: 1708 };
  for (const [w, h] of [[1920, 1080], [1280, 720], [1024, 1366], [390, 844]]) {
    const rect = L.backgroundRect({ left: 0, top: 0, width: w, height: h }, nat, 'cover', '50% 50%');
    const [t] = L.targetsFor(pts, rect, 28);
    close((t.x - rect.left) / rect.width, .765); close((t.y - rect.top) / rect.height, .215);
    assert.ok(t.r >= 28, 'target never smaller than the phone minimum');
  }
});

test('targets: minimum radius on phones, hit test inclusive', () => {
  const rect = { left: 0, top: 0, width: 390, height: 260 };
  const [t] = L.targetsFor([{ x: .5, y: .5, r: .035 }], rect, 28);
  assert.strictEqual(t.r, 28);
  assert.deepStrictEqual(L.hitIndexes([t], 195 + 28, 130), [0]);
  assert.deepStrictEqual(L.hitIndexes([t], 195 + 29, 130), []);
});

function seq(count = 3, timeoutMs = 6000) {
  let calls = 0;
  const s = L.createSequence({ count, timeoutMs, onComplete: () => { calls++; } });
  return { s, calls: () => calls };
}

test('sequence: correct order completes exactly once', () => {
  const { s, calls } = seq();
  assert.strictEqual(s.tap([0], 0), 'advance');
  assert.strictEqual(s.tap([1], 1000), 'advance');
  assert.strictEqual(s.tap([2], 2000), 'complete');
  assert.strictEqual(calls(), 1);
  assert.strictEqual(s.tap([0], 2100), 'ignored');
  assert.strictEqual(s.tap([1], 2200), 'ignored');
  assert.strictEqual(s.tap([2], 2300), 'ignored');
  assert.strictEqual(calls(), 1);
});

test('sequence: wrong point, miss and wrong order reset quietly', () => {
  const { s, calls } = seq();
  s.tap([0], 0); assert.strictEqual(s.tap([2], 100), 'reset'); assert.strictEqual(s.state.step, 0);
  s.tap([0], 200); assert.strictEqual(s.tap([], 300), 'reset'); assert.strictEqual(s.state.step, 0);
  assert.strictEqual(s.tap([1], 400), 'reset');
  assert.strictEqual(s.tap([2], 500), 'reset');
  assert.strictEqual(calls(), 0);
});

test('sequence: repeating the first point starts over at step 1', () => {
  const { s, calls } = seq();
  s.tap([0], 0); assert.strictEqual(s.tap([0], 100), 'restart'); assert.strictEqual(s.state.step, 1);
  s.tap([1], 200); s.tap([2], 300); assert.strictEqual(calls(), 1);
});

test('sequence: a pause longer than the timeout resets', () => {
  const { s, calls } = seq(3, 6000);
  s.tap([0], 0); s.tap([1], 5000);
  assert.ok(!s.expired(11000)); assert.ok(s.expired(11001));
  assert.strictEqual(s.tap([2], 11001), 'reset');
  assert.strictEqual(calls(), 0);
  s.tap([0], 12000); s.tap([1], 13000); assert.strictEqual(s.tap([2], 14000), 'complete'); assert.strictEqual(calls(), 1);
});

test('sequence: four points', () => {
  const { s, calls } = seq(4);
  [0, 1, 2].forEach((i, k) => assert.strictEqual(s.tap([i], k * 100), 'advance'));
  assert.strictEqual(s.tap([3], 400), 'complete'); assert.strictEqual(calls(), 1);
});

test('sequence: overlapping targets prefer the expected one', () => {
  const { s, calls } = seq(2);
  s.tap([0, 1], 0); assert.strictEqual(s.state.step, 1);
  s.tap([0, 1], 100); assert.strictEqual(calls(), 1);
});

test('ui taps: card, controls and own panels are not picture taps', () => {
  const el = (tag, cls = '', attrs = {}) => ({ nodeType: 1, tagName: tag.toUpperCase(), className: cls,
    getAttribute: n => attrs[n] === undefined ? null : attrs[n], hasAttribute: n => n in attrs });
  assert.ok(L.isUiTap([el('span'), el('button')]));
  assert.ok(L.isUiTap([el('div'), el('main', 'pf-c-login__main')]));
  assert.ok(L.isUiTap([el('ak-locale-select')]));
  assert.ok(L.isUiTap([el('div', '', { 'data-dtc-ui': '' })]));
  assert.ok(!L.isUiTap([el('div', 'pf-c-login'), el('ak-flow-executor'), el('body')]));
});

test('template safety: script and template contain no stray Django tokens', () => {
  const js = fs.readFileSync(path.join(__dirname, '../assets/authentik-login/login-experience.js'), 'utf8');
  assert.ok(!/\{\{|\{%|\{#|%\}|#\}/.test(js), 'login-experience.js must not contain Django template delimiters');
  assert.ok(!/<\/script/i.test(js), 'login-experience.js must not close the script element');
  const tpl = fs.readFileSync(path.join(__dirname, '../assets/authentik-login/flow.html'), 'utf8');
  assert.ok(tpl.startsWith('{% extends "if/flow.html" %}'), 'the override must extend authentik\'s own template');
  assert.ok(/not safe_mode/.test(tpl) && /dtc_login\.flowSlug == flow\.slug/.test(tpl), 'active only for the opted-in flow, never in recovery');
  assert.ok(/json_script:"dtc-login-config"/.test(tpl), 'configuration is emitted with json_script (escaped)');
});

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) { process.exitCode = 1; }
