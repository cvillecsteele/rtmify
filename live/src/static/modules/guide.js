import {
  guideErrorsCache,
  guideLookupByAnchor,
  guideLookupByKey,
  pendingGuideAnchor,
  setGuideErrorsCache,
  setGuideLookupByAnchor,
  setGuideLookupByKey,
  setPendingGuideAnchor,
} from '/modules/state.js';
import { esc } from '/modules/helpers.js';

let showTabHook = () => {};

export function bindGuideNavigation({ showTab }) {
  showTabHook = showTab;
}

function guideKeyForEntry(entry) {
  if (entry.surface === 'runtime_diagnostic') return `diag:${entry.code_label}`;
  return entry.variant ? `gap:${entry.code}:${entry.variant}` : `gap:${entry.code}`;
}

function updateGuideHash(anchor) {
  if (window.location.hash === `#${anchor}`) return;
  history.replaceState(null, '', `#${anchor}`);
}

function activateGuideEntry(anchor) {
  document.querySelectorAll('.guide-entry.active-guide').forEach((el) => el.classList.remove('active-guide'));
  const el = document.getElementById(anchor);
  if (!el) return;
  el.classList.add('active-guide');
  el.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function consumePendingGuideAnchor() {
  if (!pendingGuideAnchor) return;
  const anchor = pendingGuideAnchor;
  setPendingGuideAnchor(null);
  requestAnimationFrame(() => activateGuideEntry(anchor));
}

export function renderGuideErrors(data) {
  const indexEl = document.getElementById('guide-errors-index');
  const bodyEl = document.getElementById('guide-errors-body');
  if (!indexEl || !bodyEl) return;

  const groups = data.groups || [];
  indexEl.innerHTML = `<h3>Index</h3>${groups.map((group) => `
        <div class="guide-index-group">
        <div class="guide-index-group-title">${esc(group.title || '')}</div>
        ${(group.entries || []).map((entry) => `
          <a href="#${esc(entry.anchor || '')}" data-action="open-guide" data-guide-code="${esc(entry.code_label || entry.code || '')}" data-guide-variant="${esc(entry.variant || '')}">
            ${esc(entry.code_label || '')} ${esc(entry.title || '')}
          </a>
        `).join('')}
      </div>
    `).join('')}`;

  bodyEl.innerHTML = groups.map((group) => `
      <div class="card guide-group-card">
        <h3>${esc(group.title || '')}</h3>
        <div class="guide-entries">
          ${(group.entries || []).map((entry) => `
            <article id="${esc(entry.anchor || '')}" class="guide-entry">
              <div class="guide-entry-head">
                <span class="guide-entry-code">${esc(entry.code_label || '')}</span>
                <span class="guide-entry-title">${esc(entry.title || '')}</span>
              </div>
              <div class="guide-entry-summary">${esc(entry.summary || '')}</div>
              <div class="guide-entry-grid">
                <div class="guide-entry-block">
                  <strong>What RTMify Checked</strong>
                  <div>${esc(entry.what_checked || '')}</div>
                </div>
                <div class="guide-entry-block">
                  <strong>Common Causes</strong>
                  <ul>${(entry.common_causes || []).map((item) => `<li>${esc(item)}</li>`).join('')}</ul>
                </div>
                <div class="guide-entry-block">
                  <strong>What To Inspect Next</strong>
                  <ul>${(entry.what_to_inspect || []).map((item) => `<li>${esc(item)}</li>`).join('')}</ul>
                </div>
                <div class="guide-entry-block">
                  <strong>Evidence Type</strong>
                  <div>${esc(entry.evidence_kind || '')}</div>
                </div>
              </div>
            </article>
          `).join('')}
        </div>
      </div>
    `).join('');

  consumePendingGuideAnchor();
}

export async function loadGuideErrors(force = false) {
  const errEl = document.getElementById('guide-errors-error');
  const indexEl = document.getElementById('guide-errors-index');
  const bodyEl = document.getElementById('guide-errors-body');
  if (!errEl || !indexEl || !bodyEl) return;

  errEl.style.display = 'none';
  if (guideErrorsCache && !force) {
    renderGuideErrors(guideErrorsCache);
    return;
  }

  try {
    const res = await fetch('/api/guide/errors', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    const nextByAnchor = new Map();
    const nextByKey = new Map();
    const chainCodeCounts = new Map();

    (data.groups || []).forEach((group) => {
      (group.entries || []).forEach((entry) => {
        if (entry.surface === 'chain_gap') {
          chainCodeCounts.set(entry.code, (chainCodeCounts.get(entry.code) || 0) + 1);
        }
      });
    });

    (data.groups || []).forEach((group) => {
      group.entries = (group.entries || []).sort((a, b) => {
        const codeDiff = Number(a.code || 0) - Number(b.code || 0);
        if (codeDiff !== 0) return codeDiff;
        return String(a.title || '').localeCompare(String(b.title || ''));
      });
      group.entries.forEach((entry) => {
        nextByAnchor.set(entry.anchor, entry);
        nextByKey.set(guideKeyForEntry(entry), entry);
        if (entry.surface === 'chain_gap' && (chainCodeCounts.get(entry.code) || 0) === 1) {
          nextByKey.set(`gap:${entry.code}`, entry);
        }
      });
    });

    setGuideLookupByAnchor(nextByAnchor);
    setGuideLookupByKey(nextByKey);
    setGuideErrorsCache(data);
    renderGuideErrors(data);
  } catch (e) {
    errEl.textContent = 'Failed to load guide entries: ' + e.message;
    errEl.style.display = 'block';
    indexEl.innerHTML = '<h3>Index</h3><div><em class="text-hint">Guide unavailable.</em></div>';
    bodyEl.innerHTML = `<div class="card"><div class="empty-state">Failed to load guide entries: ${esc(e.message)}</div></div>`;
  }
}

export async function openGuideForCode(codeLabelOrNumber, options = {}) {
  const value = String(codeLabelOrNumber || '').trim();
  const key = value.startsWith('E')
    ? `diag:${value}`
    : (options.variant ? `gap:${value}:${options.variant}` : `gap:${value}`);

  showTabHook('guide-errors');
  await loadGuideErrors();

  const entry = guideLookupByKey.get(key);
  if (!entry) return;
  setPendingGuideAnchor(entry.anchor);
  updateGuideHash(entry.anchor);
  consumePendingGuideAnchor();
}

export async function handleGuideHash() {
  const anchor = window.location.hash.startsWith('#guide-code-') ? window.location.hash.slice(1) : null;
  if (!anchor) return;
  setPendingGuideAnchor(anchor);
  showTabHook('guide-errors');
  await loadGuideErrors();
}
