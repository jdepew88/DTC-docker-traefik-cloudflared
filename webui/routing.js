'use strict';
// Authentication & Routing (#routing/<service>): how a public request for one application travels through Cloudflare,
// Traefik and authentik, drawn from the application's real configuration (GET /api/routing). Two views: the browser
// journey (what the visitor's browser does) and the internal routing (what happens between containers). Every stage
// says how sure the manager is: verified by a real request, or configured but not tested. Read-only; "Run checks"
// sends read-only requests. Guided mode only for now: the model (lib\RoutingModel.psm1) is shaped so that a future
// manual mode can edit the same stages.
(function () {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { arr, h, fill, icon, plainChip, toast, api, withBusy } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const form = (ctx) => ctx.state.forms.routing || (ctx.state.forms.routing = { tab: 'journey', data: null, service: '' });

  const stateChip = (state) => { const s = L.routingState(state); return h('span', { class: `chip ${s.tone}`, title: s.text }, icon(s.icon), s.label); };
  const audienceChip = (a) => { const x = L.endpointAudience(a); return h('span', { class: `chip ${x.tone} ep-chip`, title: x.text }, icon(x.icon), x.label); };

  // "?" beside a stage: what it does, why, what the manager does, what you manage, common failures.
  function stageHelp(id, label) {
    const t = L.routingHelp(id);
    if (!t) return null;
    const btn = h('button', { type: 'button', class: 'help-btn', 'aria-expanded': 'false', 'aria-label': `Help: ${label}`, title: 'What is this?' }, '?');
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      const host = btn.closest('[data-help-host]');
      const open = host.querySelector(':scope > .help-panel');
      if (open) { open.remove(); btn.setAttribute('aria-expanded', 'false'); return; }
      host.append(h('div', { class: 'help-panel rt-help', role: 'note' },
        h('dl', null,
          h('dt', null, 'What it does'), h('dd', null, t.what),
          h('dt', null, 'Why it is needed'), h('dd', null, t.why),
          h('dt', null, 'What the manager sets up'), h('dd', null, t.dtc),
          h('dt', null, 'What you may manage yourself'), h('dd', null, t.you),
          h('dt', null, 'Common reasons it fails'), h('dd', null, t.fails))));
      btn.setAttribute('aria-expanded', 'true');
    });
    return btn;
  }

  function detailBlock(d, open) {
    if (!d) return null;
    return h('details', { class: 'rt-detail', open: open ? true : null }, h('summary', null, 'What was tested and what to do'),
      h('dl', { class: 'kv' },
        h('dt', null, 'Tested'), h('dd', null, h('code', null, d.endpoint || '')),
        h('dt', null, 'Expected'), h('dd', null, d.expected || ''),
        h('dt', null, 'Actual'), h('dd', null, h('code', null, d.actual || '(nothing)')),
        h('dt', null, 'Why'), h('dd', null, d.explanation || ''),
        h('dt', null, 'What to do'), h('dd', null, h('strong', null, d.fix || ''))));
  }

  function stageCard(s) {
    const eps = arr(s.endpoints).filter((e) => e.value);
    const v = s.values || {};
    const chain = arr(v.middlewares).length ? h('ol', { class: 'rt-chain', 'aria-label': 'Middleware order' }, arr(v.middlewares).map((m) => h('li', null, h('code', null, m)))) : null;
    const nets = s.id === 'networks' && v.proxy ? h('ul', { class: 'rt-nets' },
      h('li', null, h('strong', null, 'Shared network: '), h('code', null, v.proxy)),
      arr(v.traefik).length ? h('li', null, 'Traefik: ', arr(v.traefik).join(', ')) : null,
      arr(v.authentik).length ? h('li', null, 'authentik: ', arr(v.authentik).join(', ')) : null,
      v.backend && arr(v.backend).length ? h('li', null, 'Application container: ', arr(v.backend).join(', ')) : null) : null;
    return h('li', { class: `rt-stage ${s.state} side-${s.side}`, id: `rt-${s.id}`, 'data-state': s.state },
      h('div', { class: 'rt-stage-head', 'data-help-host': '' },
        h('div', { class: 'rt-stage-title' }, h('h3', null, s.title), stageHelp(s.id, s.title)),
        h('div', { class: 'rt-stage-meta' }, stateChip(s.state), s.evidence && s.evidence !== 'none' ? h('span', { class: 'small muted' }, L.routingEvidence(s.evidence)) : null)),
      h('p', { class: 'rt-summary' }, s.summary),
      eps.length ? h('ul', { class: 'rt-endpoints' }, eps.map((e) => h('li', null, audienceChip(e.audience), h('span', { class: 'small' }, `${e.label}: `), h('code', null, e.value)))) : null,
      chain, nets,
      detailBlock(s.detail, s.state === 'failed'));
  }

  function journeyView(m) {
    const byId = Object.fromEntries(arr(m.stages).map((s) => [s.id, s]));
    return h('ol', { class: 'rt-journey', 'aria-label': 'Browser journey' }, arr(m.journey).map((j) => {
      const p = L.journeyPath(j.path);
      const problems = arr(j.stages).map((id) => byId[id]).filter((s) => s && (s.state === 'failed' || s.state === 'warning'));
      return h('li', { class: `rt-step path-${j.path} ${j.state}`, id: `rj-${j.id}`, 'data-state': j.state },
        h('div', { class: 'rt-step-num', 'aria-hidden': 'true' }, String(j.n)),
        h('div', { class: 'rt-step-body' },
          h('div', { class: 'rt-step-head' }, h('h3', null, j.title), stateChip(j.state)),
          h('p', { class: 'rt-hop' }, h('span', { class: `chip ${p.tone}` }, icon(p.icon), p.label), ' ', h('span', null, j.from), h('span', { 'aria-hidden': 'true' }, ' → '), h('span', { class: 'sr-only' }, ' to '), h('span', null, j.to)),
          h('p', null, j.text),
          problems.map((s) => h('div', { class: `callout ${s.state === 'failed' ? 'err' : 'warn'}` }, h('p', null, h('strong', null, `${s.title}: `), s.summary), detailBlock(s.detail, false), h('p', { class: 'small' }, h('a', { href: `#routing/${m.service}`, 'data-stage': s.id, class: 'rt-goto' }, 'Show this stage in the internal routing view'))))));
    }));
  }

  function internalView(m) {
    const browser = arr(m.stages).filter((s) => s.side === 'browser');
    const internal = arr(m.stages).filter((s) => s.side !== 'browser');
    return h('div', { class: 'rt-internal' },
      h('p', { class: 'small muted' }, 'In request order. Blue stages are what browsers see; grey stages happen between containers on this PC.'),
      h('ol', { class: 'rt-stages' }, arr(m.stages).map(stageCard)),
      h('p', { class: 'small muted' }, `${browser.length} browser-facing and ${internal.length} internal stages.`));
  }

  P.routing = async (main, ctx, sub) => {
    if (!ctx.state.setup) await ctx.refresh();
    const f = form(ctx);
    const want = (sub || '').split('/')[0];
    const back = h('a', { href: '#identity', class: 'btn', id: 'rt-back' }, '← Back to Identity & Access');
    const head = h('div', { class: 'page-head' },
      h('div', null, h('div', { class: 'eyebrow' }, 'Access'), h('h1', null, 'Authentication & Routing'),
        h('p', null, 'How a visit to one of your applications travels through Cloudflare, Traefik and authentik, and whether each part works. You do not need this page to publish or protect applications.')),
      h('div', { class: 'actions' }, back));
    fill(main, head, h('p', { class: 'muted' }, 'Loading…'));
    let d;
    try { d = await api('GET', `/api/routing${want ? `?service=${encodeURIComponent(want)}` : ''}`); }
    catch (e) { fill(main, head, h('div', { class: 'callout err' }, h('p', null, e.message))); return; }
    f.data = d; f.service = d.selected;
    render(main, ctx, head);
  };

  function render(main, ctx, head) {
    const f = form(ctx);
    const d = f.data;
    const m = d.model;
    const services = arr(d.services);
    if (!m) { fill(main, head, h('p', { class: 'muted' }, 'No published applications yet. Add one on the Services page first.')); return; }
    const select = h('select', { id: 'rt-app' }, [...services].sort((a, b) => Number(b.protected) - Number(a.protected) || a.name.localeCompare(b.name)).map((s) =>
      h('option', { value: s.name, selected: s.name === d.selected }, `${s.displayName} (${s.hostname})${s.protected ? ' - authentik' : ''}`)));
    select.addEventListener('change', () => { location.hash = `#routing/${select.value}`; });
    const run = h('button', { type: 'button', class: 'btn primary', id: 'rt-run' }, icon('refresh'), m.probed ? 'Check again' : 'Run checks');
    run.addEventListener('click', () => withBusy(run, async () => {
      try { f.data = await api('GET', `/api/routing?service=${encodeURIComponent(d.selected)}&probe=1`); render(main, ctx, head); toast('Checks finished.'); }
      catch (e) { toast(e.message, true); }
    }));
    const c = m.counts || {};
    const first = m.firstProblem;
    const summary = h('section', { class: 'card rt-summary-card', 'aria-labelledby': 'rt-sum-h' },
      h('h2', { id: 'rt-sum-h' }, m.displayName || m.service, ' ', h('span', { class: 'small muted' }, m.appUrl)),
      h('div', { class: 'rt-pick' }, h('label', { for: 'rt-app' }, 'Application'), select, run),
      h('p', { class: 'small muted' }, m.probed ? `Checked ${m.checkedAt}. Read-only: anonymous requests only, no sign-in, no cookies or credentials sent.` : 'Showing the configuration. Run checks sends read-only requests (through Traefik, from Traefik to the application, and to the public addresses through Cloudflare); it never signs in.'),
      h('p', { class: 'rt-counts' }, stateChip('verified'), ` ${c.verified || 0}  `, stateChip('configured'), ` ${c.configured || 0}  `, stateChip('warning'), ` ${c.warning || 0}  `, stateChip('failed'), ` ${c.failed || 0}`),
      first ? h('div', { class: `callout ${first.state === 'failed' ? 'err' : 'warn'}`, role: 'status', id: 'rt-first' }, h('p', null, h('strong', null, `${first.state === 'failed' ? 'First problem' : 'Attention'}: ${first.title}. `), first.summary))
        : m.probed ? h('div', { class: 'callout', role: 'status' }, h('p', null, h('strong', null, 'No problem found. '), 'Stages marked "Configured, not tested" could not be proven without signing in.')) : null,
      !m.protected ? h('p', { class: 'hint' }, 'This application is not protected by authentik, so the sign-in steps do not apply. ', h('a', { href: '#identity/apps' }, 'Protect applications')) : null);
    const tabs = [['journey', 'Browser journey'], ['internal', 'Internal routing']];
    const tablist = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Views' }, tabs.map(([id, label]) =>
      h('button', { type: 'button', role: 'tab', id: `rt-tab-${id}`, 'aria-selected': String(f.tab === id), 'aria-controls': 'rt-view', class: `tab ${f.tab === id ? 'active' : ''}`, onclick: () => { f.tab = id; render(main, ctx, head); } }, label)));
    const legend = h('p', { class: 'rt-legend small' }, audienceChip('browser'), ' what browsers open (public HTTPS)  ', audienceChip('internal'), ' only between containers');
    const view = h('section', { class: 'card', id: 'rt-view', role: 'tabpanel', 'aria-labelledby': `rt-tab-${f.tab}` }, f.tab === 'journey' ? journeyView(m) : internalView(m));
    const future = h('p', { class: 'small muted' }, 'Guided mode: the manager sets up routing, DNS and sign-in for you. A manual mode for inspecting and changing each part is planned.');
    fill(main, head, summary, tablist, legend, view, future);
    main.querySelectorAll('.rt-goto').forEach((a) => a.addEventListener('click', (e) => {
      e.preventDefault(); f.tab = 'internal'; render(main, ctx, head);
      const el = document.getElementById(`rt-${a.dataset.stage}`); if (el) el.scrollIntoView({ block: 'start' });
    }));
  }
})();
