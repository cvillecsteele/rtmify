import { esc } from '/modules/helpers.js';
import { soupState } from '/modules/state.js';

let loadDesignBomWorkspaceHook = null;
let loadSoupWorkspaceHook = null;
let loadInfoHook = null;

export function bindUploadHooks({ loadDesignBomWorkspace, loadSoupWorkspace, loadInfo } = {}) {
  loadDesignBomWorkspaceHook = typeof loadDesignBomWorkspace === 'function' ? loadDesignBomWorkspace : null;
  loadSoupWorkspaceHook = typeof loadSoupWorkspace === 'function' ? loadSoupWorkspace : null;
  loadInfoHook = typeof loadInfo === 'function' ? loadInfo : null;
}

export async function currentIngestToken() {
  const tokenEl = document.getElementById('test-results-token');
  const inline = tokenEl?.textContent?.trim();
  if (inline && inline !== 'Loading…' && inline !== '—' && inline !== 'unknown') return inline;
  const res = await fetch('/api/info', { cache: 'no-store' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const info = await res.json();
  if (!info.test_results_token) throw new Error('Missing ingestion token.');
  return info.test_results_token;
}

export async function authenticatedApiFetch(input, init = {}) {
  const token = await currentIngestToken();
  const headers = new Headers(init.headers || {});
  headers.set('Authorization', `Bearer ${token}`);
  return fetch(input, { ...init, headers });
}

export async function uploadBomArtifactFile(file) {
  const resultEl = document.getElementById('bom-upload-result');
  const errEl = document.getElementById('design-boms-error');
  if (!resultEl) return;
  if (errEl) errEl.style.display = 'none';
  resultEl.textContent = `Uploading ${file.name}…`;
  try {
    const token = await currentIngestToken();
    let res;
    if (file.name.toLowerCase().endsWith('.xlsx')) {
      const formData = new FormData();
      formData.append('file', file, file.name);
      res = await fetch('/api/v1/bom/xlsx', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body: formData,
      });
    } else {
      const body = await file.text();
      const contentType = file.name.toLowerCase().endsWith('.csv') ? 'text/csv' : 'application/json';
      res = await fetch('/api/v1/bom', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': contentType,
        },
        body,
      });
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
    resultEl.innerHTML = renderBomUploadResult(data);
    if (loadDesignBomWorkspaceHook) await loadDesignBomWorkspaceHook(true);
  } catch (error) {
    resultEl.textContent = '';
    if (errEl) {
      errEl.textContent = 'BOM upload failed: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export async function uploadSoupArtifactFile(file) {
  const resultEl = document.getElementById('soup-upload-result');
  const errEl = document.getElementById('software-boms-error');
  if (!resultEl) return;
  if (errEl) errEl.style.display = 'none';
  resultEl.textContent = `Uploading ${file.name}…`;
  try {
    const token = await currentIngestToken();
    let res;
    if (file.name.toLowerCase().endsWith('.xlsx')) {
      const product = document.getElementById('soup-upload-product')?.value.trim() || soupState.selectedProduct || '';
      const bomName = document.getElementById('soup-upload-name')?.value.trim() || soupState.selectedBomName || 'SOUP Components';
      if (!product) throw new Error('Provide the product full_identifier for SOUP .xlsx uploads.');
      const formData = new FormData();
      formData.append('file', file, file.name);
      formData.append('full_product_identifier', product);
      if (bomName) formData.append('bom_name', bomName);
      res = await fetch('/api/v1/soup/xlsx', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body: formData,
      });
    } else {
      const body = await file.text();
      res = await fetch('/api/v1/soup', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body,
      });
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
    resultEl.innerHTML = renderSoupUploadResult(data);
    if (loadSoupWorkspaceHook) await loadSoupWorkspaceHook(true);
  } catch (error) {
    resultEl.textContent = '';
    if (errEl) {
      errEl.textContent = 'SOUP upload failed: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export function renderBomUploadResult(data) {
  if (Array.isArray(data.groups)) {
    return data.groups.map((group) => {
      const warningText = (group.warnings || []).map((warning) => warning.code).join(', ');
      return `<div class="repo-row repo-row--block">
        <div><strong>${esc(group.full_product_identifier || '')}</strong> · ${esc(group.bom_name || '')}</div>
        <div class="text-sm-subtle">${esc(group.status || 'unknown')} · rows ${esc(String(group.rows_ingested || 0))} · nodes ${esc(String(group.inserted_nodes || 0))} · edges ${esc(String(group.inserted_edges || 0))}</div>
        <div class="text-sm-subtle">${group.error ? esc(`${group.error.code}: ${group.error.detail || ''}`) : (warningText ? esc(`warnings: ${warningText}`) : 'no warnings')}</div>
      </div>`;
    }).join('');
  }
  const warningText = (data.warnings || []).map((warning) => warning.code).join(', ');
  return `<div class="repo-row repo-row--block">
    <div><strong>${esc(data.full_product_identifier || '')}</strong> · ${esc(data.bom_name || '')}</div>
    <div class="text-sm-subtle">nodes ${esc(String(data.inserted_nodes || 0))} · edges ${esc(String(data.inserted_edges || 0))}</div>
    <div class="text-sm-subtle">${warningText ? esc(`warnings: ${warningText}`) : 'no warnings'}</div>
  </div>`;
}

export function renderSoupUploadResult(data) {
  const rowErrors = Array.isArray(data.row_errors) ? data.row_errors.map((error) => `${error.code} row ${error.row}`).join(', ') : '';
  const warningText = (data.warnings || []).map((warning) => warning.code).join(', ');
  return `<div class="repo-row repo-row--block">
    <div><strong>${esc(data.full_product_identifier || '')}</strong> · ${esc(data.bom_name || 'SOUP Components')}</div>
    <div class="text-sm-subtle">rows received ${esc(String(data.rows_received || 0))} · rows ingested ${esc(String(data.rows_ingested || 0))} · nodes ${esc(String(data.inserted_nodes || 0))} · edges ${esc(String(data.inserted_edges || 0))}</div>
    <div class="text-sm-subtle">${rowErrors ? esc(`row errors: ${rowErrors}`) : 'no row errors'}${warningText ? esc(` · warnings: ${warningText}`) : ''}</div>
  </div>`;
}

export function renderTestResultsApiInfo(info, endpointEl, bomEndpointEl, tokenEl, inboxEl) {
  if (endpointEl) endpointEl.textContent = info.test_results_endpoint || 'unknown';
  if (bomEndpointEl) bomEndpointEl.textContent = info.bom_endpoint || 'unknown';
  if (tokenEl) tokenEl.textContent = info.test_results_token || 'unknown';
  if (inboxEl) inboxEl.textContent = info.inbox_dir || info.test_results_inbox_dir || 'unknown';
}

export function copyTestResultsToken() {
  const value = document.getElementById('test-results-token')?.textContent;
  if (!value || value === 'Loading…' || value === '—') return;
  navigator.clipboard.writeText(value).catch(() => {});
}

export async function regenerateTestResultsToken() {
  const errEl = document.getElementById('info-error');
  if (errEl) errEl.style.display = 'none';
  try {
    const res = await fetch('/api/v1/test-results/token/regenerate', { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    if (loadInfoHook) await loadInfoHook();
  } catch (error) {
    if (errEl) {
      errEl.textContent = 'Failed to regenerate ingestion token: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}
