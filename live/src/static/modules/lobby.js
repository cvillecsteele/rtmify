import { currentStatus, lobbyState, LOBBY_PROFILES, PROFILE_ICONS, PENDING_WORKSPACE_TAB_KEY } from '/modules/state.js';
import { esc, formatDiagnosticsError } from '/modules/helpers.js';
import { connectionErrorMessage, loadStatus, syncPreviewUi, updateLobbyConnectionMessage } from '/modules/status.js';
import { hideLicenseGate } from '/modules/license.js';

const hooks = {
  loadWorkbooksState: null,
  loadData: null,
  handleGuideHash: null,
  showTab: null,
  showSettingsTab: null,
};

let lobbyCurrentScreen = 1;
let lobbyMode = 'setup';

export function bindLobbyHooks(nextHooks = {}) {
  hooks.loadWorkbooksState = typeof nextHooks.loadWorkbooksState === 'function' ? nextHooks.loadWorkbooksState : null;
  hooks.loadData = typeof nextHooks.loadData === 'function' ? nextHooks.loadData : null;
  hooks.handleGuideHash = typeof nextHooks.handleGuideHash === 'function' ? nextHooks.handleGuideHash : null;
  hooks.showTab = typeof nextHooks.showTab === 'function' ? nextHooks.showTab : null;
  hooks.showSettingsTab = typeof nextHooks.showSettingsTab === 'function' ? nextHooks.showSettingsTab : null;
}

export function renderProfileList() {
  const list = document.getElementById('profile-list');
  if (!list) return;
  list.innerHTML = LOBBY_PROFILES.map((profile) => `
    <div class="profile-row${profile.id === lobbyState.profileId ? ' selected' : ''}" data-action="select-profile" data-profile-id="${profile.id}" role="option" aria-selected="${profile.id === lobbyState.profileId}" tabindex="0">
      <span class="profile-row-icon">${PROFILE_ICONS[profile.id]}</span>
      <span class="profile-row-name">${profile.label}</span>
      <span class="profile-row-check"><svg width="10" height="8" viewBox="0 0 10 8" fill="none"><polyline points="1,4 4,7 9,1" stroke="white" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></span>
    </div>`).join('');
}

export function selectProfile(id) {
  lobbyState.profileId = id;
  document.querySelectorAll('.profile-row').forEach((row) => {
    const isSelected = row.dataset.profileId === id;
    row.classList.toggle('selected', isSelected);
    row.setAttribute('aria-selected', String(isSelected));
  });
}

export function clearProfileSelection() {
  lobbyState.profileId = null;
  document.querySelectorAll('.profile-row').forEach((row) => {
    row.classList.remove('selected');
    row.setAttribute('aria-selected', 'false');
  });
}

export function selectProvider(provider) {
  lobbyState.provider = provider;
  const ids = ['google', 'excel', 'local'];
  ids.forEach((kind) => document.getElementById(`tile-${kind}`)?.classList.toggle('selected', provider === kind));
  document.getElementById('s3-google')?.style.setProperty('display', provider === 'google' ? '' : 'none');
  document.getElementById('s3-excel')?.style.setProperty('display', provider === 'excel' ? '' : 'none');
  document.getElementById('s3-local')?.style.setProperty('display', provider === 'local' ? '' : 'none');
  document.getElementById('lobby-url-wrap')?.style.setProperty('display', provider === 'local' ? 'none' : '');
  const urlInput = document.getElementById('lobby-url');
  if (urlInput) {
    urlInput.placeholder = provider === 'excel'
      ? 'https://tenant.sharepoint.com/:x:/r/sites/…'
      : 'https://docs.google.com/spreadsheets/d/…';
  }
  const localName = document.getElementById('local-db-name');
  if (localName) localName.textContent = currentStatus?.active_workbook?.display_name || 'Current workspace database';
}

