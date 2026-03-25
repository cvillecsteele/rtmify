import { currentStatus, licenseStatusCache, lobbyState, LOBBY_PROFILES, setCurrentStatus, setLicenseStatusCache } from '/modules/state.js';
import { formatUnixTimestamp } from '/modules/helpers.js';
import { renderTestResultsApiInfo } from '/modules/uploads.js';
import { updateWorkbookContext } from '/modules/workbooks.js';

const hooks = {
  syncLicenseInfo: null,
  selectProvider: null,
  selectProfile: null,
  clearProfileSelection: null,
  updateLobbyConnectionMessage: null,
  showGroup: null,
};

export function bindStatusUiHooks(nextHooks = {}) {
  hooks.syncLicenseInfo = typeof nextHooks.syncLicenseInfo === 'function' ? nextHooks.syncLicenseInfo : null;
  hooks.selectProvider = typeof nextHooks.selectProvider === 'function' ? nextHooks.selectProvider : null;
  hooks.selectProfile = typeof nextHooks.selectProfile === 'function' ? nextHooks.selectProfile : null;
  hooks.clearProfileSelection = typeof nextHooks.clearProfileSelection === 'function' ? nextHooks.clearProfileSelection : null;
  hooks.updateLobbyConnectionMessage = typeof nextHooks.updateLobbyConnectionMessage === 'function' ? nextHooks.updateLobbyConnectionMessage : null;
  hooks.showGroup = typeof nextHooks.showGroup === 'function' ? nextHooks.showGroup : null;
}

export function applyStatus(status) {
  setCurrentStatus(status || null);
  setLicenseStatusCache(status?.license || null);
  hooks.syncLicenseInfo?.(licenseStatusCache);
  syncPreviewUi(status || {});

  if (status?.platform) {
    lobbyState.provider = status.platform;
    hooks.selectProvider?.(status.platform);
  } else if (status?.source_of_truth === 'workbook_first') {
    lobbyState.provider = 'local';
    hooks.selectProvider?.('local');
  } else {
    hooks.selectProvider?.(lobbyState.provider || 'google');
  }

  if (status?.workbook_url) {
    lobbyState.workbookUrl = status.workbook_url;
    const input = document.getElementById('lobby-url');
    if (input) input.value = status.workbook_url;
  }

  if (status?.platform === 'google' && status?.credential_display) {
    lobbyState.googleCredentialEmail = status.credential_display;
    const emailEl = document.getElementById('sa-loaded-email');
    if (emailEl) emailEl.textContent = status.credential_display;
    const uploadZone = document.getElementById('sa-upload-zone');
    const loadedChip = document.getElementById('sa-loaded-chip');
    const shareHint = document.getElementById('lobby-share-hint');
    if (uploadZone) uploadZone.style.display = 'none';
    if (loadedChip) loadedChip.style.display = '';
    if (shareHint) shareHint.style.display = 'block';
  }

  if (status?.profile) {
    const backendToUi = { medical: 'medical', aerospace: 'aerospace', automotive: 'automotive', generic: null };
    const uiId = backendToUi[status.profile] ?? null;
    if (uiId) hooks.selectProfile?.(uiId);
    else hooks.clearProfileSelection?.();
  } else {
    hooks.clearProfileSelection?.();
  }

  if (status?.source_of_truth) {
    lobbyState.sourceOfTruth = status.source_of_truth;
  }
  hooks.updateLobbyConnectionMessage?.(status);
}

