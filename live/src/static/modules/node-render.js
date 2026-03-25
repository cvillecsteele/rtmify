import { esc, propsObj } from '/modules/helpers.js';
import { humanEdgeLabel, splitSemanticEdges } from '/modules/graph-edges.js';

export async function fetchNodeEnvelope(id) {
  const res = await fetch('/query/node/' + encodeURIComponent(id));
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const data = await res.json();
  if (!data?.node || !Array.isArray(data?.edges_out) || !Array.isArray(data?.edges_in)) {
    throw new Error('invalid node payload');
  }
  return data;
}

export function renderNodeProperties(node, classPrefix = 'prop') {
  return Object.entries(propsObj(node.properties))
    .filter(([key]) => key !== 'source_assertions')
    .filter(([, value]) => value !== '' && value != null)
    .map(([key, value]) => `<div class="${classPrefix}-row">
      <span class="${classPrefix}-key">${esc(key)}</span>
      <span class="${classPrefix}-val">${esc(String(value))}</span>
    </div>`).join('');
}

export function renderEdgeSections(node, edgesOut, edgesIn, renderer) {
  const { upstream, downstream } = splitSemanticEdges(node.type, edgesOut, edgesIn);
  return {
    upstream,
    downstream,
    upstreamHtml: renderer('Upstream', upstream),
    downstreamHtml: renderer('Downstream', downstream),
  };
}

export function renderNodeTreeSection(currentType, label, edges, renderNodeTreeChild) {
  const items = edges.map(({ edge, rawDir }) => renderNodeTreeChild(currentType, edge, rawDir)).join('');
  return `
    <div class="tree-section">
      <div class="tree-section-header" data-action="toggle-tree-section">
        <button class="expand-btn" aria-label="Expand ${label}" aria-expanded="false">${getChevron()}</button>
        <span class="tree-section-label">${label}</span>
        <span class="tree-count">${edges.length}</span>
      </div>
      <div class="tree-section-body" style="display:none">
        ${items || '<div class="de-none">—</div>'}
      </div>
    </div>`;
}

export function renderNodeTreeChild(currentType, edge, dir) {
  const relation = humanEdgeLabel(currentType, edge, dir);
  return `
    <div class="tree-node">
      <div class="tree-node-header">
        <button class="expand-btn" aria-label="Expand ${esc(edge.node.id)}" aria-expanded="false" data-action="toggle-tree-node" data-id="${esc(edge.node.id)}">${getChevron()}</button>
        <span class="tree-edge-label">${esc(relation)}</span>
        <span class="tree-node-id">${esc(edge.node.id)}</span>
        <span class="node-type-badge">${esc(edge.node.type)}</span>
      </div>
      <div class="tree-node-body" style="display:none"></div>
    </div>`;
}

export async function fillNodeDetail(container, id, { showProps = true } = {}) {
  let data;
  try {
    data = await fetchNodeEnvelope(id);
  } catch (error) {
    container.innerHTML = `<span class="text-error-inline">Error: ${esc(error.message)}</span>`;
    return;
  }

  try {
    const { node, edges_out, edges_in } = data;
    const rawProps = propsObj(node.properties);
    const props = renderNodeProperties(node, 'dp');
    const sourceAssertions = renderSourceAssertions(rawProps);
    const suspect = node.suspect ? `
      <div class="di-suspect">
        <span><strong>SUSPECT</strong>${node.suspect_reason ? ' — ' + esc(node.suspect_reason) : ''}</span>
        <button data-action="clear-suspect" data-id="${esc(node.id)}">Mark Reviewed</button>
      </div>` : '';
    const sections = renderEdgeSections(
      node,
      edges_out,
      edges_in,
      (label, edges) => renderNodeTreeSection(node.type, label, edges, renderNodeTreeChild),
    );

    container.innerHTML = `
      ${suspect}
      ${showProps ? `<div class="detail-props">${props}</div>` : ''}
      ${sourceAssertions}
      <div class="tree-sections">
        ${sections.downstreamHtml}
        ${sections.upstreamHtml}
      </div>`;
  } catch (error) {
    console.error('inline detail render failure', error, data);
    container.innerHTML = `<span class="text-error-inline">Error: render failure: ${esc(error.message)}</span>`;
  }
}

function renderSourceAssertions(props) {
  const assertions = Array.isArray(props.source_assertions) ? props.source_assertions : [];
  if (!assertions.length) return '';

  const rows = assertions
    .filter((item) => item && (item.artifact_id || item.text || item.source_kind))
    .map((item) => {
      const context = [item.section, item.parse_status && item.parse_status !== 'ok' ? item.parse_status : '']
        .filter(Boolean)
        .join(' · ');
      return `<div class="suspect-source-item">
        <div class="suspect-source-meta">
          <span class="node-type-badge">${esc(formatRequirementSourceKind(item.source_kind || ''))}</span>
          <span class="req-id">${esc(item.artifact_id || item.id || 'unknown source')}</span>
        </div>
        <div class="suspect-source-subtle">${esc(context || 'source assertion')}</div>
        <div class="suspect-source-text">${esc(item.text || '—')}</div>
      </div>`;
    })
    .join('');
  if (!rows) return '';

  const title = props.text_status === 'conflict' ? 'Differing Source Texts' : 'Source Assertions';
  return `<div class="suspect-source-preview">
    <div class="suspect-source-title">${esc(title)}</div>
    ${rows}
  </div>`;
}

function formatRequirementSourceKind(kind) {
  if (kind === 'rtm_workbook') return 'RTM Workbook';
  if (kind === 'urs_docx') return 'URS';
  if (kind === 'srs_docx') return 'SRS';
  if (kind === 'swrs_docx') return 'SwRS';
  if (kind === 'hrs_docx') return 'HRS';
  if (kind === 'sysrd_docx') return 'SysRD / SRD';
  return kind || 'Source';
}

function getChevron() {
  return `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 1.5l4 3.5-4 3.5"/></svg>`;
}
