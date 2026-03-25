import { esc, formatUnixTimestamp } from '/modules/helpers.js';
import { workbookState } from '/modules/state.js';

let reloadWorkspaceHook = null;
let loadInfoHook = null;

export function bindWorkbookHooks({ reloadWorkspace, loadInfo } = {}) {
  reloadWorkspaceHook = typeof reloadWorkspace === 'function' ? reloadWorkspace : null;
  loadInfoHook = typeof loadInfo === 'function' ? loadInfo : null;
}

export async function loadWorkbooksState() {
  try {
    const res = await fetch('/api/workbooks', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    workbookState.activeWorkbookId = data.active_workbook_id || null;
    workbookState.workbooks = Array.isArray(data.workbooks) ? data.workbooks : [];
    workbookState.removedWorkbooks = Array.isArray(data.removed_workbooks) ? data.removed_workbooks : [];
    renderWorkbookContext();
    renderWorkbooksTable();
  } catch {
    workbookState.activeWorkbookId = null;
    workbookState.workbooks = [];
    workbookState.removedWorkbooks = [];
    renderWorkbookContext();
    renderWorkbooksTable();
  }
}

export function updateWorkbookContext(activeWorkbook) {
  if (!activeWorkbook) return;
  workbookState.activeWorkbookId = activeWorkbook.id || workbookState.activeWorkbookId;
  renderWorkbookContext(activeWorkbook);
}

export function renderWorkbookContext(activeWorkbookOverride = null) {
  const selectEl = document.getElementById('workbook-switcher');
  const metaEl = document.getElementById('header-workbook-meta');
  if (!selectEl || !metaEl) return;

  const workbooks = workbookState.workbooks || [];
  const active = activeWorkbookOverride || workbooks.find((workbook) => workbook.id === workbookState.activeWorkbookId) || null;
  selectEl.disabled = workbookState.switching;
  if (!workbooks.length) {
    selectEl.innerHTML = '<option value="">No workbooks</option>';
    selectEl.value = '';
    metaEl.textContent = 'Connect a workbook to begin.';
    return;
  }

  selectEl.innerHTML = workbooks.map((workbook) => `<option value="${esc(workbook.id || '')}">${esc(workbook.display_name || workbook.workbook_label || workbook.id || '')}</option>`).join('');
  selectEl.value = workbookState.activeWorkbookId || '';
  const provider = active?.provider || 'unconfigured';
  const profile = active?.profile || 'unknown';
  const sync = active?.sync_in_progress ? 'syncing' : (active?.last_sync_at ? `last sync ${formatUnixTimestamp(active.last_sync_at)}` : 'never synced');
  metaEl.textContent = `${profile} · ${provider} · ${sync}`;
}

export function renderWorkbooksTable() {
  const bodyEl = document.getElementById('workbooks-body');
  const removedEl = document.getElementById('removed-workbooks-body');

  if (bodyEl) {
    if (!workbookState.workbooks.length) {
      bodyEl.innerHTML = '<tr><td colspan="6" class="empty-state"><strong>No workbooks configured</strong><br>Use Add Workbook to connect one.</td></tr>';
    } else {
      bodyEl.innerHTML = workbookState.workbooks.map((workbook) => {
        const sync = workbook.last_sync_at ? formatUnixTimestamp(workbook.last_sync_at) : 'Never';
        const status = workbook.sync_in_progress ? 'Syncing…' : (workbook.has_error ? `Error: ${esc(workbook.last_error || 'sync failed')}` : 'Ready');
        return `<tr>
          <td><strong>${esc(workbook.display_name || '')}</strong>${workbook.is_active ? ' <span class="badge">Active</span>' : ''}</td>
          <td>${esc(workbook.profile || '')}</td>
          <td>${esc(workbook.provider || '—')}</td>
          <td>${esc(sync)}</td>
          <td>${status}</td>
          <td>
            ${workbook.is_active ? '' : `<button class="btn" data-action="switch-workbook" data-id="${esc(workbook.id || '')}">Activate</button>`}
            <button class="btn" data-action="rename-workbook" data-id="${esc(workbook.id || '')}">Rename</button>
            <button class="btn-danger" data-action="remove-workbook" data-id="${esc(workbook.id || '')}">Remove</button>
          </td>
        </tr>`;
      }).join('');
    }
  }

  if (removedEl) {
    if (!workbookState.removedWorkbooks.length) {
      removedEl.innerHTML = '<tr><td colspan="4" class="empty-state">No removed workbooks.</td></tr>';
    } else {
      removedEl.innerHTML = workbookState.removedWorkbooks.map((workbook) => `<tr>
        <td><strong>${esc(workbook.display_name || '')}</strong></td>
        <td>${esc(workbook.profile || '')}</td>
        <td>${workbook.removed_at ? esc(formatUnixTimestamp(workbook.removed_at)) : '—'}</td>
        <td><button class="btn-danger" data-action="purge-workbook" data-id="${esc(workbook.id || '')}" data-name="${esc(workbook.display_name || '')}">Purge</button></td>
      </tr>`).join('');
    }
  }
}

export async function loadWorkbooksView() {
  const errEl = document.getElementById('workbooks-error');
  if (errEl) errEl.style.display = 'none';
  try {
    await loadWorkbooksState();
  } catch (error) {
    if (errEl) {
      errEl.textContent = 'Failed to load workbooks: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export async function switchWorkbook(id) {
  if (!id || workbookState.switching || id === workbookState.activeWorkbookId) return;
  workbookState.switching = true;
  renderWorkbookContext();
  try {
    const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}/activate`, { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    await loadWorkbooksState();
    if (reloadWorkspaceHook) await reloadWorkspaceHook();
  } catch (error) {
    window.alert('Failed to switch workbook: ' + error.message);
  } finally {
    workbookState.switching = false;
    renderWorkbookContext();
  }
}

export async function switchWorkbookFromHeader() {
  const selectEl = document.getElementById('workbook-switcher');
  if (!selectEl) return;
  await switchWorkbook(selectEl.value);
}

export async function renameWorkbook(id) {
  const workbook = workbookState.workbooks.find((item) => item.id === id);
  if (!workbook) return;
  const nextName = window.prompt('New workbook display name:', workbook.display_name || '');
  if (!nextName || nextName.trim() === '' || nextName.trim() === workbook.display_name) return;
  const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ display_name: nextName.trim() }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `HTTP ${res.status}`);
  }
  await loadWorkbooksState();
  if (loadInfoHook) await loadInfoHook();
}

export async function removeWorkbook(id) {
  const workbook = workbookState.workbooks.find((item) => item.id === id);
  if (!workbook) return;
  if (!window.confirm(`Remove workbook "${workbook.display_name}"? This hides it but does not delete its files.`)) return;
  const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}/remove`, { method: 'POST' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  await loadWorkbooksState();
  if (reloadWorkspaceHook) await reloadWorkspaceHook();
}

export async function purgeWorkbook(id, displayName) {
  const confirmation = window.prompt(`Type the workbook name to purge it permanently:\n${displayName}`);
  if (!confirmation) return;
  const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ confirm_display_name: confirmation }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  await loadWorkbooksState();
}
