'use strict';
// Adopt an existing application (#adopt, #adopt/<id>): an application installed without this manager gets routes through the
// proxies, step by step, using its routing specification (lib\AppAdoption.psm1). Discovery changes nothing. Every changing step
// has its own confirmation, Cloudflare has a separate approval, and retiring an old proxy is separate from deleting it.
// Local reachability, DNS, TLS and sign-in are shown as separate checks; `unverified` is never presented as working.
(function () {
  const U = window.TPMUI;
  const { arr, h, fill, icon, plainChip, toast, api, withBusy, confirmDialog, technical } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const head = (title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, 'Services'), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const TONES = { ok: 'ok', done: 'ok', failed: 'err', pending: 'warn', unverified: 'neutral', warning: 'warn', refused: 'err', skipped: 'neutral' };
  const stateChip = (s) => plainChip(s, TONES[String(s).toLowerCase()] || 'neutral');
  const callout = (tone, items, title) => (items && items.length ? h('div', { class: `callout ${tone}` }, title ? h('h3', null, title) : null, h('ul', null, items.map((t) => h('li', null, t)))) : null);
  const form = (ctx) => ctx.state.forms.adopt || (ctx.state.forms.adopt = { request: { mode: 'none', externalHost: '', internalHost: '', authEndpoint: '', noAuth: false }, source: null, plan: null, checks: [], cf: null, retire: null, steps: [], manual: [] });

  const checksTable = (checks) => (arr(checks).length ? h('div', { class: 'table-wrap' }, h('table', null,
    h('thead', null, h('tr', null, ['Check', 'Route', 'What', 'State', 'Detail'].map((c) => h('th', null, c)))),
    h('tbody', null, arr(checks).map((c) => h('tr', null, h('td', null, c.kind), h('td', null, c.role), h('td', null, h('code', null, c.subject)), h('td', null, stateChip(c.state)), h('td', { class: 'small' }, c.detail)))))) : null);
  const stepList = (steps) => (arr(steps).length ? h('ul', { class: 'plain-list' }, arr(steps).map((s) => h('li', null, stateChip(s.status), ' ', s.name || s.summary, s.message ? h('span', { class: 'small muted' }, ` ${s.message}`) : null))) : null);

  // --- List ------------------------------------------------------------------------------------------------------------------
  P.adopt = async (main, ctx, sub) => {
    if (!ctx.state.setup) await ctx.refresh();
    if (!ctx.state.setup.installed) { fill(main, head('Adopt an application', 'Available after the installation.')); return; }
    if (sub) { await wizard(main, ctx, sub); return; }
    fill(main, head('Adopt an application', 'Reading Docker and Traefik…'));
    let d;
    try { d = await api('GET', '/api/adoption/discover'); } catch (e) { fill(main, head('Adopt an application', ''), h('div', { class: 'callout err' }, h('p', null, e.message))); return; }
    const inv = d.inventory;
    const specs = arr(inv.apps).filter((a) => a.kind === 'specification');
    const others = arr(inv.apps).filter((a) => a.kind === 'container');
    fill(main,
      head('Adopt an application', 'Applications already running on this PC, installed any way you like. Nothing is published or changed until you go through the steps and approve them.',
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => P.adopt(main, ctx, '')) }, icon('refresh'), 'Refresh')),
      h('section', { class: 'card' }, h('h2', null, 'Applications with a routing specification'),
        specs.length ? specs.map((a) => h('div', { class: 'card-row' },
          h('div', null, h('strong', null, a.displayName), a.multiBackend ? plainChip(`${a.backendCount} backends, ${a.routeCount} routes`, 'info') : null, h('p', { class: 'small muted' }, a.description),
            h('ul', { class: 'small plain-list' }, arr(a.containers).map((c) => h('li', null, h('code', null, c.container), ' ', stateChip(c.state), ` ${c.owner.manager}`, c.onProxyNetwork ? '' : ' - not on the proxy network')))),
          h('a', { class: 'btn primary', href: `#adopt/${encodeURIComponent(a.id)}` }, 'Adopt'))) : h('p', { class: 'empty' }, 'No application with a specification was found.')),
      h('section', { class: 'card' }, h('h2', null, 'Other containers'),
        others.length ? h('div', { class: 'table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Container', 'Managed by', 'Ports', 'State', ''].map((c) => h('th', null, c)))),
          h('tbody', null, others.map((c) => {
            const port = arr(c.ports)[0];
            return h('tr', null, h('td', null, h('code', null, c.name)), h('td', null, c.owner.manager), h('td', null, arr(c.ports).join(', ')), h('td', null, stateChip(c.state)),
              h('td', null, port ? h('a', { class: 'btn', href: `#adopt/container:${encodeURIComponent(c.id)}:${port}` }, 'Adopt') : null));
          })))) : h('p', { class: 'empty' }, 'None.')),
      callout('warn', arr(inv.conflicts).map((c) => c.detail), 'Conflicts'),
      inv.unreachable.length ? callout('warn', arr(inv.unreachable).map((n) => `${n}: on no network the proxy shares, and no published port`), 'Cannot be reached without a network change') : null,
      inv.redundant.length ? callout('info', arr(inv.redundant).map((r) => `${r.type} ${r.name} (${r.state}): ${r.detail}`), 'Possibly redundant proxy infrastructure (nothing is changed from here)') : null,
      h('section', { class: 'card' }, h('h2', null, 'Proxies'), h('ul', { class: 'plain-list' }, ['external', 'internal'].map((r) => { const t = d.targets[r]; return h('li', null, h('strong', null, r), ' ', stateChip(t.mode === 'absent' ? 'absent' : t.running ? 'ok' : 'stopped'), ` ${t.detail}`); }))));
  };

  // --- Wizard ----------------------------------------------------------------------------------------------------------------
  const STEPS = ['What will be adopted', 'Routes and network changes', 'Reachability from the proxies', 'Prepare and validate', 'Activate and test (no traffic moves)', 'Approve Cloudflare', 'Cut over', 'Verify', 'Retire the old proxy'];

  async function wizard(main, ctx, sub) {
    const f = form(ctx);
    const m = /^container:([^:]+):(\d+)$/.exec(sub);
    const source = m ? { container: m[1], port: Number(m[2]) } : { specId: sub };
    if (f.source && JSON.stringify(f.source) !== JSON.stringify(source)) { ctx.state.forms.adopt = null; return wizard(main, ctx, sub); }
    if (!f.defaults) {
      f.source = source;
      fill(main, head('Adopt', 'Reading the current state…'));
      const q = m ? `container=${encodeURIComponent(m[1])}&port=${m[2]}` : `specId=${encodeURIComponent(sub)}`;
      const start = await api('GET', `/api/adoption/status?${q}`);
      f.defaults = start;
      if (start.state) { f.request = start.state.request; f.phase = start.state.phase; f.checks = arr(start.state.checks); }
      else if (start.suggested) Object.assign(f.request, start.suggested);
    }
    const body = (extra) => ({ ...source, request: f.request, ...extra });
    const rerender = () => wizard(main, ctx, sub);
    const run = (fn) => (e) => withBusy(e.currentTarget, async () => { try { await fn(); } catch (err) { toast(err.message, true); } rerender(); });
    const adopt = f.defaults;
    const phase = f.phase || (adopt.state && adopt.state.phase) || 'new';
    const input = (key, placeholder) => { const i = h('input', { type: 'text', id: `adopt-${key}`, value: f.request[key] || '', placeholder, autocomplete: 'off', spellcheck: 'false' }); i.addEventListener('change', () => { f.request[key] = i.value.trim().toLowerCase(); f.plan = null; }); return i; };
    const mode = h('select', { id: 'adopt-mode' }, [['none', 'No routes (keep it standalone)'], ['internal', 'Internal only (LAN, no sign-in)'], ['external', 'External only (Cloudflare + authentik)'], ['both', 'Both']].map(([v, t]) => h('option', { value: v, selected: f.request.mode === v }, t)));
    mode.addEventListener('change', () => { f.request.mode = mode.value; f.plan = null; rerender(); });
    const noAuth = h('input', { type: 'checkbox', id: 'adopt-noauth', checked: !!f.request.noAuth });
    noAuth.addEventListener('change', () => { f.request.noAuth = noAuth.checked; f.plan = null; });
    const wantsExt = ['external', 'both'].includes(f.request.mode);
    const wantsInt = ['internal', 'both'].includes(f.request.mode);
    const plan = f.plan;
    const preview = run(async () => { f.plan = await api('POST', '/api/adoption/preview', body()); });

    const drift = arr(adopt.drift).filter((d) => d && d.detail);
    fill(main,
      head(`Adopt ${adopt.displayName || sub}`, 'Each step says what it does. Application containers, models and volumes stay where they are.',
        h('a', { class: 'btn', href: '#adopt' }, 'All applications')),
      h('ol', { class: 'adopt-steps small muted' }, STEPS.map((s) => h('li', null, s))),
      h('p', null, 'Current phase: ', stateChip(phase)),
      drift.length ? h('div', { class: 'callout warn' }, h('h3', null, 'This adoption has drifted'), h('ul', null, drift.map((d) => h('li', null, d.detail))),
        h('button', { type: 'button', class: 'btn', onclick: run(async () => { const ok = await confirmDialog({ title: 'Attach again', body: 'Runs docker network connect for the networks listed above. The containers keep running.', okText: 'Attach' }); if (!ok) return; const r = await api('POST', '/api/adoption/repair', body({ confirm: true })); f.steps = r.steps; f.defaults = null; }) }, 'Attach the networks again')) : null,

      h('section', { class: 'card' }, h('h2', null, 'Routing'),
        h('div', { class: 'form-grid' },
          h('label', { for: 'adopt-mode' }, 'Where should it be reachable?', mode),
          wantsExt ? h('label', { for: 'adopt-externalHost' }, 'External hostname', input('externalHost', 'voice.example.com')) : null,
          wantsExt ? h('label', { for: 'adopt-authEndpoint' }, 'authentik address', input('authEndpoint', 'http://authentik-server:9000')) : null,
          wantsExt ? h('label', { class: 'check' }, noAuth, h('span', null, 'Publish without sign-in (not recommended)')) : null,
          wantsInt ? h('label', { for: 'adopt-internalHost' }, 'Internal hostname', input('internalHost', 'voice.local.example.com')) : null),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', id: 'adopt-preview', onclick: preview }, 'Preview'))),

      plan ? renderPlan(plan) : null,
      plan && plan.ok ? h('section', { class: 'card' }, h('h2', null, 'Migration'),
        h('div', { class: 'actions wrap' },
          h('button', { type: 'button', class: 'btn', id: 'adopt-validate', onclick: run(async () => { const r = await api('POST', '/api/adoption/validate', body()); f.checks = r.checks; }) }, '1. Check reachability'),
          h('button', { type: 'button', class: 'btn', id: 'adopt-prepare', onclick: run(async () => { const r = await api('POST', '/api/adoption/prepare', body()); f.checks = r.checks; f.phase = r.phase; }) }, '2. Prepare and validate'),
          h('button', { type: 'button', class: 'btn', id: 'adopt-activate', onclick: run(async () => {
            const changes = arr(plan.networkChanges).map((n) => n.command);
            const ok = await confirmDialog({ title: 'Activate on the proxies', body: h('div', null, h('p', null, 'Writes the route files shown above. No traffic moves: visitors reach these routes only after DNS or the tunnel point here.'), changes.length ? h('p', null, 'Also runs (live, without restarting anything):') : null, changes.length ? h('ul', null, changes.map((c) => h('li', null, h('code', null, c)))) : null), okText: 'Activate' });
            if (!ok) return;
            const r = await api('POST', '/api/adoption/activate', body({ confirm: true }));
            f.steps = r.steps; f.checks = r.checks; f.phase = r.phase; f.plan = await api('POST', '/api/adoption/preview', body());
          }) }, '3. Activate and test'),
          h('button', { type: 'button', class: 'btn', id: 'adopt-test', onclick: run(async () => { const r = await api('POST', '/api/adoption/test', body()); f.checks = r.checks; f.phase = r.phase; }) }, 'Test again'),
          h('button', { type: 'button', class: 'btn', id: 'adopt-cfplan', onclick: run(async () => { f.cf = await api('POST', '/api/adoption/cutover-plan', body()); }) }, '4. Review the cutover')),
        stepList(f.steps), checksTable(f.checks)) : null,

      f.cf ? renderCutover(f, body, run) : null,
      phase === 'cutover' || phase === 'verified' || phase === 'cutover-failed' ? h('section', { class: 'card' }, h('h2', null, 'Verify and retire'),
        h('div', { class: 'actions wrap' },
          h('button', { type: 'button', class: 'btn', id: 'adopt-verify', onclick: run(async () => { const r = await api('POST', '/api/adoption/verify', body()); f.checks = r.checks; f.phase = r.phase; }) }, 'Verify'),
          h('button', { type: 'button', class: 'btn', id: 'adopt-retire-plan', onclick: run(async () => { f.retire = await api('POST', '/api/adoption/retire-plan', body()); }) }, 'Review the old proxy'))) : null,
      f.retire ? renderRetire(f, body, run, phase) : null,
      arr(f.manual).length ? callout('warn', f.manual, 'Needs you: these Cloudflare changes are not undone automatically') : null,
      adopt.state ? h('section', { class: 'card' }, h('h2', null, 'Roll back'), h('p', { class: 'small' }, 'Removes the adoption\'s route files, detaches only the networks it attached and removes only the Cloudflare records it created. Application data is not involved.'),
        h('button', { type: 'button', class: 'btn danger', id: 'adopt-rollback', onclick: run(async () => {
          const ok = await confirmDialog({ title: 'Roll back this adoption', body: 'Routes through the proxies stop answering.', okText: 'Roll back', danger: true });
          if (!ok) return;
          const r = await api('POST', '/api/adoption/rollback', body({ confirm: true }));
          f.steps = r.steps; f.manual = r.manual; f.phase = r.phase; f.checks = []; f.cf = null; f.retire = null; f.plan = null; f.defaults = null; toast('Rolled back.');
        }) }, 'Roll back')) : null);
  }

  function renderPlan(plan) {
    return [
      callout('err', plan.blockers, 'Blocked: nothing can be applied until these are resolved'),
      callout('warn', plan.warnings, 'Worth knowing'),
      h('section', { class: 'card' }, h('h2', null, 'What will be adopted'),
        h('div', { class: 'table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Backend', 'Where', 'State', 'Managed by'].map((c) => h('th', null, c)))),
          h('tbody', null, arr(plan.backends).map((b) => h('tr', null, h('td', null, b.id), h('td', null, h('code', null, b.container || `Windows host, port ${b.port}`)), h('td', null, stateChip(b.state)), h('td', { class: 'small' }, b.owner ? b.owner.manager : ''))))))
        , arr(plan.preserved).length ? h('p', { class: 'small muted' }, `Left untouched: ${arr(plan.preserved).join(', ')} and every other volume.`) : null),
      arr(plan.targets).map((t) => h('section', { class: 'card' }, h('h2', null, `${t.role} route: ${t.hostname}`), h('p', { class: 'small muted' }, `Proxy ${t.proxy || 'absent'}, entry point ${t.entryPoint || '-'}, sign-in: ${t.signIn}. File ${t.file.name}: ${t.file.action}.`),
        h('div', { class: 'table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Path', 'Backend', 'Priority', 'Details'].map((c) => h('th', null, c)))),
          h('tbody', null, arr(t.routers).map((r) => h('tr', null, h('td', null, h('code', null, r.path || '/')), h('td', null, h('code', null, r.url)), h('td', null, String(r.priority)),
            h('td', { class: 'small' }, [r.stripPrefix ? 'prefix removed' : '', r.websocket ? 'WebSocket' : '', r.maxRequestBodyBytes ? `upload limit ${r.maxRequestBodyBytes}` : ''].filter(Boolean).join(', '))))))),
        technical(String(t.file.content).split('\n'), `Generated ${t.file.name}`))),
      arr(plan.networkChanges).length ? h('section', { class: 'card' }, h('h2', null, 'Network changes'), h('ul', { class: 'plain-list' }, arr(plan.networkChanges).map((n) => h('li', null, h('code', null, n.command), h('div', { class: 'small muted' }, n.note), technical(n.composeSnippet, 'To keep it after a redeploy, add to its definition'))))) : h('p', { class: 'small muted' }, 'No network changes.'),
    ];
  }

  function renderCutover(f, body, run) {
    const cf = f.cf;
    const overwrites = arr(cf.actions).filter((a) => a.overwrite);
    const boxes = overwrites.map((a) => { const b = h('input', { type: 'checkbox', 'data-overwrite': a.id }); return h('label', { class: 'check' }, b, h('span', null, `Replace: ${a.summary}`)); });
    const cut = run(async () => {
      const ok = await confirmDialog({ title: 'Cut over', body: cf.needed && cf.connected ? 'These Cloudflare changes run now, and visitors start reaching the new routes.' : 'Records that the routes are in use. You make any DNS or tunnel change yourself.', okText: 'Cut over' });
      if (!ok) return;
      const confirmOverwrites = boxes.map((l) => l.querySelector('input')).filter((b) => b.checked).map((b) => b.dataset.overwrite);
      const r = await api('POST', '/api/adoption/cutover', body({ confirm: true, approveCloudflare: true, fingerprint: cf.fingerprint, confirmOverwrites }));
      f.steps = r.steps; f.manual = r.manual; f.phase = r.phase; f.cf = null;
    });
    return h('section', { class: 'card' }, h('h2', null, 'Cloudflare changes for approval'),
      callout('err', cf.errors, 'Blocked'), callout('info', cf.notes),
      arr(cf.actions).length ? h('ul', { class: 'plain-list' }, arr(cf.actions).map((a) => h('li', null, plainChip(a.kind, a.overwrite ? 'warn' : 'neutral'), ` ${a.summary}`, a.detail ? h('div', { class: 'small muted' }, a.detail) : null))) : null,
      arr(cf.manualSteps).length ? technical(arr(cf.manualSteps).map((s) => (typeof s === 'string' ? s : JSON.stringify(s))), 'Manual steps') : null,
      boxes, h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn primary', id: 'adopt-cutover', disabled: arr(cf.errors).length > 0, onclick: cut }, 'Approve and cut over')));
  }

  function renderRetire(f, body, run, phase) {
    const items = arr(f.retire.items);
    const act = (action, names) => run(async () => {
      const danger = action === 'delete';
      const typed = h('input', { type: 'text', id: 'adopt-retire-typed', autocomplete: 'off' });
      const ok = await confirmDialog({ title: danger ? 'Delete' : 'Stop', body: h('div', null, h('p', null, danger ? `Permanently removes: ${names.join(', ')}. Volumes are not removed.` : `Stops: ${names.join(', ')}. docker start undoes this.`), danger ? h('label', null, `Type ${names[0]} to confirm`, typed) : null), okText: danger ? 'Delete' : 'Stop', danger });
      if (!ok) return;
      const r = await api('POST', '/api/adoption/retire', body({ confirm: true, action, names, confirmText: typed.value.trim() }));
      f.steps = r.results; f.retire = await api('POST', '/api/adoption/retire-plan', body());
    });
    return h('section', { class: 'card' }, h('h2', null, 'Old proxy resources'), h('p', { class: 'small muted' }, f.retire.neverTouched),
      phase !== 'verified' ? h('p', { class: 'callout warn' }, 'Available after a successful verification.') : null,
      items.length ? h('div', { class: 'table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Type', 'Name', 'State', ''].map((c) => h('th', null, c)))),
        h('tbody', null, items.map((i) => h('tr', null, h('td', null, i.type), h('td', null, h('code', null, i.name)), h('td', null, i.state), h('td', null, i.blocked ? h('span', { class: 'small muted' }, i.blocked) : phase !== 'verified' ? null : [
          i.type === 'container' && i.state === 'running' ? h('button', { type: 'button', class: 'btn', onclick: act('stop', [i.name]) }, 'Stop') : null,
          !(i.type === 'container' && i.state === 'running') ? h('button', { type: 'button', class: 'btn danger', onclick: act('delete', [i.name]) }, 'Delete') : null,
        ])))))) : h('p', { class: 'empty' }, 'Nothing left to retire.'));
  }
})();