export async function loadStatus(force = false) {
  const res = await fetch('/api/status', { cache: force ? 'no-store' : 'default' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const status = await res.json();
  applyStatus(status);
  return status;
}

export function syncPreviewUi(status) {
  const preview = document.getElementById('preview-banner');
  const prompt = document.getElementById('attach-workbook-prompt');
  const locked = status.license_required_features || [];
  if (preview) {
    preview.classList.toggle('visible', Boolean(status.hobbled_mode));
    const sub = document.getElementById('preview-banner-sub');
    if (sub) {
      sub.textContent = status.hobbled_mode
        ? `Locked in preview: ${locked.join(', ') || 'Reports, MCP, repository scanning, code traceability, and background sync'}.`
        : 'Licensed features are active.';
    }
  }
  if (prompt) {
    const showPrompt = status.source_of_truth === 'document_first' &&
      !status.connection_configured &&
      !status.attach_workbook_prompt_dismissed &&
      !document.getElementById('lobby')?.classList.contains('visible');
    prompt.classList.toggle('visible', Boolean(showPrompt));
  }

  const restricted = Boolean(status.hobbled_mode);
  document.querySelectorAll('button[data-group="code"], button[data-group="reports"], .nav-sub [data-tab="mcp-ai"]').forEach((btn) => {
    btn.disabled = restricted;
    btn.title = restricted ? 'Requires a license' : '';
  });
  if (restricted && (
    document.getElementById('tab-code')?.classList.contains('active') ||
    document.getElementById('tab-reports')?.classList.contains('active') ||
    document.getElementById('tab-mcp-ai')?.classList.contains('active')
  )) {
    hooks.showGroup?.('data');
  }
}

export function loadMcpHelp() {
  const endpoint = window.location.origin + '/mcp';
  const endpointEl = document.getElementById('mcp-endpoint');
  const claudeEl = document.getElementById('mcp-claude-cmd');
  const codexEl = document.getElementById('mcp-codex-cmd');
  const geminiEl = document.getElementById('mcp-gemini-json');
  if (!endpointEl || !claudeEl || !codexEl || !geminiEl) return;

  endpointEl.textContent = endpoint;
  claudeEl.textContent = `claude mcp add --transport http rtmify-live ${endpoint}`;
  codexEl.textContent = `codex mcp add rtmify-live --url ${endpoint}`;
  geminiEl.textContent = `{
  "mcpServers": {
    "rtmify-live": {
      "httpUrl": "${endpoint}"
    }
  }
}`;
}

export async function loadInfo() {
  const errEl = document.getElementById('info-error');
  const licenseStateEl = document.getElementById('info-license-state');
  const trayEl = document.getElementById('info-tray-version');
  const liveEl = document.getElementById('info-live-version');
  const dbEl = document.getElementById('info-db-path');
  const logEl = document.getElementById('info-log-path');
  const testResultsEndpointEl = document.getElementById('test-results-endpoint');
  const bomEndpointEl = document.getElementById('bom-endpoint');
  const testResultsTokenEl = document.getElementById('test-results-token');
  const testResultsInboxEl = document.getElementById('test-results-inbox');
  if (!errEl || !trayEl || !liveEl || !dbEl || !logEl || !licenseStateEl) return;

  errEl.style.display = 'none';
  try {
    const res = await fetch('/api/info', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const info = await res.json();
    licenseStateEl.textContent = licenseStatusCache?.state || 'unknown';
    trayEl.textContent = info.tray_app_version || 'not available';
    liveEl.textContent = info.live_version || 'unknown';
    dbEl.textContent = info.db_path || 'unknown';
    logEl.textContent = info.log_path || 'unknown';
    renderTestResultsApiInfo(info, testResultsEndpointEl, bomEndpointEl, testResultsTokenEl, testResultsInboxEl);
    updateWorkbookContext(info.active_workbook || null);
  } catch (error) {
    errEl.textContent = 'Failed to load info: ' + error.message;
    errEl.style.display = 'block';
    licenseStateEl.textContent = '—';
    trayEl.textContent = '—';
    liveEl.textContent = '—';
    dbEl.textContent = '—';
    logEl.textContent = '—';
    if (testResultsEndpointEl) testResultsEndpointEl.textContent = '—';
    if (bomEndpointEl) bomEndpointEl.textContent = '—';
    if (testResultsTokenEl) testResultsTokenEl.textContent = '—';
    if (testResultsInboxEl) testResultsInboxEl.textContent = '—';
  }
}

export function connectionBlockMessage(status) {
  switch (status?.connection_block_reason) {
    case 'legacy_plaintext_credentials':
      return status?.platform === 'excel'
        ? 'Stored Excel Online credentials need to be re-entered before this workbook can sync.'
        : 'Stored Google Sheets credentials need to be re-uploaded before this workbook can sync.';
    case 'secure_storage_unsupported':
      return 'Secure credential storage is not available on this platform.';
    case 'secret_not_found':
    case 'secret_store_error':
    case 'credential_ref_missing':
      return status?.platform === 'excel'
        ? 'Stored Excel Online credentials are unavailable. Re-enter them to continue.'
        : 'Stored Google Sheets credentials are unavailable. Re-upload the service-account JSON to continue.';
    default:
      return '';
  }
}

export function connectionErrorMessage(code, platform) {
  switch (code) {
    case 'secure_storage_unavailable':
      return 'Secure credential storage is not available on this platform.';
    case 'failed to persist secure credentials':
      return 'Provider credentials could not be saved securely.';
    case 'failed to connect: InvalidCredential':
    case 'failed to validate connection: InvalidCredential':
    case 'InvalidCredential':
      return platform === 'excel'
        ? 'Those Excel Online credentials are invalid or incomplete.'
        : 'That file is not a valid Google service-account credential.';
    default:
      return '';
  }
}

export function showPreviewFeatureHelp() {
  const locked = (currentStatus?.license_required_features || []).join(', ') || 'Reports, MCP, repository scanning, code traceability, and background sync';
  window.alert(`Preview mode keeps the graph readable, but these features require a license: ${locked}.`);
}

export function updateLobbyConnectionMessage(status) {
  const errEl = document.getElementById('lobby-error');
  if (!errEl) return;
  const msg = connectionBlockMessage(status);
  if (!msg) return;
  errEl.textContent = msg;
  errEl.style.display = 'block';
}

export function activeProfileLabel() {
  const profile = LOBBY_PROFILES.find((item) => item.id === lobbyState.profileId);
  return profile || null;
}
