import { CHEVRON_SVG, esc } from '/modules/helpers.js';

let rerenderNodeHook = null;
let refreshAllHook = null;

export function bindSuspectHooks({ rerenderNode, refreshAll } = {}) {
  rerenderNodeHook = typeof rerenderNode === 'function' ? rerenderNode : null;
  refreshAllHook = typeof refreshAll === 'function' ? refreshAll : null;
}

export async function loadSuspects() {
  const errEl = document.getElementById('review-error');
  const resultEl = document.getElementById('review-result');
  if (!errEl || !resultEl) return;

  errEl.style.display = 'none';
  resultEl.innerHTML = '<div class="empty-state loading-pulse">Loading…</div>';

  let data;
  try {
    const res = await fetch('/query/suspects');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    data = await res.json();
  } catch (error) {
    errEl.textContent = 'Failed to load: ' + error.message;
    errEl.style.display = 'block';
    return;
  }

  updateSuspectBadge(data.length);

  if (data.length === 0) {
    resultEl.innerHTML = '<div class="empty-state"><strong>All clear</strong><br>No nodes flagged for review.</div>';
    return;
  }

  resultEl.innerHTML = `
    <div class="card">
      <table>
        <thead><tr><th>Node ID</th><th>Type</th><th>Reason</th><th></th></tr></thead>
        <tbody>
          ${data.map((node) => `<tr class="suspect">
            <td><button class="expand-btn" aria-label="Expand ${esc(node.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(node.id)}" data-colspan="4">${CHEVRON_SVG}</button><span class="req-id">${esc(node.id)}</span></td>
            <td><span class="node-type-badge">${esc(node.type)}</span></td>
            <td class="text-suspect">${esc(node.suspect_reason || '')}</td>
            <td><button class="suspect-clear" data-action="clear-suspect" data-id="${esc(node.id)}">Mark Reviewed</button></td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
}

export function updateSuspectBadge(count) {
  const headerBadge = document.getElementById('suspect-header-badge');
  const navBadge = document.getElementById('suspect-nav-badge');
  const groupBadge = document.getElementById('suspect-group-badge');
  if (!headerBadge || !navBadge) return;

  const prevCount = navBadge.dataset.count ? Number(navBadge.dataset.count) : -1;
  if (count > 0) {
    const label = count + ' suspect';
    headerBadge.textContent = '⚠ ' + label;
    headerBadge.style.display = 'inline';
    navBadge.textContent = count;
    navBadge.dataset.count = String(count);
    navBadge.style.display = 'inline';
    if (groupBadge) {
      groupBadge.textContent = String(count);
      groupBadge.className = navBadge.className;
      groupBadge.style.display = 'inline';
    }
    if (prevCount !== count) {
      [navBadge, headerBadge, groupBadge].forEach((el) => {
        if (!el) return;
        el.classList.remove('badge-pop');
        void el.offsetWidth;
        el.classList.add('badge-pop');
      });
    }
  } else {
    headerBadge.style.display = 'none';
    navBadge.style.display = 'none';
    navBadge.dataset.count = '0';
    if (groupBadge) groupBadge.style.display = 'none';
  }
}

export async function refreshSuspectBadge() {
  try {
    const res = await fetch('/query/suspects');
    const data = await res.json();
    updateSuspectBadge(data.length);
  } catch {}
}

export async function clearSuspect(id) {
  await fetch('/suspect/' + encodeURIComponent(id) + '/clear', { method: 'POST' });
  if (rerenderNodeHook) {
    await rerenderNodeHook(id);
  }
  if (refreshAllHook) {
    await refreshAllHook();
  } else {
    await refreshSuspectBadge();
  }
  if (document.getElementById('tab-review')?.classList.contains('active')) {
    await loadSuspects();
  }
}
