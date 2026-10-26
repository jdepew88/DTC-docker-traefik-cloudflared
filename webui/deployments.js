'use strict';
// Installed apps (GET /api/apps): one card per installed instance. The status shows the long-running services and the
// one-time setup jobs separately ("3/3 running · 2 setup jobs completed") and opens the details: every service with its
// role, image, state, health check, exit code, dependencies and logs, the networks it is attached to (with the other
// containers there and their DNS names), published ports, volumes and hostnames (GET /api/apps/detail). Records of
// obsolete installations can be archived (nothing on the PC changes), Compose projects found on the PC adopted, and
// containers of completed setup jobs tidied up; all of it only after a preview and a confirmation.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, fill, icon, plainChip, toast, api, withBusy, field, gate, kv, technical, checkItem } = U;
  const P = (window.TPMPages = window.TPMPages || {});
  const brand = (id, fallback) => (P.explorerBrand ? P.explorerBrand(String(id).replace(/-/g, ''), fallback) : icon(fallback));
  const head = (eyebrow, title, text, ...actions) => h('div', { class: 'page-head' },
    h('div', null, h('div', { class: 'eyebrow' }, eyebrow), h('h1', null, title), text ? h('p', null, text) : null),
    actions.length ? h('div', { class: 'actions' }, actions) : null);
  const domId = (project) => `dep-${String(project).replace(/[^a-z0-9-]/g, '')}`;

  P.apps = async (main, ctx, sub) => {
    const s = ctx.state;
    if (!s.setup) await ctx.refresh();
    if (!s.setup.installed) { fill(main, head('Apps', 'Installed apps', 'Available after the installation.')); return; }
    const first = !main.querySelector('.dep-list');
    if (first) fill(main, head('Apps', 'Installed apps', 'Loading…'));
    s.appsOpen = s.appsOpen || {};
    if (sub) s.appsOpen[sub] = true;
    const data = await api('GET', '/api/apps');
    const reload = () => P.apps(main, ctx);
    // Keep the reader's place when the list is refreshed (actions, Refresh): no jump to the top.
    const y = window.scrollY;
    fill(main,
      head('Apps', 'Installed apps', 'Each app is a Docker Compose project in its own folder. The status counts the services that should keep running; one-time setup jobs that finished are counted separately.',
        h('a', { class: 'btn primary', href: '#catalog' }, icon('plus'), 'Install an app'), h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, reload) }, icon('refresh'), 'Refresh')),
      arr(data.apps).length ? h('div', { class: 'disc-list dep-list' }, data.apps.map((a) => installedCard(ctx, a, reload))) : h('p', { class: 'empty' }, 'No apps installed yet. Choose one in the App Catalog.'),
      arr(data.discovered).length ? discoveredSection(data.discovered, reload) : null,
      arr(data.archived).length ? archivedSection(data.archived, reload) : null);
    if (first && sub) { const el = document.getElementById(`${domId(sub)}-card`); if (el) el.scrollIntoView({ block: 'start' }); }
    else if (!first) window.scrollTo(0, y);
  };

  function installedCard(ctx, a, reload) {
    const s = ctx.state;
    const lc = a.lifecycle || { state: a.prepared ? 'prepared' : 'absent', headline: '', health: { text: '' }, services: [] };
    const st = L.deploymentState(lc.state);
    const id = domId(a.project);
    const out = h('div', { class: 'app-out', 'aria-live': 'polite' });
    const detail = h('div', { id, class: 'dep-details', hidden: true });
    const running = arr(lc.services).some((x) => x.state === 'running');
    const routes = arr(a.routes);
    const toggle = h('button', { type: 'button', class: `dep-status chip ${st.tone}`, 'aria-expanded': 'false', 'aria-controls': id, title: 'Show the services of this app' },
      icon(st.tone === 'ok' ? 'check' : st.tone === 'err' ? 'alert' : 'box'), h('span', null, lc.headline || st.label), icon('chevron'));
    const setOpen = (open) => {
      s.appsOpen[a.project] = open;
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      detail.hidden = !open;
      if (card) card.classList.toggle('open', open);
      if (open && !detail.dataset.loaded) loadDetail(a, detail, reload);
    };
    let card = null;
    toggle.addEventListener('click', () => setOpen(detail.hidden));
    const action = (verb, label) => h('button', { type: 'button', class: 'btn small', 'aria-label': `${label} ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
      if (verb !== 'start') { const ok = await U.confirmDialog({ title: `${label} ${a.name}`, okText: label, body: [verb === 'stop' ? 'The app stops until you start it again. Its data is kept.' : 'The app restarts; it is unavailable for a moment.'] }); if (!ok) return; }
      try { const r = await api('POST', '/api/apps/action', { project: a.project, action: verb, confirm: true }); toast(r.ok ? `${a.name}: ${verb} done` : `${a.name}: ${verb} failed`, !r.ok); } catch (x) { toast(x.message, true); }
      reload();
    }) }, label);
    card = h('article', { class: 'card disc-card dep-card', id: `${id}-card`, 'aria-label': L.instanceTitle(a), 'data-state': lc.state },
      h('div', { class: 'card-head' }, h('span', { class: 'xp-icon' }, brand(a.applicationId || a.appId, 'box')), h('h2', null, L.instanceTitle(a)), plainChip(a.project), a.origin === 'adopted' ? plainChip('adopted', 'info') : null,
        h('span', { class: 'grow' }), toggle),
      h('p', { class: `dep-health small ${lc.health && lc.health.verified ? 'ok' : ''}` }, lc.health ? lc.health.text : ''),
      arr(a.siblings).length ? h('p', { class: 'small hint' }, icon('info'), ` Another installation of ${a.name} is registered: ${a.siblings.join(', ')}. They are separate deployments; nothing is shared or merged.`) : null,
      a.updateAvailable ? h('p', null, plainChip('Update available', 'info')) : null,
      a.composeChanged ? h('p', { class: 'small hint warn' }, icon('alert'), ' compose.yaml was changed outside the manager (for example in Arcane or Portainer). The manager keeps those edits and asks before changing the file.') : null,
      routes.length ? h('ul', { class: 'checks' }, routes.map((r) => checkItem('ok', `Published as ${r.hostnames.join(', ')}`, `${r.publish ? 'Through Cloudflare' : 'Local route'}${r.authProvider ? ` · protected by ${r.authProvider}` : ''}`))) : h('p', { class: 'small muted' }, 'Not published.'),
      U.gateSpan('intermediate', h('p', { class: 'mono small' }, a.folder)),
      h('div', { class: 'actions' },
        a.localUrl && running ? h('a', { class: 'btn small', href: a.localUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Open ', icon('external')) : null,
        routes.length ? h('a', { class: 'btn small', href: `https://${routes[0].hostnames[0]}/`, target: '_blank', rel: 'noopener noreferrer' }, 'Open site ', icon('external'))
          : running ? h('a', { class: 'btn small', href: `#publish/${encodeURIComponent((arr(lc.services).find((x) => x.web) || arr(a.containers)[0] || { container: a.project }).container || a.project)}` }, icon('globe'), 'Publish…') : null,
        running ? action('restart', 'Restart') : action('start', 'Start'), running ? action('stop', 'Stop') : null,
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Logs of ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
          const r = await api('GET', `/api/apps/logs?project=${encodeURIComponent(a.project)}&tail=200`);
          fill(out, technical(arr(r.lines).length ? r.lines : ['(no output)'], `Logs of ${a.project} (secrets redacted)`));
          const d = $('details', out); if (d) d.open = true;
        }) }, icon('terminal'), 'Logs'),
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Check for updates of ${a.name}`, onclick: (e) => withBusy(e.currentTarget, () => updateFlow(a, out, reload)) }, icon('download'), 'Updates'),
        h('button', { type: 'button', class: 'btn small', 'aria-label': `Back up ${a.name}`, onclick: (e) => withBusy(e.currentTarget, async () => {
          const ok = await U.confirmDialog({ title: `Back up ${a.name}`, okText: 'Back up', body: ['Copies compose.yaml, .env, configuration folders and the data volumes into the app folder (backups\\<time>), readable by your Windows account only.', 'Apps with a database are stopped for a moment so the copy is consistent. Media and library folders are not copied.'] });
          if (!ok) return;
          const r = await api('POST', '/api/apps/backup', { project: a.project, confirm: true });
          fill(out, h('ul', { class: 'checks' }, checkItem(r.ok ? 'ok' : 'err', 'Backup', r.folder), arr(r.volumes).map((v) => checkItem(v.ok ? 'ok' : 'err', v.volume, `${v.sizeMB} MB`)), arr(r.skipped).map((v) => checkItem('neutral', v, 'Not backed up (cache or user data).'))));
        }) }, icon('archive'), 'Back up'),
        !running ? h('button', { type: 'button', class: 'btn small', 'aria-label': `Archive the record of ${a.project}`, onclick: (e) => withBusy(e.currentTarget, () => archiveFlow(a, reload)) }, icon('archive'), 'Archive record…') : null,
        h('button', { type: 'button', class: 'btn small danger-outline', 'aria-label': `Remove ${a.name}`, onclick: (e) => withBusy(e.currentTarget, () => removeFlow(a, reload)) }, 'Remove…')),
      detail, out);
    if (s.appsOpen[a.project]) setOpen(true);
    return card;
  }

  async function loadDetail(a, host, reload) {
    host.dataset.loaded = '1';
    fill(host, h('p', { class: 'muted small' }, 'Reading the containers…'));
    let d;
    try { d = await api('GET', `/api/apps/detail?project=${encodeURIComponent(a.project)}`); } catch (x) { host.dataset.loaded = ''; fill(host, h('p', { class: 'form-error' }, x.message)); return; }
    fill(host, detailView(a, d, reload));
  }

  function detailView(a, d, reload) {
    const lc = d.lifecycle || { services: [] };
    const groups = L.serviceGroups(lc);
    return [
      groups.map((g) => h('section', { class: 'dep-group', 'aria-label': g.title }, h('h3', null, g.title, ' ', h('span', { class: 'small muted' }, `(${g.items.length})`)),
        h('div', { class: 'dep-services' }, g.items.map((sv) => serviceCard(a, sv))))),
      arr(d.cleanup).length ? h('div', { class: 'callout' }, h('p', { class: 'small' }, `${d.cleanup.length} setup job container${d.cleanup.length > 1 ? 's' : ''} finished successfully and only sit${d.cleanup.length > 1 ? '' : 's'} there. Keeping them is fine; they are reported as completed.`),
        h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small', id: `${domId(a.project)}-tidy`, onclick: (e) => withBusy(e.currentTarget, () => cleanupFlow(a, reload)) }, 'Tidy up completed setup containers…'))) : null,
      networksView(d), portsView(d), volumesView(d), referencesView(d)];
  }

  function serviceCard(a, sv) {
    const out = h('div', { class: 'app-out' });
    const deps = arr(sv.dependsOn).map((x) => `${x.service} (${String(x.condition).replace(/^service_/, '').replace(/_/g, ' ')})`);
    const needed = arr(sv.dependents).map((x) => `${x.service} (${String(x.condition).replace(/^service_/, '').replace(/_/g, ' ')})`);
    return h('article', { class: 'dep-svc', 'data-service': sv.service, 'data-status': sv.status.key, 'aria-label': sv.label },
      h('div', { class: 'dep-svc-head' }, h('strong', null, sv.label), sv.roleName ? plainChip(sv.roleName, 'neutral') : null, h('span', { class: 'grow' }), plainChip(sv.status.label, L.statusTone(sv.status))),
      sv.status.detail ? h('p', { class: 'small muted' }, sv.status.detail) : null,
      sv.purpose ? h('p', { class: 'small' }, sv.purpose) : null,
      kv([['Service', sv.service], ['Container', sv.container || '(none)'], ['Image', L.shortImage(sv.image) || '-'], ['State', L.terminationText(sv)], ['Health', L.healthText(sv)],
        ['Role', `${sv.roleName || 'Unknown'} (${L.roleSource(sv.roleSource)})`], ['Restart policy', sv.restartPolicy || '-'],
        deps.length ? ['Waits for', deps.join(', ')] : null, needed.length ? ['Needed by', needed.join(', ')] : null].filter(Boolean)),
      U.gateSpan('advanced', h('p', { class: 'small muted' }, sv.roleReason)),
      sv.container ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small ghost', 'aria-label': `Logs of ${sv.label}`, onclick: (e) => withBusy(e.currentTarget, async () => {
        const r = await api('GET', `/api/apps/logs?project=${encodeURIComponent(a.project)}&service=${encodeURIComponent(sv.service)}&tail=100`);
        fill(out, technical(arr(r.lines).length ? r.lines : ['(no output)'], `Logs of ${sv.service} (secrets redacted)`)); const det = $('details', out); if (det) det.open = true;
      }) }, icon('terminal'), 'Logs')) : null, out);
  }

  function networksView(d) {
    if (!arr(d.networks).length) return null;
    return h('section', { class: 'dep-group', 'aria-label': 'Networks' }, h('h3', null, 'Networks'),
      h('p', { class: 'small muted' }, 'Containers reach each other by these names on a network they share. Nothing on a network is published to your LAN or the internet by being there.'),
      d.networks.map((n) => h('details', { class: 'more dep-net' }, h('summary', null, h('span', { class: 'mono' }, n.name), ' ', n.shared ? plainChip('shared with Traefik', 'info') : n.private ? plainChip('private to this app', 'neutral') : null, ` · ${arr(n.members).length} container${arr(n.members).length === 1 ? '' : 's'}`),
        h('div', { class: 'table-wrap' }, h('table', { class: 'dep-table' }, h('thead', null, h('tr', null, h('th', null, 'Container'), h('th', null, 'Reached as'), h('th', null, 'IP'))),
          h('tbody', null, arr(n.members).map((m) => h('tr', { class: m.inThisApp ? 'mine' : '' }, h('td', null, m.container, m.inThisApp ? '' : h('span', { class: 'small muted' }, ` (${m.project || 'other'})`)), h('td', { class: 'mono small' }, arr(m.dnsNames).join(', ') || '-'), h('td', { class: 'mono small' }, m.ip || '-')))))))));
  }

  function portsView(d) {
    const ports = arr(d.published);
    return h('section', { class: 'dep-group', 'aria-label': 'Published ports' }, h('h3', null, 'Published ports'),
      ports.length ? h('ul', { class: 'checks' }, ports.map((p) => checkItem(p.localOnly ? 'ok' : 'warn', `${p.hostIp || '0.0.0.0'}:${p.hostPort} → ${p.container} ${p.port}`, p.localOnly ? 'This PC only.' : 'Reachable from your network.')))
        : h('p', { class: 'small muted' }, 'None: the app is reached through Traefik only.'));
  }

  function volumesView(d) {
    const v = arr(d.volumes);
    if (!v.length) return null;
    return h('section', { class: 'dep-group', 'aria-label': 'Data volumes' }, h('h3', null, 'Data volumes'),
      kv(v.map((x) => [x.anonymous ? `anonymous ${x.name.slice(0, 12)}…` : x.name, `${x.container}: ${x.target}${x.readOnly ? ' (read-only)' : ''}${x.anonymous ? ' (created by Docker for this container)' : ''}`])));
  }

  function referencesView(d) {
    const items = [
      ...arr(d.routes).map((r) => checkItem('ok', `Route ${r.name}`, `${r.hostnames.join(', ')}${r.authProvider ? ` (sign-in: ${r.authProvider})` : ''}`)),
      ...arr(d.cloudflare).map((c) => checkItem('neutral', `Cloudflare: ${c.hostname}`, `${c.dnsRecord ? 'DNS record' : 'no DNS record'} managed here${c.accessApp ? ', Access application recorded' : ''}`)),
      ...arr(d.authentik).map((x) => checkItem('neutral', `authentik application ${x.slug}`, 'Who may open it is decided in authentik.')),
    ];
    return items.length ? h('section', { class: 'dep-group', 'aria-label': 'Hostnames and sign-in' }, h('h3', null, 'Hostnames and sign-in'), h('ul', { class: 'checks' }, items)) : null;
  }

  async function updateFlow(a, out, reload) {
    const p = await api('POST', '/api/apps/update/preview', { project: a.project });
    const blocked = arr(p.blocked).map((c) => h('li', { class: 'small' }, `${c.service}: ${c.note}`));
    if (!arr(p.changes).length) { fill(out, h('p', { class: 'hint ok' }, icon('check'), ' No update to apply.'), blocked.length ? h('ul', null, blocked) : null); return; }
    const ok = await U.confirmDialog({ title: `Update ${a.name}`, okText: 'Back up and update',
      body: [p.externalChanges ? h('div', { class: 'callout warn' }, h('p', null, p.externalNote)) : null,
        h('ul', null, p.changes.map((c) => h('li', { class: 'mono small' }, `${c.service}: ${c.from || '(none)'} → ${c.to}${c.note ? ` (${c.note})` : ''}`))), blocked.length ? h('ul', null, blocked) : null, p.notes,
        arr(p.releaseNotes).length ? h('p', null, 'Release notes: ', h('a', { href: p.releaseNotes[0].url, target: '_blank', rel: 'noopener noreferrer' }, p.releaseNotes[0].title)) : null, h('ul', null, arr(p.keeps).map((k) => h('li', { class: 'small' }, k)))],
      checkbox: p.externalChanges ? 'I reviewed the changes made outside the manager; update the image lines only.' : 'I read the release notes; the app restarts during the update.' });
    if (!ok) return;
    const r = await api('POST', '/api/apps/update/apply', { project: a.project, previewKey: p.previewKey, acknowledgeExternalChanges: !!p.externalChanges, confirm: true });
    toast(r.ok ? `${a.name} updated (backup ${r.backup})` : `${a.name}: update failed`, !r.ok);
    reload();
  }

  async function cleanupFlow(a, reload) {
    const p = await api('POST', '/api/apps/cleanup/plan', { project: a.project });
    if (!arr(p.candidates).length) { toast('Nothing to tidy up.'); return; }
    const ok = await U.confirmDialog({ title: `Tidy up ${a.name}`, okText: 'Remove these containers',
      body: [h('p', null, 'These containers of completed setup jobs would be removed:'), h('ul', null, p.candidates.map((c) => h('li', { class: 'mono small' }, `${c.container} (${c.label})`))),
        h('ul', null, arr(p.notes).map((n) => h('li', { class: 'small' }, n)))],
      checkbox: 'Remove only these containers; keep the definitions and data.' });
    if (!ok) return;
    try { const r = await api('POST', '/api/apps/cleanup', { project: a.project, key: p.key, confirm: true }); toast(r.ok ? 'Completed setup containers removed.' : 'Some containers were left alone.', !r.ok); } catch (x) { toast(x.message, true); }
    reload();
  }

  async function archiveFlow(a, reload) {
    const ok = await U.confirmDialog({ title: `Archive the record of ${a.project}`, okText: 'Archive record',
      body: [`The manager stops listing ${L.instanceTitle(a)} (${a.project}) as an installed app.`, 'Nothing on this PC changes: its folder, containers, volumes, routes, Cloudflare and authentik settings stay exactly as they are. You can restore the record at any time.'] });
    if (!ok) return;
    try { await api('POST', '/api/apps/archive', { project: a.project, confirm: true }); toast(`Record of ${a.project} archived. Nothing else changed.`); } catch (x) { toast(x.message, true); }
    reload();
  }

  function archivedSection(list, reload) {
    return h('details', { class: 'more card', id: 'apps-archived' }, h('summary', null, `Archived records (${list.length})`),
      h('p', { class: 'small muted' }, 'Hidden from the list; nothing on the PC was changed when they were archived.'),
      h('ul', { class: 'checks' }, list.map((a) => h('li', { class: 'check-item' }, h('span', null, h('strong', null, L.instanceTitle(a)), ' ', plainChip(a.project), h('span', { class: 'small muted' }, ` archived ${a.archivedAt || ''} · ${a.folder}`)), ' ',
        h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/apps/restore', { project: a.project, confirm: true }); toast(`Record of ${a.project} restored.`); reload(); }) }, 'Restore')))));
  }

  function discoveredSection(list, reload) {
    return h('section', { class: 'card', id: 'apps-discovered', 'aria-label': 'Found on this PC' }, h('h2', null, 'Found on this PC, not registered'),
      h('p', { class: 'small muted' }, 'Compose projects that run a catalog application but were not installed (or adopted) here. They are left alone unless you adopt them.'),
      h('ul', { class: 'checks' }, list.map((u) => h('li', { class: 'check-item' }, h('span', null, h('strong', null, u.name), ' ', plainChip(u.project), u.availability === 'retired' ? plainChip('no longer offered', 'neutral') : null,
        h('span', { class: 'small muted' }, ` ${u.reason}`)), ' ', h('button', { type: 'button', class: 'btn small', onclick: (e) => withBusy(e.currentTarget, () => adoptFlow(u, reload)) }, 'Review and adopt…')))));
  }

  async function adoptFlow(u, reload) {
    const p = await api('POST', '/api/apps/adopt/plan', { project: u.project });
    const label = h('input', { id: 'adopt-label', autocomplete: 'off', maxlength: '40', placeholder: 'optional, e.g. Testing' });
    const ok = await U.confirmDialog({ title: `Adopt ${u.project}`, okText: 'Adopt', body: [h('ul', { class: 'checks' }, arr(p.checks).map((c) => checkItem(c.state === 'ok' ? 'ok' : c.state === 'failed' ? 'err' : 'warn', c.label, c.message))),
      h('p', null, `Status: ${p.lifecycle ? p.lifecycle.headline : ''}`), h('ul', null, arr(p.keeps).map((k) => h('li', { class: 'small' }, k))), p.canAdopt ? field({ id: 'adopt-label', label: 'Instance label', control: label }) : null] });
    if (!ok || !p.canAdopt) return;
    try { await api('POST', '/api/apps/adopt', { project: u.project, reviewKey: p.reviewKey, label: label.value.trim(), confirm: true }); toast(`${u.project} adopted.`); } catch (x) { toast(x.message, true); }
    reload();
  }

  async function removeFlow(a, reload) {
    let inv = null;
    try { inv = await api('POST', '/api/apps/remove/plan', { project: a.project }); } catch (x) { toast(x.message, true); return; }
    const vols = h('input', { type: 'checkbox', id: 'rm-vols', disabled: !inv.dataDeletionAllowed }); const files = h('input', { type: 'checkbox', id: 'rm-files', disabled: !inv.createdByManager });
    const typed = h('input', { id: 'rm-typed', autocomplete: 'off', spellcheck: 'false', placeholder: a.project });
    const list = (title, items, text) => (arr(items).length ? [h('p', { class: 'small' }, h('strong', null, title)), h('ul', null, items.map((x) => h('li', { class: 'small' }, text(x))))] : null);
    const ok = await U.confirmDialog({ title: `Remove ${L.instanceTitle(a)}`, okText: 'Remove', danger: true,
      body: [arr(inv.blocking).length ? h('div', { class: 'callout warn' }, inv.blocking.map((b) => h('p', null, b))) : null,
        list('Containers', inv.containers, (c) => `${c.name}: ${c.action}`), list('Data volumes', inv.volumes, (v) => `${v.anonymous ? `anonymous volume ${v.name.slice(0, 12)}… of ${v.usedBy} (${v.target})` : v.name}: ${v.action}${arr(v.sharedWith).length ? ` (${v.sharedWith.join(', ')})` : ''}`),
        list('Networks', inv.networks, (n) => `${n.name}: ${n.action}`), list('Files', inv.files, (f) => `${f.name}: ${f.action}`), list('Left unchanged', inv.references, (r) => r),
        h('label', { class: 'check' }, vols, h('span', null, inv.dataDeletionAllowed ? 'Also delete its data volumes (cannot be undone)' : 'Data volumes cannot be deleted here (shared or not created by the manager)')),
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

  // Install wizard: existing installations of the application, with what can be done instead of a second installation.
  P.installExisting = (a, f, onChange) => {
    const existing = arr(f.existing);
    if (!existing.length) return null;
    const current = existing.filter((e) => !e.archived);
    const another = h('input', { type: 'checkbox', id: 'inst-another', checked: !!f.anotherInstance });
    const label = h('input', { id: 'inst-label', autocomplete: 'off', maxlength: '40', value: f.instanceLabel || '', placeholder: 'e.g. Testing' });
    another.addEventListener('change', () => { f.anotherInstance = another.checked; f.plan = null; f.reviewed = false; onChange(); });
    label.addEventListener('change', () => { f.instanceLabel = label.value.trim(); f.plan = null; f.reviewed = false; onChange(); });
    const item = (e) => h('li', { class: 'dep-existing', 'data-project': e.project },
      h('div', null, h('strong', null, e.project), ' ', e.archived ? plainChip('archived record', 'neutral') : e.source === 'docker' ? plainChip('not registered', 'warn') : plainChip(e.headline || e.state || 'registered', e.state === 'running' ? 'ok' : 'neutral'),
        h('p', { class: 'small muted' }, `${e.folder || ''}${arr(e.hostnames).length ? ` · ${e.hostnames.join(', ')}` : ''}`), h('p', { class: 'small' }, e.reason)),
      h('div', { class: 'actions' },
        e.source === 'registry' && !e.archived ? h('a', { class: 'btn small', href: `#apps/${encodeURIComponent(e.project)}` }, 'Manage existing') : null,
        e.source === 'docker' ? h('a', { class: 'btn small', href: '#apps' }, 'Adopt existing…') : null,
        e.source === 'registry' && !e.archived && !e.containers ? h('button', { type: 'button', class: 'btn small', onclick: (ev) => withBusy(ev.currentTarget, async () => {
          const ok = await U.confirmDialog({ title: `Archive the record of ${e.project}`, okText: 'Archive record', body: ['The manager stops listing it. Its folder and files stay on disk; nothing else changes. You can restore the record on the Installed apps page.'] });
          if (!ok) return;
          try { await api('POST', '/api/apps/archive', { project: e.project, confirm: true }); e.archived = true; toast(`Record of ${e.project} archived.`); f.plan = null; onChange(); } catch (x) { toast(x.message, true); }
        }) }, 'Archive obsolete record…') : null,
        e.source === 'registry' && !e.archived ? h('a', { class: 'btn small ghost', href: `#apps/${encodeURIComponent(e.project)}` }, 'Uninstall…') : null));
    return h('section', { class: `callout ${current.length ? 'warn' : ''} inst-existing`, id: 'inst-existing', 'aria-label': `${a.name} is already installed` },
      h('h2', null, current.length ? `${a.name} is already installed on this PC` : `Earlier ${a.name} records`),
      h('p', { class: 'small' }, current.length ? 'Use the existing installation, or install another, separate instance on purpose. Nothing is merged: each instance has its own project, folder, data and port.' : 'Only archived records exist; this will be a new installation.'),
      h('ul', { class: 'dep-existing-list' }, existing.map(item)),
      current.length ? [h('label', { class: 'check' }, another, h('span', null, 'Install another, separate instance')), f.anotherInstance ? field({ id: 'inst-label', label: 'Instance label (optional)', control: label, hint: 'Shown next to the name, e.g. Production or Testing.' }) : null] : null);
  };
})();
