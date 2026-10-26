'use strict';
// Identity & Access (GET /api/identity) as a linear, resumable wizard: choose local or Google sign-in, install or adopt
// authentik, connect the manager, publish the sign-in address, register with Google (guided; Google offers no API for
// OAuth clients; the downloaded client JSON is the preferred import), the Google-first sign-in page, verify the owner,
// protect applications. A step counts as complete only from what the server observed (TPMLogic.identityWizard); the
// position is kept in the URL (#identity/<step>) and on the server, so a refresh or restart resumes in place. Secrets are
// typed or uploaded once, sent to the local server and never stored in the browser. After setup, users and access are
// managed in authentik.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, fill, icon, plainChip, toast, api, withBusy, field, gate, kv, technical, checkItem, help } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const stateChip = (state) => { const s = L.identityState(state); return h('span', { class: `chip ${s.tone}` }, icon(s.icon), s.label); };
  const stateTone = (state) => ({ ok: 'ok', err: 'err', warn: 'warn', auth: 'auth', info: 'neutral', neutral: 'neutral' })[L.identityState(state).tone];
  const ext = (href, text) => h('a', { href, target: '_blank', rel: 'noopener noreferrer' }, text, ' ', icon('external'));
  function copyRow(label, value, id, helpId) {
    const btn = h('button', { type: 'button', class: 'btn small', 'aria-label': `Copy ${label}`, onclick: async () => { try { await navigator.clipboard.writeText(value); toast(`Copied: ${label}`); } catch (e) { toast('Copy failed; select the text instead.', true); } } }, 'Copy');
    return h('div', { class: 'copy-row', 'data-help-host': '' }, h('span', { class: 'copy-label', id }, label, helpId ? help(helpId, label) : null), h('code', { 'aria-labelledby': id }, value), btn);
  }
  const actionList = (actions) => h('ul', { class: 'checks' }, arr(actions).map((a) => checkItem(
    a.kind === 'none' ? 'neutral' : a.status === 'Failed' ? 'err' : a.status === 'Done' ? 'ok' : a.kind === 'delete' ? 'warn' : 'auth',
    `${({ create: 'Create', update: 'Change', delete: 'Remove', none: 'No change' })[a.kind] || a.kind}: ${a.summary}`, a.detail || a.message || '')));

  // probe=apps: the server sends one anonymous request per protected application through Traefik, so step 8 and the
  // summary show what is enforced now, not stored flags.
  async function load(ctx, deep) { ctx.state.identity = await api('GET', `/api/identity?probe=apps${deep ? '&deep=1' : ''}`); return ctx.state.identity; }
  const form = (ctx) => ctx.state.forms.identity || (ctx.state.forms.identity = { google: null, protect: null, plans: {}, secret: '', owner: null, verify: null, loginPlan: null, json: null });

  // Why each step exists, in plain words (shown at the top of the step).
  const WHY = {
    mode: 'Decide how people will sign in to your protected applications. You can start with local accounts and add Google later; nothing you set up now is lost.',
    authentik: 'authentik is the sign-in service. It runs as its own Docker project on this PC, next to Traefik.',
    connect: 'The manager configures authentik for you through authentik\'s API. It needs an administrator API token, stored encrypted on this PC.',
    address: 'People (and Google) reach the sign-in page at its own address. It goes through your existing Traefik and Cloudflare Tunnel.',
    google: 'Google only lets you create the sign-in client in its Cloud Console. Follow the four short steps there, then import the file Google gives you; the manager configures authentik.',
    signin: 'Optional: a sign-in page that offers "Google" first, with email and password below it for local accounts.',
    owner: 'Proves that the owner can actually sign in, and gives that account access to the applications you protect next.',
    apps: 'Choose which applications require signing in. From then on, who may open them is decided in authentik.',
    done: 'Setup is complete. From now on, users and access are managed in authentik.',
  };

  P.identity = async (main, ctx, sub) => {
    if (!ctx.state.setup) await ctx.refresh();
    if (!(ctx.state.setup && ctx.state.setup.installed)) {
      fill(main, head('Access', 'Identity & Access', 'Install the Traefik deployment first.'), h('p', null, h('a', { href: '#setup' }, 'Go to the setup journey')));
      return;
    }
    fill(main, head('Access', 'Identity & Access', 'Loading…'));
    const d = await load(ctx, sub === 'check');
    render(main, ctx, d, sub && sub !== 'check' ? sub : '', false);
  };

  function render(main, ctx, d, wanted, keepScroll) {
    const y = window.scrollY;
    const f = form(ctx);
    const wiz = L.identityWizard(d);
    const byId = Object.fromEntries(wiz.steps.map((s) => [s.id, s]));
    let id = wanted && byId[wanted] ? wanted : wiz.current;
    if (!byId[id].available) id = wiz.firstOpen;
    const step = byId[id];
    const rerender = (keep = true) => render(main, ctx, ctx.state.identity, id, keep);
    const reload = async (deep) => { await load(ctx, deep); rerender(true); };
    const go = (to, extra) => {
      const req = api('POST', '/api/identity/wizard', { step: to, ...(extra || {}) }).catch(() => {});
      if (extra && extra.skip) { req.then(() => load(ctx, false)).then(() => render(main, ctx, ctx.state.identity, to, true)); }
      if (location.hash !== `#identity/${to}`) history.replaceState(null, '', `#identity/${to}`);
      render(main, ctx, ctx.state.identity, to, false);
      const p = document.getElementById('wizard-panel'); if (p) p.scrollIntoView({ block: 'start' });
    };
    const nb = L.wizardNeighbours(wiz, id);
    const nav = h('nav', { class: 'wizard-steps', 'aria-label': 'Setup steps' }, h('ol', null, wiz.steps.map((s) => h('li', { class: `${s.id === id ? 'current' : ''} ${s.done ? 'done' : ''} ${s.skipped ? 'skipped' : ''} ${!s.available ? 'locked' : ''}`, 'data-step': s.id },
      s.available ? h('button', { type: 'button', class: 'step-link', 'aria-current': s.id === id ? 'step' : null, onclick: () => go(s.id) },
        h('span', { class: 'step-num', 'aria-hidden': 'true' }, s.done ? '✓' : s.skipped ? '–' : String(s.number)), h('span', null, s.title, s.optional ? h('span', { class: 'small muted' }, ' (optional)') : null, s.badge ? h('span', { class: 'step-badge small muted' }, s.badge) : null),
        h('span', { class: 'sr-only' }, `${s.done ? ', complete' : s.skipped ? ', skipped' : ''}${s.id === id ? ', current step' : ''}`))
        : h('span', { class: 'step-link', title: `First: ${s.blockedBy}` }, h('span', { class: 'step-num', 'aria-hidden': 'true' }, String(s.number)), h('span', null, s.title), h('span', { class: 'sr-only' }, `, available after: ${s.blockedBy}`))))));
    const pr = wiz.protection;
    const appsStatus = () => ({
      done: h('p', { class: 'step-status ok', role: 'status', id: 'id-apps-status' }, icon('check'), ` Done: ${pr.protected} of ${pr.total} application(s) protected; ForwardAuth verified just now (anonymous visitors are sent to sign in).${pr.unprotected ? ` ${pr.unprotected} not protected.` : ''} You can protect more or remove protection here at any time.`),
      skipped: h('p', { class: 'step-status skipped', role: 'status', id: 'id-apps-status' }, icon('minus'), ' Skipped: no application is protected by authentik. Come back here at any time to protect applications.'),
      attention: h('p', { class: 'step-status todo', role: 'status', id: 'id-apps-status' }, icon('alert'), ` ${pr.protected} of ${pr.total} protected, but ForwardAuth is not working for ${pr.failing.join(', ')}. See the table below.`),
      checking: h('p', { class: 'step-status todo', role: 'status', id: 'id-apps-status' }, icon('refresh'), ` ${pr.protected} of ${pr.total} protected; not verified yet.`),
      open: h('p', { class: 'step-status todo', role: 'status', id: 'id-apps-status' }, icon('alert'), ' Optional: protect applications now, or skip this step.'),
    })[pr.state];
    const status = step.final ? (step.done ? h('p', { class: 'step-status ok', role: 'status', id: 'id-done-status' }, icon('check'), ' Setup is complete (checked just now).')
      : h('p', { class: 'step-status todo', role: 'status', id: 'id-done-status' }, icon('alert'), ` Not finished yet: ${arr(step.missing).length ? arr(step.missing).join(', ') : 'protection needs attention'}.`))
      : id === 'apps' ? appsStatus()
      : step.done ? h('p', { class: 'step-status ok', role: 'status' }, icon('check'), ' Done. ', step.optional ? 'You can change it here at any time.' : 'Continue to the next step.')
      : h('p', { class: 'step-status todo', role: 'status' }, icon('alert'), step.optional ? ' Optional: do it now or skip it.' : ' Not done yet: follow the instructions below.');
    const bodyFor = {
      mode: () => modeStep(ctx, d, reload, go),
      authentik: () => [installSection(ctx, d, reload), adminSection(d)],
      connect: () => apiSection(ctx, d, reload),
      address: () => hostnameSection(ctx, d, reload),
      google: () => googleStep(ctx, d, f, reload, rerender),
      signin: () => signinStep(ctx, d, f, reload, rerender),
      owner: () => ownerStep(ctx, d, f, reload, rerender, go),
      apps: () => protectStep(ctx, d, f, reload, rerender),
      done: () => doneStep(d, wiz, go),
    };
    const skipping = id === 'apps' && !step.done && !pr.protected;
    const continueLabel = nb.next ? (step.done || step.skipped || !step.optional ? `Continue: ${nb.next.title}` : `Skip for now: ${nb.next.title}`) : '';
    const footer = h('div', { class: 'wizard-foot' },
      nb.prev ? h('button', { type: 'button', class: 'btn', onclick: () => go(nb.prev.id) }, '← Back') : h('span'),
      h('span', { class: 'grow' }),
      nb.next ? h('button', { type: 'button', class: `btn ${step.done ? 'primary' : ''}`, disabled: !(step.done || step.optional), title: step.done || step.optional ? '' : 'Finish this step first', onclick: () => go(nb.next.id, skipping && !step.skipped ? { skip: 'apps' } : null) }, continueLabel, ' →') : null);
    const panel = h('section', { class: 'card wizard-panel', id: 'wizard-panel', 'aria-labelledby': 'wizard-title' },
      h('div', { class: 'eyebrow' }, `Step ${step.number} of ${wiz.steps.length}`),
      h('h2', { id: 'wizard-title', tabindex: '-1' }, step.title),
      h('p', { class: 'why' }, WHY[id] || ''), status,
      h('div', { class: 'wizard-body', id: `identity-${id}` }, bodyFor[id]()),
      footer);
    fill(main,
      head('Access', 'Identity & Access', 'A one-time guided setup of sign-in (authentik, optionally with Google) for the applications you choose. Afterwards users and access are managed in authentik. Basic setup and Cloudflare Access work without it.',
        h('a', { href: `#routing${arr(d.apps).find((a) => a.protected) ? `/${arr(d.apps).find((a) => a.protected).service}` : ''}`, class: 'btn small', id: 'id-flow-link' }, icon('route'), 'View Authentication Flow'),
        h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, () => reload(true)) }, icon('refresh'), 'Check again')),
      h('div', { class: 'wizard' }, nav, panel),
      gate('advanced', healthSection(d)),
      gate('expert', technical([JSON.stringify({ config: d.config, overview: d.overview, model: d.model, wizard: wiz }, null, 2)], 'Raw identity state (no secrets)')));
    if (keepScroll) window.scrollTo(0, y);
  }

  // --- 1. Sign-in path -----------------------------------------------------------------------------------------------------
  function modeStep(ctx, d, reload, go) {
    const mode = d.config.authMode;
    const pick = (m) => (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/mode', { mode: m }); await load(ctx, false); go('authentik'); });
    const card = (m, title, text, extra) => h('div', { class: `choice ${mode === m ? 'selected' : ''}`, role: 'listitem' },
      h('strong', null, title), mode === m ? plainChip('Chosen', 'ok') : null, h('p', { class: 'small' }, text), extra || null,
      h('button', { type: 'button', class: `btn small ${mode === m ? '' : 'primary'}`, onclick: pick(m) }, mode === m ? 'Keep this' : 'Choose'));
    return [h('div', { class: 'choice-cards', role: 'list' },
      card('local', 'A. Local accounts (username and password)', 'authentik accounts with passwords. Simplest start: no Google Cloud steps. You can add Google later in this wizard without losing accounts, rules or access.'),
      card('google', 'B. Google sign-in (recommended for Gmail users)', 'People sign in with their Google account. Needs a short visit to Google Cloud (about five minutes, guided). A local administrator password always remains as a recovery path.')),
      mode === 'local' && d.google && d.google.source ? h('p', { class: 'small' }, 'Google sign-in is already configured in authentik; choosing local accounts here only changes this wizard, nothing in authentik.') : null,
      h('details', { class: 'more' }, h('summary', null, 'Other choices'),
        h('p', { class: 'small' }, 'Authelia can be installed from the App Catalog, but its sign-in integration is not implemented in this version. ',
          h('button', { type: 'button', class: 'btn small ghost', onclick: (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/provider', { provider: 'none' }); toast('Saved: configure later. Cloudflare Access keeps working.'); await reload(false); }) }, 'Configure later'))),
      d.provider === 'none' ? h('p', { class: 'small muted' }, 'Currently: configure later (no self-hosted sign-in). Choose A or B to start.') : null];
  }

  // --- 2. Installation -----------------------------------------------------------------------------------------------------
  function installSection(ctx, d, reload) {
    const inst = d.install;
    const adopt = (p) => (e) => withBusy(e.currentTarget, async () => {
      const r = await api('POST', '/api/identity/adopt', { project: p.project, container: p.serverContainer });
      arr(r.notes).forEach((n) => toast(n, true)); if (!arr(r.notes).length) toast('authentik adopted. Nothing in it was changed.');
      await reload(false);
    });
    const row = (c, label) => checkItem(!c ? 'neutral' : c.state !== 'running' ? 'err' : c.health === 'unhealthy' ? 'err' : 'ok', label, c ? `${c.name}: ${c.state}${c.health ? ` (${c.health})` : ''}` : 'no container');
    let body;
    if (!inst) {
      const found = arr(d.installs);
      body = [found.length ? h('div', null, h('p', null, 'authentik installations found on this PC. Adopting one records it here; its containers, database, volumes and administrator are left exactly as they are.'),
        h('ul', { class: 'checks' }, found.map((p) => h('li', null, h('span', null, h('strong', null, p.project || p.serverContainer), ' ',
          plainChip(p.managed ? 'Installed by this manager' : 'Installed by hand', p.managed ? 'ok' : 'neutral'), ' ',
          h('span', { class: 'small muted' }, `${p.server ? `${p.server.state}` : 'prepared, not started'}${p.version ? `, ${p.version}` : ''}${p.localUrl ? `, ${p.localUrl}` : ''}`),
          ' ', h('button', { type: 'button', class: 'btn small', onclick: adopt(p) }, 'Adopt'))))))
        : h('p', null, 'No authentik installation was found on this PC.'),
        h('div', { class: 'actions' }, h('a', { class: 'btn primary', href: '#install/authentik' }, icon('download'), 'Install authentik…')),
        h('p', { class: 'hint' }, 'The App Catalog installs authentik as an ordinary Compose project (server, worker, PostgreSQL on a private network, generated secrets, an administrator created on first start). Come back here afterwards and adopt it.')];
    } else {
      body = [kv([['Project', inst.project || '(no Compose project)'], ['Installed by', inst.managed ? 'this manager (App Catalog)' : 'hand (adopted, managed with docker compose)'], ['Version', inst.version || '—'],
        ['Local address (this PC)', inst.localUrl ? ext(inst.localUrl, inst.localUrl) : 'not published on 127.0.0.1'], ['Traefik reaches it as', inst.serverContainer ? h('code', null, `http://${inst.serverContainer}:9000`) : '—', 'intermediate'],
        ['Folder', inst.folder || '—', 'advanced']]),
        h('ul', { class: 'checks' }, row(inst.server, 'Server'), row(inst.worker, 'Worker'), row(inst.database, 'PostgreSQL'),
          checkItem(inst.onProxyNetwork ? 'ok' : 'err', 'Shared proxy network', inst.onProxyNetwork ? 'The server is on the shared network; the database and worker are not.' : 'The server is not on the shared network: Traefik cannot reach it.')),
        !inst.server && inst.managed ? h('div', { class: 'actions' }, h('a', { class: 'btn primary', href: '#apps' }, 'Start it on the Installed apps page')) : null];
    }
    return h('section', { class: 'card', id: 'identity-install', 'aria-labelledby': 'id-inst-h' }, h('h2', { id: 'id-inst-h' }, 'authentik installation'), body);
  }

  // --- Administrator and recovery ------------------------------------------------------------------------------------------
  function adminSection(d) {
    const inst = d.install;
    const setup = d.health ? d.health.Setup : 'unknown';
    const local = inst && inst.localUrl;
    return h('section', { class: 'card', id: 'identity-admin', 'aria-labelledby': 'id-admin-h' }, h('h2', { id: 'id-admin-h' }, 'Administrator and recovery'),
      setup === 'pending' ? h('div', { class: 'callout warn', role: 'alert' }, h('p', null, h('strong', null, 'Claim this authentik now. '), 'Nobody has set the administrator password yet; until you do, anyone who can open the setup page could.'),
        local ? h('p', null, ext(`${local}/if/flow/initial-setup/`, 'Open the initial setup on this PC')) : null)
        : setup === 'done' ? h('p', null, stateChip('configured'), ' The administrator (akadmin) is set up. The manager never changes or resets its password.')
          : h('p', { class: 'muted' }, 'The setup state is shown once authentik answers.'),
      d.install && d.install.managed ? h('p', { class: 'small' }, 'Installed by this manager: the akadmin password is in ', h('code', null, `${d.install.folder}\\credentials.txt`), ' (readable by your Windows account only).') : null,
      h('details', { class: 'more' }, h('summary', null, 'If Google, Cloudflare or authentik stops working'),
        h('ul', null,
          h('li', null, 'akadmin always keeps its password: sign in on this PC at ', local ? ext(local, local) : 'the local address', ' even if Google sign-in or Cloudflare is down.'),
          h('li', null, 'Forgotten password: create a one-time recovery link with ', h('code', null, `docker compose exec worker ak create_recovery_key 10 akadmin`), ' in the authentik folder and open the printed path on the local address.'),
          h('li', null, 'If authentik is stopped, protected applications refuse requests (Traefik fails closed) until it runs again; remove the protection here or restore a backup to open them without authentik.'),
          h('li', null, 'Google sign-in never replaces the local administrator; accounts created through Google never become administrators automatically.'))));
  }

  // --- Connection settings (managed API credential) ---------------------------------------------------------------------
  // The reusable credential card (credentials.js): status, Test connection, Replace API token (always available). A
  // replacement is validated against this authentik before it replaces the saved token; a refused one changes nothing.
  function apiSection(ctx, d, reload) {
    const C = window.TPMCredentials;
    const v = d.credential || { status: 'missing', stored: false };
    const local = d.install && d.install.localUrl;
    const remove = (e) => withBusy(e.currentTarget, async () => {
      if (!await U.confirmDialog({ title: 'Remove the authentik API token', okText: 'Remove', danger: true, body: ['The manager can no longer read or change authentik. authentik itself and the token inside authentik are not changed (revoke it there under Directory > Tokens).'] })) return;
      await api('POST', '/api/identity/token/delete', { confirm: true }); await reload(false);
    });
    const fromBootstrap = (e) => withBusy(e.currentTarget, async () => {
      try { const r = await api('POST', '/api/identity/token', { fromBootstrap: true }); toast(`Connected as ${r.username}.`); await afterChange(r); }
      catch (x) { toast(x.message, true); }
    });
    async function afterChange(r) {
      await load(ctx, false);
      // Resume where the setup stands now: the next step that needs attention.
      if (r && r.next) location.hash = `#identity/${r.next}`; else await reload(false);
    }
    const explain = h('details', { class: 'more', open: v.status === 'insufficient' || !v.stored ? true : null }, h('summary', null, 'How to create an API token in authentik'),
      h('ol', { class: 'small' },
        h('li', null, 'Sign in to authentik as akadmin (or another administrator)', local ? [' at ', h('a', { href: `${local}/if/admin/#/core/tokens`, target: '_blank', rel: 'noopener noreferrer' }, `${local}/if/admin/`, ' ', icon('external'))] : '', '.'),
        h('li', null, 'Directory > Tokens and App passwords > Create.'),
        h('li', null, 'User: akadmin (or your administrator account). Intent: API Token. Turn "Expiring" off: authentik gives expiring API tokens its default token lifetime (1 day unless changed under System > Settings). If you keep it on, the manager warns before it runs out.'),
        h('li', null, 'Create, then use "Copy token" and paste it below.')),
      h('p', { class: 'small muted' }, 'Do not use a token whose user starts with ak-outpost-: it belongs to authentik\'s own outpost and cannot administer authentik.'));
    return h('div', { id: 'identity-api' },
      C.card({
        id: 'authentik-api', title: 'authentik: Connection settings', view: v, testPath: '/api/identity/token/test', replacePath: '/api/identity/token',
        tokenLabel: 'New authentik API token', serverLabel: 'Connected authentik server', accountLabel: 'API account', explain,
        tokenHint: 'Checked against this authentik (administrator account, API access) before it is saved, encrypted for this Windows account. If it is refused, the current token stays as it is. Nothing in authentik is changed.',
        extraActions: [d.install && d.install.managed && !v.ok ? h('button', { type: 'button', class: 'btn', onclick: fromBootstrap }, 'Use the token created at installation') : null,
          v.stored ? h('span', { 'data-min-level': 'advanced' }, h('button', { type: 'button', class: 'btn ghost', onclick: remove }, 'Remove saved token')) : null],
        onChanged: (r) => afterChange(r), rerender: () => reload(false),
      }));
  }

  // --- Public sign-in address --------------------------------------------------------------------------------------------
  function hostnameSection(ctx, d, reload) {
    const inst = d.install;
    const cfg = d.config.authentik;
    const f = form(ctx);
    if (!f.host) f.host = { hostname: d.suggestedHostname || '', exposure: d.cloudflareReady ? 'public' : 'local' };
    const host = h('input', { id: 'id-host', value: f.host.hostname, autocomplete: 'off', spellcheck: 'false', placeholder: 'auth.example.com' });
    host.addEventListener('input', () => { f.host.hostname = host.value.trim().toLowerCase(); });
    const exp = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'How the sign-in page is reached' },
      [['public', 'Internet: authentik is the login (recommended)', 'Google redirects back here; visitors sign in once, with authentik.', !d.cloudflareReady],
        ['access', 'Internet, behind Cloudflare Access too', 'Two logins (Cloudflare, then authentik). Only if you want both gates.', !d.cloudflareReady],
        ['local', 'This PC only', 'No DNS record or tunnel route. Google sign-in needs a public https address, so it cannot be used yet.', false]].map(([v, t, s, dis]) =>
        h('label', { class: `choice ${dis ? 'disabled' : ''}` }, h('input', { type: 'radio', name: 'id-exp', value: v, checked: f.host.exposure === v, disabled: dis, onchange: () => { f.host.exposure = v; } }), h('strong', null, t), h('span', { class: 'small' }, s))));
    const preview = (e) => withBusy(e.currentTarget, async () => {
      if (!inst || !inst.serverContainer) throw new Error('Adopt or install authentik first.');
      const name = d.routeBody ? d.routeBody.name : 'authentik';
      await api('POST', '/api/identity/hostname', { hostname: f.host.hostname, service: name });
      const fresh = await load(ctx, false);
      const body = JSON.parse(JSON.stringify(fresh.routeBody));
      body.service.hostnames = [f.host.hostname];
      body.service.cloudflare = { publish: f.host.exposure !== 'local', access: f.host.exposure === 'access' };
      body.cloudflare = { automate: f.host.exposure !== 'local' && fresh.cloudflareReady, accessEmails: f.host.exposure === 'access' && fresh.contactEmail ? [fresh.contactEmail] : [], cleanup: true };
      ctx.state.afterApply = () => reload(false);
      await ctx.startPlan(body);
    });
    const outpost = d.overview && d.overview.outpost;
    const outpostOk = outpost && cfg.publicUrl && outpost.authentikHost.replace(/\/+$/, '') === cfg.publicUrl.replace(/\/+$/, '');
    const outpostPlan = (e) => withBusy(e.currentTarget, async () => {
      const p = await api('POST', '/api/identity/outpost/plan', {});
      if (!p.canApply) { toast('The embedded outpost already uses the public address.'); return; }
      if (!await U.confirmDialog({ title: 'Embedded outpost', okText: 'Apply', body: [actionList(p.actions), 'Sign-in redirects for protected applications will send browsers to this address.'] })) return;
      await api('POST', '/api/identity/outpost/apply', { planId: p.planId, confirm: true }); toast('Embedded outpost updated.'); await reload(false);
    });
    const r = d.route;
    return h('section', { class: 'card', id: 'identity-hostname', 'aria-labelledby': 'id-host-h' }, h('h2', { id: 'id-host-h' }, 'Public sign-in address'),
      h('p', null, 'authentik needs one address of its own (its login page, Google\'s callback and the sign-in redirects for every protected application). It is routed through Traefik like any service, and published through your existing Cloudflare Tunnel; no second tunnel is created.'),
      field({ id: 'id-host', label: 'Hostname', control: host, hint: d.domains.length ? `Suggested from your domain ${d.domains[0]}. Checked against every existing route, DNS record and tunnel hostname in the preview.` : 'Connect Cloudflare and allow a domain first to publish it.' }),
      h('div', { class: 'field' }, h('span', { class: 'label' }, 'Who can reach the sign-in page?'), exp),
      f.host.exposure === 'access' ? h('div', { class: 'callout warn' }, h('p', null, 'With Cloudflare Access in front of authentik, Google\'s redirect back to authentik must pass Access first, and every visitor logs in twice. Only choose this deliberately.')) : null,
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: preview, disabled: !inst }, icon('eye'), r && r.exists ? 'Preview route change…' : 'Preview route…')),
      r && r.exists ? h('ul', { class: 'checks' },
        checkItem(r.router === 'enabled' ? 'ok' : 'err', `Traefik route svc-${r.service}`, `${r.target} (router ${r.router})`),
        checkItem(r.publish ? (d.cloudflare && d.cloudflare.dns ? 'ok' : 'warn') : 'neutral', 'Cloudflare', r.publish ? (d.cloudflare && d.cloudflare.dns ? 'DNS record and tunnel route created by the manager.' : 'Not created yet (or Cloudflare not connected).') : 'Not published (this PC only).'),
        r.access ? checkItem('warn', 'Cloudflare Access', 'Also in front of the sign-in page (two logins).') : null,
        checkItem(d.publicCheck ? (d.publicCheck.state === 'ok' ? 'ok' : 'err') : 'neutral', 'Public address', d.publicCheck ? d.publicCheck.message : 'Not checked yet: use "Run checks" (DNS can take a few minutes).'),
        outpost ? checkItem(outpostOk ? 'ok' : 'warn', 'Embedded outpost', outpostOk ? `Sends browsers to ${outpost.authentikHost}` : `Sends browsers to "${outpost.authentikHost || '(automatic)'}" instead of ${cfg.publicUrl || 'the public address'}.`) : null) : null,
      outpost && cfg.publicUrl && !outpostOk ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: outpostPlan }, 'Point the embedded outpost at the public address…')) : null);
  }

  // --- Managed in authentik --------------------------------------------------------------------------------------------
  // After the one-time setup the manager only connects applications; people and permissions live in authentik.
  function managedSection(d) {
    const l = d.adminLinks;
    if (!l) return null;
    const link = (href, text) => h('a', { class: 'btn small', href, target: '_blank', rel: 'noopener noreferrer' }, text, ' ', icon('external'));
    return h('section', { class: 'card', id: 'identity-managed', 'aria-labelledby': 'id-managed-h' },
      h('div', { class: 'card-head' }, h('h2', { id: 'id-managed-h' }, 'Users and access are managed in authentik'), h('span', { class: 'grow' }), link(l.base + '/if/admin/', 'Open in authentik')),
      h('p', null, 'Users, passwords, Google sign-in, invitations, group memberships, sign-in flows and who may open each application are set in authentik. Changes there take effect immediately: nothing has to be updated here and no Traefik file changes. The manager never overwrites them.'),
      h('div', { class: 'actions' }, link(l.users, 'Users'), link(l.groups, 'Groups'), link(l.invitations, 'Invitations'), link(l.applications, 'Applications and access'), link(l.flows, 'Flows'), link(l.sources, 'Google source')),
      h('p', { class: 'small muted' }, 'The manager handles the rest: deploying applications, routing, connecting them to authentik (ForwardAuth), connection health and removing protection.'));
  }

  // --- 5. Register with Google ---------------------------------------------------------------------------------------------
  function googleStep(ctx, d, f, reload, rerender) {
    const cfg = d.config.authentik;
    const g = d.google || {};
    const v = d.googleValues;
    const owner = cfg.owner || {};
    if (!v) return h('p', { class: 'muted' }, 'Set up the public sign-in address first: Google only accepts https addresses.');
    if (!f.owner) f.owner = { email: owner.email || d.contactEmail || '', makeAdmin: owner.makeAdmin !== false };
    if (!f.google) f.google = { clientId: cfg.google.clientId || '', manual: false, replace: false };
    const gf = f.google; const of = f.owner;
    const sub = (n, title, ...body) => h('section', { class: 'wiz-step', 'aria-labelledby': `gs-${n}` }, h('h3', { id: `gs-${n}` }, h('span', { class: 'step-num' }, n), title), body);
    // a. The owner (asked once).
    const ownerEmail = h('input', { id: 'id-owner', type: 'email', value: of.email, autocomplete: 'off', spellcheck: 'false', placeholder: 'you@gmail.com', disabled: !!owner.subject });
    ownerEmail.addEventListener('input', () => { of.email = ownerEmail.value.trim(); });
    const adminBox = h('input', { type: 'checkbox', checked: of.makeAdmin, disabled: !!owner.subject }); adminBox.addEventListener('change', () => { of.makeAdmin = adminBox.checked; });
    const saveOwner = (e) => withBusy(e.currentTarget, async () => { if (!L.isEmail(of.email)) { toast('Enter a valid email address.', true); return; } await api('POST', '/api/identity/owner', { email: of.email, makeAdmin: of.makeAdmin }); toast('Saved.'); await reload(false); });
    // e. Import the client JSON (preferred) or type the values.
    const jsonState = f.json;
    const fileInput = h('input', { type: 'file', id: 'id-g-json', accept: 'application/json,.json' });
    fileInput.addEventListener('change', () => {
      const file = fileInput.files && fileInput.files[0]; if (!file) return;
      if (file.size > 20000) { f.json = { error: 'That file is too large to be a Google OAuth client file.' }; rerender(); return; }
      const reader = new FileReader();
      reader.onload = async () => {
        const text = String(reader.result || '');
        try { const r = await api('POST', '/api/identity/google/inspect', { clientJson: text }); f.json = r.ok ? { ...r, text } : { ...r, text: '' }; }
        catch (x) { f.json = { error: x.message }; }
        f.plans.google = null; rerender();
      };
      reader.readAsText(file);
    });
    const cid = h('input', { id: 'id-g-cid', value: gf.clientId, autocomplete: 'off', spellcheck: 'false', placeholder: '1234567890-abc….apps.googleusercontent.com' });
    cid.addEventListener('input', () => { gf.clientId = cid.value.trim(); f.plans.google = null; });
    const sec = h('input', { id: 'id-g-sec', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: g.source ? 'Only to replace it' : 'GOCSPX-…' });
    sec.value = f.secret || ''; sec.addEventListener('input', () => { f.secret = sec.value; f.plans.google = null; });
    const err = h('p', { class: 'form-error', role: 'alert' });
    const replaceBox = h('input', { type: 'checkbox', checked: gf.replace }); replaceBox.addEventListener('change', () => { gf.replace = replaceBox.checked; f.plans.google = null; });
    const body = () => (jsonState && jsonState.ok && jsonState.text && !gf.manual ? { clientJson: jsonState.text, replace: gf.replace } : { clientId: gf.clientId, clientSecret: f.secret || '', replace: gf.replace });
    const plan = f.plans.google;
    const previewBtn = h('button', { type: 'button', class: 'btn primary' }, icon('eye'), 'Check and preview the authentik changes');
    previewBtn.addEventListener('click', () => withBusy(previewBtn, async () => {
      err.textContent = '';
      if (!owner.email) { err.textContent = 'Save the owner\'s Google account first (a).'; return; }
      const b = body();
      if (!b.clientJson && (!L.isGoogleClientId(b.clientId) || (!g.source && !b.clientSecret))) { err.textContent = 'Import the downloaded JSON file, or enter the client ID and secret.'; return; }
      try { f.plans.google = await api('POST', '/api/identity/google/plan', b); rerender(); }
      catch (x) { err.textContent = x.message; if (x.data && x.data.needsReplace) { gf.replaceOffered = true; rerender(); } }
    }));
    const applyBtn = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Turn on Google sign-in');
    const reviewed = h('input', { type: 'checkbox' }); reviewed.addEventListener('change', () => { applyBtn.disabled = !reviewed.checked; });
    applyBtn.addEventListener('click', () => withBusy(applyBtn, async () => {
      const r = await api('POST', '/api/identity/google/apply', { planId: plan.planId, confirm: true });
      f.plans.google = null; if (r.ok) { f.secret = ''; f.json = null; f.googleResult = r; toast('Google sign-in is on.'); } else toast(r.message, true);
      await reload(false);
    }));
    const res = f.googleResult;
    return [
      sub('a', 'Who owns this sign-in?',
        h('p', null, 'The Google account of the person who owns this authentik. Only this account can create an authentik account with Google at first; everyone else is added later in authentik. It becomes an Internal authentik account and the first member of ', h('strong', null, 'DTC owners'), '.'),
        field({ id: 'id-owner', label: 'Owner\'s Google account', control: ownerEmail, helpId: 'authentik-user-type', hint: owner.subject ? 'Verified with Google; change people in authentik from now on.' : 'Can be changed until the owner has signed in with Google.' }),
        h('label', { class: 'check' }, adminBox, h('span', null, 'Also make this account an authentik administrator (akadmin keeps its password either way)')),
        owner.subject ? null : h('div', { class: 'actions' }, h('button', { type: 'button', class: owner.email ? 'btn' : 'btn primary', onclick: saveOwner }, owner.email ? 'Save changes' : 'Save'))),
      sub('b', 'Values you will need (copy them)',
        copyRow('App name', v.AppName, 'gv-app'), copyRow('Support email', of.email || owner.email || '(your email)', 'gv-mail'), copyRow('Authorized domain', v.AuthorizedDomain, 'gv-dom', 'google-branding'),
        copyRow('Application type', v.ClientType, 'gv-type'), copyRow('Authorized redirect URI', v.RedirectUri, 'gv-redir', 'redirect-uri'),
        gate('advanced', h('p', { class: 'small muted' }, 'Scopes: ', v.ScopeNames.join(', '), ' (basic, non-sensitive; Google does not require verification for them). No JavaScript origins and no Google API are needed.'))),
      sub('c', 'In Google Cloud (about five minutes)',
        h('ol', { class: 'gsteps' },
          h('li', null, h('strong', null, 'Project. '), ext(v.ConsoleUrls.projects, 'Create a project'), ' (any name), or pick an existing one at the top of the console.'),
          h('li', { 'data-help-host': '' }, h('strong', null, 'Branding. '), ext(v.ConsoleUrls.branding, 'Google Auth Platform > Branding'), ' (or "Get started"): App name ', h('code', null, v.AppName), ', User support email, Developer contact email. Leave logo, home page, privacy policy and terms empty: they are optional. Under Authorized domains add ', h('code', null, v.AuthorizedDomain), '.', help('google-branding', 'Branding')),
          h('li', { 'data-help-host': '' }, h('strong', null, 'Audience. '), ext(v.ConsoleUrls.audience, 'Audience'), ': choose ', h('strong', null, 'External'), ' for ordinary Gmail accounts (Internal is only for Google Workspace organizations). In ', h('strong', null, 'Testing'), ', add ', h('code', null, of.email || owner.email || 'the owner\'s address'), ' under Test users, or press Publish app. Publishing does not let anyone into your applications: authentik still decides.', help('google-audience', 'Audience'), help('google-testing', 'Testing')),
          h('li', { 'data-help-host': '' }, h('strong', null, 'Client. '), ext(v.ConsoleUrls.clients, 'Clients'), ' > Create client > Application type ', h('strong', null, 'Web application'), ', name ', h('code', null, v.AppName), '. Under Authorized redirect URIs press Add URI and paste ', h('code', null, v.RedirectUri), ' exactly. Create.', help('redirect-uri', 'Redirect URI')),
          h('li', { 'data-help-host': '' }, h('strong', null, 'Download. '), 'In the dialog that appears, press ', h('strong', null, 'Download JSON'), ' (Google shows the secret only now; if you closed it, open the client, Add secret, then download).', help('oauth-json', 'Client JSON')))),
      sub('d', 'Import the downloaded file',
        g.source && !gf.replace ? h('div', { class: 'callout', role: 'status' }, h('p', null, stateChip('configured'), ` Google sign-in is already connected (client ${g.source.ConsumerKey}). It is only changed if you choose to replace it.`),
          h('label', { class: 'check' }, replaceBox, h('span', null, 'Replace the Google client (for example after creating a new one in Google Cloud)'))) : null,
        !g.source || gf.replace ? [
          gf.manual ? null : field({ id: 'id-g-json', label: 'Google client file (.json)', control: fileInput, helpId: 'oauth-json', hint: 'Read on this PC and checked: Web application client, client ID and secret present, the redirect URI above, Google endpoints. The secret is passed to authentik once and never stored by the manager.' }),
          !gf.manual && jsonState ? (jsonState.ok ? h('ul', { class: 'checks' }, checkItem('ok', 'Web application client', jsonState.clientId), checkItem('ok', 'Client secret', 'present (not shown)'), checkItem('ok', 'Redirect URI', jsonState.expectedRedirectUri), ...arr(jsonState.warnings).map((w) => checkItem('warn', 'Note', w)))
            : h('div', { class: 'callout err', role: 'alert' }, arr(jsonState.errors).length ? arr(jsonState.errors).map((x) => h('p', null, x)) : h('p', null, jsonState.error || 'The file could not be read.'))) : null,
          h('p', { class: 'small' }, h('button', { type: 'button', class: 'link-btn', onclick: () => { gf.manual = !gf.manual; f.plans.google = null; rerender(); } }, gf.manual ? 'Use the JSON file instead' : 'No file? Enter the client ID and secret instead')),
          gf.manual ? [field({ id: 'id-g-cid', label: 'Client ID', control: cid }), field({ id: 'id-g-sec', label: 'Client secret', control: sec, hint: 'Sent once to this PC\'s manager and straight into authentik; never stored, shown or logged.' })] : null,
          h('div', { class: 'actions' }, previewBtn), err] : null),
      plan ? sub('e', 'Turn on Google sign-in', actionList(plan.actions), h('ul', null, arr(plan.notes).map((n) => h('li', { class: 'small' }, n))),
        h('div', { class: 'actions' }, h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), applyBtn)) : null,
      res ? sub('e', 'Done in authentik', actionList(res.actions)) : null,
      g.source ? h('ul', { class: 'checks' },
        checkItem('ok', 'Google source in authentik', `client ${g.source.ConsumerKey}`),
        checkItem(g.redirect ? (g.redirect.ok ? 'ok' : 'err') : 'neutral', 'Redirect to Google', g.redirect ? g.redirect.message : 'Checked when the page loads.')) : null,
    ];
  }

  // --- 6. Sign-in page -------------------------------------------------------------------------------------------------------
  function signinStep(ctx, d, f, reload, rerender) {
    const lp = d.config.authentik.loginPage || {};
    const pub = d.config.authentik.publicUrl;
    const local = d.install && d.install.localUrl;
    const plan = f.loginPlan;
    const preview = (e) => withBusy(e.currentTarget, async () => { f.loginPlan = await api('POST', '/api/identity/loginpage/plan', {}); rerender(); });
    const apply = (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/loginpage/apply', { planId: plan.planId, confirm: true }); f.loginPlan = null; toast('The sign-in page shows Google first.'); await reload(false); });
    const restore = (e) => withBusy(e.currentTarget, async () => {
      if (!await U.confirmDialog({ title: 'Restore the previous sign-in page', okText: 'Restore', body: ['authentik shows its previous sign-in flow and title again. Google sign-in and all accounts stay as they are.'] })) return;
      await api('POST', '/api/identity/loginpage/restore', { confirm: true }); await reload(false);
    });
    return [
      h('div', { class: 'login-preview', 'aria-hidden': 'true' }, h('div', { class: 'lp-card' }, h('strong', null, `Sign in to ${(d.config.authentik.hostname || '').replace(/^[^.]+\./, '')}`),
        h('div', { class: 'lp-google' }, 'Continue with Google'), h('div', { class: 'lp-or' }, 'or'), h('div', { class: 'lp-field' }, 'Email or username'), h('div', { class: 'lp-field' }, 'Password'), h('div', { class: 'lp-btn' }, 'Log in'))),
      h('ul', null,
        h('li', null, 'Google comes first: one click opens Google\'s own account chooser; nobody types an email into authentik first.'),
        h('li', null, 'Email or username with password stays below it, for local accounts.'),
        h('li', null, 'A separate copy of authentik\'s sign-in flow is used; the original flow stays untouched as the recovery route', local ? [': ', ext(`${local}/if/flow/default-authentication-flow/`, 'local recovery sign-in')] : '', '.', help('local-recovery', 'Recovery'))),
      lp.appliedAt ? [h('p', null, stateChip('configured'), ` Applied ${lp.appliedAt}. `, pub ? ext(`${pub}/`, 'Open the sign-in page') : null),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn ghost', onclick: restore }, 'Restore the previous sign-in page'))]
        : plan ? [actionList(plan.actions), h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: apply, disabled: !plan.canApply }, 'Use this sign-in page'))]
          : h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: preview }, icon('eye'), 'Preview')),
    ];
  }

  // --- 7. Verify the owner ---------------------------------------------------------------------------------------------------
  function ownerStep(ctx, d, f, reload, rerender, go) {
    const cfg = d.config.authentik;
    const o = cfg.owner || {};
    const local = d.config.authMode === 'local';
    const pub = cfg.publicUrl;
    const v = f.verify;
    const check = (repair) => (e) => withBusy(e.currentTarget, async () => {
      try { f.verify = await api('POST', '/api/identity/owner/verify', { repair: !!repair }); }
      catch (x) { f.verify = { ok: false, message: x.message, items: [] }; }
      if (f.verify.ok) { await load(ctx, false); toast('Owner verified.'); }
      rerender();
    });
    const startLocal = (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/owner/local-start', {}); await reload(false); });
    const items = v && arr(v.items).length ? h('ul', { class: 'checks owner-checks' }, arr(v.items).map((x) => checkItem(x.ok ? 'ok' : 'err', x.label, x.message))) : null;
    if (o.verifiedAt && (local || o.subject)) {
      return [h('div', { class: 'verified-banner', role: 'status' }, icon('check'), h('div', null, h('strong', null, 'Owner verified'), h('p', null, `${local || !o.email ? 'Local administrator' : o.email} signed in as '${o.username}' (${o.verifiedAt}). The account is Internal and in DTC owners${o.makeAdmin && !local ? ', with administrator rights' : ''}.`))),
        items, h('p', { class: 'small muted' }, 'From now on users and access are managed in authentik.')];
    }
    if (local) {
      return [h('p', null, 'Prove that the local administrator can sign in: start the check, sign in on the sign-in page with your administrator account (akadmin and its password), then come back here.'),
        !o.localSince ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: startLocal }, 'Start the sign-in check'))
          : [h('div', { class: 'actions' }, pub ? h('a', { class: 'btn primary', href: `${pub}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Sign in now ', icon('external')) : null,
            h('button', { type: 'button', class: 'btn', onclick: check(false) }, icon('refresh'), "I've signed in - check again"))],
        v && !v.ok ? h('div', { class: 'callout warn', role: 'status' }, h('p', null, v.message), v.needsRepair ? h('button', { type: 'button', class: 'btn small', onclick: check(true) }, 'Repair: make the account Internal') : null) : null, items];
    }
    return [
      o.email ? h('p', null, 'Sign in once as the owner (', h('strong', null, o.email), ') with Google. It opens Google\'s own account chooser directly; pick that account. Come back to this tab afterwards.') : h('p', { class: 'callout warn' }, 'Enter the owner\'s Google account in the previous step first.'),
      pub && o.email ? h('div', { class: 'actions big' }, h('a', { class: 'btn primary google-btn', href: `${pub}/source/oauth/login/${cfg.google.slug}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Continue with Google ', icon('external')),
        h('button', { type: 'button', class: 'btn', onclick: check(false) }, icon('refresh'), "I've signed in - check again")) : null,
      v && !v.ok ? h('div', { class: 'callout warn', role: 'status' }, h('p', null, v.message), v.needsRepair ? h('button', { type: 'button', class: 'btn small', onclick: check(true) }, 'Repair: make the account Internal') : null) : null,
      items,
      h('details', { class: 'more' }, h('summary', null, 'What is checked?'), h('ul', { class: 'small' },
        h('li', null, 'The Google account with the owner\'s address (Google verified it) signed in and is the same Google identity as the first time.'),
        h('li', null, 'The authentik account is Internal (it can open its authentik dashboard).', help('authentik-user-type', 'Internal account')),
        h('li', null, 'It is in DTC owners', help('dtc-owners', 'DTC owners'), ' and, if you chose it, an authentik administrator.'),
        h('li', null, 'The sign-in completed. Nothing can be marked verified by hand.'))),
    ];
  }

  // --- 8. Protect applications -----------------------------------------------------------------------------------------------
  // Selecting never re-renders the page (no jumping): the count and the button update in place.
  function protectStep(ctx, d, f, reload, rerender) {
    const connected = d.token && d.token.ok;
    const services = arr(d.services).filter((s) => !s.isIdentity);
    const byName = Object.fromEntries(arr(d.apps).map((a) => [a.service, a]));
    if (!f.protect) f.protect = { selected: {}, access: 'keep', plan: null, result: null };
    const pf = f.protect;
    const compatible = (s) => s.enabled && arr(s.hostnames).length === 1 && s.auth !== 'authentik';
    const why = (s) => (!s.enabled ? 'disabled' : arr(s.hostnames).length !== 1 ? 'several hostnames' : '');
    const link = d.adminLinks;
    const candidates = services.filter(compatible);
    Object.keys(pf.selected).forEach((k) => { if (!candidates.some((s) => s.name === k)) delete pf.selected[k]; });
    const count = h('span', { class: 'sel-count', 'aria-live': 'polite' });
    const protectBtn = h('button', { type: 'button', class: 'btn primary', id: 'id-protect-btn' }, icon('lock'), 'Protect selected with authentik…');
    const boxes = [];
    const sync = () => {
      const n = Object.keys(pf.selected).filter((k) => pf.selected[k]).length;
      count.textContent = `${n} of ${candidates.length} selected`;
      protectBtn.disabled = !n || !connected;
      protectBtn.lastChild.textContent = `Protect ${n || ''} selected with authentik…`.replace('  ', ' ');
      boxes.forEach((b) => { b.checked = !!pf.selected[b.dataset.name]; });
    };
    const rows = services.map((s) => {
      const a = byName[s.name];
      const prot = s.auth === 'authentik';
      const ps = L.appProtectionState(a);
      const state = a ? (ps === 'verified' ? (a.verifiedAt ? 'verified' : 'auth-required') : ({ unchecked: 'configured', disabled: 'configured' })[ps] || 'failed') : 'not-configured';
      let cell;
      if (prot) cell = h('span', { title: 'Already protected (not affected by this selection)' }, icon('lock'), h('span', { class: 'sr-only' }, 'Already protected'));
      else {
        const box = h('input', { type: 'checkbox', 'data-name': s.name, id: `sel-${s.name}`, 'aria-label': `Select ${s.displayName || s.name}`, checked: !!pf.selected[s.name], disabled: !compatible(s) || !connected });
        box.addEventListener('change', () => { pf.selected[s.name] = box.checked; pf.plan = null; sync(); });
        boxes.push(box); cell = box;
      }
      const access = prot && a ? (a.rules === null || a.rules === undefined ? '' : a.ownerOnly ? 'owner only (DTC owners)' : a.rules ? `${a.rules} rule(s) in authentik` : 'no rule (everyone signed in)') : '';
      return h('tr', { class: prot ? 'protected' : '' },
        h('td', null, cell),
        h('td', null, h('label', { for: prot ? null : `sel-${s.name}` }, s.displayName || s.name), why(s) && !prot ? h('span', { class: 'small muted' }, ` (${why(s)})`) : null),
        h('td', null, arr(s.hostnames).join(', ')),
        h('td', null, prot ? [h('span', { class: 'small' }, 'Already protected '), stateChip(state), access ? h('div', { class: 'small muted' }, access) : null] : s.publish && s.access ? plainChip('Cloudflare Access', 'info') : !s.publish ? plainChip('Local only') : plainChip('Public', 'warn')),
        h('td', null, prot ? [link ? h('a', { class: 'btn small', href: `${link.base}/if/admin/#/core/applications/${a ? a.slug : `dm-${s.name}`}`, target: '_blank', rel: 'noopener noreferrer' }, 'Open in authentik ', icon('external')) : null,
          h('button', { type: 'button', class: 'btn small ghost', onclick: (e) => withBusy(e.currentTarget, async () => { pf.plan = await api('POST', '/api/identity/unprotect/plan', { service: s.name, cloudflareAccess: 'keep' }); pf.plan.remove = true; pf.result = null; rerender(); }) }, 'Remove protection…')] : null));
    });
    const selAll = h('button', { type: 'button', class: 'btn small', id: 'id-sel-all', disabled: !candidates.length || !connected, onclick: () => { candidates.forEach((s) => { pf.selected[s.name] = true; }); pf.plan = null; sync(); } }, 'Select all');
    const clrAll = h('button', { type: 'button', class: 'btn small ghost', id: 'id-sel-none', onclick: () => { pf.selected = {}; pf.plan = null; sync(); } }, 'Clear all');
    const table = services.length ? h('table', { class: 'table protect-table' }, h('thead', null, h('tr', null, h('th', null, h('span', { class: 'sr-only' }, 'Select')), h('th', null, 'Application'), h('th', null, 'Address'), h('th', null, 'Sign-in'), h('th', null, ''))), h('tbody', null, rows))
      : h('p', { class: 'muted' }, 'No services yet. Publish an application on the Services page first.');
    const accessSel = h('select', { id: 'id-p-access' }, h('option', { value: 'keep', selected: pf.access === 'keep' }, 'Keep Cloudflare Access as it is (default)'), h('option', { value: 'remove', selected: pf.access === 'remove' }, 'Remove Cloudflare Access from the selected applications (authentik becomes the only login)'));
    accessSel.addEventListener('change', () => { pf.access = accessSel.value; pf.plan = null; });
    protectBtn.addEventListener('click', () => withBusy(protectBtn, async () => {
      const chosen = Object.keys(pf.selected).filter((k) => pf.selected[k]);
      pf.plan = await api('POST', '/api/identity/protect/plan', { services: chosen, cloudflareAccess: pf.access }); pf.plan.remove = false; pf.result = null; rerender();
      const r = document.getElementById('id-protect-review'); if (r) r.scrollIntoView({ block: 'start' });
    }));
    let review = null;
    const plan = pf.plan;
    if (plan) {
      const its = arr(plan.items);
      const reviewed = h('input', { type: 'checkbox' });
      const overwrites = its.flatMap((it) => arr(it.traefik.cloudflare.actions).filter((x) => x.overwrite).map((x) => { const b = h('input', { type: 'checkbox', 'data-id': x.id }); return h('label', { class: 'check' }, b, h('span', null, `Overwrite: ${x.summary}`)); }));
      const apply = h('button', { type: 'button', class: `btn ${plan.remove ? 'danger' : 'primary'}`, disabled: true }, plan.remove ? 'Remove protection' : `Protect ${its.length} application(s)`);
      const goesPublic = plan.remove && its.some((it) => it.becomesPublic);
      const ackPublic = h('input', { type: 'checkbox', id: 'id-ack-public' });
      const syncApply = () => { apply.disabled = !(reviewed.checked && plan.canApply && overwrites.every((o) => o.querySelector('input').checked) && (!goesPublic || ackPublic.checked)); };
      reviewed.addEventListener('change', syncApply); ackPublic.addEventListener('change', syncApply); overwrites.forEach((o) => o.querySelector('input').addEventListener('change', syncApply));
      apply.addEventListener('click', () => withBusy(apply, async () => {
        const ids = overwrites.map((o) => o.querySelector('input')).filter((b) => b.checked).map((b) => b.dataset.id);
        const progress = document.getElementById('id-protect-progress'); if (progress) progress.textContent = `Working on ${its.length} application(s), one after the other…`;
        pf.result = await api('POST', `/api/identity/${plan.remove ? 'unprotect' : 'protect'}/apply`, { planId: plan.planId, confirm: true, confirmOverwrites: ids });
        pf.plan = null; pf.selected = {}; await reload(false);
        const r = document.getElementById('id-protect-result'); if (r) r.scrollIntoView({ block: 'start' });
      }));
      review = h('div', { class: 'card inset', id: 'id-protect-review' }, h('h3', null, plan.remove ? 'Preview: remove protection' : `Preview: protect ${its.length} application(s)`),
        its.map((it) => h('details', { class: 'more', open: its.length === 1 ? true : null }, h('summary', null, `${it.displayName} (${it.hostname})${it.errors ? ' — has problems' : ''}`),
          arr(it.notes).map((n) => h('div', { class: 'callout' }, h('p', null, n))),
          h('h4', null, 'authentik'), actionList(it.authentik),
          h('h4', null, 'Traefik'), arr(it.traefik.traefik.changes).length ? arr(it.traefik.traefik.changes).map((c) => h('details', { class: 'tech' }, h('summary', null, `${c.action}: ${c.file}`), U.diffBlock(c.diff))) : h('p', { class: 'muted' }, 'No route change.'),
          arr(it.traefik.traefik.issues).filter((i) => i.Level === 'Error').length ? h('ul', { class: 'checks' }, arr(it.traefik.traefik.issues).filter((i) => i.Level === 'Error').map((i) => checkItem('err', i.Field, i.Message))) : null,
          arr(it.traefik.cloudflare.actions).filter((x) => x.kind !== 'none').length ? [h('h4', null, 'Cloudflare'), h('ul', { class: 'checks' }, arr(it.traefik.cloudflare.actions).filter((x) => x.kind !== 'none').map((x) => checkItem('auth', x.summary, x.detail)))] : null,
          plan.remove && arr(it.keeps).length ? [h('h4', null, 'Stays as it is'), h('ul', { class: 'checks', id: 'id-unprotect-keeps' }, arr(it.keeps).map((k) => checkItem('ok', k, '')))] : null)),
        goesPublic ? h('div', { class: 'callout warn', id: 'id-public-warning' }, h('p', null, h('strong', null, 'Public without sign-in. '), 'After this, anyone on the Internet can open the application without signing in (no authentik, no Cloudflare Access). Its own login, if it has one, is the only protection.'),
          h('label', { class: 'check' }, ackPublic, h('span', null, 'I understand that this application becomes publicly accessible.'))) : null,
        overwrites, plan.canApply ? h('div', { class: 'actions' }, h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), apply, h('button', { type: 'button', class: 'btn ghost', onclick: () => { pf.plan = null; rerender(); } }, 'Cancel'))
          : h('p', { class: 'muted' }, 'The preview has problems (see above); nothing can be applied.'),
        h('p', { class: 'small muted', id: 'id-protect-progress', role: 'status', 'aria-live': 'polite' }));
    }
    const res = pf.result;
    const stepState = (x, name) => { const st = arr(x.traefik && x.traefik.steps).find((s) => s.name === name); return st ? (st.status === 'Done' ? 'ok' : st.status === 'Failed' ? 'err' : 'warn') : 'neutral'; };
    const result = res ? h('div', { class: `callout ${res.ok ? '' : 'err'}`, role: 'status', id: 'id-protect-result' }, h('p', null, h('strong', null, res.ok ? 'Done. ' : 'Not everything completed. '), res.message || ''),
      arr(res.results).map((x) => h('div', { class: 'protect-res' }, h('strong', null, x.service, ' '), x.ok ? plainChip('Protected', 'ok') : plainChip('Not protected', 'err'),
        h('ul', { class: 'checks' },
          checkItem(stepState(x, 'Backend reachable from Traefik'), 'Backend reachable', (arr(x.traefik && x.traefik.steps).find((s) => s.name === 'Backend reachable from Traefik') || {}).message || 'Not checked.'),
          checkItem(stepState(x, 'Traefik reload'), 'Route loaded by Traefik', (arr(x.traefik && x.traefik.steps).find((s) => s.name === 'Traefik reload') || {}).message || ''),
          checkItem(x.challenge ? (['auth', 'misrouted'].includes(x.challenge.State) ? 'ok' : 'err') : 'neutral', 'ForwardAuth enforced', x.challenge ? (x.challenge.State === 'misrouted' ? 'Anonymous visitors are stopped by authentik.' : x.challenge.Message) : (x.message || 'Not checked.')),
          x.challenge && ['auth', 'misrouted'].includes(x.challenge.State) ? checkItem(x.challenge.State === 'auth' ? 'ok' : 'err', 'Browsers sent to the public sign-in page', x.challenge.State === 'auth' ? 'The sign-in redirect uses the public address.' : x.challenge.Message) : null,
          checkItem('neutral', 'Sign-in verified', 'Shown as Verified after someone opened it through authentik.'))))) : null;
    const out = [
      h('p', null, 'Tick the applications that should require signing in. New ones start owner-only (group DTC owners); applications that already have rules in authentik keep them. Already protected applications are not affected by what you tick.', help('forwardauth', 'ForwardAuth'), help('dtc-owners', 'DTC owners')),
      !connected ? h('p', { class: 'hint' }, 'Connect the manager to authentik first.') : null,
      h('div', { class: 'sel-bar' }, selAll, clrAll, count),
      table,
      h('div', { class: 'protect-bar' }, field({ id: 'id-p-access', label: 'Cloudflare Access', control: accessSel }), h('div', { class: 'actions' }, protectBtn)),
      review, result,
    ];
    sync();
    return out;
  }

  // --- 9. Finished -------------------------------------------------------------------------------------------------------------
  function doneStep(d, wiz, go) {
    const pr = wiz.protection;
    const line = pr.state === 'skipped' ? 'Protecting applications was skipped: no application asks for sign-in yet.'
      : `${pr.protected} of ${pr.total} application(s) protected${pr.state === 'done' ? ' and verified just now' : ''}${pr.unprotected ? `; ${pr.unprotected} not protected` : ''}.`;
    const manage = h('button', { type: 'button', class: 'btn', id: 'id-manage-protection', onclick: () => go('apps') }, icon('lock'), pr.protected ? 'Manage protection…' : 'Protect applications…');
    return [wiz.complete ? h('div', { class: 'verified-banner', role: 'status' }, icon('check'), h('div', null, h('strong', null, 'Sign-in is set up'),
      h('p', { id: 'id-done-summary' }, `${line} Manage people, groups, invitations and who may open what in authentik.`)))
      : h('div', { class: 'callout warn', role: 'status' }, h('p', { id: 'id-done-summary' }, line)),
    h('div', { class: 'actions' }, manage), managedSection(d)];
  }

  // --- Health (advanced) -----------------------------------------------------------------------------------------------------
  function healthSection(d) {
    const comps = arr(d.model && d.model.components);
    return h('section', { class: 'card', id: 'identity-health', 'aria-labelledby': 'id-health-h' }, h('h2', { id: 'id-health-h' }, 'Health'),
      h('p', { class: 'small muted' }, 'Browser → Cloudflare → tunnel → Traefik → authentik authorization → application. Each part is checked on its own; "Verified" needs real sign-in evidence.'),
      h('ul', { class: 'checks' }, comps.map((c) => checkItem(stateTone(c.state), c.label, `${L.identityState(c.state).label}${c.message ? ` — ${c.message}` : ''}`))),
      d.overviewError ? h('div', { class: 'callout err' }, h('p', null, d.overviewError)) : null,
      h('p', { class: 'small muted' }, `Checked ${d.checkedAt}.`));
  }
})();
