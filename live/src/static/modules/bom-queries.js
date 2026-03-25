import { esc, propsObj } from '/modules/helpers.js';
import { bomState } from '/modules/state.js';
import { authenticatedApiFetch } from '/modules/uploads.js';

export async function runBomPartUsage() {
  const errEl = document.getElementById('bom-usage-error');
  const resultEl = document.getElementById('bom-usage-result');
  const inputEl = document.getElementById('bom-usage-part');
  const includeObsolete = !!document.getElementById('bom-usage-include-obsolete')?.checked;
  if (!errEl || !resultEl || !inputEl) return;

  errEl.style.display = 'none';
  const part = inputEl.value.trim();
  if (!part) {
    errEl.textContent = 'Enter a part number.';
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
    return;
  }

  resultEl.innerHTML = '<div class="empty-state">Loading part usage…</div>';
  try {
    const query = includeObsolete
      ? `part=${encodeURIComponent(part)}&include_obsolete=true`
      : `part=${encodeURIComponent(part)}`;
    const res = await authenticatedApiFetch(`/api/v1/bom/part-usage?${query}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const usages = Array.isArray(data.usages) ? data.usages : [];
    if (!usages.length) {
      resultEl.innerHTML = '<div class="empty-state">No Design BOM usage found for that part.</div>';
      return;
    }
    resultEl.innerHTML = usages.map((usage) => {
      const designBom = propsObj(usage.design_bom);
      const parent = propsObj(usage.parent_properties);
      const edgeProps = propsObj(usage.edge_properties);
      return `<div class="card card--padded">
        <div class="bom-tree-head">
          <span class="req-id">${esc(usage.part || data.part || '')}</span>
          ${usage.revision ? `<span class="bom-chip">${esc(usage.revision)}</span>` : ''}
          <span class="bom-chip">${esc(designBom.full_product_identifier || '—')}</span>
          <span class="bom-chip">${esc(designBom.bom_name || '—')}</span>
        </div>
        <div class="text-sm-subtle">Parent: ${esc(parent.part || usage.parent_id || 'BOM root')}</div>
        <div class="text-sm-subtle">Quantity: ${esc(edgeProps.quantity || '—')} · Ref Des: ${esc(edgeProps.ref_designator || '—')} · Supplier: ${esc(edgeProps.supplier || '—')}</div>
      </div>`;
    }).join('');
  } catch (error) {
    errEl.textContent = 'Failed to load part usage: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function loadBomGaps() {
  const errEl = document.getElementById('bom-gaps-error');
  const resultEl = document.getElementById('bom-gaps-result');
  const productEl = document.getElementById('bom-gaps-product');
  const nameEl = document.getElementById('bom-gaps-name');
  const includeInactive = !!document.getElementById('bom-gaps-include-inactive')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl) return;

  errEl.style.display = 'none';
  const params = new URLSearchParams();
  if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
  if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
  if (includeInactive) params.set('include_inactive', 'true');
  resultEl.innerHTML = '<div class="empty-state">Loading BOM gaps…</div>';
  try {
    const res = await authenticatedApiFetch(`/api/v1/bom/gaps?${params.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const gaps = Array.isArray(data.gaps) ? data.gaps : [];
    if (!gaps.length) {
      resultEl.innerHTML = '<div class="empty-state">No BOM traceability gaps found for the current filter.</div>';
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
        <div class="text-sm-subtle">Declared requirements: ${(props.requirement_ids || []).map((id) => esc(id)).join(', ') || '—'}</div>
        <div class="text-sm-subtle">Declared tests: ${(props.test_ids || []).map((id) => esc(id)).join(', ') || '—'}</div>
        <div class="mt-8">${(gap.unresolved_requirement_ids || []).concat(gap.unresolved_test_ids || []).map((id) => `<span class="bom-chip warn">${esc(id)}</span>`).join('') || '<span class="text-placeholder">All declared refs currently resolve.</span>'}</div>
      </div>`;
    }).join('');
  } catch (error) {
    errEl.textContent = 'Failed to load BOM gaps: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}

export async function loadBomImpactAnalysis() {
  const errEl = document.getElementById('bom-impact-error');
  const resultEl = document.getElementById('bom-impact-result');
  const productEl = document.getElementById('bom-impact-product');
  const nameEl = document.getElementById('bom-impact-name');
  const includeObsolete = !!document.getElementById('bom-impact-include-obsolete')?.checked;
  if (!errEl || !resultEl || !productEl || !nameEl) return;

  errEl.style.display = 'none';
  if (!productEl.value.trim() && bomState.selectedProduct) productEl.value = bomState.selectedProduct;
  if (!nameEl.value.trim() && bomState.selectedBomName) nameEl.value = bomState.selectedBomName;
  if (!productEl.value.trim() || !nameEl.value.trim()) {
    errEl.textContent = 'Provide a product full_identifier and BOM name, or select a Design BOM first.';
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
    return;
  }

  resultEl.innerHTML = '<div class="empty-state">Loading BOM impact analysis…</div>';
  try {
    const query = new URLSearchParams({
      full_product_identifier: productEl.value.trim(),
      bom_name: nameEl.value.trim(),
    });
    if (includeObsolete) query.set('include_obsolete', 'true');
    const res = await authenticatedApiFetch(`/api/v1/bom/impact-analysis?${query.toString()}`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const items = Array.isArray(data.items) ? data.items : [];
    if (!items.length) {
      resultEl.innerHTML = '<div class="empty-state">No impact records found for that Design BOM.</div>';
      return;
    }
    resultEl.innerHTML = items.map((item) => {
      const props = propsObj(item.properties);
      return `<div class="card card--padded">
        <div class="bom-tree-head">
          <span class="req-id">${esc(props.part || item.item_id || '')}</span>
          <span class="bom-chip">${esc(props.revision || '-')}</span>
          <span class="bom-chip">${esc(String((item.linked_requirements || []).length))} requirements</span>
          <span class="bom-chip">${esc(String((item.linked_tests || []).length))} tests</span>
        </div>
        <div>${(item.linked_requirements || []).map((node) => `<span class="bom-chip">${esc(node.id)}</span>`).join('') || '<span class="text-placeholder">No linked requirements</span>'}</div>
        <div class="mt-8">${(item.linked_tests || []).map((node) => `<span class="bom-chip">${esc(node.id)}</span>`).join('') || '<span class="text-placeholder">No linked tests</span>'}</div>
      </div>`;
    }).join('');
  } catch (error) {
    errEl.textContent = 'Failed to load BOM impact analysis: ' + error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
  }
}
