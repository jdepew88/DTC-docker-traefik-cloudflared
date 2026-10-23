'use strict';
// The backend part of the Add Service / Edit Service form: "Where is your application running?", then the address
// Traefik will use from inside Docker, explained and verified. The server's resolver (POST /api/services/backend)
// recommends the address from what runs on this engine and what the user typed; a connection test runs from Traefik's
// own network. Detail levels change what is shown, never what is sent.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { h, arr, fill, icon, plainChip, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});

  const WHERE_TEXT = {
    docker: ['In a Docker container', 'box', 'An app in a container on this computer\'s Docker.'],
    'this-computer': ['On this computer', 'monitor', 'An app installed directly on Windows.'],
    lan: ['On another computer or device on my network', 'server', 'A NAS, media server, camera or another PC.'],
  };
  const EXPLAIN = {
    docker: 'Traefik reaches an app in Docker by its container name and the port the app listens on inside the container. No Windows address is involved.',
    'this-computer': 'Traefik runs inside Docker. It reaches apps on Windows through the Docker host address (host.docker.internal), never 127.0.0.1, which inside Docker means Traefik itself.',
    lan: 'Traefik uses the other device\'s own address, exactly as you enter it.',
  };
  const VIA = { docker: 'Docker network', host: 'Docker host address', lan: 'Your network (LAN)' };

  // State lives in the service form object f: where, container, address, port, protocol, touched, override, custom,
  // backend (last resolver answer), verification, target (what is saved), source, dismissed.
  P.initBackendState = (f, sv) => {
    f.where = sv ? L.whereFromTargetType(sv.target.type) : 'docker';
    f.container = sv && sv.target.type === 'docker' ? sv.target.host : '';
    f.address = sv && sv.target.type === 'lan' ? sv.target.host : '';
    f.port = sv ? String(sv.target.port) : '';
    f.protocol = sv ? sv.target.protocol : 'http';
    f.touched = { protocol: !!sv };
    f.override = false; f.custom = '';
    f.backend = null; f.verification = null; f.dismissed = {};
    f.target = sv ? { type: sv.target.type, host: sv.target.host, port: Number(sv.target.port), protocol: sv.target.protocol, url: `${sv.target.protocol}://${sv.target.host}:${sv.target.port}` } : null;
    f.source = sv ? 'existing' : '';
  };

  function requestBody(f, extra) {
    const typed = f.where === 'docker' ? f.container : f.address;
    return { location: f.where, address: f.override ? f.custom : typed, port: f.port, protocol: f.touched.protocol ? f.protocol : '', container: f.where === 'docker' ? f.container : '',
      override: !!(f.override && f.custom), hostname: f.hostname || '', ...extra };
  }

  // Builds the section once per form render; refresh() re-renders only the result panel (inputs keep their focus).
  P.backendSection = (ctx, f, opts = {}) => {
    const panel = h('div', { class: 'backend-box', id: 'svc-backend', 'aria-live': 'polite' });
    let seq = 0; let timer = null;
    const resolve = async (test = false, btn = null) => {
      const my = ++seq;
      const hadContainers = !!(f.backend && arr(f.backend.containers).length);
      f.resolvedKey = JSON.stringify(requestBody(f));
      const body = requestBody(f, test && f.target ? { test: true, target: { type: f.target.type, host: f.target.host, port: f.target.port, protocol: f.touched.protocol ? f.protocol : f.target.protocol, tlsSkipVerify: !!f.tls } } : {});
      f.busy = test ? 'test' : 'resolve'; draw();
      const run = async () => {
        try {
          const r = await api('POST', '/api/services/backend', body);
          if (my !== seq) return;
          f.backend = r;
          const pick = L.chooseBackend({ source: f.source, target: f.target, override: f.override && f.custom }, r.resolution);
          if (!L.sameTarget(pick.target, f.target)) f.verification = null;
          f.target = pick.target; f.source = pick.source; f.needsChoice = pick.needsChoice;
          if (f.target && !f.touched.protocol) f.protocol = f.target.protocol;
          if (opts.onTarget) opts.onTarget();
          if (r.verification) f.verification = r.verification;
          f.error = '';
          // The container list arrives with the first answer: the inputs above are drawn again once.
          if (!hadContainers && f.where === 'docker' && arr(r.containers).length && opts.onContainers) { f.busy = ''; opts.onContainers(); return; }
        } catch (e) { if (my === seq) f.error = e.message; }
        finally { if (my === seq) { f.busy = ''; draw(); } }
      };
      return btn ? withBusy(btn, run) : run();
    };
    const schedule = () => { clearTimeout(timer); timer = setTimeout(() => resolve(false), 500); };
    const useTarget = (cand) => {
      f.target = { type: cand.type, host: cand.host, port: cand.port, protocol: cand.protocol, url: cand.url };
      f.source = 'chosen'; f.needsChoice = false; f.verification = null;
      if (!f.touched.protocol) f.protocol = cand.protocol;
      // The guidance that offered this choice is settled.
      for (const g of arr(f.backend && f.backend.resolution.guidance)) if (g.action === 'use-recommended') f.dismissed[g.condition] = true;
      if (opts.onTarget) opts.onTarget();
      draw();
      resolve(true);
    };

    function guidanceNode(g, rec) {
      const tone = g.severity === 'error' ? 'err' : g.severity === 'warn' ? 'warn' : '';
      return h('div', { class: `callout ${tone} guidance`, role: g.severity === 'error' ? 'alert' : 'note', 'data-guidance': g.id },
        h('p', null, h('strong', null, g.title)), h('p', null, g.text),
        h('div', { class: 'actions' },
          g.action === 'use-recommended' && rec && !L.sameTarget(rec, f.target) ? h('button', { type: 'button', class: 'btn small primary', onclick: () => useTarget(rec) }, icon('check'), 'Use recommended address') : null,
          g.severity !== 'error' ? h('button', { type: 'button', class: 'btn small ghost', 'aria-label': `Dismiss: ${g.title}`, onclick: () => { f.dismissed[g.condition] = true; draw(); } }, 'Dismiss') : null));
    }

    function draw() {
      const r = f.backend;
      const res = r ? r.resolution : null;
      const rec = res ? (res.suggested || res.recommended) : null;
      const st = L.backendStatus(f.verification);
      const target = f.target;
      const where = f.where;
      const plain = target ? (where === 'docker' ? `Traefik will reach ${f.display || 'the app'} inside Docker, as ${target.host}.`
        : target.type === 'host' ? `Traefik will reach ${f.display || 'the app'} on this computer through Docker's host address.`
          : `Traefik will reach ${f.display || 'the app'} at ${target.host} on your network.`) : '';
      const cands = res ? arr(res.candidates) : [];
      const usable = cands.filter((c) => !c.rejected);
      const container = r && f.where === 'docker' ? arr(r.containers).find((c) => c.name === (res && res.container ? res.container : f.container)) : null;
      const env = r ? r.environment : null;
      fill(panel,
        h('h3', null, icon('route'), ' Backend Traefik will use'),
        h('p', { class: 'small muted', 'data-min-level': 'beginner' }, EXPLAIN[where]),
        f.error ? h('div', { class: 'callout err', role: 'alert' }, h('p', null, f.error)) : null,
        f.busy === 'resolve' && !res ? h('p', { class: 'muted small' }, 'Looking at Docker and this computer…') : null,
        res ? L.visibleGuidance(res.guidance, f.dismissed).map((g) => guidanceNode(g, rec)) : null,
        // Several possible paths: the options, never a silent pick.
        usable.length > 1 || (f.needsChoice && usable.length) ? h('fieldset', { class: 'cand-list' }, h('legend', null, f.needsChoice ? 'Choose how Traefik reaches it' : 'Possible backends'),
          usable.map((c, i) => h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'svc-cand', value: String(i), checked: L.sameTarget(c, target), onchange: () => useTarget(c) }),
            h('strong', { class: 'mono' }, c.url), h('span', { class: 'small muted' }, c.reason)))) : null,
        target ? h('div', { class: 'backend-result' },
          U.beginnerOnly(h('p', null, plain)),
          h('div', { 'data-min-level': 'intermediate' }, kv([
            ['Recommended backend', h('span', { class: 'mono' }, rec ? rec.url : target.url || `${target.protocol}://${target.host}:${target.port}`)],
            ['Traefik will use', h('span', { class: 'mono' }, `${f.touched.protocol ? f.protocol : target.protocol}://${target.host}:${target.port}`)],
            ['Application port', String(target.port)],
            ['Connection type', target.type === 'docker' ? `${VIA.docker}${container && container.networks.length ? ` (${container.networks.filter((n) => env && arr(env.traefikNetworks).includes(n.name)).map((n) => n.name).join(', ') || 'not shared with Traefik'})` : ''}` : VIA[target.type]],
            ['Connection status', h('span', null, plainChip(st.label, st.tone), f.verification && f.verification.testedAt ? h('span', { class: 'small muted' }, ` ${String(f.verification.testedAt).replace('T', ' ')}`) : null)],
          ])),
          h('div', { 'data-only-level': 'beginner' }, h('p', null, plainChip(st.label, st.tone))),
          f.verification ? h('p', { class: `small ${st.tone === 'err' ? 'form-error' : ''}` }, f.verification.message) : h('p', { class: 'small muted' }, 'Not tested yet: Test connection sends one request from Traefik\'s network.'),
          f.source === 'existing' && rec && !L.sameTarget(rec, target) ? h('p', { class: 'small' }, 'This is the saved backend. It changes only if you choose another one.') : null)
          : res && !f.needsChoice ? h('p', { class: 'muted small' }, where === 'docker' ? 'Choose the container and its port.' : 'Enter the address and port.') : null,
        h('div', { class: 'actions' },
          rec && target && !L.sameTarget(rec, target) && !L.visibleGuidance(res.guidance, f.dismissed).some((g) => g.action === 'use-recommended') ? h('button', { type: 'button', class: 'btn small', onclick: () => useTarget(rec) }, icon('check'), 'Use recommended address') : null,
          target ? h('button', { type: 'button', class: 'btn small', 'aria-busy': f.busy === 'test' ? 'true' : null, onclick: (e) => resolve(true, e.currentTarget) }, icon('pulse'), f.busy === 'test' ? 'Testing…' : 'Test connection') : null,
          h('button', { type: 'button', class: 'btn small ghost', 'aria-expanded': String(!!f.showDiag), 'aria-controls': 'svc-backend-diag', onclick: () => { f.showDiag = !f.showDiag; draw(); } }, icon('info'), f.showDiag ? 'Hide diagnostic details' : 'View diagnostic details')),
        f.showDiag && res ? h('div', { id: 'svc-backend-diag', class: 'diag' },
          h('h4', null, 'Why this address'), h('ul', { class: 'checks' }, arr(res.evidence).map((e) => checkItem('neutral', e))),
          cands.length ? gate('advanced', h('h4', null, 'Candidates'), h('ul', { class: 'checks' }, cands.map((c) => checkItem(c.rejected ? 'err' : L.sameTarget(c, target) ? 'ok' : 'neutral', c.url, `${c.reason}${c.rejected ? ' (rejected)' : ''}`)))) : null,
          // Advanced: networks, aliases, gateway, internal versus published ports.
          gate('advanced', h('h4', null, 'Networking'), kv([
            ['Docker host', env ? `${env.adapter.name}` : '—'],
            ['Host gateway', env ? `${env.hostGateway} — ${env.hostGatewayVerified === true ? 'resolves inside Traefik' : env.hostGatewayVerified === false ? 'does not resolve inside Traefik' : 'not checked'}` : '—'],
            ['Traefik\'s networks', env ? arr(env.traefikNetworks).join(', ') : '—'],
            ...(container ? [['Container networks', container.networks.map((n) => `${n.name}: ${[n.name === 'bridge' ? null : container.name, ...arr(n.aliases).filter((a) => a !== container.name)].filter(Boolean).join(', ')}`).join(' · ')],
              ['Ports (inside → published)', arr(container.ports).map((p) => `${p.port}/${p.proto}${p.hostPort ? ` → ${p.hostIp || '0.0.0.0'}:${p.hostPort}` : ''}`).join(', ') || '—']] : []),
          ])),
          // Expert: exact URL, addresses, network identities and subnets, generated service, redacted test output.
          gate('expert', h('h4', null, 'Exact configuration'), kv([
            ['Exact backend URL', target ? h('code', null, `${f.touched.protocol ? f.protocol : target.protocol}://${target.host}:${target.port}`) : '—'],
            ...(container ? [['Container addresses', container.networks.map((n) => `${n.name} ${n.ipv4 || '—'}`).join(' · ')]] : []),
            ['Network identities', env ? Object.entries(env.traefikNetworkIds || {}).map(([k, v]) => `${k} ${v}`).join(' · ') : '—'],
            ['Docker subnets', env ? arr(env.dockerSubnets).map((n) => `${n.name} ${n.subnet}`).join(' · ') : '—'],
            ['This computer\'s IPv4', env ? arr(env.localAddresses).join(', ') : '—'],
          ]),
          r.traefikYaml ? technical(r.traefikYaml.split('\n'), 'Generated Traefik service (preview)') : null,
          f.verification && arr(f.verification.evidence).length ? technical(arr(f.verification.evidence), 'Connection test output (redacted)') : null)) : null);
    }

    const api2 = { node: panel, refresh: draw, resolve, schedule };
    draw();
    // A form drawn again with unchanged inputs keeps the last answer instead of asking again.
    if (!f.backend || f.resolvedKey !== JSON.stringify(requestBody(f))) resolve(false);
    return api2;
  };

  // The location question and the inputs that belong to it. Changing the location keeps advanced settings (protocol,
  // custom address) and asks the resolver again.
  P.backendInputs = (ctx, f, section, rerender) => {
    const net = ctx.state.status.instance.proxyNetwork;
    const where = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': 'Where is your application running?' }, L.WHERE.map((k) => {
      const [title, ic, text] = WHERE_TEXT[k];
      return h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'svc-where', value: k, checked: f.where === k,
        onchange: () => { f.where = k; if (f.source !== 'override') { f.source = ''; f.target = null; } f.verification = null; f.backend = null; rerender(); } }),
      h('strong', null, icon(ic), ' ', title), h('span', { class: 'small muted' }, text));
    }));
    const changed = () => { if (f.source !== 'override') { f.source = ''; } f.verification = null; section.schedule(); };
    const port = h('input', { value: f.port, inputmode: 'numeric', autocomplete: 'off', placeholder: f.where === 'docker' ? '3001' : f.where === 'lan' ? '32400' : '4119' });
    port.addEventListener('input', () => { f.port = port.value.trim(); changed(); });
    let first;
    if (f.where === 'docker') {
      const list = f.backend ? arr(f.backend.containers) : [];
      const sel = h('select', null, h('option', { value: '' }, list.length ? 'Choose a container…' : 'Reading Docker…'),
        list.map((c) => h('option', { value: c.name, selected: c.name === f.container, disabled: c.private }, `${c.name}${c.private ? ' (database or cache: stays private)' : c.sharesTraefikNetwork ? '' : ` (not on ${net})`}`)),
        f.container && !list.some((c) => c.name === f.container) ? h('option', { value: f.container, selected: true }, f.container) : null);
      sel.addEventListener('change', () => {
        f.container = sel.value;
        const c = list.find((x) => x.name === f.container);
        const best = c ? L.choosePort(c.ports) : null;
        if (best && !f.portTouched) { f.port = String(best.port); port.value = f.port; }
        changed();
      });
      port.addEventListener('input', () => { f.portTouched = true; });
      const name = h('input', { value: f.container, autocomplete: 'off', spellcheck: 'false', placeholder: 'uptime-kuma' });
      name.addEventListener('input', () => { f.container = name.value.trim(); changed(); });
      first = h('div', { class: 'grid' },
        field({ id: 'svc-container', label: 'Container', control: sel, hint: `Containers on ${net} are reached by name.` }),
        field({ id: 'svc-container-name', label: 'Container name or network alias', control: name, minLevel: 'advanced' }),
        field({ id: 'svc-port', label: 'Port inside the container', control: port, hint: 'The port the app listens on inside its container, not a port published on Windows.' }));
    } else {
      const addr = h('input', { value: f.address, autocomplete: 'off', spellcheck: 'false', placeholder: f.where === 'lan' ? '10.10.0.8' : '127.0.0.1:4119 or just 4119' });
      addr.addEventListener('input', () => {
        f.address = addr.value.trim();
        const p = L.parseBackendAddress(f.address);
        if (p.port && !f.portTouched) { f.port = String(p.port); port.value = f.port; }
        changed();
      });
      port.addEventListener('input', () => { f.portTouched = true; });
      first = h('div', { class: 'grid' },
        field({ id: 'svc-address', label: f.where === 'lan' ? 'Device address' : 'Address you use on this computer (optional)', control: addr,
          hint: f.where === 'lan' ? 'Its IP address or DNS name.' : 'Paste what you open in the browser, e.g. http://127.0.0.1:4119. Only the port matters.' }),
        field({ id: 'svc-port', label: 'Port', control: port }));
    }
    const proto = h('select', null, [['http', 'http'], ['https', 'https'], ['h2c', 'h2c (gRPC, cleartext)']].map(([v, t]) => h('option', { value: v, selected: f.protocol === v }, t)));
    proto.addEventListener('change', () => { f.protocol = proto.value; f.touched.protocol = true; f.verification = null; rerender(); });
    const customOn = h('input', { type: 'checkbox', checked: f.override });
    const custom = h('input', { value: f.custom, autocomplete: 'off', spellcheck: 'false', placeholder: 'http://10.10.0.8:32400', disabled: !f.override });
    customOn.addEventListener('change', () => { f.override = customOn.checked; custom.disabled = !f.override; if (!f.override && f.source === 'override') { f.source = ''; f.target = null; } section.schedule(); });
    custom.addEventListener('input', () => { f.custom = custom.value.trim(); f.source = f.override && f.custom ? 'override' : f.source; section.schedule(); });
    return h('div', null,
      h('div', { class: 'field', 'data-help-host': '' }, h('span', { class: 'label' }, 'Where is your application running? ', U.help('container-dns', 'Container names')), where),
      first,
      gate('advanced', h('div', { class: 'grid' },
        field({ id: 'svc-protocol', label: 'Protocol to the app', control: proto, helpId: 'ports-protocols', hint: 'Usually http: Cloudflare already encrypts the public side, and Traefik talks to the app inside your network.' }),
        h('div', { class: 'field' }, h('label', { class: 'check' }, customOn, h('span', null, 'Use a custom backend address')),
          Object.assign(custom, { id: 'svc-custom', 'aria-label': 'Custom backend address' }), h('p', { class: 'hint' }, 'Kept as typed after it passes a connection test. 127.0.0.1 is never accepted: inside Traefik it is Traefik.')))));
  };
})();
