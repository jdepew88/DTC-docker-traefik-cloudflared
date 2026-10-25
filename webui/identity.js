'use strict';
// Identity & Access (GET /api/identity): choose an identity provider, install or adopt authentik, connect the manager
// to its API, publish the sign-in page, connect Google sign-in (guided: Google offers no API for OAuth clients), protect
// applications with Traefik ForwardAuth and verify each part. Every change is previewed and confirmed; secrets are typed
// into password fields, sent once to the local server and never stored in the browser.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, fill, icon, plainChip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const stateChip = (state) => { const s = L.identityState(state); return h('span', { class: `chip ${s.tone}` }, icon(s.icon), s.label); };
  const stateTone = (state) => ({ ok: 'ok', err: 'err', warn: 'warn', auth: 'auth', info: 'neutral', neutral: 'neutral' })[L.identityState(state).tone];
  const ext = (href, text) => h('a', { href, target: '_blank', rel: 'noopener noreferrer' }, text, ' ', icon('external'));
  function copyRow(label, value, id) {
    const btn = h('button', { type: 'button', class: 'btn small', 'aria-label': `Copy ${label}`, onclick: async () => { try { await navigator.clipboard.writeText(value); toast(`Copied: ${label}`); } catch (e) { toast('Copy failed; select the text instead.', true); } } }, 'Copy');
    return h('div', { class: 'copy-row' }, h('span', { class: 'copy-label', id }, label), h('code', { 'aria-labelledby': id }, value), btn);
  }
  const actionList = (actions) => h('ul', { class: 'checks' }, arr(actions).map((a) => checkItem(
    a.kind === 'none' ? 'neutral' : a.status === 'Failed' ? 'err' : a.status === 'Done' ? 'ok' : a.kind === 'delete' ? 'warn' : 'auth',
    `${({ create: 'Create', update: 'Change', delete: 'Remove', none: 'No change' })[a.kind] || a.kind}: ${a.summary}`, a.detail || a.message || '')));

  async function load(ctx, deep) { ctx.state.identity = await api('GET', `/api/identity${deep ? '?deep=1' : ''}`); return ctx.state.identity; }
  const form = (ctx) => ctx.state.forms.identity || (ctx.state.forms.identity = { google: null, protect: null, plans: {}, secret: '' });

  P.identity = async (main, ctx, sub) => {
    if (!ctx.state.setup) await ctx.refresh();
    if (!(ctx.state.setup && ctx.state.setup.installed)) {
      fill(main, head('Access', 'Identity & Access', 'Install the Traefik deployment first.'), h('p', null, h('a', { href: '#setup' }, 'Go to the setup journey')));
      return;
    }
    fill(main, head('Access', 'Identity & Access', 'Loading…'));
    const d = await load(ctx, sub === 'check');
    render(main, ctx, d);
  };

  function render(main, ctx, d) {
    const f = form(ctx);
    const rerender = () => render(main, ctx, ctx.state.identity);
    const reload = async (deep) => { await load(ctx, deep); rerender(); };
    const steps = arr(d.model && d.model.steps);
    const next = L.identityNextStep(steps);
    const progress = h('section', { class: 'card', 'aria-labelledby': 'id-progress' },
      h('div', { class: 'card-head' }, h('h2', { id: 'id-progress' }, 'Setup progress'), h('span', { class: 'grow' }),
        h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, () => reload(true)) }, icon('refresh'), 'Run checks')),
      h('ol', { class: 'id-steps' }, steps.map((s) => h('li', { class: next && next.id === s.id ? 'current' : '' },
        h('a', { href: `#identity-${s.id}` }, h('strong', null, s.label)), ' ', stateChip(s.state), s.optional ? h('span', { class: 'muted small' }, ' (optional)') : null,
        h('p', { class: 'small muted' }, s.message)))),
      d.progress && d.progress.step ? gate('advanced', h('p', { class: 'small muted' }, `Last step worked on: ${d.progress.step} (${d.progress.status}) at ${d.progress.at}.`)) : null,
      next ? h('p', null, h('strong', null, 'Next: '), next.label, ' — ', next.message) : steps.length ? h('p', { class: 'muted' }, 'Nothing is waiting for you.') : null);

    const sections = [providerSection(ctx, d, reload)];
    if (d.provider === 'authentik') {
      sections.push(installSection(ctx, d, reload), adminSection(d), apiSection(ctx, d, reload), hostnameSection(ctx, d, reload),
        googleSection(ctx, d, f, reload, rerender), protectSection(ctx, d, f, reload, rerender), healthSection(d));
    }
    fill(main,
      head('Access', 'Identity & Access', 'Optional: a self-hosted sign-in (authentik) with Google accounts, in front of the applications you choose. Basic setup and Cloudflare Access work without it.',
        h('a', { class: 'btn', href: '#explorer' }, icon('network'), 'Infrastructure Explorer')),
      progress, sections,
      gate('expert', technical([JSON.stringify({ config: d.config, overview: d.overview, model: d.model }, null, 2)], 'Raw identity state (no secrets)')));
  }

  // --- Provider ----------------------------------------------------------------------------------------------------------
  function providerSection(ctx, d, reload) {
    const choose = (id) => (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/provider', { provider: id }); toast('Saved.'); await reload(false); });
    return h('section', { class: 'card', id: 'identity-provider', 'aria-labelledby': 'id-prov-h' }, h('h2', { id: 'id-prov-h' }, 'Identity provider'),
      h('div', { class: 'choice-cards', role: 'list' }, arr(d.providers).map((p) => {
        const current = d.provider === p.id;
        const disabled = p.status !== 'integrated';
        return h('div', { class: `choice ${current ? 'selected' : ''} ${disabled ? 'disabled' : ''}`, role: 'listitem' },
          h('strong', null, p.name), current ? plainChip('Selected', 'ok') : disabled ? plainChip('Install only', 'warn') : null,
          h('p', { class: 'small' }, p.summary),
          disabled ? h('a', { class: 'btn small', href: `#install/${p.catalogId}` }, 'App Catalog') : current ? null : h('button', { type: 'button', class: 'btn small primary', onclick: choose(p.id) }, `Choose ${p.name}`));
      })),
      d.provider === 'authentik' ? h('p', { class: 'small muted' }, 'Only one identity provider is set up at a time; nothing is installed automatically.') : null);
  }

  // --- Installation ------------------------------------------------------------------------------------------------------
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

  // --- API connection ----------------------------------------------------------------------------------------------------
  function apiSection(ctx, d, reload) {
    const t = d.token || {};
    const input = h('input', { type: 'password', id: 'id-token', autocomplete: 'off', spellcheck: 'false', placeholder: 'authentik API token' });
    const save = (body) => (e) => withBusy(e.currentTarget, async () => { const r = await api('POST', '/api/identity/token', body); input.value = ''; toast(r.warning || `Connected as ${r.username}.`, !!r.warning); await reload(false); });
    const remove = (e) => withBusy(e.currentTarget, async () => {
      if (!await U.confirmDialog({ title: 'Remove the authentik API token', okText: 'Remove', danger: true, body: ['The manager can no longer read or change authentik. authentik itself and the token inside authentik are not changed (revoke it there under Directory > Tokens).'] })) return;
      await api('POST', '/api/identity/token/delete', { confirm: true }); await reload(false);
    });
    return h('section', { class: 'card', id: 'identity-api', 'aria-labelledby': 'id-api-h' }, h('h2', { id: 'id-api-h' }, 'Manager connection to authentik'),
      t.stored ? h('p', null, t.ok ? stateChip('verified') : stateChip('failed'), ' ', t.ok ? `API token of ${t.username}${t.superuser ? ' (administrator)' : ' (NOT an administrator)'}.` : t.message || 'The token could not be checked.',
        h('span', { class: 'small muted' }, ` Saved ${t.savedAt} by ${t.user}, encrypted for this Windows account.`)) : h('p', null, 'No token saved yet.'),
      d.install && d.install.managed && !t.ok ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: save({ fromBootstrap: true }) }, icon('key'), 'Use the token created at installation')) : null,
      !t.ok ? [field({ id: 'id-token', label: 'API token', control: input, hint: 'In authentik: Directory > Tokens and App passwords > Create, user akadmin (or another administrator), intent "API Token", then copy it. It is stored encrypted on this PC and never shown again.' }),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => save({ token: input.value })(e) }, 'Save and test'))] : null,
      t.stored ? gate('advanced', h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small ghost', onclick: remove }, 'Remove saved token'))) : null);
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

  // --- Google ----------------------------------------------------------------------------------------------------------
  function googleSection(ctx, d, f, reload, rerender) {
    const cfg = d.config.authentik;
    const g = d.google || {};
    const v = d.googleValues;
    const connected = d.token && d.token.ok;
    if (!f.google) f.google = { clientId: cfg.google.clientId || '', signup: cfg.google.signup || 'allowlist', list: [...arr(cfg.google.emails), ...arr(cfg.google.domains)].join(', ') || d.contactEmail || '', matching: cfg.google.matching || 'identifier', showOnLogin: cfg.google.showOnLogin !== false };
    const gf = f.google;
    if (!v) {
      return h('section', { class: 'card', id: 'identity-google', 'aria-labelledby': 'id-g-h' }, h('h2', { id: 'id-g-h' }, 'Google sign-in (optional)'),
        h('p', { class: 'muted' }, 'Choose the public sign-in address first: Google only accepts https redirect addresses.'));
    }
    const step = (n, title, ...body) => h('section', { class: 'wiz-step', 'aria-labelledby': `gs-${n}` }, h('h3', { id: `gs-${n}` }, h('span', { class: 'step-num' }, String(n)), title), body);
    const cid = h('input', { id: 'id-g-cid', value: gf.clientId, autocomplete: 'off', spellcheck: 'false', placeholder: '1234567890-abc….apps.googleusercontent.com' });
    cid.addEventListener('input', () => { gf.clientId = cid.value.trim(); });
    const sec = h('input', { id: 'id-g-sec', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: g.source ? 'Leave empty to keep the secret authentik already has' : 'GOCSPX-…' });
    sec.value = f.secret || '';
    sec.addEventListener('input', () => { f.secret = sec.value; });
    const list = h('textarea', { id: 'id-g-list', rows: 2, spellcheck: 'false' }, gf.list);
    list.addEventListener('input', () => { gf.list = list.value; });
    const signup = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Who may create an account with Google' },
      [['allowlist', 'Only the people I list (recommended)', 'Their verified Google address (or domain) must be on the list.'],
        ['open', 'Any Google account', 'Anyone can create an account; it has no access to protected applications until you allow it.'],
        ['existing', 'No new accounts', 'Only existing authentik users who connected Google in their own settings.']].map(([val, t, s]) =>
        h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'id-g-signup', value: val, checked: gf.signup === val, onchange: () => { gf.signup = val; rerender(); } }), h('strong', null, t), h('span', { class: 'small' }, s))));
    const matching = h('select', { id: 'id-g-match' }, h('option', { value: 'identifier', selected: gf.matching === 'identifier' }, 'Never link by email (recommended): a Google account is its own authentik user'),
      h('option', { value: 'email_deny', selected: gf.matching === 'email_deny' }, 'Refuse sign-up when an authentik user already has that email'));
    matching.addEventListener('change', () => { gf.matching = matching.value; });
    const showBox = h('input', { type: 'checkbox', checked: gf.showOnLogin }); showBox.addEventListener('change', () => { gf.showOnLogin = showBox.checked; });
    const body = () => { const al = L.splitAccessList(gf.list); return { clientId: gf.clientId, clientSecret: f.secret || '', signup: gf.signup, emails: al.emails, domains: al.domains, matching: gf.matching, showOnLogin: gf.showOnLogin }; };
    const err = h('p', { class: 'form-error', role: 'alert' });
    const validate = () => {
      const al = L.splitAccessList(gf.list);
      if (!L.isGoogleClientId(gf.clientId)) return 'The client ID ends in .apps.googleusercontent.com — copy it from Google Cloud.';
      if (!g.source && !f.secret) return 'Paste the client secret (Google shows it only right after you create the client).';
      if (al.invalid.length) return `Not an email address or domain: ${al.invalid.join(', ')}`;
      if (gf.signup === 'allowlist' && !al.emails.length && !al.domains.length) return 'List at least one email address or domain, or choose another sign-up option.';
      return '';
    };
    const saveDraft = (e) => withBusy(e.currentTarget, async () => { const b = body(); delete b.clientSecret; await api('POST', '/api/identity/google/save', b); toast('Saved. You can leave for Google Cloud and continue later; the secret is never saved.'); });
    const plan = f.plans.google;
    const previewBtn = h('button', { type: 'button', class: 'btn primary', disabled: !connected }, icon('eye'), 'Preview the authentik changes');
    previewBtn.addEventListener('click', () => withBusy(previewBtn, async () => {
      err.textContent = validate(); if (err.textContent) return;
      f.plans.google = await api('POST', '/api/identity/google/plan', body()); rerender();
    }));
    const applyBtn = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Apply in authentik');
    const reviewed = h('input', { type: 'checkbox' }); reviewed.addEventListener('change', () => { applyBtn.disabled = !reviewed.checked; });
    applyBtn.addEventListener('click', () => withBusy(applyBtn, async () => {
      const r = await api('POST', '/api/identity/google/apply', { planId: plan.planId, confirm: true });
      f.plans.google = null; if (r.ok) { f.secret = ''; f.googleResult = r; } else toast(r.message, true);
      await reload(false);
    }));
    const res = f.googleResult;
    const redirect = g.redirect;
    return h('section', { class: 'card wizard', id: 'identity-google', 'aria-labelledby': 'id-g-h' }, h('h2', { id: 'id-g-h' }, 'Google sign-in (optional) ', g.verifiedAt ? stateChip('verified') : g.source ? stateChip('configured') : stateChip('awaiting-user')),
      h('p', null, 'Google does not offer an API to create the sign-in client, so steps 1–4 happen in Google Cloud (about five minutes). Everything else — the authentik source, the login button, sign-up rules — the manager configures for you.'),
      h('ul', { class: 'legend small' }, h('li', null, plainChip('You', 'warn'), ' steps in Google Cloud'), h('li', null, plainChip('Automatic', 'ok'), ' done by the manager'), h('li', null, plainChip('Verified', 'ok'), ' only after a real Google sign-in')),
      step(1, 'Values to use (copy them)', copyRow('App name', v.AppName, 'gv-app'), copyRow('Application type', v.ClientType, 'gv-type'), copyRow('Authorized redirect URI', v.RedirectUri, 'gv-redir'),
        copyRow('Authorized domain', v.AuthorizedDomain, 'gv-dom'), copyRow('Scopes', v.ScopeNames.join(', '), 'gv-scopes'),
        gate('advanced', h('p', { class: 'small muted' }, 'Scopes in full: ', v.Scopes.join(' '), '. authentik asks Google for "email profile"; openid, email and profile are the basic, non-sensitive scopes, so Google does not require app verification for them. No Gmail, Drive, Calendar or Cloud scopes are used. No JavaScript origins are needed.'))),
      step(2, 'Create or choose a Google Cloud project', plainChip('You', 'warn'),
        h('p', null, 'Use a project just for sign-in. ', ext(v.ConsoleUrls.projects, 'Create a project'), ' (or pick an existing one at the top of the console). No Google API has to be enabled for sign-in.')),
      step(3, 'Branding and audience', plainChip('You', 'warn'),
        h('ol', null,
          h('li', null, ext(v.ConsoleUrls.branding, 'Google Auth Platform > Branding'), ': App name ', h('code', null, v.AppName), ', your support email, developer contact email; add the authorized domain ', h('code', null, v.AuthorizedDomain), '. Uploading a logo triggers Google\'s brand verification — skip it.'),
          h('li', null, ext(v.ConsoleUrls.audience, 'Audience'), ': ', h('strong', null, 'Internal'), ' if all users belong to your Google Workspace organization; otherwise ', h('strong', null, 'External'), '. External starts in "Testing": only listed test users (up to 100) can sign in — add yourself — or press "Publish app" to allow any Google account (still filtered by authentik\'s rules below).'),
          h('li', null, ext(v.ConsoleUrls.dataAccess, 'Data access'), ' (optional): add only openid, …/auth/userinfo.email and …/auth/userinfo.profile.'))),
      step(4, 'Create the OAuth client', plainChip('You', 'warn'),
        h('ol', null, h('li', null, ext(v.ConsoleUrls.clients, 'Clients'), ' > Create client > Application type ', h('strong', null, 'Web application'), ', name it as you like.'),
          h('li', null, 'Authorized redirect URIs > Add URI: ', h('code', null, v.RedirectUri), ' (exactly, including the trailing slash).'),
          h('li', null, 'Create, then copy the Client ID and the Client secret right away: Google shows the secret only once (afterwards only its last characters).'))),
      step(5, 'Paste the client details', plainChip('You', 'warn'),
        field({ id: 'id-g-cid', label: 'Client ID', control: cid }),
        field({ id: 'id-g-sec', label: g.source ? 'Client secret (only to replace it)' : 'Client secret', control: sec, hint: 'Sent once to this PC\'s manager and straight into authentik. It is never saved by the manager, never shown again and never logged.' }),
        h('div', { class: 'field' }, h('span', { class: 'label' }, 'Who may create an account by signing in with Google?'), signup),
        gf.signup === 'allowlist' ? field({ id: 'id-g-list', label: 'Allowed Google addresses and domains', control: list, hint: 'For example: you@gmail.com, partner@example.org, example.com (a domain allows every verified address in it).' }) : null,
        gate('advanced', field({ id: 'id-g-match', label: 'Existing accounts', control: matching, hint: 'Linking by email could hand an existing account (even akadmin) to whoever controls that Google address, so it is not offered.' }),
          h('label', { class: 'check' }, showBox, h('span', null, 'Show "Sign in with Google" on the authentik login page'))),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: saveDraft }, 'Save progress'), previewBtn), err,
        !connected ? h('p', { class: 'hint' }, 'Connect the manager to authentik first (above).') : null),
      step(6, 'Configure authentik', plainChip('Automatic', 'ok'),
        plan ? [actionList(plan.actions), h('ul', null, arr(plan.notes).map((n) => h('li', { class: 'small' }, n))),
          h('div', { class: 'actions' }, h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), applyBtn)]
          : res ? [actionList(res.actions)] : h('p', { class: 'muted' }, 'Preview first: nothing in authentik changes until you apply.')),
      step(7, 'Verify', plainChip('Verified', 'ok'),
        h('ul', { class: 'checks' },
          checkItem(g.source ? 'ok' : 'neutral', 'Google source in authentik', g.source ? `Slug ${g.source.Slug}, client ${g.source.ConsumerKey}` : 'Not created yet.'),
          checkItem(redirect ? (redirect.ok ? 'ok' : 'err') : 'neutral', 'Redirect to Google', redirect ? redirect.message : 'Checked once the source exists.'),
          checkItem(g.verifiedAt ? 'ok' : g.source ? 'warn' : 'neutral', 'Real Google sign-in', g.verifiedAt ? `Succeeded for ${g.verifiedBy} at ${g.verifiedAt}.` : g.source ? 'Not verified yet: open the sign-in page, choose "Sign in with Google" with an allowed account, then press "Check again".' : '')),
        g.source && cfg.publicUrl ? h('div', { class: 'actions' }, h('a', { class: 'btn', href: `${cfg.publicUrl}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Open the sign-in page ', icon('external')),
          h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => reload(false)) }, icon('refresh'), 'Check again')) : null,
        h('p', { class: 'hint' }, 'Mock or saved configuration never counts as verified: only a user who actually signed in with Google after this configuration does.')));
  }

  // --- Protected applications ------------------------------------------------------------------------------------------
  function protectSection(ctx, d, f, reload, rerender) {
    const connected = d.token && d.token.ok;
    const candidates = arr(d.services).filter((s) => !s.isIdentity && s.enabled);
    const byName = Object.fromEntries(arr(d.apps).map((a) => [a.service, a]));
    if (!f.protect) f.protect = { service: '', list: '', groups: [], createGroup: true, access: 'keep', plan: null, result: null, groupsLoaded: null };
    const pf = f.protect;
    const table = candidates.length ? h('table', { class: 'table' }, h('thead', null, h('tr', null, h('th', null, 'Application'), h('th', null, 'Address'), h('th', null, 'Sign-in'), h('th', null, 'Status'), h('th', null, ''))),
      h('tbody', null, candidates.map((s) => {
        const a = byName[s.name];
        const state = a ? (a.verifiedAt ? 'verified' : !a.authentik ? 'failed' : a.challenge ? ({ auth: 'auth-required', open: 'failed', loop: 'failed', failed: 'failed' })[a.challenge.State] : 'configured') : 'not-configured';
        const signin = [s.auth === 'authentik' ? plainChip('authentik', 'ok') : null, s.publish && s.access ? plainChip('Cloudflare Access', 'info') : null, !s.publish ? plainChip('Local only', 'neutral') : null, s.publish && !s.access && s.auth !== 'authentik' ? plainChip('Public', 'warn') : null].filter(Boolean);
        return h('tr', null, h('td', null, s.displayName || s.name), h('td', null, arr(s.hostnames).join(', ')), h('td', null, signin), h('td', null, stateChip(state), a && a.verifiedAt ? h('span', { class: 'small muted' }, ` ${a.verifiedBy}`) : null),
          h('td', null, h('button', { type: 'button', class: 'btn small', disabled: !connected, onclick: () => { pf.service = s.name; pf.plan = null; pf.result = null; if (a) { pf.list = [...arr(a.emails), ...arr(a.domains)].join(', '); pf.groups = arr(a.groups); pf.createGroup = false; } rerender(); const el = $('#id-protect-form'); if (el) el.scrollIntoView({ block: 'start' }); } }, s.auth === 'authentik' ? 'Change…' : 'Protect…')));
      }))) : h('p', { class: 'muted' }, 'No services yet. Publish an application on the Services page first.');

    let editor = null;
    const svc = candidates.find((s) => s.name === pf.service);
    if (svc) {
      const a = byName[svc.name];
      if (pf.groupsLoaded === null && connected) { pf.groupsLoaded = []; api('GET', '/api/identity/groups').then((r) => { pf.groupsLoaded = arr(r.groups); rerender(); }).catch(() => { pf.groupsLoaded = []; }); }
      const list = h('textarea', { id: 'id-p-list', rows: 2, spellcheck: 'false' }, pf.list);
      list.addEventListener('input', () => { pf.list = list.value; pf.plan = null; });
      const groups = arr(pf.groupsLoaded).filter((g) => !g.superuser);
      const groupBoxes = groups.map((g) => { const b = h('input', { type: 'checkbox', checked: pf.groups.includes(g.name) }); b.addEventListener('change', () => { pf.groups = b.checked ? [...pf.groups, g.name] : pf.groups.filter((x) => x !== g.name); pf.plan = null; }); return h('label', { class: 'check' }, b, h('span', null, `${g.name} (${g.members} member${g.members === 1 ? '' : 's'})`)); });
      const own = h('input', { type: 'checkbox', checked: pf.createGroup }); own.addEventListener('change', () => { pf.createGroup = own.checked; pf.plan = null; });
      const accessSel = h('select', { id: 'id-p-access' },
        svc.access ? [h('option', { value: 'keep', selected: pf.access === 'keep' }, 'Keep Cloudflare Access in front (two logins)'), h('option', { value: 'remove', selected: pf.access === 'remove' }, 'Remove Cloudflare Access: authentik is the only login')]
          : [h('option', { value: 'keep', selected: pf.access === 'keep' }, svc.publish ? 'No Cloudflare Access (authentik is the login)' : 'Not published through Cloudflare'), svc.publish ? h('option', { value: 'add', selected: pf.access === 'add' }, 'Also put Cloudflare Access in front (two logins)') : null]);
      accessSel.addEventListener('change', () => { pf.access = accessSel.value; pf.plan = null; });
      const err = h('p', { class: 'form-error', role: 'alert' });
      const doPlan = (remove) => (e) => withBusy(e.currentTarget, async () => {
        err.textContent = '';
        const al = L.splitAccessList(pf.list);
        if (!remove && al.invalid.length) { err.textContent = `Not an email address or domain: ${al.invalid.join(', ')}`; return; }
        if (!remove && !al.emails.length && !al.domains.length && !pf.groups.length && !pf.createGroup) { err.textContent = 'Choose who may open it: email addresses, domains or groups.'; return; }
        pf.plan = await api('POST', `/api/identity/${remove ? 'unprotect' : 'protect'}/plan`, { service: svc.name, emails: al.emails, domains: al.domains, groups: pf.groups, createGroup: pf.createGroup, cloudflareAccess: pf.access });
        pf.plan.remove = remove; pf.result = null; rerender();
      });
      const plan = pf.plan;
      let review = null;
      if (plan) {
        const t = plan.traefik;
        const reviewed = h('input', { type: 'checkbox' });
        const overwrites = arr(t.cloudflare.actions).filter((x) => x.overwrite).map((x) => { const b = h('input', { type: 'checkbox', class: 'id-ow', 'data-id': x.id }); return h('label', { class: 'check' }, b, h('span', null, `Overwrite: ${x.summary}`)); });
        const apply = h('button', { type: 'button', class: `btn ${plan.remove ? 'danger' : 'primary'}`, disabled: true }, plan.remove ? 'Remove protection' : 'Protect');
        const sync = () => { apply.disabled = !(reviewed.checked && plan.canApply && overwrites.every((o) => o.querySelector('input').checked)); };
        reviewed.addEventListener('change', sync); overwrites.forEach((o) => o.querySelector('input').addEventListener('change', sync));
        apply.addEventListener('click', () => withBusy(apply, async () => {
          const ids = overwrites.map((o) => o.querySelector('input')).filter((b) => b.checked).map((b) => b.dataset.id);
          pf.result = await api('POST', `/api/identity/${plan.remove ? 'unprotect' : 'protect'}/apply`, { planId: plan.planId, confirm: true, confirmOverwrites: ids });
          pf.plan = null; await reload(false);
        }));
        review = h('div', { class: 'card inset' }, h('h3', null, plan.remove ? 'Preview: remove protection' : 'Preview: protect'),
          arr(plan.notes).map((n) => h('div', { class: 'callout' }, h('p', null, n))),
          h('h4', null, 'authentik'), actionList(plan.authentik),
          h('h4', null, 'Traefik'), arr(t.traefik.changes).length ? arr(t.traefik.changes).map((c) => h('details', { class: 'tech', open: true }, h('summary', null, `${c.action}: ${c.file}`), U.diffBlock(c.diff))) : h('p', { class: 'muted' }, 'No route change.'),
          arr(t.traefik.issues).length ? h('ul', { class: 'checks' }, arr(t.traefik.issues).map((i) => checkItem(i.Level === 'Error' ? 'err' : 'warn', i.Field, i.Message))) : null,
          arr(t.cloudflare.actions).filter((x) => x.kind !== 'none').length ? [h('h4', null, 'Cloudflare'), h('ul', { class: 'checks' }, arr(t.cloudflare.actions).filter((x) => x.kind !== 'none').map((x) => checkItem('auth', x.summary, x.detail)))] : null,
          arr(t.cloudflare.errors).length ? h('div', { class: 'callout err' }, arr(t.cloudflare.errors).map((x) => h('p', null, x))) : null,
          overwrites, plan.canApply ? h('div', { class: 'actions' }, h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), apply) : h('p', { class: 'muted' }, 'Nothing to change, or the preview has problems (see above).'));
      }
      const res = pf.result;
      editor = h('div', { class: 'card inset', id: 'id-protect-form' }, h('h3', null, `${svc.auth === 'authentik' ? 'Change' : 'Protect'}: ${svc.displayName || svc.name} (${arr(svc.hostnames)[0]})`),
        h('p', { class: 'small' }, 'Only the people you list may open it. Signing in with Google alone does not grant access: a Google user must be on this list or in a chosen group.'),
        field({ id: 'id-p-list', label: 'Allowed email addresses and domains', control: list, hint: 'For example: you@gmail.com, example.com. Matches the user\'s authentik email (users cannot change it themselves).' }),
        h('div', { class: 'field' }, h('span', { class: 'label' }, 'Allowed groups'), h('label', { class: 'check' }, own, h('span', null, `Create a group "${svc.name} users" for this application`)), groupBoxes.length ? groupBoxes : h('p', { class: 'hint' }, connected ? 'No other groups (administrator groups are never offered).' : '')),
        field({ id: 'id-p-access', label: 'Cloudflare Access', control: accessSel, hint: 'Existing Cloudflare Access protection is kept unless you choose to remove it here.' }),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: doPlan(false) }, icon('eye'), 'Preview…'),
          svc.auth === 'authentik' ? h('button', { type: 'button', class: 'btn ghost', onclick: doPlan(true) }, 'Preview removing protection…') : null,
          h('button', { type: 'button', class: 'btn ghost', onclick: () => { pf.service = ''; pf.plan = null; rerender(); } }, 'Close')), err,
        review,
        res ? h('div', { class: `callout ${res.ok ? '' : 'err'}`, role: 'status' }, h('p', null, h('strong', null, res.ok ? 'Done.' : 'Not completed. '), res.message || ''),
          arr(res.authentik).length ? actionList(res.authentik) : null,
          res.traefik ? h('ul', { class: 'checks' }, arr(res.traefik.steps).map((x) => checkItem(x.status === 'Done' ? 'ok' : x.status === 'Failed' ? 'err' : 'warn', x.name, x.message))) : null,
          res.challenge ? h('ul', { class: 'checks' }, checkItem(res.challenge.State === 'auth' ? 'auth' : 'err', 'Unauthenticated request', res.challenge.Message)) : null,
          res.ok && !(a && a.verifiedAt) ? h('p', { class: 'small' }, 'Open the application in a browser and sign in with an allowed account; "Run checks" then marks it verified from authentik\'s own access log.') : null) : null);
    }
    return h('section', { class: 'card', id: 'identity-apps', 'aria-labelledby': 'id-apps-h' }, h('h2', { id: 'id-apps-h' }, 'Protected applications (optional)'),
      h('p', null, 'Each protected application gets its own authentik application and access rules, and a ForwardAuth middleware in its own Traefik route file. Nothing is protected automatically.'),
      h('details', { class: 'more' }, h('summary', null, 'ForwardAuth or the application\'s own OpenID Connect?'),
        h('p', { class: 'small' }, 'ForwardAuth (used here) puts authentik in front of any web application without changing it; the application sees the user in X-authentik-* headers but keeps its own login, if it has one. Applications that support OpenID Connect themselves (Portainer, Immich, Jellyfin plugins, …) can instead sign users in natively through an authentik OAuth2 provider — configure that in authentik and the application; the manager does not set up native OIDC in this version.')),
      table, editor);
  }

  // --- Health ------------------------------------------------------------------------------------------------------------
  function healthSection(d) {
    const comps = arr(d.model && d.model.components);
    return h('section', { class: 'card', id: 'identity-health', 'aria-labelledby': 'id-health-h' }, h('h2', { id: 'id-health-h' }, 'Health'),
      h('p', { class: 'small muted' }, 'Browser → Cloudflare → tunnel → Traefik → authentik authorization → application. Each part is checked on its own; "Verified" needs real sign-in evidence.'),
      h('ul', { class: 'checks' }, comps.map((c) => checkItem(stateTone(c.state), c.label, `${L.identityState(c.state).label}${c.message ? ` — ${c.message}` : ''}`))),
      d.overviewError ? h('div', { class: 'callout err' }, h('p', null, d.overviewError)) : null,
      h('p', { class: 'small muted' }, `Checked ${d.checkedAt}.`));
  }
})();