export function selectSourceOfTruth(source) {
  lobbyState.sourceOfTruth = source;
  document.getElementById('tile-document-source')?.classList.toggle('selected', source === 'document_first');
  document.getElementById('tile-workbook-source')?.classList.toggle('selected', source === 'workbook_first');
  document.getElementById('source-upload-panel')?.style.setProperty('display', source === 'document_first' ? '' : 'none');
  if (lobbyMode === 'add') {
    const headline = document.getElementById('source-screen-headline');
    if (headline) headline.textContent = 'Connect another workbook';
    document.getElementById('source-tiles')?.classList.add('provider-tiles-single');
    document.getElementById('tile-document-source')?.style.setProperty('display', 'none');
    document.getElementById('tile-workbook-source')?.style.setProperty('display', '');
  } else {
    const headline = document.getElementById('source-screen-headline');
    if (headline) headline.textContent = 'What is your source of truth?';
    document.getElementById('source-tiles')?.classList.remove('provider-tiles-single');
    document.getElementById('tile-document-source')?.style.setProperty('display', '');
    document.getElementById('tile-workbook-source')?.style.setProperty('display', '');
  }
}

export function visibleLobbyScreens() {
  if (lobbyMode === 'add') return [1, 3, 4];
  if (lobbyState.sourceOfTruth === 'document_first') return [1, 2, 4];
  return [1, 2, 3, 4];
}

export function renderLobbyDots() {
  const dots = document.getElementById('lobby-dots');
  if (!dots) return;
  const screens = visibleLobbyScreens();
  dots.innerHTML = screens.map((screen) => `<div class="lobby-dot${screen === lobbyCurrentScreen ? ' active' : ''}" data-dot="${screen}"></div>`).join('');
  dots.style.visibility = lobbyCurrentScreen === 5 ? 'hidden' : '';
  document.getElementById('lobby-screen-label-1').textContent = `Step 1 of ${screens.length}`;
  document.getElementById('lobby-screen-label-2').textContent = `Step ${Math.max(2, screens.indexOf(2) + 1 || 2)} of ${screens.length}`;
  document.getElementById('lobby-screen-label-3').textContent = `Step ${screens.indexOf(3) + 1} of ${screens.length}`;
  document.getElementById('lobby-screen-label-4').textContent = `Step ${screens.indexOf(4) + 1} of ${screens.length}`;
}

export function showScreen(n, direction = 'forward') {
  const prev = document.querySelector(`.lobby-screen[data-screen="${lobbyCurrentScreen}"]`);
  const next = document.querySelector(`.lobby-screen[data-screen="${n}"]`);
  if (!prev || !next) return;
  const exitClass = direction === 'forward' ? 'exit-fwd' : 'exit-back';
  const enterClass = direction === 'back' ? 'enter-back' : '';

  prev.classList.add(exitClass);
  prev.addEventListener('animationend', function handler() {
    prev.removeEventListener('animationend', handler);
    prev.classList.remove('active', exitClass);
    next.classList.add('active');
    if (enterClass) {
      next.classList.add(enterClass);
      next.addEventListener('animationend', function complete() {
        next.removeEventListener('animationend', complete);
        next.classList.remove(enterClass);
      });
    }
  });

  lobbyCurrentScreen = n;
  updateLobbyNav();
  if (n === 4) renderLicenseStep();
}

export function updateLobbyNav() {
  const backBtn = document.getElementById('lobby-back-btn');
  const onSuccess = lobbyCurrentScreen === 5;
  if (backBtn) backBtn.classList.toggle('visible', visibleLobbyScreens()[0] !== lobbyCurrentScreen && !onSuccess);
  renderLobbyDots();
}

async function persistLobbyProfileSelection() {
  const profile = LOBBY_PROFILES.find((item) => item.id === lobbyState.profileId);
  if (!profile) throw new Error('Select a profile to continue.');
  const res = await fetch('/api/profile', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ profile: profile.backendId }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.error || `HTTP ${res.status}`);
  }
}

