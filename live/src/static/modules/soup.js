import { createSyncSettingsController } from '/modules/sync-settings.js';
import { esc, formatUnixTimestamp, propsObj } from '/modules/helpers.js';
import { soupState } from '/modules/state.js';
import { authenticatedApiFetch } from '/modules/uploads.js';

export async function loadSoupWorkspace(force = false) {
  const errEl = document.getElementById('software-boms-error');
  const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
  if (errEl) errEl.style.display = 'none';
  try {
    const params = new URLSearchParams();
    if (includeObsolete) params.set('include_obsolete', 'true');
    const res = await authenticatedApiFetch(`/api/v1/soup?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    soupState.softwareBoms = Array.isArray(data.software_boms) ? data.software_boms : [];
    const stillSelected = soupState.softwareBoms.some((bom) =>
      bom.full_product_identifier === soupState.selectedProduct && bom.bom_name === soupState.selectedBomName);
    if (!stillSelected || force) {
      if (soupState.softwareBoms.length) {
        soupState.selectedProduct = soupState.softwareBoms[0].full_product_identifier || null;
        soupState.selectedBomName = soupState.softwareBoms[0].bom_name || null;
      } else {
        soupState.selectedProduct = null;
        soupState.selectedBomName = null;
      }
    }
    renderSoftwareBomList();
    if (soupState.selectedProduct && soupState.selectedBomName) {
      await loadSelectedSoupDetail();
    } else {
      const detailEl = document.getElementById('software-bom-detail');
      if (detailEl) detailEl.innerHTML = '<div class="empty-state">No software BOMs or SOUP registers ingested yet.</div>';
    }
  } catch (error) {
    soupState.softwareBoms = [];
    renderSoftwareBomList();
    const detailEl = document.getElementById('software-bom-detail');
    if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load software BOMs: ${esc(error.message)}</div>`;
    if (errEl) {
      errEl.textContent = 'Failed to load software BOMs: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

function renderSoftwareBomList() {
  const bodyEl = document.getElementById('software-bom-list-body');
  if (!bodyEl) return;
  if (!soupState.softwareBoms.length) {
    bodyEl.innerHTML = '<tr><td colspan="8" class="empty-state">No software BOMs available for the active workbook.</td></tr>';
    return;
  }
  bodyEl.innerHTML = soupState.softwareBoms.map((bom) => {
    const selected = bom.full_product_identifier === soupState.selectedProduct && bom.bom_name === soupState.selectedBomName;
    return `<tr${selected ? ' class="warning"' : ''}>
      <td><span class="req-id">${esc(bom.full_product_identifier || '—')}</span></td>
      <td>${esc(bom.product_status || 'Active')}</td>
      <td>${esc(bom.bom_name || '—')}</td>
      <td>${esc(bom.source_format || '—')}</td>
      <td>${esc(String(bom.item_count || 0))}</td>
      <td>${esc(String(bom.warning_count || 0))}</td>
      <td>${esc(formatUnixTimestamp(bom.ingested_at))}</td>
      <td><button class="btn" data-action="select-software-bom" data-product="${esc(bom.full_product_identifier || '')}" data-bom-name="${esc(bom.bom_name || '')}">${selected ? 'Selected' : 'Inspect'}</button></td>
    </tr>`;
  }).join('');
}

export async function selectSoftwareBom(fullProductIdentifier, bomName) {
  soupState.selectedProduct = fullProductIdentifier || null;
  soupState.selectedBomName = bomName || null;
  renderSoftwareBomList();
  syncSoupFiltersFromSelection();
  await loadSelectedSoupDetail();
}

function syncSoupFiltersFromSelection() {
  const product = soupState.selectedProduct || '';
  const name = soupState.selectedBomName || '';
  const ids = [
    ['soup-components-product', product],
    ['soup-components-name', name],
    ['soup-gaps-product', product],
    ['soup-gaps-name', name],
    ['soup-licenses-product', product],
    ['soup-safety-product', product],
    ['soup-upload-product', product],
    ['soup-upload-name', name],
    ['soup-sync-product', product],
    ['soup-sync-bom-name', name],
    ['report-soup-product', product],
    ['report-soup-name', name],
  ];
  ids.forEach(([id, value]) => {
    const el = document.getElementById(id);
    if (el && !el.value) el.value = value;
  });
}

export async function loadSelectedSoupDetail() {
  const detailEl = document.getElementById('software-bom-detail');
  const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
  if (!detailEl) return;
  if (!soupState.selectedProduct || !soupState.selectedBomName) {
    detailEl.innerHTML = '<div class="empty-state">Select a SOUP register to inspect it.</div>';
    return;
  }
  detailEl.innerHTML = '<div class="empty-state">Loading SOUP detail…</div>';
  try {
    const query = new URLSearchParams({
      full_product_identifier: soupState.selectedProduct,
      bom_name: soupState.selectedBomName,
    });
    if (includeObsolete) query.set('include_obsolete', 'true');
    const res = await authenticatedApiFetch(`/api/v1/soup/components?${query.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const components = Array.isArray(data.components) ? data.components : [];
    const totalWarnings = components.reduce((sum, item) =>
      sum + ((item.statuses || []).filter((status) => status !== 'SOUP_OK').length), 0);
    detailEl.innerHTML = `
      <div class="toolbar card-toolbar">
        <span class="card-title">${esc(data.full_product_identifier || '')} · ${esc(data.bom_name || '')}</span>
      </div>
      <div class="bom-metrics">
        <div class="bom-metric"><div class="bom-metric-label">Components</div><div class="bom-metric-value">${esc(String(components.length))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Status Flags</div><div class="bom-metric-value">${esc(String(totalWarnings))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Source</div><div class="bom-metric-value">SOUP</div></div>
      </div>
      ${components.length ? `<div class="table-scroll"><table>
        <thead><tr><th>Component</th><th>Version</th><th>Supplier</th><th>License</th><th>Safety</th><th>Anomalies</th><th>Links</th><th>Statuses</th></tr></thead>
        <tbody>${components.map(renderSoupComponentRow).join('')}</tbody>
      </table></div>` : '<div class="empty-state">No SOUP components found.</div>'}
    `;
    syncSoupFiltersFromSelection();
  } catch (error) {
    detailEl.innerHTML = `<div class="empty-state">Failed to load SOUP detail: ${esc(error.message)}</div>`;
  }
}

function renderSoupComponentRow(item) {
  const props = propsObj(item.properties);
  const declaredReqs = Array.isArray(props.requirement_ids) ? props.requirement_ids : [];
  const declaredTests = Array.isArray(props.test_ids) ? props.test_ids : [];
  const anomalies = props.known_anomalies || '—';
  const evaluation = props.anomaly_evaluation || '—';
  return `<tr>
    <td><span class="req-id">${esc(props.part || item.item_id || '—')}</span></td>
    <td>${esc(props.revision || '—')}</td>
    <td>${esc(props.supplier || '—')}</td>
    <td>${esc(props.license || '—')}</td>
    <td>${esc(props.safety_class || '—')}</td>
    <td><div>${esc(anomalies)}</div><div class="text-sm-subtle mt-8">${esc(evaluation)}</div></td>
    <td>
      <div>${declaredReqs.map((id) => `<span class="bom-chip">${esc(id)}</span>`).join('') || '<span class="text-placeholder">No requirement IDs</span>'}</div>
      <div class="mt-8">${declaredTests.map((id) => `<span class="bom-chip">${esc(id)}</span>`).join('') || '<span class="text-placeholder">No test IDs</span>'}</div>
    </td>
    <td>${(item.statuses || []).map((status) => `<span class="bom-chip${status === 'SOUP_OK' ? '' : ' warn'}">${esc(status)}</span>`).join('')}</td>
  </tr>`;
}

export async function loadSoupComponents() {
  const errEl = document.getElementById('soup-components-error');
  const resultEl = document.getElementById('soup-components-result');
  const productEl = document.getElementById('soup-components-product');
  const nameEl = document.getElementById('soup-components-name');
  const searchEl = document.getElementById('soup-components-search');
  const includeObsolete = !!document.getElementById('soup-components-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl || !searchEl) return;

  errEl.style.display = 'none';
  if (!productEl.value.trim() && soupState.selectedProduct) productEl.value = soupState.selectedProduct;
  if (!nameEl.value.trim() && soupState.selectedBomName) nameEl.value = soupState.selectedBomName;
  if (!productEl.value.trim()) {
    errEl.textContent = 'Provide a product full_identifier, or select a SOUP register first.';
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
    return;
  }
  const params = new URLSearchParams({ full_product_identifier: productEl.value.trim() });
  if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
  if (includeObsolete) params.set('include_obsolete', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading SOUP components…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/soup/components?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const q = searchEl.value.trim().toLowerCase();
    const rows = (Array.isArray(data.components) ? data.components : []).filter((item) => {
      if (!q) return true;
      const props = propsObj(item.properties);
      return [props.part, props.license, props.supplier, props.category, props.known_anomalies, props.anomaly_evaluation]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(q));
    });
    if (!rows.length) {
      resultEl.innerHTML = '<div class="empty-state">No matching SOUP components found.</div>';
      return;
    }
    resultEl.innerHTML = `<div class="table-scroll"><table>
      <thead><tr><th>Component</th><th>Version</th><th>Supplier</th><th>Category</th><th>License</th><th>PURL</th><th>Safety</th><th>Req</th><th>Test</th><th>Statuses</th></tr></thead>
      <tbody>${rows.map((item) => {
        const props = propsObj(item.properties);
        return `<tr>
          <td><span class="req-id">${esc(props.part || '—')}</span></td>
          <td>${esc(props.revision || '—')}</td>
          <td>${esc(props.supplier || '—')}</td>
          <td>${esc(props.category || '—')}</td>
          <td>${esc(props.license || '—')}</td>
          <td>${esc(props.purl || '—')}</td>
          <td>${esc(props.safety_class || '—')}</td>
          <td>${esc(String(item.linked_requirement_count || 0))}/${esc(String(item.declared_requirement_count || 0))}</td>
          <td>${esc(String(item.linked_test_count || 0))}/${esc(String(item.declared_test_count || 0))}</td>
          <td>${(item.statuses || []).map((status) => `<span class="bom-chip${status === 'SOUP_OK' ? '' : ' warn'}">${esc(status)}</span>`).join('')}</td>
        </tr>`;
      }).join('')}</tbody>
    </table></div>`;
  } catch (error) {
    errEl.textContent = 'Failed to load SOUP components: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function loadSoupGaps() {
  const errEl = document.getElementById('soup-gaps-error');
  const resultEl = document.getElementById('soup-gaps-result');
  const productEl = document.getElementById('soup-gaps-product');
  const nameEl = document.getElementById('soup-gaps-name');
  const includeInactive = !!document.getElementById('soup-gaps-include-inactive')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl) return;

  errEl.style.display = 'none';
  const params = new URLSearchParams();
  if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
  if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
  if (includeInactive) params.set('include_inactive', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading SOUP gaps…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/soup/gaps?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const gaps = Array.isArray(data.gaps) ? data.gaps : [];
    if (!gaps.length) {
      resultEl.innerHTML = '<div class="empty-state">No SOUP gaps found for the current filter.</div>';
      return;
    }
    resultEl.innerHTML = gaps.map((gap) => {
      const props = propsObj(gap.properties);
      return `<div class="card card--padded">
        <div class="bom-tree-head">
          <span class="req-id">${esc(props.part || gap.item_id || '')}</span>
          <span class="bom-chip">${esc(props.revision || '-')}</span>
          <span class="bom-chip">${esc(gap.full_product_identifier || '')}</span>
          <span class="bom-chip">${esc(gap.bom_name || '')}</span>
        </div>
        <div class="mt-8">${(gap.statuses || []).map((status) => `<span class="bom-chip warn">${esc(status)}</span>`).join('')}</div>
        <div class="text-sm-subtle mt-8">Anomalies: ${esc(props.known_anomalies || '—')}</div>
        <div class="text-sm-subtle">Evaluation: ${esc(props.anomaly_evaluation || '—')}</div>
        <div class="text-sm-subtle">Unresolved IDs: ${esc((gap.unresolved_requirement_ids || []).concat(gap.unresolved_test_ids || []).join(', ') || '—')}</div>
      </div>`;
    }).join('');
  } catch (error) {
    errEl.textContent = 'Failed to load SOUP gaps: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function loadSoupLicenses() {
  const errEl = document.getElementById('soup-licenses-error');
  const resultEl = document.getElementById('soup-licenses-result');
  const productEl = document.getElementById('soup-licenses-product');
  const licenseEl = document.getElementById('soup-licenses-license');
  const includeObsolete = !!document.getElementById('soup-licenses-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !licenseEl) return;

  errEl.style.display = 'none';
  const params = new URLSearchParams();
  if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
  if (licenseEl.value.trim()) params.set('license', licenseEl.value.trim());
  if (includeObsolete) params.set('include_obsolete', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading SOUP licenses…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/soup/licenses?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const rows = Array.isArray(data.components) ? data.components : [];
    if (!rows.length) {
      resultEl.innerHTML = '<div class="empty-state">No SOUP components matched that license filter.</div>';
      return;
    }
    resultEl.innerHTML = `<div class="table-scroll"><table>
      <thead><tr><th>Product</th><th>BOM</th><th>Component</th><th>Version</th><th>License</th><th>Supplier</th></tr></thead>
      <tbody>${rows.map((row) => {
        const props = propsObj(row.properties);
        return `<tr>
          <td>${esc(row.full_product_identifier || '—')}</td>
          <td>${esc(row.bom_name || '—')}</td>
          <td><span class="req-id">${esc(props.part || '—')}</span></td>
          <td>${esc(props.revision || '—')}</td>
          <td>${esc(props.license || '—')}</td>
          <td>${esc(props.supplier || '—')}</td>
        </tr>`;
      }).join('')}</tbody>
    </table></div>`;
  } catch (error) {
    errEl.textContent = 'Failed to load SOUP licenses: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function loadSoupSafetyClasses() {
  const errEl = document.getElementById('soup-safety-error');
  const resultEl = document.getElementById('soup-safety-result');
  const productEl = document.getElementById('soup-safety-product');
  const classEl = document.getElementById('soup-safety-class');
  const includeObsolete = !!document.getElementById('soup-safety-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !classEl) return;

  errEl.style.display = 'none';
  if (!productEl.value.trim() && soupState.selectedProduct) productEl.value = soupState.selectedProduct;
  if (!productEl.value.trim()) {
    errEl.textContent = 'Provide a product full_identifier, or select a SOUP register first.';
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
    return;
  }
  const params = new URLSearchParams({ full_product_identifier: productEl.value.trim() });
  if (classEl.value.trim()) params.set('safety_class', classEl.value.trim());
  if (includeObsolete) params.set('include_obsolete', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading SOUP safety classes…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/soup/safety-classes?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const rows = Array.isArray(data.components) ? data.components : [];
    if (!rows.length) {
      resultEl.innerHTML = '<div class="empty-state">No SOUP components matched that safety class filter.</div>';
      return;
    }
    resultEl.innerHTML = rows.map((row) => {
      const props = propsObj(row.properties);
      return `<div class="card card--padded">
        <div class="bom-tree-head">
          <span class="req-id">${esc(props.part || row.item_id || '')}</span>
          <span class="bom-chip">${esc(props.revision || '-')}</span>
          <span class="bom-chip">${esc(props.safety_class || '—')}</span>
          <span class="bom-chip">${esc(row.bom_name || '—')}</span>
        </div>
        <div class="text-sm-subtle">License: ${esc(props.license || '—')} · Supplier: ${esc(props.supplier || '—')}</div>
        <div class="text-sm-subtle">Known anomalies: ${esc(props.known_anomalies || '—')}</div>
      </div>`;
    }).join('');
  } catch (error) {
    errEl.textContent = 'Failed to load SOUP safety classes: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export function downloadSoupReport(format = 'md') {
  const productEl = document.getElementById('report-soup-product');
  const nameEl = document.getElementById('report-soup-name');
  const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
  const fullProductIdentifier = productEl?.value.trim() || soupState.selectedProduct || '';
  const bomName = nameEl?.value.trim() || soupState.selectedBomName || 'SOUP Components';
  if (!fullProductIdentifier) {
    window.alert('Select a SOUP register first, or enter a product full_identifier.');
    return;
  }
  if (productEl && !productEl.value.trim()) productEl.value = fullProductIdentifier;
  if (nameEl && !nameEl.value.trim()) nameEl.value = bomName;
  const query = new URLSearchParams({ full_product_identifier: fullProductIdentifier, bom_name: bomName });
  if (includeObsolete) query.set('include_obsolete', 'true');
  const path = format === 'pdf' ? '/report/soup' : (format === 'docx' ? '/report/soup.docx' : '/report/soup.md');
  window.location.href = `${path}?${query.toString()}`;
}

function toggleSyncKind(prefix) {
  const kind = document.getElementById(`${prefix}-kind`)?.value || 'local_xlsx';
  const localEl = document.getElementById(`${prefix}-local`);
  const providerEl = document.getElementById(`${prefix}-provider`);
  const googleEl = document.getElementById(`${prefix}-google`);
  const excelEl = document.getElementById(`${prefix}-excel`);
  if (localEl) localEl.classList.toggle('active', kind === 'local_xlsx');
  if (providerEl) providerEl.classList.toggle('active', kind !== 'local_xlsx');
  if (googleEl) googleEl.classList.toggle('active', kind === 'google');
  if (excelEl) excelEl.classList.toggle('active', kind === 'excel');
}

export function toggleSoupSyncKind() {
  toggleSyncKind('soup-sync');
}

function renderSoupSyncStatus(data) {
  const statusEl = document.getElementById('soup-sync-status');
  if (!statusEl) return;
  if (!data.configured) {
    statusEl.innerHTML = '<dt>State</dt><dd>Not configured</dd><dt>Sync</dt><dd>No secondary SOUP source attached.</dd>';
    return;
  }
  statusEl.innerHTML = `
    <dt>State</dt><dd>${esc(data.kind || 'unknown')}</dd>
    <dt>Display Name</dt><dd>${esc(data.display_name || '—')}</dd>
    <dt>Product Anchor</dt><dd>${esc(data.full_product_identifier || '—')}</dd>
    <dt>BOM Name</dt><dd>${esc(data.bom_name || 'SOUP Components')}</dd>
    <dt>Workbook</dt><dd>${esc(data.workbook_label || data.workbook_url || data.local_xlsx_path || '—')}</dd>
    <dt>Credential</dt><dd>${esc(data.credential_display || 'stored in secure store')}</dd>
    <dt>Last Sync</dt><dd>${esc(formatUnixTimestamp(data.last_sync_at))}</dd>
    <dt>Last Result</dt><dd>${data.last_sync_ok === '1' ? 'OK' : (data.last_error || 'No successful sync recorded')}</dd>
  `;
}

function applySoupSyncForm(data) {
  const kind = data.configured ? (data.kind || 'local_xlsx') : 'local_xlsx';
  const kindEl = document.getElementById('soup-sync-kind');
  const displayNameEl = document.getElementById('soup-sync-display-name');
  const productEl = document.getElementById('soup-sync-product');
  const bomNameEl = document.getElementById('soup-sync-bom-name');
  const localPathEl = document.getElementById('soup-sync-local-path');
  const workbookUrlEl = document.getElementById('soup-sync-workbook-url');
  if (kindEl) kindEl.value = kind;
  if (displayNameEl) displayNameEl.value = data.display_name || 'SOUP Workbook';
  if (productEl) productEl.value = data.full_product_identifier || '';
  if (bomNameEl) bomNameEl.value = data.bom_name || 'SOUP Components';
  if (localPathEl) localPathEl.value = data.local_xlsx_path || '';
  if (workbookUrlEl) workbookUrlEl.value = data.workbook_url || '';
  toggleSoupSyncKind();
}

function buildSoupSyncDraft() {
  const kind = document.getElementById('soup-sync-kind')?.value || 'local_xlsx';
  const displayName = document.getElementById('soup-sync-display-name')?.value.trim() || 'SOUP Workbook';
  const fullProductIdentifier = document.getElementById('soup-sync-product')?.value.trim() || '';
  const bomName = document.getElementById('soup-sync-bom-name')?.value.trim() || 'SOUP Components';
  if (!fullProductIdentifier) throw new Error('Enter the product full_identifier for this SOUP source.');
  if (kind === 'local_xlsx') {
    const localPath = document.getElementById('soup-sync-local-path')?.value.trim() || '';
    if (!localPath) throw new Error('Enter a local XLSX path.');
    return { kind, display_name: displayName, full_product_identifier: fullProductIdentifier, bom_name: bomName, local_xlsx_path: localPath };
  }
  const workbookUrl = document.getElementById('soup-sync-workbook-url')?.value.trim() || '';
  if (!workbookUrl) throw new Error('Enter a workbook URL.');
  if (kind === 'google') {
    const serviceAccountJson = document.getElementById('soup-sync-google-json')?.value.trim() || '';
    if (!serviceAccountJson) throw new Error('Paste the Google service account JSON.');
    return {
      kind,
      platform: 'google',
      workbook_url: workbookUrl,
      display_name: displayName,
      full_product_identifier: fullProductIdentifier,
      bom_name: bomName,
      credentials: { service_account_json: serviceAccountJson },
    };
  }
  const tenantId = document.getElementById('soup-sync-excel-tenant')?.value.trim() || '';
  const clientId = document.getElementById('soup-sync-excel-client')?.value.trim() || '';
  const clientSecret = document.getElementById('soup-sync-excel-secret')?.value.trim() || '';
  if (!tenantId || !clientId || !clientSecret) throw new Error('Enter all Excel Online credentials.');
  return {
    kind,
    platform: 'excel',
    workbook_url: workbookUrl,
    display_name: displayName,
    full_product_identifier: fullProductIdentifier,
    bom_name: bomName,
    credentials: { tenant_id: tenantId, client_id: clientId, client_secret: clientSecret },
  };
}

const soupSyncController = createSyncSettingsController({
  errorId: 'soup-sync-error',
  statusId: 'soup-sync-status',
  loadUrl: '/api/soup-sync',
  validateUrl: '/api/soup-sync/validate',
  saveUrl: '/api/soup-sync',
  deleteUrl: '/api/soup-sync',
  unavailableHtml: '<dt>State</dt><dd>Unavailable</dd>',
  loadErrorPrefix: 'Failed to load SOUP sync settings: ',
  validateErrorPrefix: 'Validation failed: ',
  saveErrorPrefix: 'Failed to save SOUP sync: ',
  deleteErrorPrefix: 'Failed to remove SOUP sync: ',
  deleteConfirm: 'Remove the secondary SOUP source from the active workbook?',
  buildDraft: buildSoupSyncDraft,
  renderStatus: renderSoupSyncStatus,
  applyForm: applySoupSyncForm,
  buildValidationState: (data, draft) => ({
    configured: true,
    kind: data.kind,
    display_name: data.display_name,
    workbook_label: data.workbook_label,
    workbook_url: draft.workbook_url,
    credential_display: data.credential_display,
    local_xlsx_path: draft.local_xlsx_path,
    full_product_identifier: draft.full_product_identifier,
    bom_name: draft.bom_name,
    last_sync_at: 0,
    last_sync_ok: null,
    last_error: null,
  }),
});

export async function loadSoupSyncSettings(force = false) {
  return soupSyncController.load(force);
}

export async function validateSoupSync() {
  return soupSyncController.validate();
}

export async function saveSoupSync() {
  return soupSyncController.save();
}

export async function deleteSoupSync() {
  return soupSyncController.remove();
}
