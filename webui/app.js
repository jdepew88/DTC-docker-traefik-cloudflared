'use strict';
// Traefik + Cloudflare Deployment Manager - application shell: state, routing, navigation, shared change dialogs.
// Pages live in setup.js (the seven-step installation journey) and pages.js (the operational pages). The browser
// only talks to the local webui.ps1 API (same origin); all content is built with DOM nodes, never innerHTML.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, $$, arr, h, clear, fill, icon, chip, plainChip, toast, api, withBusy } = U;

  const state = {
    status: null, setup: null, dashboard: null, discovery: null, env: null, overview: null,
    installPlan: null, installResult: null, verify: null, expert: null,
    services: [], middlewares: [], zones: [], cf: null, backups: null,
    plan: null, planBody: null, planApplyPath: '/api/services/apply', replan: null, afterApply: null,
    restore: null, page: 'setup', sub: '', journeyOpen: {}, forms: {}, session: { chosen: true, canStop: false }, projects: null, reviewPath: '',
    approvals: { local: null, cloudflare: null, dashboardSig: null, overwrites: [] },
  };

  // --- Navigation ---------------------------------------------------------------------------------------------------------
  const OPS_NAV = [
    ['overview', 'Overview', 'home'], ['services', 'Services', 'list'], ['cloudflare', 'Cloudflare', 'cloud'],
    ['dashboard', 'Traefik Dashboard', 'gauge'], ['backups', 'Backups', 'archive'], ['diagnostics', 'Diagnostics', 'terminal'],
    ['settings', 'Settings', 'settings'], ['help', 'Help and Learning', 'book'],
  ];
  const STEPS = [
    [1, 'Connect Cloudflare'], [2, 'Prepare Docker Desktop'], [3, 'Configure the deployment'], [4, 'Configure ingress'],
    [5, 'Review local infrastructure'], [6, 'Review Cloudflare changes'], [7, 'Install and verify'],
  ];
  const LEGACY = { logs: 'diagnostics' };
  const installed = () => !!(state.setup && state.setup.installed);

  function parseHash() {
    const [raw] = decodeURIComponent(location.hash.replace(/^#/, '')).split('?');
    const [page, ...rest] = raw.split('/');
    return { page: LEGACY[page] || page, sub: rest.join('/') };
  }
  function navigate(page, sub = '') {
    const target = `#${page}${sub ? `/${sub}` : ''}`;
    if (location.hash === target) route(); else location.hash = target;
  }
  function route() {
    let { page, sub } = parseHash();
    const pages = window.TPMPages || {};
    if (!pages[page]) page = !state.session.chosen ? 'projects' : installed() ? 'overview' : 'setup';
    // Until a deployment is chosen, only the chooser and general pages are shown.
    if (!state.session.chosen && !['projects', 'help', 'settings'].includes(page)) page = 'projects';
    // Focus moves to the new page on navigation, but not on the first load (keyboard users start at the skip link).
    const changed = page !== state.page && state.routed;
    state.page = page; state.sub = sub; state.routed = true;
    renderNav();
    const main = $('#main');
    // Each render gets its own container: a slower, older render (e.g. after a level switch) finishes into a detached
    // element instead of overwriting the page the user moved to.
    const host = h('div', { class: 'page' });
    fill(main, host);
    Promise.resolve(pages[page](host, ctx, sub)).catch((e) => { if (e && e.status !== 401) toast(e.message, true); });
    if (changed) { main.focus({ preventScroll: true }); window.scrollTo(0, 0); }
  }
  function rerender() { route(); }

  function stepStatusList() { return window.TPMPages && window.TPMPages.stepStatuses ? window.TPMPages.stepStatuses(ctx) : []; }

  function renderNav() {
    const rail = clear($('#rail'));
    const mobile = clear($('#mobile-nav'));
    const select = h('select', { 'aria-label': 'Go to' });
    const add = (value, label, selected) => select.append(h('option', { value, selected }, label));
    const steps = stepStatusList();
    rail.append(h('h2', null, 'Deployment'));
    rail.append(h('ul', null, h('li', null, h('a', { href: '#projects', 'aria-current': state.page === 'projects' ? 'page' : null }, icon('folder'), state.session.chosen ? 'Switch deployment' : 'Choose a deployment'))));
    add('projects', state.session.chosen ? 'Switch deployment' : 'Choose a deployment', state.page === 'projects');
    if (!state.session.chosen) {
      rail.append(h('h2', null, 'Also'));
      rail.append(h('ul', null, [['help', 'Help and Learning', 'book'], ['settings', 'Settings', 'settings']].map(([id, label, ic]) => h('li', null, h('a', { href: `#${id}`, 'aria-current': state.page === id ? 'page' : null }, icon(ic), label)))));
      add('help', 'Help and Learning', state.page === 'help'); add('settings', 'Settings', state.page === 'settings');
    } else if (installed()) {
      rail.append(h('h2', null, 'Operate'));
      rail.append(h('ul', null, OPS_NAV.map(([id, label, ic]) => h('li', null, h('a', { href: `#${id}`, 'aria-current': state.page === id ? 'page' : null }, icon(ic), label)))));
      rail.append(h('h2', null, 'Installation'));
      rail.append(h('ul', null, h('li', null, h('a', { href: '#setup', 'aria-current': state.page === 'setup' ? 'page' : null }, icon('rocket'), 'Setup journey'))));
      OPS_NAV.forEach(([id, label]) => add(id, label, state.page === id));
      add('setup', 'Setup journey', state.page === 'setup');
    } else {
      rail.append(h('h2', null, 'Installation'));
      rail.append(h('ol', { class: 'rail-steps' }, STEPS.map(([n, title]) => {
        const st = steps[n - 1] || {};
        return h('li', null, h('a', { href: `#setup/${n}`, 'aria-current': state.page === 'setup' && st.current ? 'step' : null },
          h('span', { class: `step-num ${st.cls || ''}` }, st.cls === 'done' ? icon('check') : String(n)), h('span', null, title,
            h('span', { class: 'sr-only' }, st.cls === 'done' ? ' (done)' : st.current ? ' (current step)' : ''))));
      })));
      rail.append(h('h2', null, 'Also'));
      rail.append(h('ul', null, [['backups', 'Restore a backup', 'archive'], ['help', 'Help and Learning', 'book'], ['settings', 'Settings', 'settings']]
        .map(([id, label, ic]) => h('li', null, h('a', { href: `#${id}`, 'aria-current': state.page === id ? 'page' : null }, icon(ic), label)))));
      rail.append(h('p', { class: 'rail-note' }, 'Nothing in Docker or Cloudflare changes until you approve it in steps 5 and 6.'));
      STEPS.forEach(([n, title]) => add(`setup/${n}`, `${n}. ${title}${(steps[n - 1] || {}).cls === 'done' ? ' ✓' : ''}`, state.page === 'setup' && (steps[n - 1] || {}).current));
      add('backups', 'Restore a backup', state.page === 'backups');
      add('help', 'Help and Learning', state.page === 'help');
      add('settings', 'Settings', state.page === 'settings');
    }
    select.addEventListener('change', () => { const [p, s] = select.value.split('/'); navigate(p, s || ''); });
    mobile.append(select);
    if (state.session.chosen && !installed()) {
      const done = steps.filter((s) => s.cls === 'done').length;
      const bar = h('div', { class: 'progress', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '7', 'aria-valuenow': String(done), 'aria-label': 'Setup progress' }, h('span'));
      bar.firstChild.style.width = `${Math.round((done / 7) * 100)}%`;
      mobile.append(bar);
    }
  }

  function renderInstancePill() {
    const s = state.status;
    const pill = $('#instance-pill');
    if (!s) return;
    if (!state.session.chosen) { fill(pill, h('span', { class: 'dot' }), 'No deployment open'); return; }
    const i = s.instance;
    const running = arr(s.stack && s.stack.Containers).filter((c) => c.State === 'running').length;
    const tone = !i.installed ? '' : s.stack.TraefikApi ? 'ok' : running ? 'warn' : 'err';
    fill(pill, h('span', { class: `dot ${tone}` }), `${i.stackName} · ${i.installed ? (s.stack.TraefikApi ? 'running' : 'not healthy') : 'not installed'}`);
    pill.title = i.installPath;
  }

  async function refresh() {
    const [s, setup] = await Promise.all([api('GET', '/api/status'), api('GET', '/api/setup')]);
    state.status = s; state.setup = setup;
    state.dashboard = await api('GET', '/api/dashboard').catch(() => null);
    U.setReviewScope(setup.installPath);
    renderInstancePill();
    return s;
  }

  // --- Change preview dialog (services, public dashboard) ----------------------------------------------------------------------
  const kindBadge = {
    create: () => plainChip('Create', 'info'), update: () => plainChip('Overwrite', 'warn'), delete: () => plainChip('Delete', 'err'),
    none: () => plainChip('No change', 'neutral'), blocked: () => plainChip('Blocked', 'err'),
  };
  const stepLabel = (s) => ({ dns: 'DNS', tunnel: 'Tunnel route', access: 'Access', route: 'Traefik route' })[s] || s;

  function reviewList(review) {
    // Server review items -> status lines grouped by stage.
    const groups = [['prepared', 'Configuration prepared'], ['validated', 'Validation'], ['applied', 'Changes applied'], ['verified', 'Runtime verified'], ['action', 'Requires your action']];
    const items = arr(review);
    return groups.map(([stage, title]) => {
      const list = items.filter((i) => i.stage === stage);
      if (!list.length) return null;
      return [h('h4', null, title), h('ul', { class: 'checks' }, list.map((i) => U.checkItem(i.state === 'ok' ? 'ok' : i.state === 'failed' ? 'err' : i.state === 'warning' ? 'warn' : 'neutral', i.label, i.message)))];
    });
  }

  function cloudflareActionList(actions, confirmClass) {
    return h('ul', { class: 'action-list' }, arr(actions).map((a) => {
      const li = h('li', { class: a.overwrite ? 'overwrite' : a.kind === 'blocked' ? 'blocked' : '' },
        (kindBadge[a.kind] || kindBadge.none)(), ' ', plainChip(stepLabel(a.step)), ' ', a.summary,
        a.detail ? h('p', { class: 'detail' }, a.detail) : null,
        U.gate('expert', a.id ? h('p', { class: 'detail mono' }, `id ${a.id}`) : null));
      if (a.overwrite && confirmClass) li.append(h('label', { class: 'check' }, h('input', { type: 'checkbox', class: confirmClass, 'data-id': a.id }), h('span', null, h('strong', null, 'Yes, overwrite this existing Cloudflare resource.'))));
      return li;
    }));
  }

  function renderPlan(plan, body) {
    $('#plan-title').textContent = plan.summary;
    const content = clear($('#plan-content'));
    if (arr(plan.review).length) content.append(h('div', null, reviewList(plan.review)));
    const notes = arr(plan.notes);
    if (notes.length) content.append(h('div', { class: 'callout' }, notes.map((n) => h('p', null, n))));
    const issues = arr(plan.traefik.issues);
    if (issues.length) {
      content.append(h('h3', null, 'Validation'), h('ul', { class: 'checks' }, issues.map((i) => U.checkItem(i.Level === 'Error' ? 'err' : 'warn', `${i.Service ? `${i.Service}: ` : ''}${i.Level}`, i.Message))));
    }
    const changes = arr(plan.traefik.changes);
    const t = h('section', null, h('h3', null, icon('route'), ' Traefik (this PC)'));
    if (!changes.length && !plan.traefik.registryChanged) t.append(h('p', { class: 'muted' }, 'No Traefik changes.'));
    for (const c of changes) {
      t.append(h('div', { class: 'file-head' }, c.action === 'add' ? plainChip('Add', 'info') : c.action === 'remove' ? plainChip('Remove', 'err') : plainChip('Update', 'warn'), h('span', { class: 'mono' }, c.file)));
      t.append(U.gate('intermediate', U.diffBlock(c.diff)));
    }
    if (plan.traefik.registryChanged) t.append(h('p', { class: 'muted' }, 'config\\services.json is updated. The current state is saved first (recovery point and snapshot).'));
    content.append(t);
    const cf = plan.cloudflare;
    const c = h('section', null, h('h3', null, icon('cloud'), ' Cloudflare'));
    for (const n of arr(cf.notes)) c.append(h('p', { class: 'muted' }, n));
    for (const e of arr(cf.errors)) c.append(h('p', { class: 'form-error' }, e));
    if (arr(cf.actions).length) c.append(cloudflareActionList(cf.actions, 'overwrite-confirm'));
    else if (cf.connected && !arr(cf.errors).length) c.append(h('p', { class: 'muted' }, 'No Cloudflare changes.'));
    const manual = arr(cf.manualSteps);
    if (manual.length) {
      c.append(h('p', null, h('strong', null, 'Do this in the Cloudflare dashboard'), ' (', h('a', { href: 'https://one.dash.cloudflare.com/', target: '_blank', rel: 'noopener noreferrer' }, 'one.dash.cloudflare.com'), '):'));
      c.append(h('ol', null, manual.map((m) => h('li', null, m))));
    }
    if ((body.op === 'remove' || body.op === 'update') && body.cloudflare && body.cloudflare.automate) {
      const box = h('input', { type: 'checkbox', checked: body.cloudflare.cleanup !== false });
      box.addEventListener('change', () => startPlan({ ...body, cloudflare: { ...body.cloudflare, cleanup: box.checked } }));
      c.append(h('label', { class: 'check' }, box, h('span', null, 'Also remove DNS records, tunnel routes and Access applications (created by this tool) for hostnames this change stops using.')));
    }
    content.append(c);
    renderPlanFooter(plan);
  }

  function renderPlanFooter(plan) {
    const foot = clear($('#plan-foot'));
    const cancel = h('button', { type: 'button', class: 'btn', 'data-close': true }, plan.canApply ? 'Cancel' : 'Close');
    if (!plan.canApply) { foot.append(h('div', { class: 'grow' }, h('span', { class: 'muted' }, plan.hasWork ? 'Fix the problems above, then preview again.' : 'Nothing to change.')), cancel); return; }
    const reviewed = h('input', { type: 'checkbox', id: 'plan-reviewed' });
    const apply = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Apply changes');
    const sync = () => { apply.disabled = !(reviewed.checked && $$('.overwrite-confirm', $('#plan-content')).every((b) => b.checked)); };
    reviewed.addEventListener('change', sync);
    $$('.overwrite-confirm', $('#plan-content')).forEach((b) => b.addEventListener('change', sync));
    apply.addEventListener('click', () => applyPlan(apply));
    foot.append(h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), cancel, apply);
  }

  async function startPlan(body, button) {
    state.planBody = body; state.planApplyPath = '/api/services/apply'; state.replan = () => startPlan(body);
    return withBusy(button, async () => { const plan = await api('POST', '/api/services/plan', body); state.plan = plan; renderPlan(plan, body); U.openDialog($('#plan-dialog')); });
  }
  async function startDashboardPlan(body, button) {
    state.planBody = body; state.planApplyPath = '/api/dashboard/apply'; state.replan = () => startDashboardPlan(body);
    return withBusy(button, async () => { const plan = await api('POST', '/api/dashboard/plan', body); state.plan = plan; renderPlan(plan, { op: 'dashboard' }); U.openDialog($('#plan-dialog')); });
  }

  async function applyPlan(button) {
    const overwrites = $$('.overwrite-confirm:checked', $('#plan-content')).map((b) => b.dataset.id);
    const path = state.planApplyPath;
    button.disabled = true; button.setAttribute('aria-busy', 'true');
    try {
      const r = await api('POST', path, { planId: state.plan.planId, confirm: true, confirmOverwrites: overwrites });
      renderResult(r);
      state.verify = null;
      if (state.afterApply) { state.afterApply(); state.afterApply = null; }
    } catch (e) {
      const content = $('#plan-content');
      const replan = state.replan;
      content.prepend(h('div', { class: 'callout err', role: 'alert' }, h('p', null, e.message),
        e.status === 409 && replan ? h('button', { type: 'button', class: 'btn', onclick: () => replan() }, 'Preview again') : null));
      content.scrollTop = 0;
    } finally { button.removeAttribute('aria-busy'); }
    await refresh().catch(() => {});
    rerender();
  }

  function renderResult(r) {
    $('#plan-title').textContent = r.failClosed ? 'Nothing was published' : r.ok ? 'Changes applied' : 'Some changes failed';
    const tone = { Done: 'ok', Unchanged: 'neutral', Warning: 'warn', Skipped: 'warn', 'Not run': 'neutral', Failed: 'err' };
    fill($('#plan-content'),
      arr(r.review).length ? reviewList(r.review) : h('ul', { class: 'checks', 'aria-live': 'polite' }, arr(r.steps).map((s) => U.checkItem(tone[s.status] || 'neutral', s.name, s.message))),
      arr(r.warnings).map((w) => h('p', { class: 'hint warn' }, w)),
      r.url ? h('div', { class: 'callout ok' }, h('p', null, h('strong', null, 'Dashboard: '), h('a', { href: r.url, target: '_blank', rel: 'noopener noreferrer' }, r.url)), h('p', { class: 'small' }, 'Cloudflare asks you to sign in first. A new DNS record can take a few minutes.')) : null,
      r.backup ? h('p', { class: 'muted' }, `The previous state was saved as snapshot ${r.backup}.`) : null,
      r.recoveryPoint ? h('p', { class: 'muted' }, `Recovery point: ${r.recoveryPoint} (Backups page).`) : null,
      !r.ok && !r.failClosed ? h('p', null, 'Changes that were applied stay in place. Fix the cause and preview again, or restore the recovery point.') : null);
    fill($('#plan-foot'), h('button', { type: 'button', class: 'btn primary', 'data-close': true }, 'Close'));
    $('#plan-foot .btn').focus();
  }

  // --- Init -------------------------------------------------------------------------------------------------------------------------
  const ctx = {
    state, refresh, navigate, rerender, startPlan, startDashboardPlan, renderPlan, renderResult, reviewList, cloudflareActionList, kindBadge,
    STEPS, installed,
  };
  window.TPMApp = ctx;

  function showSignedOut() {
    $('#signed-out').hidden = false;
    $('#layout').hidden = true;
  }

  async function init() {
    U.setTheme(U.getTheme());
    U.setLevel(U.store('tpm.level') || L.DEFAULT_LEVEL);
    // A link may carry presentation preferences (#page?level=expert&theme=light), e.g. for previews and help links.
    const q = new URLSearchParams(location.hash.split('?')[1] || '');
    if (q.get('level')) U.setLevel(q.get('level'));
    if (q.get('theme')) U.setTheme(q.get('theme'));
    U.wireDialogs();
    U.session.onSignedOut = showSignedOut;
    $$('input[name="detail-level"]').forEach((i) => i.addEventListener('change', () => { if (i.checked) U.setLevel(i.value); }));
    U.onLevelChange(() => { if (window.TPMPages && window.TPMPages.onLevelChange) window.TPMPages.onLevelChange(ctx); });
    try {
      const s = await api('GET', '/api/session');
      U.session.csrf = s.csrf;
      state.session = { chosen: s.chosen !== false, canStop: !!s.canStop };
    } catch (e) { if (e.status !== 401) toast(e.message, true); return; }
    await U.loadCatalog();
    try { await refresh(); } catch (e) { toast(e.message, true); }
    $('#brand-link').addEventListener('click', (e) => { e.preventDefault(); navigate(installed() ? 'overview' : 'setup'); });
    window.addEventListener('hashchange', route);
    let navQueued = false;
    window.addEventListener('tpm-steps', () => { if (navQueued) return; navQueued = true; requestAnimationFrame(() => { navQueued = false; renderNav(); }); });
    route();
  }
  init();
})();
