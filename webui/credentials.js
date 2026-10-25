'use strict';
// Reusable credential card (window.TPMCredentials) for API integrations: authentik today; Authelia, Cloudflare and
// others can use the same card with their own endpoints. It shows a credential's status (never its value), offers
// "Test connection" and an always available "Replace API token", and opens a replacement form right away when the
// stored credential does not work. The token typed into the form is sent once to the local server and never kept in
// the page state or browser storage; the server only replaces the stored credential after the new one validated.
(() => {
  const L = window.TPMLogic;
  const U = window.TPMUI;
  const { h, arr, icon, kv, toast, api, withBusy } = U;
  const open = {};        // id -> replacement form open (no token values)
  const lastError = {};   // id -> message of the last failed replacement in this page session

  // credential view from the server (lib\CredentialManager.psm1, Get-CredentialView).
  function statusChip(view) {
    const s = L.credentialStatus(view);
    return h('span', { class: `chip ${s.tone}` }, icon(s.icon), s.label);
  }

  // opts: id, title, view, testPath, replacePath, tokenLabel, tokenHint, accountLabel, serverLabel, extraActions (nodes),
  //       explain (node: how to create a token), onChanged(result, kind) (async; kind = 'replaced' | 'tested'), rerender().
  function card(opts) {
    const v = opts.view || { status: 'missing', stored: false };
    const s = L.credentialStatus(v);
    const formOpen = !!open[opts.id] || (!v.ok && v.status !== 'unreachable' && v.status !== 'unknown');
    const input = h('input', { type: 'password', id: `cred-${opts.id}`, autocomplete: 'off', spellcheck: 'false', placeholder: opts.tokenLabel || 'API token' });
    const err = h('p', { class: 'form-error', role: 'alert' }, lastError[opts.id] || '');
    const save = h('button', { type: 'button', class: 'btn primary' }, icon('key'), 'Validate and save');
    save.addEventListener('click', () => withBusy(save, async () => {
      const token = input.value.trim();
      if (!token) { err.textContent = 'Paste the new token first.'; return; }
      err.textContent = '';
      try {
        const r = await api('POST', opts.replacePath, { token });
        input.value = '';
        delete lastError[opts.id]; open[opts.id] = false;
        toast(r.replaced ? `Token replaced: connected as ${r.username}.` : `Connected as ${r.username}.`);
        if (opts.onChanged) await opts.onChanged(r, 'replaced');
      } catch (e) {
        input.value = '';
        lastError[opts.id] = e.message;
        err.textContent = e.message;
        input.focus();
      }
    }));
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); save.click(); } });
    const test = h('button', { type: 'button', class: 'btn', disabled: !v.stored }, icon('refresh'), 'Test connection');
    test.addEventListener('click', () => withBusy(test, async () => {
      const r = await api('POST', opts.testPath, {});
      toast(r.ok ? 'Connection works.' : `Connection test failed: ${r.credential.message}`, !r.ok);
      if (opts.onChanged) await opts.onChanged(r, 'tested');
    }));
    const replace = h('button', { type: 'button', class: 'btn', 'aria-expanded': String(formOpen), 'aria-controls': `cred-form-${opts.id}` }, icon('key'), v.stored ? 'Replace API token' : 'Add API token');
    replace.addEventListener('click', () => { open[opts.id] = !formOpen; if (opts.rerender) opts.rerender(); setTimeout(() => { const el = document.getElementById(`cred-${opts.id}`); if (el) el.focus(); }, 0); });
    const failed = v.stored && !v.ok && !['unknown', 'unreachable'].includes(v.status);
    const attempt = v.lastAttempt && v.lastAttempt.candidate && v.lastAttempt.status !== 'valid' ? v.lastAttempt : null;
    const pairs = [
      [opts.serverLabel || 'Server', v.server ? `${v.server}${v.version ? ` (version ${v.version})` : ''}` : '—'],
      [opts.accountLabel || 'API account', v.account || '—'],
      ['Validation status', statusChip(v)],
      ['Last successful validation', v.lastSuccessAt || 'never'],
      ['Last checked', v.lastValidatedAt || '—', 'intermediate'],
      ['Token saved', v.stored ? `${v.savedAt}${v.savedBy ? ` by ${v.savedBy}` : ''} (encrypted for this Windows account)` : 'no', 'intermediate'],
      ['Expires', !v.stored ? '—' : v.expiresAt ? v.expiresAt : v.ok ? 'no expiry date' : 'unknown'],
      v.rotatedAt ? ['Last replaced', v.rotatedAt, 'advanced'] : null,
    ];
    return h('section', { class: 'card cred-card', id: `cred-card-${opts.id}`, 'aria-labelledby': `cred-h-${opts.id}` },
      h('div', { class: 'card-head' }, h('h2', { id: `cred-h-${opts.id}` }, opts.title), h('span', { class: 'grow' }), statusChip(v)),
      kv(pairs),
      v.expiryWarning ? h('div', { class: `callout ${v.status === 'expired' ? 'err' : 'warn'}`, role: 'status' }, h('p', null, v.expiryWarning)) : null,
      failed ? h('div', { class: 'callout err', role: 'alert' }, h('p', null, h('strong', null, `${s.label}. `), v.message || ''),
        !formOpen ? h('div', { class: 'actions' }, h('button', { type: 'button', class: 'btn small primary', onclick: () => { open[opts.id] = true; if (opts.rerender) opts.rerender(); } }, 'Try different token')) : null) : null,
      v.status === 'unreachable' ? h('div', { class: 'callout warn', role: 'status' }, h('p', null, v.message || 'The server did not answer.')) : null,
      attempt && !lastError[opts.id] ? h('p', { class: 'small muted' }, `Last replacement attempt (${attempt.at}) was refused: ${attempt.message} The saved token was kept.`) : null,
      h('div', { class: 'actions' }, test, replace, arr(opts.extraActions)),
      formOpen ? h('div', { class: 'cred-form', id: `cred-form-${opts.id}` },
        h('h3', null, failed ? 'Try a different token' : v.stored ? 'Replace the API token' : 'Add an API token'),
        opts.explain || null,
        U.field({ id: `cred-${opts.id}`, label: opts.tokenLabel || 'New API token', control: input, hint: opts.tokenHint || 'Checked against the server before it is saved. If it does not work, the current token stays as it is.' }),
        h('div', { class: 'actions' }, save, v.ok ? h('button', { type: 'button', class: 'btn ghost', onclick: () => { open[opts.id] = false; delete lastError[opts.id]; if (opts.rerender) opts.rerender(); } }, 'Cancel') : null),
        err) : null);
  }

  window.TPMCredentials = { card, statusChip };
})();
