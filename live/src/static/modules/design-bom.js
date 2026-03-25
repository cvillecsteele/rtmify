import { createSyncSettingsController } from '/modules/sync-settings.js';
import { esc, formatUnixTimestamp, propsObj } from '/modules/helpers.js';
import { bomState } from '/modules/state.js';
import { runBomPartUsage } from '/modules/bom-queries.js';
import { authenticatedApiFetch } from '/modules/uploads.js';

let showTabHook = null;

export function bindDesignBomHooks({ showTab } = {}) {
  showTabHook = typeof showTab === 'function' ? showTab : null;
}

export async function loadDesignBomWorkspace(force = false) {
  const errEl = document.getElementById('design-boms-error');
  const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
  if (errEl) errEl.style.display = 'none';
  try {
    const params = new URLSearchParams();
    if (includeObsolete) params.set('include_obsolete', 'true');
    const res = await authenticatedApiFetch(`/api/v1/bom/design?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    bomState.designBoms = Array.isArray(data.design_boms) ? data.design_boms : [];
    renderDesignBomList();

    const stillSelected = bomState.designBoms.some((bom) =>
      bom.full_product_identifier === bomState.selectedProduct && bom.bom_name === bomState.selectedBomName);
    if (!stillSelected || force) {
      if (bomState.designBoms.length) {
        bomState.selectedProduct = bomState.designBoms[0].full_product_identifier || null;
        bomState.selectedBomName = bomState.designBoms[0].bom_name || null;
      } else {
        bomState.selectedProduct = null;
        bomState.selectedBomName = null;
      }
    }
    renderDesignBomList();
    if (bomState.selectedProduct && bomState.selectedBomName) {
      await loadSelectedDesignBomDetail();
    } else {
      const detailEl = document.getElementById('design-bom-detail');
      if (detailEl) detailEl.innerHTML = '<div class="empty-state">No Design BOMs ingested yet.</div>';
    }
  } catch (error) {
    bomState.designBoms = [];
    renderDesignBomList();
    const detailEl = document.getElementById('design-bom-detail');
    if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load Design BOMs: ${esc(error.message)}</div>`;
    if (errEl) {
      errEl.textContent = 'Failed to load Design BOMs: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export function renderDesignBomList() {
  const bodyEl = document.getElementById('design-bom-list-body');
  if (!bodyEl) return;
  if (!bomState.designBoms.length) {
    bodyEl.innerHTML = '<tr><td colspan="9" class="empty-state">No Design BOMs available for the active workbook.</td></tr>';
    return;
  }
  bodyEl.innerHTML = bomState.designBoms.map((bom) => {
    const selected = bom.full_product_identifier === bomState.selectedProduct && bom.bom_name === bomState.selectedBomName;
    return `<tr${selected ? ' class="warning"' : ''}>
      <td><span class="req-id">${esc(bom.full_product_identifier || '—')}</span></td>
      <td>${esc(bom.product_status || 'Active')}</td>
      <td>${esc(bom.bom_name || '—')}</td>
      <td>${esc(bom.bom_type || '—')}</td>
      <td>${esc(bom.source_format || '—')}</td>
      <td>${esc(String(bom.item_count || 0))}</td>
      <td>${esc(String(bom.warning_count || 0))}</td>
      <td>${esc(formatUnixTimestamp(bom.ingested_at))}</td>
      <td><button class="btn" data-action="select-design-bom" data-product="${esc(bom.full_product_identifier || '')}" data-bom-name="${esc(bom.bom_name || '')}">${selected ? 'Selected' : 'Inspect'}</button></td>
    </tr>`;
  }).join('');
}

export async function selectDesignBom(fullProductIdentifier, bomName) {
  bomState.selectedProduct = fullProductIdentifier || null;
  bomState.selectedBomName = bomName || null;
  renderDesignBomList();
  syncBomFiltersFromSelection();
  await loadSelectedDesignBomDetail();
}

export function syncBomFiltersFromSelection() {
  const product = bomState.selectedProduct || '';
  const name = bomState.selectedBomName || '';
  const ids = [
    ['bom-gaps-product', product],
    ['bom-gaps-name', name],
    ['bom-impact-product', product],
    ['bom-impact-name', name],
    ['bom-components-product', product],
    ['bom-components-name', name],
    ['bom-coverage-product', product],
    ['bom-coverage-name', name],
    ['report-design-bom-product', product],
    ['report-design-bom-name', name],
  ];
  ids.forEach(([id, value]) => {
    const el = document.getElementById(id);
    if (el && !el.value) el.value = value;
  });
}

async function loadSelectedDesignBomDetail() {
  const detailEl = document.getElementById('design-bom-detail');
  const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
  if (!detailEl) return;
  if (!bomState.selectedProduct || !bomState.selectedBomName) {
    detailEl.innerHTML = '<div class="empty-state">Select a Design BOM to inspect it.</div>';
    return;
  }
  detailEl.innerHTML = '<div class="empty-state">Loading Design BOM detail…</div>';
  try {
    const product = encodeURIComponent(bomState.selectedProduct);
    const bomName = encodeURIComponent(bomState.selectedBomName);
    const query = includeObsolete ? `full_product_identifier=${product}&include_obsolete=true` : `full_product_identifier=${product}`;
    const [treeRes, itemsRes] = await Promise.all([
      authenticatedApiFetch(`/api/v1/bom/design/${bomName}?${query}`, { cache: 'no-store' }),
      authenticatedApiFetch(`/api/v1/bom/design/${bomName}/items?${query}`, { cache: 'no-store' }),
    ]);
    if (!treeRes.ok) throw new Error(`tree HTTP ${treeRes.status}`);
    if (!itemsRes.ok) throw new Error(`items HTTP ${itemsRes.status}`);
    const treeData = await treeRes.json();
    const itemsData = await itemsRes.json();
    detailEl.innerHTML = renderDesignBomDetail(treeData, itemsData);
    syncBomFiltersFromSelection();
  } catch (error) {
    detailEl.innerHTML = `<div class="empty-state">Failed to load Design BOM detail: ${esc(error.message)}</div>`;
  }
}

export function renderDesignBomDetail(treeData, itemsData) {
  const designBoms = Array.isArray(treeData.design_boms) ? treeData.design_boms : [];
  const items = Array.isArray(itemsData.items) ? itemsData.items : [];
  const totalWarnings = items.reduce((sum, item) =>
    sum + ((item.unresolved_requirement_ids || []).length + (item.unresolved_test_ids || []).length), 0);

  return `
    <div class="toolbar card-toolbar">
      <span class="card-title">${esc(treeData.full_product_identifier || '')} · ${esc(treeData.bom_name || '')}</span>
    </div>
    <div class="bom-metrics">
      <div class="bom-metric"><div class="bom-metric-label">BOM Variants</div><div class="bom-metric-value">${esc(String(designBoms.length))}</div></div>
      <div class="bom-metric"><div class="bom-metric-label">Items</div><div class="bom-metric-value">${esc(String(items.length))}</div></div>
      <div class="bom-metric"><div class="bom-metric-label">Unresolved Trace Refs</div><div class="bom-metric-value">${esc(String(totalWarnings))}</div></div>
    </div>
    <div class="bom-detail-grid">
      <div>
        <h3 class="mb-10">Hierarchy</h3>
        ${designBoms.length ? designBoms.map((bom) => `
          <div class="card card--mb card--padded">
            <div class="bom-tree-head">
              <span class="req-id">${esc(bom.bom_type || '')}</span>
              <span class="bom-chip">${esc(bom.source_format || '')}</span>
            </div>
            ${renderBomTreeRoots(bom.tree?.roots || [])}
          </div>
        `).join('') : '<div class="empty-state">No Design BOM tree available.</div>'}
      </div>
      <div>
        <h3 class="mb-10">Flattened Item Traceability</h3>
        ${items.length ? `<div class="table-scroll"><table>
          <thead><tr><th>Part</th><th>Rev</th><th>Declared Trace</th><th>Resolved Links</th><th>Unresolved</th></tr></thead>
          <tbody>${items.map(renderDesignBomItemRow).join('')}</tbody>
        </table></div>` : '<div class="empty-state">No flattened BOM items available.</div>'}
      </div>
    </div>
  `;
}

function renderBomTreeRoots(roots) {
  if (!roots.length) return '<div class="empty-state">No root items.</div>';
  return `<div class="bom-tree">${roots.map((node) => renderBomTreeNode(node)).join('')}</div>`;
}

export function renderBomTreeNode(node) {
  if (!node) return '';
  const props = propsObj(node.properties);
  const edgeProps = propsObj(node.edge_properties);
  const trace = []
    .concat(Array.isArray(props.requirement_ids) ? props.requirement_ids : [])
    .concat(Array.isArray(props.test_ids) ? props.test_ids : []);
  return `
    <div class="bom-tree-node">
      <div class="bom-tree-head">
        <span class="req-id">${esc(props.part || node.id || '')}</span>
        <span class="bom-chip">${esc(props.revision || '-')}</span>
        ${edgeProps.quantity ? `<span class="bom-chip">qty ${esc(edgeProps.quantity)}</span>` : ''}
        ${edgeProps.ref_designator ? `<span class="bom-chip">${esc(edgeProps.ref_designator)}</span>` : ''}
        ${props.category ? `<span class="bom-chip">${esc(props.category)}</span>` : ''}
      </div>
      ${props.description ? `<div class="text-sm-subtle">${esc(props.description)}</div>` : ''}
      ${trace.length ? `<div class="mt-8">${trace.map((value) => `<span class="bom-chip">${esc(value)}</span>`).join('')}</div>` : ''}
      ${Array.isArray(node.children) && node.children.length ? `<div class="bom-tree-children">${node.children.map((child) => renderBomTreeNode(child)).join('')}</div>` : ''}
    </div>
  `;
}

function renderDesignBomItemRow(item) {
  const node = item.node || {};
  const props = propsObj(node.properties);
  const declared = []
    .concat(Array.isArray(props.requirement_ids) ? props.requirement_ids : [])
    .concat(Array.isArray(props.test_ids) ? props.test_ids : []);
  const linked = []
    .concat((item.linked_requirements || []).map((nodeItem) => nodeItem.id))
    .concat((item.linked_tests || []).map((nodeItem) => nodeItem.id));
  const unresolved = []
    .concat(item.unresolved_requirement_ids || [])
    .concat(item.unresolved_test_ids || []);
  return `<tr>
    <td><span class="req-id">${esc(props.part || node.id || '—')}</span></td>
    <td>${esc(props.revision || '—')}</td>
    <td>${declared.length ? declared.map((value) => `<span class="bom-chip">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
    <td>${linked.length ? linked.map((value) => `<span class="bom-chip">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
    <td>${unresolved.length ? unresolved.map((value) => `<span class="bom-chip warn">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
  </tr>`;
}

export async function loadBomComponents() {
  const errEl = document.getElementById('bom-components-error');
  const resultEl = document.getElementById('bom-components-result');
  const productEl = document.getElementById('bom-components-product');
  const nameEl = document.getElementById('bom-components-name');
  const searchEl = document.getElementById('bom-components-search');
  const includeObsolete = !!document.getElementById('bom-components-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl || !searchEl) return;

  errEl.style.display = 'none';
  const params = new URLSearchParams();
  if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
  if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
  if (includeObsolete) params.set('include_obsolete', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading components…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/bom/components?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const q = searchEl.value.trim().toLowerCase();
    const rows = (Array.isArray(data.components) ? data.components : []).filter((item) => {
      if (!q) return true;
      const props = propsObj(item.properties);
      return [props.part, props.description, props.category, item.full_product_identifier, item.bom_name]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(q));
    });
    if (!rows.length) {
      resultEl.innerHTML = '<div class="empty-state">No matching BOM components found.</div>';
      return;
    }
    resultEl.innerHTML = `<div class="table-scroll"><table>
      <thead><tr><th>Product</th><th>BOM</th><th>Part</th><th>Rev</th><th>Description</th><th>Category</th><th>Req Links</th><th>Test Links</th><th>Warnings</th><th></th></tr></thead>
      <tbody>${rows.map((item) => {
        const props = propsObj(item.properties);
        const warningCount = Number(item.unresolved_requirement_count || 0) + Number(item.unresolved_test_count || 0);
        return `<tr>
          <td>${esc(item.full_product_identifier || '—')}</td>
          <td>${esc(item.bom_name || '—')}</td>
          <td><span class="req-id">${esc(props.part || '—')}</span></td>
          <td>${esc(props.revision || '—')}</td>
          <td>${esc(props.description || '—')}</td>
          <td>${esc(props.category || '—')}</td>
          <td>${esc(String(item.linked_requirement_count || 0))}</td>
          <td>${esc(String(item.linked_test_count || 0))}</td>
          <td>${esc(String(warningCount))}</td>
          <td><button class="btn" data-action="inspect-bom-component" data-item-id="${esc(item.item_id || '')}" data-part="${esc(props.part || '')}" data-product="${esc(item.full_product_identifier || '')}" data-bom-name="${esc(item.bom_name || '')}">Inspect</button></td>
        </tr>`;
      }).join('')}</tbody>
    </table></div>`;
  } catch (error) {
    errEl.textContent = 'Failed to load BOM components: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function inspectBomComponent(itemId, part, fullProductIdentifier, bomName) {
  bomState.selectedProduct = fullProductIdentifier || null;
  bomState.selectedBomName = bomName || null;
  renderDesignBomList();
  syncBomFiltersFromSelection();
  await loadSelectedDesignBomDetail();
  const usageInput = document.getElementById('bom-usage-part');
  if (usageInput) usageInput.value = part || '';
  if (showTabHook) showTabHook('bom-usage');
  await runBomPartUsage();
}

export async function loadBomCoverage() {
  const errEl = document.getElementById('bom-coverage-error');
  const resultEl = document.getElementById('bom-coverage-result');
  const productEl = document.getElementById('bom-coverage-product');
  const nameEl = document.getElementById('bom-coverage-name');
  const includeObsolete = !!document.getElementById('bom-coverage-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl) return;

  errEl.style.display = 'none';
  const params = new URLSearchParams();
  if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
  if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
  if (includeObsolete) params.set('include_obsolete', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading BOM coverage…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/bom/coverage?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const summary = data.summary || {};
    const rows = Array.isArray(data.design_boms) ? data.design_boms : [];
    resultEl.innerHTML = `
      <div class="bom-metrics">
        <div class="bom-metric"><div class="bom-metric-label">Items</div><div class="bom-metric-value">${esc(String(summary.item_count || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Req Covered</div><div class="bom-metric-value">${esc(String(summary.requirement_covered_count || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Test Covered</div><div class="bom-metric-value">${esc(String(summary.test_covered_count || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Fully Covered</div><div class="bom-metric-value">${esc(String(summary.fully_covered_count || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">No Trace</div><div class="bom-metric-value">${esc(String(summary.no_trace_count || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Warnings</div><div class="bom-metric-value">${esc(String(summary.warning_count || 0))}</div></div>
      </div>
      ${rows.length ? `<div class="table-scroll"><table>
        <thead><tr><th>Product</th><th>Status</th><th>BOM</th><th>Items</th><th>Req Covered</th><th>Test Covered</th><th>Fully Covered</th><th>No Trace</th><th>Warnings</th></tr></thead>
        <tbody>${rows.map((row) => `<tr>
          <td>${esc(row.full_product_identifier || '—')}</td>
          <td>${esc(row.product_status || 'Active')}</td>
          <td>${esc(row.bom_name || '—')}</td>
          <td>${esc(String(row.item_count || 0))}</td>
          <td>${esc(String(row.requirement_covered_count || 0))}</td>
          <td>${esc(String(row.test_covered_count || 0))}</td>
          <td>${esc(String(row.fully_covered_count || 0))}</td>
          <td>${esc(String(row.no_trace_count || 0))}</td>
          <td>${esc(String(row.warning_count || 0))}</td>
        </tr>`).join('')}</tbody>
      </table></div>` : '<div class="empty-state">No Design BOM coverage rows found.</div>'}
    `;
  } catch (error) {
    errEl.textContent = 'Failed to load BOM coverage: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export function downloadDesignBomReport(format = 'md') {
  const productEl = document.getElementById('report-design-bom-product');
  const nameEl = document.getElementById('report-design-bom-name');
  const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
  const fullProductIdentifier = productEl?.value.trim() || bomState.selectedProduct || '';
  const bomName = nameEl?.value.trim() || bomState.selectedBomName || '';
  if (!fullProductIdentifier || !bomName) {
    window.alert('Select a Design BOM first, or enter both product full_identifier and BOM name.');
    return;
  }
  if (productEl && !productEl.value.trim()) productEl.value = fullProductIdentifier;
  if (nameEl && !nameEl.value.trim()) nameEl.value = bomName;
  const query = new URLSearchParams({ full_product_identifier: fullProductIdentifier, bom_name: bomName });
  if (includeObsolete) query.set('include_obsolete', 'true');
  const path = format === 'pdf' ? '/report/design-bom' : (format === 'docx' ? '/report/design-bom.docx' : '/report/design-bom.md');
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

export function toggleDesignBomSyncKind() {
  toggleSyncKind('design-bom-sync');
}

function renderDesignBomSyncStatus(data) {
  const statusEl = document.getElementById('design-bom-sync-status');
  if (!statusEl) return;
  if (!data.configured) {
    statusEl.innerHTML = '<dt>State</dt><dd>Not configured</dd><dt>Sync</dt><dd>No secondary Design BOM source attached.</dd>';
    return;
  }
  statusEl.innerHTML = `
    <dt>State</dt><dd>${esc(data.kind || 'unknown')}</dd>
    <dt>Display Name</dt><dd>${esc(data.display_name || '—')}</dd>
    <dt>Workbook</dt><dd>${esc(data.workbook_label || data.workbook_url || data.local_xlsx_path || '—')}</dd>
    <dt>Credential</dt><dd>${esc(data.credential_display || 'stored in secure store')}</dd>
    <dt>Last Sync</dt><dd>${esc(formatUnixTimestamp(data.last_sync_at))}</dd>
    <dt>Last Result</dt><dd>${data.last_sync_ok === '1' ? 'OK' : (data.last_error || 'No successful sync recorded')}</dd>
  `;
}

function applyDesignBomSyncForm(data) {
  const kind = data.configured ? (data.kind || 'local_xlsx') : 'local_xlsx';
  const kindEl = document.getElementById('design-bom-sync-kind');
  const displayNameEl = document.getElementById('design-bom-sync-display-name');
  const localPathEl = document.getElementById('design-bom-sync-local-path');
  const workbookUrlEl = document.getElementById('design-bom-sync-workbook-url');
  if (kindEl) kindEl.value = kind;
  if (displayNameEl) displayNameEl.value = data.display_name || 'Design BOM Workbook';
  if (localPathEl) localPathEl.value = data.local_xlsx_path || '';
  if (workbookUrlEl) workbookUrlEl.value = data.workbook_url || '';
  toggleDesignBomSyncKind();
}

function buildDesignBomSyncDraft() {
  const kind = document.getElementById('design-bom-sync-kind')?.value || 'local_xlsx';
  const displayName = document.getElementById('design-bom-sync-display-name')?.value.trim() || 'Design BOM Workbook';
  if (kind === 'local_xlsx') {
    const localPath = document.getElementById('design-bom-sync-local-path')?.value.trim() || '';
    if (!localPath) throw new Error('Enter a local XLSX path.');
    return { kind, display_name: displayName, local_xlsx_path: localPath };
  }
  const workbookUrl = document.getElementById('design-bom-sync-workbook-url')?.value.trim() || '';
  if (!workbookUrl) throw new Error('Enter a workbook URL.');
  if (kind === 'google') {
    const serviceAccountJson = document.getElementById('design-bom-sync-google-json')?.value.trim() || '';
    if (!serviceAccountJson) throw new Error('Paste the Google service account JSON.');
    return {
      kind,
      platform: 'google',
      workbook_url: workbookUrl,
      display_name: displayName,
      credentials: { service_account_json: serviceAccountJson },
    };
  }
  const tenantId = document.getElementById('design-bom-sync-excel-tenant')?.value.trim() || '';
  const clientId = document.getElementById('design-bom-sync-excel-client')?.value.trim() || '';
  const clientSecret = document.getElementById('design-bom-sync-excel-secret')?.value.trim() || '';
  if (!tenantId || !clientId || !clientSecret) throw new Error('Enter all Excel Online credentials.');
  return {
    kind,
    platform: 'excel',
    workbook_url: workbookUrl,
    display_name: displayName,
    credentials: { tenant_id: tenantId, client_id: clientId, client_secret: clientSecret },
  };
}

const designBomSyncController = createSyncSettingsController({
  errorId: 'design-bom-sync-error',
  statusId: 'design-bom-sync-status',
  loadUrl: '/api/design-bom-sync',
  validateUrl: '/api/design-bom-sync/validate',
  saveUrl: '/api/design-bom-sync',
  deleteUrl: '/api/design-bom-sync',
  unavailableHtml: '<dt>State</dt><dd>Unavailable</dd>',
  loadErrorPrefix: 'Failed to load Design BOM sync settings: ',
  validateErrorPrefix: 'Validation failed: ',
  saveErrorPrefix: 'Failed to save Design BOM sync: ',
  deleteErrorPrefix: 'Failed to remove Design BOM sync: ',
  deleteConfirm: 'Remove the secondary Design BOM source from the active workbook?',
  buildDraft: buildDesignBomSyncDraft,
  renderStatus: renderDesignBomSyncStatus,
  applyForm: applyDesignBomSyncForm,
  buildValidationState: (data, draft) => ({
    configured: true,
    kind: data.kind,
    display_name: data.display_name,
    workbook_label: data.workbook_label,
    workbook_url: draft.workbook_url,
    credential_display: data.credential_display,
    local_xlsx_path: draft.local_xlsx_path,
    last_sync_at: 0,
    last_sync_ok: null,
    last_error: null,
  }),
});

export async function loadDesignBomSyncSettings(force = false) {
  return designBomSyncController.load(force);
}

export async function validateDesignBomSync() {
  return designBomSyncController.validate();
}

export async function saveDesignBomSync() {
  return designBomSyncController.save();
}

export async function deleteDesignBomSync() {
  return designBomSyncController.remove();
}
