export const CHEVRON_SVG = `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 1.5l4 3.5-4 3.5"/></svg>`;

export function esc(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function propsObj(value) {
  if (!value) return {};
  if (typeof value === 'string') {
    try {
      return JSON.parse(value);
    } catch {
      return {};
    }
  }
  return value;
}

export function rowSeverity(row) {
  const result = row.aggregate_result || row.result;
  const hasTests = Array.isArray(row.test_group_ids) ? row.test_group_ids.length > 0 : !!row.test_group_id;
  if (result === 'FAIL') return 'error';
  if (!hasTests || !row.user_need_id) return 'warning';
  return '';
}

export function resultBadge(result, hasTest) {
  if (!hasTest) return '';
  if (!result) return '<span class="result-pending">Pending</span>';
  if (result === 'PASS') return '<span class="result-pass">Pass</span>';
  if (result === 'FAIL') return '<span class="result-fail">Fail</span>';
  return `<span class="result-pending">${esc(result)}</span>`;
}

export function formatUnixTimestamp(ts) {
  if (!ts || Number(ts) <= 0) return 'never';
  try {
    return new Date(Number(ts) * 1000).toLocaleString();
  } catch {
    return String(ts);
  }
}

export function closestActionElement(target, selector = '[data-action]') {
  return target instanceof Element ? target.closest(selector) : null;
}

export function formatDiagnosticsError(data) {
  const diagnostics = data?.diagnostics || [];
  if (!diagnostics.length) return data?.detail || '';
  return diagnostics.map((diagnostic) => `E${diagnostic.code}: ${diagnostic.message}`).join(' ');
}

export function renderSimpleNodeList(nodes, emptyMessage) {
  if (!nodes || nodes.length === 0) {
    return `<em class="text-hint">${esc(emptyMessage)}</em>`;
  }
  return nodes.map((node) => `<div class="repo-row repo-row--block">
      <div><strong>${esc(node.id || '')}</strong></div>
      <div class="text-sm-subtle">${esc(node.type || '')}</div>
    </div>`).join('');
}
