export function createSyncSettingsController(config) {
  const getErrorEl = () => document.getElementById(config.errorId);
  const getStatusEl = () => document.getElementById(config.statusId);

  function hideError() {
    const errEl = getErrorEl();
    if (errEl) errEl.style.display = 'none';
  }

  function showError(prefix, error) {
    const errEl = getErrorEl();
    if (!errEl) return;
    errEl.textContent = prefix + error.message;
    errEl.style.display = 'block';
  }

  async function load(force = false) {
    const errEl = getErrorEl();
    const statusEl = getStatusEl();
    if (!errEl || !statusEl) return;
    if (!force) hideError();
    try {
      const res = await fetch(config.loadUrl, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      config.renderStatus(data);
      config.applyForm(data);
    } catch (error) {
      statusEl.innerHTML = config.unavailableHtml;
      showError(config.loadErrorPrefix, error);
    }
  }

  async function validate() {
    hideError();
    try {
      const draft = config.buildDraft();
      const res = await fetch(config.validateUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      config.renderStatus(config.buildValidationState(data, draft));
    } catch (error) {
      showError(config.validateErrorPrefix, error);
    }
  }

  async function save() {
    hideError();
    try {
      const draft = config.buildDraft();
      const res = await fetch(config.saveUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await load(true);
    } catch (error) {
      showError(config.saveErrorPrefix, error);
    }
  }

  async function remove() {
    if (config.deleteConfirm && !window.confirm(config.deleteConfirm)) return;
    hideError();
    try {
      const res = await fetch(config.deleteUrl, { method: 'DELETE' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await load(true);
    } catch (error) {
      showError(config.deleteErrorPrefix, error);
    }
  }

  return { load, validate, save, remove };
}
