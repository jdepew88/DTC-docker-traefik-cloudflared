'use strict';
// Applications: every application in one model (docs/universal-apps.md). Managed (DTC installed it), Integrated
// (another tool such as Arcane or Portainer owns the containers; DTC owns only the route, sign-in and publication it
// created) and Observed (listed and monitored only). Add application converges the catalog, links, pasted Compose or
// Unraid templates and running containers on one review flow. Drift checks compare what DTC intends with what Docker
// and Traefik report; repairs of DTC-owned routes are previewed and applied through the usual change pipeline, and
// anything owned by another tool is explained, never changed.
(() => {
  const U = window.TPMUI;
  const { arr, h, fill, icon, plainChip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const MODE = { managed: ['DTC Managed', 'ok'], integrated: ['DTC Integrated', 'info'], observed: ['DTC Observed', 'neutral'] };
  const SEV = { error: 'err', warning: 'warn', info: 'neutral' };
  const head = (title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, 'Apps'), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const modeChip = (m) => plainChip((MODE[m] || [m])[0], (MODE[m] || [0, 'neutral'])[1]);
  const authorityText = (a) => (a ? `${a.label}${a.confidence === 'likely' ? ' (likely)' : ''}` : 'Unknown');
  const reviewed = (label, onChange) => { const b = h('input', { type: 'checkbox' }); b.addEventListener('change', () => onChange(b.checked)); return h('label', { class: 'check' }, b, h('span', null, label)); };

  P.applications = async (main, ctx) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    if (!s.setup.installed) { fill(main, head('Applications', 'Available after the installation.')); return; }
    fill(main, head('Applications', 'Reading Docker and the registries…'));
    let data;
    try { data = await api('GET', '/api/applications'); } catch (e) { fill(main, head('Applications', ''), h('div', { class: 'callout err' }, h('p', null, e.message))); return; }
    const reload = () => P.applications(main, ctx);
    fill(main,
      head('Applications', 'Everything DTC installed, integrates or watches, and what else runs on this Docker engine. Nothing changes until you review and approve it.',
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, reload) }, icon('refresh'), 'Refresh')),
      addSection(data),
      h('section', { class: 'card', 'aria-labelledby': 'apps-known' }, h('h2', { id: 'apps-known' }, 'Your applications'),
        h('div', { class: 'chips' }, Object.entries(data.modes || {}).map(([k, v]) => h('span', { title: v.summary }, modeChip(k)))),
        U.gateSpan('intermediate', h('ul', { class: 'small muted' }, Object.entries(data.modes || {}).map(([k, v]) => h('li', null, h('strong', null, `${(MODE[k] || [k])[0]}: `), v.summary)))),
        arr(data.applications).length ? h('div', { class: 'disc-list', id: 'apps-list' }, arr(data.applications).map((a) => appCard(a, reload))) : h('p', { class: 'empty' }, 'No applications yet.')),
      h('section', { class: 'card', 'aria-labelledby': 'apps-found' }, h('h2', { id: 'apps-found' }, 'Found on this Docker engine'),
        h('p', { class: 'muted' }, 'Installed with Arcane, Portainer, docker compose or docker run. Integrate one to give it a route, sign-in or publication owned by DTC (its containers stay with their tool), or observe it.'),
        arr(data.unmanaged).length ? h('div', { class: 'disc-list', id: 'apps-unmanaged' }, arr(data.unmanaged).map((u) => unmanagedCard(u, data.proxyNetwork, reload))) : h('p', { class: 'empty' }, 'Nothing else runs on this engine.')),
      gate('expert', technical([JSON.stringify(data, null, 2)], 'Applications registry view (contract version ' + data.contractVersion + ')')));
  };

  function addSection(data) {
    return h('section', { class: 'card', 'aria-labelledby': 'apps-add' }, h('h2', { id: 'apps-add' }, 'Add application'),
      h('p', { class: 'muted' }, 'Every source ends in the same review: services, storage, networks, ports, risks, the route, sign-in and publication.'),
      h('div', { class: 'entry-cards', role: 'list' }, arr(data.entryPoints).map((e) => h('a', { class: 'entry-card', role: 'listitem', href: e.href, 'data-entry': e.id },
        h('span', { class: 'xp-icon' }, icon(e.id === 'catalog' ? 'download' : e.id === 'discover' ? 'box' : 'plus')), h('span', null, h('strong', null, e.label))))));
  }

  function routeLine(r) {
    return h('li', null, h('span', { class: 'mono' }, arr(r.hostnames).join(', ') || r.name), ' ',
      plainChip(r.owner === 'this-instance' ? 'route owned by this integration' : r.owner === 'other' ? 'route owned elsewhere' : 'route', r.owner === 'this-instance' ? 'info' : 'neutral'),
      r.protection ? plainChip(`sign-in: ${r.protection}`, 'ok') : null, r.publish ? plainChip('public', 'warn') : null, r.enabled ? null : plainChip('disabled', 'neutral'));
  }

  function appCard(a, reload) {
    const out = h('div', { class: 'app-detail', 'aria-live': 'polite' });
    const actions = [h('button', { type: 'button', class: 'btn', 'data-action': 'drift', onclick: (e) => withBusy(e.currentTarget, () => showDrift(a, out, reload)) }, icon('refresh'), 'Check drift')];
    if (a.mode === 'integrated') actions.push(h('button', { type: 'button', class: 'btn', 'data-action': 'remove', onclick: (e) => withBusy(e.currentTarget, () => showRemove(a, out, reload)) }, 'Remove integration…'));
    if (a.mode === 'observed') actions.push(h('button', { type: 'button', class: 'btn', 'data-action': 'forget', onclick: (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/applications/forget', { instanceId: a.instanceId }); toast('No longer observed.'); reload(); }) }, 'Stop observing'));
    if (a.mode === 'managed') actions.push(h('a', { class: 'btn', href: '#apps' }, 'Installed apps'));
    return h('article', { class: 'card disc-card', 'aria-label': a.name, 'data-instance': a.instanceId },
      h('div', { class: 'card-head' }, h('h3', null, a.name), modeChip(a.mode), h('span', { class: 'grow' }), a.found === false ? plainChip('container missing', 'err') : null),
      h('p', { class: 'small' }, 'Managed by ', h('strong', null, authorityText(a.authority)), U.gateSpan('advanced', h('span', { class: 'muted' }, ` · ${arr(a.authority && a.authority.evidence).join('; ')}`))),
      gate('intermediate', kv([['Recipe', a.recipe], ['Trust', a.trust ? `${a.trust.level} (${a.trust.status})` : '—'], ['Compose project', a.project || '—']])),
      arr(a.containers).length ? h('div', { class: 'chips' }, arr(a.containers).map((c) => plainChip(`${c.name} · ${c.state}${c.health ? ` · ${c.health}` : ''}`, c.state === 'running' ? 'ok' : 'warn'))) : null,
      arr(a.routes).length ? h('ul', { class: 'port-list' }, arr(a.routes).map(routeLine)) : h('p', { class: 'small muted' }, 'No route.'),
      h('div', { class: 'actions' }, actions), out);
  }

  async function showDrift(a, out, reload) {
    const d = await api('POST', '/api/applications/drift', { instanceId: a.instanceId });
    const s = d.summary || {};
    fill(out, h('h4', null, s.state === 'in-sync' ? 'In sync' : s.state === 'drifted' ? 'Drift found' : 'Needs attention'),
      arr(d.findings).length ? h('ul', { class: 'checks', 'data-drift': s.state }, arr(d.findings).map((f) => checkItem(SEV[f.severity] || 'neutral', f.title, f.explanation, f.repair ? `${f.repair.owner === 'dtc' ? 'DTC can repair this: ' : 'For the application\'s owner: '}${f.repair.description}` : ''))) : h('p', { class: 'muted' }, 'Docker and Traefik match what DTC recorded.'),
      d.repair && (d.repair.canApply || arr(d.repair.external).length) ? h('button', { type: 'button', class: 'btn primary', 'data-action': 'repair-plan', onclick: (e) => withBusy(e.currentTarget, () => showRepair(a, out, reload)) }, 'Preview repair') : null,
      gate('expert', technical([JSON.stringify(d, null, 2)], 'Drift report')));
  }

  async function showRepair(a, out, reload) {
    const r = await api('POST', '/api/applications/repair/plan', { instanceId: a.instanceId });
    const apply = h('button', { type: 'button', class: 'btn primary', disabled: true, 'data-action': 'repair-apply', onclick: (e) => withBusy(e.currentTarget, async () => {
      const res = await api('POST', '/api/applications/repair/apply', { instanceId: a.instanceId, key: r.key, confirm: true });
      toast(res.ok ? 'Repair applied.' : 'The repair did not complete; nothing else was changed.', !res.ok); reload(); }) }, 'Apply repair');
    fill(out, h('h4', null, 'Repair preview'),
      arr(r.routeChanges).length ? h('div', null, arr(r.routeChanges).map((c) => h('div', null, h('p', null, h('strong', null, c.summary)),
        arr(c.plan.traefik.changes).map((ch) => h('div', null, h('p', { class: 'mono small' }, `${ch.action}: ${ch.file}`), U.diffBlock(ch.diff)))))) : h('p', { class: 'muted' }, 'No change DTC can make itself.'),
      arr(r.external).length ? h('div', { class: 'callout warn' }, h('p', null, h('strong', null, 'To do in the application\'s own tool (DTC does not change it):')),
        h('ul', null, arr(r.external).map((x) => h('li', null, x.description, arr(x.snippet).length ? U.output(x.snippet, 'Compose lines') : null)))) : null,
      h('ul', { class: 'small muted' }, arr(r.notes).map((n) => h('li', null, n))),
      r.canApply ? h('div', { class: 'actions' }, reviewed('I reviewed the changes above.', (v) => { apply.disabled = !v; }), apply) : null);
  }

  async function showRemove(a, out, reload) {
    const p = await api('POST', '/api/integrations/remove/plan', { instanceId: a.instanceId });
    const keep = h('input', { type: 'checkbox' });
    const go = h('button', { type: 'button', class: 'btn danger', disabled: true, 'data-action': 'remove-apply', onclick: (e) => withBusy(e.currentTarget, async () => {
      const res = await api('POST', '/api/integrations/remove', { instanceId: a.instanceId, key: p.key, confirm: true, keepObserved: keep.checked });
      toast(res.ok ? 'Integration removed; the application itself was not touched.' : 'The removal did not complete.', !res.ok); reload(); }) }, 'Remove integration');
    fill(out, h('h4', null, 'Remove the integration'),
      h('ul', { class: 'checks' }, arr(p.removes).map((r) => checkItem('warn', `Route ${r.route}`, `${arr(r.hostnames).join(', ')}${r.protection ? ` · sign-in (${r.protection}) removed first` : ''}${r.cloudflare ? ' · Cloudflare records it created' : ''}`))),
      h('ul', { class: 'checks' }, arr(p.keeps).map((k) => checkItem('ok', k))),
      h('label', { class: 'check' }, keep, h('span', null, 'Keep observing it afterwards')),
      h('div', { class: 'actions' }, reviewed('I understand what will be removed.', (v) => { go.disabled = !v; }), go));
  }

  function unmanagedCard(u, proxyNet, reload) {
    const out = h('div', { class: 'app-detail', 'aria-live': 'polite' });
    const front = u.frontend;
    return h('article', { class: 'card disc-card', 'aria-label': u.name, 'data-unmanaged': u.name },
      h('div', { class: 'card-head' }, h('h3', null, u.name), plainChip(`suggested: ${(MODE[u.suggestedMode] || [u.suggestedMode])[0]}`, 'neutral')),
      h('p', { class: 'small' }, 'Managed by ', h('strong', null, authorityText(u.authority)), U.gateSpan('advanced', h('span', { class: 'muted' }, ` · ${arr(u.authority && u.authority.evidence).join('; ')}`))),
      h('div', { class: 'chips' }, arr(u.containers).map((c) => plainChip(`${c.name}${c.privateService ? ' (private)' : ''} · ${c.state}`, c.state === 'running' ? 'neutral' : 'warn'))),
      arr(u.routes).length ? h('ul', { class: 'port-list' }, arr(u.routes).map(routeLine)) : null,
      h('div', { class: 'actions' },
        front ? h('button', { type: 'button', class: 'btn primary', 'data-action': 'integrate', onclick: () => integrateForm(u, out, proxyNet, reload) }, 'Integrate…') : null,
        h('button', { type: 'button', class: 'btn', 'data-action': 'observe', onclick: (e) => withBusy(e.currentTarget, async () => {
          await api('POST', '/api/applications/observe', { container: front ? front.container : u.containers[0].name, name: u.name }); toast(`${u.name} is observed.`); reload(); }) }, 'Observe')),
      out);
  }

  function integrateForm(u, out, proxyNet, reload) {
    const f = u.frontend;
    const port = h('select', { id: `int-port-${u.name}` }, arr(f.ports).map((p) => h('option', { value: p.port }, `${p.port} (${p.guess})`)));
    const hostIn = h('input', { type: 'text', id: `int-host-${u.name}`, placeholder: `${u.name}.example.com`, autocomplete: 'off', spellcheck: 'false' });
    const pub = h('input', { type: 'checkbox' });
    const host = h('div', { 'aria-live': 'polite' });
    const preview = h('button', { type: 'submit', class: 'btn primary', 'data-action': 'integrate-plan' }, 'Preview');
    const form = h('form', { onsubmit: (e) => { e.preventDefault(); withBusy(preview, async () => {
      const r = await api('POST', '/api/integrations/plan', { container: f.container, port: Number(port.value), hostname: hostIn.value.trim(), publish: pub.checked, name: u.name });
      showPlan(r, host, reload); }); } },
      !f.onProxyNetwork ? h('div', { class: 'callout warn' }, h('p', null, `${f.container} is not on ${proxyNet}. Add the network in its owner's Compose file first; DTC does not edit it.`)) : null,
      field({ id: `int-port-${u.name}`, label: 'Web port', control: port }),
      field({ id: `int-host-${u.name}`, label: 'Hostname', control: hostIn }),
      h('label', { class: 'check' }, pub, h('span', null, 'Also publish it through Cloudflare (previewed; never automatic)')),
      h('div', { class: 'actions' }, preview));
    fill(out, form, host);
  }

  function showPlan(r, host, reload) {
    const apply = h('button', { type: 'button', class: 'btn primary', disabled: true, 'data-action': 'integrate-apply', onclick: (e) => withBusy(e.currentTarget, async () => {
      const res = await api('POST', '/api/integrations/apply', { planId: r.planId, confirm: true, acceptUnverifiedBackend: !!(ack && ack.checked) });
      toast(res.ok ? 'Integrated: the route is owned by DTC, the application stays with its tool.' : 'The route was not applied.', !res.ok); reload(); }) }, 'Integrate');
    const ack = r.needsBackendAck ? h('input', { type: 'checkbox' }) : null;
    fill(host, h('h4', null, `Route ${r.route} → ${r.backendUrl}`),
      arr(r.warnings).length ? h('div', { class: 'callout warn' }, arr(r.warnings).map((w) => h('p', null, w))) : null,
      h('ul', { class: 'checks' }, arr(r.ownership.keeps).map((k) => checkItem('ok', k))),
      arr(r.plan.traefik.changes).map((ch) => h('div', null, h('p', { class: 'mono small' }, `${ch.action}: ${ch.file}`), U.diffBlock(ch.diff))),
      arr(r.plan.traefik.issues).length ? h('ul', { class: 'checks' }, arr(r.plan.traefik.issues).map((i) => checkItem(i.Level === 'Error' ? 'err' : 'warn', i.Message))) : null,
      arr(r.plan.cloudflare.actions).length ? h('div', null, h('p', null, h('strong', null, 'Cloudflare')), h('ul', null, arr(r.plan.cloudflare.actions).map((x) => h('li', null, x.summary)))) : null,
      r.plan.backend ? h('p', { class: 'small' }, `Connection test from Traefik's network: ${r.plan.backend.message || r.plan.backend.state}`) : null,
      h('div', null, h('p', null, h('strong', null, 'Sign-in options')), h('ul', { class: 'small' }, arr(r.authentication.options).map((o) => h('li', null, `${o.name}: ${o.state}${o.available ? '' : ' (not available)'}${arr(o.notes).length ? ` — ${arr(o.notes).join(' ')}` : ''}`)))),
      ack ? h('label', { class: 'check' }, ack, h('span', null, 'Save the route although the backend did not answer correctly')) : null,
      r.canApply ? h('div', { class: 'actions' }, reviewed('I reviewed the route above.', (v) => { apply.disabled = !v; }), apply) : h('p', { class: 'muted' }, 'This integration cannot be applied yet.'));
  }
})();
