'use strict';
// The seven-step installation journey (one vertical page). Steps 1-4 collect choices (saved as a draft in the install
// folder, nothing in Docker or Cloudflare changes), step 5 reviews and approves the local changes, step 6 reviews and
// approves the Cloudflare changes, and step 7 applies both and verifies the running infrastructure.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, $$, arr, h, clear, fill, icon, chip, plainChip, toast, api, withBusy, field, gate, help, kv, checkItem, reviewPanel, technical } = U;
  const P = (window.TPMPages = window.TPMPages || {});

  const HANDOFF_TEXT = "Cloudflare will display your API token when you create it. Copy it before closing that page. For security, Cloudflare won't display the same secret again. If you lose it, revoke or delete the old token and create a replacement.";

  const tokenOk = (setup) => !!(setup && setup.cloudflare.tokenStored && setup.cloudflare.tokenReadable);
  const dockerOk = (d) => !!(d && d.CliFound && d.EngineRunning && d.OsType === 'linux' && d.ComposeOk);
  const domainsOf = (setup) => arr(setup && setup.cloudflare.domains);
  const conflictErrors = (env) => arr(env && env.conflicts).filter((c) => c.Level === 'error');
  const actionSig = (actions) => arr(actions).filter((a) => a.kind !== 'none').map((a) => `${a.step}:${a.kind}:${a.hostname}`).sort().join('|');

  // --- Step status -------------------------------------------------------------------------------------------------------
  P.stepStatuses = (ctx) => {
    const s = ctx.state; const setup = s.setup;
    if (!setup || !s.status) return [];
    const inst = setup.installed; const dep = setup.deployment; const mode = dep.mode;
    const tok = tokenOk(setup); const doms = domainsOf(setup).length;
    const env = s.env; const plan = s.installPlan;
    const list = [];
    list.push(tok && doms ? { cls: 'done', summary: `${setup.cloudflare.accountName || 'Account'} · ${doms} allowed domain${doms === 1 ? '' : 's'}` }
      : mode === 'local' && !tok ? { cls: 'done', summary: 'Skipped: local-only installation' }
        : tok ? { cls: 'attention', summary: 'Token connected; choose the allowed domains' } : { cls: 'todo', summary: 'Not connected yet' });
    if (inst) list.push({ cls: 'done', summary: 'Installed' });
    else if (!env) list.push({ cls: 'todo', summary: 'Not checked yet' });
    else if (!dockerOk(env.docker) || !env.path.ok) list.push({ cls: 'blocked', summary: !dockerOk(env.docker) ? 'Docker Desktop needs attention' : 'The install folder is not writable' });
    else if (conflictErrors(env).length) list.push({ cls: 'attention', summary: `${conflictErrors(env).length} conflict(s) with the current settings (step 3)` });
    else list.push({ cls: 'done', summary: `Docker ${env.docker.ServerVersion} ready, no conflicts` });
    list.push(inst ? { cls: 'done', summary: `Instance ${setup.settings.STACK_NAME}` }
      : setup.settingsSource === 'draft' ? { cls: env && conflictErrors(env).length ? 'attention' : 'done', summary: `Instance ${setup.settings.STACK_NAME} in ${setup.installPath}` }
        : { cls: 'todo', summary: 'Suggested values not saved yet' });
    const tunnelReady = mode === 'tunnel' && ((dep.tunnelChoice === 'existing' && dep.tunnelId) || (dep.tunnelChoice === 'new' && dep.newTunnelName));
    list.push(inst || mode === 'local' || tunnelReady ? { cls: 'done', summary: mode === 'local' ? 'Local only' : `Cloudflare Tunnel (${dep.tunnelChoice === 'new' ? `new: ${dep.newTunnelName}` : dep.tunnelName || 'existing'})` }
      : { cls: 'todo', summary: mode === 'tunnel' ? 'Choose the tunnel' : 'Not chosen yet' });
    const localApproved = !!(plan && s.approvals.local && s.approvals.local === plan.planKey);
    list.push(inst ? { cls: 'done', summary: 'Applied' } : localApproved ? { cls: 'done', summary: 'Approved' }
      : plan && !plan.canInstall ? { cls: 'blocked', summary: `${arr(plan.blockers).length || 1} problem(s) to fix` } : { cls: 'todo', summary: plan ? 'Waiting for your approval' : 'Checks not run yet' });
    list.push(inst ? { cls: 'done', summary: 'Applied' } : mode === 'local' ? { cls: 'done', summary: 'Not needed (local only)' }
      : s.approvals.cloudflare ? { cls: 'done', summary: 'Approved' } : { cls: 'todo', summary: 'Waiting for your approval' });
    const v = s.verify;
    list.push(inst && v && v.ready ? { cls: 'done', summary: 'Installed and verified' } : inst && v ? { cls: 'attention', summary: 'Installed; some checks need attention' }
      : inst ? { cls: 'attention', summary: 'Installed; run the verification' } : { cls: 'todo', summary: 'Not installed' });
    const cur = list.findIndex((x) => x.cls !== 'done');
    list.forEach((x, i) => { x.current = i === (cur < 0 ? 6 : cur); });
    return list;
  };

  // --- Page ------------------------------------------------------------------------------------------------------------------
  let C = null; // ctx of the current render
  P.setup = async (main, ctx, sub) => {
    C = ctx;
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    const steps = P.stepStatuses(ctx);
    const target = parseInt(sub, 10);
    fill(main,
      h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Installation'),
        h('h1', null, s.setup.installed ? 'Setup journey' : 'Publish your apps safely'),
        h('p', null, 'Traefik routes each hostname to the right app; a Cloudflare Tunnel brings Internet traffic to it without opening router ports. ',
          'Each step explains itself; nothing in Docker or Cloudflare changes until you approve it in steps 5 and 6.'))),
      h('div', { class: 'callout', 'data-only-level': 'beginner' }, h('p', null, h('strong', null, 'How it works: '),
        'a visitor opens https://app.your-domain → Cloudflare checks who it is (Access) → the encrypted tunnel brings the request to this PC → Traefik sends it to your app.')),
      h('ol', { class: 'steps-list', 'aria-label': 'Installation steps' }, ctx.STEPS.map(([n]) => h('li', { id: `step-${n}` }))));
    ctx.STEPS.forEach(([n]) => updateStep(n, steps));
    if (target >= 1 && target <= 7) {
      s.journeyOpen[target] = true; updateStep(target);
      const el = $(`#step-${target}`); if (el) el.scrollIntoView({ block: 'start' });
    }
    loadAsync();
  };

  // Loads what the steps need, once per page view, and updates only the affected steps.
  let loading = {};
  async function loadAsync() {
    const s = C.state;
    if (!s.env && !loading.env) { loading.env = true; api('GET', '/api/environment').then((e) => { s.env = e; refreshSteps(); }).catch(() => {}).finally(() => { loading.env = false; }); }
    if (tokenOk(s.setup) && !s.discovery && !loading.disc) {
      loading.disc = true; api('GET', '/api/cloudflare/discovery').then((d) => { s.discovery = d; refreshSteps(); }).catch(() => {}).finally(() => { loading.disc = false; });
    }
  }
  function refreshSteps() { if (C && C.state.page === 'setup') { const st = P.stepStatuses(C); C.STEPS.forEach(([n]) => updateStep(n, st)); } }
  P.refreshSteps = refreshSteps;
  P.onLevelChange = (ctx) => { if (ctx.state.page === 'setup') refreshSteps(); else ctx.rerender(); };

  const RENDER = { 1: stepCloudflare, 2: stepDocker, 3: stepConfigure, 4: stepIngress, 5: stepLocalReview, 6: stepCloudflareReview, 7: stepInstall };
  function updateStep(n, statuses) {
    const host = $(`#step-${n}`);
    if (!host) return;
    const st = (statuses || P.stepStatuses(C))[n - 1] || { cls: 'todo' };
    const s = C.state;
    const open = s.journeyOpen[n] !== undefined ? s.journeyOpen[n] : st.current;
    const title = C.STEPS[n - 1][1];
    const toggle = () => { s.journeyOpen[n] = !open; updateStep(n); };
    const head = h('div', { class: 'step-head' },
      h('button', { type: 'button', class: 'rv-toggle', 'aria-expanded': String(open), 'aria-controls': `step-body-${n}`, onclick: toggle },
        icon('chevron', 'chev'), h('h2', null, `${n}. ${title}`)),
      st.cls === 'done' ? chip('validated', 'Done') : st.cls === 'blocked' ? chip('failed', 'Blocked') : st.cls === 'attention' ? chip('warning', 'Needs attention') : st.current ? plainChip('Current step', 'info') : plainChip('To do'),
      h('p', { class: 'step-summary' }, st.summary || ''));
    const card = h('div', { class: 'step-card' }, head);
    if (open) card.append(h('div', { class: 'step-body', id: `step-body-${n}` }, RENDER[n]()));
    fill(host, h('div', { class: `step ${st.cls} ${st.current ? 'current' : ''}` }, h('div', { class: 'step-icon', 'aria-hidden': 'true' }, st.cls === 'done' ? icon('check') : st.cls === 'blocked' ? '!' : String(n)), card));
    if (C.state.page === 'setup' && window.TPMApp) { /* keep rail in sync */ const ev = new Event('tpm-steps'); window.dispatchEvent(ev); }
  }
  function goStep(n) { C.state.journeyOpen[n] = true; updateStep(n); const el = $(`#step-${n}`); if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' }); }
  async function reload(...steps) { await C.refresh(); refreshSteps(); if (steps.length) steps.forEach((n) => { C.state.journeyOpen[n] = true; }); refreshSteps(); }

  // --- Step 1: Connect Cloudflare ------------------------------------------------------------------------------------------
  function stepCloudflare() {
    const s = C.state; const setup = s.setup; const cf = setup.cloudflare;
    const ok = tokenOk(setup);
    const withAccess = s.forms.tokenAccess !== false;
    const link = h('a', { class: 'btn primary', href: withAccess ? cf.tokenLinkWithAccess : cf.tokenLink, target: '_blank', rel: 'noopener noreferrer', id: 'cf-create-token',
      onclick: () => { s.forms.handoff = true; const c = $('#cf-handoff'); if (c) c.hidden = false; } }, icon('key'), 'Create Cloudflare API Token');
    const accessBox = h('input', { type: 'checkbox', checked: withAccess });
    accessBox.addEventListener('change', () => { s.forms.tokenAccess = accessBox.checked; link.href = accessBox.checked ? cf.tokenLinkWithAccess : cf.tokenLink; });
    const perms = arr(cf.permissions);
    const level = (p) => (p.label.startsWith('Account') ? 'Account level' : 'Zone level');
    const tokenInput = h('input', { id: 'wiz-token', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: 'Paste the API token' });
    const form = h('form', { class: 'field', autocomplete: 'off', 'data-help-host': '' },
      h('label', { for: 'wiz-token' }, ok ? 'Replace the API token' : 'API token', help('cf-api-tokens', 'API token')),
      h('div', { class: 'hostname-row' }, tokenInput, h('button', { type: 'submit', class: 'btn primary' }, 'Verify and save')),
      h('p', { class: 'hint' }, 'Checked with Cloudflare before it is saved. Nothing in your Cloudflare account is changed.'));
    form.addEventListener('submit', (e) => { e.preventDefault(); saveToken(tokenInput, e.submitter || form.querySelector('button')); });
    return [
      h('p', { class: 'lead' }, 'This tool uses a Cloudflare API token, limited to the permissions below, to set up the tunnel, DNS records and logins for you. Every change is previewed and needs your approval.'),
      h('div', { class: 'card flat', 'data-help-host': '' },
        h('div', { class: 'card-head' }, h('h3', null, 'Permissions the token asks for'), help('cf-zones-accounts', 'Account and zone permissions')),
        h('ul', { class: 'checks' }, perms.map((p) => checkItem('neutral', `${p.label}${p.optional ? ' (optional)' : ''}`, `${level(p)}: to ${p.purpose}`))),
        h('p', { class: 'hint' }, 'Account-level permissions apply to the account (tunnels, Access logins). Zone-level permissions apply to each domain (DNS). On Cloudflare\'s page you choose which account and which domains the token may touch.'),
        h('label', { class: 'check' }, accessBox, h('span', null, 'Include the optional Access permission (lets this tool put a Cloudflare login in front of your apps and the dashboard)'))),
      h('div', { class: 'actions' }, link,
        !ok && setup.deployment.mode !== 'local' && !setup.installed ? h('button', { type: 'button', class: 'btn', onclick: (e) => skipCloudflare(e.currentTarget) }, 'Skip: install for local use only') : null),
      h('p', { class: 'hint' }, 'The link opens Cloudflare\'s token page (sign in with your usual Cloudflare login) with these permissions filled in. Under Account Resources and Zone Resources choose only what this PC should manage, then Continue to summary → Create Token. If Cloudflare Tunnel is not listed, add Account > Cloudflare Tunnel > Edit yourself.'),
      h('div', { class: 'callout', id: 'cf-handoff', hidden: ok && !s.forms.handoff },
        h('p', null, h('strong', null, HANDOFF_TEXT)),
        h('p', null, 'Paste it below. Once it is copied you can close the Cloudflare tab. It is encrypted for your Windows account (DPAPI) on this PC and is never shown again, put in a link, stored in the browser or written to a log.')),
      ok ? h('div', { class: 'status-line' }, chip('validated', 'Token stored (encrypted)'), h('span', { class: 'muted small' }, `Saved ${cf.tokenSavedAt}`)) : null,
      cf.tokenStored && !cf.tokenReadable ? h('div', { class: 'callout warn' }, h('p', null, 'The stored token cannot be decrypted by this Windows account. Paste it again or create a new one.')) : null,
      form,
      ok ? h('div', { class: 'actions' },
        h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => { s.discovery = await api('GET', '/api/cloudflare/discovery'); refreshSteps(); }) }, icon('refresh'), 'Check permissions again'),
        h('button', { type: 'button', class: 'btn small danger-outline', onclick: (e) => removeToken(e.currentTarget) }, 'Remove stored token')) : null,
      ok ? renderDiscovery() : null,
    ];
  }

  function renderDiscovery() {
    const s = C.state; const disc = s.discovery; const cf = s.setup.cloudflare;
    if (!disc) return h('p', { class: 'muted' }, 'Checking what the token can do…');
    const zones = arr(disc.zones); const accounts = arr(disc.accounts);
    const boxes = zones.map((z) => h('input', { type: 'checkbox', value: z.id, checked: z.allowed || zones.length === 1 }));
    const permState = (p) => (p.state === 'ok' ? 'ok' : p.state === 'partial' ? 'warn' : p.state === 'missing' ? (p.optional ? 'neutral' : 'err') : 'neutral');
    const contact = s.setup.contactEmail;
    return h('div', null,
      h('h3', null, 'What this token can do'),
      h('ul', { class: 'checks' }, arr(disc.permissions).map((p) => checkItem(permState(p), p.label, p.message))),
      accounts.length > 1 ? field({ id: 'wiz-account', label: 'Cloudflare account', control: h('select', { onchange: (e) => withBusy(null, async () => { await api('POST', '/api/cloudflare/select', { accountId: e.target.value }); s.discovery = await api('GET', '/api/cloudflare/discovery'); await reload(1); }) },
        h('option', { value: '' }, 'Choose an account…'), accounts.map((a) => h('option', { value: a.id, selected: a.id === disc.accountId }, a.name))) })
        : accounts.length === 1 ? h('p', null, 'Account: ', h('strong', null, accounts[0].name), h('span', { class: 'muted' }, ' (selected automatically)')) : null,
      h('div', { 'data-help-host': '' }, h('h3', null, 'Allowed domains ', help('fqdn', 'Allowed domains'))),
      zones.length === 0 ? h('div', { class: 'callout warn' }, h('p', null, 'The token cannot see any domain. Edit it in Cloudflare (Zone > Zone > Read and Zone > DNS > Edit for your domain) or create a new one.')) :
        [h('p', { class: 'muted' }, zones.length === 1 ? 'The token can manage one domain; it was selected automatically.' : 'Choose the domains this instance may publish under. Hostnames are only ever created under these domains, even if the token can see more.'),
          h('fieldset', { class: 'chips' }, h('legend', { class: 'sr-only' }, 'Allowed domains'),
            zones.map((z, i) => h('label', { class: 'check' }, boxes[i], h('span', null, z.name, ' ', z.dns === 'missing' ? plainChip('no DNS access', 'warn') : null, U.gateSpan('advanced', h('span', { class: 'muted small mono' }, ` ${z.id}`)))))),
          h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
            const ids = boxes.filter((b) => b.checked).map((b) => b.value);
            await api('POST', '/api/cloudflare/domains', { zoneIds: ids });
            toast(ids.length ? `Allowed domains saved (${ids.length}).` : 'No domain is allowed now.');
            s.discovery = await api('GET', '/api/cloudflare/discovery'); await reload(1);
          }) }, 'Save allowed domains'))],
      arr(cf.domains).length ? h('p', null, 'Allowed now: ', arr(cf.domains).map((d) => plainChip(d.name, 'ok'))) : null,
      disc.profileEmail && !contact ? h('div', { class: 'callout' }, h('p', null, 'Your Cloudflare profile email is ', h('strong', null, disc.profileEmail), '. Use it as your contact email (the default sign-in for Cloudflare Access)?'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/setup/contact', { email: disc.profileEmail }); await reload(); toast('Contact email saved.'); }) }, 'Use this email'))) : null,
      U.technical(gateLines(disc), 'Discovery details (ids)', 'expert'));
  }
  function gateLines(disc) {
    return [`account ${disc.accountId || '-'} ${disc.accountName || ''}`, ...arr(disc.zones).map((z) => `zone ${z.id} ${z.name} status=${z.status} dns=${z.dns}`), ...arr(disc.tunnels).map((t) => `tunnel ${t.id} ${t.name} status=${t.status} remotelyManaged=${t.remotelyManaged}`)];
  }

  async function saveToken(input, button) {
    const s = C.state;
    const token = input.value.trim();
    if (!token) { toast('Paste the API token first.', true); return; }
    const send = async (confirmReplace) => {
      try { return await api('POST', '/api/cloudflare/token', { token, confirmReplace }); }
      catch (err) {
        if (err.status === 409 && err.data.needsConfirm === 'replace') {
          const ok = await U.confirmDialog({ title: 'Replace the stored token?', body: 'A Cloudflare API token is already stored. The new token replaces it after Cloudflare verifies it. Revoke the old token in Cloudflare if you no longer need it.', okText: 'Replace' });
          return ok ? send(true) : null;
        }
        throw err;
      }
    };
    await withBusy(button, async () => {
      const r = await send(false);
      input.value = '';
      if (!r) return;
      s.discovery = r; s.forms.handoff = false;
      toast(`Token verified and saved: ${arr(r.zones).length} domain(s) visible.`);
      await reload(1);
    });
  }
  async function removeToken(button) {
    const ok = await U.confirmDialog({ title: 'Remove the stored API token?', body: 'Automation stops working until you save a token again. Nothing in Cloudflare is changed. Revoke or delete the token in the Cloudflare dashboard if you no longer need it.', okText: 'Remove', danger: true });
    if (!ok) return;
    await withBusy(button, async () => { await api('POST', '/api/cloudflare/token/delete', { confirm: true }); C.state.discovery = null; toast('Stored token removed.'); await reload(1); });
  }
  async function skipCloudflare(button) {
    await withBusy(button, async () => {
      C.state.setup = await api('POST', '/api/setup/deployment', { mode: 'local' });
      C.state.installPlan = null;
      toast('Local-only installation chosen. You can connect Cloudflare later.');
      await reload(); goStep(2);
    });
  }

  // --- Step 2: Prepare Docker Desktop ------------------------------------------------------------------------------------
  const WHY = {
    cli: 'The installer calls the docker command to create and start containers.',
    engine: 'Docker Desktop must be running: the containers live in its Linux virtual machine (WSL 2).',
    linux: 'Traefik and cloudflared are Linux images.',
    compose: 'The stack is described in compose.yaml and started with docker compose.',
    path: 'The install folder keeps this instance\'s settings, generated routes, backups and logs.',
    names: 'Container names must be unique on this PC; another program\'s container is never replaced.',
    ports: 'Traefik publishes two ports on 127.0.0.1; another program must not be using them.',
    network: 'Apps join the shared network so Traefik can reach them; an existing network is reused, never recreated.',
    subnet: 'The private network between cloudflared and Traefik must not overlap another Docker network.',
    state: 'An existing installation in this folder is managed in place, not replaced.',
    others: 'Only this instance\'s own containers are ever started or stopped.',
  };
  function envChecks(env, settings) {
    const d = env.docker;
    const byKey = (keys, level) => arr(env.conflicts).filter((c) => keys.includes(c.Key) && (!level || c.Level === level));
    const line = (list, okText) => {
      const errs = list.filter((c) => c.Level === 'error'); const warns = list.filter((c) => c.Level === 'warning');
      return errs.length ? ['err', errs.map((c) => c.Message).join(' ')] : warns.length ? ['warn', warns.map((c) => c.Message).join(' ')] : ['ok', okText];
    };
    const names = line(byKey(['STACK_NAME']), `${settings.STACK_NAME}-traefik, -socket-proxy and -cloudflared are free.`);
    const ports = line(byKey(['TRAEFIK_HTTP_PORT', 'TRAEFIK_DASHBOARD_PORT']), `127.0.0.1:${settings.TRAEFIK_HTTP_PORT} and :${settings.TRAEFIK_DASHBOARD_PORT} are free.`);
    const net = line(byKey(['PROXY_NETWORK']), `'${settings.PROXY_NETWORK}' will be created.`);
    const subnet = line(byKey(['TUNNEL_SUBNET', 'settings']), `${settings.TUNNEL_SUBNET} does not overlap another network.`);
    const dockerDown = !d.EngineRunning;
    return [
      ['Docker command available', d.CliFound ? 'ok' : 'err', d.CliFound ? 'Found.' : 'Not found. Install Docker Desktop.', WHY.cli],
      ['Docker Engine running', d.EngineRunning ? 'ok' : 'err', d.EngineRunning ? `Engine ${d.ServerVersion}.` : 'Not reachable. Start Docker Desktop and wait for "Engine running".', WHY.engine],
      ['Linux containers mode', d.OsType === 'linux' ? 'ok' : dockerDown ? 'neutral' : 'err', d.OsType === 'linux' ? 'Linux containers.' : dockerDown ? 'Checked when Docker runs.' : 'Docker Desktop is in Windows-containers mode: right-click the tray icon > Switch to Linux containers.', WHY.linux],
      ['Docker Compose works', d.ComposeOk ? 'ok' : 'err', d.ComposeOk ? `Compose ${d.ComposeVersion}.` : 'Docker Compose v2 is required. Update Docker Desktop.', WHY.compose],
      ['Install folder is writable', env.path.ok ? 'ok' : 'err', env.path.message, WHY.path],
      ['Instance name is available', dockerDown ? 'neutral' : names[0], dockerDown ? 'Checked when Docker runs.' : names[1], WHY.names],
      ['Required ports are free', dockerDown ? 'neutral' : ports[0], dockerDown ? 'Checked when Docker runs.' : ports[1], WHY.ports],
      ['Docker network', dockerDown ? 'neutral' : net[0], dockerDown ? 'Checked when Docker runs.' : net[1], WHY.network],
      ['No subnet overlap', dockerDown ? 'neutral' : subnet[0], dockerDown ? 'Checked when Docker runs.' : subnet[1], WHY.subnet],
      ['Installation state', 'ok', env.installed ? 'An installation exists in this folder; it is managed in place.' : 'No installation in this folder yet.', WHY.state],
      ['Other containers stay unchanged', dockerDown ? 'neutral' : 'ok', dockerDown ? '' : `${env.otherContainers} other container(s) on this PC will not be touched.`, WHY.others],
    ];
  }
  function stepDocker() {
    const s = C.state; const env = s.env;
    if (!env) return h('p', { class: 'muted' }, 'Checking Docker Desktop…');
    const d = env.docker;
    const settings = env.settings;
    const checks = envChecks(env, settings);
    return [
      h('p', { class: 'lead' }, 'Traefik and cloudflared run as containers in Docker Desktop. These checks run automatically and only read; you do not need to run any commands.', ' ', help('docker-desktop', 'Docker Desktop')),
      env.suggested ? h('p', { class: 'hint' }, `Checked with the suggested free values for step 3 (instance ${settings.STACK_NAME}, ports ${settings.TRAEFIK_HTTP_PORT}/${settings.TRAEFIK_DASHBOARD_PORT}).`) : null,
      !dockerOk(d) ? h('div', { class: 'callout warn' },
        h('p', null, h('strong', null, 'Docker Desktop is not ready.')),
        h('ol', null,
          !d.CliFound ? h('li', null, 'Install Docker Desktop for Windows (', h('a', { href: 'https://docs.docker.com/desktop/setup/install/windows-install/', target: '_blank', rel: 'noopener noreferrer' }, 'download and instructions'), '). Use the WSL 2 backend. Restart Windows if asked.') : null,
          h('li', null, 'Start Docker Desktop from the Start menu and wait until it shows "Engine running".'),
          d.EngineRunning && d.OsType !== 'linux' ? h('li', null, 'Right-click the Docker icon in the taskbar and choose "Switch to Linux containers".') : null,
          h('li', null, 'Select ', h('strong', null, 'Check again'), ' below.'))) : null,
      h('ul', { class: 'checks' }, checks.map(([label, st, msg, why]) => checkItem(st, label, msg, U.getLevel() === 'expert' ? null : why))),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => { s.env = await api('GET', '/api/environment'); refreshSteps(); }) }, icon('refresh'), 'Check again'),
        conflictErrors(env).length ? h('button', { type: 'button', class: 'btn primary', onclick: () => goStep(3) }, 'Fix in step 3') : null),
      gate('advanced', kv([['Docker context', d.Context], ['Server version', d.ServerVersion], ['Compose', d.ComposeVersion], ['OS type', d.OsType], ['Install folder', s.setup.installPath]])),
      technical(arr(env.conflicts).map((c) => `[${c.Level}] ${c.Key}: ${c.Message}`).concat(arr(d.Problems).map((p) => `[docker] ${p}`)), 'Raw checks', 'advanced'),
    ];
  }

  // --- Step 3: Configure the deployment ------------------------------------------------------------------------------------
  const SETTING_FIELDS = {
    STACK_NAME: ['Instance name', 'Names the containers and the Compose project, e.g. traefik-ext1.', 'instance'],
    TRAEFIK_HTTP_PORT: ['Traefik HTTP port (127.0.0.1)', 'Where Traefik receives app traffic on this PC.', 'port-publishing'],
    TRAEFIK_DASHBOARD_PORT: ['Local dashboard port (127.0.0.1)', 'Traefik\'s dashboard on this PC.', 'traefik-entrypoints'],
    PROXY_NETWORK: ['Shared Docker network', 'App containers join it so Traefik can reach them by name.', 'docker-networks'],
    TUNNEL_SUBNET: ['Tunnel subnet', 'Private network between cloudflared and Traefik.', 'cidr'],
    TUNNEL_IP_RANGE: ['Tunnel IP range', 'Addresses Docker hands out on that network (cloudflared\'s fixed address must be outside it).', 'cidr'],
    CLOUDFLARED_IP: ['cloudflared address', 'The only address Traefik trusts for forwarded headers.', 'docker-networks'],
  };
  // Unsaved defaults are replaced by the conflict-free values step 2 computed (the user still saves them).
  function settingsForm() {
    const s = C.state;
    if (!s.forms.settings) s.forms.settings = { ...(s.env && s.env.suggested && s.setup.settingsSource === 'defaults' ? s.env.settings : s.setup.settings) };
    return s.forms.settings;
  }
  function stepConfigure() {
    const s = C.state; const setup = s.setup; const editable = !setup.installed;
    const values = settingsForm();
    const level = U.getLevel();
    const input = (key) => {
      const el = h('input', { value: values[key] || '', spellcheck: 'false', autocomplete: 'off', disabled: !editable });
      el.addEventListener('input', () => { values[key] = el.value.trim(); if (key === 'STACK_NAME') updateDashSuggestion(); });
      return field({ id: `wiz-${key}`, label: SETTING_FIELDS[key][0], control: el, hint: SETTING_FIELDS[key][1], helpId: SETTING_FIELDS[key][2] });
    };
    const ports = ['TRAEFIK_HTTP_PORT', 'TRAEFIK_DASHBOARD_PORT'].map(input);
    const net = ['PROXY_NETWORK', 'TUNNEL_SUBNET', 'TUNNEL_IP_RANGE', 'CLOUDFLARED_IP'].map(input);
    const direct = [input('STACK_NAME')];
    const tucked = [];
    if (level === 'beginner') tucked.push(...ports, ...net); else if (level === 'intermediate') { direct.push(...ports); tucked.push(...net); } else direct.push(...ports, ...net);
    const pathInput = h('input', { value: s.forms.path || setup.installPath, spellcheck: 'false', autocomplete: 'off', disabled: !setup.canChangePath });
    pathInput.addEventListener('input', () => { s.forms.path = pathInput.value; });
    const conflicts = s.env ? arr(s.env.conflicts).filter((c) => c.Level !== 'info') : [];
    return [
      h('p', { class: 'lead' }, 'Where this instance lives and what it is called. The suggested values do not collide with anything on this PC; in Beginner mode the network details are tucked away.'),
      field({ id: 'wiz-path', label: 'Install folder', helpId: 'cd-and-paths', control: h('div', { class: 'hostname-row' }, pathInput,
        editable ? h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
          s.setup = await api('POST', '/api/setup/path', { path: pathInput.value.trim() });
          s.installPlan = null; s.env = null; s.forms.settings = null; s.forms.path = null;
          toast(`Install folder: ${s.setup.installPath}`); await reload(3); loadAsync();
        }) }, 'Use this folder') : null),
        hint: editable ? `Default: ${setup.defaultInstallPath}. Holds settings, generated routes, backups and logs; the program itself runs from ${setup.sourcePath}.` : 'Installed here. To use another folder, install a second instance.' }),
      h('div', { class: 'grid' }, direct),
      tucked.length ? h('details', { class: 'more', open: level === 'advanced' || level === 'expert' ? true : null },
        h('summary', null, level === 'beginner' ? 'Ports and network settings (optional: the suggested values work)' : 'Docker network settings (optional)'),
        h('div', { class: 'grid' }, tucked)) : null,
      editable ? h('div', { class: 'actions' },
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('POST', '/api/setup/suggest', {});
          s.forms.settings = { ...r.settings }; s.env = s.env ? { ...s.env, conflicts: r.conflicts } : s.env;
          toast('Free values filled in. Save them to use them.'); updateStep(3);
        }) }, icon('refresh'), 'Suggest free values'),
        h('button', { type: 'button', class: 'btn primary', onclick: (e) => saveConfiguration(e.currentTarget) }, 'Save settings')) : h('p', { class: 'hint' }, 'Settings are read-only after installation (edit .env by hand and re-run the installer).'),
      conflicts.length ? h('ul', { class: 'checks' }, conflicts.map((c) => checkItem(c.Level === 'error' ? 'err' : 'warn', c.Level === 'error' ? 'Conflict' : 'Note', c.Message))) : null,
      dashboardNaming(),
    ];
  }

  // The dashboard hostname follows the instance name until the user edits it.
  function dashForm() {
    const s = C.state; const d = s.dashboard || {};
    if (!s.forms.dash) {
      s.forms.dash = { sub: d.subdomain || L.suggestLabel(settingsForm().STACK_NAME), custom: !!d.subdomainCustom, zoneId: d.zoneId || (domainsOf(s.setup)[0] || {}).id || '', publish: d.configured ? !!d.publish : true };
    }
    return s.forms.dash;
  }
  function updateDashSuggestion() {
    const f = dashForm();
    if (!f.custom) { f.sub = L.suggestLabel(settingsForm().STACK_NAME); const el = $('#dash-sub'); if (el) el.value = f.sub; }
    const prev = $('#dash-preview'); if (prev) prev.textContent = dashUrl();
  }
  function dashUrl() {
    const f = dashForm(); const z = domainsOf(C.state.setup).find((x) => x.id === f.zoneId);
    return z ? `https://${L.joinHostname(f.sub, z.name)}/dashboard/` : '';
  }
  function dashboardNaming() {
    const s = C.state; const doms = domainsOf(s.setup);
    if (!tokenOk(s.setup) || !doms.length || s.setup.deployment.mode === 'local') return null;
    if (s.dashboard && s.dashboard.enabled) return h('div', { class: 'card flat' }, h('h3', null, 'Traefik dashboard'), h('p', null, 'Published at ', h('a', { href: s.dashboard.publicUrl, target: '_blank', rel: 'noopener noreferrer' }, s.dashboard.publicUrl)));
    const f = dashForm();
    const sub = h('input', { id: 'dash-sub', value: f.sub, spellcheck: 'false', autocomplete: 'off', 'aria-describedby': 'dash-preview' });
    const tag = h('span', { class: 'auto-tag' }, f.custom ? 'edited' : 'automatic');
    const reset = h('button', { type: 'button', class: 'btn small ghost', hidden: !f.custom, onclick: () => { Object.assign(f, { sub: L.suggestLabel(settingsForm().STACK_NAME), custom: false }); updateStep(3); } }, 'Reset to automatic');
    sub.addEventListener('input', () => {
      const st = L.autoNameEdit({ value: f.sub, custom: f.custom }, sub.value, settingsForm().STACK_NAME);
      f.sub = st.value; f.custom = st.custom; tag.textContent = f.custom ? 'edited' : 'automatic'; reset.hidden = !f.custom; $('#dash-preview').textContent = dashUrl();
    });
    const zone = h('select', { 'aria-label': 'Domain' }, doms.map((z) => h('option', { value: z.id, selected: z.id === f.zoneId }, z.name)));
    zone.addEventListener('change', () => { f.zoneId = zone.value; $('#dash-preview').textContent = dashUrl(); });
    const pub = h('input', { type: 'checkbox', checked: f.publish });
    pub.addEventListener('change', () => { f.publish = pub.checked; });
    return h('div', { class: 'card flat', 'data-help-host': '' },
      h('div', { class: 'card-head' }, h('h3', null, 'Traefik dashboard hostname'), help('traefik-dashboard', 'Traefik dashboard')),
      h('p', { class: 'muted small' }, 'Your first published hostname: Traefik\'s own dashboard, used to test the whole path before any app. Suggested from the instance name; edit it if you like.'),
      h('div', { class: 'field' }, h('label', { for: 'dash-sub' }, 'Hostname ', tag),
        h('div', { class: 'hostname-row' }, sub, h('span', { class: 'sep' }, '.'), zone),
        h('p', { class: 'hint' }, h('span', { id: 'dash-preview' }, dashUrl()), ' ', reset)),
      h('label', { class: 'check' }, pub, h('span', null, 'Publish it after installation, protected by a Cloudflare Access login (you review the Cloudflare changes in step 6)')));
  }
  async function saveConfiguration(button) {
    const s = C.state;
    await withBusy(button, async () => {
      const r = await api('POST', '/api/setup/settings', { settings: settingsForm() });
      s.installPlan = null; s.dashPlan = null; s.approvals.local = null; s.approvals.cloudflare = null;
      const f = s.forms.dash;
      if (f && tokenOk(s.setup) && domainsOf(s.setup).length && s.setup.deployment.mode !== 'local') {
        s.dashboard = await api('POST', '/api/dashboard/settings', { subdomain: f.sub, subdomainCustom: f.custom, zoneId: f.zoneId, publish: f.publish, accessEmails: s.setup.contactEmail ? [s.setup.contactEmail] : arr((s.dashboard || {}).accessEmails) });
      }
      s.env = s.env ? { ...s.env, conflicts: r.conflicts } : null;
      toast('Settings saved.');
      s.env = await api('GET', '/api/environment');
      s.forms.settings = null;
      await reload();
      if (!conflictErrors(s.env).length) goStep(4);
    });
  }

  // --- Step 4: Configure ingress ----------------------------------------------------------------------------------------------
  function stepIngress() {
    const s = C.state; const setup = s.setup; const dep = setup.deployment; const cf = setup.cloudflare;
    const ok = tokenOk(setup);
    if (setup.installed) {
      return h('p', null, dep.mode === 'tunnel' ? `Cloudflare Tunnel${cf.tunnelName ? ` (${cf.tunnelName})` : ''}. Manage it on the Cloudflare page.` : 'Local only. To publish apps later, set up a tunnel on the Cloudflare page.');
    }
    const current = s.forms.mode || dep.mode || (ok ? 'tunnel' : 'local');
    const modeIcon = { tunnel: 'tunnel', local: 'monitor', 'public-ip': 'globe' };
    const cards = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Ingress method' }, arr(setup.modes).map((m) => {
      const disabled = !m.supported || (m.id === 'tunnel' && !ok);
      return h('label', { class: `choice ${disabled ? 'disabled' : ''}` },
        h('input', { type: 'radio', name: 'wiz-mode', value: m.id, checked: m.id === current, disabled, onchange: () => { s.forms.mode = m.id; updateStep(4); } }),
        h('strong', null, icon(modeIcon[m.id] || 'globe'), ' ', m.title),
        m.supported ? (m.id === 'tunnel' && !ok ? plainChip('Connect Cloudflare first', 'warn') : plainChip('Available', 'ok')) : plainChip('Planned: not available yet', 'neutral'),
        h('span', { class: 'small muted' }, m.detail));
    }));
    const out = [h('p', { class: 'lead' }, 'How Internet visitors reach Traefik. ', help('cf-tunnel', 'Cloudflare Tunnel')), cards];
    if (current === 'tunnel' && ok) out.push(tunnelChoice());
    if (current === 'local') {
      out.push(h('div', { class: 'callout', 'data-help-host': '' },
        h('p', null, h('strong', null, 'Local only. '), 'Nothing is published and Cloudflare is not needed. Traefik answers on this PC: test a route with ',
          h('code', null, `curl -H "Host: app.example.com" http://127.0.0.1:${setup.settings.TRAEFIK_HTTP_PORT}/`), ' or a hosts-file entry. ', help('internal-dns', 'Internal DNS')),
        gate('intermediate', h('p', null, 'Internal DNS (Pi-hole, your router) can resolve names such as service.local.example.com to this PC\'s LAN address. In this version Traefik\'s ports listen on 127.0.0.1 only, so other devices on the LAN cannot reach them yet; LAN binding is a planned option.'))));
    }
    if (current === 'public-ip') out.push(h('div', { class: 'callout warn' }, h('p', null, 'Public-IP ingress is not available in this version. It would need an A record to your WAN address, router or pfSense NAT for ports 80/443, Traefik certificates and WAN hardening. Choose Cloudflare Tunnel or Local only.')));
    out.push(h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', disabled: current === 'public-ip', onclick: (e) => saveIngress(e.currentTarget, current) }, 'Save ingress method')));
    return out;
  }
  function tunnelChoice() {
    const s = C.state; const setup = s.setup; const dep = setup.deployment;
    const tunnels = arr(s.discovery && s.discovery.tunnels).filter((t) => t.remotelyManaged);
    const choice = s.forms.tunnelChoice || dep.tunnelChoice || (tunnels.length ? 'existing' : 'new');
    const nameInput = h('input', { id: 'wiz-tunnel-name', value: s.forms.tunnelName || dep.newTunnelName || setup.settings.STACK_NAME, spellcheck: 'false', autocomplete: 'off' });
    nameInput.addEventListener('input', () => { s.forms.tunnelName = nameInput.value; });
    const sel = h('select', { id: 'wiz-tunnel' }, h('option', { value: '' }, tunnels.length ? 'Choose a tunnel…' : 'No dashboard-managed tunnels found'),
      tunnels.map((t) => h('option', { value: t.id, selected: t.id === (s.forms.tunnelId || dep.tunnelId) }, `${t.name} (${t.status || 'inactive'}, ${t.connections} connection${t.connections === 1 ? '' : 's'})`)));
    sel.addEventListener('change', () => { s.forms.tunnelId = sel.value; });
    const radio = (v, label, extra) => h('label', { class: 'radio' }, h('input', { type: 'radio', name: 'wiz-tchoice', value: v, checked: choice === v, onchange: () => { s.forms.tunnelChoice = v; updateStep(4); } }), h('span', null, h('strong', null, label), extra));
    const zones = domainsOf(setup).map((d) => d.name).join(', ') || '(none allowed yet)';
    return h('fieldset', null, h('legend', null, 'Tunnel for this instance'),
      radio('new', 'Create a new tunnel', ' (recommended: one tunnel per instance). Created only when you approve the Cloudflare changes and install.'),
      choice === 'new' ? field({ id: 'wiz-tunnel-name', label: 'New tunnel name', control: nameInput }) : null,
      radio('existing', 'Reuse an existing tunnel', ' that no other connector on this PC serves.'),
      choice === 'existing' ? field({ id: 'wiz-tunnel', label: 'Tunnel', control: sel }) : null,
      kv([
        ['Account', setup.cloudflare.accountName || '—'],
        ['Domains', zones],
        ['Tunnel type', 'Remotely managed (routes configured through the API)', 'intermediate'],
        ['Local connector', `${setup.settings.STACK_NAME}-cloudflared container`, 'intermediate'],
        ['Traefik destination', 'http://traefik:80 (every hostname)', 'intermediate'],
        ['DNS', 'One proxied CNAME per hostname → <tunnel-id>.cfargotunnel.com, created per service after its own preview', 'advanced'],
      ]),
      h('p', { class: 'hint' }, 'Many hostnames share one tunnel: each app you add later gets its own route on it.'));
  }
  async function saveIngress(button, mode) {
    const s = C.state;
    const body = { mode };
    if (mode === 'tunnel') {
      const dep = s.setup.deployment;
      const tunnels = arr(s.discovery && s.discovery.tunnels).filter((t) => t.remotelyManaged);
      body.tunnelChoice = s.forms.tunnelChoice || dep.tunnelChoice || (tunnels.length ? 'existing' : 'new');
      body.tunnelId = s.forms.tunnelId || dep.tunnelId || '';
      body.newTunnelName = (s.forms.tunnelName || dep.newTunnelName || s.setup.settings.STACK_NAME).trim();
    }
    await withBusy(button, async () => {
      s.setup = await api('POST', '/api/setup/deployment', body);
      s.installPlan = null; s.dashPlan = null; s.approvals.local = null; s.approvals.cloudflare = null;
      toast('Ingress method saved.'); await reload(); goStep(5);
    });
  }

  // --- Step 5: Review local infrastructure -----------------------------------------------------------------------------------
  function stepLocalReview() {
    const s = C.state; const setup = s.setup;
    if (setup.installed) return h('p', null, 'Installed. Settings and runtime state are on the Overview and Settings pages.');
    const plan = s.installPlan;
    const out = [
      h('p', { class: 'lead' }, 'The installer\'s own checks and a dry run, as readable results. Review each section; marking it reviewed collapses it. Docker changes only after you approve below and install in step 7. ', help('review-states', 'Review states')),
      contactEmailField(),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: plan ? 'btn' : 'btn primary', onclick: (e) => runPreview(e.currentTarget) }, icon('refresh'), plan ? 'Run the checks again' : 'Run the checks and dry run')),
    ];
    if (!plan) return out;
    const items = arr(plan.review);
    const validated = items.filter((i) => i.stage === 'validated');
    const tone = (st) => (st === 'ok' ? 'ok' : st === 'failed' ? 'err' : st === 'warning' ? 'warn' : 'neutral');
    const worst = L.worstStatus(validated.map((i) => L.statusFromReview(i.state, 'validated')));
    const dry = validated.filter((i) => /dry run|Compose/.test(i.label));
    const dryStatus = L.worstStatus(dry.map((i) => L.statusFromReview(i.state, 'validated')));
    const v = setup.settings;
    const steps = arr(plan.steps).filter((x) => x.kind !== 'cloudflare');
    out.push(h('div', { class: 'review-list' },
      reviewPanel({
        id: 'local-config', title: 'Configuration to be written', icon: 'folder', status: 'validated', fingerprint: [plan.planKey, steps],
        summary: `Instance ${v.STACK_NAME} in ${setup.installPath}`,
        content: () => [kv([['Install folder', setup.installPath], ['Instance', v.STACK_NAME], ['Ports', `127.0.0.1:${v.TRAEFIK_HTTP_PORT} (apps), 127.0.0.1:${v.TRAEFIK_DASHBOARD_PORT} (dashboard)`, 'intermediate'],
          ['Shared network', v.PROXY_NETWORK, 'advanced'], ['Tunnel subnet', `${v.TUNNEL_SUBNET} (range ${v.TUNNEL_IP_RANGE}, cloudflared ${v.CLOUDFLARED_IP})`, 'advanced']]),
          h('h4', null, 'What the installation does on this PC'), h('ol', null, steps.map((x) => h('li', null, x.text))), expertConfig()],
        onEdit: () => goStep(3), editLabel: 'Edit settings (step 3)',
      }),
      reviewPanel({
        id: 'local-checks', title: 'Checks', icon: 'shield', status: worst, fingerprint: [plan.planKey, validated],
        summary: `${validated.filter((i) => i.state === 'ok').length} of ${validated.length} passed`,
        content: () => h('ul', { class: 'checks' }, validated.map((i) => checkItem(tone(i.state), i.label, i.message))),
      }),
      reviewPanel({
        id: 'local-dryrun', title: 'Installer dry run and Compose check', icon: 'terminal', status: dryStatus, fingerprint: [plan.planKey, dry],
        summary: dry.map((i) => `${i.label}: ${i.state === 'ok' ? 'passed' : i.state}`).join(' · '),
        content: () => [h('p', { class: 'muted' }, 'install.ps1 -DryRun prints every action without doing it; docker compose config checks the generated configuration.')],
        technical: plan.diagnostics, technicalTitle: 'Show technical output',
      }),
      reviewPanel({
        id: 'local-others', title: 'Existing containers', icon: 'box', status: 'validated', fingerprint: [s.env ? s.env.otherContainers : 0],
        summary: s.env ? `${s.env.otherContainers} other container(s) on this PC will remain unchanged` : 'Other containers are never touched',
        content: () => h('p', null, 'Only this instance\'s containers are created and started. Existing containers, networks (other than creating the shared network if it is missing) and volumes are not modified.'),
      })));
    if (arr(plan.blockers).length) out.push(h('div', { class: 'callout err' }, h('p', null, h('strong', null, 'Fix before installing:')), h('ul', null, arr(plan.blockers).map((b) => h('li', null, b)))));
    if (arr(plan.warnings).length) out.push(h('div', { class: 'callout warn' }, h('ul', null, arr(plan.warnings).map((w) => h('li', null, w)))));
    const approved = s.approvals.local === plan.planKey;
    const box = h('input', { type: 'checkbox', checked: approved, disabled: !plan.canInstall });
    box.addEventListener('change', () => { s.approvals.local = box.checked ? plan.planKey : null; refreshSteps(); if (box.checked) goStep(setup.deployment.mode === 'local' ? 7 : 6); });
    out.push(h('div', { class: 'card flat' }, h('h3', null, 'Approve the local changes'),
      h('label', { class: 'check' }, box, h('span', null, `I approve these changes on this PC: write the settings, create the Docker network '${v.PROXY_NETWORK}' if it is missing, and start ${v.STACK_NAME}'s containers. They run when I select Install in step 7.`)),
      !plan.canInstall ? h('p', { class: 'hint warn' }, 'Resolve the problems above first.') : null));
    return out;
  }
  function expertConfig() {
    const s = C.state;
    if (!U.atLeast('expert')) return null;
    if (!s.expert) { api('GET', '/api/expert/config').then((x) => { s.expert = x; refreshSteps(); }).catch(() => {}); return h('p', { class: 'muted' }, 'Loading generated configuration…'); }
    return gate('expert', h('h4', null, 'Generated configuration and commands'),
      arr(s.expert.commands).map((c) => h('div', null, h('p', { class: 'small muted' }, c.purpose), U.output([c.command], c.purpose))),
      arr(s.expert.files).filter((f) => f.path.startsWith('.env')).map((f) => h('details', { class: 'tech' }, h('summary', null, f.path), U.output(f.content.split('\n'), f.path))));
  }
  function contactEmailField() {
    const s = C.state;
    const input = h('input', { type: 'email', value: s.forms.contact !== undefined ? s.forms.contact : (s.setup.contactEmail || (s.discovery && s.discovery.profileEmail) || ''), autocomplete: 'email', spellcheck: 'false', placeholder: 'you@example.com' });
    input.addEventListener('input', () => { s.forms.contact = input.value; });
    const fromProfile = !s.setup.contactEmail && s.discovery && s.discovery.profileEmail && input.value === s.discovery.profileEmail;
    return h('div', { class: 'card flat' },
      field({ id: 'wiz-contact', label: 'Your email (optional)', helpId: 'cf-access', control: h('div', { class: 'hostname-row' }, input,
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => { const r = await api('POST', '/api/setup/contact', { email: input.value.trim() }); s.setup.contactEmail = r.contactEmail; s.forms.contact = undefined; toast(r.contactEmail ? 'Email saved.' : 'Email cleared.'); updateStep(5); }) }, 'Save')),
        hint: 'Used only as the default person allowed to sign in through Cloudflare Access (the public dashboard and new services). It is not used for HTTPS certificates: Cloudflare issues those at its edge without an ACME email. No notifications are sent.' }),
      fromProfile ? h('p', { class: 'hint' }, 'Prefilled from your Cloudflare profile. Check it, then Save.') : null);
  }
  async function runPreview(button) {
    const s = C.state;
    await withBusy(button, async () => {
      const prev = s.installPlan && s.installPlan.planKey;
      s.installPlan = await api('POST', '/api/setup/preview', {});
      if (prev !== s.installPlan.planKey) { s.approvals.local = null; s.approvals.cloudflare = null; }
      s.expert = null; s.dashPlan = null;
      refreshSteps();
    });
  }

  // --- Step 6: Review Cloudflare changes ---------------------------------------------------------------------------------------
  function stepCloudflareReview() {
    const s = C.state; const setup = s.setup; const dep = setup.deployment;
    if (setup.installed) return h('p', null, 'Installed. Cloudflare resources are listed on the Cloudflare page.');
    if (dep.mode === 'local') return h('p', null, 'Not needed: a local-only installation makes no Cloudflare changes.');
    if (dep.mode !== 'tunnel') return h('p', { class: 'muted' }, 'Choose the ingress method in step 4 first.');
    const plan = s.installPlan;
    if (!plan) return [h('p', { class: 'muted' }, 'Run the checks in step 5 first; the Cloudflare review uses the same preview.'), h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: () => goStep(5) }, 'Go to step 5'))];
    const d = s.dashboard || {}; const f = dashForm();
    const wantDash = f.publish && domainsOf(setup).length > 0;
    const isNew = dep.tunnelChoice === 'new';
    if (wantDash && !isNew && !s.dashPlan && !loading.dashPlan) {
      loading.dashPlan = true;
      api('POST', '/api/dashboard/plan', { subdomain: f.sub, zoneId: f.zoneId, accessEmails: dashEmails() })
        .then((p) => { s.dashPlan = p; }).catch((e) => { s.dashPlan = { error: e.message }; }).finally(() => { loading.dashPlan = false; refreshSteps(); });
    }
    const cfSteps = arr(plan.steps).filter((x) => x.kind === 'cloudflare');
    const dp = s.dashPlan;
    const dashActions = dp && !dp.error ? arr(dp.cloudflare.actions) : [];
    const dashErrors = dp ? (dp.error ? [dp.error] : arr(dp.cloudflare.errors)) : [];
    const dashHost = L.joinHostname(f.sub, (domainsOf(setup).find((z) => z.id === f.zoneId) || {}).name || '');
    const sig = JSON.stringify([plan.planKey, cfSteps, wantDash ? (isNew ? `new:${dashHost}` : actionSig(dashActions)) : 'none']);
    const approved = s.approvals.cloudflare === sig;
    const out = [h('p', { class: 'lead' }, 'Everything that will change in your Cloudflare account, reviewed separately from the local changes. A preview changes nothing: these run only after you approve them and select Install in step 7.')];
    out.push(h('div', { class: 'review-list' },
      reviewPanel({ id: 'cf-account', title: 'Account and domain', icon: 'cloud', status: 'validated', fingerprint: [setup.cloudflare.accountId, domainsOf(setup)],
        summary: `${setup.cloudflare.accountName} · ${domainsOf(setup).map((z) => z.name).join(', ')}`,
        content: () => kv([['Account', setup.cloudflare.accountName], ['Account id', setup.cloudflare.accountId, 'expert'], ['Allowed domains', domainsOf(setup).map((z) => z.name).join(', ')],
          ['Zone ids', domainsOf(setup).map((z) => z.id).join(', '), 'expert']]) }),
      reviewPanel({ id: 'cf-tunnel', title: 'Tunnel', icon: 'tunnel', status: 'validated', fingerprint: [dep.tunnelChoice, dep.tunnelId, dep.newTunnelName],
        summary: isNew ? `Create a new tunnel '${dep.newTunnelName}'` : `Reuse tunnel '${dep.tunnelName}'`,
        content: () => [h('ul', { class: 'action-list' }, h('li', null, isNew ? C.kindBadge.create() : C.kindBadge.none(), ' ', plainChip('Tunnel'), ' ',
          isNew ? `Create the remotely managed tunnel '${dep.newTunnelName}' in ${setup.cloudflare.accountName}` : `Reuse '${dep.tunnelName}' (no change to the tunnel itself)`)),
          h('p', { class: 'muted small' }, 'The connector token of this tunnel is downloaded into secrets\\ on this PC (a read-only API call) and used by this instance\'s cloudflared container.'),
          gate('expert', kv([['Tunnel id', dep.tunnelId || '(assigned by Cloudflare when created)']]))] }),
      wantDash ? reviewPanel({ id: 'cf-dashboard', title: 'Public Traefik dashboard', icon: 'lock', status: dashErrors.length ? 'failed' : isNew || dp ? 'validated' : 'pending', fingerprint: [dashHost, isNew ? 'new' : actionSig(dashActions)],
        summary: `https://${dashHost}/dashboard/ behind Cloudflare Access`, defaultOpen: true,
        content: () => [
          isNew ? h('ul', { class: 'action-list' }, ['Create (or reuse) a Cloudflare Access application for ' + dashHost, `Add the tunnel route ${dashHost} → http://traefik:80`, `Create the proxied CNAME ${dashHost} → <new tunnel>.cfargotunnel.com`]
            .map((t) => h('li', null, C.kindBadge.create(), ' ', t)))
            : dp ? C.cloudflareActionList(dashActions, 'cf-overwrite') : h('p', { class: 'muted' }, 'Reading the current Cloudflare state…'),
          isNew ? h('p', { class: 'hint' }, 'The exact plan is computed again after the tunnel exists; if it differs from this, you are asked to approve it in step 7.') : null,
          dashErrors.map((e) => h('p', { class: 'form-error' }, e)),
          dashEmailField(),
          h('p', { class: 'muted small' }, 'Fail closed: the route, tunnel route and DNS record are only created after the Access application exists. If Access cannot be set up, nothing is published.')] }) : null,
      reviewPanel({ id: 'cf-dns', title: 'DNS records', icon: 'globe', status: dashActions.some((a) => a.overwrite) ? 'warning' : 'validated', fingerprint: [dashHost, actionSig(dashActions.filter((a) => a.step === 'dns'))],
        summary: wantDash ? `One CNAME for ${dashHost}; nothing else` : 'No DNS records during installation',
        content: () => [h('p', null, wantDash ? `Only the proxied CNAME ${dashHost} is created. ` : 'No DNS record is created during installation; each app gets its own record when you add it, after its own preview. ',
          'MX, SPF, DKIM, DMARC, TXT and all other existing records are never touched. An existing record is only replaced after a separate per-record confirmation; A/AAAA records are never changed automatically.'), help('dns-mail', 'Email DNS records')] }),
      reviewPanel({ id: 'cf-security', title: 'Security and rollback', icon: 'shield', status: 'info', statusLabel: 'Read me', fingerprint: ['security-v1', wantDash],
        summary: 'Outbound tunnel, Access login, recovery points',
        content: () => h('ul', null,
          h('li', null, 'The tunnel is an outbound connection from this PC: no router port is opened and your IP address is not published.'),
          wantDash ? h('li', null, 'The public dashboard requires a Cloudflare Access login. Turnstile or a CAPTCHA is not a login and is never used instead.') : null,
          h('li', null, 'A recovery point is saved before every change. Resources this tool creates are recorded (config\\cloudflare.json) so they can be removed again without touching anything else.'),
          h('li', null, 'The API token never leaves this PC except in calls to api.cloudflare.com.')) })));
    const overwrites = dashActions.filter((a) => a.overwrite);
    const box = h('input', { type: 'checkbox', checked: approved, disabled: dashErrors.length > 0 && wantDash });
    box.addEventListener('change', () => {
      const confirmed = $$('.cf-overwrite:checked').map((b) => b.dataset.id);
      if (box.checked && overwrites.some((a) => !confirmed.includes(a.id))) { box.checked = false; toast('Tick each overwrite of an existing Cloudflare resource first.', true); return; }
      s.approvals.cloudflare = box.checked ? sig : null;
      s.approvals.dashboardSig = box.checked && wantDash ? (isNew ? 'new' : actionSig(dashActions)) : null;
      s.approvals.overwrites = box.checked ? confirmed : [];
      refreshSteps(); if (box.checked) goStep(7);
    });
    out.push(h('div', { class: 'card flat' }, h('h3', null, 'Approve the Cloudflare changes'),
      h('label', { class: 'check' }, box, h('span', null, `I approve these changes in my Cloudflare account (${[isNew ? 'create the tunnel' : null, wantDash ? 'publish the dashboard behind Access' : null].filter(Boolean).join(', ') || 'connect the existing tunnel'}). They run when I select Install in step 7.`)),
      wantDash && dashErrors.length ? h('p', { class: 'hint warn' }, 'Fix the dashboard problem above, or untick "Publish it after installation" in step 3 to install without it.') : null));
    return out;
  }
  function dashEmails() {
    const s = C.state; const d = s.dashboard || {};
    const fromForm = s.forms.dashEmails !== undefined ? L.splitEmails(s.forms.dashEmails) : null;
    return fromForm || (arr(d.accessEmails).length ? arr(d.accessEmails) : s.setup.contactEmail ? [s.setup.contactEmail] : []);
  }
  function dashEmailField() {
    const s = C.state;
    const input = h('input', { value: dashEmails().join(', '), spellcheck: 'false', autocomplete: 'off', placeholder: 'you@example.com' });
    input.addEventListener('change', () => { s.forms.dashEmails = input.value; s.dashPlan = null; refreshSteps(); });
    return field({ id: 'wiz-dash-emails', label: 'Who may sign in to the dashboard', helpId: 'cf-access', control: input, hint: 'Emails allowed by the Access application, if one has to be created. Defaults to your email from step 5.' });
  }

  // --- Step 7: Install and verify ----------------------------------------------------------------------------------------------
  function stepInstall() {
    const s = C.state; const setup = s.setup; const plan = s.installPlan; const dep = setup.deployment;
    const out = [];
    if (!setup.installed) {
      const needCf = dep.mode === 'tunnel';
      const localOk = !!(plan && s.approvals.local === plan.planKey);
      const cfOk = !needCf || !!s.approvals.cloudflare;
      out.push(h('p', { class: 'lead' }, 'Applies what you approved, then checks the running infrastructure component by component.'));
      out.push(h('ul', { class: 'checks' },
        checkItem(localOk ? 'ok' : 'neutral', 'Local changes', localOk ? 'Approved in step 5.' : 'Not approved yet (step 5).'),
        checkItem(cfOk ? 'ok' : 'neutral', 'Cloudflare changes', !needCf ? 'None (local only).' : cfOk ? 'Approved in step 6.' : 'Not approved yet (step 6).')));
      out.push(h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', disabled: !(localOk && cfOk), onclick: (e) => runInstall(e.currentTarget) }, icon('rocket'), 'Install and verify')));
    } else {
      out.push(h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => runVerify()) }, icon('pulse'), s.verify ? 'Verify again' : 'Run the verification')));
    }
    if (s.run) out.push(h('h3', null, 'Progress'), h('ul', { class: 'checks', 'aria-live': 'polite' }, s.run.map((x) => checkItem(x.status === 'done' ? 'ok' : x.status === 'failed' ? 'err' : x.status === 'warn' ? 'warn' : 'neutral', x.label, x.message))));
    if (s.installResult && arr(s.installResult.lines).length) out.push(technical(s.installResult.lines, 'Installer output'));
    if (s.verify) out.push(renderVerification(s.verify));
    return out;
  }

  async function runInstall(button) {
    const s = C.state; const plan = s.installPlan; const dep = s.setup.deployment;
    const ok = await U.confirmDialog({ title: 'Install this instance', okText: 'Install',
      body: [h('p', null, 'This applies what you approved:'), h('ul', null, arr(plan.steps).map((x) => h('li', null, x.text)), s.approvals.dashboardSig ? h('li', null, 'Publish the Traefik dashboard behind Cloudflare Access') : null),
        'Existing containers, networks and unrelated Cloudflare resources are not modified.'] });
    if (!ok) return;
    const run = s.run = [];
    const stepRun = (label) => { const x = { label, status: 'running', message: 'Working…' }; run.push(x); updateStep(7); return x; };
    await withBusy(button, async () => {
      const a = stepRun('Install (settings, tunnel, containers)');
      try {
        s.installResult = await api('POST', '/api/setup/install', { confirm: true, confirmCloudflare: dep.mode === 'tunnel' && !!s.approvals.cloudflare, planKey: plan.planKey });
        a.status = s.installResult.ok ? 'done' : 'failed';
        a.message = arr(s.installResult.steps).map((x) => `${x.name}: ${x.status}`).join(' · ');
      } catch (e) { a.status = 'failed'; a.message = e.message; if (e.status === 409) s.installPlan = null; }
      await C.refresh();
      if (a.status !== 'done') { updateStep(7); return; }
      s.installPlan = null;
      if (s.approvals.dashboardSig) {
        const b = stepRun('Publish the Traefik dashboard (Access first)');
        try {
          const f = dashForm();
          const p = await api('POST', '/api/dashboard/plan', { subdomain: f.sub, zoneId: f.zoneId, accessEmails: dashEmails() });
          const same = s.approvals.dashboardSig !== 'new' && actionSig(p.cloudflare.actions) === s.approvals.dashboardSig;
          if (!p.hasWork) { b.status = 'done'; b.message = 'Already published.'; }
          else if (!p.canApply) { b.status = 'failed'; b.message = arr(p.cloudflare.errors).join(' ') || 'The plan has errors.'; }
          else if (!same) {
            b.status = 'warn'; b.message = 'The Cloudflare plan differs from what you approved (a new tunnel). Review it in the dialog and apply it there.';
            C.state.planBody = {}; C.state.planApplyPath = '/api/dashboard/apply'; C.state.plan = p; C.state.replan = null;
            C.renderPlan(p, { op: 'dashboard' }); U.openDialog($('#plan-dialog'));
          } else {
            const r = await api('POST', '/api/dashboard/apply', { planId: p.planId, confirm: true, confirmOverwrites: s.approvals.overwrites });
            b.status = r.ok ? 'done' : 'failed'; b.message = r.failClosed ? 'Cloudflare Access could not be confirmed, so nothing was published (fail closed).' : arr(r.steps).map((x) => `${x.name}: ${x.status}`).join(' · ');
          }
        } catch (e) { b.status = 'failed'; b.message = e.message; }
      }
      await C.refresh();
      await runVerify();
    });
  }

  // Verification: every component on its own, plus the topology.
  async function runVerify() {
    const s = C.state;
    const c = s.run ? (() => { const x = { label: 'Verify the running infrastructure', status: 'running', message: '' }; s.run.push(x); updateStep(7); return x; })() : null;
    await C.refresh();
    const dash = s.dashboard || {};
    let dv = null; let ov = null;
    try { [dv, ov] = await Promise.all([api('POST', '/api/dashboard/verify', { public: !!dash.enabled }), api('GET', '/api/overview')]); } catch (e) { if (c) { c.status = 'failed'; c.message = e.message; } }
    s.verify = buildVerification(dv, ov);
    if (c) { c.status = s.verify.ready ? 'done' : 'warn'; c.message = s.verify.ready ? 'All components passed.' : 'Some components need attention (see below).'; }
    refreshSteps();
  }
  P.runVerify = (ctx) => { C = ctx; return runVerify(); };
  function buildVerification(dv, ov) {
    const s = C.state; const st = s.status; const mode = (ov && ov.mode) || s.setup.deployment.mode;
    const checks = {}; arr(dv && dv.checks).forEach((x) => { checks[x.id] = x; });
    const cont = {}; arr(st.stack.Containers).forEach((x) => { cont[x.Role] = x; });
    const cstate = (x) => (!x ? ['neutral', 'Not found.'] : x.State === 'running' && (!x.Health || x.Health === 'healthy') ? ['ok', `${x.Name}: running${x.Health ? ` (${x.Health})` : ''}`] : x.State === 'running' ? ['warn', `${x.Name}: running (${x.Health})`] : ['err', `${x.Name}: ${x.State}`]);
    const fromCheck = (id, fallback) => { const x = checks[id]; if (!x) return fallback; return [{ ok: 'ok', failed: 'err', warning: 'warn', skipped: 'neutral' }[x.state] || 'neutral', x.message]; };
    const dashEnabled = !!(s.dashboard && s.dashboard.enabled);
    const routers = arr(st.stack.Routers);
    const localRouter = routers.some((r) => r.Name === 'dashboard@file' && r.Status === 'enabled');
    const items = [
      ['Traefik container', ...cstate(cont.traefik), true],
      ['Docker socket proxy', ...cstate(cont['socket-proxy']), true],
      mode === 'tunnel' ? ['cloudflared connector', ...cstate(cont.cloudflared), true] : null,
      mode === 'tunnel' ? ['Cloudflare Tunnel connectivity', ...(ov && ov.tunnel ? (ov.tunnel.status === 'healthy' || ov.tunnel.connections > 0 ? ['ok', `Cloudflare reports '${ov.tunnel.status}', ${ov.tunnel.connections} connection(s).`] : ['err', `Cloudflare reports '${ov.tunnel.status}'.${ov.tunnel.error ? ` ${ov.tunnel.error}` : ''}`]) : ['neutral', 'Not checked (Cloudflare not connected).']), true] : null,
      ['Traefik local dashboard', ...fromCheck('local-dashboard', ['neutral', '']), true],
      ['Dashboard internal router', ...(dashEnabled ? fromCheck('local-routing', ['neutral', '']) : localRouter ? ['ok', 'dashboard@file (api@internal on 127.0.0.1) is loaded.'] : ['err', 'The local dashboard router is not loaded.']), true],
      dashEnabled ? ['Requests without Access are refused', ...fromCheck('fail-closed', ['neutral', '']), true] : null,
      dashEnabled ? ['Public DNS configuration', ...fromCheck('dns', ['neutral', '']), true] : null,
      dashEnabled ? ['Cloudflare Access protection', ...fromCheck('access', ['neutral', '']), true] : null,
      dashEnabled ? ['Tunnel route', ...fromCheck('tunnel-route', ['neutral', '']), true] : null,
      dashEnabled ? ['Authenticated dashboard reachability', ...(checks['public-url'] && checks['public-url'].state === 'ok' ? ['warn', 'The public URL shows the Cloudflare Access login, so it is protected. Sign in once to confirm the dashboard loads; this tool cannot sign in for you.'] : fromCheck('public-url', ['neutral', 'Not checked.'])), false] : null,
    ].filter(Boolean);
    const ready = items.filter((x) => x[3]).every((x) => x[1] === 'ok');
    return { items, ready, mode, ov, dv, dashEnabled, publicUrl: dash().publicUrl };
    function dash() { return s.dashboard || {}; }
  }
  function renderVerification(v) {
    const s = C.state; const st = s.status;
    const find = (label) => (v.items.find((x) => x[0] === label) || [])[1] || 'neutral';
    const tone = (x) => (x === 'ok' ? 'ok' : x === 'err' ? 'err' : x === 'warn' ? 'warn' : 'neutral');
    const nodes = v.mode === 'tunnel'
      ? [{ title: 'Visitor', sub: 'browser', icon: 'user', state: 'neutral' },
        { title: 'Cloudflare', sub: v.dashEnabled ? 'DNS + Access login' : 'edge', icon: 'cloud', state: v.dashEnabled ? tone(find('Cloudflare Access protection')) : 'neutral' },
        { title: 'Tunnel', sub: 'outbound, encrypted', icon: 'tunnel', state: tone(find('Cloudflare Tunnel connectivity')) },
        { title: 'cloudflared', sub: 'this PC', icon: 'box', state: tone(find('cloudflared connector')) },
        { title: 'Traefik', sub: `127.0.0.1:${st.instance.httpPort}`, icon: 'route', state: tone(find('Traefik container')) },
        { title: 'Your apps', sub: 'Docker, this PC, LAN', icon: 'server', state: 'neutral' }]
      : [{ title: 'Browser', sub: 'this PC', icon: 'monitor', state: 'neutral' },
        { title: 'Traefik', sub: `127.0.0.1:${st.instance.httpPort}`, icon: 'route', state: tone(find('Traefik container')) },
        { title: 'Your apps', sub: 'Docker, this PC, LAN', icon: 'server', state: 'neutral' }];
    const links = v.mode === 'tunnel' ? [{ label: 'HTTPS' }, { label: 'tunnel', state: tone(find('Cloudflare Tunnel connectivity')) === 'ok' ? 'ok' : '' }, { label: '' }, { label: 'http :80' }, { label: 'by hostname' }] : [{ label: 'http' }, { label: 'by hostname' }];
    // Outside the setup journey the page has its own topology and navigation.
    const onSetup = C.state.page === 'setup';
    return h('div', null,
      v.ready ? h('div', { class: 'ready-banner', role: 'status' }, icon('check'), h('div', null, h('h2', null, 'Your reverse proxy is ready.'),
        h('p', null, v.dashEnabled ? ['Open ', h('a', { href: v.publicUrl, target: '_blank', rel: 'noopener noreferrer' }, v.publicUrl), ' and sign in with Cloudflare Access to see Traefik.'] : 'Traefik is running. Add your first service next.'),
        h('div', { class: 'actions' }, onSetup ? h('button', { type: 'button', class: 'btn primary', onclick: () => C.navigate('overview') }, 'Go to the Overview') : null,
          h('button', { type: 'button', class: onSetup ? 'btn' : 'btn primary', onclick: () => C.navigate('services', 'add') }, 'Add a service'))))
        : h('div', { class: 'callout warn' }, h('p', null, h('strong', null, 'Not everything is healthy yet. '), 'Each component is checked on its own below; a running container alone does not mean the deployment works.'),
          h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, () => runVerify()) }, 'Verify again'),
            h('button', { type: 'button', class: 'btn small', onclick: () => C.navigate('diagnostics') }, 'Open Diagnostics'),
            h('button', { type: 'button', class: 'btn small', onclick: () => C.navigate('dashboard') }, 'Traefik dashboard settings'))),
      onSetup ? [h('h3', null, 'Topology'), U.topology(nodes, links)] : null,
      h('h3', null, 'Components'), h('ul', { class: 'checks' }, v.items.map(([label, st2, msg]) => checkItem(st2, label, msg))),
      technical(arr(v.dv && v.dv.checks).map((x) => `${x.id}: ${x.state} - ${x.message}`), 'Raw verification results', 'advanced'));
  }
  P.renderVerification = (ctx, v) => { C = ctx; return renderVerification(v); };
  P.buildVerification = (ctx, dv, ov) => { C = ctx; return buildVerification(dv, ov); };
})();
