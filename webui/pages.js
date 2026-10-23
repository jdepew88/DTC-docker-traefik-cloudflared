'use strict';
// Operational pages shown after installation: Overview, Services, Cloudflare, Traefik Dashboard, Backups, Diagnostics,
// Settings, Help and Learning. Every change still goes through a preview and an explicit confirmation on the server.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, $$, arr, h, clear, fill, icon, chip, plainChip, toast, api, withBusy, field, gate, help, kv, checkItem, technical } = U;
  const P = (window.TPMPages = window.TPMPages || {});

  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const ext = (url, text) => h('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, text || url, ' ', icon('external'));
  const notInstalled = (ctx, what) => h('div', { class: 'callout warn' }, h('p', null, `${what} is available after the installation. `), h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: () => ctx.navigate('setup') }, 'Go to the setup journey')));
  const cfReady = (s) => !!(s && s.cloudflare.tokenStored && s.cloudflare.tokenReadable && s.cloudflare.accountId && s.cloudflare.tunnelId);

  // --- Overview ----------------------------------------------------------------------------------------------------------
  P.overview = async (main, ctx) => {
    const s = ctx.state;
    fill(main, head('Operate', 'Overview', 'The health of this deployment and how requests reach your apps.'), h('p', { class: 'muted' }, 'Loading…'));
    const o = s.overview = await api('GET', '/api/overview');
    if (!o.installed) { fill(main, head('Operate', 'Overview', ''), notInstalled(ctx, 'The overview')); return; }
    const st = o.status; const c = {}; arr(st.stack.Containers).forEach((x) => { c[x.Role] = x; });
    const roles = o.mode === 'tunnel' ? ['traefik', 'socket-proxy', 'cloudflared'] : ['traefik', 'socket-proxy'];
    const running = roles.filter((r) => c[r] && c[r].State === 'running').length;
    const healthy = running === roles.length && st.stack.TraefikApi && !o.warnings.length;
    const tunnelState = !o.tunnel ? 'neutral' : o.tunnel.status === 'healthy' || o.tunnel.connections > 0 ? 'ok' : 'err';
    const cstate = (r) => (!c[r] ? 'neutral' : c[r].State === 'running' ? (c[r].Health && c[r].Health !== 'healthy' ? 'warn' : 'ok') : 'err');
    const tile = (label, ic, value, sub, st2) => h('div', { class: 'tile' }, h('span', { class: 'tile-label' }, icon(ic), label, st2 ? h('span', { class: `dot ${st2}` }) : null), h('span', { class: 'tile-value' }, value), sub ? h('span', { class: 'tile-sub' }, sub) : null);
    const dash = o.dashboard || {};
    const nodes = o.mode === 'tunnel'
      ? [{ title: 'Visitor', sub: 'browser', icon: 'user' }, { title: 'Cloudflare', sub: arr(o.domains).map((d) => d.name).join(', ') || 'edge', icon: 'cloud', state: 'neutral' },
        { title: 'Tunnel', sub: o.tunnel ? `${o.tunnel.name}: ${o.tunnel.status}` : 'not checked', icon: 'tunnel', state: tunnelState },
        { title: 'cloudflared', sub: c.cloudflared ? c.cloudflared.State : 'missing', icon: 'box', state: cstate('cloudflared') },
        { title: 'Traefik', sub: `127.0.0.1:${st.instance.httpPort}`, icon: 'route', state: st.stack.TraefikApi ? 'ok' : cstate('traefik') === 'ok' ? 'warn' : 'err' },
        { title: 'Your apps', sub: `${o.services.enabled} enabled`, icon: 'server' }]
      : [{ title: 'Browser', sub: 'this PC', icon: 'monitor' }, { title: 'Traefik', sub: `127.0.0.1:${st.instance.httpPort}`, icon: 'route', state: st.stack.TraefikApi ? 'ok' : 'err' }, { title: 'Your apps', sub: `${o.services.enabled} enabled`, icon: 'server' }];
    const links = o.mode === 'tunnel' ? [{ label: 'HTTPS' }, { label: 'tunnel', state: tunnelState === 'ok' ? 'ok' : tunnelState === 'err' ? 'err' : '' }, { label: '' }, { label: 'http :80' }, { label: 'by hostname' }] : [{ label: 'http' }, { label: 'by hostname' }];
    const actions = [];
    if (o.mode === 'tunnel' && !dash.enabled && cfReady(s.setup || st)) actions.push(['Publish the Traefik dashboard to test the whole path', 'dashboard']);
    if (o.services.total === 0) actions.push(['Add your first service', 'services']);
    if (o.upgrade && o.upgrade.state === 'available') actions.push([`Newer application files are available (${o.upgrade.installedVersion} → ${o.upgrade.sourceVersion}): preview the upgrade`, 'upgrade']);
    if (!s.verify) actions.push(['Run the end-to-end verification', 'verify']);
    const verifyBox = h('div', { id: 'overview-verify' }, s.verify ? window.TPMPages.renderVerification(ctx, s.verify) : null);
    // The diagram and the container-manager link load after the page: the overview never waits for them.
    const miniHost = h('div', { class: 'xp-mini' }, U.topology(nodes, links));
    const managerHost = h('span', { class: 'manager-link' });
    if (P.explorerMini) P.explorerMini(miniHost, ctx).then((m) => { const cm = m && arr(m.containerManagers)[0]; if (cm && managerHost.isConnected) fill(managerHost, h('a', { class: 'btn', href: cm.url, target: '_blank', rel: 'noopener noreferrer' }, icon('box'), `Open ${cm.kind === 'portainer' ? 'Portainer' : cm.kind === 'arcane' ? 'Arcane' : cm.kind}`)); });
    fill(main,
      head('Operate', 'Overview', null, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => P.overview(main, ctx)) }, icon('refresh'), 'Refresh')),
      h('div', { class: 'tiles' },
        tile('Deployment', 'pulse', healthy ? 'Healthy' : 'Needs attention', o.mode === 'tunnel' ? 'Cloudflare Tunnel' : 'Local only', healthy ? 'ok' : 'warn'),
        tile('Containers', 'box', `${running} of ${roles.length} running`, roles.map((r) => (c[r] ? c[r].Name : r)).join(', '), running === roles.length ? 'ok' : 'err'),
        o.mode === 'tunnel' ? tile('Tunnel', 'tunnel', o.tunnel ? o.tunnel.status : 'Not checked', o.tunnel ? `${o.tunnel.connections} connection(s) · ${o.tunnel.name}` : 'Connect Cloudflare to check', tunnelState) : null,
        tile('Authorized domains', 'globe', arr(o.domains).map((d) => d.name).join(', ') || 'None', o.mode === 'tunnel' ? 'Services publish only under these' : 'Not needed locally'),
        tile('Traefik dashboard', 'gauge', dash.enabled ? 'Public + local' : 'Local', dash.enabled ? dash.publicUrl : dash.localUrl, dash.enabled ? 'ok' : null),
        tile('Services', 'list', `${o.services.published} published`, `${o.services.enabled} enabled of ${o.services.total}`)),
      h('div', { class: 'quick-actions', role: 'group', 'aria-label': 'Quick actions' },
        h('a', { class: 'btn primary', href: '#explorer' }, icon('network'), 'View infrastructure'),
        h('a', { class: 'btn', href: '#catalog' }, icon('plus'), 'Add application'),
        h('a', { class: 'btn', href: '#discover' }, icon('globe'), 'Publish service'),
        h('a', { class: 'btn', href: dash.localUrl, target: '_blank', rel: 'noopener noreferrer' }, icon('gauge'), 'Open Traefik dashboard'),
        managerHost,
        h('button', { type: 'button', class: 'btn', onclick: (e) => verify(e.currentTarget) }, icon('pulse'), 'Check health')),
      h('section', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', null, 'Request flow'), help('reverse-proxy', 'Reverse proxy'), h('span', { class: 'grow' }),
        dash.enabled ? ext(dash.publicUrl, 'Public dashboard') : null, h('a', { href: '#explorer' }, 'Explore')), miniHost),
      o.warnings.length || actions.length ? h('section', { class: 'card' }, h('h2', null, 'Needs attention'),
        h('ul', { class: 'checks' }, o.warnings.map((w) => checkItem('warn', w)), actions.map(([text, target]) => h('li', null, h('span', { class: 'ci neutral' }, icon('chevron')),
          h('span', null, h('a', { href: target === 'verify' || target === 'upgrade' ? '#overview' : `#${target}`,
            onclick: target === 'verify' ? (e) => { e.preventDefault(); verify(e.currentTarget); } : target === 'upgrade' ? (e) => { e.preventDefault(); window.TPMPages.previewUpgrade(ctx, o.path, null); } : null }, text)))))) : null,
      h('section', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', null, 'Verification'), h('span', { class: 'grow' }),
        h('button', { type: 'button', class: 'btn small', onclick: (e) => verify(e.currentTarget) }, icon('pulse'), 'Verify now')),
        h('p', { class: 'muted small' }, 'Checks each component on its own: containers, tunnel, local dashboard, routing, DNS and Access.'), verifyBox),
      h('section', { class: 'card' }, h('h2', null, 'Recent changes'), o.recent.length ? h('ul', { class: 'checks' }, o.recent.map((line) => {
        const m = /^(\S+)\s+(\S+)\s*(.*)$/.exec(line) || [line, '', line, ''];
        return h('li', null, h('span', { class: 'ci neutral' }, icon('clock')), h('span', null, h('strong', null, m[2]), h('span', { class: 'msg' }, m[3]), h('span', { class: 'why' }, m[1].replace('T', ' '))));
      })) : h('p', { class: 'muted' }, 'No changes recorded yet.')),
      technical([JSON.stringify(o, null, 2)], 'Raw overview data', 'expert'));
    async function verify(btn) { await withBusy(btn, async () => { await window.TPMPages.runVerify(ctx); fill($('#overview-verify'), window.TPMPages.renderVerification(ctx, s.verify)); }); }
  };

  // --- Services ------------------------------------------------------------------------------------------------------------
  const KINDS = {
    docker: ['Docker container', 'box', 'On the shared network: reached by its container name.'],
    host: ['This Windows PC', 'monitor', 'An app running directly on Windows.'],
    lan: ['Another device', 'server', 'A NAS, router, camera or another computer on your network.'],
    other: ['Container on another network', 'route', 'Reached through routing by IP address (Advanced).'],
  };
  P.services = async (main, ctx) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    if (!s.setup.installed) { fill(main, head('Operate', 'Services', ''), notInstalled(ctx, 'Adding services')); return; }
    const data = await api('GET', '/api/services');
    s.services = arr(data.services); s.middlewares = arr(data.middlewares);
    s.zones = [];
    if (s.status.cloudflare.tokenStored && s.status.cloudflare.accountId) { try { s.zones = arr((await api('GET', '/api/cloudflare/zones')).zones).filter((z) => z.status !== 'deleted'); } catch (e) { s.zones = []; } }
    const formHost = h('div', { id: 'service-form-host' });
    const rows = s.services.map((v) => {
      const sv = v.service;
      const hosts = arr(sv.hostnames).map((hn) => h('div', null, sv.cloudflare.publish ? ext(`https://${hn}${sv.pathPrefix || ''}`, hn + (sv.pathPrefix || '')) : hn + (sv.pathPrefix || '')));
      const exposure = v.exposure === 'access' ? plainChip('Access login', 'ok') : v.exposure === 'public' ? plainChip('Public', 'warn') : plainChip('Local only');
      const router = !sv.enabled ? plainChip('Disabled') : v.router === 'enabled' ? chip('healthy', 'Routed') : v.router === 'unknown' ? plainChip('Unknown') : plainChip(v.router, 'err');
      return h('tr', null,
        h('td', null, h('strong', null, sv.displayName || sv.name), U.gateSpan('intermediate', h('div', { class: 'sub mono' }, sv.name)), sv.description ? h('div', { class: 'sub' }, sv.description) : null),
        h('td', null, hosts),
        h('td', null, h('span', { class: 'mono' }, v.url), h('div', { class: 'sub' }, KINDS[sv.target.type] ? KINDS[sv.target.type][0] : sv.target.type)),
        h('td', null, exposure), h('td', null, router),
        h('td', { class: 'actions-cell' },
          h('button', { type: 'button', class: 'btn small', 'aria-label': `Check health of ${sv.name}`, onclick: () => { const hh = $('#health-host'); if (hh && P.serviceHealth) { P.serviceHealth(hh, sv.name); hh.scrollIntoView({ block: 'nearest' }); } } }, icon('pulse'), 'Health'),
          h('button', { type: 'button', class: 'btn small', onclick: () => openForm(ctx, v), 'aria-label': `Edit ${sv.name}` }, 'Edit'),
          h('button', { type: 'button', class: 'btn small', 'aria-label': `${sv.enabled ? 'Disable' : 'Enable'} ${sv.name}`, onclick: (e) => ctx.startPlan({ op: sv.enabled ? 'disable' : 'enable', name: sv.name, cloudflare: { automate: cfReady(s.setup), cleanup: false } }, e.currentTarget) }, sv.enabled ? 'Disable' : 'Enable'),
          h('button', { type: 'button', class: 'btn small danger-outline', 'aria-label': `Remove ${sv.name}`, onclick: (e) => ctx.startPlan({ op: 'remove', name: sv.name, cloudflare: { automate: cfReady(s.setup), cleanup: true } }, e.currentTarget) }, 'Remove')));
    });
    fill(main,
      head('Operate', 'Services', 'Each service maps a public hostname to an app: name → hostname → destination → publish. Every change is previewed first.'),
      P.serviceEntryPoints ? P.serviceEntryPoints(ctx) : h('button', { type: 'button', class: 'btn primary', onclick: () => openForm(ctx, null) }, icon('plus'), 'Add a service'),
      !data.traefikUp ? h('div', { class: 'callout warn' }, h('p', null, 'Traefik is not answering, so route status is unknown. Changes are still validated and saved.')) : null,
      arr(data.drift).length ? h('div', { class: 'callout warn' }, h('p', null, `${arr(data.drift).length} generated route file(s) do not match the registry. Re-save a service or use services.ps1 apply.`)) : null,
      formHost,
      h('section', { class: 'card health-host', id: 'health-host', 'aria-live': 'polite' }),
      h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('caption', { class: 'sr-only' }, 'Services'),
        h('thead', null, h('tr', null, ['Service', 'Hostname', 'Destination', 'Who can reach it', 'Traefik', ''].map((t) => h('th', { scope: 'col' }, t || h('span', { class: 'sr-only' }, 'Actions'))))),
        h('tbody', null, rows)), s.services.length ? null : h('p', { class: 'empty' }, 'No services yet. Choose one of the three ways above to publish your first app.')),
      h('p', { class: 'muted small', 'data-help-host': '' }, 'Seeing 404 or 502 in the browser? ', help('http-errors', 'HTTP errors')),
      gate('advanced', h('p', { class: 'muted small' }, 'This tool covers basic publishing. For middleware chains, certificates, load balancing or plugins use Traefik\'s own configuration (a hand-written .yml in traefik\\dynamic) or a dedicated Traefik manager as a separate product.')));
    if (ctx.state.sub === 'add') openForm(ctx, null);
    const hm = /^health\/(.+)$/.exec(ctx.state.sub || '');
    if (hm && P.serviceHealth) P.serviceHealth($('#health-host'), decodeURIComponent(hm[1]));
  };

  function openForm(ctx, view) {
    const s = ctx.state;
    const sv = view ? view.service : null;
    const zones = s.zones.map((z) => z.name);
    const first = sv && arr(sv.hostnames).length ? L.splitHostname(sv.hostnames[0], zones) : { sub: '', domain: zones[0] || '' };
    const f = s.forms.svc = {
      editing: sv ? sv.name : null, display: sv ? (sv.displayName || sv.name) : '', id: sv ? sv.name : '', sub: { value: first.sub, custom: !!sv },
      domain: first.domain,
      exposure: sv ? (!sv.cloudflare.publish ? 'local' : sv.cloudflare.access ? 'access' : 'public') : (cfReady(s.setup) ? 'access' : 'local'),
      emails: s.setup.contactEmail || '', path: sv ? sv.pathPrefix : '', strip: sv ? !!sv.stripPrefix : false, extra: sv ? arr(sv.hostnames).slice(1).join(', ') : '',
      tls: sv ? !!sv.target.tlsSkipVerify : false, middlewares: sv ? arr(sv.middlewares) : ['default-headers@file'], enabled: sv ? !!sv.enabled : true, description: sv ? sv.description : '',
    };
    P.initBackendState(f, sv);
    f.hostname = sv ? arr(sv.hostnames)[0] : '';
    renderForm(ctx);
    const host = $('#service-form-host'); if (host) host.scrollIntoView({ block: 'start', behavior: 'smooth' });
  }

  function renderForm(ctx) {
    const s = ctx.state; const f = s.forms.svc; const host = $('#service-form-host');
    if (!host || !f) return;
    const zones = s.zones.map((z) => z.name);
    const display = h('input', { value: f.display, autocomplete: 'off', placeholder: 'Notflix', maxlength: '60' });
    const subTag = h('span', { class: 'auto-tag' }, f.sub.custom ? 'edited' : 'automatic');
    const sub = h('input', { value: f.sub.value, autocomplete: 'off', spellcheck: 'false', placeholder: 'notflix' });
    const preview = h('span', { class: 'mono' });
    const domain = zones.length ? h('select', { 'aria-label': 'Domain' }, zones.map((z) => h('option', { value: z, selected: z === f.domain }, z)))
      : h('input', { value: f.domain, placeholder: 'example.com', 'aria-label': 'Domain', spellcheck: 'false' });
    const idInput = h('input', { value: f.id, autocomplete: 'off', spellcheck: 'false', disabled: !!f.editing });
    const sync = () => { f.hostname = L.joinHostname(f.sub.value, f.domain); preview.textContent = `https://${f.hostname}${f.path || ''}`; subTag.textContent = f.sub.custom ? 'edited' : 'automatic'; };
    display.addEventListener('input', () => {
      f.display = display.value;
      if (!f.editing) { f.sub = L.autoNameFromSource(f.sub, f.display); sub.value = f.sub.value; if (!f.idCustom) { f.id = L.suggestServiceName(f.display); idInput.value = f.id; } }
      sync();
    });
    sub.addEventListener('input', () => { f.sub = L.autoNameEdit(f.sub, sub.value, f.display); sync(); });
    domain.addEventListener(zones.length ? 'change' : 'input', () => { f.domain = domain.value.trim().toLowerCase(); sync(); });
    idInput.addEventListener('input', () => { f.id = idInput.value.trim().toLowerCase(); f.idCustom = true; });
    // Where the app runs and the backend Traefik uses (backend.js): resolved by the server, verified from Traefik's network.
    const backend = P.backendSection(ctx, f, { onContainers: () => renderForm(ctx), onTarget: () => { tlsRow.hidden = f.protocol !== 'https'; } });
    const backendInputs = P.backendInputs(ctx, f, backend, () => renderForm(ctx));
    const hostHint = f.where === 'this-computer' ? h('p', { class: 'hint', 'data-min-level': 'intermediate' }, 'The app must listen on all interfaces (0.0.0.0), not only 127.0.0.1, and Windows Firewall must allow the port from Docker Desktop.') : null;
    const ready = cfReady(s.setup);
    const exposure = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Who can reach it?' },
      [['access', 'Internet, Cloudflare Access login', 'Recommended: only the emails you allow can sign in.', !ready],
        ['public', 'Internet, no extra login', 'Only for apps with their own secure login.', !ready],
        ['local', 'Local only', 'A Traefik route on this PC; nothing in Cloudflare.', false]].map(([v, title, text, needsCf]) =>
        h('label', { class: `choice ${needsCf ? 'disabled' : ''}` }, h('input', { type: 'radio', name: 'svc-exp', value: v, checked: f.exposure === v, disabled: needsCf, onchange: () => { f.exposure = v; renderForm(ctx); } }),
          h('strong', null, title), h('span', { class: 'small muted' }, needsCf ? 'Connect Cloudflare (tunnel) first.' : text))));
    const emails = h('input', { value: f.emails, spellcheck: 'false', placeholder: 'you@example.com, family@example.com' });
    emails.addEventListener('input', () => { f.emails = emails.value; });
    const path = h('input', { value: f.path, spellcheck: 'false', placeholder: '/notflix' });
    path.addEventListener('input', () => { f.path = path.value.trim(); sync(); });
    const extra = h('input', { value: f.extra, spellcheck: 'false', placeholder: 'www.example.com' });
    extra.addEventListener('input', () => { f.extra = extra.value; });
    const desc = h('input', { value: f.description, maxlength: '200' });
    desc.addEventListener('input', () => { f.description = desc.value; });
    const cb = (key, label) => { const b = h('input', { type: 'checkbox', checked: f[key] }); b.addEventListener('change', () => { f[key] = b.checked; }); return h('label', { class: 'check' }, b, h('span', null, label)); };
    const tlsRow = cb('tls', 'Skip certificate verification to the app (self-signed devices on a trusted LAN only)');
    tlsRow.hidden = f.protocol !== 'https';
    const mws = Array.from(new Set([...s.middlewares, ...f.middlewares])).map((m) => { const b = h('input', { type: 'checkbox', value: m, checked: f.middlewares.includes(m) }); b.addEventListener('change', () => { f.middlewares = b.checked ? [...new Set([...f.middlewares, m])] : f.middlewares.filter((x) => x !== m); }); return h('label', { class: 'check' }, b, h('span', { class: 'mono' }, m)); });
    const err = h('p', { class: 'form-error', role: 'alert' });
    const form = h('form', { class: 'card', novalidate: true, 'aria-labelledby': 'svc-form-title' },
      h('div', { class: 'card-head' }, h('h2', { id: 'svc-form-title' }, f.editing ? `Edit ${f.display || f.editing}` : 'Add a service'), h('span', { class: 'grow' }), h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Close', onclick: () => { s.forms.svc = null; clear(host); } }, icon('x'))),
      h('div', { class: 'grid' },
        field({ id: 'svc-display', label: 'Service name', control: display, hint: 'Any name, e.g. Notflix. It stays as you typed it.' }),
        field({ id: 'svc-id', label: 'Service id', control: idInput, minLevel: 'advanced', hint: 'Lowercase id used in file names (svc-<id>.yml); cannot change later.' })),
      h('div', { class: 'field', 'data-help-host': '' }, h('label', { for: 'svc-sub' }, 'Public hostname ', subTag, help('fqdn', 'Hostname')),
        h('div', { class: 'hostname-row' }, Object.assign(sub, { id: 'svc-sub' }), h('span', { class: 'sep' }, '.'), domain),
        h('p', { class: 'hint' }, preview, ' ', f.sub.custom && !f.editing ? h('button', { type: 'button', class: 'btn small ghost', onclick: () => { f.sub = L.autoNameReset(f.display); renderForm(ctx); } }, 'Reset to automatic') : null),
        zones.length ? null : h('p', { class: 'hint' }, ready ? 'No allowed domain: choose one on Setup > Connect Cloudflare.' : 'Without Cloudflare, type any domain; the route then works on this PC only.')),
      backendInputs, hostHint, backend.node,
      h('div', { class: 'field' }, h('span', { class: 'label' }, 'Who can reach it?'), exposure),
      f.exposure === 'access' ? field({ id: 'svc-emails', label: 'Allowed emails (Cloudflare Access)', control: emails, helpId: 'cf-access', hint: 'Used only when an Access application has to be created.' }) : null,
      f.exposure === 'public' ? h('div', { class: 'callout warn' }, h('p', null, 'Anyone on the Internet can reach this app. Only choose this when the app has its own secure login.')) : null,
      gate('advanced', h('details', { class: 'more', open: !!(f.path || f.extra || f.tls) || null }, h('summary', null, 'Advanced routing'),
        h('div', { class: 'grid' },
          field({ id: 'svc-path', label: 'Path prefix', control: path, helpId: 'path-routing', hint: 'Route only this path, e.g. /notflix. Many apps need their base path configured for this; prefer a subdomain.' }),
          field({ id: 'svc-extra', label: 'Additional hostnames', control: extra }),
          field({ id: 'svc-desc', label: 'Description', control: desc })),
        f.path ? cb('strip', 'Strip the path prefix before forwarding') : null,
        tlsRow,
        h('fieldset', null, h('legend', null, 'Middlewares ', help('traefik-middlewares', 'Middlewares')), h('div', { class: 'chips' }, mws)),
        cb('enabled', 'Enabled'))),
      gate('expert', h('p', { class: 'small muted' }, 'Generated rule: ', h('code', null, `Host(\`${L.joinHostname(f.sub.value, f.domain)}\`)${f.path ? ` && PathPrefix(\`${f.path}\`)` : ''}`), ' → ', h('code', null, f.target ? `${f.protocol}://${f.target.host}:${f.target.port}` : '(backend not chosen yet)'))),
      err,
      h('div', { class: 'actions' }, h('button', { type: 'submit', class: 'btn primary' }, 'Preview changes'), h('button', { type: 'button', class: 'btn', onclick: () => { s.forms.svc = null; clear(host); } }, 'Cancel')));
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const errors = [];
      const id = f.editing || f.id || L.suggestServiceName(f.display);
      const hostnames = [];
      if (f.domain) hostnames.push(L.joinHostname(f.sub.value, f.domain));
      for (const x of f.extra.split(/[\s,]+/)) if (x.trim()) hostnames.push(x.trim().toLowerCase());
      const portN = f.target ? Number(f.target.port) : 0;
      if (!/^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/.test(id)) errors.push('Enter a service name (it becomes the id).');
      if (f.sub.value && !L.isValidSubdomain(f.sub.value)) errors.push('The subdomain may use letters, digits and dashes.');
      if (!f.domain) errors.push('Choose a domain.');
      if (!f.target) errors.push(f.needsChoice ? 'Choose how Traefik reaches the app: use the recommended address or pick one of the options.' : f.where === 'docker' ? 'Choose the container and its port.' : 'Enter the address and port of the app.');
      else if (!(portN >= 1 && portN <= 65535)) errors.push('Enter a port from 1 to 65535.');
      if (f.exposure === 'access' && L.splitEmails(f.emails).some((x) => !L.isEmail(x))) errors.push('Check the email addresses.');
      err.textContent = errors.join(' ');
      if (errors.length) return;
      const body = {
        op: f.editing ? 'update' : 'add', name: id,
        service: { name: id, displayName: f.display, description: f.description, enabled: f.enabled, hostnames, pathPrefix: f.path, stripPrefix: !!(f.path && f.strip), middlewares: f.middlewares,
          target: { type: f.target.type, host: f.target.host, port: portN, protocol: f.protocol, tlsSkipVerify: f.protocol === 'https' && f.tls },
          cloudflare: { publish: f.exposure !== 'local', access: f.exposure === 'access' } },
        cloudflare: { automate: f.exposure !== 'local' && ready, accessEmails: L.splitEmails(f.emails), cleanup: true },
      };
      ctx.state.afterApply = () => { s.forms.svc = null; };
      ctx.startPlan(body, e.submitter || form.querySelector('[type=submit]'));
    });
    fill(host, form);
    sync();
  }

  // --- Cloudflare --------------------------------------------------------------------------------------------------------------
  P.cloudflare = async (main, ctx) => {
    const s = ctx.state;
    const cf = s.cf = await api('GET', '/api/cloudflare');
    if (!s.setup) await ctx.refresh();
    const t = cf.token;
    const tokenInput = h('input', { type: 'password', id: 'cf-token', autocomplete: 'new-password', spellcheck: 'false', placeholder: 'Paste the token' });
    const tokenForm = h('form', { class: 'field', autocomplete: 'off' }, h('label', { for: 'cf-token' }, t.Stored ? 'Replace the API token' : 'API token'), h('div', { class: 'hostname-row' }, tokenInput, h('button', { type: 'submit', class: 'btn primary' }, 'Verify and save')));
    tokenForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const token = tokenInput.value.trim();
      if (!token) { toast('Paste an API token first.', true); return; }
      const send = async (confirmReplace) => {
        try { return await api('POST', '/api/cloudflare/token', { token, confirmReplace }); } catch (err) {
          if (err.status === 409 && err.data.needsConfirm === 'replace') { const ok = await U.confirmDialog({ title: 'Replace the stored token?', body: 'The new token replaces the stored one after Cloudflare verifies it.', okText: 'Replace' }); return ok ? send(true) : null; }
          throw err;
        }
      };
      await withBusy(e.submitter, async () => { const r = await send(false); if (!r) return; tokenInput.value = ''; s.discovery = r; toast(`Token verified and saved: ${arr(r.zones).length} domain(s) visible.`); await ctx.refresh(); ctx.rerender(); });
    });
    const acct = h('select', { 'aria-label': 'Account' }, cf.config.accountId ? h('option', { value: cf.config.accountId }, cf.config.accountName || cf.config.accountId) : h('option', { value: '' }, 'Load accounts…'));
    const tun = h('select', { 'aria-label': 'Tunnel' }, cf.config.tunnelId ? h('option', { value: cf.config.tunnelId }, cf.config.tunnelName || cf.config.tunnelId) : h('option', { value: '' }, 'Load tunnels…'));
    const load = (btn) => withBusy(btn, async () => {
      const a = await api('GET', '/api/cloudflare/accounts');
      fill(acct, arr(a.accounts).length ? null : h('option', { value: '' }, 'No accounts visible to this token'), arr(a.accounts).map((x) => h('option', { value: x.id, selected: x.id === cf.config.accountId }, x.name)));
      if (!cf.config.accountId && acct.value) await api('POST', '/api/cloudflare/select', { accountId: acct.value });
      const r = await api('GET', '/api/cloudflare/tunnels');
      fill(tun, h('option', { value: '' }, arr(r.tunnels).length ? 'Choose a tunnel…' : 'No tunnels yet: create one below'),
        arr(r.tunnels).map((x) => h('option', { value: x.id, selected: x.id === cf.config.tunnelId, disabled: !x.remotelyManaged }, `${x.name} (${x.status || 'inactive'}, ${x.connections} conn.)${x.remotelyManaged ? '' : ' - locally managed, not supported'}`)));
    });
    const newName = h('input', { autocomplete: 'off', spellcheck: 'false', placeholder: 'home-proxy' });
    const c = cf.connector;
    const managed = arr(cf.managed);
    fill(main,
      head('Operate', 'Cloudflare', 'The API token, the account and tunnel of this instance, and the resources this tool created. Changes are always previewed; nothing is deleted that this tool did not create.'),
      (!t.Stored || !t.Readable) && (cf.config.accountId || cf.config.tunnelId) ? h('div', { class: 'callout warn', role: 'status' },
        h('p', null, h('strong', null, 'Reconnect Cloudflare. '), !t.Stored ? 'No API token is stored for this deployment. ' : 'The stored token cannot be decrypted by this Windows account. ',
          `Paste a token below. The saved account (${cf.config.accountName || cf.config.accountId || '—'}), tunnel (${cf.config.tunnelName || cf.config.tunnelId || '—'}) and domains are kept; nothing is recreated. The tunnel itself keeps running meanwhile.`)) : null,
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'API token'), help('cf-api-tokens', 'API token')),
        h('div', { class: 'status-line' }, t.Stored ? chip(t.Readable ? 'validated' : 'failed', t.Readable ? 'Stored (encrypted)' : 'Stored token unreadable') : plainChip('No token stored'),
          t.Stored ? h('span', { class: 'muted small' }, `Saved ${t.SavedAt} by ${t.User}`) : null, cf.apiBase !== 'https://api.cloudflare.com/client/v4' ? plainChip(`API: ${cf.apiBase} (test mock)`, 'warn') : null),
        h('p', { class: 'muted small' }, 'Encrypted with Windows DPAPI for your Windows account in secrets\\cloudflare_api.dpapi. Never shown again or sent to the browser.'),
        h('div', { class: 'actions' }, s.setup ? h('a', { class: 'btn', href: s.setup.cloudflare.tokenLinkWithAccess, target: '_blank', rel: 'noopener noreferrer' }, icon('key'), 'Create Cloudflare API Token') : null,
          t.Stored ? h('button', { type: 'button', class: 'btn danger-outline', onclick: async (e) => {
            const ok = await U.confirmDialog({ title: 'Remove the stored API token?', body: 'Automation stops until you save a token again. Nothing in Cloudflare is changed.', okText: 'Remove', danger: true });
            if (ok) await withBusy(e.currentTarget, async () => { await api('POST', '/api/cloudflare/token/delete', { confirm: true }); toast('Stored token removed.'); await ctx.refresh(); ctx.rerender(); });
          } }, 'Remove stored token') : null),
        tokenForm),
      h('section', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', null, 'Allowed domains'), help('fqdn', 'Domains')),
        arr(cf.config.domains).length ? h('p', null, arr(cf.config.domains).map((d) => plainChip(d.name, 'ok'))) : h('p', { class: 'muted' }, 'None yet.'),
        h('p', { class: 'muted small' }, 'Services can only be published under these domains. Change them in the setup journey, step 1.'), h('a', { href: '#setup/1' }, 'Change allowed domains')),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Account and tunnel'), help('cf-tunnel', 'Tunnel')),
        h('div', { class: 'grid' }, field({ id: 'cf-account', label: 'Account', control: acct }), field({ id: 'cf-tunnel', label: 'Tunnel', control: tun })),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', disabled: !t.Stored, onclick: (e) => load(e.currentTarget) }, 'Load from Cloudflare'),
          h('button', { type: 'button', class: 'btn primary', disabled: !t.Stored, onclick: (e) => withBusy(e.currentTarget, async () => {
            if (!acct.value || !tun.value) { toast('Load and choose an account and a tunnel first.', true); return; }
            s.cf = await api('POST', '/api/cloudflare/select', { accountId: acct.value, tunnelId: tun.value }); await ctx.refresh(); toast(`Using tunnel ${s.cf.config.tunnelName}.`); ctx.rerender();
          }) }, 'Use this account and tunnel')),
        h('div', { class: 'field' }, h('label', { for: 'cf-new-tunnel' }, 'New tunnel name'), h('div', { class: 'hostname-row' }, Object.assign(newName, { id: 'cf-new-tunnel' }),
          h('button', { type: 'button', class: 'btn', disabled: !t.Stored || !cf.config.accountId, onclick: async (e) => {
            const name = newName.value.trim();
            if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { toast('Tunnel name: letters, digits, dot, dash or underscore.', true); return; }
            const ok = await U.confirmDialog({ title: 'Create a Cloudflare tunnel', okText: 'Create tunnel', checkbox: 'Create this resource in my Cloudflare account', body: [h('p', null, 'Creates the remotely managed tunnel ', h('strong', null, name), ' in ', h('strong', null, cf.config.accountName || cf.config.accountId), '. Nothing else changes.')] });
            if (ok) await withBusy(e.currentTarget, async () => { s.cf = await api('POST', '/api/cloudflare/tunnel', { name, confirm: true }); await ctx.refresh(); toast(`Tunnel ${name} created.`); ctx.rerender(); });
          } }, 'Create tunnel…'))),
        gate('expert', kv([['Account id', cf.config.accountId], ['Tunnel id', cf.config.tunnelId], ['API endpoint', cf.apiBase]]))),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Connector (cloudflared)'), help('cloudflared', 'cloudflared')),
        h('div', { class: 'status-line' }, cf.config.tunnelId ? plainChip(`Tunnel: ${cf.config.tunnelName}`, 'info') : plainChip('No tunnel selected'),
          c.tokenFile ? chip('validated', 'Connector token installed') : plainChip('No connector token'), c.running ? chip('healthy', `${c.container} running`) : plainChip(`${c.container} not running`, 'warn')),
        h('p', { class: 'muted small' }, 'Downloads the selected tunnel\'s connector token into secrets\\cloudflare_tunnel_token and starts (or restarts) only this instance\'s cloudflared container.'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', disabled: !cf.config.tunnelId || !s.setup.installed, onclick: (e) => installConnector(ctx, cf, e.currentTarget) }, 'Install token and start cloudflared…')),
        h('div', { id: 'cf-connector-out' })),
      h('section', { class: 'card' }, h('h2', null, 'Created by this tool'), h('p', { class: 'muted small' }, 'Hostnames whose DNS record or Access application this tool created (and may clean up when the service is removed).'),
        managed.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('thead', null, h('tr', null, ['Hostname', 'Service', 'DNS record', 'Access app'].map((x) => h('th', { scope: 'col' }, x)))),
          h('tbody', null, managed.map((m) => h('tr', null, h('td', null, m.hostname), h('td', null, m.service), h('td', null, m.dns ? chip('applied', 'Created') : '—'), h('td', null, m.access ? chip('applied', 'Created') : '—')))))) : h('p', { class: 'muted' }, 'Nothing yet.')),
      h('section', { class: 'callout' }, h('h2', null, 'Streaming media'), h('p', null, 'Cloudflare restricts serving video or large non-HTML content through its proxy and tunnels unless you use a Cloudflare media product; uploads are capped at 100 MB on Free/Pro. Use the app\'s own remote access or a private network for heavy streaming.')));
  };
  async function installConnector(ctx, cf, button) {
    const ok = await U.confirmDialog({ title: 'Install the connector', okText: 'Install and start', body: [h('p', null, 'Downloads the connector token of tunnel ', h('strong', null, cf.config.tunnelName), ' and starts (or restarts) ', h('strong', null, cf.connector.container), '.'), 'No other container is touched.'] });
    if (!ok) return;
    const send = async (confirmReplace) => {
      try { return await api('POST', '/api/cloudflare/connector', { confirm: true, confirmReplace }); } catch (err) {
        if (err.status === 409 && err.data.needsConfirm === 'replace') { const again = await U.confirmDialog({ title: 'Replace the connector token?', body: 'A tunnel token is already installed. It is backed up and replaced, and cloudflared is restarted.', okText: 'Replace', danger: true }); return again ? send(true) : null; }
        throw err;
      }
    };
    await withBusy(button, async () => { const r = await send(false); if (!r) return; fill($('#cf-connector-out'), U.output([r.message, ...arr(r.output)])); toast(r.message, !r.ok); await ctx.refresh(); });
  }

  // --- Traefik Dashboard ------------------------------------------------------------------------------------------------------
  P.dashboard = async (main, ctx) => {
    const s = ctx.state;
    await ctx.refresh();
    const d = s.dashboard;
    if (!d || !d.installed) { fill(main, head('Operate', 'Traefik Dashboard', ''), notInstalled(ctx, 'The Traefik dashboard')); return; }
    const out = [head('Operate', 'Traefik Dashboard', 'Traefik\'s own page of routers, services and middlewares: the first end-to-end test of the deployment, independent of your apps.')];
    out.push(h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'On this PC'), help('traefik-dashboard', 'Dashboard')),
      h('p', null, ext(d.localUrl)), h('p', { class: 'muted small' }, 'Always available, 127.0.0.1 only, independent of Cloudflare.')));
    const pub = h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Public, behind Cloudflare Access'), help('cf-access', 'Cloudflare Access')));
    if (d.enabled) {
      pub.append(h('p', null, ext(d.publicUrl)), h('p', { class: 'muted small' }, 'Cloudflare asks for a login first; only /dashboard/ and /api are routed. Requests that did not pass Cloudflare Access get 404 from Traefik.'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn danger-outline', onclick: (e) => ctx.startDashboardPlan({ disable: true }, e.currentTarget) }, 'Remove public dashboard…')));
    } else if (!d.cloudflareReady) {
      pub.append(h('p', { class: 'muted' }, 'Publishing needs Cloudflare automation (API token with the Access permission, account and tunnel). It is always protected by a Cloudflare Access login; Turnstile is not a login and is never used instead.'));
    } else {
      const f = s.forms.pubdash || (s.forms.pubdash = { sub: d.subdomain, custom: d.subdomainCustom, zoneId: d.zoneId, emails: arr(d.accessEmails).join(', ') || d.contactEmail || '' });
      const sub = h('input', { value: f.sub, spellcheck: 'false', autocomplete: 'off', id: 'dash-sub-ops' });
      const tag = h('span', { class: 'auto-tag' }, f.custom ? 'edited' : 'automatic');
      sub.addEventListener('input', () => { f.sub = sub.value.trim().toLowerCase(); f.custom = f.sub !== d.defaultSubdomain; tag.textContent = f.custom ? 'edited' : 'automatic'; });
      const zone = h('select', { 'aria-label': 'Domain' }, arr(d.domains).map((z) => h('option', { value: z.id, selected: z.id === f.zoneId }, z.name)));
      zone.addEventListener('change', () => { f.zoneId = zone.value; });
      const emails = h('input', { value: f.emails, spellcheck: 'false', placeholder: 'you@example.com' });
      emails.addEventListener('input', () => { f.emails = emails.value; });
      pub.append(h('div', { class: 'field' }, h('label', { for: 'dash-sub-ops' }, 'Hostname ', tag), h('div', { class: 'hostname-row' }, sub, h('span', { class: 'sep' }, '.'), zone),
        h('p', { class: 'hint' }, `Suggested from the instance name. Uses tunnel "${d.tunnelName}".`)),
      field({ id: 'dash-emails-ops', label: 'Who may sign in', control: emails, hint: 'Used only if no Access application protects this hostname yet.' }),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', onclick: (e) => ctx.startDashboardPlan({ subdomain: f.sub, zoneId: f.zoneId, accessEmails: L.splitEmails(f.emails) }, e.currentTarget) }, 'Preview…')),
      h('p', { class: 'muted small' }, 'Fail closed: Cloudflare Access is created or confirmed first; only then are the route, tunnel route and DNS record added.'));
    }
    out.push(pub);
    const box = h('div', { id: 'dash-verify' }, s.verify ? window.TPMPages.renderVerification(ctx, s.verify) : null);
    out.push(h('section', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', null, 'Verification'), h('span', { class: 'grow' }),
      h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => { await window.TPMPages.runVerify(ctx); fill(box, window.TPMPages.renderVerification(ctx, s.verify)); }) }, icon('pulse'), 'Verify now')), box));
    fill(main, out);
  };

  // --- Backups --------------------------------------------------------------------------------------------------------------
  P.backups = async (main, ctx) => {
    const s = ctx.state;
    const r = s.backups = await api('GET', '/api/backups');
    const file = h('input', { type: 'file', accept: '.json,.zip,application/json,application/zip', id: 'import-file' });
    const emails = h('input', { spellcheck: 'false', placeholder: 'you@example.com', id: 'import-emails' });
    const importForm = h('form', { class: 'field' }, h('label', { for: 'import-file' }, 'Backup file'), h('div', { class: 'hostname-row' }, file, h('button', { type: 'submit', class: 'btn primary' }, icon('upload'), 'Preview restore')));
    importForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = file.files[0];
      if (!f) { toast('Choose a backup file first.', true); return; }
      if (f.size > 2 * 1024 * 1024) { toast('That file is larger than 2 MB; a configuration backup is much smaller.', true); return; }
      let contentBase64;
      try { contentBase64 = await readFileBase64(f); } catch (err) { toast(err.message, true); return; }
      await previewImport(ctx, { fileName: f.name, contentBase64 }, e.submitter);
    });
    s.forms.importEmails = () => L.splitEmails(emails.value);
    const rp = arr(r.recoveryPoints); const snaps = arr(r.backups);
    fill(main,
      head(ctx.installed() ? 'Operate' : 'Installation', 'Backups and restore', 'Move this configuration to another folder or PC, or back after a manager upgrade. Recovery points are made automatically before every change.'),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Export'), help('backups', 'Backups')),
        h('p', null, 'A versioned copy of this instance: settings, Docker names, Cloudflare account, zone, tunnel, DNS record and Access ids, hostnames, routes and services. Only this instance\'s folder is read.'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => U.download('/api/backups/export?format=json', 'traefik-proxy-config.json')) }, icon('download'), 'Export configuration (.json)'),
          h('button', { type: 'button', class: 'btn primary', onclick: (e) => withBusy(e.currentTarget, () => U.download('/api/backups/export?format=zip', 'traefik-proxy-backup.zip')) }, icon('download'), 'Download full backup (.zip)')),
        h('h4', null, 'Never exported (reconnect after a restore)'), h('ul', { class: 'checks' }, arr(r.credentials).map((c) => checkItem(c.present ? 'ok' : 'neutral', `${c.label} (${c.present ? 'present on this PC' : 'not stored here'})`, c.recover)))),
      h('section', { class: 'card' }, h('h2', null, 'Import and restore'),
        h('p', null, 'A .json or .zip made by this tool, or a config\\services.json from an earlier version. Checked first; you see a preview, then approve the local part and the Cloudflare part separately. Cloudflare ids are verified before they are reused.'),
        importForm, field({ id: 'import-emails', label: 'Access sign-in emails (optional)', control: emails, hint: 'Only used if an Access application has to be created again and the backup does not record who may sign in.' })),
      h('section', { class: 'card' }, h('h2', null, 'Recovery points'), h('p', { class: 'muted small' }, 'Written before each change; read-only and readable only by your Windows account and administrators.'),
        rp.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('thead', null, h('tr', null, ['Created', 'Before', 'Size', ''].map((x) => h('th', { scope: 'col' }, x || h('span', { class: 'sr-only' }, 'Actions'))))),
          h('tbody', null, rp.map((p) => h('tr', null, h('td', null, p.createdAt.replace('T', ' '), U.gateSpan('expert', h('div', { class: 'sub mono' }, p.id))), h('td', null, p.reason), h('td', null, L.formatBytes(p.bytes)),
            h('td', { class: 'actions-cell' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, () => U.download(`/api/backups/recovery/download?id=${encodeURIComponent(p.id)}`, p.id)) }, 'Download'),
              h('button', { type: 'button', class: 'btn small', onclick: (e) => previewImport(ctx, { recoveryId: p.id }, e.currentTarget) }, 'Preview restore'))))))) : h('p', { class: 'muted' }, 'No recovery points yet.')),
      gate('intermediate', h('section', { class: 'card' }, h('h2', null, 'Service snapshots'), h('p', { class: 'muted small' }, 'Every service change saves the previous routes and registry. Restoring a snapshot changes Traefik only, not Cloudflare.'),
        snaps.length ? h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('thead', null, h('tr', null, ['Snapshot', 'Created', 'Route files', ''].map((x) => h('th', { scope: 'col' }, x || h('span', { class: 'sr-only' }, 'Actions'))))),
          h('tbody', null, snaps.map((b) => h('tr', null, h('td', null, h('span', { class: 'mono' }, b.id), ' ', b.restored ? plainChip('Restored') : null, b.preRollback ? plainChip('Before a rollback', 'info') : null),
            h('td', null, b.createdAt), h('td', null, String(arr(b.files).length)), h('td', { class: 'actions-cell' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => previewSnapshot(ctx, b.id, e.currentTarget) }, 'Preview restore'))))))) : h('p', { class: 'muted' }, 'No snapshots yet.'))));
  };
  function readFileBase64(file) {
    return new Promise((resolve, reject) => { const r = new FileReader(); r.onload = () => { const x = String(r.result); resolve(x.slice(x.indexOf(',') + 1)); }; r.onerror = () => reject(new Error('The file could not be read.')); r.readAsDataURL(file); });
  }
  const importEmails = (ctx) => (ctx.state.forms.importEmails ? ctx.state.forms.importEmails() : []);
  async function previewImport(ctx, body, button) {
    await withBusy(button, async () => { const view = await api('POST', '/api/backups/import/preview', { ...body, accessEmails: importEmails(ctx) }); ctx.state.restore = view; renderRestore(ctx, view); U.openDialog($('#plan-dialog')); });
  }
  const ACTION = { create: ['Create', 'info'], update: ['Update', 'warn'], delete: ['Remove', 'err'], unchanged: ['No change', 'neutral'], keep: ['Kept', 'neutral'] };
  function renderRestore(ctx, view) {
    const src = view.source;
    $('#plan-title').textContent = `Restore ${src.fileName}`;
    const content = clear($('#plan-content'));
    const res = view.result;
    if (res) content.append(h('div', { class: `callout ${res.ok ? 'ok' : 'err'}`, role: 'status' }, h('p', null, h('strong', null, `${res.part === 'local' ? 'Local configuration' : 'Cloudflare'}: ${res.ok ? 'applied' : 'not completed'}.`), res.recoveryPoint ? ` Recovery point ${res.recoveryPoint} was written first.` : ''),
      h('ul', { class: 'checks' }, arr(res.steps).map((x) => checkItem({ Done: 'ok', Failed: 'err', Warning: 'warn', Skipped: 'warn' }[x.status] || 'neutral', x.name, x.message)))));
    content.append(h('p', { class: 'muted small' }, `Into ${src.installPath}.`, U.gateSpan('expert', ` sha256 ${src.sha256}`)), h('div', null, ctx.reviewList(view.review)));
    const local = view.local;
    const ls = h('section', null, h('h3', null, icon('monitor'), ' Part 1: local configuration (this PC)'));
    for (const e of arr(local.errors)) ls.append(h('p', { class: 'form-error' }, e));
    for (const i of arr(local.items)) {
      const [t, k] = ACTION[i.action] || [i.action, 'neutral'];
      ls.append(h('div', { class: 'file-head' }, plainChip(t, k), h('span', null, i.summary)));
      if (i.detail) ls.append(h('p', { class: 'hint' }, i.detail));
      if (arr(i.diff).length && i.action !== 'unchanged') ls.append(gate('intermediate', U.diffBlock(i.diff)));
    }
    ls.append(h('p', { class: 'muted small' }, 'Writes configuration files and reloads Traefik if it runs. No container is started or recreated; credentials are not touched.'));
    content.append(ls);
    const cf = view.cloudflare;
    const cs = h('section', null, h('h3', null, icon('cloud'), ' Part 2: Cloudflare'));
    if (cf.message) cs.append(h('p', { class: 'muted' }, cf.message));
    for (const n of arr(cf.notes)) cs.append(h('p', { class: 'muted' }, n));
    for (const e of arr(cf.errors)) cs.append(h('p', { class: 'form-error' }, e));
    if (arr(cf.actions).length) cs.append(ctx.cloudflareActionList(cf.actions, 'restore-overwrite'));
    else if (cf.connected) cs.append(h('p', { class: 'muted' }, 'Everything recorded in the backup already exists in Cloudflare.'));
    cs.append(h('p', { class: 'muted small' }, 'Existing resources are reused, never duplicated; an existing DNS record is only replaced after you tick its box; tunnels are never recreated.'));
    content.append(cs);
    const foot = clear($('#plan-foot'));
    const okLocal = h('input', { type: 'checkbox' }); const goLocal = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Apply local configuration');
    okLocal.addEventListener('change', () => { goLocal.disabled = !okLocal.checked; });
    goLocal.addEventListener('click', () => applyRestore(ctx, 'local', goLocal));
    const okCf = h('input', { type: 'checkbox' }); const goCf = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Apply Cloudflare changes');
    const syncCf = () => { goCf.disabled = !(okCf.checked && $$('.restore-overwrite', content).every((b) => b.checked)); };
    okCf.addEventListener('change', syncCf); $$('.restore-overwrite', content).forEach((b) => b.addEventListener('change', syncCf));
    goCf.addEventListener('click', () => applyRestore(ctx, 'cloudflare', goCf));
    if (local.canApply) foot.append(h('label', { class: 'check grow' }, okLocal, h('span', null, 'I approve the local changes in part 1')), goLocal);
    if (cf.canApply && !cf.needsLocal) foot.append(h('label', { class: 'check grow' }, okCf, h('span', null, 'I approve the Cloudflare changes in part 2')), goCf);
    else if (cf.canApply) foot.append(h('span', { class: 'grow muted' }, 'Part 2 becomes available after part 1.'));
    if (!local.canApply && !cf.canApply) foot.append(h('span', { class: 'grow muted' }, local.hasWork || cf.hasWork ? 'Resolve the problems above, then preview again.' : 'Nothing to restore: this instance already matches the backup.'));
    foot.append(h('button', { type: 'button', class: 'btn', 'data-close': true }, 'Close'));
  }
  async function applyRestore(ctx, part, button) {
    const view = ctx.state.restore;
    const overwrites = $$('.restore-overwrite:checked', $('#plan-content')).map((b) => b.dataset.id);
    await withBusy(button, async () => {
      try {
        const next = await api('POST', '/api/backups/import/apply', { importId: view.importId, part, confirm: true, confirmOverwrites: overwrites, accessEmails: importEmails(ctx) });
        ctx.state.restore = next; renderRestore(ctx, next);
        toast(next.result.ok ? `${part === 'local' ? 'Local configuration' : 'Cloudflare'} restored.` : 'The restore did not complete; see the details.', !next.result.ok);
      } finally { await ctx.refresh().catch(() => {}); }
    });
  }
  async function previewSnapshot(ctx, id, button) {
    await withBusy(button, async () => {
      const p = await api('POST', '/api/backups/preview', { id });
      $('#plan-title').textContent = `Restore snapshot ${id}`;
      fill($('#plan-content'), h('p', { class: 'muted' }, p.note), arr(p.changes).length ? null : h('p', null, 'The current configuration already matches this snapshot.'),
        arr(p.changes).map((c) => [h('div', { class: 'file-head' }, plainChip(c.action, c.action === 'remove' ? 'err' : 'warn'), h('span', { class: 'mono' }, c.file)), U.diffBlock(c.diff)]));
      const foot = clear($('#plan-foot'));
      const box = h('input', { type: 'checkbox' }); const go = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Restore');
      box.addEventListener('change', () => { go.disabled = !box.checked; });
      go.addEventListener('click', () => withBusy(go, async () => { const r = await api('POST', '/api/backups/restore', { id, confirm: true }); $('#plan-dialog').close(); toast(`Restored ${r.restored}. The previous state was saved as ${r.savedCurrentAs}.`); ctx.rerender(); }));
      foot.append(h('label', { class: 'check grow' }, box, h('span', null, 'Restore this snapshot (the current state is saved first)')), h('button', { type: 'button', class: 'btn', 'data-close': true }, 'Cancel'), go);
      U.openDialog($('#plan-dialog'));
    });
  }

  // --- Diagnostics ------------------------------------------------------------------------------------------------------------
  P.diagnostics = async (main, ctx) => {
    const s = ctx.state;
    const out = (id) => h('div', { id });
    const role = h('select', { id: 'logs-role' }, ['traefik', 'cloudflared', 'socket-proxy'].map((r) => h('option', { value: r }, r)));
    const tail = h('select', { id: 'logs-tail' }, ['100', '200', '500', '1000'].map((n) => h('option', { value: n, selected: n === '200' }, n)));
    const validate = (deep) => (e) => withBusy(e.currentTarget, async () => {
      const r = await api('POST', '/api/validate', { deep });
      if (r.installed === false) { fill($('#validate-out'), h('p', { class: 'muted' }, r.message)); return; }
      const items = arr(r.issues).map((i) => checkItem(i.Level === 'Error' ? 'err' : 'warn', `${i.Service}: ${i.Level}`, i.Message));
      if (r.drift > 0) items.push(checkItem('warn', 'Route files', `${r.drift} file(s) differ from config\\services.json.`));
      if (r.deep) { arr(r.deep.Errors).forEach((x) => items.push(checkItem('err', 'Traefik', x))); arr(r.deep.Warnings).forEach((x) => items.push(checkItem('warn', 'Traefik', x))); }
      items.unshift(checkItem(r.ok ? 'ok' : 'err', r.ok ? 'Configuration is valid' : 'Configuration has errors', deep ? 'Including a load into a throwaway, network-less Traefik container.' : 'Built-in checks.'));
      fill($('#validate-out'), h('ul', { class: 'checks' }, items), r.deep ? technical(arr(r.deep.Routers).map((x) => `${x.Name}  ${x.Status}  ${x.Rule}`), 'Routers loaded by the validator', 'advanced') : null);
    });
    fill(main,
      head(ctx.installed() ? 'Operate' : 'Installation', 'Diagnostics', 'Logs, validation and a shareable report. Tokens are redacted everywhere.'),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Validate the configuration'), help('http-errors', 'Errors')),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: validate(false) }, 'Validate'), h('button', { type: 'button', class: 'btn', onclick: validate(true) }, 'Deep validate')), out('validate-out')),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Container logs'), help('reading-logs', 'Logs')),
        h('div', { class: 'grid' }, field({ id: 'logs-role', label: 'Container', control: role }), field({ id: 'logs-tail', label: 'Lines', control: tail })),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('GET', `/api/logs?role=${encodeURIComponent(role.value)}&tail=${encodeURIComponent(tail.value)}`);
          const o = U.output(arr(r.Lines).length ? r.Lines : [r.Ok ? '(no log lines)' : `Container ${r.Container} not found.`], 'Container log');
          fill($('#logs-out'), o); o.scrollTop = o.scrollHeight;
        }) }, 'Show')), out('logs-out')),
      h('section', { class: 'card' }, h('h2', null, 'Diagnostics report'), h('p', { class: 'muted small' }, 'Read-only report of Docker, the stack, routes and recent logs. Safe to share.'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('POST', '/api/diagnostics', {});
          const o = U.output(r.lines, 'Diagnostics report');
          fill($('#diag-out'), h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small', onclick: async () => { try { await navigator.clipboard.writeText(o.textContent); toast('Copied.'); } catch (err) { toast('Copy failed; select the text instead.', true); } } }, 'Copy')), o);
        }) }, 'Run diagnostics')), out('diag-out')),
      h('section', { class: 'card' }, h('h2', null, 'Activity log'), h('p', { class: 'muted small' }, 'Changes made through this interface (logs\\webui-audit.log).'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => { const r = await api('GET', '/api/audit'); fill($('#audit-out'), U.output(arr(r.lines).length ? r.lines : ['No activity yet.'], 'Activity log')); }) }, 'Show activity')), out('audit-out')),
      gate('expert', h('section', { class: 'card' }, h('h2', null, 'Generated configuration'), h('p', { class: 'muted small' }, 'Every non-secret file this instance uses, and the exact commands. Anything credential-like is withheld.'),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
          const x = s.expert = await api('GET', '/api/expert/config');
          fill($('#expert-out'), h('h4', null, 'Commands'), arr(x.commands).map((c) => [h('p', { class: 'small muted' }, c.purpose), U.output([c.command], c.purpose)]),
            h('h4', null, 'Images, containers, networks'), U.output([JSON.stringify({ images: x.images, containers: x.containers, networks: x.networks }, null, 2)], 'Docker'),
            h('h4', null, 'Files'), arr(x.files).map((f) => h('details', { class: 'tech' }, h('summary', null, f.path), U.output(String(f.content).split('\n'), f.path))));
        }) }, 'Show generated configuration')), out('expert-out'))));
  };

  // --- Settings ------------------------------------------------------------------------------------------------------------------
  P.settings = async (main, ctx) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    const setup = s.setup; const v = setup.settings;
    const levelText = { beginner: 'Essential settings, plain explanations, recommended defaults. Network details are tucked away.', intermediate: 'Adds ports, addresses, tunnel summaries and diagnostics summaries.',
      advanced: 'Adds Docker networks, subnets, static addresses, DNS records and Traefik routers.', expert: 'Everything: generated files, exact commands, raw results and identifiers.' };
    const levels = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Detail level' }, L.LEVELS.map((lv) => h('label', { class: 'choice' },
      h('input', { type: 'radio', name: 'settings-level', value: lv, checked: U.getLevel() === lv, onchange: () => U.setLevel(lv) }), h('strong', null, L.LEVEL_TITLES[lv]), h('span', { class: 'small muted' }, levelText[lv]))));
    const themes = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Theme' }, [['dark', 'Dark'], ['light', 'Light'], ['system', 'Follow Windows']].map(([t, label]) => h('label', { class: 'choice' },
      h('input', { type: 'radio', name: 'settings-theme', value: t, checked: U.getTheme() === t, onchange: () => U.setTheme(t) }), h('strong', null, label))));
    fill(main,
      head(setup.installed ? 'Operate' : 'Installation', 'Settings', 'Presentation preferences (stored in this browser only) and this instance\'s configuration.'),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Detail level'), help('detail-levels', 'Detail levels')), levels,
        h('p', { class: 'muted small' }, 'Changes only what is shown. It never changes what is allowed, how changes are validated, or anything on the server.')),
      h('section', { class: 'card' }, h('h2', null, 'Theme'), themes),
      h('section', { class: 'card' }, h('h2', null, 'This instance'), kv([
        ['Install folder', setup.installPath], ['Program folder', setup.sourcePath, 'intermediate'], ['Instance', v.STACK_NAME], ['Installed', setup.installed ? setup.installedAt || 'yes' : 'not yet'],
        ['Ports (127.0.0.1)', `${v.TRAEFIK_HTTP_PORT} (apps), ${v.TRAEFIK_DASHBOARD_PORT} (dashboard)`, 'intermediate'], ['Shared network', v.PROXY_NETWORK, 'advanced'],
        ['Tunnel subnet', `${v.TUNNEL_SUBNET} · range ${v.TUNNEL_IP_RANGE} · cloudflared ${v.CLOUDFLARED_IP}`, 'advanced'], ['Ingress', setup.deployment.mode || 'not chosen'], ['Contact email', setup.contactEmail || '—']]),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: () => ctx.navigate('setup') }, icon('rocket'), 'Open the setup journey')),
        setup.installed ? h('p', { class: 'muted small' }, 'Instance settings are read-only after installation: edit .env in the install folder and re-run the installer, or install a second instance in another folder.') : null),
      h('section', { class: 'card', 'data-help-host': '' }, h('div', { class: 'card-head' }, h('h2', null, 'Upgrading this tool'), help('updating', 'Updating')),
        h('ol', null, h('li', null, 'Download a full backup on the Backups page.'), h('li', null, 'Update the program folder (git pull or a new release).'),
          h('li', null, 'See what would change (nothing is written):'), h('li', null, 'Update the files without restarting containers:')),
        U.output([`powershell -ExecutionPolicy Bypass -File "${setup.sourcePath}\\install.ps1" -InstallPath "${setup.installPath}" -DryRun`, `powershell -ExecutionPolicy Bypass -File "${setup.sourcePath}\\install.ps1" -InstallPath "${setup.installPath}"`], 'Upgrade commands'),
        h('p', { class: 'muted small' }, 'Your settings, services and Cloudflare configuration are kept; you do not repeat the onboarding.'),
        setup.installed ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => window.TPMPages.previewUpgrade(ctx, setup.installPath, e.currentTarget) }, icon('download'), 'Preview upgrade from this manager')) : null),
      h('section', { class: 'card' }, h('h2', null, 'The manager itself'),
        h('p', { class: 'muted small' }, 'This website runs on this PC only. Stopping it does not stop your deployments: Traefik, cloudflared and your apps keep running.'),
        ctx.state.session.canStop ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn danger-outline', onclick: async (e) => {
          const ok = await U.confirmDialog({ title: 'Stop the manager?', body: 'The website stops. Your deployments keep running. Start it again with START-HERE.cmd.', okText: 'Stop the manager', danger: true });
          if (ok) await withBusy(e.currentTarget, async () => { await api('POST', '/api/manager/stop', { confirm: true }); fill(main, h('div', { class: 'callout' }, h('h1', null, 'The manager has stopped.'), h('p', null, 'You can close this tab. Double-click START-HERE.cmd to start it again.'))); });
        } }, 'Stop the manager')) : h('p', { class: 'small' }, 'To stop it, close its PowerShell window or press Ctrl+C there. Started with START-HERE.cmd, it can also be stopped here or with STOP-MANAGER.cmd.')));
  };

  // --- Help and Learning -----------------------------------------------------------------------------------------------------
  P.help = async (main, ctx, sub) => {
    const cat = U.catalog;
    const search = h('input', { type: 'search', placeholder: 'Search topics', 'aria-label': 'Search topics', id: 'help-search' });
    const results = h('div');
    const draw = () => {
      const q = search.value.trim().toLowerCase();
      const topics = cat.topics.filter((t) => !q || `${t.title} ${t.summary}`.toLowerCase().includes(q));
      fill(results, cat.categories.map((c) => {
        const list = topics.filter((t) => t.category === c.id);
        if (!list.length) return null;
        return h('section', null, h('h2', null, c.title), h('div', { class: 'learn-grid' }, list.map((t) => h('article', { class: 'learn-card', id: `topic-${t.id}` },
          h('h3', null, t.title), h('p', null, arr(t.levels).map((lv) => plainChip(L.LEVEL_TITLES[lv] || lv)), ' '), h('p', null, t.summary), U.topicLinks(t)))));
      }), topics.length ? null : h('p', { class: 'muted' }, 'No topic matches.'));
    };
    search.addEventListener('input', draw);
    fill(main, head(ctx.installed() ? 'Operate' : 'Installation', 'Help and Learning', 'Short explanations of the concepts behind this tool, with links to official documentation. The same explanations open from the ? buttons next to fields.'),
      h('div', { class: 'field' }, search), results,
      gate('advanced', h('p', { class: 'muted small' }, 'The catalog (webui\\learn.json) uses stable topic ids, so links can later point to a separate learning site without changes to this application.')));
    draw();
    if (sub) { const el = $(`#topic-${CSS.escape(sub)}`); if (el) { el.scrollIntoView({ block: 'center' }); el.classList.add('focus'); el.setAttribute('tabindex', '-1'); el.focus(); } }
  };
})();
