'use strict';
// Infrastructure Explorer: the request path from a browser to an application container, one card per component,
// with what has actually been established about each one (GET /api/infrastructure). Configuration tools (Docker
// Desktop, Docker Compose, this manager) and supporting components (socket-proxy) are shown apart from the path:
// they create or observe the path but never forward a request. Read-only page; changes happen on the other pages.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, $$, arr, h, clear, fill, icon, plainChip, api, withBusy, gate, technical, kv } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const B = window.TPMBrands || {};

  // --- What each component is (static explanations) ------------------------------------------------------------------
  const CF = 'https://developers.cloudflare.com';
  const TR = 'https://doc.traefik.io/traefik';
  const INFO = {
    browser: {
      title: 'Browser', easy: 'Your browser', icon: 'user', zone: 'internet',
      what: 'Opens https://app.your-domain. It asks DNS where the name lives and then talks HTTPS to that address.',
      easyWhat: 'Where every visit starts: a phone, laptop or TV typing your app\'s web address.',
      why: 'Always part of the path. Nothing to install or configure.',
      connects: ['dns', 'edge'],
      fails: ['Cached DNS answers or an old bookmark send it to an address that no longer serves the app.', 'Browser extensions or company proxies block or rewrite requests.'],
      diagnose: ['Try a private window or another device.', 'Check the address bar for the exact hostname and path.'],
      docs: [],
    },
    dns: {
      title: 'DNS', easy: 'Address book (DNS)', icon: 'globe', brand: 'cloudflare', zone: 'internet',
      what: 'Cloudflare DNS answers the hostname with Cloudflare\'s own addresses: each published hostname is a proxied CNAME to <tunnel-id>.cfargotunnel.com.',
      easyWhat: 'Turns the name of your app into the address of Cloudflare, so visitors never learn your home address.',
      why: 'Required for every public hostname. Local-only services do not use it.',
      connects: ['browser', 'edge'],
      fails: ['No record for the hostname (NXDOMAIN).', 'The record points at another tunnel or is not proxied (grey cloud).', 'A new record is still propagating (minutes).'],
      diagnose: ['Check health for a service checks its record through the Cloudflare API.', 'nslookup <hostname> 1.1.1.1 should return Cloudflare addresses.'],
      docs: [['DNS records', `${CF}/dns/manage-dns-records/`], ['Tunnel DNS records', `${CF}/cloudflare-one/connections/connect-networks/routing-to-tunnel/dns/`]],
    },
    edge: {
      title: 'Cloudflare edge', easy: 'Cloudflare (the front door)', icon: 'cloud', brand: 'cloudflare', zone: 'cloudflare',
      what: 'Terminates HTTPS with Cloudflare\'s certificate, applies Cloudflare\'s security and caching, and forwards the request into your tunnel.',
      easyWhat: 'Cloudflare answers visitors with a secure (HTTPS) connection, so your PC never has to accept connections from the Internet.',
      why: 'Required for public access. Your PC opens no ports; Cloudflare is the only public entrance.',
      connects: ['dns', 'access', 'tunnel'],
      fails: ['Error 1033: the tunnel has no connected connector.', 'Error 502/504 at Cloudflare: the connector cannot reach Traefik or the app is slow (100 s limit).', 'Uploads above the plan limit fail with 413.'],
      diagnose: ['The Cloudflare error page names the failing side (browser, Cloudflare or host).', 'Check the tunnel and cloudflared cards.'],
      docs: [['How Cloudflare works', `${CF}/fundamentals/concepts/how-cloudflare-works/`], ['Cloudflare 5xx errors', `${CF}/support/troubleshooting/cloudflare-errors/troubleshooting-cloudflare-5xx-errors/`]],
    },
    access: {
      title: 'Cloudflare Access', easy: 'Login check (Cloudflare Access)', icon: 'shield', brand: 'cloudflare', zone: 'cloudflare', optional: true,
      what: 'An Access application in front of a hostname: Cloudflare shows its login and only lets allowed identities through, before any request reaches your PC.',
      easyWhat: 'An optional sign-in page run by Cloudflare. Only the people you allow get past it.',
      why: 'Optional per service. Required for apps without their own secure login, and always for the public Traefik dashboard.',
      connects: ['edge', 'tunnel'],
      fails: ['No Access application covers the hostname: the app is public.', 'The policy allows the wrong emails or nobody.', 'A login redirect is not proof that the app works behind it.'],
      diagnose: ['Check health compares the Access applications with each hostname.', 'Open the hostname in a private window: you should see the Cloudflare login first.'],
      docs: [['Self-hosted applications', `${CF}/cloudflare-one/applications/configure-apps/self-hosted-public-app/`], ['Access policies', `${CF}/cloudflare-one/policies/access/`]],
    },
    tunnel: {
      title: 'Cloudflare Tunnel', easy: 'Private tunnel', icon: 'tunnel', brand: 'cloudflare', zone: 'cloudflare',
      what: 'A named tunnel whose configuration sends each published hostname to http://traefik:80. Requests travel inside connections that cloudflared opened from your PC.',
      easyWhat: 'An encrypted line your PC opened to Cloudflare. Visitors come in through it, so no router ports are opened.',
      why: 'Required for public access in tunnel mode.',
      connects: ['edge', 'cloudflared'],
      fails: ['Status "down" or "inactive": no connector is connected.', 'The hostname has no route in the tunnel configuration (Cloudflare 404).', 'The route points somewhere other than traefik:80.'],
      diagnose: ['The card reports Cloudflare\'s own status and connection count.', 'Check health checks the route for a hostname.'],
      docs: [['Cloudflare Tunnel', `${CF}/cloudflare-one/connections/connect-networks/`], ['Troubleshoot tunnels', `${CF}/cloudflare-one/connections/connect-networks/troubleshoot-tunnels/`]],
    },
    cloudflared: {
      title: 'cloudflared', easy: 'Tunnel connector', icon: 'box', brand: 'cloudflare', zone: 'host',
      what: 'The connector container. It keeps outbound connections to Cloudflare open and forwards each request to Traefik over a private Docker network, from a fixed address that Traefik trusts for X-Forwarded headers.',
      easyWhat: 'A small program in Docker that holds the tunnel open and hands each visitor to Traefik.',
      why: 'Required in tunnel mode. It is the only component that talks to Cloudflare.',
      connects: ['tunnel', 'traefik'],
      fails: ['Container stopped or restarting (wrong or rotated tunnel token).', 'Outbound connections blocked by a firewall.', 'Cannot resolve or reach traefik on the tunnel network.'],
      diagnose: ['Diagnostics > cloudflared logs show "Registered tunnel connection" when it works.', 'The tunnel card shows whether Cloudflare sees it.'],
      docs: [['cloudflared', `${CF}/cloudflare-one/connections/connect-networks/downloads/`], ['Tunnel logs', `${CF}/cloudflare-one/connections/connect-networks/monitor-tunnels/logs/`]],
    },
    traefik: {
      title: 'Traefik entry point', easy: 'Traefik (the traffic director)', icon: 'route', brand: 'traefikproxy', zone: 'host',
      what: 'The reverse proxy. Its "web" entry point receives every request on port 80 inside Docker (published only on 127.0.0.1 on this PC); its API and dashboard listen on a separate entry point.',
      easyWhat: 'Traefik looks at the name of the site each visitor asked for and sends them to the right app.',
      why: 'Required: every request passes through it.',
      connects: ['cloudflared', 'router'],
      fails: ['Container stopped.', 'The local port is taken by another program.', 'A broken dynamic file stops new routes from loading (shown in the dashboard).'],
      diagnose: ['Open the Traefik dashboard: routers, services and errors.', 'Diagnostics > traefik logs.'],
      docs: [['Entry points', `${TR}/routing/entrypoints/`], ['Dashboard', `${TR}/operations/dashboard/`]],
    },
    router: {
      title: 'Traefik router', easy: 'Matching rule', icon: 'route', brand: 'traefikproxy', zone: 'host',
      what: 'A rule such as Host(`app.example.com`) that matches requests and picks the middlewares and the service. This tool writes one router per service into traefik\\dynamic\\svc-<name>.yml (file provider).',
      easyWhat: 'The rule that says "requests for this name go to that app".',
      why: 'Required for each published service.',
      connects: ['traefik', 'middleware', 'service'],
      fails: ['No router matches the hostname: Traefik answers 404.', 'Two routers claim the same hostname (another file or Docker labels).', 'A router references a missing middleware or service: Traefik disables it.'],
      diagnose: ['The Advanced view lists every router with its rule and status.', 'Traefik dashboard > HTTP routers.'],
      docs: [['Routers', `${TR}/routing/routers/`], ['File provider', `${TR}/providers/file/`]],
    },
    middleware: {
      title: 'Middleware', easy: 'Adjustments on the way', icon: 'layers', brand: 'traefikproxy', zone: 'host', optional: true,
      what: 'Steps applied by the router before the request reaches the service, e.g. security headers or removing a path prefix.',
      easyWhat: 'Small adjustments to each request, such as adding security headers.',
      why: 'Optional. The default adds security headers.',
      connects: ['router', 'service'],
      fails: ['A referenced middleware does not exist: the router is disabled.', 'A strip-prefix or redirect sends the app paths it does not expect.'],
      diagnose: ['Traefik dashboard > HTTP middlewares.'],
      docs: [['Middlewares', `${TR}/middlewares/overview/`]],
    },
    service: {
      title: 'Traefik service', easy: 'Destination', icon: 'server', brand: 'traefikproxy', zone: 'host',
      what: 'The load-balancer entry with the backend URL (e.g. http://uptime-kuma:3001). Traefik opens a new connection from itself to that URL.',
      easyWhat: 'The exact address of the app that Traefik forwards to.',
      why: 'Required for each published service.',
      connects: ['middleware', 'network', 'app'],
      fails: ['Wrong port or scheme: Traefik answers 502 Bad Gateway.', 'The app is slow: 504 Gateway Timeout.', 'HTTPS backend with a self-signed certificate: 500 unless certificate checks are skipped.'],
      diagnose: ['Check health sends a real request through Traefik.', 'Traefik only marks servers UP/DOWN when a health check is configured.'],
      docs: [['Services', `${TR}/routing/services/`]],
    },
    network: {
      title: 'Docker network', easy: 'Private network', icon: 'network', brand: 'docker', zone: 'host',
      what: 'The shared bridge network. Containers on it reach each other by container name through Docker\'s built-in DNS; Traefik and every published container must both be attached.',
      easyWhat: 'A private network inside Docker where Traefik and your apps can find each other by name.',
      why: 'Required for container apps. Apps on the PC itself or on the LAN are reached by address instead.',
      connects: ['service', 'app'],
      fails: ['The app container is not attached: 502 Bad Gateway.', 'Two networks use overlapping address ranges.', 'Every attached container can reach every other one: attach only web front ends, not databases.'],
      diagnose: ['The Advanced view lists the attached containers.', 'docker network inspect <network>.'],
      docs: [['Docker networking', 'https://docs.docker.com/engine/network/'], ['Bridge networks', 'https://docs.docker.com/engine/network/drivers/bridge/']],
    },
    app: {
      title: 'Application', easy: 'Your app', icon: 'box', brand: 'docker', zone: 'host',
      what: 'The application container (or a program on this PC or a LAN device) that finally answers the request.',
      easyWhat: 'The app you published, for example a media server or a status page.',
      why: 'The destination of every request.',
      connects: ['service', 'network'],
      fails: ['Stopped or crash-looping container.', 'Listens only on 127.0.0.1 inside its container, or on another port.', 'Needs its own "base URL" setting when published under a path.'],
      diagnose: ['Check health shows the HTTP status the app returns through Traefik.', 'docker logs <container>.'],
      docs: [],
    },
    docker: {
      title: 'Docker Desktop', easy: 'Docker Desktop', icon: 'monitor', brand: 'docker',
      what: 'Runs the Docker Engine (in WSL 2) that hosts every container and network here. It is not a proxy and forwards no requests itself.',
      easyWhat: 'The program that runs all the containers. It must be running for anything else to work.',
      why: 'Required on Windows.',
      fails: ['Not started, or in Windows-containers mode.', 'WSL 2 integration broken after an update.'],
      diagnose: ['Docker Desktop tray icon: "Engine running".', 'docker info.'],
      docs: [['Docker Desktop', 'https://docs.docker.com/desktop/']],
    },
    compose: {
      title: 'Docker Compose', easy: 'Docker Compose', icon: 'list', brand: 'docker',
      what: 'Describes and creates the containers, networks and volumes of a project from compose.yaml. It runs when you install or start; requests never pass through it.',
      easyWhat: 'A recipe file that tells Docker which containers to create. Not part of a visit.',
      why: 'Used to create and update the stack.',
      fails: ['A changed compose.yaml takes effect only after the containers are recreated.'],
      diagnose: ['docker compose -p <project> ps.'],
      docs: [['Docker Compose', 'https://docs.docker.com/compose/']],
    },
    'socket-proxy': {
      title: 'Docker socket proxy', easy: 'Safe Docker window', icon: 'lock', brand: 'docker',
      what: 'Lets Traefik read container information (GET only) without mounting the Docker socket. It sits on an internal network with no route outside Docker.',
      easyWhat: 'Lets Traefik look at Docker safely, without being able to change anything.',
      why: 'Supporting component for Traefik\'s Docker provider; not on the request path.',
      fails: ['Stopped: Traefik cannot read Docker labels (file routes keep working).'],
      diagnose: ['Diagnostics > socket-proxy logs.'],
      docs: [['Docker socket proxy', 'https://github.com/Tecnativa/docker-socket-proxy'], ['Traefik Docker provider', `${TR}/providers/docker/`]],
    },
    manager: {
      title: 'Deployment Manager', easy: 'This website', icon: 'settings',
      what: 'This website. It writes configuration files and calls Docker and the Cloudflare API when you approve a change. Stopping it does not affect any request.',
      easyWhat: 'The website you are using. Your apps keep working when it is closed.',
      why: 'Optional: everything it creates is ordinary files, Compose projects and Cloudflare resources.',
      fails: [],
      diagnose: ['Settings > The manager itself.'],
      docs: [],
    },
  };
  const LANES = [
    ['internet', 'Internet', ['browser', 'dns']],
    ['cloudflare', 'Cloudflare', ['edge', 'access', 'tunnel']],
    ['host', 'This PC · Docker Desktop', ['cloudflared', 'traefik', 'router', 'middleware', 'service', 'network', 'app']],
  ];
  const PATH = LANES.flatMap((l) => l[2]);
  const TOOLS = ['docker', 'compose', 'socket-proxy', 'manager'];
  // Request-path health checks (POST /api/services/health) shown on the component they test.
  const HEALTH_NODE = { dns: 'dns', access: 'access', tunnel: 'tunnel', router: 'router', service: 'service', backend: 'network', http: 'app', public: 'edge' };
  const HEALTH_STATUS = { ok: { tone: 'ok', label: 'Verified', icon: 'check-double' }, failed: { tone: 'err', label: 'Failed', icon: 'x' }, warning: { tone: 'warn', label: 'Warning', icon: 'alert' }, skipped: { tone: 'neutral', label: 'Not checked', icon: 'minus' }, auth: { tone: 'neutral', label: 'Login required', icon: 'lock' } };
  const healthFor = (health, id) => (health ? arr(health.checks).find((x) => HEALTH_NODE[x.id] === id) : null);

  // --- Helpers ---------------------------------------------------------------------------------------------------------
  function brandMark(key, fallback, cls = '') {
    const b = B[key];
    if (!b) return icon(fallback || 'box', cls);
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('class', `brand-mark ${key} ${cls}`.trim()); s.setAttribute('aria-hidden', 'true'); s.setAttribute('focusable', 'false');
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', b.d); s.append(p);
    return s;
  }
  const isEasy = () => U.getLevel() === 'beginner';
  const titleOf = (id) => (isEasy() ? INFO[id].easy : INFO[id].title);
  function statusChip(st) { return h('span', { class: `chip ${st.tone}` }, icon(st.icon), st.label); }
  function dimStrip(c) {
    return h('span', { class: 'dim-strip', 'data-min-level': 'intermediate' }, L.DIMENSIONS.map(([k, label]) => {
      const v = c.dims[k];
      return h('span', { class: `dim ${v === true ? 'yes' : v === false ? 'no' : 'na'}`, title: `${label}: ${v === true ? 'yes' : v === false ? 'no' : 'not checked'}` },
        h('span', { class: 'sr-only' }, `${label}: ${v === true ? 'yes' : v === false ? 'no' : 'not checked'}. `));
    }));
  }
  function dimList(c) {
    return h('ul', { class: 'dim-list', 'aria-label': 'What has been established' }, L.DIMENSIONS.map(([k, label]) => {
      const v = c.dims[k];
      return h('li', { class: v === true ? 'yes' : v === false ? 'no' : 'na' }, icon(v === true ? 'check' : v === false ? 'x' : 'minus'), h('span', null, label), h('span', { class: 'v' }, v === true ? 'yes' : v === false ? 'no' : 'not checked'));
    }));
  }

  // The short line under a node: what matters right now, for the whole deployment or for one followed service.
  function nodeSub(id, c, m, flow) {
    const f = c.facts || {};
    if (c.applicable === false) return flow && flow.exposure === 'local' && INFO[id].zone !== 'host' ? 'not used: local only' : 'not used';
    if (flow) {
      const host = arr(flow.hostnames)[0] || '';
      switch (id) {
        case 'browser': return flow.exposure === 'local' ? `http://${host} (this PC)` : `https://${host}${flow.pathPrefix || ''}`;
        case 'dns': case 'edge': return flow.exposure === 'local' ? 'not used: local only' : host;
        case 'access': return flow.exposure === 'access' ? 'login required' : flow.exposure === 'public' ? 'no login (public)' : 'not used';
        case 'tunnel': case 'cloudflared': return flow.exposure === 'local' ? 'not used: local only' : (f.tunnelName || f.container || '');
        case 'router': return flow.router ? `${flow.router.name}: ${flow.router.status}` : 'not loaded';
        case 'middleware': return arr(flow.middlewares).join(', ') || 'none';
        case 'service': return flow.service ? arr(flow.service.servers).join(', ') : 'not loaded';
        case 'network': return flow.target.type === 'docker' ? m.instance.proxyNetwork : flow.target.type === 'host' ? 'host.docker.internal' : 'LAN routing';
        case 'app': return `${flow.target.host}:${flow.target.port}`;
        default: break;
      }
    }
    switch (id) {
      case 'browser': return 'anywhere';
      case 'dns': return arr(f.domains).map((d) => d.name).join(', ') || 'no domain';
      case 'edge': return f.accountName || 'HTTPS';
      case 'access': return 'per service';
      case 'tunnel': return f.tunnelName || 'not recorded';
      case 'cloudflared': case 'socket-proxy': return f.container || '';
      case 'traefik': return `127.0.0.1:${m.instance.httpPort}${f.version ? ` · v${f.version}` : ''}`;
      case 'router': return `${arr(m.flows).filter((x) => x.enabled).length} service route(s)`;
      case 'middleware': return arr(f.middlewares).length ? `${arr(f.middlewares).length} loaded` : '';
      case 'service': return `${arr(m.flows).filter((x) => x.enabled).length} backend(s)`;
      case 'network': return m.instance.proxyNetwork;
      case 'app': return `${arr(m.flows).length} service(s)`;
      case 'docker': return f.serverVersion ? `Engine ${f.serverVersion}` : '';
      case 'compose': return f.project || '';
      default: return '';
    }
  }

  // --- Diagram ---------------------------------------------------------------------------------------------------------
  // compact: the Overview version (no lanes' explanations, no tools). onSelect(id) opens the details.
  function diagram(m, opts = {}) {
    const byId = {}; arr(m.components).forEach((c) => { byId[c.id] = c; });
    const flow = opts.flow || null;
    const blockedHealth = opts.health ? PATH.findIndex((id) => { const x = healthFor(opts.health, id); return x && x.state === 'failed'; }) : -1;
    const blocked = blockedHealth >= 0 ? blockedHealth : L.firstBlocked(m.components, PATH);
    const buttons = [];
    const wrap = h('div', { class: `xp-diagram${opts.compact ? ' compact' : ''}${opts.paused ? ' paused' : ''}`, role: 'group', 'aria-label': flow ? `Request path for ${flow.displayName}` : 'Request path from a browser to your applications' });
    let index = 0;
    LANES.forEach(([zone, label, ids]) => {
      const shown = ids.filter((id) => byId[id] && !(opts.compact && byId[id].applicable === false));
      if (!shown.length) return;
      // A lane whose components are all unused (e.g. Cloudflare in a local-only deployment) collapses to one line;
      // its cards stay reachable through the detail links and the Expert data.
      if (!flow && shown.every((id) => byId[id].applicable === false)) {
        wrap.append(h('div', { class: `xp-lane ${zone} collapsed` }, h('div', { class: 'xp-lane-label' }, label),
          h('p', { class: 'muted small' }, `${shown.map((id) => titleOf(id)).join(', ')}: not used by this deployment.`)));
        index += shown.length;
        return;
      }
      const lane = h('div', { class: `xp-lane ${zone}` }, h('div', { class: 'xp-lane-label' }, label));
      const row = h('ol', { class: 'xp-row' });
      shown.forEach((id, i) => {
        const c = byId[id];
        const hc = healthFor(opts.health, id);
        // A backend check names its result (Timeout, Hostname rejected, ...) instead of a bare Failed.
        const st = hc ? { ...HEALTH_STATUS[hc.state], ...(hc.resultLabel && hc.state !== 'ok' ? { label: hc.resultLabel } : {}) } : L.componentStatus(c);
        const pos = PATH.indexOf(id);
        const after = blocked >= 0 && pos > blocked;
        const btn = h('button', { type: 'button', class: `xp-node ${st.tone}${opts.selected === id ? ' selected' : ''}${after ? ' downstream' : ''}`, 'data-id': id, 'aria-pressed': opts.selected === id ? 'true' : 'false',
          'aria-controls': opts.compact ? null : 'xp-detail', onclick: () => opts.onSelect && opts.onSelect(id) },
          h('span', { class: 'xp-icon' }, brandMark(INFO[id].brand, INFO[id].icon)),
          h('span', { class: 'xp-text' }, h('strong', null, titleOf(id)), opts.compact ? null : h('span', { class: 'xp-sub' }, nodeSub(id, c, m, flow))),
          h('span', { class: 'xp-state' }, statusChip(st), opts.compact ? null : dimStrip(c)));
        buttons.push(btn);
        const item = h('li', { class: 'xp-item' }, btn);
        if (i < shown.length - 1) {
          const wire = h('span', { class: `xp-wire${blocked >= 0 && pos >= blocked ? ' blocked' : ''}`, 'aria-hidden': 'true' }, h('span', { class: 'packet' }));
          wire.firstChild.style.animationDelay = `${(index * 0.35).toFixed(2)}s`;
          item.append(wire);
        }
        index += 1;
        row.append(item);
      });
      lane.append(row);
      wrap.append(lane);
    });
    // A wire at the end of a wrapped line would point at nothing: hide it (recomputed when the width changes).
    const markWraps = () => $$('.xp-item', wrap).forEach((item) => {
      const wire = $('.xp-wire', item); const next = item.nextElementSibling;
      // Wrapped: the next card starts a new line further left (in the one-column phone layout nothing wraps).
      if (wire) wire.classList.toggle('wrapped', !!next && next.offsetTop > item.offsetTop + 4 && next.offsetLeft < item.offsetLeft);
    });
    if (window.ResizeObserver) new ResizeObserver(() => markWraps()).observe(wrap);
    requestAnimationFrame(markWraps);
    // Arrow keys move between the components in path order.
    wrap.addEventListener('keydown', (e) => {
      const keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1, Home: -999, End: 999 };
      if (!(e.key in keys)) return;
      const i = buttons.indexOf(document.activeElement);
      if (i < 0) return;
      e.preventDefault();
      const next = Math.max(0, Math.min(buttons.length - 1, i + keys[e.key]));
      buttons[next].focus();
    });
    return wrap;
  }

  function toolsRow(m, opts) {
    const byId = {}; arr(m.components).forEach((c) => { byId[c.id] = c; });
    return h('section', { class: 'xp-tools', 'aria-labelledby': 'xp-tools-title' },
      h('h2', { id: 'xp-tools-title' }, 'Around the path: tools and supporting components'),
      h('p', { class: 'muted small' }, 'These create, host or observe the path. No request passes through them.'),
      h('ul', { class: 'xp-tool-list' }, TOOLS.filter((id) => byId[id]).map((id) => {
        const c = byId[id]; const st = L.componentStatus(c);
        return h('li', null, h('button', { type: 'button', class: `xp-node tool ${st.tone}${opts.selected === id ? ' selected' : ''}`, 'data-id': id, 'aria-pressed': opts.selected === id ? 'true' : 'false', 'aria-controls': 'xp-detail', onclick: () => opts.onSelect(id) },
          h('span', { class: 'xp-icon' }, brandMark(INFO[id].brand, INFO[id].icon)), h('span', { class: 'xp-text' }, h('strong', null, titleOf(id)), h('span', { class: 'xp-sub' }, nodeSub(id, c, m, null))),
          h('span', { class: 'xp-state' }, statusChip(st))));
      })));
  }

  // --- Details panel ---------------------------------------------------------------------------------------------------
  function detail(m, id, flow) {
    const c = arr(m.components).find((x) => x.id === id);
    const info = INFO[id];
    if (!c || !info) return h('div', { class: 'xp-detail-empty muted' }, 'Select a component to see what it does and how it is doing.');
    const st = L.componentStatus(c);
    const easy = isEasy();
    const connects = arr(info.connects).map((x) => h('li', null, h('button', { type: 'button', class: 'link-btn', onclick: () => P.explorerSelect(x) }, titleOf(x))));
    const evidence = arr(c.evidence);
    const sec = (title, ...content) => h('section', null, h('h3', null, title), content);
    return h('div', { class: 'xp-detail-body' },
      h('div', { class: 'xp-detail-head' }, h('span', { class: 'xp-icon big' }, brandMark(info.brand, info.icon)),
        h('div', null, h('h2', { id: 'xp-detail-title', tabindex: '-1' }, titleOf(id)), h('p', { class: 'muted small' }, info.zone ? 'On the request path' : 'Tool or supporting component (not a hop)')),
        statusChip(st)),
      h('p', null, easy ? info.easyWhat : info.what),
      c.applicable === false ? h('div', { class: 'callout' }, h('p', null, id === 'access' ? 'Not in use: no service asks for a Cloudflare Access login.' : 'Not used by this deployment (local only).')) : null,
      sec('Why it is here', h('p', null, info.why)),
      connects.length ? sec('Connects to', h('ul', { class: 'xp-connects' }, connects)) : null,
      sec(easy ? 'How is it doing?' : 'What has been established', dimList(c),
        evidence.length ? h('ul', { class: 'checks' }, evidence.map((e) => U.checkItem(e.ok === true ? 'ok' : e.ok === false ? 'err' : 'neutral', e.text, U.atLeast('advanced') ? e.dim : ''))) : null,
        h('p', { class: 'muted small' }, 'A file existing only makes a component "configured". "Verified" needs a real check against the running component or Cloudflare.')),
      flow && ['router', 'service', 'middleware', 'app', 'access', 'dns'].includes(id) ? sec(`For ${flow.displayName}`, flowFacts(flow, id)) : null,
      flow && healthFor(view.health[flow.name], id) ? sec('Health check', h('ul', { class: 'checks' }, [healthFor(view.health[flow.name], id)].map((x) => U.checkItem(x.state === 'ok' ? 'ok' : x.state === 'failed' ? 'err' : x.state === 'warning' ? 'warn' : x.state === 'auth' ? 'auth' : 'neutral', `${x.label}${x.resultLabel ? ` · ${x.resultLabel}` : ''}${x.performed ? '' : ' (not checked)'}`, x.message)))) : null,
      arr(info.fails).length ? sec('How it can fail', h('ul', null, info.fails.map((x) => h('li', null, x)))) : null,
      gate('intermediate', arr(info.diagnose).length ? sec('How to diagnose', h('ul', null, info.diagnose.map((x) => h('li', null, x)))) : null),
      arr(info.docs).length ? sec('Documentation', h('ul', { class: 'xp-docs' }, info.docs.map(([t, url]) => h('li', null, h('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, t, ' ', icon('external')))))) : null,
      gate('expert', Object.keys(c.facts || {}).length ? technical([JSON.stringify(c.facts, null, 2)], 'Identifiers and raw facts') : null));
  }
  function flowFacts(flow, id) {
    const pairs = [['Hostnames', arr(flow.hostnames).join(', ') || '(none)'], ['Who can reach it', { access: 'Cloudflare Access login', public: 'Public (no login)', local: 'This PC only' }[flow.exposure]]];
    if (id === 'router' || id === 'middleware') pairs.push(['Router', flow.router ? `${flow.router.name} (${flow.router.status})` : 'not loaded by Traefik'], ['Rule', flow.router ? flow.router.rule : '-'], ['Middlewares', arr(flow.middlewares).join(', ') || 'none']);
    if (id === 'service' || id === 'app') pairs.push(['Backend', `${flow.target.protocol}://${flow.target.host}:${flow.target.port}`], ['Traefik service', flow.service ? `${flow.service.name} (${flow.service.status})` : 'not loaded']);
    return kv(pairs);
  }

  // --- Advanced and Expert sections ------------------------------------------------------------------------------------
  function routesTable(m) {
    const rows = arr(m.flows).map((f) => h('tr', null,
      h('td', null, h('strong', null, f.displayName), f.enabled ? null : h('div', { class: 'sub' }, 'disabled')),
      h('td', { class: 'mono' }, arr(f.hostnames).join(', ') + (f.pathPrefix || '')),
      h('td', { class: 'mono' }, f.router ? f.router.name : '—', f.router ? h('div', { class: 'sub' }, f.router.status) : null),
      h('td', { class: 'mono' }, arr(f.middlewares).join(', ') || '—'),
      h('td', { class: 'mono' }, f.service ? arr(f.service.servers).join(', ') : `${f.target.protocol}://${f.target.host}:${f.target.port}`)));
    const other = arr((arr(m.components).find((c) => c.id === 'router') || { facts: {} }).facts.routers).filter((r) => r.provider !== 'internal' && !arr(m.flows).some((f) => f.router && f.router.name === r.name));
    return h('section', { class: 'card', 'data-min-level': 'advanced' },
      h('h2', null, 'Routes: router → middlewares → service'),
      arr(m.conflicts).length ? h('div', { class: 'callout warn', role: 'status' }, h('p', null, h('strong', null, 'Competing definitions: '), m.conflicts.map((x) => `${x.hostname} is claimed by ${x.routers.join(' and ')}`).join('; '), '. Only one configuration source should own a hostname.')) : null,
      h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('caption', { class: 'sr-only' }, 'Routes'),
        h('thead', null, h('tr', null, ['Service', 'Hostname', 'Router', 'Middlewares', 'Backend'].map((t) => h('th', { scope: 'col' }, t)))),
        h('tbody', null, rows))),
      rows.length ? null : h('p', { class: 'empty' }, 'No services yet.'),
      other.length ? [h('h3', null, 'Other routers (not managed here)'), h('ul', { class: 'mono small' }, other.map((r) => h('li', null, `${r.name} · ${r.rule} · ${r.status}`)))] : null);
  }
  function networkingCard(m) {
    const net = (arr(m.components).find((c) => c.id === 'network') || { facts: {} }).facts.network;
    return h('section', { class: 'card', 'data-min-level': 'advanced' }, h('h2', null, 'Networking'),
      kv([['Shared network', net ? `${net.name} · ${net.driver || '?'} · ${arr(net.subnets).join(', ') || 'no subnet'}` : m.instance.proxyNetwork],
        ['Attached containers', net && arr(net.containers).length ? net.containers.map((x) => `${x.name} (${x.ipv4})`).join(', ') : 'none'],
        ['Tunnel network', m.instance.tunnelNetwork], ['Requests (web entry point)', `127.0.0.1:${m.instance.httpPort} → :80 in Traefik`],
        ['Dashboard and API', `127.0.0.1:${m.instance.dashboardPort} → :8080 in Traefik`]]));
  }
  // The fetched files are kept in the view, so a refresh of the diagram does not hide them again.
  function expertCard() {
    const out = h('div', null, view.files ? view.files.map((f) => technical(String(f.content || f.note || '').split('\n'), f.path)) : null);
    return h('section', { class: 'card', 'data-min-level': 'expert' }, h('h2', null, 'Generated configuration'),
      h('p', { class: 'muted small' }, 'The Compose, Traefik and Cloudflare files of this deployment. Anything credential-like is withheld.'),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => {
        const x = await api('GET', '/api/expert/config');
        view.files = arr(x.files);
        fill(out, view.files.map((f) => technical(String(f.content || f.note || '').split('\n'), f.path)));
      }) }, icon('eye'), 'Show the files')), out);
  }

  // --- Page ------------------------------------------------------------------------------------------------------------
  const view = { selected: '', flow: '', paused: false, stale: false, files: null, health: {} };
  try { view.paused = U.store('tpm.xp.paused') === '1'; } catch (e) { /* storage unavailable */ }
  let current = null;
  let mainRef = null;

  function render() {
    const m = current; const main = mainRef;
    if (!m || !main || !main.isConnected) return;
    const flow = arr(m.flows).find((f) => f.name === view.flow) || null;
    const follow = h('select', { id: 'xp-follow' }, h('option', { value: '' }, 'The whole deployment'), arr(m.flows).map((f) => h('option', { value: f.name, selected: f.name === view.flow }, `${f.displayName} (${arr(f.hostnames)[0] || f.name})`)));
    follow.addEventListener('change', () => { view.flow = follow.value; render(); });
    const pause = h('button', { type: 'button', class: 'btn small ghost', 'aria-pressed': view.paused ? 'true' : 'false', onclick: () => { view.paused = !view.paused; U.store('tpm.xp.paused', view.paused ? '1' : '0'); render(); } }, icon(view.paused ? 'play' : 'pause'), view.paused ? 'Animate packets' : 'Pause animation');
    const onSelect = (id) => P.explorerSelect(id);
    const blocked = L.firstBlocked(m.components, PATH);
    const summary = blocked >= 0
      ? h('div', { class: 'callout err', role: 'status' }, h('p', null, h('strong', null, `${titleOf(PATH[blocked])} needs attention. `), 'Requests stop here; the components after it are greyed out until it works.'))
      : h('div', { class: 'callout', role: 'status' }, h('p', null, isEasy() ? 'Nothing is blocking the path that we know of. Green with two checks means verified; one check means running but not yet tested.' : 'No component reports a problem. Two checks: verified by a real check. One check: running, not yet verified. Grey: configured or not checked.'));
    fill(main,
      h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Operate'), h('h1', null, 'Infrastructure Explorer'),
        h('p', null, isEasy() ? 'Follow a visit from a browser to your app. Select any box to learn what it does and how it is doing.' : 'Each component of the request path, what it does and what has actually been established about it.')),
      h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => load()) }, icon('refresh'), 'Refresh'))),
      summary,
      h('div', { class: 'xp-toolbar', 'data-xp-ready': view.stale ? null : 'true' }, h('label', { for: 'xp-follow' }, 'Follow a request to'), follow,
        flow ? h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => { view.health[flow.name] = await api('POST', '/api/services/health', { name: flow.name }); render(); }) }, icon('pulse'), view.health[flow.name] ? 'Check again' : 'Check health') : null,
        h('span', { class: 'grow' }), pause,
        h('span', { class: 'muted small' }, `Checked ${String(m.checkedAt || '').replace('T', ' ')}`)),
      h('div', { class: `xp-layout${view.selected ? '' : ' no-detail'}` },
        h('div', { class: 'xp-main' }, flow && view.health[flow.name] && P.healthList ? h('details', { class: 'more' }, h('summary', null, `Health of ${flow.displayName}: ${view.health[flow.name].performed} of ${view.health[flow.name].total} checks performed`), P.healthList(view.health[flow.name])) : null,
          diagram(m, { selected: view.selected, flow, paused: view.paused, onSelect, health: flow ? view.health[flow.name] : null }), U.atLeast('intermediate') ? toolsRow(m, { selected: view.selected, onSelect }) : null),
        h('aside', { class: 'xp-detail card', id: 'xp-detail', 'aria-live': 'polite', 'aria-labelledby': view.selected ? 'xp-detail-title' : null, hidden: view.selected ? null : true }, detail(m, view.selected, flow))),
      routesTable(m), networkingCard(m), expertCard(),
      technical([JSON.stringify(m, null, 2)], 'Raw explorer data', 'expert'));
  }
  P.explorerSelect = (id) => {
    view.selected = id; render();
    const t = $('#xp-detail-title'); if (t && window.matchMedia('(max-width: 960px)').matches) t.scrollIntoView({ block: 'start', behavior: 'smooth' });
    const b = $(`.xp-node[data-id="${id}"]`); if (b) b.focus();
  };
  async function load() {
    const next = await api('GET', '/api/infrastructure');
    // Another deployment was opened: forget what belonged to the previous one.
    if (current && current.instance.installPath !== next.instance.installPath) { view.files = null; view.flow = ''; view.selected = ''; view.health = {}; }
    current = next; view.stale = false; render(); return current;
  }

  P.explorer = async (main, ctx, sub) => {
    mainRef = main;
    if (sub && INFO[sub]) view.selected = sub;
    // A cached model is shown at once and replaced by fresh data (marked data-xp-ready) when it arrives.
    view.stale = true;
    if (!current) fill(main, h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Operate'), h('h1', null, 'Infrastructure Explorer'))), h('p', { class: 'muted' }, 'Reading Docker and Traefik…'));
    else render();
    await load();
    if (ctx.state.sub === 'check' && P.runVerify) { await P.runVerify(ctx); }
  };

  // Small version for the Overview page; selecting a component opens the Explorer on it.
  P.explorerMini = async (host, ctx) => {
    try {
      const m = current = await api('GET', '/api/infrastructure');
      if (!host.isConnected) return;
      fill(host, diagram(m, { compact: true, paused: view.paused, onSelect: (id) => ctx.navigate('explorer', id) }));
      return m;
    } catch (e) { if (host.isConnected) host.append(h('p', { class: 'muted small' }, `The detailed diagram is not available: ${e.message}`)); return null; }
  };
  P.explorerBrand = brandMark;
})();