export async function lobbyNext(fromScreen) {
  const errEl = document.getElementById('lobby-error');
  if (!errEl) return;
  errEl.style.display = 'none';
  if (fromScreen === 1) {
    if (!lobbyState.profileId) {
      errEl.textContent = 'Select a profile to continue.';
      errEl.style.display = 'block';
      return;
    }
    try {
      await persistLobbyProfileSelection();
    } catch (error) {
      errEl.textContent = 'Failed to save profile: ' + (error.message || error);
      errEl.style.display = 'block';
      return;
    }
    showScreen(lobbyMode === 'add' ? 3 : 2, 'forward');
  } else if (fromScreen === 2) {
    if (!lobbyState.sourceOfTruth) {
      errEl.textContent = 'Choose a source of truth to continue.';
      errEl.style.display = 'block';
      return;
    }
    if (lobbyState.sourceOfTruth === 'document_first') {
      errEl.textContent = 'Upload a requirements artifact to continue.';
      errEl.style.display = 'block';
      return;
    }
    showScreen(3, 'forward');
  } else if (fromScreen === 3) {
    await connectWorkbookSource();
  }
}

export function lobbyBack() {
  const screens = visibleLobbyScreens();
  const idx = screens.indexOf(lobbyCurrentScreen);
  if (idx > 0) showScreen(screens[idx - 1], 'back');
}

function lobbyStateFromInputs() {
  const workbookUrl = document.getElementById('lobby-url')?.value.trim() || '';
  lobbyState.workbookUrl = workbookUrl;
  if (lobbyState.provider === 'excel') {
    lobbyState.excelTenantId = document.getElementById('excel-tenant-id')?.value.trim() || '';
    lobbyState.excelClientId = document.getElementById('excel-client-id')?.value.trim() || '';
    lobbyState.excelClientSecret = document.getElementById('excel-client-secret')?.value.trim() || '';
  }
}

export function toggleSecretVisibility() {
  const input = document.getElementById('excel-client-secret');
  const eye = document.getElementById('secret-eye');
  if (!input || !eye) return;
  const isPassword = input.type === 'password';
  input.type = isPassword ? 'text' : 'password';
  eye.style.opacity = isPassword ? '0.4' : '1';
}

function renderLicenseStep() {
  const status = currentStatus || {};
  const locked = (status.license_required_features || []).join(', ') || 'Reports, MCP, repository scanning, code traceability, and background sync';
  document.getElementById('license-step-mode').textContent = status.license?.permits_use ? 'Licensed' : 'Preview';
  document.getElementById('license-step-status').textContent = status.license?.permits_use ? 'A valid license is installed.' : 'No active license is installed. You can continue in preview mode.';
  document.getElementById('license-step-locked').textContent = locked;
}

export function showSuccess(status = currentStatus || {}) {
  const profile = LOBBY_PROFILES.find((item) => item.id === lobbyState.profileId) || { label: '—', standards: '—' };
  const sourceLabel = status.source_of_truth === 'document_first'
    ? 'Requirements Artifact'
    : `${lobbyState.provider === 'google' ? 'Google Sheets' : (lobbyState.provider === 'local' ? 'Local DB' : 'Excel Online')} Workbook`;
  document.getElementById('success-title').textContent = status.hobbled_mode ? 'Preview workspace ready.' : 'Workspace ready.';
  document.getElementById('success-sub').textContent = `${profile.label} · ${sourceLabel}`;
  document.getElementById('success-detail').innerHTML = `
    <div class="success-detail-row"><span class="success-detail-key">Standard</span><span class="success-detail-val">${esc(profile.standards)}</span></div>
    <div class="success-detail-row"><span class="success-detail-key">Source</span><span class="success-detail-val">${esc(sourceLabel)}</span></div>
    <div class="success-detail-row"><span class="success-detail-key">Mode</span><span class="success-detail-val">${status.hobbled_mode ? 'Preview mode' : 'Licensed mode'}</span></div>`;
  showScreen(5, 'forward');
}

export async function enterWorkspace(status = null) {
  if (!status) status = currentStatus || await loadStatus(true);
  hideLicenseGate();
  document.getElementById('lobby')?.classList.remove('visible');
  releaseLobby();
  syncPreviewUi(status);
  await hooks.loadWorkbooksState?.();
  await hooks.loadData?.();
  const pendingTab = sessionStorage.getItem(PENDING_WORKSPACE_TAB_KEY);
  if (pendingTab && !window.location.hash.startsWith('#guide-code-')) {
    sessionStorage.removeItem(PENDING_WORKSPACE_TAB_KEY);
    hooks.showTab?.(pendingTab);
  }
  await hooks.handleGuideHash?.();
}

