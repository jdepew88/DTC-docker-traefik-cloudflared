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
      sections.push(managedSection(d), installSection(ctx, d, reload), adminSection(d), apiSection(ctx, d, reload), ownerSection(ctx, d, f, reload, rerender), hostnameSection(ctx, d, reload),
        googleSection(ctx, d, f, reload, rerender), protectSection(ctx, d, f, reload, rerender), healthSection(d));
    }
    fill(main,
      head('Access', 'Identity & Access', 'Optional, one-time setup: authentik with Google sign-in, then pick the applications to protect. Afterwards users, groups, invitations and who may open what are managed in authentik only. Basic setup and Cloudflare Access work without it.',
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
      await reload(false);
      // Resume where the setup stands now: the next step that needs attention.
      const next = r && r.next ? document.getElementById(`identity-${r.next}`) : null;
      if (next) next.scrollIntoView({ block: 'start' });
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

  // --- Initial owner ---------------------------------------------------------------------------------------------------
  function ownerSection(ctx, d, f, reload, rerender) {
    const o = (d.config.authentik && d.config.authentik.owner) || {};
    const g = d.google || {};
    const pub = d.config.authentik.publicUrl;
    if (!f.owner) f.owner = { email: o.email || d.contactEmail || '', makeAdmin: o.makeAdmin !== false };
    const of = f.owner;
    if (o.verifiedAt) {
      return h('section', { class: 'card', id: 'identity-owner', 'aria-labelledby': 'id-own-h' }, h('h2', { id: 'id-own-h' }, 'Initial owner ', stateChip('verified')),
        h('p', null, `${o.email} signed in with Google as authentik user '${o.username}' (${o.verifiedAt}) and is in the group "DTC owners"${o.makeAdmin ? ' and the authentik administrators' : ''}. Everyone else is added in authentik.`));
    }
    const email = h('input', { id: 'id-owner', type: 'email', value: of.email, autocomplete: 'off', spellcheck: 'false', placeholder: 'you@gmail.com' });
    email.addEventListener('input', () => { of.email = email.value.trim(); });
    const admin = h('input', { type: 'checkbox', checked: of.makeAdmin }); admin.addEventListener('change', () => { of.makeAdmin = admin.checked; });
    const save = (e) => withBusy(e.currentTarget, async () => { if (!L.isEmail(of.email)) { toast('Enter a valid email address.', true); return; } await api('POST', '/api/identity/owner', { email: of.email, makeAdmin: of.makeAdmin }); toast('Saved.'); await reload(false); });
    const check = (e) => withBusy(e.currentTarget, async () => {
      const r = await api('POST', '/api/identity/owner/verify', {});
      if (!r.ok) { toast(r.message, true); return; }
      toast(`Owner set up: ${r.username}.`); await reload(false);
      const n = r.next ? document.getElementById(`identity-${r.next}`) : null; if (n) n.scrollIntoView({ block: 'start' });
    });
    const waiting = o.email && g.source;
    return h('section', { class: 'card', id: 'identity-owner', 'aria-labelledby': 'id-own-h' }, h('h2', { id: 'id-own-h' }, 'Initial owner ', stateChip(waiting ? 'awaiting-user' : o.email ? 'configured' : 'awaiting-user')),
      h('p', null, 'The Google account of the person who owns this authentik. Asked once: it becomes the only Google account that can create an authentik account at first, and the first member of the owner group that protected applications admit. Authentik checks that Google has verified the address.'),
      field({ id: 'id-owner', label: 'Owner\'s Google account', control: email, hint: 'Can be changed until the owner has signed in with Google.' }),
      h('label', { class: 'check' }, admin, h('span', null, 'Also make this account an authentik administrator (so you can manage authentik with Google sign-in; akadmin keeps its password either way)')),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: o.email ? 'btn' : 'btn primary', onclick: save }, o.email ? 'Change owner' : 'Save')),
      waiting ? h('div', { class: 'callout', role: 'status' }, h('p', null, h('strong', null, 'Last setup step: '), `open the sign-in page, choose "Sign in with Google" and use ${o.email}. Then press "Check owner sign-in".`),
        h('div', { class: 'actions' }, pub ? h('a', { class: 'btn', href: `${pub}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Open the sign-in page ', icon('external')) : null,
          h('button', { type: 'button', class: 'btn primary', onclick: check }, icon('refresh'), 'Check owner sign-in'))) : null);
  }

  // --- Google ----------------------------------------------------------------------------------------------------------
  function googleSection(ctx, d, f, reload, rerender) {
    const cfg = d.config.authentik;
    const g = d.google || {};
    const v = d.googleValues;
    const connected = d.token && d.token.ok;
    const owner = cfg.owner || {};
    if (!f.google) f.google = { clientId: cfg.google.clientId || '' };
    const gf = f.google;
    if (!v) {
      return h('section', { class: 'card', id: 'identity-google', 'aria-labelledby': 'id-g-h' }, h('h2', { id: 'id-g-h' }, 'Google sign-in'),
        h('p', { class: 'muted' }, 'Set up the public sign-in address first: Google only accepts https redirect addresses.'));
    }
    const step = (n, title, ...body) => h('section', { class: 'wiz-step', 'aria-labelledby': `gs-${n}` }, h('h3', { id: `gs-${n}` }, h('span', { class: 'step-num' }, String(n)), title), body);
    const cid = h('input', { id: 'id-g-cid', value: gf.clientId, autocomplete: 'off', spellcheck: 'false', placeholder: '1234567890-abc….apps.googleusercontent.com' });
    cid.addEventListener('input', () => { gf.clientId = cid.value.trim(); });
    const sec = h('input', { id: 'id-g-sec', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: g.source ? 'Leave empty to keep the secret authentik already has' : 'GOCSPX-…' });
    sec.value = f.secret || '';
    sec.addEventListener('input', () => { f.secret = sec.value; });
    const err = h('p', { class: 'form-error', role: 'alert' });
    const validate = () => {
      if (!owner.email) return 'Enter the initial owner\'s Google account first (above).';
      if (!L.isGoogleClientId(gf.clientId)) return 'The client ID ends in .apps.googleusercontent.com — copy it from Google Cloud.';
      if (!g.source && !f.secret) return 'Paste the client secret (Google shows it only right after you create the client).';
      return '';
    };
    const saveDraft = (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/identity/google/save', { clientId: gf.clientId }); toast('Saved. You can leave for Google Cloud and continue later; the secret is never saved.'); });
    const plan = f.plans.google;
    const previewBtn = h('button', { type: 'button', class: 'btn primary', disabled: !connected }, icon('eye'), 'Preview the authentik changes');
    previewBtn.addEventListener('click', () => withBusy(previewBtn, async () => {
      err.textContent = validate(); if (err.textContent) return;
      f.plans.google = await api('POST', '/api/identity/google/plan', { clientId: gf.clientId, clientSecret: f.secret || '' }); rerender();
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
    return h('section', { class: 'card wizard', id: 'identity-google', 'aria-labelledby': 'id-g-h' }, h('h2', { id: 'id-g-h' }, 'Google sign-in ', g.verifiedAt ? stateChip('verified') : g.source ? stateChip('configured') : stateChip('awaiting-user')),
      h('p', null, 'Google offers no API to create the sign-in client, so steps 1–4 are a short visit to Google Cloud (about five minutes). The rest — the Google source, the login button, the owner-only sign-up — the manager configures in authentik.'),
      h('ul', { class: 'legend small' }, h('li', null, plainChip('You', 'warn'), ' steps in Google Cloud'), h('li', null, plainChip('Automatic', 'ok'), ' done by the manager'), h('li', null, plainChip('Verified', 'ok'), ' only after the owner\'s real Google sign-in')),
      step(1, 'Values to use (copy them)', copyRow('App name', v.AppName, 'gv-app'), copyRow('Application type', v.ClientType, 'gv-type'), copyRow('Authorized redirect URI', v.RedirectUri, 'gv-redir'),
        copyRow('Authorized domain', v.AuthorizedDomain, 'gv-dom'), copyRow('Scopes', v.ScopeNames.join(', '), 'gv-scopes'),
        gate('advanced', h('p', { class: 'small muted' }, 'Scopes in full: ', v.Scopes.join(' '), '. authentik asks Google for "email profile"; openid, email and profile are the basic, non-sensitive scopes, so Google does not require app verification for them. No JavaScript origins are needed.'))),
      step(2, 'Create or choose a Google Cloud project', plainChip('You', 'warn'),
        h('p', null, 'Use a project just for sign-in. ', ext(v.ConsoleUrls.projects, 'Create a project'), ' (or pick one at the top of the console). No Google API has to be enabled for sign-in.')),
      step(3, 'Branding and audience', plainChip('You', 'warn'),
        h('ol', null,
          h('li', null, ext(v.ConsoleUrls.branding, 'Google Auth Platform > Branding'), ': App name ', h('code', null, v.AppName), ', your support email, developer contact email; authorized domain ', h('code', null, v.AuthorizedDomain), '. Skip the logo (it triggers Google\'s brand verification).'),
          h('li', null, ext(v.ConsoleUrls.audience, 'Audience'), ': ', h('strong', null, 'Internal'), ' if everyone is in your Google Workspace organization, otherwise ', h('strong', null, 'External'), '. External starts in "Testing" (only listed test users, up to 100 — add ', h('code', null, owner.email || 'the owner'), ') or press "Publish app"; authentik still decides who may enroll.'))),
      step(4, 'Create the OAuth client', plainChip('You', 'warn'),
        h('ol', null, h('li', null, ext(v.ConsoleUrls.clients, 'Clients'), ' > Create client > Application type ', h('strong', null, 'Web application'), '.'),
          h('li', null, 'Authorized redirect URIs > Add URI: ', h('code', null, v.RedirectUri), ' (exactly, including the trailing slash).'),
          h('li', null, 'Create, then copy the Client ID and Client secret right away: Google shows the secret only once.'))),
      step(5, 'Paste the client details', plainChip('You', 'warn'),
        field({ id: 'id-g-cid', label: 'Client ID', control: cid }),
        field({ id: 'id-g-sec', label: g.source ? 'Client secret (only to replace it)' : 'Client secret', control: sec, hint: 'Sent once to this PC\'s manager and straight into authentik. Never saved by the manager, never shown again, never logged.' }),
        h('p', { class: 'small' }, owner.email ? `Only ${owner.email} will be able to create an account with Google at first.` : 'Enter the initial owner (above) first.'),
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
          checkItem(g.verifiedAt ? 'ok' : g.source ? 'warn' : 'neutral', 'Owner\'s Google sign-in', g.verifiedAt ? `Succeeded for ${g.verifiedBy} at ${g.verifiedAt}.` : g.source ? 'Waiting for the owner (see "Initial owner").' : '')),
        h('p', { class: 'hint' }, 'Saved configuration never counts as verified: only the owner\'s real Google sign-in does.')));
  }

  // --- Protected applications ------------------------------------------------------------------------------------------
  // Select applications, one action. Access starts owner-only and is then managed in authentik; nothing about people is
  // asked here.
  function protectSection(ctx, d, f, reload, rerender) {
    const connected = d.token && d.token.ok;
    const ownerReady = !!(d.config.authentik.owner && d.config.authentik.owner.verifiedAt) || !!(d.google && d.google.source);
    const services = arr(d.services).filter((s) => !s.isIdentity);
    const byName = Object.fromEntries(arr(d.apps).map((a) => [a.service, a]));
    if (!f.protect) f.protect = { selected: {}, access: 'keep', plan: null, result: null, remove: null };
    const pf = f.protect;
    const compatible = (s) => s.enabled && arr(s.hostnames).length === 1 && s.auth !== 'authentik';
    const why = (s) => (!s.enabled ? 'disabled' : arr(s.hostnames).length !== 1 ? 'several hostnames' : '');
    const link = d.adminLinks;
    const rows = services.map((s) => {
      const a = byName[s.name];
      const prot = s.auth === 'authentik';
      const state = a ? (a.verifiedAt ? 'verified' : !a.authentik ? 'failed' : a.challenge ? ({ auth: 'auth-required', open: 'failed', loop: 'failed', failed: 'failed' })[a.challenge.State] : 'configured') : 'not-configured';
      const box = h('input', { type: 'checkbox', 'aria-label': `Select ${s.displayName || s.name}`, checked: !!pf.selected[s.name], disabled: !compatible(s) || !connected });
      box.addEventListener('change', () => { pf.selected[s.name] = box.checked; pf.plan = null; rerender(); });
      const access = prot && a ? (a.rules === null || a.rules === undefined ? '' : a.ownerOnly ? 'owner only (DTC owners)' : a.rules ? `${a.rules} rule(s) in authentik` : 'no rule (everyone signed in)') : '';
      return h('tr', null,
        h('td', null, prot ? icon('lock') : box),
        h('td', null, s.displayName || s.name, why(s) && !prot ? h('span', { class: 'small muted' }, ` (${why(s)})`) : null),
        h('td', null, arr(s.hostnames).join(', ')),
        h('td', null, prot ? [stateChip(state), access ? h('div', { class: 'small muted' }, access) : null] : s.publish && s.access ? plainChip('Cloudflare Access', 'info') : !s.publish ? plainChip('Local only') : plainChip('Public', 'warn')),
        h('td', null, prot ? [link ? h('a', { class: 'btn small', href: `${link.base}/if/admin/#/core/applications/${a ? a.slug : `dm-${s.name}`}`, target: '_blank', rel: 'noopener noreferrer' }, 'Open in authentik ', icon('external')) : null,
          h('button', { type: 'button', class: 'btn small ghost', onclick: (e) => withBusy(e.currentTarget, async () => { pf.plan = await api('POST', '/api/identity/unprotect/plan', { service: s.name }); pf.plan.remove = true; pf.result = null; rerender(); }) }, 'Remove protection…')] : null));
    });
    const table = services.length ? h('table', { class: 'table' }, h('thead', null, h('tr', null, h('th', null, ''), h('th', null, 'Application'), h('th', null, 'Address'), h('th', null, 'Sign-in'), h('th', null, ''))), h('tbody', null, rows))
      : h('p', { class: 'muted' }, 'No services yet. Publish an application on the Services page first.');
    const chosen = Object.keys(pf.selected).filter((k) => pf.selected[k]);
    const accessSel = h('select', { id: 'id-p-access' }, h('option', { value: 'keep', selected: pf.access === 'keep' }, 'Keep Cloudflare Access as it is (default)'), h('option', { value: 'remove', selected: pf.access === 'remove' }, 'Remove Cloudflare Access from the selected applications (authentik becomes the only login)'));
    accessSel.addEventListener('change', () => { pf.access = accessSel.value; pf.plan = null; });
    const protectBtn = h('button', { type: 'button', class: 'btn primary', disabled: !chosen.length || !connected || !ownerReady }, icon('lock'), `Protect selected with authentik${chosen.length ? ` (${chosen.length})` : ''}…`);
    protectBtn.addEventListener('click', () => withBusy(protectBtn, async () => { pf.plan = await api('POST', '/api/identity/protect/plan', { services: chosen, cloudflareAccess: pf.access }); pf.plan.remove = false; pf.result = null; rerender(); }));
    let review = null;
    const plan = pf.plan;
    if (plan) {
      const items = arr(plan.items);
      const reviewed = h('input', { type: 'checkbox' });
      const overwrites = items.flatMap((it) => arr(it.traefik.cloudflare.actions).filter((x) => x.overwrite).map((x) => { const b = h('input', { type: 'checkbox', 'data-id': x.id }); return h('label', { class: 'check' }, b, h('span', null, `Overwrite: ${x.summary}`)); }));
      const apply = h('button', { type: 'button', class: `btn ${plan.remove ? 'danger' : 'primary'}`, disabled: true }, plan.remove ? 'Remove protection' : `Protect ${items.length} application(s)`);
      const sync = () => { apply.disabled = !(reviewed.checked && plan.canApply && overwrites.every((o) => o.querySelector('input').checked)); };
      reviewed.addEventListener('change', sync); overwrites.forEach((o) => o.querySelector('input').addEventListener('change', sync));
      apply.addEventListener('click', () => withBusy(apply, async () => {
        const ids = overwrites.map((o) => o.querySelector('input')).filter((b) => b.checked).map((b) => b.dataset.id);
        pf.result = await api('POST', `/api/identity/${plan.remove ? 'unprotect' : 'protect'}/apply`, { planId: plan.planId, confirm: true, confirmOverwrites: ids });
        pf.plan = null; pf.selected = {}; await reload(false);
      }));
      review = h('div', { class: 'card inset', id: 'id-protect-review' }, h('h3', null, plan.remove ? 'Preview: remove protection' : 'Preview: protect with authentik'),
        items.map((it) => h('details', { class: 'more', open: items.length === 1 ? true : null }, h('summary', null, `${it.displayName} (${it.hostname})${it.errors ? ' — has problems' : ''}`),
          arr(it.notes).map((n) => h('div', { class: 'callout' }, h('p', null, n))),
          h('h4', null, 'authentik'), actionList(it.authentik),
          h('h4', null, 'Traefik'), arr(it.traefik.traefik.changes).length ? arr(it.traefik.traefik.changes).map((c) => h('details', { class: 'tech' }, h('summary', null, `${c.action}: ${c.file}`), U.diffBlock(c.diff))) : h('p', { class: 'muted' }, 'No route change.'),
          arr(it.traefik.traefik.issues).length ? h('ul', { class: 'checks' }, arr(it.traefik.traefik.issues).map((i) => checkItem(i.Level === 'Error' ? 'err' : 'warn', i.Field, i.Message))) : null,
          arr(it.traefik.cloudflare.actions).filter((x) => x.kind !== 'none').length ? [h('h4', null, 'Cloudflare'), h('ul', { class: 'checks' }, arr(it.traefik.cloudflare.actions).filter((x) => x.kind !== 'none').map((x) => checkItem('auth', x.summary, x.detail)))] : null,
          arr(it.traefik.cloudflare.errors).length ? h('div', { class: 'callout err' }, arr(it.traefik.cloudflare.errors).map((x) => h('p', null, x))) : null)),
        overwrites, plan.canApply ? h('div', { class: 'actions' }, h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), apply, h('button', { type: 'button', class: 'btn ghost', onclick: () => { pf.plan = null; rerender(); } }, 'Cancel'))
          : h('p', { class: 'muted' }, 'The preview has problems (see above); nothing can be applied.'));
    }
    const res = pf.result;
    const result = res ? h('div', { class: `callout ${res.ok ? '' : 'err'}`, role: 'status', id: 'id-protect-result' }, h('p', null, h('strong', null, res.ok ? 'Done. ' : 'Not everything completed. '), res.message || ''),
      h('ul', { class: 'checks' }, arr(res.results).map((x) => checkItem(x.ok ? (x.challenge && x.challenge.State === 'auth' ? 'auth' : 'ok') : 'err', x.service, x.message || '')))) : null;
    return h('section', { class: 'card', id: 'identity-apps', 'aria-labelledby': 'id-apps-h' }, h('h2', { id: 'id-apps-h' }, 'Protect applications'),
      h('p', null, 'Select applications and protect them in one step. Each gets its own authentik application, a ForwardAuth middleware in its Traefik route and, if it has no access rule in authentik yet, the owner-only rule (group "DTC owners"). Who else may open it is then decided in authentik — nothing about people is asked here.'),
      !ownerReady ? h('p', { class: 'hint' }, 'Set up Google sign-in first: it creates the owner-only rule new applications start with.') : null,
      table,
      h('div', { class: 'protect-bar' }, field({ id: 'id-p-access', label: 'Cloudflare Access', control: accessSel }), h('div', { class: 'actions' }, protectBtn)),
      review, result,
      h('details', { class: 'more' }, h('summary', null, 'ForwardAuth or the application\'s own OpenID Connect?'),
        h('p', { class: 'small' }, 'ForwardAuth (used here) puts authentik in front of any web application without changing it; the application sees the user in X-authentik-* headers and keeps its own login, if it has one. Applications that support OpenID Connect themselves can instead sign users in natively through an authentik OAuth2 provider — configure that in authentik and the application.')));
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
