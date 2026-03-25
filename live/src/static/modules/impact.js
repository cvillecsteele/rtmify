import { CHEVRON_SVG, esc } from '/modules/helpers.js';

export async function runImpact() {
  const id = document.getElementById('impact-input')?.value.trim();
  const errEl = document.getElementById('impact-error');
  const resultEl = document.getElementById('impact-result');
  if (!errEl || !resultEl) return;

  errEl.style.display = 'none';
  if (!id) return;
  resultEl.innerHTML = '<div class="empty-state loading-pulse">Analyzing…</div>';

  let data;
  try {
    const url = new URL('/query/impact/' + encodeURIComponent(id), window.location.origin).toString();
    const res = await fetch(url, { cache: 'no-store' });
    if (res.status === 404) throw new Error(`Node "${id}" not found`);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    data = await res.json();
  } catch (error) {
    errEl.textContent = error.message;
    errEl.style.display = 'block';
    resultEl.innerHTML = '';
    return;
  }

  if (data.length === 0) {
    resultEl.innerHTML = '<div class="empty-state"><strong>No downstream impact</strong><br>Nothing depends on this node via traced edges.</div>';
    return;
  }

  resultEl.innerHTML = `
    <p class="text-sm-muted mb-12">
      Changing <strong>${esc(id)}</strong> would affect <strong>${data.length}</strong> node${data.length === 1 ? '' : 's'}:
    </p>
    <div class="card">
      <table>
        <thead><tr><th>Node ID</th><th>Type</th><th>Via</th></tr></thead>
        <tbody>
          ${data.map((node) => `<tr>
            <td><button class="expand-btn" aria-label="Expand ${esc(node.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(node.id)}" data-colspan="3">${CHEVRON_SVG}</button><span class="req-id">${esc(node.id)}</span></td>
            <td><span class="node-type-badge">${esc(node.type)}</span></td>
            <td><span class="tree-edge-label">${esc(node.dir)} ${esc(node.via)}</span></td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
}