export async function openWorkspace() {
  const status = await loadStatus(true).catch(() => currentStatus || {});
  document.getElementById('lobby')?.classList.remove('visible');
  releaseLobby();
  syncPreviewUi(status);
  await hooks.loadWorkbooksState?.();
  await hooks.loadData?.();
  const pendingTab = sessionStorage.getItem(PENDING_WORKSPACE_TAB_KEY);
  if (pendingTab && !window.location.hash.startsWith('#guide-code-')) {
    sessionStorage.removeItem(PENDING_WORKSPACE_TAB_KEY);
    hooks.showTab?.(pendingTab);
  }
  await hooks.handleGuideHash?.();
}

export function openAddWorkbook() {
  hooks.showSettingsTab?.('workbooks');
  void showLobby('add');
}

export function clearCredential() {
  lobbyState.googleCredentialJson = '';
  lobbyState.googleCredentialEmail = '';
  document.getElementById('sa-upload-zone').style.display = '';
  document.getElementById('sa-loaded-chip').style.display = 'none';
  document.getElementById('lobby-share-hint').style.display = 'none';
}

export function clearSourceArtifact() {
  lobbyState.sourceArtifactFileName = '';
  lobbyState.sourceArtifactKind = '';
  document.getElementById('source-upload-chip').classList.remove('visible');
  document.getElementById('source-artifact-zone').style.display = '';
}

function trapLobby() {
  document.querySelector('main').inert = true;
  document.querySelector('header').inert = true;
  document.getElementById('preview-banner')?.classList.remove('visible');
  document.getElementById('attach-workbook-prompt')?.classList.remove('visible');
  document.querySelector('nav.nav-primary').inert = true;
  document.querySelectorAll('.nav-sub').forEach((nav) => { nav.inert = true; });
  document.querySelector('#lobby .profile-row')?.focus();
}

function releaseLobby() {
  document.querySelector('main').inert = false;
  document.querySelector('header').inert = false;
  document.querySelector('nav.nav-primary').inert = false;
  document.querySelectorAll('.nav-sub').forEach((nav) => { nav.inert = false; });
}

export async function showLobby(mode = 'setup') {
  lobbyMode = mode;
  document.getElementById('lobby')?.classList.add('visible');
  trapLobby();
  try {
    const status = await loadStatus(true);
    resetLobbyScreens(1);
    lobbyCurrentScreen = 1;
    if (mode === 'add') lobbyState.sourceOfTruth = 'workbook_first';
    if (lobbyState.sourceOfTruth) selectSourceOfTruth(lobbyState.sourceOfTruth);
    else selectSourceOfTruth(mode === 'add' ? 'workbook_first' : null);
    updateLobbyNav();
    return status;
  } catch {}
  resetLobbyScreens(1);
  lobbyCurrentScreen = 1;
  updateLobbyNav();
}

function resetLobbyScreens(activeScreen) {
  document.querySelectorAll('.lobby-screen').forEach((screen) => {
    screen.classList.remove('active', 'exit-fwd', 'exit-back', 'enter-back');
  });
  document.querySelector(`.lobby-screen[data-screen="${activeScreen}"]`)?.classList.add('active');
}

