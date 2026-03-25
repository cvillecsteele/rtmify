import { licenseStatusCache, setLicenseStatusCache } from '/modules/state.js';

const hooks = {
  loadStatus: null,
  showSuccess: null,
  enterWorkspace: null,
};

export function bindLicenseHooks(nextHooks = {}) {
  hooks.loadStatus = typeof nextHooks.loadStatus === 'function' ? nextHooks.loadStatus : null;
  hooks.showSuccess = typeof nextHooks.showSuccess === 'function' ? nextHooks.showSuccess : null;
  hooks.enterWorkspace = typeof nextHooks.enterWorkspace === 'function' ? nextHooks.enterWorkspace : null;
}

export function licenseStateMessage(status) {
  if (!status) return 'Select a signed license file to continue.';
  switch (status.state) {
    case 'not_licensed':
      return status.using_free_run
        ? 'A free run is available.'
        : 'Select a signed license file or place it at ~/.rtmify/license.json.';
    case 'expired':
      return 'This license has expired.';
    case 'invalid':
      return 'This license file is invalid.';
    case 'tampered':
      return 'This license file appears to have been modified or is for a different product.';
    case 'valid':
      return 'License is active.';
    default:
      return 'A signed license file is required.';
  }
}

function shortFingerprint(value) {
  if (!value) return '—';
  return String(value).slice(0, 12);
}

export function syncLicenseInfo(status) {
  const stateEl = document.getElementById('info-license-state');
  const idEl = document.getElementById('info-license-id');
  const issuedToEl = document.getElementById('info-license-issued-to');
  const orgEl = document.getElementById('info-license-org');
  const tierEl = document.getElementById('info-license-tier');
  const expiresEl = document.getElementById('info-license-expires');
  const pathEl = document.getElementById('info-license-path');
  const buildFpEl = document.getElementById('info-license-key-fingerprint');
  const fileFpEl = document.getElementById('info-license-file-fingerprint');
  const clearBtn = document.getElementById('info-license-clear');
  const gateClearBtn = document.getElementById('license-clear-btn');
  const gateFpEl = document.getElementById('license-gate-fingerprint');
  const gateFileFpEl = document.getElementById('license-gate-file-fingerprint');
  const gateFileFpRowEl = document.getElementById('license-gate-file-fingerprint-row');
  if (stateEl) stateEl.textContent = status?.state || 'unknown';
  if (idEl) idEl.textContent = status?.license_id || '—';
  if (issuedToEl) issuedToEl.textContent = status?.issued_to || '—';
  if (orgEl) orgEl.textContent = status?.org || '—';
  if (tierEl) tierEl.textContent = status?.tier || '—';
  if (expiresEl) expiresEl.textContent = status?.expires_at == null ? 'perpetual' : String(status.expires_at);
  if (pathEl) pathEl.textContent = status?.license_path || '—';
  if (buildFpEl) buildFpEl.textContent = shortFingerprint(status?.expected_key_fingerprint);
  if (fileFpEl) fileFpEl.textContent = shortFingerprint(status?.license_signing_key_fingerprint);
  if (gateFpEl) gateFpEl.textContent = shortFingerprint(status?.expected_key_fingerprint);
  if (gateFileFpEl) gateFileFpEl.textContent = shortFingerprint(status?.license_signing_key_fingerprint);
  if (gateFileFpRowEl) gateFileFpRowEl.style.display = status?.license_signing_key_fingerprint ? 'inline' : 'none';
  if (clearBtn) clearBtn.style.display = status?.license_id ? 'inline-block' : 'none';
  if (gateClearBtn) gateClearBtn.style.display = status?.license_id ? 'inline-block' : 'none';
}

export function showLicenseGate(status, errorMessage = '') {
  setLicenseStatusCache(status || licenseStatusCache);
  const gate = document.getElementById('license-gate');
  const stateEl = document.getElementById('license-gate-state');
  const errEl = document.getElementById('license-gate-error');
  if (stateEl) stateEl.textContent = licenseStateMessage(status);
  if (errEl) {
    const message = errorMessage || status?.message || '';
    errEl.textContent = message;
    errEl.style.display = message ? 'block' : 'none';
  }
  syncLicenseInfo(status);
  gate?.classList.add('visible');
  document.getElementById('license-import-btn')?.focus();
}

export function hideLicenseGate() {
  document.getElementById('license-gate')?.classList.remove('visible');
}

export async function loadLicenseStatus(force = false) {
  if (!force && licenseStatusCache) return licenseStatusCache;
  const res = await fetch('/api/license/status', { cache: 'no-store' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  setLicenseStatusCache(data.license || null);
  syncLicenseInfo(licenseStatusCache);
  return licenseStatusCache;
}

export function chooseLicenseFile() {
  document.getElementById('license-file-input')?.click();
}

export async function importLicenseFile(file) {
  const btn = document.getElementById('license-import-btn');
  if (!file) {
    showLicenseGate(licenseStatusCache, 'Please select a license.json file.');
    return;
  }
  if (btn) {
    btn.disabled = true;
    btn.textContent = 'Importing…';
  }
  try {
    const licenseJson = await file.text();
    const res = await fetch('/api/license/import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ license_json: licenseJson }),
    });
    const data = await res.json().catch(() => ({}));
    const status = data.license || null;
    setLicenseStatusCache(status);
    syncLicenseInfo(status);
    if (!res.ok || !status || !status.permits_use) {
      showLicenseGate(status, status?.message || `License import failed (HTTP ${res.status})`);
      return;
    }
    hideLicenseGate();
    await refreshLicenseStatus();
  } catch (error) {
    showLicenseGate(licenseStatusCache, error.message);
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = 'Select License File';
    }
    const input = document.getElementById('license-file-input');
    if (input) input.value = '';
  }
}

export async function clearInstalledLicense() {
  if (!window.confirm('Clear the installed license on this machine?')) return;
  try {
    const res = await fetch('/api/license/clear', { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    const status = data.license || null;
    setLicenseStatusCache(status);
    syncLicenseInfo(status);
    showLicenseGate(status, status?.message || '');
  } catch (error) {
    showLicenseGate(licenseStatusCache, error.message);
  }
}

export async function refreshLicenseStatus() {
  try {
    const status = await hooks.loadStatus?.(true);
    if (!status) return;
    if (status.workspace_ready && document.getElementById('lobby')?.classList.contains('visible')) {
      hooks.showSuccess?.(status);
    } else if (status.workspace_ready) {
      await hooks.enterWorkspace?.(status);
    } else {
      hideLicenseGate();
    }
  } catch (error) {
    showLicenseGate(licenseStatusCache, error.message);
  }
}
