'use strict';
// The backend part of the Add Service / Edit Service form: "How should Traefik connect to this application?", then the
// address Traefik will use from inside Docker, explained and verified. The server's resolver (POST /api/services/backend)
// recommends an address from what runs on this engine and what the user typed; a connection test runs from Traefik's
// own network. A recommendation never replaces the user's choice: the address they entered stays selectable next to it.
// Detail levels change what is shown, never what is sent.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { h, arr, fill, icon, plainChip, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});

  const WHERE_TEXT = {
    docker: ['Docker container', 'box', 'Connect to an application running in Docker using its container network name and internal port.', 'http://uptime-kuma:3001'],
    'this-computer': ['Application on this computer', 'monitor', 'Connect to an HTTP application running directly on this Windows computer.', 'http://host.docker.internal:80'],
    lan: ['Another computer or network device', 'server', 'Connect to an HTTP application using an IP address or hostname on your network.', 'http://10.10.0.8:8080'],
  };
  const EXPLAIN = {
    docker: 'Traefik reaches an app in Docker by its container name and the port the app listens on inside the container. No Windows address is involved.',
    'this-computer': 'Traefik runs inside Docker. Docker Desktop provides host.docker.internal as a way to reach applications running directly on Windows. This computer\'s LAN address can also be used, but Docker network routing may affect it. 127.0.0.1 never works: inside Docker it means Traefik itself.',
    lan: 'Traefik uses the other device\'s own address, exactly as you enter it.',
  };
  const VIA = { docker: 'Docker network', host: 'Docker host address', lan: 'Network address (LAN)' };

  // State lives in the service form object f: where, container, address, port, protocol, touched, override, custom,
  // backend (last resolver answer), tests (connection test per URL), target (what is saved), source, dismissed, stash.
  // source: existing (an edited service's backend) | chosen (picked by the user) | entered (the typed address) |
  // auto (the only usable candidate) | override (a custom URL).
  P.initBackendState = (f, sv) => {
    f.where = sv ? L.whereFromTargetType(sv.target.type) : 'docker';
    f.container = sv && sv.target.type === 'docker' ? sv.target.host : '';
    f.address = sv && sv.target.type === 'lan' ? sv.target.host : '';
    f.port = sv ? String(sv.target.port) : '';
    f.protocol = sv ? sv.target.protocol : 'http';
    f.touched = { protocol: !!sv };
    f.override = false; f.custom = '';
    f.backend = null; f.verification = null; f.tests = {}; f.dismissed = {}; f.stash = {};
    f.target = sv ? { type: sv.target.type, host: sv.target.host, port: Number(sv.target.port), protocol: sv.target.protocol, url: `${sv.target.protocol}://${sv.target.host}:${sv.target.port}` } : null;
    f.source = sv ? 'existing' : '';
  };

  function proto(f, t) { return f.touched.protocol ? f.protocol : (t && t.protocol) || f.protocol || 'http'; }
  function testOf(f, t) { return t ? f.tests[L.targetUrl(t, proto(f, t))] || null : null; }
  function requestBody(f, extra) {
    const typed = f.where === 'docker' ? f.container : f.address;
    const custom = f.override ? L.parseBackendUrl(f.custom) : null;
    return { location: f.where, address: custom ? (custom.ok ? custom.url : '') : typed, port: custom && custom.ok ? String(custom.port) : f.port,
      protocol: custom && custom.ok ? custom.scheme : f.touched.protocol ? f.protocol : '', container: f.where === 'docker' && !f.override ? f.container : '',
      override: !!(custom && custom.ok), hostname: f.hostname || '', ...extra };
  }
  const asTarget = (f, c) => ({ type: c.type, host: c.host, port: Number(c.port), protocol: proto(f, c), tlsSkipVerify: !!f.tls });

  // Builds the section once per form render; refresh() re-renders only the result panel (inputs keep their focus).
  P.backendSection = (ctx, f, opts = {}) => {
    const panel = h('div', { class: 'backend-box', id: 'svc-backend', 'aria-live': 'polite' });
    let seq = 0; let timer = null;
    // test: true tests the selected backend; 'all' tests every usable candidate, each on its own.
    const resolve = async (test = false, btn = null) => {
      const my = ++seq;
      const hadContainers = !!(f.backend && arr(f.backend.containers).length);
      f.resolvedKey = JSON.stringify(requestBody(f));
      const all = test === 'all' && f.backend ? L.backendCandidates(f.backend.resolution).filter((c) => !c.rejected).slice(0, 4).map((c) => asTarget(f, c)) : [];
      const body = requestBody(f, test === true && f.target ? { test: true, target: asTarget(f, f.target) } : all.length ? { targets: all } : {});
      f.busy = test ? 'test' : 'resolve'; draw();
      const run = async () => {
        try {
          const r = await api('POST', '/api/services/backend', body);
          if (my !== seq) return;
          f.backend = r;
          for (const v of [r.verification, ...arr(r.verifications)]) if (v && v.targetUrl) f.tests[v.targetUrl] = v;
          const pick = L.chooseBackend({ source: f.source, target: f.target, override: f.override }, r.resolution);
          f.target = pick.target ? { type: pick.target.type, host: pick.target.host, port: Number(pick.target.port), protocol: pick.target.protocol, url: pick.target.url } : null;
          f.source = pick.source; f.needsChoice = pick.needsChoice;
          if (f.target && !f.touched.protocol) f.protocol = f.target.protocol;
          f.verification = testOf(f, f.target);
          if (opts.onTarget) opts.onTarget();
          f.error = '';
          // The container list arrives with the first answer: the inputs above are drawn again once.
          if (!hadContainers && f.where === 'docker' && arr(r.containers).length && opts.onContainers) { f.busy = ''; opts.onContainers(); return; }
        } catch (e) { if (my === seq) f.error = e.message; }
        finally { if (my === seq) { f.busy = ''; draw(); } }
      };
      return btn ? withBusy(btn, run) : run();
    };
    const schedule = () => { clearTimeout(timer); timer = setTimeout(() => resolve(false), 500); };
    // The user's pick: kept through later recommendations until they pick another one.
    const useTarget = (cand) => {
      f.target = { type: cand.type, host: cand.host, port: Number(cand.port), protocol: cand.protocol, url: cand.url };
      f.source = 'chosen'; f.needsChoice = false;
      if (!f.touched.protocol) f.protocol = cand.protocol;
      f.verification = testOf(f, f.target);
      if (opts.onTarget) opts.onTarget();
      draw();
      if (!f.verification) resolve(true);
    };

    function guidanceNode(g, rec) {
      const tone = g.severity === 'error' ? 'err' : g.severity === 'warn' ? 'warn' : '';
      return h('div', { class: `callout ${tone} guidance`, role: g.severity === 'error' ? 'alert' : 'note', 'data-guidance': g.id, 'data-category': g.category || '' },
        h('p', null, h('strong', null, g.title)), h('p', null, g.text),
        h('div', { class: 'actions' },
          g.action === 'use-recommended' && rec && !L.sameTarget(rec, f.target) ? h('button', { type: 'button', class: 'btn small primary', onclick: () => useTarget(rec) }, icon('check'), 'Use recommended address') : null,
          g.severity !== 'error' ? h('button', { type: 'button', class: 'btn small ghost', 'aria-label': `Dismiss: ${g.title}`, onclick: () => { f.dismissed[g.condition] = true; draw(); } }, 'Dismiss') : null));
    }

    // One row per candidate, each with its own radio: the address entered, the recommendation, other paths.
    function candidateRow(c, i) {
      const t = testOf(f, c);
      const st = t ? L.backendStatus(t) : null;
      const selected = L.sameTarget(c, f.target);
      return h('label', { class: `choice cand ${c.rejected ? 'disabled' : ''} ${selected ? 'selected' : ''}`, 'data-role': c.role },
        h('input', { type: 'radio', name: 'svc-cand', value: c.url, checked: selected, disabled: c.rejected, 'aria-describedby': `cand-why-${i}`, onchange: () => useTarget(c) }),
        h('span', { class: 'cand-head' }, h('strong', null, c.label), c.isRecommended && c.role !== 'recommended' ? plainChip('Recommended', 'info') : null, st ? plainChip(st.label, st.tone) : null),
        h('span', { class: 'mono' }, c.url),
        h('span', { class: 'small muted', id: `cand-why-${i}` }, c.rejected ? c.rejectedReason || c.reason : c.reason),
        c.warning && !c.rejected && !(t && (t.state === 'ok' || t.state === 'auth')) ? h('span', { class: 'small warn-text' }, c.warning) : null);
    }

    function draw() {
      const r = f.backend;
      const res = r ? r.resolution : null;
      const rec = res ? (res.suggested || res.recommended) : null;
      const target = f.target;
      const ver = testOf(f, target);
      f.verification = ver;
      const st = L.backendStatus(ver);
      const where = f.where;
      const cands = res ? L.backendCandidates(res) : [];
      const usable = cands.filter((c) => !c.rejected);
      const entered = cands.find((c) => c.role === 'entered' || c.role === 'custom');
      const plain = target ? (target.type === 'docker' ? `Traefik will reach ${f.display || 'the app'} inside Docker, as ${target.host}.`
        : target.type === 'host' ? `Traefik will reach ${f.display || 'the app'} on this computer through Docker's host address.`
          : `Traefik will reach ${f.display || 'the app'} at ${target.host}, exactly as entered.`) : '';
      const container = r && f.where === 'docker' ? arr(r.containers).find((c) => c.name === (res && res.container ? res.container : f.container)) : null;
      const env = r ? r.environment : null;
      const notices = res ? L.visibleGuidance(res.guidance, f.dismissed, { target, verification: ver, recommended: rec }) : [];
      const others = usable.filter((c) => !L.sameTarget(c, target));
      fill(panel,
        h('h3', null, icon('route'), ' Backend Traefik will use'),
        h('p', { class: 'small muted', 'data-min-level': 'beginner' }, EXPLAIN[where]),
        f.error ? h('div', { class: 'callout err', role: 'alert' }, h('p', null, f.error)) : null,
        f.busy === 'resolve' && !res ? h('p', { class: 'muted small' }, 'Looking at Docker and this computer…') : null,
        notices.map((g) => guidanceNode(g, rec)),
        // Every address Traefik could use, each with its own control. Shown whenever there is a choice to see.
        cands.length > 1 || (cands.length === 1 && (cands[0].rejected || cands[0].role !== 'recommended')) ? h('fieldset', { class: 'cand-list', id: 'svc-candidates' },
          h('legend', null, 'Address Traefik will use'), cands.map(candidateRow)) : null,
        target ? h('div', { class: 'backend-result' },
          U.beginnerOnly(h('p', null, plain)),
          h('div', { 'data-min-level': 'intermediate' }, kv([
            ...(entered ? [[entered.role === 'custom' ? 'Custom address' : 'Address you entered', h('span', { class: 'mono' }, entered.url)]] : []),
            ...(rec && (!entered || rec.url !== entered.url) ? [['Recommended alternative', h('span', { class: 'mono' }, rec.url)]] : []),
            ['Traefik will use', h('span', { class: 'mono', id: 'svc-selected-url' }, L.targetUrl(target, proto(f, target)))],
            ['Application port', String(target.port)],
            ['Connection type', target.type === 'docker' ? `${VIA.docker}${container && container.networks.length ? ` (${container.networks.filter((n) => env && arr(env.traefikNetworks).includes(n.name)).map((n) => n.name).join(', ') || 'not shared with Traefik'})` : ''}` : VIA[target.type]],
            ['Connection status', h('span', null, plainChip(st.label, st.tone), ver && ver.testedAt ? h('span', { class: 'small muted' }, ` ${String(ver.testedAt).replace('T', ' ')}`) : null)],
          ])),
          h('div', { 'data-only-level': 'beginner' }, h('p', null, plainChip(st.label, st.tone))),
          ver ? h('div', { class: `test-result ${st.tone}`, id: 'svc-test-result' },
            h('p', null, h('strong', null, L.backendHeadline(ver, target))),
            h('p', { class: 'small' }, ver.message),
            gate('intermediate', ver.steps && Object.keys(ver.steps).length ? kv(Object.entries(ver.steps).map(([k, v]) => [{ dns: 'DNS', tcp: 'TCP connection', http: 'HTTP answer', tls: 'TLS', redirect: 'Redirect', hostHeader: 'Host header' }[k] || k, v])) : null),
            st.tone === 'err' || st.tone === 'warn' ? h('p', { class: 'small' }, others.length ? 'Choose another address above and test it, or preview and save this route anyway: you will be asked to confirm, and it is not marked healthy.' : 'You can still preview and save this route: you will be asked to confirm, and it is not marked healthy.') : null)
            : h('p', { class: 'small muted' }, 'Not tested yet: Test connection sends one request from Traefik\'s network to exactly this address.'),
          f.source === 'existing' && rec && !L.sameTarget(rec, target) ? h('p', { class: 'small' }, 'This is the saved backend. It changes only if you choose another one.') : null)
          : res && !f.needsChoice && !usable.length ? h('p', { class: 'muted small' }, where === 'docker' ? 'Choose the container and its port.' : 'Enter the address and port of the application.') : null,
        !target && f.needsChoice && usable.length ? h('p', { class: 'small', role: 'status' }, 'Select the address Traefik should use to reach your application.') : null,
        h('div', { class: 'actions' },
          rec && target && !L.sameTarget(rec, target) && !notices.some((g) => g.action === 'use-recommended') ? h('button', { type: 'button', class: 'btn small', onclick: () => useTarget(rec) }, icon('check'), 'Use recommended address') : null,
          target ? h('button', { type: 'button', class: 'btn small', id: 'svc-test', 'aria-busy': f.busy === 'test' ? 'true' : null, onclick: (e) => resolve(true, e.currentTarget) }, icon('pulse'), f.busy === 'test' ? 'Testing…' : 'Test connection') : null,
          usable.length > 1 ? h('button', { type: 'button', class: 'btn small', id: 'svc-test-all', onclick: (e) => resolve('all', e.currentTarget) }, icon('pulse'), 'Test every address') : null,
          h('button', { type: 'button', class: 'btn small ghost', 'aria-expanded': String(!!f.showDiag), 'aria-controls': 'svc-backend-diag', onclick: () => { f.showDiag = !f.showDiag; draw(); } }, icon('info'), f.showDiag ? 'Hide diagnostic details' : 'View diagnostic details')),
        f.showDiag && res ? h('div', { id: 'svc-backend-diag', class: 'diag' },
          h('h4', null, 'Why this address'), h('ul', { class: 'checks' }, arr(res.evidence).map((e) => checkItem('neutral', e))),
          cands.length ? gate('advanced', h('h4', null, 'Candidates'), h('ul', { class: 'checks' }, cands.map((c) => { const t = testOf(f, c); return checkItem(c.rejected ? 'err' : L.sameTarget(c, target) ? 'ok' : 'neutral', `${c.label}: ${c.url}`, `${c.rejected ? c.rejectedReason : c.reason}${t ? ` — tested: ${t.label}` : ''}`); }))) : null,
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
            ['Exact backend URL', target ? h('code', null, L.targetUrl(target, proto(f, target))) : '—'],
            ...(container ? [['Container addresses', container.networks.map((n) => `${n.name} ${n.ipv4 || '—'}`).join(' · ')]] : []),
            ['Network identities', env ? Object.entries(env.traefikNetworkIds || {}).map(([k, v]) => `${k} ${v}`).join(' · ') : '—'],
            ['Docker subnets', env ? arr(env.dockerSubnets).map((n) => `${n.name} ${n.subnet}`).join(' · ') : '—'],
            ['This computer\'s IPv4', env ? arr(env.localAddresses).join(', ') : '—'],
          ]),
          r.traefikYaml ? technical(r.traefikYaml.split('\n'), 'Generated Traefik service (preview)') : null,
          ver && arr(ver.evidence).length ? technical(arr(ver.evidence), 'Connection test output (redacted)') : null)) : null);
    }

    const api2 = { node: panel, refresh: draw, resolve, schedule };
    draw();
    // A form drawn again with unchanged inputs keeps the last answer instead of asking again.
    if (!f.backend || f.resolvedKey !== JSON.stringify(requestBody(f))) resolve(false);
    return api2;
  };

  // The connection question and the inputs that belong to it. Changing the option keeps the typed address, advanced
  // settings (protocol, custom URL) and a backend picked under each option, and asks the resolver again.
  P.backendInputs = (ctx, f, section, rerender) => {
    const net = ctx.state.status.instance.proxyNetwork;
    const where = h('div', { class: 'choice-cards', role: 'radiogroup', 'aria-label': L.BACKEND_QUESTION }, L.WHERE.map((k) => {
      const [title, ic, text, example] = WHERE_TEXT[k];
      return h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'svc-where', value: k, checked: f.where === k,
        onchange: () => {
          const prev = f.where;
          f.stash[prev] = { target: f.target, source: f.source, port: f.port, portTouched: f.portTouched };
          f.where = k;
          const back = f.stash[k];
          // A container port and a port on Windows or another device are different things: each option keeps its own.
          if (back) { f.port = back.port; f.portTouched = back.portTouched; } else if ((k === 'docker') !== (prev === 'docker')) { f.port = ''; f.portTouched = false; }
          if (f.source !== 'override') {
            if (back && back.target && (back.source === 'chosen' || back.source === 'existing')) { f.target = back.target; f.source = back.source; } else { f.source = ''; f.target = null; }
          }
          f.backend = null; rerender();
        } }),
      h('strong', null, icon(ic), ' ', title), h('span', { class: 'small muted' }, text), h('span', { class: 'small mono muted', 'data-min-level': 'intermediate' }, `e.g. ${example}`));
    }));
    const changed = () => { if (f.source !== 'override') { f.source = ''; } section.schedule(); };
    const port = h('input', { value: f.port, inputmode: 'numeric', autocomplete: 'off', placeholder: f.where === 'docker' ? '3001' : f.where === 'lan' ? '8080' : '80' });
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
      const addr = h('input', { value: f.address, autocomplete: 'off', spellcheck: 'false', placeholder: f.where === 'lan' ? '10.10.0.8 or nas.home.arpa' : 'host.docker.internal, this PC\'s LAN address, or just the port' });
      addr.addEventListener('input', () => {
        f.address = addr.value.trim();
        const p = L.parseBackendAddress(f.address);
        if (p.port && !f.portTouched) { f.port = String(p.port); port.value = f.port; }
        changed();
      });
      port.addEventListener('input', () => { f.portTouched = true; });
      first = h('div', { class: 'grid' },
        field({ id: 'svc-address', label: f.where === 'lan' ? 'Device address' : 'Address on this computer (optional)', control: addr,
          hint: f.where === 'lan' ? 'Its IP address or DNS name. It is used exactly as entered.' : 'Leave empty to use host.docker.internal, or enter the address you use (e.g. this PC\'s LAN address). Pasting http://127.0.0.1:4119 takes only the port.' }),
        field({ id: 'svc-port', label: 'Port', control: port }));
    }
    const protoSel = h('select', null, [['http', 'http'], ['https', 'https'], ['h2c', 'h2c (gRPC, cleartext)']].map(([v, t]) => h('option', { value: v, selected: f.protocol === v }, t)));
    protoSel.addEventListener('change', () => { f.protocol = protoSel.value; f.touched.protocol = true; rerender(); });
    const customOn = h('input', { type: 'checkbox', checked: f.override });
    const customErr = h('p', { class: 'form-error small', id: 'svc-custom-error', role: 'status' });
    const custom = h('input', { value: f.custom, autocomplete: 'off', spellcheck: 'false', placeholder: 'http://10.10.0.8:8080', disabled: !f.override, 'aria-describedby': 'svc-custom-error' });
    const showCustomError = () => { const p = f.override && f.custom ? L.parseBackendUrl(f.custom) : null; customErr.textContent = p && !p.ok ? p.error : ''; };
    customOn.addEventListener('change', () => {
      f.override = customOn.checked; custom.disabled = !f.override;
      if (f.override) { if (!f.custom && f.target) { f.custom = L.targetUrl(f.target, proto(f, f.target)); custom.value = f.custom; } f.source = 'override'; f.target = null; } else if (f.source === 'override') { f.source = ''; f.target = null; }
      showCustomError(); section.schedule();
    });
    custom.addEventListener('input', () => { f.custom = custom.value.trim(); if (f.override) { f.source = 'override'; } showCustomError(); section.schedule(); });
    showCustomError();
    return h('div', null,
      h('div', { class: 'field', 'data-help-host': '' }, h('span', { class: 'label', id: 'svc-where-label' }, `${L.BACKEND_QUESTION} `, U.help('container-dns', 'Container names')), where),
      first,
      gate('advanced', h('div', { class: 'grid' },
        field({ id: 'svc-protocol', label: 'Protocol to the app', control: protoSel, helpId: 'ports-protocols', hint: 'Usually http: Cloudflare already encrypts the public side, and Traefik talks to the app inside your network.' }),
        h('div', { class: 'field' }, h('label', { class: 'check' }, customOn, h('span', null, 'Use a custom backend URL')),
          Object.assign(custom, { id: 'svc-custom', 'aria-label': 'Custom backend URL' }), customErr,
          h('p', { class: 'hint' }, 'A complete URL with protocol, host and port, e.g. http://10.10.0.8:8080. Kept exactly as typed; test it before saving. 127.0.0.1 is never accepted: inside Traefik it is Traefik.')))));
  };
})();
