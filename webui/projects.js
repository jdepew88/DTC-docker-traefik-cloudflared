'use strict';
// Projects: continue with an existing deployment (attach) or start a new one. Attaching only reads: the review
// shows what was detected and verified, and "Open existing deployment" makes it the active project without changing
// its files, Docker or Cloudflare. Upgrading application files is a separate, previewed and confirmed step; restoring
// from a backup file is a third, different operation (Backups page).
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { $, arr, h, clear, fill, icon, chip, plainChip, toast, api, withBusy, field, gate, help, kv, technical } = U;
  const P = (window.TPMPages = window.TPMPages || {});

  const KIND = {
    manager: ['Installed', 'ok'], draft: ['Setup not finished', 'info'], legacy: ['Earlier layout (read-only)', 'warn'],
    missing: ['Folder not found', 'err'], other: ['Not a deployment', 'neutral'], package: ['Program copy, not a deployment', 'neutral'],
  };
  const SECTIONS = [['identity', 'Deployment'], ['files', 'Saved configuration'], ['docker', 'Docker'], ['services', 'Services and routes'], ['cloudflare', 'Cloudflare']];
  const folderName = (p) => String(p).split('\\').filter(Boolean).pop();

  P.projects = async (main, ctx, sub) => {
    if (sub === 'review' && ctx.state.reviewPath) return renderReview(main, ctx, ctx.state.reviewPath);
    fill(main, head(ctx), h('p', { class: 'muted' }, 'Looking for deployments…'));
    const data = ctx.state.projects = await api('GET', '/api/projects');
    const list = arr(data.projects).filter((p) => p.summary.kind !== 'other' || p.recent);
    const pathInput = h('input', { id: 'new-path', value: ctx.state.forms.newPath || data.suggestedNewPath, spellcheck: 'false', autocomplete: 'off' });
    pathInput.addEventListener('input', () => { ctx.state.forms.newPath = pathInput.value; });
    const best = list.find((p) => p.summary.usable);
    fill(main, head(ctx),
      h('div', { class: 'callout', 'data-only-level': 'beginner' }, h('p', null, best
        ? ['We found ', h('strong', null, best.summary.stackName || folderName(best.summary.path)), '. Select ', h('strong', null, 'Review and open'), ' to continue managing it: nothing is reinstalled or changed by opening it.']
        : 'No existing deployment was found in the usual places. Start a new one, or choose its folder if you installed it somewhere else.')),
      h('section', { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('folder'), ' Continue where you left off'), help('instance', 'Deployments')),
        h('p', { class: 'muted small' }, `Recently opened folders, the subfolders of ${data.projectsRoot}, and folders of running Traefik + socket-proxy stacks. Nothing is changed by looking.`),
        list.length ? h('div', { class: 'review-list' }, list.map((p) => projectCard(ctx, p))) : h('p', { class: 'muted' }, 'No deployments found yet.'),
        folderBrowser(ctx)),
      h('section', { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('rocket'), ' Start a new deployment')),
        h('p', null, 'Begins the guided installation in an empty folder. Nothing is installed until you approve it in the setup journey.'),
        field({ id: 'new-path', label: 'Folder for the new deployment', control: h('div', { class: 'hostname-row' }, pathInput,
          h('button', { type: 'button', class: 'btn primary', onclick: (e) => withBusy(e.currentTarget, async () => {
            try { await api('POST', '/api/projects/new', { path: pathInput.value.trim() }); }
            catch (err) { if (err.data && err.data.needsAttach) { toast(err.message, true); ctx.state.reviewPath = pathInput.value.trim(); ctx.navigate('projects', 'review'); return; } throw err; }
            resetProjectState(ctx); ctx.state.session.chosen = true; await ctx.refresh(); ctx.navigate('setup');
          }) }, 'Start setup')), hint: 'A new folder under your Docker projects folder is suggested. A folder that already contains a deployment is opened instead, never reinstalled.' })),
      h('p', { class: 'muted small' }, 'Have a backup file instead? ', h('a', { href: '#backups' }, 'Restore from a backup'), ' recovers configuration into a deployment; you do not need it to open an existing one.'));
  };

  function head(ctx) {
    return h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Deployments'), h('h1', null, 'Choose a deployment'),
      h('p', null, 'Open an existing Traefik + Cloudflare deployment, or start a new one. Several independent deployments can be managed; each keeps its own settings and credentials.')));
  }

  function projectCard(ctx, p) {
    const s = p.summary;
    const [kindText, kindTone] = KIND[s.kind] || [s.kind, 'neutral'];
    const name = s.stackName || folderName(s.path);
    const chips = [plainChip(kindText, kindTone)];
    if (p.active) chips.push(plainChip('Open now', 'info'));
    if (s.containers) chips.push(plainChip(`Containers ${s.containers}`, s.running ? 'ok' : 'warn'));
    if (s.installed && s.mode === 'tunnel') chips.push(s.tokenReadable ? plainChip('Cloudflare connected', 'ok') : plainChip('Cloudflare needs reconnection', 'warn'));
    if (s.upgrade === 'available') chips.push(chip('upgrade'));
    const facts = [s.tunnelName ? `tunnel ${s.tunnelName}` : null, arr(s.domains).length ? arr(s.domains).join(', ') : null, s.installed ? `${s.services} service${s.services === 1 ? '' : 's'}` : null].filter(Boolean).join(' · ');
    return h('article', { class: 'rv', 'aria-label': name },
      h('div', { class: 'rv-head' }, h('strong', null, icon(s.kind === 'missing' ? 'alert' : 'folder'), ' ', name), h('span', { class: 'status-line' }, chips),
        h('p', { class: 'rv-summary' }, h('span', { class: 'mono' }, s.path), facts ? ` — ${facts}` : '', s.note ? h('span', { class: 'msg' }, s.note) : null),
        gate('expert', h('p', { class: 'rv-summary small' }, `Found via: ${arr(p.sources).join(', ')}${p.lastOpened ? `; last opened ${p.lastOpened.replace('T', ' ')}` : ''}${s.installedVersion ? `; files ${s.installedVersion}` : ''}`))),
      h('div', { class: 'rv-body' }, h('div', { class: 'rv-actions' },
        s.usable ? h('button', { type: 'button', class: 'btn primary small', onclick: () => { ctx.state.reviewPath = s.path; ctx.navigate('projects', 'review'); } }, 'Review and open') : null,
        s.kind === 'legacy' ? h('button', { type: 'button', class: 'btn small', onclick: () => { ctx.state.reviewPath = s.path; ctx.navigate('projects', 'review'); } }, 'Details') : null,
        s.kind === 'missing' ? h('button', { type: 'button', class: 'btn small', onclick: () => browseTo(ctx, s.path.split('\\').slice(0, -1).join('\\')) }, 'Locate…') : null,
        p.recent ? h('button', { type: 'button', class: 'btn small ghost', onclick: (e) => withBusy(e.currentTarget, async () => { await api('POST', '/api/projects/forget', { path: s.path }); toast('Removed from the list. No files or containers were touched.'); ctx.rerender(); }) }, 'Remove from list') : null)));
  }

  // Server-side folder picker: lists subfolders (names only), marks deployments. A typed path works as well.
  function folderBrowser(ctx) {
    const box = h('div', { id: 'folder-browser' });
    const input = h('input', { id: 'browse-path', spellcheck: 'false', autocomplete: 'off', placeholder: 'C:\\Users\\you\\.docker\\projects\\traefik-proxy' });
    const wrap = h('details', { class: 'more', id: 'browse-details', open: ctx.state.forms.browseOpen ? true : null },
      h('summary', null, 'Open another folder…'),
      field({ id: 'browse-path', label: 'Deployment folder', control: h('div', { class: 'hostname-row' }, input,
        h('button', { type: 'button', class: 'btn', onclick: (e) => withBusy(e.currentTarget, () => browseTo(ctx, input.value.trim())) }, 'Browse'),
        h('button', { type: 'button', class: 'btn primary', onclick: () => { if (!input.value.trim()) { toast('Enter or browse to a folder.', true); return; } ctx.state.reviewPath = input.value.trim(); ctx.navigate('projects', 'review'); } }, 'Review this folder')),
        hint: 'The folder that contains the deployment\'s .env and compose.yaml. Only folders on this PC can be opened.' }),
      box);
    wrap.addEventListener('toggle', () => { ctx.state.forms.browseOpen = wrap.open; if (wrap.open && !box.firstChild) browseTo(ctx, ''); });
    return wrap;
  }

  async function browseTo(ctx, path) {
    const wrap = $('#browse-details'); if (wrap && !wrap.open) { wrap.open = true; ctx.state.forms.browseOpen = true; }
    const box = $('#folder-browser'); const input = $('#browse-path');
    if (!box) return;
    let d;
    try { d = await api('GET', `/api/projects/browse?path=${encodeURIComponent(path || '')}`); } catch (e) { toast(e.message, true); return; }
    if (input) input.value = d.path;
    const [kt] = KIND[d.kind] || [''];
    fill(box,
      h('div', { class: 'chips' }, arr(d.roots).map((r) => h('button', { type: 'button', class: 'btn small ghost', onclick: () => browseTo(ctx, r.path) }, r.label))),
      h('p', { class: 'small' }, h('strong', null, d.path), d.kind === 'manager' || d.kind === 'draft' || d.kind === 'legacy' ? [' ', plainChip(kt, (KIND[d.kind] || [])[1])] : null),
      h('ul', { class: 'checks', 'aria-label': 'Folders' },
        d.parent ? h('li', null, h('span', { class: 'ci neutral' }, icon('chevron')), h('span', null, h('button', { type: 'button', class: 'btn small ghost', onclick: () => browseTo(ctx, d.parent) }, '.. (up one level)'))) : null,
        arr(d.entries).map((e) => h('li', null, h('span', { class: 'ci neutral' }, icon('folder')), h('span', null,
          h('button', { type: 'button', class: 'btn small ghost', onclick: () => browseTo(ctx, e.path) }, e.name),
          KIND[e.kind] && e.kind !== 'other' ? [' ', plainChip(KIND[e.kind][0], KIND[e.kind][1])] : null,
          e.kind === 'manager' || e.kind === 'draft' ? [' ', h('button', { type: 'button', class: 'btn small', onclick: () => { ctx.state.reviewPath = e.path; ctx.navigate('projects', 'review'); } }, 'Review and open')] : null)))),
      arr(d.entries).length ? null : h('p', { class: 'muted small' }, 'No subfolders.'));
  }

  function resetProjectState(ctx) {
    const s = ctx.state;
    s.setup = null; s.status = null; s.dashboard = null; s.discovery = null; s.env = null; s.overview = null; s.installPlan = null; s.installResult = null;
    s.verify = null; s.expert = null; s.cf = null; s.backups = null; s.restore = null; s.dashPlan = null; s.run = null; s.forms = {}; s.journeyOpen = {}; s.inspection = null;
    s.approvals = { local: null, cloudflare: null, dashboardSig: null, overwrites: [] };
  }

  // --- Review (attach) -----------------------------------------------------------------------------------------------------
  async function renderReview(main, ctx, path) {
    fill(main, h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Deployments'), h('h1', null, 'Review deployment'), h('p', { class: 'mono' }, path))),
      h('p', { class: 'muted' }, 'Reading the folder, Docker and (read-only) Cloudflare…'));
    let r;
    // The last inspection is reused for a minute (switching the detail level re-renders without new checks).
    const cached = ctx.state.inspection;
    if (cached && cached.path === path && Date.now() - cached.at < 60000) r = cached.result;
    else {
      try { r = await api('POST', '/api/projects/inspect', { path, cloudflare: true }); }
      catch (e) { fill(main, h('div', { class: 'page-head' }, h('h1', null, 'Review deployment')), h('div', { class: 'callout err' }, h('p', null, e.message)), backLink(ctx)); return; }
      ctx.state.inspection = { path, at: Date.now(), result: r };
    }
    const s = r.summary; const items = arr(r.items);
    const has = (st) => items.some((i) => i.status === st);
    const reconnect = has('reconnect');
    const upgrade = r.upgrade && r.upgrade.state === 'available';
    const problems = items.filter((i) => ['missing', 'failed', 'warning'].includes(i.status));
    const name = s.stackName || folderName(s.path);
    const plain = !r.usable ? (s.kind === 'legacy' ? 'This folder holds an earlier version of the proxy with fixed container names. This manager leaves it exactly as it is.' : r.blockers.join(' '))
      : [`${name} ${s.installed ? 'is installed' : 'has saved setup choices'}${s.containers ? `; its containers: ${s.containers}` : ''}.`,
        s.mode === 'tunnel' ? (reconnect ? ' Cloudflare needs to be reconnected (the saved account, tunnel and domains are kept).' : ' Cloudflare is connected.') : '',
        s.installed ? ` ${s.services} service${s.services === 1 ? '' : 's'}.` : '',
        problems.length ? ` ${problems.length} item(s) need a look (below).` : ' Everything checked looks fine.',
        upgrade ? ' Newer application files are available; you can upgrade later.' : ''].join('');
    const actions = h('div', { class: 'actions' },
      r.usable ? h('button', { type: 'button', class: 'btn primary', onclick: (e) => openProject(ctx, path, e.currentTarget, reconnect ? 'cloudflare' : null) }, icon('folder'), s.installed ? 'Open existing deployment' : 'Continue setup') : null,
      r.usable && reconnect ? h('button', { type: 'button', class: 'btn', onclick: (e) => openProject(ctx, path, e.currentTarget, 'cloudflare') }, icon('key'), 'Reconnect Cloudflare') : null,
      upgrade ? h('button', { type: 'button', class: 'btn', onclick: (e) => previewUpgrade(ctx, path, e.currentTarget) }, icon('download'), 'Preview upgrade') : null,
      h('button', { type: 'button', class: 'btn ghost', onclick: () => ctx.navigate('projects') }, 'Back'));
    fill(main,
      h('div', { class: 'page-head' }, h('div', null, h('div', { class: 'eyebrow' }, 'Deployments'), h('h1', null, name), h('p', { class: 'mono' }, s.path))),
      h('div', { class: `callout ${!r.usable ? 'warn' : problems.length ? 'warn' : 'ok'}` }, h('p', null, plain),
        h('p', { class: 'small' }, 'Opening it reads only: no file, container or Cloudflare resource is created, changed or restarted. An upgrade is optional and separate.')),
      actions,
      SECTIONS.map(([id, title]) => {
        const list = items.filter((i) => i.section === id);
        if (!list.length) return null;
        const worst = sectionStatus(list);
        return U.reviewPanel({ id: `attach-${id}`, title, status: worst, statusLabel: (L.STATUS[worst] || {}).label, reviewable: false, defaultOpen: id !== 'files' || list.some((i) => ['missing', 'failed'].includes(i.status)),
          summary: summarize(list), content: () => h('ul', { class: 'checks' }, list.map((i) => h('li', null,
            h('span', { class: `ci ${(L.STATUS[i.status] || L.STATUS.info).tone}` }, icon((L.STATUS[i.status] || L.STATUS.info).icon)),
            h('span', null, h('strong', null, i.label), ' ', chip(i.status in L.STATUS ? i.status : 'info'), h('span', { class: 'msg' }, i.message),
              i.detail ? gate('expert', U.output([JSON.stringify(i.detail, null, 2)], `${i.label} details`)) : null)))) });
      }),
      r.cloudflareChecked ? h('p', { class: 'muted small' }, 'Cloudflare was checked with read-only requests using this deployment\'s own stored token.') : null,
      technical([JSON.stringify(r, null, 2)], 'Raw inspection result', 'expert'),
      h('p', { class: 'muted small' }, 'Attach opens this deployment as it is. Upgrade updates its application files. Restore recovers configuration from a backup file (Backups page) and is not needed here.'));
  }
  // A section's chip in the attach vocabulary: the most serious finding, else Verified when everything was confirmed
  // live, else Detected.
  function sectionStatus(list) {
    const st = list.map((i) => i.status);
    for (const s of ['failed', 'missing', 'reconnect', 'warning', 'upgrade']) if (st.includes(s)) return s;
    return st.every((s) => s === 'verified' || s === 'info') && st.includes('verified') ? 'verified' : 'detected';
  }
  function summarize(list) {
    const counts = {};
    list.forEach((i) => { counts[i.status] = (counts[i.status] || 0) + 1; });
    return Object.entries(counts).map(([k, n]) => `${n} ${((L.STATUS[k] || {}).label || k).toLowerCase()}`).join(' · ');
  }
  const backLink = (ctx) => h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn', onclick: () => ctx.navigate('projects') }, 'Back to deployments'));

  async function openProject(ctx, path, button, then) {
    await withBusy(button, async () => {
      const r = await api('POST', '/api/projects/attach', { path });
      resetProjectState(ctx);
      ctx.state.session.chosen = true;
      await ctx.refresh();
      toast(`Opened ${r.stackName}.`);
      ctx.navigate(then || (r.installed ? 'overview' : 'setup'));
    });
  }

  // --- Upgrade (separate, previewed, confirmed) -------------------------------------------------------------------------------
  async function previewUpgrade(ctx, path, button) {
    await withBusy(button, async () => {
      const p = await api('POST', '/api/projects/upgrade/preview', { path });
      const u = p.upgrade;
      $('#plan-title').textContent = `Upgrade the application files (${u.installedVersion || '?'} → ${u.sourceVersion})`;
      const files = arr(p.files);
      fill($('#plan-content'),
        h('div', { class: 'callout' }, arr(p.notes).map((n) => h('p', null, n))),
        h('h3', null, 'Files'),
        files.length ? h('ul', { class: 'checks' }, files.map((f) => U.checkItem(f.action === 'keep' ? 'warn' : 'neutral', `${f.action === 'add' ? 'Add' : f.action === 'update' ? 'Update' : 'Keep (edited by hand)'} ${f.file}`, ''))) : h('p', { class: 'muted' }, 'Nothing to update.'),
        technical(p.lines, 'Installer dry run (install.ps1 -DryRun)'));
      const foot = clear($('#plan-foot'));
      const box = h('input', { type: 'checkbox' });
      const go = h('button', { type: 'button', class: 'btn primary', disabled: true }, 'Upgrade');
      box.addEventListener('change', () => { go.disabled = !box.checked; });
      go.addEventListener('click', () => withBusy(go, async () => {
        const r = await api('POST', '/api/projects/upgrade/apply', { path, confirm: true, previewKey: p.previewKey });
        fill($('#plan-content'), h('div', { class: `callout ${r.ok ? 'ok' : 'err'}` }, h('p', null, r.ok ? 'The application files were updated. Your configuration is unchanged.' : 'The upgrade reported an error; see the output.'),
          r.recoveryPoint ? h('p', { class: 'small' }, `Recovery point ${r.recoveryPoint} was written first.`) : null), technical(r.lines, 'Installer output'));
        fill($('#plan-foot'), h('button', { type: 'button', class: 'btn primary', 'data-close': true }, 'Close'));
        ctx.state.inspection = null;
        ctx.rerender();
      }));
      if (files.some((f) => f.action !== 'keep')) foot.append(h('label', { class: 'check grow' }, box, h('span', null, 'Update these application files (no container is restarted)')), go);
      foot.append(h('button', { type: 'button', class: 'btn', 'data-close': true }, 'Close'));
      U.openDialog($('#plan-dialog'));
    });
  }
  P.previewUpgrade = previewUpgrade;
})();
