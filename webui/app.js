'use strict';
// Traefik Proxy Manager - browser side. Talks only to the local webui.ps1 API (same origin).
// All dynamic content is inserted with textContent / DOM nodes, never innerHTML.
(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const arr = (v) => (Array.isArray(v) ? v : v === null || v === undefined ? [] : [v]);

  const state = {
    csrf: '',
    status: null,
    services: [],
    middlewares: [],
    zones: [],
    cf: null,
    setup: null,
    discovery: null,
    installPlan: null,
    installResult: null,
    conflicts: null,
    editing: null,
    planBody: null,
    plan: null,
  };

  // --- DOM helpers ----------------------------------------------------------------------------------
  function h(tag, attrs, ...children) {
    const el = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = v;
        else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, v === true ? '' : String(v));
      }
    }
    for (const c of children.flat(Infinity)) {
      if (c === null || c === undefined || c === false) continue;
      el.append(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  }
  const badge = (text, kind = 'neutral') => h('span', { class: `badge ${kind}` }, text);
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function fill(el, ...nodes) { clear(el); el.append(...nodes.flat(Infinity).filter((n) => n !== null && n !== undefined && n !== false)); return el; }

  let toastTimer = null;
  function toast(message, isError = false) {
    const t = $('#toast');
    t.textContent = message;
    t.className = isError ? 'toast err' : 'toast';
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, isError ? 9000 : 4500);
  }

  // --- API ------------------------------------------------------------------------------------------
  async function api(method, path, body) {
    const opts = { method, headers: { Accept: 'application/json' }, credentials: 'same-origin' };
    if (method !== 'GET') {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['X-CSRF-Token'] = state.csrf;
      opts.body = JSON.stringify(body || {});
    }
    let res;
    try {
      res = await fetch(path, opts);
    } catch (e) {
      throw new Error('The web UI server is not reachable. Is webui.ps1 still running?');
    }
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (res.status === 401) showSignedOut();
    if (!res.ok) {
      const err = new Error((data && data.error) || `Request failed (HTTP ${res.status}).`);
      err.status = res.status;
      err.data = data || {};
      throw err;
    }
    return data;
  }

  async function withBusy(button, fn) {
    if (button) { button.disabled = true; button.setAttribute('aria-busy', 'true'); }
    try {
      return await fn();
    } catch (e) {
      if (e.status !== 401) toast(e.message, true);
      return undefined;
    } finally {
      if (button) { button.disabled = false; button.removeAttribute('aria-busy'); }
    }
  }

  function showSignedOut() {
    $('#signed-out').hidden = false;
    $$('.panel').forEach((p) => { p.hidden = true; });
    $('.tabs').hidden = true;
  }

  // --- Dialogs --------------------------------------------------------------------------------------
  function openDialog(dlg) {
    if (!dlg.open) dlg.showModal();
    const focusTarget = dlg.querySelector('[autofocus], .dialog-scroll input, .dialog-foot .btn.primary') || dlg.querySelector('.icon-btn');
    if (focusTarget) focusTarget.focus();
  }
  $$('dialog').forEach((dlg) => {
    dlg.addEventListener('click', (e) => { if (e.target.closest('[data-close]')) dlg.close('cancel'); });
  });

  // Generic confirmation. Resolves true only when the user presses the confirm button (and ticks the box, if any).
  function confirmDialog({ title, body, okText = 'Confirm', danger = false, checkbox = null }) {
    const dlg = $('#confirm-dialog');
    $('#confirm-title').textContent = title;
    const content = fill($('#confirm-content'), arr(body).map((b) => (typeof b === 'string' ? h('p', null, b) : b)));
    const ok = $('#confirm-ok');
    ok.textContent = okText;
    ok.className = danger ? 'btn danger' : 'btn primary';
    let box = null;
    if (checkbox) {
      box = h('input', { type: 'checkbox', id: 'confirm-check' });
      content.append(h('label', { class: 'check' }, box, h('span', null, checkbox)));
      ok.disabled = true;
      box.addEventListener('change', () => { ok.disabled = !box.checked; });
    } else {
      ok.disabled = false;
    }
    return new Promise((resolve) => {
      const onOk = () => { cleanup(); dlg.close('ok'); resolve(true); };
      const onClose = () => { cleanup(); resolve(false); };
      function cleanup() { ok.removeEventListener('click', onOk); dlg.removeEventListener('close', onClose); }
      ok.addEventListener('click', onOk);
      dlg.addEventListener('close', onClose);
      openDialog(dlg);
    });
  }

  // --- Tabs -----------------------------------------------------------------------------------------
  const tabs = $$('[role="tab"]');
  const loaders = {
    setup: () => refreshStatus(),
    services: () => loadServices(),
    cloudflare: () => loadCloudflare(),
    backups: () => loadBackups(),
    logs: () => Promise.resolve(),
  };
  function selectTab(name, focus = false) {
    if (!loaders[name]) name = 'setup';
    for (const t of tabs) {
      const on = t.id === `tab-${name}`;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $(`#${t.getAttribute('aria-controls')}`).hidden = !on;
      if (on && focus) t.focus();
    }
    if (location.hash !== `#${name}`) history.replaceState(null, '', `#${name}`);
    loaders[name]().catch((e) => toast(e.message, true));
  }
  tabs.forEach((t, i) => {
    t.addEventListener('click', () => selectTab(t.id.replace('tab-', '')));
    t.addEventListener('keydown', (e) => {
      let j = null;
      if (e.key === 'ArrowRight') j = (i + 1) % tabs.length;
      else if (e.key === 'ArrowLeft') j = (i - 1 + tabs.length) % tabs.length;
      else if (e.key === 'Home') j = 0;
      else if (e.key === 'End') j = tabs.length - 1;
      if (j !== null) { e.preventDefault(); selectTab(tabs[j].id.replace('tab-', ''), true); }
    });
  });

  // --- Status / setup -------------------------------------------------------------------------------
  function cfReady(s = state.status) {
    return !!(s && s.cloudflare.tokenStored && s.cloudflare.accountId && s.cloudflare.tunnelId);
  }

  async function refreshStatus() {
    const [s, setup] = await Promise.all([api('GET', '/api/status'), api('GET', '/api/setup')]);
    state.status = s;
    state.setup = setup;
    if (!setup.cloudflare.tokenStored) state.discovery = null;
    renderInstance(s);
    renderSetup(s);
    // What the stored token can do is checked once per page load (read-only Cloudflare calls).
    if (setup.cloudflare.tokenStored && setup.cloudflare.tokenReadable && !state.discovery && !state.discoveryLoading) {
      state.discoveryLoading = true;
      loadDiscovery().catch((e) => toast(e.message, true)).finally(() => { state.discoveryLoading = false; });
    }
    return s;
  }

  function renderInstance(s) {
    const i = s.instance;
    fill($('#instance-badge'),
      h('span', { class: 'pill', title: i.installPath }, `Instance: ${i.stackName}`),
      h('span', { class: 'pill' }, `Traefik 127.0.0.1:${i.httpPort}`),
      h('span', { class: 'pill' }, `Dashboard 127.0.0.1:${i.dashboardPort}`));
  }

  function check(ok, text, warn = false) {
    return h('li', null, badge(ok ? 'OK' : warn ? 'Check' : 'Missing', ok ? 'ok' : warn ? 'warn' : 'err'), ' ', text);
  }

  function step(n, title, status, badgeEl, ...body) {
    const icon = status === 'done' ? '✓' : status === 'blocked' ? '!' : String(n);
    return h('li', { class: `step ${status}` },
      h('div', { class: 'step-icon', 'aria-hidden': 'true' }, icon),
      h('div', null, h('h2', null, `${n}. ${title}`, ' ', badgeEl), ...body));
  }

  // The first-run wizard. Order: Cloudflare first (or skip for local-only), then Docker, install folder and
  // instance settings, deployment method, domains, HTTPS, and finally a preview and the confirmed installation.
  // Nothing changes Docker or Cloudflare before "Install" is confirmed (the API token is only verified and stored).
  const HANDOFF_TEXT = "Cloudflare will display your API token when you create it. Copy it before closing that page. For security, Cloudflare won't display the same secret again. If you lose it, revoke or delete the old token and create a replacement.";

  function renderSetup(s) {
    const setup = state.setup;
    if (!setup) return;
    const d = s.docker;
    const cf = setup.cloudflare;
    const dep = setup.deployment;
    const localOnly = dep.mode === 'local';
    const steps = [];
    const tokenOk = cf.tokenStored && cf.tokenReadable;
    const dockerOk = d.CliFound && d.EngineRunning && d.OsType === 'linux' && d.ComposeOk;

    // 1. Connect Cloudflare
    const cfDone = tokenOk && arr(cf.domains).length > 0;
    steps.push(step(1, 'Connect Cloudflare', cfDone ? 'done' : (localOnly && !tokenOk) ? 'done' : 'attention',
      badge(cfDone ? `${arr(cf.domains).length} allowed domain(s)` : tokenOk ? 'Choose domains' : localOnly ? 'Skipped (local only)' : 'Start here', cfDone || (localOnly && !tokenOk) ? 'ok' : 'warn'),
      renderConnectCloudflare(setup)));

    // 2. Docker Desktop
    steps.push(step(2, 'Docker Desktop', dockerOk ? 'done' : 'blocked', badge(dockerOk ? 'Ready' : 'Needs attention', dockerOk ? 'ok' : 'err'),
      h('p', null, 'Traefik and cloudflared run as Linux containers in Docker Desktop (WSL 2 backend). This check only reads.'),
      h('ul', { class: 'checks' },
        check(d.CliFound, 'docker command available'),
        check(d.EngineRunning, d.EngineRunning ? `Docker engine running (version ${d.ServerVersion})` : 'Docker engine running'),
        check(d.OsType === 'linux', 'Linux containers mode'),
        check(d.ComposeOk, d.ComposeVersion ? `Docker Compose ${d.ComposeVersion}` : 'Docker Compose v2')),
      arr(d.Problems).map((p) => h('p', { class: 'hint warn' }, p)),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, refreshStatus) }, 'Check again'))));

    // 3. Install folder and instance settings
    steps.push(step(3, 'Install folder and instance settings', setup.installed ? 'done' : setup.settingsSource === 'draft' ? 'done' : 'todo',
      badge(setup.installed ? 'Installed' : setup.settingsSource === 'draft' ? 'Saved' : 'Defaults', setup.installed || setup.settingsSource === 'draft' ? 'ok' : 'neutral'),
      renderInstanceSettings(setup)));

    // 4. Deployment method
    steps.push(step(4, 'Deployment method', dep.mode ? 'done' : 'todo', badge(dep.mode === 'tunnel' ? 'Cloudflare Tunnel' : localOnly ? 'Local only' : 'Not chosen', dep.mode ? 'ok' : 'neutral'),
      renderDeployment(setup)));

    // 5. Domains and DNS
    steps.push(step(5, 'Domains and DNS', localOnly || arr(cf.domains).length ? 'done' : 'todo',
      badge(localOnly ? 'Not needed' : arr(cf.domains).length ? arr(cf.domains).map((x) => x.name).join(', ') : 'No domain', localOnly || arr(cf.domains).length ? 'ok' : 'neutral'),
      localOnly
        ? h('p', null, 'Local only: no DNS records are created. Apps are reached through Traefik on this PC (127.0.0.1) with their hostname, for example with a hosts-file entry or ',
          h('code', null, `curl -H "Host: app.example.com" http://127.0.0.1:${setup.settings.TRAEFIK_HTTP_PORT}/`), '.')
        : [h('p', null, 'Services can only be published under the allowed domains chosen in step 1, even if the API token can see more. ',
          'Each published hostname gets a proxied CNAME record pointing at the tunnel; it is created when you add the service, after its own preview and confirmation. Existing records are never replaced without a separate confirmation.'),
        arr(cf.domains).length ? h('ul', { class: 'checks' }, arr(cf.domains).map((x) => check(true, x.name))) : h('p', { class: 'hint warn' }, 'No allowed domain yet. Choose one in step 1.')]));

    // 6. HTTPS certificates
    steps.push(step(6, 'HTTPS certificates', 'done', badge(localOnly ? 'HTTP on 127.0.0.1' : 'Provided by Cloudflare', 'neutral'),
      h('p', null, setup.tls.detail)));

    // 7. Review and install
    steps.push(step(7, setup.installed ? 'Installation' : 'Review and install', setup.installed ? 'done' : 'todo',
      badge(setup.installed ? 'Installed' : 'Not installed', setup.installed ? 'ok' : 'neutral'),
      renderInstall(setup, dockerOk)));

    // 8. Services
    const svc = s.services;
    steps.push(step(8, 'Services', svc.total > 0 ? 'done' : 'todo', badge(`${svc.enabled} enabled / ${svc.total} total`, svc.total > 0 ? 'ok' : 'neutral'),
      h('p', null, 'Add each app you want to publish: a name, its public hostname and where it runs. You can manage many apps through this one Traefik.'),
      svc.drift > 0 ? h('p', { class: 'hint warn' }, `${svc.drift} route file(s) differ from the service registry. Open Services to review.`) : null,
      h('div', { class: 'actions' }, h('button', {
        type: 'button', class: 'btn primary', disabled: !setup.installed,
        onclick: () => { selectTab('services'); openServiceForm(null); },
      }, 'Add a service'))));

    fill($('#setup-steps'), steps);
  }

  function renderConnectCloudflare(setup) {
    const cf = setup.cloudflare;
    const tokenOk = cf.tokenStored && cf.tokenReadable;
    const withAccess = state.tokenLinkAccess !== false;
    const link = h('a', {
      class: 'btn primary', href: withAccess ? cf.tokenLinkWithAccess : cf.tokenLink, target: '_blank', rel: 'noopener noreferrer', id: 'cf-create-token',
      onclick: () => { state.handoff = true; $('#cf-handoff').hidden = false; },
    }, 'Create Cloudflare API Token');
    const accessBox = h('input', { type: 'checkbox', id: 'cf-incl-access', checked: withAccess });
    accessBox.addEventListener('change', () => { state.tokenLinkAccess = accessBox.checked; link.href = accessBox.checked ? cf.tokenLinkWithAccess : cf.tokenLink; });

    const tokenInput = h('input', { id: 'wiz-token', type: 'password', autocomplete: 'off', spellcheck: 'false', placeholder: 'Paste the API token', 'aria-describedby': 'wiz-token-hint' });
    const form = h('form', { class: 'inline-form', autocomplete: 'off', id: 'wiz-token-form' },
      h('label', { for: 'wiz-token' }, tokenOk ? 'Replace the API token' : 'API token'), tokenInput,
      h('button', { type: 'submit', class: 'btn primary' }, 'Verify and save'));
    form.addEventListener('submit', (e) => { e.preventDefault(); saveToken(tokenInput, e.submitter || form.querySelector('button')); });

    return [
      h('p', null, 'This tool uses a Cloudflare API token, limited to the permissions below, to set up the tunnel and DNS for you. Every change is previewed and needs your confirmation.'),
      h('ul', { class: 'perm-list' }, arr(cf.permissions).map((p) => h('li', null, h('strong', null, p.label), p.optional ? ' (optional)' : '', h('span', { class: 'muted' }, ` - to ${p.purpose}`)))),
      h('label', { class: 'check' }, accessBox, h('span', null, 'Include the optional Access permission (lets this tool put a Cloudflare login in front of your apps)')),
      h('div', { class: 'actions' }, link,
        !tokenOk && setup.deployment.mode !== 'local' && !setup.installed ? h('button', { type: 'button', class: 'btn', onclick: (e) => skipCloudflare(e.currentTarget) }, 'Skip: install local only, without Cloudflare') : null),
      h('p', { class: 'hint' }, 'The link opens Cloudflare\'s token page with these permissions filled in. Review them there. Under ',
        h('strong', null, 'Account Resources'), ' and ', h('strong', null, 'Zone Resources'),
        ', choose only the account and the domains this PC should manage, then select Continue to summary and Create Token. If Cloudflare\'s page does not list "Cloudflare Tunnel", add Account > Cloudflare Tunnel > Edit yourself.'),
      h('div', { class: 'card callout info', id: 'cf-handoff', hidden: tokenOk && !state.handoff },
        h('p', null, h('strong', null, HANDOFF_TEXT)),
        h('p', null, 'Paste the token below. Once it is copied, you can close the Cloudflare tab. The token is encrypted for your Windows account (DPAPI) on this PC and never shown again, put in a link, or stored in the browser.')),
      tokenOk ? h('div', { class: 'status-line' }, badge('Token stored (encrypted)', 'ok'), h('span', { class: 'muted' }, `Saved ${cf.tokenSavedAt}`)) : null,
      cf.tokenStored && !cf.tokenReadable ? h('p', { class: 'hint warn' }, 'The stored token cannot be decrypted by this Windows account. Paste it again or create a new one.') : null,
      form,
      h('p', { class: 'hint', id: 'wiz-token-hint' }, 'The token is checked with Cloudflare before it is saved. Nothing in your Cloudflare account is changed.'),
      tokenOk ? h('div', { class: 'actions' },
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, loadDiscovery) }, 'Check permissions again'),
        h('button', { type: 'button', class: 'btn danger-outline', onclick: (e) => removeToken(e.currentTarget) }, 'Remove stored token')) : null,
      tokenOk ? renderDiscovery(state.discovery, cf) : null,
    ];
  }

  function permBadge(p) {
    const map = { ok: ['OK', 'ok'], partial: ['Partly', 'warn'], missing: [p.optional ? 'Not granted' : 'Missing', p.optional ? 'neutral' : 'err'], unknown: ['Unknown', 'neutral'] };
    const [text, kind] = map[p.state] || ['?', 'neutral'];
    return badge(text, kind);
  }

  function renderDiscovery(disc, cf) {
    if (!disc) return h('p', { class: 'muted' }, 'Checking what the token can do…');
    const zones = arr(disc.zones);
    const accounts = arr(disc.accounts);
    const boxes = zones.map((z) => h('input', { type: 'checkbox', value: z.id, checked: z.allowed || (zones.length === 1) }));
    return h('div', { class: 'plan-section' },
      h('h3', null, 'What this token can do'),
      h('ul', { class: 'issue-list' }, arr(disc.permissions).map((p) => h('li', null, permBadge(p), ' ', h('strong', null, p.label), h('p', { class: 'hint' }, p.message)))),
      accounts.length > 1 ? h('div', { class: 'inline-form' },
        h('label', { for: 'wiz-account' }, 'Account'),
        h('select', { id: 'wiz-account', onchange: (e) => withBusy(null, async () => { await api('POST', '/api/cloudflare/select', { accountId: e.target.value }); await loadDiscovery(); await refreshStatus(); }) },
          h('option', { value: '' }, 'Choose an account…'), accounts.map((a) => h('option', { value: a.id, selected: a.id === disc.accountId }, a.name)))) :
        accounts.length === 1 ? h('p', null, 'Account: ', h('strong', null, accounts[0].name)) : null,
      h('h3', null, 'Allowed domains'),
      zones.length === 0 ? h('p', { class: 'hint warn' }, 'The token cannot see any domain. Edit the token in Cloudflare (Zone > Zone > Read and Zone > DNS > Edit for your domain) or create a new one.') :
        [h('p', { class: 'muted' }, zones.length === 1 ? 'The token can manage one domain; it was selected automatically.' : 'Choose the domains this instance may publish services under.'),
          h('fieldset', { class: 'chips' }, h('legend', { class: 'sr-only' }, 'Allowed domains'),
            zones.map((z, i) => h('label', { class: 'check' }, boxes[i], h('span', null, z.name, ' ', z.dns === 'missing' ? badge('no DNS access', 'warn') : null)))),
          h('div', { class: 'actions' }, h('button', {
            type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
              const ids = boxes.filter((b) => b.checked).map((b) => b.value);
              await api('POST', '/api/cloudflare/domains', { zoneIds: ids });
              toast(ids.length ? `Allowed domains saved (${ids.length}).` : 'No domain is allowed now.');
              await loadDiscovery();
              await refreshStatus();
            }),
          }, 'Save allowed domains'))],
      arr(cf.domains).length === 0 && zones.length > 1 ? h('p', { class: 'hint warn' }, 'No domain is allowed yet.') : null);
  }

  async function saveToken(input, button) {
    const token = input.value.trim();
    if (!token) { toast('Paste the API token first.', true); return; }
    const send = async (confirmReplace) => {
      try {
        return await api('POST', '/api/cloudflare/token', { token, confirmReplace });
      } catch (err) {
        if (err.status === 409 && err.data.needsConfirm === 'replace') {
          const ok = await confirmDialog({ title: 'Replace the stored token?', body: 'A Cloudflare API token is already stored. The new token replaces it after Cloudflare verifies it. Revoke the old token in Cloudflare if you no longer need it.', okText: 'Replace' });
          return ok ? send(true) : null;
        }
        throw err;
      }
    };
    await withBusy(button, async () => {
      const r = await send(false);
      input.value = '';
      if (!r) return;
      state.discovery = r;
      state.handoff = false;
      toast(`Token verified and saved: ${arr(r.zones).length} domain(s) visible.`);
      await refreshStatus();
    });
  }

  async function removeToken(button) {
    const ok = await confirmDialog({ title: 'Remove the stored API token?', body: 'Automation stops working until you save a token again. Nothing in Cloudflare is changed. Revoke or delete the token in the Cloudflare dashboard if you no longer need it.', okText: 'Remove', danger: true });
    if (!ok) return;
    await withBusy(button, async () => {
      await api('POST', '/api/cloudflare/token/delete', { confirm: true });
      state.discovery = null;
      toast('Stored token removed.');
      await refreshStatus();
    });
  }

  async function loadDiscovery() {
    state.discovery = await api('GET', '/api/cloudflare/discovery');
    renderSetup(state.status);
  }

  async function skipCloudflare(button) {
    await withBusy(button, async () => {
      state.setup = await api('POST', '/api/setup/deployment', { mode: 'local' });
      state.installPlan = null;
      toast('Local-only installation chosen. You can connect Cloudflare later.');
      renderSetup(state.status);
    });
  }

  const SETTING_FIELDS = [
    ['STACK_NAME', 'Instance name', 'Prefix of the container names and the Compose project.'],
    ['TRAEFIK_HTTP_PORT', 'Traefik HTTP port (127.0.0.1)', ''],
    ['TRAEFIK_DASHBOARD_PORT', 'Dashboard port (127.0.0.1)', ''],
    ['PROXY_NETWORK', 'Shared Docker network', 'App containers join it so Traefik can reach them by name.'],
    ['TUNNEL_SUBNET', 'Tunnel subnet', 'Private network between cloudflared and Traefik.'],
    ['TUNNEL_IP_RANGE', 'Tunnel IP range', ''],
    ['CLOUDFLARED_IP', 'cloudflared address', ''],
  ];

  function renderConflicts(list) {
    const items = arr(list).filter((c) => c.Level !== 'info');
    if (!items.length) return h('p', { class: 'hint' }, 'No conflicts with containers, ports or networks on this PC.');
    return h('ul', { class: 'issue-list' }, items.map((c) => h('li', { class: c.Level === 'error' ? 'err' : 'warn' }, badge(c.Level === 'error' ? 'Conflict' : 'Note', c.Level === 'error' ? 'err' : 'warn'), ' ', c.Message)));
  }

  function renderInstanceSettings(setup) {
    const editable = !setup.installed;
    const pathInput = h('input', { id: 'wiz-path', value: setup.installPath, spellcheck: 'false', autocomplete: 'off', disabled: !setup.canChangePath });
    const inputs = {};
    const fields = SETTING_FIELDS.map(([key, label, hint]) => {
      inputs[key] = h('input', { id: `wiz-${key}`, value: setup.settings[key], spellcheck: 'false', autocomplete: 'off', disabled: !editable });
      return h('div', { class: 'field' }, h('label', { for: `wiz-${key}` }, label), inputs[key], hint ? h('p', { class: 'hint' }, hint) : null);
    });
    const read = () => { const o = {}; for (const [k] of SETTING_FIELDS) o[k] = inputs[k].value.trim(); return o; };
    const conflictsBox = h('div', { id: 'wiz-conflicts' }, state.conflicts ? renderConflicts(state.conflicts) : null);
    return [
      h('p', null, 'The install folder holds this instance\'s settings (.env), configuration, secrets, backups and logs. The program itself runs from ',
        h('code', null, setup.sourcePath), '.'),
      h('div', { class: 'inline-form' },
        h('label', { for: 'wiz-path' }, 'Install folder'), pathInput,
        editable ? h('button', {
          type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
            state.setup = await api('POST', '/api/setup/path', { path: pathInput.value.trim() });
            state.installPlan = null; state.conflicts = null;
            toast(`Install folder: ${state.setup.installPath}`);
            await refreshStatus();
          }),
        }, 'Use this folder') : null),
      editable ? null : h('p', { class: 'hint' }, 'This instance is installed; its settings are shown read-only. Edit .env in the install folder by hand to change them.'),
      h('p', { class: 'muted' }, 'Each instance needs its own name, ports, network and tunnel subnet so it cannot interfere with other stacks on this PC (including other Traefik or cloudflared containers).'),
      h('div', { class: 'grid' }, fields),
      editable ? h('div', { class: 'actions' },
        h('button', {
          type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
            const r = await api('POST', '/api/setup/suggest', {});
            for (const [k] of SETTING_FIELDS) inputs[k].value = r.settings[k];
            state.conflicts = r.conflicts;
            fill(conflictsBox, renderConflicts(r.conflicts));
            toast('Suggested free values filled in. Save them to use them.');
          }),
        }, 'Suggest free values'),
        h('button', {
          type: 'button', class: 'btn primary', onclick: (e) => withBusy(e.currentTarget, async () => {
            const r = await api('POST', '/api/setup/settings', { settings: read() });
            state.conflicts = r.conflicts; state.installPlan = null;
            toast('Instance settings saved.');
            await refreshStatus();
          }),
        }, 'Save settings'),
        h('button', {
          type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
            const r = await api('POST', '/api/setup/check', {});
            state.conflicts = r.conflicts;
            fill(conflictsBox, renderConflicts(r.conflicts));
          }),
        }, 'Check saved settings')) : null,
      conflictsBox,
    ];
  }

  function renderDeployment(setup) {
    const dep = setup.deployment;
    const cf = setup.cloudflare;
    const tokenOk = cf.tokenStored && cf.tokenReadable;
    if (setup.installed) return h('p', null, dep.mode === 'tunnel' ? `Cloudflare Tunnel${cf.tunnelName ? ` (${cf.tunnelName})` : ''}. Manage the tunnel on the Cloudflare page.` : 'Local only. To publish apps later, set up a tunnel on the Cloudflare page.');
    const current = state.depMode || dep.mode || (tokenOk ? 'tunnel' : 'local');
    const radios = arr(setup.modes).map((m) => h('label', { class: 'radio' },
      h('input', { type: 'radio', name: 'wiz-mode', value: m.id, checked: m.id === current, disabled: !m.supported || (m.id === 'tunnel' && !tokenOk), onchange: () => { state.depMode = m.id; renderSetup(state.status); } }),
      h('span', null, h('strong', null, m.title), m.supported ? '' : ' (not supported in this version)', ': ', m.detail,
        m.id === 'tunnel' && !tokenOk ? h('span', { class: 'hint warn' }, ' Connect Cloudflare first (step 1).') : null)));
    const tunnels = arr(state.discovery && state.discovery.tunnels).filter((t) => t.remotelyManaged);
    const choice = state.tunnelChoice || dep.tunnelChoice || (tunnels.length ? 'existing' : 'new');
    const sel = h('select', { id: 'wiz-tunnel' }, h('option', { value: '' }, tunnels.length ? 'Choose a tunnel…' : 'No dashboard-managed tunnels found'),
      tunnels.map((t) => h('option', { value: t.id, selected: t.id === dep.tunnelId }, `${t.name} (${t.status || 'inactive'}, ${t.connections} connection${t.connections === 1 ? '' : 's'})`)));
    const nameInput = h('input', { id: 'wiz-tunnel-name', value: dep.newTunnelName || `${setup.settings.STACK_NAME}`, spellcheck: 'false', autocomplete: 'off' });
    const tunnelBlock = current === 'tunnel' && tokenOk ? h('fieldset', { class: 'exposure' }, h('legend', null, 'Tunnel for this instance'),
      h('label', { class: 'radio' }, h('input', { type: 'radio', name: 'wiz-tchoice', value: 'new', checked: choice === 'new', onchange: () => { state.tunnelChoice = 'new'; } }),
        h('span', null, h('strong', null, 'Create a new tunnel'), ' (recommended: one tunnel per instance). It is created only when you confirm the installation.')),
      h('div', { class: 'inline-form' }, h('label', { for: 'wiz-tunnel-name' }, 'New tunnel name'), nameInput),
      h('label', { class: 'radio' }, h('input', { type: 'radio', name: 'wiz-tchoice', value: 'existing', checked: choice === 'existing', onchange: () => { state.tunnelChoice = 'existing'; } }),
        h('span', null, h('strong', null, 'Use an existing tunnel'), ' that no other connector on this PC serves.')),
      h('div', { class: 'inline-form' }, h('label', { for: 'wiz-tunnel' }, 'Tunnel'), sel)) : null;
    return [
      h('fieldset', { class: 'exposure' }, h('legend', null, 'How will apps be reached?'), radios),
      tunnelBlock,
      h('div', { class: 'actions' }, h('button', {
        type: 'button', class: 'btn primary', onclick: (e) => withBusy(e.currentTarget, async () => {
          const body = { mode: current };
          if (current === 'tunnel') {
            const c = $('input[name="wiz-tchoice"]:checked');
            body.tunnelChoice = c ? c.value : '';
            body.tunnelId = sel.value;
            body.newTunnelName = nameInput.value.trim();
          }
          state.setup = await api('POST', '/api/setup/deployment', body);
          state.installPlan = null;
          toast('Deployment method saved.');
          renderSetup(state.status);
        }),
      }, 'Save deployment method')),
    ];
  }

  function renderInstall(setup, dockerOk) {
    if (setup.installed) {
      const st = state.status.stack;
      const containers = arr(st.Containers);
      return [
        h('p', null, 'Installed in ', h('code', null, setup.installPath), setup.installedAt ? ` on ${setup.installedAt}` : '', '.'),
        h('ul', { class: 'checks' },
          containers.filter((c) => c.Role !== 'cloudflared' || setup.deployment.mode === 'tunnel').map((c) => check(c.State === 'running', `${c.Name}: ${c.State}${c.Health ? ` (${c.Health})` : ''}`)),
          check(st.TraefikApi, st.TraefikApi ? `Traefik API answering (v${st.TraefikVersion})` : 'Traefik API answering')),
      ];
    }
    const plan = state.installPlan;
    const out = h('pre', { class: 'output', hidden: !plan || !arr(plan.dryRun).length, tabindex: '0' }, plan ? arr(plan.dryRun).join('\n') : '');
    const box = h('input', { type: 'checkbox', id: 'wiz-install-ok' });
    const go = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Install…');
    box.addEventListener('change', () => { go.disabled = !(box.checked && plan && plan.canInstall); });
    go.addEventListener('click', () => runInstall(go));
    const kind = { local: ['This PC', 'neutral'], docker: ['Docker', 'info'], cloudflare: ['Cloudflare', 'warn'] };
    return [
      h('p', null, 'The preview lists every step and runs the installer in dry-run mode. Docker and Cloudflare are only changed after you confirm.'),
      h('div', { class: 'actions' }, h('button', {
        type: 'button', class: 'btn', disabled: !setup.canInstall, onclick: (e) => withBusy(e.currentTarget, async () => {
          state.installPlan = await api('POST', '/api/setup/preview', {});
          renderSetup(state.status);
        }),
      }, plan ? 'Preview again' : 'Preview installation')),
      plan ? h('div', { class: 'plan-section' },
        h('h3', null, 'Steps'),
        h('ol', { class: 'action-list' }, arr(plan.steps).map((s) => h('li', null, badge((kind[s.kind] || ['', 'neutral'])[0], (kind[s.kind] || ['', 'neutral'])[1]), ' ', s.text))),
        arr(plan.blockers).length ? [h('h3', null, 'Blocking problems'), h('ul', { class: 'issue-list' }, arr(plan.blockers).map((b) => h('li', { class: 'err' }, b)))] : null,
        arr(plan.warnings).length ? [h('h3', null, 'Notes'), h('ul', { class: 'issue-list' }, arr(plan.warnings).map((w) => h('li', { class: 'warn' }, w)))] : null,
        h('h3', null, 'Installer dry run'), out,
        plan.canInstall ? h('div', { class: 'actions' }, h('label', { class: 'check' }, box, h('span', null, 'I reviewed these steps')), go) : null) : null,
      !dockerOk ? h('p', { class: 'hint warn' }, 'Docker Desktop must be running to install.') : null,
      state.installResult ? h('div', { class: 'plan-section' }, h('h3', null, state.installResult.ok ? 'Installation finished' : 'Installation failed'),
        h('ul', { class: 'result-list' }, arr(state.installResult.steps).map((s) => h('li', null, badge(s.status, s.status === 'Done' ? 'ok' : 'err'), ' ', s.name, s.message ? h('p', { class: 'hint' }, s.message) : null))),
        h('pre', { class: 'output', tabindex: '0' }, arr(state.installResult.lines).join('\n'))) : null,
    ];
  }

  async function runInstall(button) {
    const plan = state.installPlan;
    const ok = await confirmDialog({
      title: 'Install this instance',
      body: [h('p', null, 'This performs the previewed steps:'), h('ol', null, arr(plan.steps).map((s) => h('li', null, s.text))),
        'Only this instance\'s containers are started. Existing containers, networks and Cloudflare resources are not modified.'],
      okText: 'Install',
      checkbox: plan.steps.some((s) => s.kind === 'cloudflare') ? 'Create the listed resource in my Cloudflare account' : null,
    });
    if (!ok) return;
    await withBusy(button, async () => {
      try {
        state.installResult = await api('POST', '/api/setup/install', { confirm: true, planKey: plan.planKey });
      } catch (err) {
        if (err.status === 409) state.installPlan = null;
        throw err;
      }
      state.installPlan = null;
      toast(state.installResult.ok ? 'Installed and started.' : 'The installation reported an error; see the output.', !state.installResult.ok);
      await refreshStatus();
    });
  }

  function showOutput(pre, lines) {
    pre.hidden = false;
    pre.textContent = arr(lines).join('\n') || '(no output)';
  }

  // --- Services ---------------------------------------------------------------------------------------
  async function loadServices() {
    if (!state.status) await refreshStatus();
    const alerts = clear($('#services-alerts'));
    if (!state.status.instance.installed) {
      alerts.append(h('div', { class: 'card callout warn' }, h('p', null, 'The stack is not installed yet. Finish step 2 on the Setup page first.')));
      $('#btn-add-service').disabled = true;
      return;
    }
    $('#btn-add-service').disabled = false;
    const data = await api('GET', '/api/services');
    state.services = arr(data.services);
    state.middlewares = arr(data.middlewares);
    if (!data.traefikUp) alerts.append(h('div', { class: 'card callout warn' }, h('p', null, 'Traefik is not answering, so route status is unknown. Changes are still validated and saved; Traefik loads them when it runs.')));
    const drift = arr(data.drift);
    if (drift.length) {
      alerts.append(h('div', { class: 'card callout warn' },
        h('p', null, `${drift.length} generated route file(s) do not match the service registry (${drift.map((d) => `${d.action} ${d.file}`).join(', ')}). This happens after hand edits or a failed change.`),
        h('button', { type: 'button', class: 'btn', onclick: () => { toast('Use services.ps1 apply or re-save a service to regenerate routes.'); } }, 'How to fix')));
    }
    renderServices();
  }

  function exposureBadge(x) {
    if (x === 'access') return badge('Cloudflare Access', 'ok');
    if (x === 'public') return badge('Public', 'warn');
    return badge('Local only', 'neutral');
  }

  function routerBadge(v, enabled) {
    if (!enabled) return badge('Disabled', 'neutral');
    if (v === 'enabled') return badge('Loaded', 'ok');
    if (v === 'unknown') return badge('Unknown', 'neutral');
    return badge(v, 'err');
  }

  function renderServices() {
    const tbody = clear($('#services-table tbody'));
    $('#services-empty').hidden = state.services.length > 0;
    for (const v of state.services) {
      const s = v.service;
      const hosts = arr(s.hostnames).map((hn) => h('div', null,
        s.cloudflare.publish ? h('a', { href: `https://${hn}${s.pathPrefix || ''}`, target: '_blank', rel: 'noopener noreferrer' }, hn + (s.pathPrefix || '')) : hn + (s.pathPrefix || '')));
      const typeLabel = { docker: 'Container', host: 'This PC', lan: 'Network device' }[s.target.type] || s.target.type;
      tbody.append(h('tr', null,
        h('td', null, h('strong', null, s.name), s.description ? h('div', { class: 'sub' }, s.description) : null),
        h('td', null, hosts),
        h('td', null, h('span', { class: 'mono' }, v.url), h('div', { class: 'sub' }, typeLabel)),
        h('td', null, exposureBadge(v.exposure)),
        h('td', null, routerBadge(v.router, s.enabled)),
        h('td', { class: 'actions-cell' },
          h('button', { type: 'button', class: 'btn small', onclick: () => openServiceForm(v), 'aria-label': `Edit ${s.name}` }, 'Edit'),
          h('button', {
            type: 'button', class: 'btn small', 'aria-label': `${s.enabled ? 'Disable' : 'Enable'} ${s.name}`,
            onclick: () => startPlan({ op: s.enabled ? 'disable' : 'enable', name: s.name, cloudflare: { automate: cfReady(), cleanup: false } }),
          }, s.enabled ? 'Disable' : 'Enable'),
          h('button', {
            type: 'button', class: 'btn small danger-outline', 'aria-label': `Remove ${s.name}`,
            onclick: () => startPlan({ op: 'remove', name: s.name, cloudflare: { automate: cfReady(), cleanup: true } }),
          }, 'Remove'))));
    }
  }

  async function loadZones() {
    state.zones = [];
    if (state.status && state.status.cloudflare.tokenStored && state.status.cloudflare.accountId) {
      try {
        const z = await api('GET', '/api/cloudflare/zones');
        state.zones = arr(z.zones).filter((x) => x.status !== 'deleted');
      } catch (e) {
        toast(`Could not load domains from Cloudflare: ${e.message}`, true);
      }
    }
  }

  function setDomainOptions(selected) {
    const sel = $('#f-domain');
    const text = $('#f-domain-text');
    clear(sel);
    if (state.zones.length === 0) {
      sel.hidden = true;
      text.hidden = false;
      text.value = selected || '';
      return;
    }
    sel.hidden = false;
    for (const z of state.zones) sel.append(h('option', { value: z.name }, z.name));
    sel.append(h('option', { value: '__other' }, 'Other domain…'));
    const known = state.zones.some((z) => z.name === selected);
    sel.value = selected ? (known ? selected : '__other') : state.zones[0].name;
    text.hidden = sel.value !== '__other';
    text.value = known ? '' : selected || '';
  }

  function splitHostname(hn) {
    const zone = state.zones.map((z) => z.name).filter((z) => hn === z || hn.endsWith(`.${z}`)).sort((a, b) => b.length - a.length)[0];
    if (zone) return { sub: hn === zone ? '' : hn.slice(0, hn.length - zone.length - 1), domain: zone };
    const parts = hn.split('.');
    if (parts.length <= 2) return { sub: '', domain: hn };
    return { sub: parts[0], domain: parts.slice(1).join('.') };
  }

  function currentDomain() {
    const sel = $('#f-domain');
    if (!sel.hidden && sel.value !== '__other') return sel.value;
    return $('#f-domain-text').value.trim().toLowerCase();
  }

  function detectTarget(hostValue, type) {
    const v = hostValue.trim().toLowerCase();
    const net = state.status ? state.status.instance.proxyNetwork : 'proxy';
    let t = type;
    if (t === 'auto') {
      if (/^(localhost|127\.\d+\.\d+\.\d+|host\.docker\.internal|::1)$/.test(v)) t = 'host';
      else if (/^\d+\.\d+\.\d+\.\d+$/.test(v) || v.includes('.')) t = 'lan';
      else t = 'docker';
    }
    if (!v) return { text: 'An IP address (10.10.0.11), a DNS name, a Docker container name, or localhost for an app on this PC.', warn: false };
    if (t === 'host') return { text: 'This Windows PC: Traefik connects to host.docker.internal. The app must listen on all interfaces (0.0.0.0), not only 127.0.0.1, and Windows Firewall must allow the port.', warn: false };
    if (t === 'docker') return { text: `Docker container "${v}": it must be attached to the "${net}" network. Use the port the app listens on inside the container.`, warn: false };
    if (/^\d+\.\d+\.\d+\.\d+$/.test(v) && !/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(v)) {
      return { text: `${v} is not a private network address. Make sure this is the device you want to publish.`, warn: true };
    }
    return { text: 'A device on your network. Traefik connects to it from inside Docker Desktop, so the device must be reachable from this PC.', warn: false };
  }

  function updateTargetHint() {
    const r = detectTarget($('#f-target-host').value, $('#f-target-type').value);
    const hint = $('#f-target-hint');
    hint.textContent = r.text;
    hint.className = r.warn ? 'hint warn' : 'hint';
  }

  function updateExposureUi() {
    const exposure = $('input[name="exposure"]:checked').value;
    const ready = cfReady();
    const automate = $('#f-automate');
    $('#f-automate-wrap').hidden = exposure === 'local';
    automate.disabled = !ready;
    if (!ready) automate.checked = false;
    $('#f-automate-hint').textContent = exposure === 'local' ? '' : ready
      ? `Uses tunnel "${state.status.cloudflare.tunnelName}". Existing DNS records are never replaced without a separate confirmation.`
      : 'Cloudflare is not connected (see the Cloudflare page), so you will get step-by-step instructions for the Cloudflare dashboard instead.';
    $('#f-emails-field').hidden = !(exposure === 'access' && automate.checked);
  }

  async function openServiceForm(view) {
    const form = $('#service-form');
    state.editing = view ? view.service.name : null;
    $('#service-form-title').textContent = view ? `Edit ${view.service.name}` : 'Add a service';
    $('#service-form-error').textContent = '';
    await loadZones();
    const s = view ? view.service : null;
    $('#f-name').value = s ? s.name : '';
    $('#f-name').disabled = !!s;
    const hosts = s ? arr(s.hostnames) : [];
    const first = hosts.length ? splitHostname(hosts[0]) : { sub: '', domain: '' };
    $('#f-sub').value = first.sub;
    setDomainOptions(first.domain);
    $('#f-extra-hosts').value = hosts.slice(1).join(', ');
    $('#f-target-host').value = s ? s.target.host : '';
    $('#f-port').value = s ? s.target.port : '';
    $('#f-protocol').value = s ? s.target.protocol : 'http';
    $('#f-target-type').value = s ? s.target.type : 'auto';
    $('#f-path').value = s ? s.pathPrefix : '';
    $('#f-strip').checked = s ? !!s.stripPrefix : false;
    $('#f-tls-skip').checked = s ? !!s.target.tlsSkipVerify : false;
    $('#f-description').value = s ? s.description : '';
    $('#f-enabled').checked = s ? !!s.enabled : true;
    const exposure = s ? (!s.cloudflare.publish ? 'local' : s.cloudflare.access ? 'access' : 'public') : 'access';
    $(`input[name="exposure"][value="${exposure}"]`).checked = true;
    $('#f-automate').checked = cfReady();
    const selectedMw = s ? arr(s.middlewares) : ['default-headers@file'];
    const allMw = Array.from(new Set([...state.middlewares, ...selectedMw]));
    fill($('#f-middlewares'), allMw.map((m) => h('label', { class: 'check' },
      h('input', { type: 'checkbox', value: m, checked: selectedMw.includes(m) }), h('span', { class: 'mono' }, m))));
    updateTargetHint();
    updateExposureUi();
    form.hidden = false;
    form.scrollIntoView({ behavior: 'smooth', block: 'start' });
    (s ? $('#f-sub') : $('#f-name')).focus();
  }

  function closeServiceForm() {
    $('#service-form').hidden = true;
    state.editing = null;
  }

  function readServiceForm() {
    const errors = [];
    const name = $('#f-name').value.trim().toLowerCase();
    const domain = currentDomain();
    const sub = $('#f-sub').value.trim().toLowerCase().replace(/\.$/, '');
    const hostnames = [];
    if (domain) hostnames.push(sub ? `${sub}.${domain}` : domain);
    for (const x of $('#f-extra-hosts').value.split(/[\s,]+/)) { if (x.trim()) hostnames.push(x.trim().toLowerCase()); }
    const port = parseInt($('#f-port').value, 10);
    const targetHost = $('#f-target-host').value.trim();
    if (!/^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/.test(name)) errors.push('Enter a service name (lowercase letters, digits, dashes).');
    if (!domain) errors.push('Choose or enter a domain.');
    if (!targetHost) errors.push('Enter the backend IP address or hostname.');
    if (!(port >= 1 && port <= 65535)) errors.push('Enter a port from 1 to 65535.');
    const exposure = $('input[name="exposure"]:checked').value;
    const automate = exposure !== 'local' && $('#f-automate').checked;
    const emails = $('#f-emails').value.split(/[\s,;]+/).map((e) => e.trim()).filter(Boolean);
    const body = {
      op: state.editing ? 'update' : 'add',
      name: state.editing || name,
      service: {
        name,
        description: $('#f-description').value.trim(),
        enabled: $('#f-enabled').checked,
        hostnames,
        pathPrefix: $('#f-path').value.trim(),
        stripPrefix: $('#f-strip').checked,
        middlewares: $$('#f-middlewares input:checked').map((i) => i.value),
        target: { type: $('#f-target-type').value, host: targetHost, port, protocol: $('#f-protocol').value, tlsSkipVerify: $('#f-tls-skip').checked },
        cloudflare: { publish: exposure !== 'local', access: exposure === 'access' },
      },
      cloudflare: { automate, accessEmails: emails, cleanup: true },
    };
    return { errors, body };
  }

  // --- Plan / apply ---------------------------------------------------------------------------------
  async function startPlan(body, button) {
    state.planBody = body;
    return withBusy(button, async () => {
      const plan = await api('POST', '/api/services/plan', body);
      state.plan = plan;
      renderPlan(plan, body);
      openDialog($('#plan-dialog'));
    });
  }

  function diffBlock(lines) {
    return h('div', { class: 'diff', role: 'region', 'aria-label': 'Line changes', tabindex: '0' },
      arr(lines).map((l) => h('div', { class: l.startsWith('+ ') ? 'add' : l.startsWith('- ') ? 'del' : '' }, l)));
  }

  const kindBadge = {
    create: () => badge('Create', 'info'),
    update: () => badge('Overwrite', 'warn'),
    delete: () => badge('Delete', 'err'),
    none: () => badge('No change', 'neutral'),
    blocked: () => badge('Blocked', 'err'),
  };

  function renderPlan(plan, body) {
    $('#plan-title').textContent = plan.summary;
    const content = clear($('#plan-content'));
    const notes = arr(plan.notes);
    if (notes.length) content.append(h('div', { class: 'plan-section' }, h('ul', { class: 'issue-list' }, notes.map((n) => h('li', { class: 'warn' }, n)))));

    const issues = arr(plan.traefik.issues);
    if (issues.length) {
      content.append(h('div', { class: 'plan-section' }, h('h3', null, 'Validation'),
        h('ul', { class: 'issue-list' }, issues.map((i) => h('li', { class: i.Level === 'Error' ? 'err' : 'warn' },
          badge(i.Level, i.Level === 'Error' ? 'err' : 'warn'), ' ', i.Service ? `${i.Service}: ` : '', i.Message)))));
    }

    const changes = arr(plan.traefik.changes);
    const t = h('div', { class: 'plan-section' }, h('h3', null, 'Traefik'));
    if (changes.length === 0 && !plan.traefik.registryChanged) t.append(h('p', { class: 'muted' }, 'No Traefik changes.'));
    for (const c of changes) {
      const b = c.action === 'add' ? badge('Add', 'info') : c.action === 'remove' ? badge('Remove', 'err') : badge('Update', 'warn');
      t.append(h('div', { class: 'file-head' }, b, h('span', { class: 'mono' }, c.file)));
      t.append(diffBlock(c.diff));
    }
    if (plan.traefik.registryChanged) t.append(h('p', { class: 'muted' }, 'config\\services.json is updated. The current state is backed up first and can be restored on the Backups page.'));
    content.append(t);

    const cf = plan.cloudflare;
    const c = h('div', { class: 'plan-section' }, h('h3', null, 'Cloudflare'));
    for (const n of arr(cf.notes)) c.append(h('p', { class: 'muted' }, n));
    for (const e of arr(cf.errors)) c.append(h('p', { class: 'form-error' }, e));
    const actions = arr(cf.actions);
    if (actions.length) {
      c.append(h('ul', { class: 'action-list' }, actions.map((a) => {
        const li = h('li', { class: a.overwrite ? 'overwrite' : a.kind === 'blocked' ? 'blocked' : '' },
          (kindBadge[a.kind] || kindBadge.none)(), ' ', badge(a.step === 'dns' ? 'DNS' : a.step === 'tunnel' ? 'Tunnel route' : 'Access', 'neutral'), ' ', a.summary,
          a.detail ? h('p', { class: 'detail' }, a.detail) : null);
        if (a.overwrite) {
          li.append(h('label', { class: 'check' }, h('input', { type: 'checkbox', class: 'overwrite-confirm', 'data-id': a.id }),
            h('span', null, h('strong', null, 'Yes, overwrite this existing Cloudflare resource.'))));
        }
        return li;
      })));
    } else if (cf.connected && !arr(cf.errors).length) {
      c.append(h('p', { class: 'muted' }, 'No Cloudflare changes.'));
    }
    const manual = arr(cf.manualSteps);
    if (manual.length) {
      c.append(h('p', null, h('strong', null, 'Do this in the Cloudflare dashboard'), ' (', h('a', { href: 'https://one.dash.cloudflare.com/', target: '_blank', rel: 'noopener noreferrer' }, 'one.dash.cloudflare.com'), '):'));
      c.append(h('ol', null, manual.map((m) => h('li', null, m))));
    }
    if ((body.op === 'remove' || body.op === 'update') && body.cloudflare && body.cloudflare.automate) {
      const box = h('input', { type: 'checkbox', checked: body.cloudflare.cleanup !== false });
      box.addEventListener('change', () => {
        startPlan({ ...body, cloudflare: { ...body.cloudflare, cleanup: box.checked } });
      });
      c.append(h('label', { class: 'check' }, box, h('span', null, 'Also remove Cloudflare DNS records, tunnel routes and Access applications (created by this tool) for hostnames this change stops using.')));
    }
    content.append(c);
    renderPlanFooter(plan);
  }

  function renderPlanFooter(plan) {
    const foot = clear($('#plan-foot'));
    const cancel = h('button', { type: 'button', class: 'btn', 'data-close': true }, plan.canApply ? 'Cancel' : 'Close');
    if (!plan.canApply) {
      foot.append(h('div', { class: 'grow' }, h('span', { class: 'muted' }, plan.hasWork ? 'Fix the problems above, then preview again.' : 'Nothing to change.')), cancel);
      return;
    }
    const reviewed = h('input', { type: 'checkbox', id: 'plan-reviewed' });
    const apply = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Apply changes');
    const sync = () => {
      const allOverwrites = $$('.overwrite-confirm', $('#plan-content')).every((b) => b.checked);
      apply.disabled = !(reviewed.checked && allOverwrites);
    };
    reviewed.addEventListener('change', sync);
    $$('.overwrite-confirm', $('#plan-content')).forEach((b) => b.addEventListener('change', sync));
    apply.addEventListener('click', () => applyPlan(apply));
    foot.append(h('label', { class: 'check grow' }, reviewed, h('span', null, 'I reviewed these changes')), cancel, apply);
  }

  async function applyPlan(button) {
    const overwrites = $$('.overwrite-confirm:checked', $('#plan-content')).map((b) => b.dataset.id);
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
    try {
      const r = await api('POST', '/api/services/apply', { planId: state.plan.planId, confirm: true, confirmOverwrites: overwrites });
      renderResult(r);
      closeServiceForm();
    } catch (e) {
      const content = $('#plan-content');
      content.prepend(h('div', { class: 'card callout err', role: 'alert' }, h('p', null, e.message),
        e.status === 409 ? h('button', { type: 'button', class: 'btn', onclick: () => startPlan(state.planBody) }, 'Preview again') : null));
      content.scrollTop = 0;
    } finally {
      button.removeAttribute('aria-busy');
    }
    loadServices().catch(() => {});
    refreshStatus().catch(() => {});
  }

  function renderResult(r) {
    $('#plan-title').textContent = r.ok ? 'Changes applied' : 'Some changes failed';
    const statusKind = { Done: 'ok', Unchanged: 'neutral', Warning: 'warn', Skipped: 'warn', 'Not run': 'neutral', Failed: 'err' };
    fill($('#plan-content'),
      h('ul', { class: 'result-list', 'aria-live': 'polite' }, arr(r.steps).map((s) => h('li', null,
        badge(s.status, statusKind[s.status] || 'neutral'), ' ', s.name, s.message ? h('p', { class: 'hint' }, s.message) : null))),
      arr(r.warnings).map((w) => h('p', { class: 'hint warn' }, w)),
      r.backup ? h('p', { class: 'muted' }, `The previous state was saved as backup ${r.backup}. Restore it on the Backups page if needed.`) : null,
      !r.ok ? h('p', null, 'Traefik changes that were applied stay in place. Fix the cause and preview again, or restore the backup.') : null);
    fill($('#plan-foot'), h('button', { type: 'button', class: 'btn primary', 'data-close': true }, 'Close'));
    $('#plan-foot .btn').focus();
  }

  // --- Cloudflare -------------------------------------------------------------------------------------
  async function loadCloudflare() {
    if (!state.status) await refreshStatus();
    const cf = await api('GET', '/api/cloudflare');
    state.cf = cf;
    renderCloudflare(cf);
  }

  function renderCloudflare(cf) {
    const t = cf.token;
    fill($('#cf-token-status'),
      t.Stored ? badge(t.Readable ? 'Token stored (encrypted)' : 'Stored token unreadable', t.Readable ? 'ok' : 'err') : badge('No token stored', 'neutral'),
      t.Stored ? h('span', { class: 'muted' }, `Saved ${t.SavedAt} by ${t.User}`) : null,
      cf.apiBase !== 'https://api.cloudflare.com/client/v4' ? badge(`API: ${cf.apiBase} (test mock)`, 'warn') : null);
    $('#btn-cf-token-remove').hidden = !t.Stored;
    if (state.setup) $('#cf-tab-create-token').href = state.setup.cloudflare.tokenLinkWithAccess;
    const disabled = !t.Stored;
    ['#cf-account', '#cf-tunnel', '#btn-cf-load', '#btn-cf-select', '#cf-tunnel-name'].forEach((s) => { $(s).disabled = disabled; });
    $('#cf-tunnel-form button').disabled = disabled || !cf.config.accountId;

    const acct = $('#cf-account');
    if (!acct.options.length || acct.dataset.loaded !== 'true') {
      fill(acct, cf.config.accountId ? h('option', { value: cf.config.accountId }, cf.config.accountName || cf.config.accountId) : h('option', { value: '' }, 'Load accounts…'));
    }
    const tun = $('#cf-tunnel');
    if (!tun.options.length || tun.dataset.loaded !== 'true') {
      fill(tun, cf.config.tunnelId ? h('option', { value: cf.config.tunnelId }, cf.config.tunnelName || cf.config.tunnelId) : h('option', { value: '' }, 'Load tunnels…'));
    }

    const c = cf.connector;
    fill($('#cf-connector-status'),
      cf.config.tunnelId ? badge(`Tunnel: ${cf.config.tunnelName}`, 'info') : badge('No tunnel selected', 'neutral'),
      badge(c.tokenFile ? 'Connector token installed' : 'No connector token', c.tokenFile ? 'ok' : 'neutral'),
      badge(c.running ? `${c.container} running` : `${c.container} not running`, c.running ? 'ok' : 'neutral'));
    $('#btn-cf-connector').disabled = !cf.config.tunnelId || !state.status.instance.installed;

    const managed = arr(cf.managed);
    fill($('#cf-managed'), managed.length === 0 ? h('p', { class: 'muted' }, 'Nothing yet.') :
      h('table', { class: 'table' }, h('thead', null, h('tr', null, h('th', { scope: 'col' }, 'Hostname'), h('th', { scope: 'col' }, 'Service'), h('th', { scope: 'col' }, 'DNS record'), h('th', { scope: 'col' }, 'Access app'))),
        h('tbody', null, managed.map((m) => h('tr', null, h('td', null, m.hostname), h('td', null, m.service),
          h('td', null, m.dns ? badge('Created', 'ok') : '—'), h('td', null, m.access ? badge('Created', 'ok') : '—'))))));
  }

  async function loadAccountsAndTunnels(button) {
    await withBusy(button, async () => {
      const a = await api('GET', '/api/cloudflare/accounts');
      const acct = $('#cf-account');
      const current = state.cf.config.accountId;
      fill(acct, arr(a.accounts).length ? null : h('option', { value: '' }, 'No accounts visible to this token'),
        arr(a.accounts).map((x) => h('option', { value: x.id, selected: x.id === current }, x.name)));
      acct.dataset.loaded = 'true';
      if (!current && acct.value) await api('POST', '/api/cloudflare/select', { accountId: acct.value });
      await loadTunnels();
    });
  }

  async function loadTunnels() {
    const tun = $('#cf-tunnel');
    const r = await api('GET', '/api/cloudflare/tunnels');
    const current = state.cf.config.tunnelId;
    fill(tun, h('option', { value: '' }, arr(r.tunnels).length ? 'Choose a tunnel…' : 'No tunnels yet: create one below'),
      arr(r.tunnels).map((t) => h('option', { value: t.id, selected: t.id === current, disabled: !t.remotelyManaged },
        `${t.name} (${t.status || 'inactive'}, ${t.connections} connection${t.connections === 1 ? '' : 's'})${t.remotelyManaged ? '' : ' - locally managed, not supported'}`)));
    tun.dataset.loaded = 'true';
  }

  // --- Backups ----------------------------------------------------------------------------------------
  async function loadBackups() {
    if (!state.status) await refreshStatus();
    if (!state.status.instance.installed) { $('#backups-empty').hidden = false; clear($('#backups-table tbody')); return; }
    const r = await api('GET', '/api/backups');
    const list = arr(r.backups);
    const tbody = clear($('#backups-table tbody'));
    $('#backups-empty').hidden = list.length > 0;
    for (const b of list) {
      tbody.append(h('tr', null,
        h('td', null, h('span', { class: 'mono' }, b.id), ' ', b.restored ? badge('Restored', 'neutral') : null, b.preRollback ? badge('Before a rollback', 'info') : null),
        h('td', null, b.createdAt),
        h('td', null, String(arr(b.files).length)),
        h('td', { class: 'actions-cell' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => previewRestore(b.id, e.currentTarget) }, 'Preview restore'))));
    }
  }

  async function previewRestore(id, button) {
    await withBusy(button, async () => {
      const p = await api('POST', '/api/backups/preview', { id });
      $('#plan-title').textContent = `Restore backup ${id}`;
      const changes = arr(p.changes);
      fill($('#plan-content'),
        h('p', { class: 'muted' }, p.note),
        changes.length === 0 ? h('p', null, 'The current configuration already matches this backup.') : null,
        changes.map((c) => [h('div', { class: 'file-head' }, badge(c.action, c.action === 'remove' ? 'err' : 'warn'), h('span', { class: 'mono' }, c.file)), diffBlock(c.diff)]));
      const foot = clear($('#plan-foot'));
      const box = h('input', { type: 'checkbox' });
      const go = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Restore');
      box.addEventListener('change', () => { go.disabled = !box.checked; });
      go.addEventListener('click', () => withBusy(go, async () => {
        const r = await api('POST', '/api/backups/restore', { id, confirm: true });
        $('#plan-dialog').close();
        toast(`Restored ${r.restored}. The previous state was saved as ${r.savedCurrentAs}.${r.warning ? ` ${r.warning}` : ''}`);
        await loadBackups();
      }));
      foot.append(h('label', { class: 'check grow' }, box, h('span', null, 'Restore this backup (the current state is saved first)')),
        h('button', { type: 'button', class: 'btn', 'data-close': true }, 'Cancel'), go);
      openDialog($('#plan-dialog'));
    });
  }

  // --- Event wiring -------------------------------------------------------------------------------------
  function wire() {
    $('#btn-add-service').addEventListener('click', () => openServiceForm(null));
    $('#btn-cancel-service').addEventListener('click', closeServiceForm);
    $('#f-target-host').addEventListener('input', updateTargetHint);
    $('#f-target-type').addEventListener('change', updateTargetHint);
    $('#f-automate').addEventListener('change', updateExposureUi);
    $$('input[name="exposure"]').forEach((r) => r.addEventListener('change', updateExposureUi));
    $('#f-domain').addEventListener('change', () => {
      const other = $('#f-domain').value === '__other';
      $('#f-domain-text').hidden = !other;
      if (other) $('#f-domain-text').focus();
    });
    $('#service-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const { errors, body } = readServiceForm();
      $('#service-form-error').textContent = errors.join(' ');
      if (errors.length) return;
      startPlan(body, e.submitter || $('#service-form button[type="submit"]'));
    });

    $('#cf-token-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const input = $('#cf-token');
      const token = input.value.trim();
      if (!token) { toast('Paste an API token first.', true); return; }
      const button = e.submitter || $('#cf-token-form button[type="submit"]');
      const send = async (confirmReplace) => {
        try {
          return await api('POST', '/api/cloudflare/token', { token, confirmReplace });
        } catch (err) {
          if (err.status === 409 && err.data.needsConfirm === 'replace') {
            const ok = await confirmDialog({ title: 'Replace the stored token?', body: 'A Cloudflare API token is already stored. The new token replaces it after Cloudflare verifies it.', okText: 'Replace' });
            return ok ? send(true) : null;
          }
          throw err;
        }
      };
      await withBusy(button, async () => {
        const r = await send(false);
        if (!r) return;
        input.value = '';
        toast(`Token verified and saved: ${arr(r.accounts).length} account(s), ${arr(r.zones).length} domain(s) visible.`);
        await refreshStatus();
        await loadCloudflare();
      });
    });
    $('#btn-cf-token-remove').addEventListener('click', async (e) => {
      const ok = await confirmDialog({ title: 'Remove the stored API token?', body: 'Automation stops working until you save a token again. Nothing in Cloudflare is changed. Revoke the token in the Cloudflare dashboard if you no longer need it.', okText: 'Remove', danger: true });
      if (!ok) return;
      await withBusy(e.currentTarget, async () => {
        await api('POST', '/api/cloudflare/token/delete', { confirm: true });
        toast('Stored token removed.');
        await refreshStatus();
        await loadCloudflare();
      });
    });
    $('#btn-cf-load').addEventListener('click', (e) => loadAccountsAndTunnels(e.currentTarget));
    $('#cf-account').addEventListener('change', (e) => withBusy(null, async () => {
      if (!e.target.value) return;
      state.cf = await api('POST', '/api/cloudflare/select', { accountId: e.target.value });
      await loadTunnels();
      renderCloudflare(state.cf);
    }));
    $('#btn-cf-select').addEventListener('click', (e) => withBusy(e.currentTarget, async () => {
      const accountId = $('#cf-account').value;
      const tunnelId = $('#cf-tunnel').value;
      if (!accountId || !tunnelId) { toast('Load and choose an account and a tunnel first.', true); return; }
      state.cf = await api('POST', '/api/cloudflare/select', { accountId, tunnelId });
      renderCloudflare(state.cf);
      await refreshStatus();
      toast(`Using tunnel ${state.cf.config.tunnelName}. Next: install the connector.`);
    }));
    $('#cf-tunnel-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const name = $('#cf-tunnel-name').value.trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { toast('Tunnel name: letters, digits, dot, dash or underscore.', true); return; }
      const ok = await confirmDialog({
        title: 'Create a Cloudflare tunnel',
        body: [h('p', null, 'This creates a new remotely managed tunnel named ', h('strong', null, name), ' in account ', h('strong', null, state.cf.config.accountName || state.cf.config.accountId), '.'),
          'Nothing else in Cloudflare is changed. The tunnel becomes the selected tunnel for this instance.'],
        okText: 'Create tunnel',
        checkbox: 'Create this resource in my Cloudflare account',
      });
      if (!ok) return;
      await withBusy(e.submitter, async () => {
        state.cf = await api('POST', '/api/cloudflare/tunnel', { name, confirm: true });
        $('#cf-tunnel-name').value = '';
        $('#cf-tunnel').dataset.loaded = 'false';
        renderCloudflare(state.cf);
        await refreshStatus();
        toast(`Tunnel ${name} created. Next: install the connector.`);
      });
    });
    $('#btn-cf-connector').addEventListener('click', async (e) => {
      const button = e.currentTarget;
      const cf = state.cf;
      const ok = await confirmDialog({
        title: 'Install the connector',
        body: [h('p', null, 'Downloads the connector token of tunnel ', h('strong', null, cf.config.tunnelName), ' into ', h('code', null, 'secrets\\cloudflare_tunnel_token'),
          ' and starts (or restarts) the container ', h('strong', null, cf.connector.container), '.'),
          'No other container is touched. If another cloudflared container already serves this tunnel, the step stops.'],
        okText: 'Install and start',
      });
      if (!ok) return;
      const send = async (confirmReplace) => {
        try {
          return await api('POST', '/api/cloudflare/connector', { confirm: true, confirmReplace });
        } catch (err) {
          if (err.status === 409 && err.data.needsConfirm === 'replace') {
            const again = await confirmDialog({ title: 'Replace the connector token?', body: 'A tunnel token is already installed. It is backed up and replaced with the token of the selected tunnel, and cloudflared is restarted.', okText: 'Replace', danger: true });
            return again ? send(true) : null;
          }
          throw err;
        }
      };
      await withBusy(button, async () => {
        const r = await send(false);
        if (!r) return;
        showOutput($('#cf-connector-output'), [r.message, ...arr(r.output)]);
        toast(r.message, !r.ok);
        await refreshStatus();
        await loadCloudflare();
      });
    });

    $('#logs-form').addEventListener('submit', (e) => {
      e.preventDefault();
      withBusy(e.submitter, async () => {
        const r = await api('GET', `/api/logs?role=${encodeURIComponent($('#logs-role').value)}&tail=${encodeURIComponent($('#logs-tail').value)}`);
        const out = $('#logs-output');
        out.textContent = arr(r.Lines).join('\n') || (r.Ok ? '(no log lines)' : `Container ${r.Container} not found.`);
        out.scrollTop = out.scrollHeight;
      });
    });
    const validate = (deep) => async (e) => withBusy(e.currentTarget, async () => {
      const r = await api('POST', '/api/validate', { deep });
      if (r.installed === false) { showOutput($('#validate-output'), [r.message]); return; }
      const lines = [];
      for (const i of arr(r.issues)) lines.push(`[${i.Level.toUpperCase()}] ${i.Service}: ${i.Message}`);
      if (r.drift > 0) lines.push(`${r.drift} route file(s) differ from config\\services.json.`);
      if (r.deep) {
        for (const w of arr(r.deep.Warnings)) lines.push(`[WARNING] ${w}`);
        for (const x of arr(r.deep.Errors)) lines.push(`[ERROR] ${x}`);
        for (const ro of arr(r.deep.Routers)) lines.push(`${ro.Name}  ${ro.Status}  ${ro.Rule}`);
      }
      lines.push(r.ok ? 'Configuration is valid.' : 'Configuration has errors.');
      showOutput($('#validate-output'), lines);
    });
    $('#btn-validate').addEventListener('click', validate(false));
    $('#btn-validate-deep').addEventListener('click', validate(true));
    $('#btn-diagnostics').addEventListener('click', (e) => withBusy(e.currentTarget, async () => {
      const r = await api('POST', '/api/diagnostics', {});
      showOutput($('#diagnostics-output'), r.lines);
      $('#btn-diagnostics-copy').hidden = false;
    }));
    $('#btn-diagnostics-copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText($('#diagnostics-output').textContent); toast('Copied.'); } catch (err) { toast('Copy failed; select the text instead.', true); }
    });
    $('#btn-audit').addEventListener('click', (e) => withBusy(e.currentTarget, async () => {
      const r = await api('GET', '/api/audit');
      showOutput($('#audit-output'), arr(r.lines).length ? r.lines : ['No activity yet.']);
    }));
  }

  // --- Start ---------------------------------------------------------------------------------------------
  async function init() {
    try {
      const s = await api('GET', '/api/session');
      state.csrf = s.csrf;
    } catch (e) {
      if (e.status !== 401) toast(e.message, true);
      return;
    }
    wire();
    const name = location.hash.replace('#', '');
    selectTab(loaders[name] ? name : 'setup');
  }
  init();
})();