function buildDraftConnection() {
  lobbyStateFromInputs();
  const profile = LOBBY_PROFILES.find((item) => item.id === lobbyState.profileId);
  if (!profile) return null;
  if (lobbyState.provider === 'local') {
    return {
      display_name: currentStatus?.active_workbook?.display_name || 'Workspace',
      platform: 'local',
      profile: profile.backendId,
      workbook_url: '',
      credentials: {},
    };
  }
  const draft = {
    display_name: currentStatus?.active_workbook?.display_name || 'Workspace',
    platform: lobbyState.provider,
    profile: profile.backendId,
    workbook_url: lobbyState.workbookUrl,
    credentials: {},
  };
  if (lobbyState.provider === 'google') {
    if (!lobbyState.googleCredentialJson) return null;
    draft.credentials.service_account_json = lobbyState.googleCredentialJson;
  } else {
    let parsed;
    try {
      parsed = validateExcelCredentials(lobbyState.excelTenantId, lobbyState.excelClientId, lobbyState.excelClientSecret);
    } catch {
      return null;
    }
    draft.credentials.tenant_id = parsed.tenantId;
    draft.credentials.client_id = parsed.clientId;
    draft.credentials.client_secret = parsed.clientSecret;
  }
  if (!lobbyState.workbookUrl) return null;
  return draft;
}

export async function connectWorkbookSource() {
  const errEl = document.getElementById('lobby-error');
  const btn = document.getElementById('s3-continue-btn');
  const labelEl = btn?.querySelector('.authorize-btn-label');
  const draft = buildDraftConnection();
  if (!draft || !errEl || !btn) {
    if (errEl) {
      errEl.textContent = 'Complete all connection fields before continuing.';
      errEl.style.display = 'block';
    }
    return;
  }
  errEl.style.display = 'none';
  btn.disabled = true;
  if (labelEl) labelEl.textContent = 'Connecting…';
  try {
    if (draft.platform === 'local') {
      const prefsRes = await fetch('/api/workspace/preferences', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ workspace_ready: true, workspace_source_of_truth: 'workbook_first' }),
      });
      const prefsData = await prefsRes.json().catch(() => ({}));
      if (!prefsRes.ok || prefsData.ok === false) {
        throw new Error(prefsData.error || prefsData.detail || `HTTP ${prefsRes.status}`);
      }
      lobbyState.sourceOfTruth = 'workbook_first';
      await loadStatus(true);
      showScreen(4, 'forward');
      return;
    }
    const res = await fetch(lobbyMode === 'add' ? '/api/workbooks' : '/api/connection', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(draft),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) {
      throw new Error(formatDiagnosticsError(data) || connectionErrorMessage(data.error, draft.platform) || data.detail || data.error || `HTTP ${res.status}`);
    }
    lobbyState.sourceOfTruth = 'workbook_first';
    await loadStatus(true);
    showScreen(4, 'forward');
  } catch (error) {
    errEl.textContent = 'Failed to connect: ' + (error.message || error);
    errEl.style.display = 'block';
  } finally {
    btn.disabled = false;
    if (labelEl) labelEl.textContent = 'Review →';
  }
}

export async function continueInPreviewMode() {
  const errEl = document.getElementById('lobby-error');
  if (errEl) errEl.style.display = 'none';
  try {
    const status = await loadStatus(true);
    if (!status.workspace_ready) throw new Error('Finish seeding the workspace before continuing.');
    showSuccess(status);
  } catch (error) {
    if (errEl) {
      errEl.textContent = error.message || String(error);
      errEl.style.display = 'block';
    }
  }
}

function updateSourceArtifactChip(name, meta) {
  const chip = document.getElementById('source-upload-chip');
  document.getElementById('source-upload-name').textContent = name;
  document.getElementById('source-upload-meta').textContent = meta;
  chip.classList.add('visible');
  document.getElementById('source-artifact-zone').style.display = 'none';
}

export async function uploadOnboardingSourceArtifact(file) {
  if (!file) return;
  const errEl = document.getElementById('lobby-error');
  if (errEl) errEl.style.display = 'none';
  const form = new FormData();
  form.append('file', file);
  form.append('display_name', file.name);
  try {
    const res = await fetch('/api/onboarding/source-artifact', { method: 'POST', body: form });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
    lobbyState.sourceArtifactFileName = file.name;
    lobbyState.sourceArtifactKind = data.kind || '';
    lobbyState.sourceOfTruth = data.source_of_truth || 'document_first';
    sessionStorage.setItem(PENDING_WORKSPACE_TAB_KEY, 'design-artifacts');
    updateSourceArtifactChip(file.name, `Classified as ${data.kind || 'artifact'} and ingested into the preview workspace.`);
    await loadStatus(true);
    showScreen(4, 'forward');
  } catch (error) {
    if (errEl) {
      errEl.textContent = 'Failed to ingest artifact: ' + (error.message || error);
      errEl.style.display = 'block';
    }
  }
}

