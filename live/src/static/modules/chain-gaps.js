import { esc } from '/modules/helpers.js';
import { PROFILE_DESCRIPTIONS } from '/modules/state.js';

export async function loadProfileState() {
  const selectEl = document.getElementById('profile-select');
  if (!selectEl) return;
  try {
    const res = await fetch('/api/profile');
    if (!res.ok) return;
    const data = await res.json();
    const profile = data.profile || 'generic';
    selectEl.value = profile;
    const descEl = document.getElementById('profile-desc');
    if (descEl) descEl.textContent = PROFILE_DESCRIPTIONS[profile] || '';
    await refreshDashboardProvisionPreview(profile);
  } catch {}
}

export async function refreshDashboardProvisionPreview(profile) {
  const previewEl = document.getElementById('profile-preview');
  const btnEl = document.getElementById('profile-provision-btn');
  if (!previewEl || !btnEl) return;
  try {
    const res = await fetch('/api/provision-preview?profile=' + encodeURIComponent(profile));
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    if (!data.ready) {
      previewEl.style.display = 'none';
      btnEl.style.display = 'none';
      return;
    }
    previewEl.textContent = provisionPreviewText(data);
    previewEl.style.display = 'block';
    btnEl.style.display = (data.missing_count || 0) > 0 ? 'inline-block' : 'none';
  } catch {
    previewEl.style.display = 'none';
    btnEl.style.display = 'none';
  }
}

export async function changeProfile() {
  const selectEl = document.getElementById('profile-select');
  const errEl = document.getElementById('gaps-error');
  if (!selectEl || !errEl) return;
  const profile = selectEl.value;
  errEl.style.display = 'none';
  try {
    const res = await fetch('/api/profile', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ profile }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const descEl = document.getElementById('profile-desc');
    if (descEl) descEl.textContent = PROFILE_DESCRIPTIONS[profile] || '';
    await refreshDashboardProvisionPreview(profile);
    await loadChainGaps();
  } catch (error) {
    errEl.textContent = 'Failed to change profile: ' + error.message;
    errEl.style.display = 'block';
  }
}

export async function provisionMissingTabs() {
  const errEl = document.getElementById('gaps-error');
  if (!errEl) return;
  errEl.style.display = 'none';
  try {
    const res = await fetch('/api/provision', { method: 'POST' });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || `HTTP ${res.status}`);
    const profile = document.getElementById('profile-select')?.value || 'generic';
    await refreshDashboardProvisionPreview(profile);
    await loadChainGaps();
  } catch (error) {
    errEl.textContent = 'Provisioning failed: ' + error.message;
    errEl.style.display = 'block';
  }
}

export async function loadChainGaps() {
  const errEl = document.getElementById('gaps-error');
  const tbody = document.getElementById('chain-gaps-body');
  const badge = document.getElementById('chain-gap-count');
  if (!errEl || !tbody || !badge) return;

  errEl.style.display = 'none';
  tbody.innerHTML = '<tr class="loading-row"><td colspan="6" class="empty-state">Loading…</td></tr>';

  let gaps;
  try {
    const res = await fetch('/query/chain-gaps');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    gaps = await res.json();
  } catch (error) {
    errEl.textContent = 'Failed to load chain gaps: ' + error.message;
    errEl.style.display = 'block';
    tbody.innerHTML = '';
    badge.style.display = 'none';
    return;
  }

  badge.textContent = String((gaps || []).length);
  badge.style.display = 'inline-block';

  if (!gaps || gaps.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="empty-state"><strong>No gaps</strong><br>All traceability checks pass for this profile.</td></tr>';
    return;
  }

  tbody.innerHTML = gaps.map((gap) => {
    const severity = (gap.severity || 'info').toLowerCase();
    return `<tr>
      <td><a href="#" class="guide-link" data-action="open-guide" data-guide-code="${esc(String(gap.code || ''))}" data-guide-variant="${esc(gap.gap_type || '')}">${esc(String(gap.code || ''))}</a></td>
      <td><a href="#" class="guide-link" data-action="open-guide" data-guide-code="${esc(String(gap.code || ''))}" data-guide-variant="${esc(gap.gap_type || '')}">${esc(gap.title || '')}</a></td>
      <td>${esc(gap.gap_type || '')}</td>
      <td>${esc(gap.node_id || '')}</td>
      <td><span class="gap-badge-sev ${severity}">${esc(severity)}</span></td>
      <td>${esc(gap.message || '')}</td>
    </tr>`;
  }).join('');
}

export function provisionPreviewText(data) {
  const missing = data.missing || [];
  const existing = data.existing || [];
  if ((data.missing_count || 0) === 0) return 'All required tabs already exist for this profile.';
  if ((data.existing_count || 0) === 0) return `This will create ${missing.length} tabs in your sheet: ${missing.join(', ')}`;
  return `Found ${existing.length} existing tabs. Will create ${missing.length} additional tabs: ${missing.join(', ')}`;
}
