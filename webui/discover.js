'use strict';
// Docker discovery and publishing: the containers on this engine (GET /api/docker/containers), a short publishing
// wizard (application -> port -> hostname -> reachability -> who can reach it -> review -> publish) and the per-service
// request-path health view (POST /api/services/health). Publishing reuses the services plan/apply pipeline, so every
// change is previewed and confirmed; attaching a container to the shared network is a separate, confirmed Docker change.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, clear, fill, icon, plainChip, chip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const cfReady = (s) => !!(s && s.cloudflare && s.cloudflare.tokenStored && s.cloudflare.tokenReadable && s.cloudflare.accountId && s.cloudflare.tunnelId);
  const guessChip = (g) => ({ http: plainChip('likely HTTP', 'info'), https: plainChip('likely HTTPS', 'info'), 'not-http': plainChip('not HTTP', 'neutral'), blocked: plainChip('never publish', 'err') })[g] || plainChip('unknown', 'neutral');
  const resultChip = (r) => ({ http: chip('verified', 'HTTP answers'), https: chip('verified', 'HTTPS answers'), closed: plainChip('closed', 'err'), timeout: plainChip('no answer', 'warn'), 'not-http': plainChip('not HTTP', 'warn'), error: plainChip('not tested', 'neutral') })[r] || null;

  // --- Entry points on the Services page --------------------------------------------------------------------------------
  P.serviceEntryPoints = (ctx) => h('div', { class: 'entry-cards', role: 'list', 'aria-label': 'Add an application' },
    [['discover', 'box', 'Discover running containers', 'Pick an app that already runs in Docker on this PC.'],
      ['catalog', 'download', 'Install a new application', 'Choose from the App Catalog.'],
      ['services/add', 'edit', 'Enter an HTTP backend manually', 'An app on this PC, a NAS or another device, or any address.']].map(([href, ic, title, text]) =>
      h('a', { class: 'entry-card', role: 'listitem', href: `#${href}` }, h('span', { class: 'xp-icon' }, icon(ic)), h('span', null, h('strong', null, title), h('span', { class: 'small muted' }, text)))));

  // --- Discover ----------------------------------------------------------------------------------------------------------
  const filters = { q: '', stopped: false, infra: false };
  P.discover = async (main, ctx) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    if (!s.setup.installed) { fill(main, head('Services', 'Discover running containers', 'Available after the installation.')); return; }
    fill(main, head('Services', 'Discover running containers', 'Reading Docker…'));
    let data;
    try { data = s.docker = await api('GET', '/api/docker/containers'); } catch (e) { fill(main, head('Services', 'Discover running containers', ''), h('div', { class: 'callout err' }, h('p', null, e.message))); return; }
    const listHost = h('div', { class: 'disc-list', 'aria-live': 'polite' });
    const search = h('input', { type: 'search', id: 'disc-q', value: filters.q, placeholder: 'Name, image or project', autocomplete: 'off' });
    const cb = (key, label) => { const b = h('input', { type: 'checkbox', checked: filters[key] }); b.addEventListener('change', () => { filters[key] = b.checked; draw(); }); return h('label', { class: 'check' }, b, h('span', null, label)); };
    search.addEventListener('input', () => { filters.q = search.value.trim().toLowerCase(); draw(); });
    function draw() {
      const list = arr(data.containers).filter((c) => (filters.stopped || c.state === 'running') && (filters.infra || !(c.infrastructure || c.ownInstance))
        && (!filters.q || [c.name, c.image, c.compose.project, c.compose.service].join(' ').toLowerCase().includes(filters.q)));
      fill(listHost, list.length ? list.map((c) => card(ctx, c, data.proxyNetwork)) : h('p', { class: 'empty' }, 'No container matches. Show stopped or infrastructure containers, or clear the search.'));
    }
    fill(main,
      head('Services', 'Discover running containers', 'Containers on this Docker engine. Choose one to publish it through Traefik; nothing changes until you review and approve.',
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => P.discover(main, ctx)) }, icon('refresh'), 'Refresh')),
      h('p', null, h('a', { href: '#services' }, '← Services')),
      h('div', { class: 'disc-toolbar' }, field({ id: 'disc-q', label: 'Search', control: search }), cb('stopped', 'Show stopped containers'), cb('infra', 'Show proxy and tunnel infrastructure')),
      listHost,
      gate('expert', technical([JSON.stringify(data, null, 2)], 'Raw discovery data (no environment variables, mounts or commands)')));
    draw();
  };

  function card(ctx, c, proxyNet) {
    const ports = arr(c.ports);
    const claims = [...arr(c.services).map((sv) => `Published here as ${arr(sv.hostnames).join(', ')} (service ${sv.name}, port ${sv.port})`),
      ...arr(c.traefik.routers).map((r) => `Traefik labels: ${arr(r.hosts).join(', ') || r.rule}`)];
    const canPublish = c.state === 'running' && !c.ownInstance && !c.infrastructure && ports.some((p) => p.proto === 'tcp' && p.guess !== 'blocked');
    return h('article', { class: 'card disc-card', 'aria-label': c.name },
      h('div', { class: 'card-head' }, h('h2', null, c.name), c.compose.project ? plainChip(`${c.compose.project}${c.compose.service ? ` / ${c.compose.service}` : ''}`) : null,
        h('span', { class: 'grow' }), c.state === 'running' ? chip(c.health && c.health !== 'healthy' ? 'warning' : 'healthy', c.health ? `running · ${c.health}` : 'running') : plainChip(c.state, 'neutral')),
      h('p', { class: 'mono small' }, c.image.replace(/@sha256:[0-9a-f]+/, '@sha256:…'), ' ', c.tag === 'latest (implicit)' || c.tag === 'latest' ? plainChip('unpinned tag', 'warn') : null),
      h('div', { class: 'chips' }, arr(c.networks).map((n) => plainChip(n.name === proxyNet ? `${n.name} (Traefik can reach it)` : n.name, n.name === proxyNet ? 'ok' : 'neutral'))),
      ports.length ? h('ul', { class: 'port-list' }, ports.map((p) => h('li', null, h('span', { class: 'mono' }, `${p.port}/${p.proto}`), ' ', guessChip(p.guess),
        p.hostPort ? h('span', { class: 'small muted' }, ` published on ${p.hostIp || '0.0.0.0'}:${p.hostPort}`) : null, U.gateSpan('advanced', h('span', { class: 'small muted' }, ` · ${p.reason}`))))) : h('p', { class: 'muted small' }, 'No ports declared.'),
      claims.length ? h('ul', { class: 'checks' }, claims.map((t) => checkItem('neutral', t))) : null,
      gate('expert', kv([['ID', c.id], ['Restart policy', c.restart || 'no'], ['Compose folder', c.compose.workingDir || '—']])),
      h('div', { class: 'actions' },
        canPublish ? h('a', { class: 'btn primary', href: `#publish/${encodeURIComponent(c.name)}`, 'aria-label': `Publish ${c.name}` }, icon('globe'), 'Publish…') : null,
        !canPublish ? h('span', { class: 'small muted' }, c.ownInstance ? 'Part of this deployment.' : c.infrastructure ? 'Proxy or tunnel infrastructure: not published.' : c.state !== 'running' ? 'Start the container to publish it.' : 'No TCP port to publish.') : null));
  }

  // --- Publishing wizard -----------------------------------------------------------------------------------------------
  P.publish = async (main, ctx, sub) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    const name = decodeURIComponent(sub || '');
    fill(main, head('Services', 'Publish an application', 'Reading Docker…'));
    const data = s.docker && arr(s.docker.containers).some((x) => x.name === name) ? s.docker : (s.docker = await api('GET', '/api/docker/containers'));
    const c = arr(data.containers).find((x) => x.name === name);
    if (!c) { fill(main, head('Services', 'Publish an application', ''), h('div', { class: 'callout err' }, h('p', null, `No container named ${name}.`)), h('a', { href: '#discover' }, 'Back to the containers')); return; }
    s.zones = s.zones && s.zones.length ? s.zones : [];
    if (!s.zones.length && cfReady(s.status)) { try { s.zones = arr((await api('GET', '/api/cloudflare/zones')).zones).filter((z) => z.status !== 'deleted'); } catch (e) { s.zones = []; } }
    // Apps from the catalog bring their own defaults: web port and scheme, exposure, warnings.
    if (c.managedBy && !s.catalog) { try { s.catalog = await api('GET', '/api/catalog'); } catch (e) { s.catalog = null; } }
    const app = c.managedBy && s.catalog ? arr(s.catalog.apps).find((x) => x.id === c.managedBy) : null;
    const appPort = app ? arr(app.services).flatMap((x) => x.ports).find((p) => p.primary) : null;
    const label = app ? L.suggestLabel(c.name) : L.suggestAppName(c);
    const port = (appPort && arr(c.ports).find((p) => p.port === appPort.container)) || L.choosePort(c.ports);
    if (!s.forms.pub || s.forms.pub.container !== c.name) {
      const reach = L.reachOptions(c, port ? port.port : 0);
      const exp = app && app.exposure ? app.exposure.default : 'access';
      s.forms.pub = { container: c.name, display: app ? app.name : L.displayNameFromLabel(label), sub: L.autoName(label), domain: (s.zones[0] || {}).name || '', port: port ? port.port : 0,
        scheme: (appPort && appPort.protocol === 'https') || (port && port.guess === 'https') ? 'https' : 'http', tls: !!(app && app.web && app.web.tlsSkipVerify), reach: reach.default,
        exposure: cfReady(s.status) && exp !== 'local' ? exp : 'local', emails: s.setup.contactEmail || '', probes: {}, claims: null, warning: app && app.exposure ? app.exposure.warning || '' : '', noPublic: !!(app && app.exposure && app.exposure.allowPublic === false) };
    }
    renderWizard(main, ctx, c, data.proxyNetwork);
  };

  function renderWizard(main, ctx, c, proxyNet) {
    const s = ctx.state; const f = s.forms.pub;
    const zones = arr(s.zones).map((z) => z.name);
    const ready = cfReady(s.status);
    const reach = L.reachOptions(c, f.port);
    if (!reach.options.includes(f.reach)) f.reach = reach.default;
    const host = () => L.joinHostname(f.sub.value, f.domain);
    const rerender = () => renderWizard(main, ctx, c, proxyNet);
    const step = (n, title, ...body) => h('section', { class: 'wiz-step', 'aria-labelledby': `wiz-${n}` }, h('h2', { id: `wiz-${n}` }, h('span', { class: 'step-num' }, String(n)), title), body);

    // 1. Application
    const display = h('input', { id: 'pub-display', value: f.display, maxlength: '60', autocomplete: 'off' });
    display.addEventListener('input', () => { f.display = display.value; f.sub = L.autoNameFromSource(f.sub, L.suggestLabel(f.display)); subInput.value = f.sub.value; syncHost(); });
    // 2. Port
    const portRows = arr(c.ports).map((p) => {
      const pr = f.probes[p.port];
      const radio = h('input', { type: 'radio', name: 'pub-port', value: String(p.port), checked: f.port === p.port, disabled: p.proto !== 'tcp' || p.guess === 'blocked',
        onchange: () => { f.port = p.port; f.scheme = pr && pr.result === 'https' ? 'https' : p.guess === 'https' ? 'https' : 'http'; f.reach = L.reachOptions(c, p.port).default; rerender(); } });
      return h('li', { class: 'port-choice' }, h('label', { class: 'check' }, radio, h('span', null, h('span', { class: 'mono' }, `${p.port}/${p.proto}`), ' ', guessChip(p.guess), pr ? [' ', resultChip(pr.result)] : null)),
        p.proto === 'tcp' && p.guess !== 'blocked' ? h('button', { type: 'button', class: 'btn small ghost', 'aria-label': `Test port ${p.port}`, onclick: (e) => withBusy(e.currentTarget, async () => {
          try { f.probes[p.port] = await api('POST', '/api/docker/probe', { container: c.name, port: p.port }); if (f.port === p.port && f.probes[p.port].result === 'https') f.scheme = 'https'; } catch (err) { f.probes[p.port] = { result: 'error', detail: err.message }; }
          rerender();
        }) }, icon('pulse'), 'Test') : null,
        pr ? h('p', { class: 'small muted' }, pr.detail, U.atLeast('advanced') && pr.method ? ` (${pr.method === 'probe-container' ? `probe container on ${pr.network}` : `published port ${pr.network}`})` : '') : null);
    });
    // 3. Hostname
    const subInput = h('input', { id: 'pub-sub', value: f.sub.value, autocomplete: 'off', spellcheck: 'false' });
    const subTag = h('span', { class: 'auto-tag' }, f.sub.custom ? 'edited' : 'automatic');
    const preview = h('span', { class: 'mono' });
    const claimBox = h('div', { class: 'claims', 'aria-live': 'polite' });
    let claimTimer = null;
    const checkClaims = () => {
      clearTimeout(claimTimer);
      claimTimer = setTimeout(async () => {
        if (!f.sub.value || !f.domain || !L.isValidSubdomain(f.sub.value)) { fill(claimBox); return; }
        try {
          const r = f.claims = await api('GET', `/api/docker/claims?hostname=${encodeURIComponent(host())}`);
          fill(claimBox, r.free && !arr(r.claims).length ? h('p', { class: 'hint ok' }, icon('check'), ` ${r.hostname} is not used by anything else.`)
            : h('ul', { class: 'checks' }, arr(r.claims).map((x) => checkItem(x.level === 'error' ? 'err' : 'warn', x.name, x.detail))));
        } catch (e) { fill(claimBox, h('p', { class: 'form-error' }, e.message)); }
      }, 300);
    };
    function syncHost() { preview.textContent = `${f.exposure === 'local' ? 'http' : 'https'}://${host()}`; subTag.textContent = f.sub.custom ? 'edited' : 'automatic'; checkClaims(); }
    subInput.addEventListener('input', () => { f.sub = L.autoNameEdit(f.sub, subInput.value, L.suggestLabel(f.display)); syncHost(); });
    const domain = zones.length ? h('select', { 'aria-label': 'Domain' }, zones.map((z) => h('option', { value: z, selected: z === f.domain }, z)))
      : h('input', { value: f.domain, placeholder: 'example.com', 'aria-label': 'Domain', spellcheck: 'false' });
    domain.addEventListener(zones.length ? 'change' : 'input', () => { f.domain = domain.value.trim().toLowerCase(); syncHost(); });
    // 4. Reachability
    const reachChoices = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'How Traefik reaches it' }, reach.options.map((o) => {
      const text = { network: [`Shared network '${proxyNet}'`, `${c.name} is attached: Traefik reaches it as http://${c.name}:${f.port}. No Docker change.`],
        attach: [`Attach to '${proxyNet}'`, `Runs docker network connect ${proxyNet} ${c.name} after a separate confirmation. Lasts until the container is recreated: add the network to its compose file to keep it.`],
        hostport: ['Through the published port', `Traefik uses host.docker.internal:${reach.hostPort} (the port already published on this PC). No Docker change.`] }[o];
      return h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'pub-reach', value: o, checked: f.reach === o, onchange: () => { f.reach = o; rerender(); } }), h('strong', null, text[0]), h('span', { class: 'small muted' }, text[1]));
    }));
    // 5. Who can reach it
    const exposure = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Who can reach it?' },
      [['access', 'Internet, Cloudflare Access login', 'Recommended: only the emails you allow can sign in.', !ready],
        ['public', 'Internet, no extra login', f.noPublic ? 'Not offered for this app: it controls Docker on this PC.' : 'Only for apps with their own secure login.', !ready || f.noPublic],
        ['local', 'Local only', 'A Traefik route on this PC; nothing in Cloudflare.', false]].map(([v, title, text, needsCf]) =>
        h('label', { class: `choice ${needsCf ? 'disabled' : ''}` }, h('input', { type: 'radio', name: 'pub-exp', value: v, checked: f.exposure === v, disabled: needsCf, onchange: () => { f.exposure = v; rerender(); } }),
          h('strong', null, title), h('span', { class: 'small muted' }, needsCf && !(v === 'public' && f.noPublic && ready) ? 'Connect Cloudflare (tunnel) first.' : text))));
    const emails = h('input', { id: 'pub-emails', value: f.emails, spellcheck: 'false', placeholder: 'you@example.com' });
    emails.addEventListener('input', () => { f.emails = emails.value; });
    const tls = h('input', { type: 'checkbox', checked: f.tls }); tls.addEventListener('change', () => { f.tls = tls.checked; });
    const err = h('p', { class: 'form-error', role: 'alert' });
    const target = f.reach === 'hostport' ? `${f.scheme}://host.docker.internal:${reach.hostPort}` : `${f.scheme}://${c.name}:${f.port}`;

    fill(main,
      head('Services', `Publish ${f.display || c.name}`, 'Five short choices, then a preview of every change. Nothing changes until you approve it.'),
      h('p', null, h('a', { href: '#discover' }, '← All containers')),
      h('form', { class: 'card wizard', novalidate: true, 'aria-label': 'Publish an application' },
        step(1, 'Application', h('p', { class: 'small muted' }, `${c.name} · ${c.image.replace(/@sha256:[0-9a-f]+/, '')}`),
          field({ id: 'pub-display', label: 'Name', control: display, hint: 'Shown in this manager; the hostname follows it until you edit the hostname.' })),
        step(2, 'Port', h('p', { class: 'small muted' }, 'Ports are only guesses until tested: Test runs a short-lived probe container on the app\'s network (or uses a published port) and changes nothing.'),
          h('ul', { class: 'port-choices' }, portRows),
          f.scheme === 'https' ? h('label', { class: 'check' }, tls, h('span', null, 'Skip certificate verification to the app (self-signed certificate)')) : null),
        step(3, 'Hostname', h('div', { class: 'field' }, h('label', { for: 'pub-sub' }, 'Hostname ', subTag), h('div', { class: 'hostname-row' }, subInput, h('span', { class: 'sep' }, '.'), domain), h('p', { class: 'hint' }, preview)), claimBox),
        step(4, 'How Traefik reaches it', reachChoices, reach.loopbackOnly ? h('p', { class: 'hint warn' }, 'Its published port listens on 127.0.0.1 only, which containers cannot reach; attach it to the network instead.') : null),
        step(5, 'Who can reach it', f.warning ? h('div', { class: 'callout warn' }, h('p', null, f.warning)) : null, exposure, f.exposure === 'access' ? field({ id: 'pub-emails', label: 'Allowed emails (Cloudflare Access)', control: emails }) : null,
          f.exposure === 'public' ? h('div', { class: 'callout warn' }, h('p', null, 'Anyone on the Internet can reach this app. Only choose this when the app has its own secure login.')) : null),
        h('section', { class: 'wiz-step' }, h('h2', null, h('span', { class: 'step-num' }, icon('eye')), 'Review'),
          kv([['Application', `${f.display} (${c.name})`], ['Address', `${f.exposure === 'local' ? 'http' : 'https'}://${host()}`], ['Traefik forwards to', target],
            ['Docker change', f.reach === 'attach' ? `Attach ${c.name} to ${proxyNet} (asked separately)` : 'None'],
            ['Who can reach it', { access: 'Cloudflare Access login', public: 'Anyone (app login)', local: 'This PC only' }[f.exposure]]]),
          err,
          h('div', { class: 'actions' }, h('button', { type: 'submit', class: 'btn primary' }, icon('eye'), 'Preview changes'), h('a', { class: 'btn', href: '#discover' }, 'Cancel')))));
    syncHost();
    const form = $('form.wizard', main);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const errors = [];
      const id = L.suggestServiceName(f.display || c.name);
      if (!/^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/.test(id)) errors.push('Enter a name.');
      if (!f.sub.value || !L.isValidSubdomain(f.sub.value)) errors.push('Enter a hostname (letters, digits and dashes).');
      if (!f.domain) errors.push('Choose a domain.');
      if (!f.port) errors.push('Choose a port.');
      if (f.exposure === 'access' && L.splitEmails(f.emails).some((x) => !L.isEmail(x))) errors.push('Check the email addresses.');
      if (f.claims && f.claims.hostname === host() && !f.claims.free) errors.push(`${host()} is already routed elsewhere (see Hostname).`);
      err.textContent = errors.join(' ');
      if (errors.length) return;
      const btn = e.submitter || form.querySelector('[type=submit]');
      if (f.reach === 'attach') {
        const ok = await U.confirmDialog({ title: `Attach ${c.name} to ${proxyNet}`, okText: 'Attach',
          body: [`This runs docker network connect ${proxyNet} ${c.name}. The container keeps running; it gains a connection to the shared network, where Traefik and every other attached container can reach it.`,
            'The attachment lasts until the container is recreated (for example by docker compose up after an update). Add the network to its compose file to keep it; the lines are shown afterwards.'],
          checkbox: 'I understand this changes the Docker networking of this container.' });
        if (!ok) return;
        try {
          const r = await api('POST', '/api/docker/connect', { container: c.name, confirm: true });
          toast(r.message);
          c.onProxyNetwork = true; f.reach = 'network';
          s.lastConnect = r;
        } catch (x) { err.textContent = x.message; return; }
      }
      const type = f.reach === 'hostport' ? 'host' : 'docker';
      const body = {
        op: 'add', name: id,
        service: { name: id, displayName: f.display, description: `Published from container ${c.name}`, enabled: true, hostnames: [host()], pathPrefix: '', stripPrefix: false, middlewares: ['default-headers@file'],
          target: { type, host: type === 'host' ? 'host.docker.internal' : c.name, port: type === 'host' ? reach.hostPort : f.port, protocol: f.scheme, tlsSkipVerify: f.scheme === 'https' && f.tls },
          cloudflare: { publish: f.exposure !== 'local', access: f.exposure === 'access' } },
        cloudflare: { automate: f.exposure !== 'local' && ready, accessEmails: L.splitEmails(f.emails), cleanup: true },
      };
      ctx.state.afterApply = () => { s.forms.pub = null; s.healthFor = id; ctx.navigate('services', `health/${id}`); };
      ctx.startPlan(body, btn);
    });
  }

  // --- Request-path health ---------------------------------------------------------------------------------------------
  const ORDER = ['dns', 'access', 'tunnel', 'router', 'service', 'backend', 'http', 'public'];
  const healthTone = (s) => (s === 'ok' ? 'ok' : s === 'failed' ? 'err' : s === 'warning' ? 'warn' : s === 'auth' ? 'auth' : 'neutral');
  P.healthTone = healthTone;
  P.healthList = (r) => h('div', { class: 'health' },
    r.firstFailure ? h('div', { class: 'callout err first-failure' }, h('p', null, h('strong', null, `First failing hop: ${r.firstFailure.label}. `), r.firstFailure.message))
      : h('p', { class: 'small' }, 'No failing hop among the checks performed.'),
    h('p', { class: 'small muted' }, `${r.performed} of ${r.total} checks performed · ${String(r.checkedAt).replace('T', ' ')}. Grey checks were not performed; they are never counted as passed. A lock means a login page answered: reachable, but signing in was not tested.`),
    h('ol', { class: 'checks health-path' }, ORDER.map((id) => arr(r.checks).find((x) => x.id === id)).filter(Boolean).map((x) =>
      checkItem(healthTone(x.state), `${x.label}${x.performed ? '' : ' (not checked)'}`, x.message))));
  P.serviceHealth = async (host, name, opts = {}) => {
    fill(host, h('p', { class: 'muted' }, 'Checking the request path…'));
    try {
      const r = await api('POST', '/api/services/health', { name, public: !!opts.public });
      if (!host.isConnected) return r;
      fill(host, h('div', { class: 'card-head' }, h('h2', null, `Health: ${name}`), h('span', { class: 'grow' }),
        r.exposure !== 'local' && !opts.public ? h('button', { type: 'button', class: 'btn small', onclick: () => P.serviceHealth(host, name, { public: true }) }, icon('globe'), 'Also check the public URL') : null,
        h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close health results', onclick: () => clear(host) }, icon('x'))), P.healthList(r));
      return r;
    } catch (e) { fill(host, h('div', { class: 'callout err' }, h('p', null, e.message))); return null; }
  };

  // --- App Catalog (next milestone) ----------------------------------------------------------------------------------------
  P.catalog = P.catalog || (async (main) => {
    fill(main, head('Services', 'Install a new application', 'The App Catalog (curated applications deployed as ordinary Compose projects) is the next milestone.'),
      h('div', { class: 'callout' }, h('p', null, 'Until then, start the application with Docker Compose yourself, then publish it with ', h('a', { href: '#discover' }, 'Discover running containers'), '.')));
  });
})();