export function onSourceArtifactDragOver(event) {
  event.preventDefault();
  document.getElementById('source-artifact-zone').classList.add('drag-over');
}

export function onSourceArtifactDragLeave(event) {
  if (!event.currentTarget.contains(event.relatedTarget)) {
    document.getElementById('source-artifact-zone').classList.remove('drag-over');
  }
}

export async function onSourceArtifactDrop(event) {
  event.preventDefault();
  document.getElementById('source-artifact-zone').classList.remove('drag-over');
  const file = event.dataTransfer.files?.[0] || null;
  if (file) await uploadOnboardingSourceArtifact(file);
}

export function onSaDragOver(event) {
  event.preventDefault();
  document.getElementById('sa-upload-zone').classList.add('drag-over');
}

export function onSaDragLeave(event) {
  if (!event.currentTarget.contains(event.relatedTarget)) {
    document.getElementById('sa-upload-zone').classList.remove('drag-over');
  }
}

export async function onSaDrop(event) {
  event.preventDefault();
  document.getElementById('sa-upload-zone').classList.remove('drag-over');
  const file = event.dataTransfer.files[0];
  if (lobbyState.provider === 'google' && file) await uploadSaFile(file);
}

export async function uploadSaFile(file) {
  const errEl = document.getElementById('lobby-error');
  if (errEl) errEl.style.display = 'none';

  let text;
  try {
    text = await file.text();
  } catch {
    if (errEl) {
      errEl.textContent = 'Could not read that file.';
      errEl.style.display = 'block';
    }
    return;
  }

  try {
    const parsed = parseGoogleServiceAccountJson(text);
    lobbyState.googleCredentialEmail = parsed.client_email;
    lobbyState.googleCredentialJson = text;
  } catch (error) {
    if (errEl) {
      errEl.textContent = error.message || 'Invalid Google service-account JSON.';
      errEl.style.display = 'block';
    }
    return;
  }

  document.getElementById('sa-loaded-email').textContent = lobbyState.googleCredentialEmail;
  document.getElementById('sa-upload-zone').style.display = 'none';
  document.getElementById('sa-loaded-chip').style.display = '';
  document.getElementById('lobby-share-hint').style.display = 'block';
}

function parseGoogleServiceAccountJson(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error('Invalid JSON file.');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('That file is JSON, but it is not a Google service-account credential.');
  }
  if (parsed.type !== 'service_account') {
    throw new Error('That file is JSON, but it is not a Google service-account credential.');
  }
  if (typeof parsed.client_email !== 'string' || !parsed.client_email.trim()) {
    throw new Error('Google service-account JSON is missing client_email.');
  }
  if (typeof parsed.private_key !== 'string' || !parsed.private_key.trim()) {
    throw new Error('Google service-account JSON is missing private_key.');
  }
  return parsed;
}

function validateExcelCredentials(tenantId, clientId, clientSecret) {
  if (!tenantId || !clientId || !clientSecret) throw new Error('Enter all Azure credentials to continue.');
  if (!tenantId.trim() || !clientId.trim() || !clientSecret.trim()) throw new Error('Excel Online credentials cannot be blank.');
  return { tenantId: tenantId.trim(), clientId: clientId.trim(), clientSecret: clientSecret.trim() };
}

export async function dismissAttachWorkbookPrompt() {
  document.getElementById('attach-workbook-prompt')?.classList.remove('visible');
  try {
    await fetch('/api/workspace/preferences', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ attach_workbook_prompt_dismissed: true }),
    });
  } catch {}
}

export function copyEmail() {
  const value = document.getElementById('sa-loaded-email').textContent;
  if (!value) return;
  navigator.clipboard.writeText(value).catch(() => {});
}
