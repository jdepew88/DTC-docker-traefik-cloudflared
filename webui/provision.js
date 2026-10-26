'use strict';
// New app (universal provisioning): paste a link -> 1 Container (an imported draft, reviewed) -> 2 Reverse proxy (where
// it is reachable) -> 3 Authentication (who may open it) -> 4 one review -> deploy -> verify. The server does the work
// (lib\AppSources.psm1 and the provisioning section of webui.ps1); this page collects choices and shows previews.
// Nothing is installed, routed or published before the review is approved, and AI is used only when you approve an
// estimate for one request.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { arr, h, fill, icon, plainChip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const SEV = { block: ['err', 'Blocks installation'], high: ['err', 'High risk'], review: ['warn', 'Review'], info: ['neutral', 'Note'] };
  const STAGE = { passed: 'ok', failed: 'err', 'not-tested': 'neutral', 'not-applicable': 'neutral' };
  const STAGE_TEXT = { passed: 'Passed', failed: 'Failed', 'not-tested': 'Not tested', 'not-applicable': 'Does not apply' };
  const AUTH = {
    authentik: ['authentik', 'Visitors sign in with authentik (owner-only until you add access rules in authentik).'],
    'cloudflare-access': ['Cloudflare Access', 'Cloudflare asks visitors to sign in before the request reaches this PC.'],
    native: ['The application\'s own login', 'No additional sign-in in front of the application.'],
    none: ['No additional sign-in', 'Only for this PC or your own network.'],
    authelia: ['Authelia', 'Not implemented in this version.'],
  };
  const st = { draft: null, acknowledged: [], access: 'local', hostname: '', auth: 'none', project: '', review: null, result: null, step: 'container', ai: null, authAck: false };
  const head = (title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, 'Apps'), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const short = (img) => String(img || '').replace(/@sha256:[0-9a-f]{64}$/, '');
  const money = (n) => `$${Number(n || 0).toFixed(4)}`;

  function resetFor(draft) {
    st.draft = draft; st.acknowledged = []; st.review = null; st.result = null; st.ai = null; st.authAck = false;
    st.project = draft ? draft.id : '';
    st.hostname = draft ? L.suggestProvisionHostname(draft.id, arr((st.data || {}).domains)) : '';
  }

  P.provision = async (main, ctx, sub) => {
    fill(main, head('New app', 'Loading…'));
    st.data = await api('GET', '/api/provision');
    if (sub && /^[a-f0-9]{8,32}$/.test(sub) && (!st.draft || st.draft.draftId !== sub)) {
      try { resetFor(await api('GET', `/api/provision/draft?id=${sub}`)); } catch (e) { toast(e.message, true); }
    }
    render(main, ctx);
  };

  function render(main, ctx) {
    const wiz = L.provisionWizard(st);
    const byId = Object.fromEntries(wiz.steps.map((s) => [s.id, s]));
    if (!byId[st.step] || !byId[st.step].available) st.step = wiz.current;
    const go = (id) => { st.step = id; render(main, ctx); const p = document.getElementById('prov-panel'); if (p) p.scrollIntoView({ block: 'start' }); };
    const rerender = () => render(main, ctx);
    const nav = h('nav', { class: 'wizard-steps', 'aria-label': 'New app steps' }, h('ol', null, wiz.steps.map((s) => h('li', { class: `${s.id === st.step ? 'current' : ''} ${s.done ? 'done' : ''} ${!s.available ? 'locked' : ''}`, 'data-step': s.id },
      s.available ? h('button', { type: 'button', class: 'step-link', 'aria-current': s.id === st.step ? 'step' : null, onclick: () => go(s.id) },
        h('span', { class: 'step-num', 'aria-hidden': 'true' }, s.done ? '✓' : String(s.number)), h('span', null, s.title, !s.done && s.missing ? h('span', { class: 'step-badge small muted' }, s.missing) : null),
        h('span', { class: 'sr-only' }, `${s.done ? ', complete' : ''}${s.id === st.step ? ', current step' : ''}`))
        : h('span', { class: 'step-link' }, h('span', { class: 'step-num', 'aria-hidden': 'true' }, String(s.number)), h('span', null, s.title), h('span', { class: 'sr-only' }, ', not available yet'))))));
    const body = { container: () => containerStep(rerender), proxy: () => proxyStep(rerender), auth: () => authStep(rerender), review: () => reviewStep(rerender) }[st.step]();
    const ids = wiz.steps.map((s) => s.id);
    const i = ids.indexOf(st.step);
    const next = wiz.steps[i + 1];
    const foot = h('div', { class: 'wizard-foot' },
      i > 0 ? h('button', { type: 'button', class: 'btn', onclick: () => go(ids[i - 1]) }, '← Back') : h('span'), h('span', { class: 'grow' }),
      next ? h('button', { type: 'button', class: 'btn primary', id: 'prov-next', disabled: !byId[st.step].done, title: byId[st.step].done ? '' : byId[st.step].missing, onclick: () => go(next.id) }, `Continue: ${next.title} →`) : null);
    fill(main,
      head('New app', 'Paste a link from Docker Hub, GitHub, an Unraid template or awesome-selfhosted. The manager works out how to install it, where to reach it and who may open it; you review everything before anything is installed or published.',
        h('a', { class: 'btn', href: '#catalog' }, icon('download'), 'Curated catalog')),
      nav,
      h('section', { class: 'card wizard-panel', id: 'prov-panel', 'aria-labelledby': 'prov-title' }, h('h2', { id: 'prov-title' }, `${byId[st.step].number}. ${byId[st.step].title}`), body, foot),
      recentSection(main, ctx), aiSettingsSection(rerender));
  }

  // --- 1. Container ---------------------------------------------------------------------------------------------------
  function containerStep(rerender) {
    const url = h('input', { type: 'url', id: 'prov-url', placeholder: 'https://hub.docker.com/r/owner/app or https://github.com/owner/app', autocomplete: 'off', spellcheck: 'false' });
    const btn = h('button', { type: 'submit', class: 'btn primary', id: 'prov-import' }, icon('download'), 'Import');
    const form = h('form', { class: 'prov-import', onsubmit: (e) => { e.preventDefault(); withBusy(btn, async () => { resetFor(await api('POST', '/api/provision/import', { url: url.value })); history.replaceState(null, '', `#provision/${st.draft.draftId}`); rerender(); }); } },
      field({ id: 'prov-url', label: 'Application link or image name', control: h('div', { class: 'row' }, url, btn), hint: 'Supported: Docker Hub, GitHub repositories and Compose files, ghcr.io / quay.io / lscr.io images, raw Unraid template XML links, awesome-selfhosted entries. Links are fetched over HTTPS from those sites only.' }));
    return [form, st.draft ? draftView(st.draft, rerender) : h('p', { class: 'muted' }, 'Nothing imported yet.')];
  }

  function draftView(d, rerender) {
    const pending = new Set(L.provisionAckIds(d.findings).filter((x) => !st.acknowledged.includes(x)));
    const blocks = arr(d.findings).filter((f) => f.severity === 'block');
    const webOpen = !d.web || arr(d.unresolved).some((u) => u.field === 'web.port' || u.field === 'web.service');
    return h('div', { class: 'prov-draft', id: 'prov-draft' },
      h('div', { class: 'card-head' }, h('h3', null, d.name), h('span', { class: 'grow' }), plainChip(d.kind, 'neutral'),
        d.deployable ? plainChip(pending.size ? `${pending.size} to review` : 'Ready', pending.size ? 'warn' : 'ok') : plainChip('Cannot be deployed yet', 'err')),
      h('p', null, d.description),
      kv([['Source', h('a', { href: d.url.startsWith('https://') ? d.url : '#provision', rel: 'noopener noreferrer', target: '_blank' }, d.url)], ['Licence', d.license], ['Publisher', d.maintainer],
        ['Documentation', h('span', null, arr(d.docs).map((x) => h('a', { href: x.url, rel: 'noopener noreferrer', target: '_blank', class: 'link-gap' }, x.title)))], ['Platforms', arr(d.architectures).join(', ') || 'unknown', 'advanced']]),
      d.catalogMatch ? h('div', { class: 'callout ok', id: 'prov-catalog-match' }, h('p', null, h('strong', null, 'A curated recipe exists: '), `${d.catalogMatch.name} is in the App Catalog, tested for this manager. It is the better choice.`), h('a', { class: 'btn', href: '#catalog' }, 'Open the catalog')) : null,
      h('h3', null, 'Services'),
      h('div', { class: 'table-wrap' }, h('table', { class: 'table', id: 'prov-services' }, h('thead', null, h('tr', null, ['Service', 'Role', 'Image', 'Ports', 'Storage'].map((x) => h('th', null, x)))),
        h('tbody', null, arr(d.services).map((s) => h('tr', null, h('td', null, s.name), h('td', null, s.role || '—'), h('td', { class: 'mono small' }, short(s.image)),
          h('td', null, arr(s.ports).map((p) => `${p.container}/${p.protocol}${p.primary ? ' (web)' : ''}`).join(', ') || '—'), h('td', null, arr(s.volumes).map((v) => v.target).join(', ') || '—')))))),
      arr(d.unresolved).length ? h('div', { class: 'callout warn', id: 'prov-unresolved' }, h('p', null, h('strong', null, 'Open questions')), h('ul', null, arr(d.unresolved).map((u) => h('li', null, u.reason)))) : null,
      webOpen ? webPortForm(d, rerender) : null,
      aiPanel(d, rerender),
      h('h3', null, 'Security review'),
      blocks.length ? h('p', { class: 'step-status todo' }, icon('alert'), ' Some settings cannot be installed as imported: a curated recipe or the project\'s own instructions are needed.') : null,
      h('ul', { class: 'checks', id: 'prov-findings' }, arr(d.findings).map((f) => {
        const [tone, label] = SEV[f.severity] || SEV.info;
        const ackable = f.severity === 'high' || f.severity === 'review';
        const box = ackable ? h('input', { type: 'checkbox', class: 'prov-ack', 'data-ack': f.id, checked: st.acknowledged.includes(f.id) || null, onchange: (e) => { st.acknowledged = e.target.checked ? [...new Set([...st.acknowledged, f.id])] : st.acknowledged.filter((x) => x !== f.id); st.review = null; rerender(); } }) : null;
        return h('li', { 'data-severity': f.severity }, h('span', { class: `ci ${tone}` }, icon(tone === 'ok' ? 'check' : tone === 'neutral' ? 'info' : 'alert')),
          h('span', null, h('strong', null, `${label}: `), f.message, ackable ? h('label', { class: 'check small' }, box, h('span', null, 'I reviewed this')) : null));
      })),
      h('h3', null, 'This PC'),
      h('ul', { class: 'checks', id: 'prov-compat' }, checkItem(d.compatibility.status === 'compatible' ? 'ok' : d.compatibility.status === 'limited' ? 'warn' : 'err', d.compatibility.host, ({ compatible: 'Compatible', limited: 'Works with limitations', incompatible: 'Not compatible' })[d.compatibility.status]),
        arr(d.compatibility.items).map((x) => checkItem(x.level === 'incompatible' ? 'err' : x.level === 'limited' ? 'warn' : 'neutral', x.message, ''))),
      gate('advanced', h('details', { class: 'more' }, h('summary', null, `Evidence (${arr(d.evidence).length})`), h('ul', { class: 'small' }, arr(d.evidence).map((e) => h('li', null, h('strong', null, e.field), `: ${e.value} — ${e.how} (${e.source})`))))),
      arr(d.assumptions).length ? h('div', { class: 'callout' }, h('p', null, h('strong', null, 'Assumptions (AI) — check them: ')), h('ul', null, arr(d.assumptions).map((a) => h('li', null, a)))) : null,
      arr(d.manifestErrors).length ? gate('advanced', h('div', { class: 'callout warn' }, h('p', null, 'Manifest checks: '), h('ul', null, d.manifestErrors.map((x) => h('li', null, x))))) : null,
      gate('expert', technical([JSON.stringify(d, null, 2)], 'Draft (normalized manifest view)')));
  }

  function webPortForm(d, rerender) {
    const svc = h('select', { id: 'prov-web-service' }, arr(d.services).filter((s) => !['database', 'cache', 'messaging', 'init'].includes(s.role)).map((s) => h('option', { value: s.name }, s.name)));
    const port = h('input', { type: 'number', id: 'prov-web-port', min: '1', max: '65535', placeholder: '8080' });
    const proto = h('select', { id: 'prov-web-proto' }, h('option', { value: 'http' }, 'http'), h('option', { value: 'https' }, 'https'));
    const btn = h('button', { type: 'button', class: 'btn', id: 'prov-web-save', onclick: () => withBusy(btn, async () => { st.draft = await api('POST', '/api/provision/draft/web', { draftId: d.draftId, webService: svc.value, webPort: Number(port.value), protocol: proto.value }); st.review = null; rerender(); }) }, 'Use this port');
    return h('div', { class: 'card inset', id: 'prov-web' }, h('p', null, 'Which port is the web interface? The project\'s documentation says it; nothing is guessed.'),
      h('div', { class: 'row' }, field({ id: 'prov-web-service', label: 'Service', control: svc }), field({ id: 'prov-web-port', label: 'Container port', control: port }), field({ id: 'prov-web-proto', label: 'Protocol', control: proto }), btn));
  }

  function aiPanel(d, rerender) {
    if (!arr(d.unresolved).length) return null;
    const ai = (st.data || {}).ai || {};
    if (ai.provider === 'none') return gate('intermediate', h('p', { class: 'muted small', id: 'prov-ai-off' }, icon('info'), ' AI assistance is off. You can answer the open questions yourself, or turn on AI with your own API key in "AI assistance" below (every request shows its cost first).'));
    const box = h('div', { class: 'card inset', id: 'prov-ai' });
    const est = h('button', { type: 'button', class: 'btn', id: 'prov-ai-estimate', onclick: () => withBusy(est, async () => { st.ai = await api('POST', '/api/provision/ai/estimate', { draftId: d.draftId }); rerender(); }) }, 'Ask AI: show the cost first');
    if (!st.ai) {
      fill(box, h('p', null, `AI can read the project's documentation and answer the ${arr(d.unresolved).length} open question(s). You see exactly what would be sent and the maximum cost before anything is sent.`), est);
      return box;
    }
    const e = st.ai;
    const approve = h('input', { type: 'checkbox', id: 'prov-ai-approve' });
    const run = h('button', { type: 'button', class: 'btn primary', id: 'prov-ai-run', disabled: true, onclick: () => withBusy(run, async () => { const r = await api('POST', '/api/provision/ai/run', { estimateId: e.estimateId, confirm: true }); st.ai = null; st.draft = r.draft; st.review = null; toast(`AI ${r.run.cached ? 'answer from the local cache (no cost)' : `cost ${money(r.run.usage.usd)}`}: ${arr(r.run.applied).length} answer(s) applied.`); st.data = await api('GET', '/api/provision'); rerender(); }) }, 'Send this request');
    approve.addEventListener('change', () => { run.disabled = !(approve.checked && e.budget.ok); });
    fill(box,
      kv([['Provider and model', `${e.provider}: ${e.model}`], ['Estimated cost', `typically ${money(e.estimate.typicalUsd)}, at most ${money(e.estimate.maxUsd)} (${e.estimate.inputTokens} input tokens, up to ${e.estimate.maxOutputTokens} output tokens)`],
        ['This month', `${money(e.month.spentUsd)} of ${money(e.month.limitUsd)} spent`], ['Removed before sending', Object.entries(e.redacted || {}).map(([k, v]) => `${k}: ${v}`).join(', ') || 'nothing private found']]),
      e.budget.ok ? null : h('p', { class: 'step-status todo', id: 'prov-ai-budget' }, icon('alert'), ` ${e.budget.reason}`),
      h('details', { class: 'more', id: 'prov-ai-preview' }, h('summary', null, 'Exactly what would be sent'), U.output ? h('pre', { class: 'output', tabindex: '0' }, `${e.preview.system}\n\n${e.preview.user}`) : null),
      h('label', { class: 'check' }, approve, h('span', null, `I approve sending this request (at most ${money(e.estimate.maxUsd)}, billed to my API account).`)), run);
    return box;
  }

  // --- 2. Reverse proxy --------------------------------------------------------------------------------------------------
  function proxyStep(rerender) {
    const radios = Object.entries(L.PROVISION_ACCESS).map(([k, v]) => h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'prov-access', value: k, checked: st.access === k || null, onchange: () => { st.access = k; if (k === 'local') st.auth = 'none'; else if (st.auth === 'none') st.auth = k === 'public' ? 'authentik' : 'none'; st.review = null; rerender(); } }),
      h('span', null, h('strong', null, v.label), h('span', { class: 'small muted' }, ` ${v.text}`))));
    const hostIn = h('input', { type: 'text', id: 'prov-hostname', value: st.hostname, placeholder: 'app.example.com', autocomplete: 'off', spellcheck: 'false', oninput: (e) => { st.hostname = e.target.value.trim().toLowerCase(); st.review = null; } , onchange: rerender });
    const proj = h('input', { type: 'text', id: 'prov-project', value: st.project, autocomplete: 'off', oninput: (e) => { st.project = e.target.value.trim().toLowerCase(); st.review = null; } });
    return [h('fieldset', { id: 'prov-access' }, h('legend', null, 'Where should it be reachable?'), h('div', { class: 'choice-cards' }, radios)),
      st.access !== 'local' ? field({ id: 'prov-hostname', label: 'Host name', control: hostIn, hint: st.access === 'public' ? `Must be in a Cloudflare domain of this deployment${arr((st.data || {}).domains).length ? ` (${st.data.domains.join(', ')})` : ''}. Existing DNS records are never overwritten without your confirmation.` : 'The route is generated as an explicit Traefik file-provider definition.' }) : null,
      field({ id: 'prov-project', label: 'Project name', control: proj, hint: 'The Compose project, folder and route name (lowercase letters, digits and dashes).', minLevel: 'intermediate' })];
  }

  // --- 3. Authentication -------------------------------------------------------------------------------------------------
  function authStep(rerender) {
    const ready = (((st.data || {}).identity || {}).readiness) || { ready: false, missing: [] };
    const allowed = st.access === 'local' ? ['none', 'native'] : st.access === 'lan' ? ['authentik', 'native', 'none', 'authelia'] : ['authentik', 'cloudflare-access', 'native', 'authelia'];
    const radios = allowed.map((k) => h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'prov-auth', value: k, disabled: k === 'authelia' || (k === 'authentik' && !ready.ready) || null, checked: st.auth === k || null, onchange: () => { st.auth = k; st.review = null; rerender(); } }),
      h('span', null, h('strong', null, AUTH[k][0]), h('span', { class: 'small muted' }, ` ${k === 'authentik' && !ready.ready ? `Not ready: ${arr(ready.missing).map((m) => m.message).join(' ')}` : AUTH[k][1]}`))));
    const prot = st.draft && st.draft.protection;
    return [h('fieldset', { id: 'prov-auth' }, h('legend', null, 'Who should have access?'), h('div', { class: 'choice-cards' }, radios)),
      prot && st.auth === 'authentik' && prot.forwardAuth === 'caution' ? h('div', { class: 'callout warn', id: 'prov-forwardauth-caution' }, h('p', null, prot.recommendation), h('ul', null, arr(prot.reasons).map((r) => h('li', null, r)))) : null,
      st.access === 'public' && st.auth === 'native' ? h('label', { class: 'check', id: 'prov-public-native' }, h('input', { type: 'checkbox', id: 'prov-ack-auth', checked: st.authAck || null, onchange: (e) => { st.authAck = e.target.checked; st.review = null; } }), h('span', null, 'I understand that only the application\'s own login protects it on the Internet.')) : null,
      st.access === 'lan' && st.auth === 'none' ? h('label', { class: 'check' }, h('input', { type: 'checkbox', id: 'prov-ack-auth', checked: st.authAck || null, onchange: (e) => { st.authAck = e.target.checked; st.review = null; } }), h('span', null, 'I understand that anyone who can reach this host name can open it.')) : null];
  }

  // --- 4. Review and deploy ----------------------------------------------------------------------------------------------
  function planBody() {
    const ack = [...st.acknowledged]; if (st.authAck) ack.push(`auth:${st.auth}`);
    return { draftId: st.draft.draftId, project: st.project, access: st.access, hostname: st.access === 'local' ? '' : st.hostname, auth: st.auth, acknowledge: ack };
  }

  function reviewStep(rerender) {
    if (st.result) return resultView(st.result, rerender);
    const prep = h('button', { type: 'button', class: 'btn primary', id: 'prov-plan', onclick: () => withBusy(prep, async () => { st.review = await api('POST', '/api/provision/plan', planBody()); rerender(); }) }, icon('refresh'), st.review ? 'Prepare the review again' : 'Prepare the review');
    if (!st.review) return [h('p', null, 'The review checks everything against this PC, Docker, Traefik, Cloudflare and Identity & Access now. Nothing is changed.'), prep];
    const r = st.review;
    const c = r.container || {};
    const cfActions = arr(r.routing && r.routing.cloudflare && r.routing.cloudflare.actions).filter((a) => a.kind !== 'none');
    const files = arr(r.routing && r.routing.traefik && r.routing.traefik.changes);
    const ak = r.authentication && r.authentication.identity;
    const approve = h('input', { type: 'checkbox', id: 'prov-approve' });
    const priv = arr(c.privileges).length ? h('input', { type: 'checkbox', id: 'prov-priv' }) : null;
    const overwrites = cfActions.filter((a) => a.overwrite);
    const owBoxes = overwrites.map((a) => h('label', { class: 'check' }, h('input', { type: 'checkbox', class: 'prov-overwrite', 'data-id': a.id }), h('span', null, `Overwrite: ${a.summary}`)));
    const deploy = h('button', { type: 'button', class: 'btn primary', id: 'prov-deploy', disabled: true, onclick: () => withBusy(deploy, async () => {
      const confirmOverwrites = owBoxes.filter((b) => b.querySelector('input').checked).map((b) => b.querySelector('input').dataset.id);
      st.result = await api('POST', '/api/provision/apply', { planId: r.planId, confirm: true, confirmPrivileges: !!(priv && priv.checked), confirmOverwrites });
      st.data = await api('GET', '/api/provision'); rerender();
    }) }, icon('rocket'), 'Deploy');
    const sync = () => { deploy.disabled = !(r.canApply && approve.checked && (!priv || priv.checked) && owBoxes.every((b) => b.querySelector('input').checked)); };
    [approve, priv, ...owBoxes.map((b) => b.querySelector('input'))].filter(Boolean).forEach((x) => x.addEventListener('change', sync));
    return h('div', { id: 'prov-review' },
      arr(r.blockers).length ? h('div', { class: 'callout err', id: 'prov-blockers' }, h('p', null, h('strong', null, 'Cannot deploy yet:')), h('ul', null, r.blockers.map((b) => h('li', null, b)))) : h('p', { class: 'step-status ok', id: 'prov-ready' }, icon('check'), ' Everything below was checked just now.'),
      arr(r.warnings).length ? h('div', { class: 'callout warn', id: 'prov-warnings' }, h('ul', null, r.warnings.map((w) => h('li', null, w)))) : null,
      h('h3', null, 'What happens, in this order'), h('ol', { id: 'prov-steps' }, arr(r.steps).map((s) => h('li', null, s))),
      h('h3', null, 'Containers and images'),
      kv([['Project and folder', `${c.project || ''} in ${c.folder || ''}`], ['Containers', arr(c.services).map((s) => `${s.container} (${short(s.image)})`).join(', ')],
        ['Images', arr(c.images).map((i) => `${short(i.image)}${i.present ? ' (on this PC)' : ' (download)'}`).join(', ')], ['Data volumes', arr(c.volumes).join(', ') || 'none'],
        ['Networks', 'The web service joins the shared proxy network; databases, caches and workers only the app\'s private network.'], ['Host ports', c.localUrl ? `${c.localUrl} (this PC only)` : 'none'],
        ['AI usage', r.ai && r.ai.runs ? `${r.ai.runs} request(s), ${money(r.ai.usd)}; none during deployment` : 'none']]),
      arr(c.privileges).length ? h('label', { class: 'check', id: 'prov-priv-label' }, priv, h('span', null, `Allow: ${c.privileges.map((p) => p.reason || p.kind).join(' ')}`)) : null,
      st.access !== 'local' ? [h('h3', null, 'Traefik (explicit file-provider configuration)'), h('ul', { class: 'checks', id: 'prov-traefik' }, files.map((f) => checkItem('neutral', f.file, f.action)), checkItem('neutral', `Router for ${st.hostname}`, `to ${c.container}`))] : null,
      st.access === 'public' ? [h('h3', null, 'Cloudflare'), h('ul', { class: 'checks', id: 'prov-cloudflare' }, cfActions.map((a) => checkItem(a.overwrite ? 'warn' : 'neutral', a.summary, a.detail)))] : null,
      ak ? [h('h3', null, 'authentik (through Identity & Access)'), h('ul', { class: 'checks', id: 'prov-authentik' }, arr(ak.actions).map((a) => checkItem(a.kind === 'none' ? 'ok' : 'neutral', a.summary, a.kind === 'none' ? 'reused' : '')))] : null,
      owBoxes,
      gate('expert', technical([c.compose || ''], 'compose.yaml'), technical(files.map((f) => `# ${f.file}\n${arr(f.diff).join('\n')}`), 'Traefik files')),
      h('label', { class: 'check' }, approve, h('span', null, 'I reviewed this deployment.')),
      h('div', { class: 'actions' }, prep, deploy));
  }

  function verificationList(stages) {
    return h('ul', { class: 'checks', id: 'prov-verification' }, arr(stages).map((s) => h('li', { 'data-stage': s.stage, 'data-status': s.status }, h('span', { class: `ci ${STAGE[s.status] === 'ok' ? 'ok' : STAGE[s.status] === 'err' ? 'err' : 'neutral'}` }, icon(s.status === 'passed' ? 'check' : s.status === 'failed' ? 'alert' : 'minus')),
      h('span', null, h('strong', null, `${s.stage}: ${STAGE_TEXT[s.status] || s.status}`), s.detail ? h('span', { class: 'msg' }, s.detail) : null))));
  }

  function resultView(res, rerender) {
    const j = res.journal || {};
    const v = L.provisionVerdict(j.verification);
    const verify = h('button', { type: 'button', class: 'btn', id: 'prov-verify', onclick: () => withBusy(verify, async () => { const x = await api('POST', '/api/provision/verify', { operationId: res.operationId }); res.journal.verification = x.verification; rerender(); }) }, icon('refresh'), 'Verify again');
    const recipe = h('button', { type: 'button', class: 'btn', id: 'prov-recipe', onclick: () => withBusy(recipe, async () => { const x = await api('POST', '/api/provision/recipe/save', { operationId: res.operationId }); toast(`Recipe saved (${x.trust.status}).`); }) }, 'Save as a local recipe');
    return h('div', { id: 'prov-result' },
      res.ok ? h('p', { class: `step-status ${v.state === 'verified' ? 'ok' : 'todo'}`, id: 'prov-result-status' }, icon(v.state === 'verified' ? 'check' : 'alert'), ` Deployed. ${v.counts.passed} check(s) passed, ${v.counts.failed} failed, ${v.counts.notTested} not tested.`, res.url ? [' Open: ', h('a', { href: res.url, target: '_blank', rel: 'noopener noreferrer', id: 'prov-url-out' }, res.url)] : null)
        : h('div', { class: 'callout err', id: 'prov-result-status' }, h('p', null, `Stopped at "${(arr(j.stages).find((s) => s.status === 'failed') || {}).stage || '?'}": ${(arr(j.stages).find((s) => s.status === 'failed') || {}).message || ''}`), h('p', null, 'Nothing after that stage was done. Roll back to remove what this operation created.')),
      h('h3', null, 'Stages'), h('ul', { class: 'checks', id: 'prov-stages' }, arr(j.stages).map((s) => checkItem(s.status === 'passed' ? 'ok' : 'err', s.stage, s.message))),
      arr(j.verification).length ? [h('h3', null, 'Verification'), verificationList(j.verification)] : null,
      gate('advanced', h('details', { class: 'more' }, h('summary', null, 'Resources this operation owns'), h('ul', { class: 'small', id: 'prov-resources' }, arr(j.resources).map((x) => h('li', null, `${x.kind} ${x.name}: ${x.ownership}`))))),
      h('div', { class: 'actions' }, res.ok ? verify : null, res.ok ? recipe : null, rollbackButton(res.operationId, () => { st.result = null; st.review = null; rerender(); })));
  }

  function rollbackButton(operationId, done) {
    const btn = h('button', { type: 'button', class: 'btn danger', id: 'prov-rollback', onclick: () => withBusy(btn, async () => {
      const p = await api('POST', '/api/provision/rollback/plan', { operationId });
      const host = document.getElementById('prov-rollback-panel') || h('div', { id: 'prov-rollback-panel', class: 'card inset' });
      const del = h('input', { type: 'checkbox', id: 'prov-rb-data' });
      const name = h('input', { type: 'text', id: 'prov-rb-name', placeholder: 'project name', autocomplete: 'off' });
      const go = h('button', { type: 'button', class: 'btn danger', id: 'prov-rb-go', onclick: () => withBusy(go, async () => { const r = await api('POST', '/api/provision/rollback', { operationId, confirm: true, deleteData: del.checked, confirmText: name.value }); toast(r.ok ? 'Rolled back.' : r.error, !r.ok); done(); }) }, 'Roll back now');
      fill(host, h('p', null, h('strong', null, 'Rolling back removes:')), h('ul', { id: 'prov-rb-steps' }, arr(p.plan.steps).map((s) => h('li', null, `${s.kind} ${s.name}`))),
        h('p', null, h('strong', null, 'Kept:')), h('ul', { id: 'prov-rb-kept' }, arr(p.plan.kept).map((k) => h('li', null, `${k.kind} ${k.name} (${k.why})`))),
        h('label', { class: 'check' }, del, h('span', null, 'Also delete the data volumes (cannot be undone)')), field({ id: 'prov-rb-name', label: 'To delete data, type the project name', control: name }), go);
      btn.after(host);
    }) }, 'Roll back…');
    return btn;
  }

  // --- Recent drafts and operations, AI settings --------------------------------------------------------------------------
  function recentSection() {
    const d = st.data || {};
    return h('section', { class: 'card', id: 'prov-recent' }, h('h2', null, 'Recent'),
      arr(d.drafts).length ? h('ul', { class: 'small' }, d.drafts.slice(0, 8).map((x) => h('li', null, h('a', { href: `#provision/${x.draftId}` }, x.name), ` (${x.kind}, ${x.unresolved} open question(s))`))) : h('p', { class: 'muted small' }, 'No drafts.'),
      arr(d.operations).length ? [h('h3', null, 'Deployments'), h('ul', { class: 'small', id: 'prov-ops' }, d.operations.slice(0, 8).map((o) => h('li', null, `${o.summary}: ${o.state}`)))] : null,
      gate('advanced', h('p', { class: 'muted small' }, `Host: ${(d.host || {}).name || ''}. Other platforms are designed but not tested: ${arr(d.hosts).filter((x) => !x.tested).map((x) => x.name).join(', ')}.`)));
  }

  function aiSettingsSection(rerender) {
    const a = ((st.data || {}).ai) || {};
    const prov = h('select', { id: 'prov-ai-provider' }, arr(a.providers).map((p) => h('option', { value: p.id, disabled: p.status !== 'implemented' || null, selected: p.id === a.provider || null }, `${p.name}${p.status !== 'implemented' ? ' (not implemented)' : ''}`)));
    const model = h('select', { id: 'prov-ai-model' }, Object.entries(a.prices || {}).map(([k, v]) => h('option', { value: k, selected: k === a.model || null }, `${v.label}: $${v.input} / $${v.output} per million tokens`)));
    const monthly = h('input', { type: 'number', id: 'prov-ai-monthly', step: '0.5', min: '0', value: a.monthlyLimitUsd });
    const per = h('input', { type: 'number', id: 'prov-ai-per', step: '0.01', min: '0', value: a.perRequestLimitUsd });
    const key = h('input', { type: 'password', id: 'prov-ai-key', autocomplete: 'off', placeholder: a.keyStored ? 'A key is stored (never shown)' : 'sk-ant-…' });
    const save = h('button', { type: 'button', class: 'btn', id: 'prov-ai-save', onclick: () => withBusy(save, async () => {
      await api('POST', '/api/provision/ai/settings', { provider: prov.value, model: model.value, escalationModel: a.escalationModel, monthlyLimitUsd: monthly.value, perRequestLimitUsd: per.value });
      if (key.value) await api('POST', '/api/provision/ai/key', { key: key.value });
      st.data = await api('GET', '/api/provision'); toast('AI settings saved.'); rerender();
    }) }, 'Save');
    return gate('advanced', h('section', { class: 'card', id: 'prov-ai-settings' }, h('h2', null, 'AI assistance (optional)'),
      h('p', { class: 'muted small' }, 'Off by default. Uses your own API key (stored encrypted for your Windows account); a Claude subscription is not an API key. Only setting names, ports and documentation excerpts are sent, never passwords, tokens, addresses or your host names, and every request needs your approval of its cost.'),
      kv([['This month', a.month ? `${money(a.month.spentUsd)} of ${money(a.month.limitUsd)} (${a.month.calls} request(s))` : '—']]),
      h('div', { class: 'row' }, field({ id: 'prov-ai-provider', label: 'Provider', control: prov }), field({ id: 'prov-ai-model', label: 'Model', control: model })),
      h('div', { class: 'row' }, field({ id: 'prov-ai-monthly', label: 'Monthly limit (USD)', control: monthly }), field({ id: 'prov-ai-per', label: 'Per request (USD)', control: per })),
      field({ id: 'prov-ai-key', label: 'Anthropic API key', control: key }), save));
  }
})();
