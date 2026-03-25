import { esc } from '/modules/helpers.js';
import { humanEdgeLabel } from '/modules/graph-edges.js';
import { fetchNodeEnvelope, renderEdgeSections, renderNodeProperties } from '/modules/node-render.js';

let drawerHistory = [];
let drawerOpener = null;

export async function openNode(id) {
  drawerOpener = document.activeElement;
  drawerHistory = [id];
  await renderDrawerNode(id);
  document.getElementById('node-drawer')?.classList.add('open');
  document.getElementById('drawer-overlay')?.classList.add('visible');
  document.getElementById('drawer-content')?.focus();
}

export async function drawerNav(id) {
  drawerHistory.push(id);
  await renderDrawerNode(id);
}

export async function drawerBack() {
  if (drawerHistory.length <= 1) return;
  drawerHistory.pop();
  await renderDrawerNode(drawerHistory[drawerHistory.length - 1]);
}

export function closeDrawer() {
  document.getElementById('node-drawer')?.classList.remove('open');
  document.getElementById('drawer-overlay')?.classList.remove('visible');
  drawerHistory = [];
  drawerOpener?.focus();
  drawerOpener = null;
}

export async function renderDrawerNode(id) {
  const content = document.getElementById('drawer-content');
  const backBtn = document.getElementById('drawer-back');
  if (!content || !backBtn) return;
  backBtn.disabled = drawerHistory.length <= 1;
  content.innerHTML = '<div class="empty-state">Loading…</div>';

  let data;
  try {
    data = await fetchNodeEnvelope(id);
  } catch (error) {
    content.innerHTML = '<div class="empty-state">Error: ' + esc(error.message) + '</div>';
    return;
  }

  try {
    const { node, edges_out, edges_in } = data;
    const props = renderNodeProperties(node, 'prop');
    const sections = renderEdgeSections(node, edges_out, edges_in, (label, items) => {
      const rows = items.length
        ? items.map(({ edge, rawDir }) => {
          const relation = humanEdgeLabel(node.type, edge, rawDir);
          return `<div class="edge-row" data-action="drawer-nav" data-id="${esc(edge.node.id)}">
            <span class="edge-label">${esc(relation)}</span>
            <span class="node-id-link">${esc(edge.node.id)}</span>
            <span class="node-type-badge">${esc(edge.node.type)}</span>
          </div>`;
        }).join('')
        : '<div class="edge-empty">None</div>';
      return `
        <div class="edge-section">
          <div class="edge-section-title">${label} (${items.length})</div>
          ${rows}
        </div>`;
    });

    const suspectBanner = node.suspect ? `
      <div class="suspect-banner">
        <span class="suspect-text">
          <span class="suspect-label">SUSPECT</span>${node.suspect_reason ? esc(node.suspect_reason) : ''}
        </span>
        <button class="suspect-clear" data-action="clear-suspect" data-id="${esc(node.id)}">Mark Reviewed</button>
      </div>` : '';

    content.innerHTML = `
      <div class="drawer-node-header">
        <span class="node-type-badge">${esc(node.type)}</span>
        <span class="drawer-node-id">${esc(node.id)}</span>
      </div>
      ${suspectBanner}
      <div class="prop-section">${props}</div>
      ${sections.downstreamHtml}
      ${sections.upstreamHtml}`;
  } catch (error) {
    console.error('drawer render failure', error, data);
    content.innerHTML = '<div class="empty-state">Error: render failure: ' + esc(error.message) + '</div>';
  }
}
