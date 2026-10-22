'use strict';
// App Catalog (GET /api/catalog), the installation wizard (plan -> preview -> validate -> approve -> deploy -> health ->
// publish) and the installed apps (GET /api/apps) with start / stop / restart, logs, health, updates and removal.
// Every installed app is an ordinary Compose project in its own folder; this page only drives docker compose.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, clear, fill, icon, plainChip, chip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const brand = (id, fallback) => (P.explorerBrand ? P.explorerBrand(id.replace(/-/g, ''), fallback) : icon(fallback));
  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const CATEGORY = { monitoring: 'Monitoring', media: 'Media', management: 'Container management', authentication: 'Sign-in and identity', networking: 'Networking', tools: 'Tools', productivity: 'Productivity' };
  const supportChip = (p) => ({ supported: plainChip('Windows: supported', 'ok'), untested: plainChip('Windows: untested', 'warn') })[p.support] || plainChip('Not on this platform', 'err');
  const stateTone = (s) => (s === 'ok' ? 'ok' : s === 'failed' ? 'err' : s === 'warning' ? 'warn' : 'neutral');
  async function loadCatalog(ctx) { ctx.state.catalog = await api('GET', '/api/catalog'); return ctx.state.catalog; }

  // --- Catalog ---------------------------------------------------------------------------------------------------------
  const filt = { q: '', cat: '' };
  P.catalog = async (main, ctx) => {
    fill(main, head('Apps', 'App Catalog', 'Loading…'));
    const cat = await loadCatalog(ctx);
    const gridHost = h('div', { class: 'cat-grid' });
    const q = h('input', { type: 'search', id: 'cat-q', value: filt.q, placeholder: 'Search apps', autocomplete: 'off' });
    const sel = h('select', { id: 'cat-cat' }, h('option', { value: '' }, 'All categories'), Object.entries(CATEGORY).map(([k, v]) => h('option', { value: k, selected: filt.cat === k }, v)));
    q.addEventListener('input', () => { filt.q = q.value.trim().toLowerCase(); draw(); });
    sel.addEventListener('change', () => { filt.cat = sel.value; draw(); });
    function draw() {
      const list = arr(cat.apps).filter((a) => (!filt.cat || a.category === filt.cat) && (!filt.q || `${a.name} ${a.description} ${a.category}`.toLowerCase().includes(filt.q)));
      fill(gridHost, list.length ? list.map((a) => appCard(a)) : h('p', { class: 'empty' }, 'No app matches.'));
    }
    fill(main,
      head('Apps', 'App Catalog', 'Curated applications, installed as ordinary Docker Compose projects in their own folders. They keep running, and stay yours, without this manager.',
        h('a', { class: 'btn', href: '#apps' }, icon('box'), 'Installed apps')),
      h('div', { class: 'disc-toolbar' }, field({ id: 'cat-q', label: 'Search', control: q }), field({ id: 'cat-cat', label: 'Category', control: sel })),
      gridHost,
      gate('advanced', h('section', { class: 'card' }, h('h2', null, 'Catalog sources'),
        h('p', { class: 'muted small' }, 'Only the curated catalog can install apps in this version. Images found in registries are image discoveries, not installable templates; community templates are never executed automatically.'),
        h('ul', { class: 'checks' }, arr(cat.sources).map((s) => checkItem(s.enabled ? 'ok' : 'neutral', s.name, s.enabled ? 'enabled' : 'planned'))))),
      arr(cat.invalid).length ? gate('expert', h('div', { class: 'callout warn' }, h('p', null, 'Invalid manifests (ignored): '), h('ul', null, cat.invalid.map((x) => h('li', null, `${x.file}: ${x.errors.join('; ')}`))))) : null,
      gate('expert', technical([JSON.stringify(cat, null, 2)], 'Raw catalog')));
    draw();
  };

  function appCard(a) {
    const socket = arr(a.privileges).some((p) => p.kind === 'docker-socket');
    return h('article', { class: 'card cat-card', 'aria-label': a.name },
      h('div', { class: 'card-head' }, h('span', { class: 'xp-icon' }, brand(a.id, 'box')), h('div', null, h('h2', null, a.name), h('span', { class: 'small muted' }, CATEGORY[a.category] || a.category))),
      h('p', null, a.description),
      h('div', { class: 'chips' }, supportChip(a.platform), plainChip(a.license), socket ? plainChip('Controls Docker', 'warn') : null, arr(a.installedAs).length ? plainChip(`Installed: ${a.installedAs.join(', ')}`, 'ok') : null),
      U.gateSpan('advanced', h('p', { class: 'mono small' }, arr(a.services).map((s) => s.image.replace(/@sha256:[0-9a-f]{64}/, '@sha256:…')).join(', ') || (a.imageReference || '').replace(/@sha256:[0-9a-f]{64}/, '@sha256:…'))),
      h('div', { class: 'actions' }, a.installable && a.platform.installable
        ? h('a', { class: 'btn primary', href: `#install/${a.id}`, 'aria-label': `Install ${a.name}` }, icon('download'), 'Install…')
        : h('p', { class: 'small muted' }, a.installNote || 'Not installable on this platform.'),
        arr(a.docs)[0] ? h('a', { class: 'btn ghost', href: a.docs[0].url, target: '_blank', rel: 'noopener noreferrer', 'aria-label': `${a.name} documentation` }, 'Docs ', icon('external')) : null));
  }

  // --- Installation wizard -------------------------------------------------------------------------------------------------
  P.install = async (main, ctx, sub) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    fill(main, head('Apps', 'Install an app', 'Loading…'));
    const cat = s.catalog || await loadCatalog(ctx);
    const a = arr(cat.apps).find((x) => x.id === sub);
    if (!a || !a.installable) { fill(main, head('Apps', 'Install an app', ''), h('div', { class: 'callout err' }, h('p', null, a ? a.installNote : `No catalog app '${sub}'.`)), h('a', { href: '#catalog' }, '← App Catalog')); return; }
    if (!s.forms.install || s.forms.install.appId !== a.id) {
      const d = await api('GET', `/api/catalog/defaults?id=${encodeURIComponent(a.id)}`);
      const web = arr(a.services).flatMap((x) => x.ports).find((p) => p.primary) || { container: 8080 };
      s.forms.install = { appId: a.id, project: d.project, folder: d.folder, folderAuto: true, timezone: d.timezone, local: false, localPort: String(web.container >= 1024 ? web.container : 18000 + web.container), inputs: {}, privileges: false, reviewed: false, plan: null, result: null };
    }
    renderInstall(main, ctx, a);
  };

  function renderInstall(main, ctx, a) {
    const s = ctx.state; const f = s.forms.install;
    const rerender = () => renderInstall(main, ctx, a);
    const invalidate = () => { if (f.plan) { f.plan = null; f.reviewed = false; rerender(); } };
    const net = s.status && s.status.instance ? s.status.instance.proxyNetwork : 'proxy';
    const webSvc = arr(a.services).find((x) => x.ports.some((p) => p.primary)) || arr(a.services)[0];
    const webPort = (webSvc.ports.find((p) => p.primary) || {}).container;
    const container = arr(a.services).length === 1 ? f.project : `${f.project}-${webSvc.name}`;
    const step = (n, title, ...body) => h('section', { class: 'wiz-step', 'aria-labelledby': `inst-${n}` }, h('h2', { id: `inst-${n}` }, h('span', { class: 'step-num' }, String(n)), title), body);
    const text = (id, value, onInput, attrs = {}) => { const el = h('input', { id, value, autocomplete: 'off', spellcheck: 'false', ...attrs }); el.addEventListener('input', () => { onInput(el.value); invalidate(); }); el.addEventListener('change', () => { f.plan = null; f.reviewed = false; rerender(); }); return el; };
    const project = text('inst-project', f.project, (v) => { f.project = v.trim().toLowerCase(); if (f.folderAuto) { f.folder = f.folder.replace(/[^\\]+$/, f.project); folder.value = f.folder; } });
    const folder = text('inst-folder', f.folder, (v) => { f.folder = v.trim(); f.folderAuto = false; });
    const folderInputs = arr(a.inputs).filter((i) => i.type === 'folder');
    const otherInputs = arr(a.inputs).filter((i) => i.type !== 'folder' && i.type !== 'generated');
    const generated = arr(a.inputs).filter((i) => i.type === 'generated');
    const inputField = (i) => field({ id: `inst-in-${i.id}`, label: `${i.label}${i.required ? '' : ' (optional)'}`, hint: i.help,
      control: text(`inst-in-${i.id}`, f.inputs[i.id] || '', (v) => { f.inputs[i.id] = v; }, i.type === 'secret' ? { type: 'password' } : {}) });
    const localBox = h('input', { type: 'checkbox', checked: f.local }); localBox.addEventListener('change', () => { f.local = localBox.checked; f.plan = null; rerender(); });
    const localPort = text('inst-port', f.localPort, (v) => { f.localPort = v.trim(); }, { inputmode: 'numeric' });
    const tz = text('inst-tz', f.timezone, (v) => { f.timezone = v.trim(); });
    const privBox = h('input', { type: 'checkbox', checked: f.privileges }); privBox.addEventListener('change', () => { f.privileges = privBox.checked; syncDeploy(); });
    const reviewed = h('input', { type: 'checkbox', checked: f.reviewed, disabled: !f.plan || !f.plan.canApply }); reviewed.addEventListener('change', () => { f.reviewed = reviewed.checked; syncDeploy(); });
    const deploy = h('button', { type: 'button', class: 'btn primary' }, icon('rocket'), 'Deploy');
    const needsPriv = arr(a.privileges).length > 0;
    function syncDeploy() { deploy.disabled = !(f.plan && f.plan.canApply && f.reviewed && (!needsPriv || f.privileges)) || !!f.result; }
    const err = h('p', { class: 'form-error', role: 'alert' });
    const preview = h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, async () => {
      err.textContent = '';
      try {
        f.plan = await api('POST', '/api/catalog/plan', { appId: a.id, project: f.project, folder: f.folder, timezone: f.timezone, localPort: f.local ? parseInt(f.localPort, 10) || 0 : 0, inputs: f.inputs, reuseData: !!f.reuseData });
        f.reviewed = false; rerender(); const p = $('#inst-7'); if (p) p.scrollIntoView({ block: 'start' });
      } catch (x) { err.textContent = x.message; }
    }) }, icon('eye'), f.plan ? 'Preview again' : 'Preview the Compose project');
    deploy.addEventListener('click', () => withBusy(deploy, async () => {
      const ok = await U.confirmDialog({ title: `Deploy ${a.name}`, okText: 'Deploy',
        body: [`Creates ${f.plan.folder} (compose.yaml, .env, README.md) and runs docker compose up -d. Images are downloaded first; this can take several minutes.`,
          'Nothing is published until you choose to in the last step.'] });
      if (!ok) return;
      f.progress = true; rerender();
      try { f.result = await api('POST', '/api/catalog/apply', { planId: f.plan.planId, confirm: true, confirmPrivileges: f.privileges }); }
      catch (x) { f.result = { ok: false, steps: [{ name: 'Deploy', status: 'Failed', message: x.message }] }; f.plan = null; }
      f.progress = false; rerender(); const r = $('#inst-10'); if (r) r.scrollIntoView({ block: 'start' });
    }));
    syncDeploy();
    const plan = f.plan; const res = f.result;
    const health = res && res.health;
    const exposureWarn = a.exposure && a.exposure.warning;
    fill(main,
      head('Apps', `Install ${a.name}`, 'Eleven steps; nothing changes on this PC until step 9.'),
      h('p', null, h('a', { href: '#catalog' }, '← App Catalog')),
      h('form', { class: 'card wizard', novalidate: true, 'aria-label': `Install ${a.name}`, onsubmit: (e) => e.preventDefault() },
        step(1, 'The app', h('div', { class: 'cat-head' }, h('span', { class: 'xp-icon big' }, brand(a.id, 'box')), h('div', null, h('strong', null, a.name), h('p', { class: 'small muted' }, a.description))),
          kv([['Maintainer', a.maintainer], ['Licence', a.license], ['Platform', `${a.platform.platform}: ${a.platform.support}`]]),
          h('ul', { class: 'xp-docs' }, arr(a.docs).map((d) => h('li', null, h('a', { href: d.url, target: '_blank', rel: 'noopener noreferrer' }, d.title, ' ', icon('external')))))),
        step(2, 'Installation location', h('div', { class: 'grid' },
          field({ id: 'inst-project', label: 'Project name', control: project, hint: 'The Compose project and container name; also prefixes its data volumes.' }),
          field({ id: 'inst-folder', label: 'Folder', control: folder, hint: 'A new or empty folder for compose.yaml, .env and README.md.' }))),
        step(3, 'Storage', h('ul', { class: 'checks' }, arr(a.services).flatMap((sv) => sv.volumes).filter((v) => v.kind !== 'folder').map((v) => checkItem('neutral', `${f.project}_${v.name} → ${v.target}`, `${v.description} Docker volume: kept across updates, restarts and removal unless you delete it.`))),
          folderInputs.map(inputField),
          arr(a.services).every((sv) => !sv.volumes.length) ? h('p', { class: 'muted small' }, 'This app stores no data.') : null),
        step(4, 'Networking', h('p', null, `Joins the shared network '${net}', so Traefik can reach it as `, h('code', null, `http://${container}:${webPort}`), '. It is not reachable from the Internet or your LAN until you publish it (step 11).'),
          h('label', { class: 'check' }, localBox, h('span', null, 'Also open it on this PC (127.0.0.1 only)')),
          f.local ? field({ id: 'inst-port', label: 'Local port', control: localPort, hint: `http://127.0.0.1:${f.localPort || '?'}/` }) : null),
        step(5, 'Settings and secrets', field({ id: 'inst-tz', label: 'Time zone', control: tz, hint: 'IANA name, e.g. Europe/Berlin.' }), otherInputs.map(inputField),
          generated.length ? h('ul', { class: 'checks' }, generated.map((g) => checkItem('ok', g.label, 'Generated on this PC and stored only in the app\'s .env (readable by your Windows account only). Never shown here.'))) : null),
        step(6, 'Dependencies and privileges',
          needsPriv ? [h('div', { class: 'callout warn' }, arr(a.privileges).map((p) => h('p', null, h('strong', null, 'Elevated access: '), p.explain))), h('label', { class: 'check' }, privBox, h('span', null, 'I understand what this app can do on this PC.'))] : h('p', { class: 'muted' }, 'No elevated privileges: no Docker socket, no host network, no added capabilities.'),
          arr(a.dependencies).length ? h('p', null, `Also runs: ${a.dependencies.join(', ')}`) : null,
          arr(a.security).length ? h('ul', null, a.security.map((x) => h('li', { class: 'small' }, x))) : null),
        step(7, 'Preview the Compose project', h('div', { class: 'actions' }, preview), err,
          plan && plan.compose ? [technical(plan.compose.split('\n'), 'compose.yaml'), technical(plan.envPreview.split('\n'), '.env (secrets masked)')] : null),
        step(8, 'Validation', plan ? [h('ul', { class: 'checks' }, arr(plan.checks).map((c) => checkItem(stateTone(c.state), c.label, c.message))),
          arr(plan.existingVolumes).length ? h('label', { class: 'check' }, (() => { const b = h('input', { type: 'checkbox', checked: !!f.reuseData }); b.addEventListener('change', () => { f.reuseData = b.checked; f.plan = null; rerender(); }); return b; })(), h('span', null, `Reuse the data in ${plan.existingVolumes.join(', ')} (then preview again)`)) : null] : h('p', { class: 'muted' }, 'Runs with the preview: folder, project name, volumes, ports, network, settings and docker compose config.')),
        step(9, 'Approve and deploy', h('label', { class: 'check' }, reviewed, h('span', null, 'I reviewed the Compose project and the checks.')), h('div', { class: 'actions' }, deploy),
          f.progress ? h('p', { class: 'muted', role: 'status' }, 'Downloading images and starting… this can take several minutes.') : null),
        step(10, 'Health', res ? [h('ul', { class: 'checks' }, arr(res.steps).map((x) => checkItem(x.status === 'Done' ? 'ok' : 'err', x.name, x.message))),
          health ? h('ul', { class: 'checks' }, checkItem(health.running ? 'ok' : 'err', 'Container running', arr(health.containers).map((c) => `${c.name}: ${c.status}`).join(', ')),
            health.http ? checkItem(health.http.result === 'http' || health.http.result === 'https' ? 'ok' : 'warn', 'Web interface answers', health.http.detail) : checkItem('neutral', 'Web interface answers', 'Not checked.')) : null,
          gate('expert', res.output ? technical(res.output.split('\n'), 'docker compose output') : null)] : h('p', { class: 'muted' }, 'Checked right after deploying.')),
        step(11, 'Publish (optional)', res && res.ok ? [
          exposureWarn ? h('div', { class: 'callout warn' }, h('p', null, exposureWarn)) : null,
          h('div', { class: 'actions' }, h('a', { class: 'btn primary', href: `#publish/${encodeURIComponent(res.container)}` }, icon('globe'), 'Publish through Traefik…'), h('a', { class: 'btn', href: '#apps' }, 'Installed apps'))] : h('p', { class: 'muted' }, 'After deploying: publish it with a hostname, behind Cloudflare Access by default, or keep it private.'))));
  }

  // --- Installed apps ------------------------------------------------------------------------------------------------------
  P.apps = async (main, ctx) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    if (!s.setup.installed) { fill(main, head('Apps', 'Installed apps', 'Available after the installation.')); return; }
    fill(main, head('Apps', 'Installed apps', 'Loading…'));
    const data = await api('GET', '/api/apps');
    const reload = () => P.apps(main, ctx);
    fill(main,
      head('Apps', 'Installed apps', 'Apps installed from the catalog. Each is a Compose project in its own folder; external stacks are never changed here.',
        h('a', { class: 'btn primary', href: '#catalog' }, icon('plus'), 'Install an app'), h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, reload) }, icon('refresh'), 'Refresh')),
      arr(data.apps).length ? h('div', { class: 'disc-list' }, data.apps.map((a) => installedCard(ctx, a, reload))) : h('p', { class: 'empty' }, 'No apps installed yet. Choose one in the App Catalog.'));
  };

  function installedCard(ctx, a, reload) {
    const out = h('div', { class: 'app-out', 'aria-live': 'polite' });
    const up = a.running > 0 && a.running === a.total;
    const routes = arr(a.routes);
    const action = (verb, label, danger) => h('button', { type: 'button', class: `btn small${danger ? ' danger-outline' : ''}`, 'aria-label': `${label} ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
      if (verb !== 'start') { const ok = await U.confirmDialog({ title: `${label} ${a.name}`, okText: label, body: [verb === 'stop' ? 'The app stops until you start it again. Its data is kept.' : 'The app restarts; it is unavailable for a moment.'] }); if (!ok) return; }
      try { const r = await api('POST', '/api/apps/action', { project: a.project, action: verb, confirm: true }); toast(r.ok ? `${a.name}: ${verb} done` : `${a.name}: ${verb} failed`, !r.ok); } catch (x) { toast(x.message, true); }
      reload();
    }) }, label);
    return h('article', { class: 'card disc-card', 'aria-label': a.name },
      h('div', { class: 'card-head' }, h('span', { class: 'xp-icon' }, brand(a.appId, 'box')), h('h2', null, a.name), plainChip(a.project), h('span', { class: 'grow' }),
        a.total === 0 ? plainChip('no containers', 'warn') : up ? chip('healthy', `running ${a.running}/${a.total}`) : plainChip(`running ${a.running}/${a.total}`, 'err')),
      a.updateAvailable ? h('p', null, plainChip('Update available', 'info')) : null,
      routes.length ? h('ul', { class: 'checks' }, routes.map((r) => checkItem('ok', `Published as ${r.hostnames.join(', ')}`, r.publish ? 'Through Cloudflare' : 'Local route'))) : h('p', { class: 'small muted' }, 'Not published.'),
      U.gateSpan('intermediate', h('p', { class: 'mono small' }, a.folder)),
      gate('advanced', kv(arr(a.containers).map((c) => [c.name, `${c.status} · ${c.image.replace(/@sha256:[0-9a-f]{64}/, '@sha256:…')}`]))),
      h('div', { class: 'actions' },
        a.localUrl ? h('a', { class: 'btn small', href: a.localUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Open ', icon('external')) : null,
        routes.length ? h('a', { class: 'btn small', href: `https://${routes[0].hostnames[0]}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Open site ', icon('external')) : h('a', { class: 'btn small', href: `#publish/${encodeURIComponent(arr(a.containers)[0] ? a.containers[0].name : a.project)}` }, icon('globe'), 'Publish…'),
        up ? action('restart', 'Restart') : action('start', 'Start'), up ? action('stop', 'Stop') : null,
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Health of ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('POST', '/api/apps/health', { project: a.project });
          fill(out, h('ul', { class: 'checks' }, checkItem(r.running ? 'ok' : 'err', 'Container running', arr(r.containers).map((c) => `${c.name}: ${c.status}`).join(', ')),
            r.http ? checkItem(r.http.result === 'http' || r.http.result === 'https' ? 'ok' : 'warn', 'Web interface answers', r.http.detail) : checkItem('neutral', 'Web interface answers', 'Not checked (not running).')));
        }) }, icon('pulse'), 'Health'),
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Logs of ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('GET', `/api/apps/logs?project=${encodeURIComponent(a.project)}&tail=200`);
          fill(out, technical(arr(r.lines).length ? r.lines : ['(no output)'], `Logs of ${a.project} (secrets redacted)`));
          const d = $('details', out); if (d) d.open = true;
        }) }, icon('terminal'), 'Logs'),
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Check for updates of ${a.name}`, onclick: (e) => withBusy(e.currentTarget, () => updateFlow(a, out, reload)) }, icon('download'), 'Updates'),
        h('button', { type: 'button', class: 'btn small danger-outline', 'aria-label': `Remove ${a.name}`, onclick: (e) => withBusy(e.currentTarget, () => removeFlow(a, reload)) }, 'Remove')),
      out);
  }

  async function updateFlow(a, out, reload) {
    const p = await api('POST', '/api/apps/update/preview', { project: a.project });
    if (!arr(p.changes).length) { fill(out, h('p', { class: 'hint ok' }, icon('check'), ' Up to date with the catalog.')); return; }
    const ok = await U.confirmDialog({ title: `Update ${a.name}`, okText: 'Update',
      body: [h('ul', null, p.changes.map((c) => h('li', { class: 'mono small' }, `${c.service}: ${c.from || '(none)'} → ${c.to}`))), p.notes, h('ul', null, arr(p.keeps).map((k) => h('li', { class: 'small' }, k)))],
      checkbox: 'I read the release notes; the app restarts during the update.' });
    if (!ok) return;
    const r = await api('POST', '/api/apps/update/apply', { project: a.project, previewKey: p.previewKey, confirm: true });
    toast(r.ok ? `${a.name} updated (backup ${r.backup})` : `${a.name}: update failed`, !r.ok);
    reload();
  }

  async function removeFlow(a, reload) {
    const vols = h('input', { type: 'checkbox', id: 'rm-vols' }); const files = h('input', { type: 'checkbox', id: 'rm-files' });
    const typed = h('input', { id: 'rm-typed', autocomplete: 'off', spellcheck: 'false', placeholder: a.project });
    const ok = await U.confirmDialog({ title: `Remove ${a.name}`, okText: 'Remove', danger: true,
      body: ['Stops and removes the containers. By default the data volumes and the project folder are kept, so reinstalling with the same project name finds the data again.',
        h('label', { class: 'check' }, vols, h('span', null, 'Also delete its data volumes (cannot be undone)')),
        h('label', { class: 'check' }, files, h('span', null, 'Also delete compose.yaml, .env and README.md in its folder')),
        field({ id: 'rm-typed', label: `To delete data, type the project name (${a.project})`, control: typed }),
        h('p', { class: 'small muted' }, 'Folders you chose for media or files are never deleted.')],
      checkbox: 'Remove the containers.' });
    if (!ok) return;
    try {
      const r = await api('POST', '/api/apps/remove', { project: a.project, confirm: true, deleteVolumes: vols.checked, deleteFolder: files.checked, confirmText: typed.value.trim() });
      toast(r.volumesDeleted ? `${a.name} removed with its data` : `${a.name} removed; data kept (${arr(r.keptVolumes).join(', ') || 'no volumes'})`);
    } catch (x) { toast(x.message, true); }
    reload();
  }
})();
