  const CHEVRON_SVG = `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 1.5l4 3.5-4 3.5"/></svg>`;
  let licenseStatusCache = null;
  let currentStatus = null;
  const PENDING_WORKSPACE_TAB_KEY = 'rtmify.pendingWorkspaceTab';

  // --- Tab switching ---

  // Tab → group mapping
  const TAB_GROUP = {
    'requirements': 'data', 'user-needs': 'data', 'design-artifacts': 'data', 'tests': 'data',
    'risks': 'data', 'rtm': 'data',
    'design-boms': 'bom', 'bom-components': 'bom', 'bom-coverage': 'bom', 'bom-usage': 'bom', 'bom-gaps': 'bom', 'bom-impact': 'bom',
    'software-boms': 'soup', 'soup-components': 'soup', 'soup-gaps': 'soup', 'soup-licenses': 'soup', 'soup-safety': 'soup',
    'chain-gaps': 'analysis', 'impact': 'analysis', 'review': 'analysis',
    'guide-errors': 'guide', 'mcp-ai': 'guide',
    'code': 'code', 'reports': 'reports',
    'workbooks': 'settings', 'design-bom-sync': 'settings', 'soup-sync': 'settings', 'info': 'settings',
  };

  // Default sub-tab per group
  const GROUP_DEFAULTS = {
    data: 'user-needs',
    bom: 'design-boms',
    soup: 'software-boms',
    analysis: 'chain-gaps',
    guide: 'guide-errors',
    code: 'code',
    reports: 'reports',
  };

  const workbookState = {
    activeWorkbookId: null,
    workbooks: [],
    removedWorkbooks: [],
    switching: false,
  };

  const bomState = {
    designBoms: [],
    selectedProduct: null,
    selectedBomName: null,
  };

  const soupState = {
    softwareBoms: [],
    selectedProduct: null,
    selectedBomName: null,
  };

  const artifactState = {
    artifacts: [],
    selectedArtifactId: null,
  };

  let guideErrorsCache = null;
  let guideLookupByAnchor = new Map();
  let guideLookupByKey = new Map();
  let pendingGuideAnchor = null;


  function showGroup(name) {
    document.querySelectorAll('.nav-primary button[data-group]').forEach(b =>
      b.classList.toggle('active', b.dataset.group === name));
    document.querySelectorAll('.nav-sub').forEach(sn =>
      sn.classList.toggle('active', sn.dataset.group === name));
    if (GROUP_DEFAULTS[name]) showTab(GROUP_DEFAULTS[name]);
  }

  function showTab(name) {
    document.querySelectorAll('section').forEach(s => s.classList.remove('active'));
    document.getElementById('tab-' + name).classList.add('active');

    const group = TAB_GROUP[name];
    document.querySelectorAll('.nav-primary button[data-group]').forEach(b =>
      b.classList.toggle('active', b.dataset.group === group));

    document.querySelectorAll('.nav-sub').forEach(sn => {
      const isActive = sn.dataset.group === group;
      sn.classList.toggle('active', isActive);
      if (isActive) {
        sn.querySelectorAll('button[data-tab]').forEach(b =>
          b.classList.toggle('active', b.dataset.tab === name));
      }
    });

    if (name === 'review') loadSuspects();
    if (name === 'design-artifacts') loadDesignArtifacts();
    if (name === 'design-boms') loadDesignBomWorkspace();
    if (name === 'bom-components') loadBomComponents();
    if (name === 'bom-coverage') loadBomCoverage();
    if (name === 'bom-gaps') loadBomGaps();
    if (name === 'bom-impact') loadBomImpactAnalysis();
    if (name === 'software-boms') loadSoupWorkspace();
    if (name === 'soup-components') loadSoupComponents();
    if (name === 'soup-gaps') loadSoupGaps();
    if (name === 'soup-licenses') loadSoupLicenses();
    if (name === 'soup-safety') loadSoupSafetyClasses();
    if (name === 'chain-gaps') { loadProfileState(); loadChainGaps(); }
    if (name === 'guide-errors') loadGuideErrors();
    if (name === 'code') loadCodeTraceability();
    if (name === 'mcp-ai') { loadMcpHelp(); loadInfo(); }
    if (name === 'info') loadInfo();
  }

  function showSettingsTab(name) {
    document.getElementById('settings-panel').style.display = 'none';
    document.querySelectorAll('section').forEach(s => s.classList.remove('active'));
    document.getElementById('tab-' + name).classList.add('active');
    document.querySelectorAll('.nav-primary button[data-group]').forEach(b =>
      b.classList.remove('active'));
    document.querySelectorAll('.nav-sub').forEach(sn => sn.classList.remove('active'));
    if (name === 'workbooks') loadWorkbooksView();
    if (name === 'design-bom-sync') loadDesignBomSyncSettings();
    if (name === 'soup-sync') loadSoupSyncSettings();
    if (name === 'info') loadInfo();
  }

  function toggleSettings(e) {
    e.stopPropagation();
    const panel = document.getElementById('settings-panel');
    panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
  }

  function closestActionElement(target, selector = '[data-action]') {
    return target instanceof Element ? target.closest(selector) : null;
  }

  function handleActionClick(e) {
    const actionEl = closestActionElement(e.target);
    if (!actionEl) return false;

    switch (actionEl.dataset.action) {
      case 'open-guide':
        e.preventDefault();
        void openGuideForCode(actionEl.dataset.guideCode, actionEl.dataset.guideVariant ? { variant: actionEl.dataset.guideVariant } : {});
        return true;
      case 'toggle-row':
        e.preventDefault();
        void toggleRow(actionEl.dataset.id || '', actionEl, Number(actionEl.dataset.colspan || 0));
        return true;
      case 'drawer-nav':
        e.preventDefault();
        void drawerNav(actionEl.dataset.id || '');
        return true;
      case 'clear-suspect':
        e.preventDefault();
        void clearSuspect(actionEl.dataset.id || '');
        return true;
      case 'toggle-tree-section':
        e.preventDefault();
        toggleTreeSection(actionEl);
        return true;
      case 'toggle-tree-node':
        e.preventDefault();
        void toggleTreeNode(actionEl, actionEl.dataset.id || '');
        return true;
      case 'select-profile':
        e.preventDefault();
        selectProfile(actionEl.dataset.profileId || '');
        return true;
      case 'delete-repo':
        e.preventDefault();
        void deleteRepo(Number(actionEl.dataset.slot || 0));
        return true;
      case 'switch-workbook':
        e.preventDefault();
        void switchWorkbook(actionEl.dataset.id || '');
        return true;
      case 'select-design-bom':
        e.preventDefault();
        void selectDesignBom(actionEl.dataset.product || '', actionEl.dataset.bomName || '');
        return true;
      case 'select-software-bom':
        e.preventDefault();
        void selectSoftwareBom(actionEl.dataset.product || '', actionEl.dataset.bomName || '');
        return true;
      case 'select-design-artifact':
        e.preventDefault();
        void selectDesignArtifact(actionEl.dataset.artifactId || '');
        return true;
      case 'reingest-design-artifact':
        e.preventDefault();
        void reingestDesignArtifact(actionEl.dataset.artifactId || '');
        return true;
      case 'inspect-bom-component':
        e.preventDefault();
        void inspectBomComponent(
          actionEl.dataset.itemId || '',
          actionEl.dataset.part || '',
          actionEl.dataset.product || '',
          actionEl.dataset.bomName || '',
        );
        return true;
      case 'rename-workbook':
        e.preventDefault();
        void renameWorkbook(actionEl.dataset.id || '');
        return true;
      case 'remove-workbook':
        e.preventDefault();
        void removeWorkbook(actionEl.dataset.id || '');
        return true;
      case 'purge-workbook':
        e.preventDefault();
        void purgeWorkbook(actionEl.dataset.id || '', actionEl.dataset.name || '');
        return true;
      case 'expand-file': {
        e.preventDefault();
        const row = actionEl.closest('tr');
        if (row) void expandFile(row, row.dataset.filePath || actionEl.dataset.filePath || '');
        return true;
      }
      default:
        return false;
    }
  }

  document.addEventListener('click', (e) => {
    const handled = handleActionClick(e);
    const p = document.getElementById('settings-panel');
    if (p) p.style.display = 'none';
    if (handled) return;
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && document.getElementById('node-drawer').classList.contains('open')) {
      closeDrawer();
    }

    const profileRow = closestActionElement(e.target, '[data-action="select-profile"]');
    if (profileRow && (e.key === 'Enter' || e.key === ' ')) {
      e.preventDefault();
      selectProfile(profileRow.dataset.profileId || '');
    }
  });

  function guideKeyForEntry(entry) {
    if (entry.surface === 'runtime_diagnostic') return `diag:${entry.code_label}`;
    return entry.variant ? `gap:${entry.code}:${entry.variant}` : `gap:${entry.code}`;
  }

  function updateGuideHash(anchor) {
    if (window.location.hash === `#${anchor}`) return;
    history.replaceState(null, '', `#${anchor}`);
  }

  function activateGuideEntry(anchor) {
    document.querySelectorAll('.guide-entry.active-guide').forEach(el => el.classList.remove('active-guide'));
    const el = document.getElementById(anchor);
    if (!el) return;
    el.classList.add('active-guide');
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function consumePendingGuideAnchor() {
    if (!pendingGuideAnchor) return;
    const anchor = pendingGuideAnchor;
    pendingGuideAnchor = null;
    requestAnimationFrame(() => activateGuideEntry(anchor));
  }

  function renderGuideErrors(data) {
    const indexEl = document.getElementById('guide-errors-index');
    const bodyEl = document.getElementById('guide-errors-body');
    if (!indexEl || !bodyEl) return;

    const groups = data.groups || [];
    indexEl.innerHTML = `<h3>Index</h3>${groups.map(group => `
        <div class="guide-index-group">
        <div class="guide-index-group-title">${esc(group.title || '')}</div>
        ${(group.entries || []).map(entry => `
          <a href="#${esc(entry.anchor || '')}" data-action="open-guide" data-guide-code="${esc(entry.code_label || entry.code || '')}" data-guide-variant="${esc(entry.variant || '')}">
            ${esc(entry.code_label || '')} ${esc(entry.title || '')}
          </a>
        `).join('')}
      </div>
    `).join('')}`;

    bodyEl.innerHTML = groups.map(group => `
      <div class="card guide-group-card">
        <h3>${esc(group.title || '')}</h3>
        <div class="guide-entries">
          ${(group.entries || []).map(entry => `
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
                  <ul>${(entry.common_causes || []).map(item => `<li>${esc(item)}</li>`).join('')}</ul>
                </div>
                <div class="guide-entry-block">
                  <strong>What To Inspect Next</strong>
                  <ul>${(entry.what_to_inspect || []).map(item => `<li>${esc(item)}</li>`).join('')}</ul>
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

  async function loadGuideErrors(force = false) {
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

      guideLookupByAnchor = new Map();
      guideLookupByKey = new Map();
      const chainCodeCounts = new Map();

      (data.groups || []).forEach(group => {
        (group.entries || []).forEach(entry => {
          if (entry.surface === 'chain_gap') {
            chainCodeCounts.set(entry.code, (chainCodeCounts.get(entry.code) || 0) + 1);
          }
        });
      });

      (data.groups || []).forEach(group => {
        group.entries = (group.entries || []).sort((a, b) => {
          const codeDiff = Number(a.code || 0) - Number(b.code || 0);
          if (codeDiff !== 0) return codeDiff;
          return String(a.title || '').localeCompare(String(b.title || ''));
        });
        group.entries.forEach(entry => {
          guideLookupByAnchor.set(entry.anchor, entry);
          guideLookupByKey.set(guideKeyForEntry(entry), entry);
          if (entry.surface === 'chain_gap' && (chainCodeCounts.get(entry.code) || 0) === 1) {
            guideLookupByKey.set(`gap:${entry.code}`, entry);
          }
        });
      });

      guideErrorsCache = data;
      renderGuideErrors(data);
    } catch (e) {
      errEl.textContent = 'Failed to load guide entries: ' + e.message;
      errEl.style.display = 'block';
      indexEl.innerHTML = '<h3>Index</h3><div><em class="text-hint">Guide unavailable.</em></div>';
      bodyEl.innerHTML = `<div class="card"><div class="empty-state">Failed to load guide entries: ${esc(e.message)}</div></div>`;
    }
  }

  async function openGuideForCode(codeLabelOrNumber, options = {}) {
    const value = String(codeLabelOrNumber || '').trim();
    const key = value.startsWith('E')
      ? `diag:${value}`
      : (options.variant ? `gap:${value}:${options.variant}` : `gap:${value}`);

    showTab('guide-errors');
    await loadGuideErrors();

    const entry = guideLookupByKey.get(key);
    if (!entry) return;
    pendingGuideAnchor = entry.anchor;
    updateGuideHash(entry.anchor);
    consumePendingGuideAnchor();
  }

  async function handleGuideHash() {
    const anchor = window.location.hash.startsWith('#guide-code-') ? window.location.hash.slice(1) : null;
    if (!anchor) return;
    pendingGuideAnchor = anchor;
    showTab('guide-errors');
    await loadGuideErrors();
  }

  // --- Data loading ---

  async function loadData() {
    _closeAllExpanded();
    await Promise.all([renderRequirements(), renderUserNeeds(), renderTests(), renderRTM(), renderRisks(), refreshSuspectBadge()]);
    await loadProfileState();
    await loadWorkbooksState();
    await loadDesignArtifacts();
    await loadDesignBomWorkspace();
    loadMcpHelp();
    loadInfo();
  }

  function loadMcpHelp() {
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

  async function loadInfo() {
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
      const licenseStatus = await loadLicenseStatus(true);
      const res = await fetch('/api/info', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const info = await res.json();
      licenseStateEl.textContent = licenseStatus?.state || 'unknown';
      trayEl.textContent = info.tray_app_version || 'not available';
      liveEl.textContent = info.live_version || 'unknown';
      dbEl.textContent = info.db_path || 'unknown';
      logEl.textContent = info.log_path || 'unknown';
      renderTestResultsApiInfo(info, testResultsEndpointEl, bomEndpointEl, testResultsTokenEl, testResultsInboxEl);
      updateWorkbookContext(info.active_workbook || null);
    } catch (e) {
      errEl.textContent = 'Failed to load info: ' + e.message;
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

  async function loadWorkbooksState() {
    try {
      const res = await fetch('/api/workbooks', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      workbookState.activeWorkbookId = data.active_workbook_id || null;
      workbookState.workbooks = Array.isArray(data.workbooks) ? data.workbooks : [];
      workbookState.removedWorkbooks = Array.isArray(data.removed_workbooks) ? data.removed_workbooks : [];
      renderWorkbookContext();
      renderWorkbooksTable();
    } catch (_) {
      workbookState.activeWorkbookId = null;
      workbookState.workbooks = [];
      workbookState.removedWorkbooks = [];
      renderWorkbookContext();
      renderWorkbooksTable();
    }
  }

  function updateWorkbookContext(activeWorkbook) {
    if (!activeWorkbook) return;
    workbookState.activeWorkbookId = activeWorkbook.id || workbookState.activeWorkbookId;
    renderWorkbookContext(activeWorkbook);
  }

  function renderWorkbookContext(activeWorkbookOverride = null) {
    const selectEl = document.getElementById('workbook-switcher');
    const metaEl = document.getElementById('header-workbook-meta');
    if (!selectEl || !metaEl) return;
    const workbooks = workbookState.workbooks || [];
    const active = activeWorkbookOverride || workbooks.find(w => w.id === workbookState.activeWorkbookId) || null;
    selectEl.disabled = workbookState.switching;
    if (!workbooks.length) {
      selectEl.innerHTML = '<option value="">No workbooks</option>';
      selectEl.value = '';
      metaEl.textContent = 'Connect a workbook to begin.';
      return;
    }
    selectEl.innerHTML = workbooks.map(w => `<option value="${esc(w.id || '')}">${esc(w.display_name || w.workbook_label || w.id || '')}</option>`).join('');
    selectEl.value = workbookState.activeWorkbookId || '';
    const provider = active?.provider || 'unconfigured';
    const profile = active?.profile || 'unknown';
    const sync = active?.sync_in_progress ? 'syncing' : (active?.last_sync_at ? `last sync ${formatUnixTimestamp(active.last_sync_at)}` : 'never synced');
    metaEl.textContent = `${profile} · ${provider} · ${sync}`;
  }

  function renderWorkbooksTable() {
    const bodyEl = document.getElementById('workbooks-body');
    const removedEl = document.getElementById('removed-workbooks-body');
    if (bodyEl) {
      if (!workbookState.workbooks.length) {
        bodyEl.innerHTML = '<tr><td colspan="6" class="empty-state"><strong>No workbooks configured</strong><br>Use Add Workbook to connect one.</td></tr>';
      } else {
        bodyEl.innerHTML = workbookState.workbooks.map(w => {
          const sync = w.last_sync_at ? formatUnixTimestamp(w.last_sync_at) : 'Never';
          const status = w.sync_in_progress ? 'Syncing…' : (w.has_error ? `Error: ${esc(w.last_error || 'sync failed')}` : 'Ready');
          return `<tr>
            <td><strong>${esc(w.display_name || '')}</strong>${w.is_active ? ' <span class="badge">Active</span>' : ''}</td>
            <td>${esc(w.profile || '')}</td>
            <td>${esc(w.provider || '—')}</td>
            <td>${esc(sync)}</td>
            <td>${status}</td>
            <td>
              ${w.is_active ? '' : `<button class="btn" data-action="switch-workbook" data-id="${esc(w.id || '')}">Activate</button>`}
              <button class="btn" data-action="rename-workbook" data-id="${esc(w.id || '')}">Rename</button>
              <button class="btn-danger" data-action="remove-workbook" data-id="${esc(w.id || '')}">Remove</button>
            </td>
          </tr>`;
        }).join('');
      }
    }
    if (removedEl) {
      if (!workbookState.removedWorkbooks.length) {
        removedEl.innerHTML = '<tr><td colspan="4" class="empty-state">No removed workbooks.</td></tr>';
      } else {
        removedEl.innerHTML = workbookState.removedWorkbooks.map(w => `<tr>
          <td><strong>${esc(w.display_name || '')}</strong></td>
          <td>${esc(w.profile || '')}</td>
          <td>${w.removed_at ? esc(formatUnixTimestamp(w.removed_at)) : '—'}</td>
          <td><button class="btn-danger" data-action="purge-workbook" data-id="${esc(w.id || '')}" data-name="${esc(w.display_name || '')}">Purge</button></td>
        </tr>`).join('');
      }
    }
  }

  async function loadWorkbooksView() {
    const errEl = document.getElementById('workbooks-error');
    if (errEl) errEl.style.display = 'none';
    try {
      await loadWorkbooksState();
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to load workbooks: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function switchWorkbook(id) {
    if (!id || workbookState.switching || id === workbookState.activeWorkbookId) return;
    workbookState.switching = true;
    renderWorkbookContext();
    try {
      const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}/activate`, { method: 'POST' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      await loadWorkbooksState();
      await loadData();
    } catch (e) {
      alert('Failed to switch workbook: ' + e.message);
    } finally {
      workbookState.switching = false;
      renderWorkbookContext();
    }
  }

  async function switchWorkbookFromHeader() {
    const selectEl = document.getElementById('workbook-switcher');
    if (!selectEl) return;
    await switchWorkbook(selectEl.value);
  }

  async function renameWorkbook(id) {
    const workbook = workbookState.workbooks.find(w => w.id === id);
    if (!workbook) return;
    const nextName = window.prompt('New workbook display name:', workbook.display_name || '');
    if (!nextName || nextName.trim() === '' || nextName.trim() === workbook.display_name) return;
    const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ display_name: nextName.trim() }),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || `HTTP ${res.status}`);
    }
    await loadWorkbooksState();
    loadInfo();
  }

  async function removeWorkbook(id) {
    const workbook = workbookState.workbooks.find(w => w.id === id);
    if (!workbook) return;
    if (!window.confirm(`Remove workbook "${workbook.display_name}"? This hides it but does not delete its files.`)) return;
    const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}/remove`, { method: 'POST' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    await loadWorkbooksState();
    await loadData();
  }

  async function purgeWorkbook(id, displayName) {
    const confirmation = window.prompt(`Type the workbook name to purge it permanently:\n${displayName}`);
    if (!confirmation) return;
    const res = await fetch(`/api/workbooks/${encodeURIComponent(id)}`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ confirm_display_name: confirmation }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    await loadWorkbooksState();
  }

  async function loadDesignBomWorkspace(force = false) {
    const errEl = document.getElementById('design-boms-error');
    const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
    if (errEl) errEl.style.display = 'none';
    try {
      const params = new URLSearchParams();
      if (includeObsolete) params.set('include_obsolete', 'true');
      const res = await fetch(`/api/v1/bom/design?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      bomState.designBoms = Array.isArray(data.design_boms) ? data.design_boms : [];
      renderDesignBomList();

      const stillSelected = bomState.designBoms.some(b =>
        b.full_product_identifier === bomState.selectedProduct && b.bom_name === bomState.selectedBomName);
      if (!stillSelected || force) {
        if (bomState.designBoms.length) {
          bomState.selectedProduct = bomState.designBoms[0].full_product_identifier || null;
          bomState.selectedBomName = bomState.designBoms[0].bom_name || null;
        } else {
          bomState.selectedProduct = null;
          bomState.selectedBomName = null;
        }
      }
      renderDesignBomList();
      if (bomState.selectedProduct && bomState.selectedBomName) {
        await loadSelectedDesignBomDetail();
      } else {
        const detailEl = document.getElementById('design-bom-detail');
        if (detailEl) detailEl.innerHTML = '<div class="empty-state">No Design BOMs ingested yet.</div>';
      }
    } catch (e) {
      bomState.designBoms = [];
      renderDesignBomList();
      const detailEl = document.getElementById('design-bom-detail');
      if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load Design BOMs: ${esc(e.message)}</div>`;
      if (errEl) {
        errEl.textContent = 'Failed to load Design BOMs: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function renderDesignBomList() {
    const bodyEl = document.getElementById('design-bom-list-body');
    if (!bodyEl) return;
    if (!bomState.designBoms.length) {
      bodyEl.innerHTML = '<tr><td colspan="9" class="empty-state">No Design BOMs available for the active workbook.</td></tr>';
      return;
    }
    bodyEl.innerHTML = bomState.designBoms.map(b => {
      const selected = b.full_product_identifier === bomState.selectedProduct && b.bom_name === bomState.selectedBomName;
      return `<tr${selected ? ' class="warning"' : ''}>
        <td><span class="req-id">${esc(b.full_product_identifier || '—')}</span></td>
        <td>${esc(b.product_status || 'Active')}</td>
        <td>${esc(b.bom_name || '—')}</td>
        <td>${esc(b.bom_type || '—')}</td>
        <td>${esc(b.source_format || '—')}</td>
        <td>${esc(String(b.item_count || 0))}</td>
        <td>${esc(String(b.warning_count || 0))}</td>
        <td>${esc(formatUnixTimestamp(b.ingested_at))}</td>
        <td><button class="btn" data-action="select-design-bom" data-product="${esc(b.full_product_identifier || '')}" data-bom-name="${esc(b.bom_name || '')}">${selected ? 'Selected' : 'Inspect'}</button></td>
      </tr>`;
    }).join('');
  }

  async function selectDesignBom(fullProductIdentifier, bomName) {
    bomState.selectedProduct = fullProductIdentifier || null;
    bomState.selectedBomName = bomName || null;
    renderDesignBomList();
    syncBomFiltersFromSelection();
    await loadSelectedDesignBomDetail();
  }

  function syncBomFiltersFromSelection() {
    const product = bomState.selectedProduct || '';
    const name = bomState.selectedBomName || '';
    const gapsProduct = document.getElementById('bom-gaps-product');
    const gapsName = document.getElementById('bom-gaps-name');
    const impactProduct = document.getElementById('bom-impact-product');
    const impactName = document.getElementById('bom-impact-name');
    const componentsProduct = document.getElementById('bom-components-product');
    const componentsName = document.getElementById('bom-components-name');
    const coverageProduct = document.getElementById('bom-coverage-product');
    const coverageName = document.getElementById('bom-coverage-name');
    const reportProduct = document.getElementById('report-design-bom-product');
    const reportName = document.getElementById('report-design-bom-name');
    if (gapsProduct && !gapsProduct.value) gapsProduct.value = product;
    if (gapsName && !gapsName.value) gapsName.value = name;
    if (impactProduct && !impactProduct.value) impactProduct.value = product;
    if (impactName && !impactName.value) impactName.value = name;
    if (componentsProduct && !componentsProduct.value) componentsProduct.value = product;
    if (componentsName && !componentsName.value) componentsName.value = name;
    if (coverageProduct && !coverageProduct.value) coverageProduct.value = product;
    if (coverageName && !coverageName.value) coverageName.value = name;
    if (reportProduct && !reportProduct.value) reportProduct.value = product;
    if (reportName && !reportName.value) reportName.value = name;
  }

  async function loadSelectedDesignBomDetail() {
    const detailEl = document.getElementById('design-bom-detail');
    const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
    if (!detailEl) return;
    if (!bomState.selectedProduct || !bomState.selectedBomName) {
      detailEl.innerHTML = '<div class="empty-state">Select a Design BOM to inspect it.</div>';
      return;
    }
    detailEl.innerHTML = '<div class="empty-state">Loading Design BOM detail…</div>';
    try {
      const product = encodeURIComponent(bomState.selectedProduct);
      const bomName = encodeURIComponent(bomState.selectedBomName);
      const query = includeObsolete ? `full_product_identifier=${product}&include_obsolete=true` : `full_product_identifier=${product}`;
      const [treeRes, itemsRes] = await Promise.all([
        fetch(`/api/v1/bom/design/${bomName}?${query}`, { cache: 'no-store' }),
        fetch(`/api/v1/bom/design/${bomName}/items?${query}`, { cache: 'no-store' }),
      ]);
      if (!treeRes.ok) throw new Error(`tree HTTP ${treeRes.status}`);
      if (!itemsRes.ok) throw new Error(`items HTTP ${itemsRes.status}`);
      const treeData = await treeRes.json();
      const itemsData = await itemsRes.json();
      detailEl.innerHTML = renderDesignBomDetail(treeData, itemsData);
      syncBomFiltersFromSelection();
    } catch (e) {
      detailEl.innerHTML = `<div class="empty-state">Failed to load Design BOM detail: ${esc(e.message)}</div>`;
    }
  }

  function renderDesignBomDetail(treeData, itemsData) {
    const designBoms = Array.isArray(treeData.design_boms) ? treeData.design_boms : [];
    const items = Array.isArray(itemsData.items) ? itemsData.items : [];
    const totalWarnings = items.reduce((sum, item) =>
      sum + ((item.unresolved_requirement_ids || []).length + (item.unresolved_test_ids || []).length), 0);

    return `
      <div class="toolbar card-toolbar">
        <span class="card-title">${esc(treeData.full_product_identifier || '')} · ${esc(treeData.bom_name || '')}</span>
      </div>
      <div class="bom-metrics">
        <div class="bom-metric">
          <div class="bom-metric-label">BOM Variants</div>
          <div class="bom-metric-value">${esc(String(designBoms.length))}</div>
        </div>
        <div class="bom-metric">
          <div class="bom-metric-label">Items</div>
          <div class="bom-metric-value">${esc(String(items.length))}</div>
        </div>
        <div class="bom-metric">
          <div class="bom-metric-label">Unresolved Trace Refs</div>
          <div class="bom-metric-value">${esc(String(totalWarnings))}</div>
        </div>
      </div>
      <div class="bom-detail-grid">
        <div>
          <h3 class="mb-10">Hierarchy</h3>
          ${designBoms.length ? designBoms.map(b => `
            <div class="card card--mb card--padded">
              <div class="bom-tree-head">
                <span class="req-id">${esc(b.bom_type || '')}</span>
                <span class="bom-chip">${esc(b.source_format || '')}</span>
              </div>
              ${renderBomTreeRoots(b.tree?.roots || [])}
            </div>
          `).join('') : '<div class="empty-state">No Design BOM tree available.</div>'}
        </div>
        <div>
          <h3 class="mb-10">Flattened Item Traceability</h3>
          ${items.length ? `<div class="table-scroll"><table>
            <thead>
              <tr>
                <th>Part</th>
                <th>Rev</th>
                <th>Declared Trace</th>
                <th>Resolved Links</th>
                <th>Unresolved</th>
              </tr>
            </thead>
            <tbody>
              ${items.map(renderDesignBomItemRow).join('')}
            </tbody>
          </table></div>` : '<div class="empty-state">No flattened BOM items available.</div>'}
        </div>
      </div>
    `;
  }

  function renderBomTreeRoots(roots) {
    if (!roots.length) return '<div class="empty-state">No root items.</div>';
    return `<div class="bom-tree">${roots.map(node => renderBomTreeNode(node)).join('')}</div>`;
  }

  function renderBomTreeNode(node) {
    if (!node) return '';
    const props = propsObj(node.properties);
    const edgeProps = propsObj(node.edge_properties);
    const trace = []
      .concat(Array.isArray(props.requirement_ids) ? props.requirement_ids : [])
      .concat(Array.isArray(props.test_ids) ? props.test_ids : []);
    return `
      <div class="bom-tree-node">
        <div class="bom-tree-head">
          <span class="req-id">${esc(props.part || node.id || '')}</span>
          <span class="bom-chip">${esc(props.revision || '-')}</span>
          ${edgeProps.quantity ? `<span class="bom-chip">qty ${esc(edgeProps.quantity)}</span>` : ''}
          ${edgeProps.ref_designator ? `<span class="bom-chip">${esc(edgeProps.ref_designator)}</span>` : ''}
          ${props.category ? `<span class="bom-chip">${esc(props.category)}</span>` : ''}
        </div>
        ${props.description ? `<div class="text-sm-subtle">${esc(props.description)}</div>` : ''}
        ${trace.length ? `<div class="mt-8">${trace.map(value => `<span class="bom-chip">${esc(value)}</span>`).join('')}</div>` : ''}
        ${Array.isArray(node.children) && node.children.length ? `<div class="bom-tree-children">${node.children.map(child => renderBomTreeNode(child)).join('')}</div>` : ''}
      </div>
    `;
  }

  function renderDesignBomItemRow(item) {
    const node = item.node || {};
    const props = propsObj(node.properties);
    const declared = []
      .concat(Array.isArray(props.requirement_ids) ? props.requirement_ids : [])
      .concat(Array.isArray(props.test_ids) ? props.test_ids : []);
    const linked = []
      .concat((item.linked_requirements || []).map(n => n.id))
      .concat((item.linked_tests || []).map(n => n.id));
    const unresolved = []
      .concat(item.unresolved_requirement_ids || [])
      .concat(item.unresolved_test_ids || []);
    return `<tr>
      <td><span class="req-id">${esc(props.part || node.id || '—')}</span></td>
      <td>${esc(props.revision || '—')}</td>
      <td>${declared.length ? declared.map(value => `<span class="bom-chip">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
      <td>${linked.length ? linked.map(value => `<span class="bom-chip">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
      <td>${unresolved.length ? unresolved.map(value => `<span class="bom-chip warn">${esc(value)}</span>`).join('') : '<span class="text-placeholder">—</span>'}</td>
    </tr>`;
  }

  async function loadBomComponents() {
    const errEl = document.getElementById('bom-components-error');
    const resultEl = document.getElementById('bom-components-result');
    const productEl = document.getElementById('bom-components-product');
    const nameEl = document.getElementById('bom-components-name');
    const searchEl = document.getElementById('bom-components-search');
    const includeObsolete = !!document.getElementById('bom-components-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl || !searchEl) return;
    errEl.style.display = 'none';

    const params = new URLSearchParams();
    if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
    if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
    if (includeObsolete) params.set('include_obsolete', 'true');

    resultEl.innerHTML = '<div class="empty-state">Loading components…</div>';
    try {
      const res = await fetch(`/api/v1/bom/components?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const q = searchEl.value.trim().toLowerCase();
      const rows = (Array.isArray(data.components) ? data.components : []).filter(item => {
        if (!q) return true;
        const props = propsObj(item.properties);
        return [props.part, props.description, props.category, item.full_product_identifier, item.bom_name]
          .filter(Boolean)
          .some(value => String(value).toLowerCase().includes(q));
      });
      if (!rows.length) {
        resultEl.innerHTML = '<div class="empty-state">No matching BOM components found.</div>';
        return;
      }
      resultEl.innerHTML = `<div class="table-scroll"><table>
        <thead>
          <tr>
            <th>Product</th>
            <th>BOM</th>
            <th>Part</th>
            <th>Rev</th>
            <th>Description</th>
            <th>Category</th>
            <th>Req Links</th>
            <th>Test Links</th>
            <th>Warnings</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(item => {
            const props = propsObj(item.properties);
            const warningCount = Number(item.unresolved_requirement_count || 0) + Number(item.unresolved_test_count || 0);
            return `<tr>
              <td>${esc(item.full_product_identifier || '—')}</td>
              <td>${esc(item.bom_name || '—')}</td>
              <td><span class="req-id">${esc(props.part || '—')}</span></td>
              <td>${esc(props.revision || '—')}</td>
              <td>${esc(props.description || '—')}</td>
              <td>${esc(props.category || '—')}</td>
              <td>${esc(String(item.linked_requirement_count || 0))}</td>
              <td>${esc(String(item.linked_test_count || 0))}</td>
              <td>${esc(String(warningCount))}</td>
              <td><button class="btn" data-action="inspect-bom-component" data-item-id="${esc(item.item_id || '')}" data-part="${esc(props.part || '')}" data-product="${esc(item.full_product_identifier || '')}" data-bom-name="${esc(item.bom_name || '')}">Inspect</button></td>
            </tr>`;
          }).join('')}
        </tbody>
      </table></div>`;
    } catch (e) {
      errEl.textContent = 'Failed to load BOM components: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function inspectBomComponent(itemId, part, fullProductIdentifier, bomName) {
    bomState.selectedProduct = fullProductIdentifier || null;
    bomState.selectedBomName = bomName || null;
    renderDesignBomList();
    syncBomFiltersFromSelection();
    await loadSelectedDesignBomDetail();
    const usageInput = document.getElementById('bom-usage-part');
    if (usageInput) usageInput.value = part || '';
    showTab('bom-usage');
    await runBomPartUsage();
  }

  async function loadBomCoverage() {
    const errEl = document.getElementById('bom-coverage-error');
    const resultEl = document.getElementById('bom-coverage-result');
    const productEl = document.getElementById('bom-coverage-product');
    const nameEl = document.getElementById('bom-coverage-name');
    const includeObsolete = !!document.getElementById('bom-coverage-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl) return;
    errEl.style.display = 'none';

    const params = new URLSearchParams();
    if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
    if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
    if (includeObsolete) params.set('include_obsolete', 'true');

    resultEl.innerHTML = '<div class="empty-state">Loading BOM coverage…</div>';
    try {
      const res = await fetch(`/api/v1/bom/coverage?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const summary = data.summary || {};
      const rows = Array.isArray(data.design_boms) ? data.design_boms : [];
      resultEl.innerHTML = `
        <div class="bom-metrics">
          <div class="bom-metric"><div class="bom-metric-label">Items</div><div class="bom-metric-value">${esc(String(summary.item_count || 0))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Req Covered</div><div class="bom-metric-value">${esc(String(summary.requirement_covered_count || 0))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Test Covered</div><div class="bom-metric-value">${esc(String(summary.test_covered_count || 0))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Fully Covered</div><div class="bom-metric-value">${esc(String(summary.fully_covered_count || 0))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">No Trace</div><div class="bom-metric-value">${esc(String(summary.no_trace_count || 0))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Warnings</div><div class="bom-metric-value">${esc(String(summary.warning_count || 0))}</div></div>
        </div>
        ${rows.length ? `<div class="table-scroll"><table>
          <thead>
            <tr>
              <th>Product</th>
              <th>Status</th>
              <th>BOM</th>
              <th>Items</th>
              <th>Req Covered</th>
              <th>Test Covered</th>
              <th>Fully Covered</th>
              <th>No Trace</th>
              <th>Warnings</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map(row => `<tr>
              <td>${esc(row.full_product_identifier || '—')}</td>
              <td>${esc(row.product_status || 'Active')}</td>
              <td>${esc(row.bom_name || '—')}</td>
              <td>${esc(String(row.item_count || 0))}</td>
              <td>${esc(String(row.requirement_covered_count || 0))}</td>
              <td>${esc(String(row.test_covered_count || 0))}</td>
              <td>${esc(String(row.fully_covered_count || 0))}</td>
              <td>${esc(String(row.no_trace_count || 0))}</td>
              <td>${esc(String(row.warning_count || 0))}</td>
            </tr>`).join('')}
          </tbody>
        </table></div>` : '<div class="empty-state">No Design BOM coverage rows found.</div>'}
      `;
    } catch (e) {
      errEl.textContent = 'Failed to load BOM coverage: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  function downloadDesignBomReport(format = 'md') {
    const productEl = document.getElementById('report-design-bom-product');
    const nameEl = document.getElementById('report-design-bom-name');
    const includeObsolete = !!document.getElementById('design-boms-include-obsolete')?.checked;
    const fullProductIdentifier = productEl?.value.trim() || bomState.selectedProduct || '';
    const bomName = nameEl?.value.trim() || bomState.selectedBomName || '';
    if (!fullProductIdentifier || !bomName) {
      alert('Select a Design BOM first, or enter both product full_identifier and BOM name.');
      return;
    }

    if (productEl && !productEl.value.trim()) productEl.value = fullProductIdentifier;
    if (nameEl && !nameEl.value.trim()) nameEl.value = bomName;

    const query = new URLSearchParams({
      full_product_identifier: fullProductIdentifier,
      bom_name: bomName,
    });
    if (includeObsolete) query.set('include_obsolete', 'true');
    const path = format === 'pdf'
      ? '/report/design-bom'
      : (format === 'docx' ? '/report/design-bom.docx' : '/report/design-bom.md');
    window.location.href = `${path}?${query.toString()}`;
  }

  async function loadSoupWorkspace(force = false) {
    const errEl = document.getElementById('software-boms-error');
    const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
    if (errEl) errEl.style.display = 'none';
    try {
      const params = new URLSearchParams();
      if (includeObsolete) params.set('include_obsolete', 'true');
      const res = await fetch(`/api/v1/soup?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      soupState.softwareBoms = Array.isArray(data.software_boms) ? data.software_boms : [];
      const stillSelected = soupState.softwareBoms.some(b =>
        b.full_product_identifier === soupState.selectedProduct && b.bom_name === soupState.selectedBomName);
      if (!stillSelected || force) {
        if (soupState.softwareBoms.length) {
          soupState.selectedProduct = soupState.softwareBoms[0].full_product_identifier || null;
          soupState.selectedBomName = soupState.softwareBoms[0].bom_name || null;
        } else {
          soupState.selectedProduct = null;
          soupState.selectedBomName = null;
        }
      }
      renderSoftwareBomList();
      if (soupState.selectedProduct && soupState.selectedBomName) {
        await loadSelectedSoupDetail();
      } else {
        const detailEl = document.getElementById('software-bom-detail');
        if (detailEl) detailEl.innerHTML = '<div class="empty-state">No software BOMs or SOUP registers ingested yet.</div>';
      }
    } catch (e) {
      soupState.softwareBoms = [];
      renderSoftwareBomList();
      const detailEl = document.getElementById('software-bom-detail');
      if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load software BOMs: ${esc(e.message)}</div>`;
      if (errEl) {
        errEl.textContent = 'Failed to load software BOMs: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function renderSoftwareBomList() {
    const bodyEl = document.getElementById('software-bom-list-body');
    if (!bodyEl) return;
    if (!soupState.softwareBoms.length) {
      bodyEl.innerHTML = '<tr><td colspan="8" class="empty-state">No software BOMs available for the active workbook.</td></tr>';
      return;
    }
    bodyEl.innerHTML = soupState.softwareBoms.map(b => {
      const selected = b.full_product_identifier === soupState.selectedProduct && b.bom_name === soupState.selectedBomName;
      return `<tr${selected ? ' class="warning"' : ''}>
        <td><span class="req-id">${esc(b.full_product_identifier || '—')}</span></td>
        <td>${esc(b.product_status || 'Active')}</td>
        <td>${esc(b.bom_name || '—')}</td>
        <td>${esc(b.source_format || '—')}</td>
        <td>${esc(String(b.item_count || 0))}</td>
        <td>${esc(String(b.warning_count || 0))}</td>
        <td>${esc(formatUnixTimestamp(b.ingested_at))}</td>
        <td><button class="btn" data-action="select-software-bom" data-product="${esc(b.full_product_identifier || '')}" data-bom-name="${esc(b.bom_name || '')}">${selected ? 'Selected' : 'Inspect'}</button></td>
      </tr>`;
    }).join('');
  }

  async function selectSoftwareBom(fullProductIdentifier, bomName) {
    soupState.selectedProduct = fullProductIdentifier || null;
    soupState.selectedBomName = bomName || null;
    renderSoftwareBomList();
    syncSoupFiltersFromSelection();
    await loadSelectedSoupDetail();
  }

  function syncSoupFiltersFromSelection() {
    const product = soupState.selectedProduct || '';
    const name = soupState.selectedBomName || '';
    const componentProduct = document.getElementById('soup-components-product');
    const componentName = document.getElementById('soup-components-name');
    const gapsProduct = document.getElementById('soup-gaps-product');
    const gapsName = document.getElementById('soup-gaps-name');
    const licenseProduct = document.getElementById('soup-licenses-product');
    const safetyProduct = document.getElementById('soup-safety-product');
    const uploadProduct = document.getElementById('soup-upload-product');
    const uploadName = document.getElementById('soup-upload-name');
    const syncProduct = document.getElementById('soup-sync-product');
    const syncName = document.getElementById('soup-sync-bom-name');
    const reportProduct = document.getElementById('report-soup-product');
    const reportName = document.getElementById('report-soup-name');
    if (componentProduct && !componentProduct.value) componentProduct.value = product;
    if (componentName && !componentName.value) componentName.value = name;
    if (gapsProduct && !gapsProduct.value) gapsProduct.value = product;
    if (gapsName && !gapsName.value) gapsName.value = name;
    if (licenseProduct && !licenseProduct.value) licenseProduct.value = product;
    if (safetyProduct && !safetyProduct.value) safetyProduct.value = product;
    if (uploadProduct && !uploadProduct.value) uploadProduct.value = product;
    if (uploadName && !uploadName.value) uploadName.value = name;
    if (syncProduct && !syncProduct.value) syncProduct.value = product;
    if (syncName && !syncName.value) syncName.value = name;
    if (reportProduct && !reportProduct.value) reportProduct.value = product;
    if (reportName && !reportName.value) reportName.value = name;
  }

  async function loadSelectedSoupDetail() {
    const detailEl = document.getElementById('software-bom-detail');
    const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
    if (!detailEl) return;
    if (!soupState.selectedProduct || !soupState.selectedBomName) {
      detailEl.innerHTML = '<div class="empty-state">Select a SOUP register to inspect it.</div>';
      return;
    }
    detailEl.innerHTML = '<div class="empty-state">Loading SOUP detail…</div>';
    try {
      const query = new URLSearchParams({
        full_product_identifier: soupState.selectedProduct,
        bom_name: soupState.selectedBomName,
      });
      if (includeObsolete) query.set('include_obsolete', 'true');
      const res = await fetch(`/api/v1/soup/components?${query.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const components = Array.isArray(data.components) ? data.components : [];
      const totalWarnings = components.reduce((sum, item) =>
        sum + ((item.statuses || []).filter(status => status !== 'SOUP_OK').length), 0);
      detailEl.innerHTML = `
        <div class="toolbar card-toolbar">
          <span class="card-title">${esc(data.full_product_identifier || '')} · ${esc(data.bom_name || '')}</span>
        </div>
        <div class="bom-metrics">
          <div class="bom-metric">
            <div class="bom-metric-label">Components</div>
            <div class="bom-metric-value">${esc(String(components.length))}</div>
          </div>
          <div class="bom-metric">
            <div class="bom-metric-label">Status Flags</div>
            <div class="bom-metric-value">${esc(String(totalWarnings))}</div>
          </div>
          <div class="bom-metric">
            <div class="bom-metric-label">Source</div>
            <div class="bom-metric-value">SOUP</div>
          </div>
        </div>
        ${components.length ? `<div class="table-scroll"><table>
          <thead>
            <tr>
              <th>Component</th>
              <th>Version</th>
              <th>Supplier</th>
              <th>License</th>
              <th>Safety</th>
              <th>Anomalies</th>
              <th>Links</th>
              <th>Statuses</th>
            </tr>
          </thead>
          <tbody>${components.map(renderSoupComponentRow).join('')}</tbody>
        </table></div>` : '<div class="empty-state">No SOUP components found.</div>'}
      `;
      syncSoupFiltersFromSelection();
    } catch (e) {
      detailEl.innerHTML = `<div class="empty-state">Failed to load SOUP detail: ${esc(e.message)}</div>`;
    }
  }

  function renderSoupComponentRow(item) {
    const props = propsObj(item.properties);
    const declaredReqs = Array.isArray(props.requirement_ids) ? props.requirement_ids : [];
    const declaredTests = Array.isArray(props.test_ids) ? props.test_ids : [];
    const anomalies = props.known_anomalies || '—';
    const evaluation = props.anomaly_evaluation || '—';
    return `<tr>
      <td><span class="req-id">${esc(props.part || item.item_id || '—')}</span></td>
      <td>${esc(props.revision || '—')}</td>
      <td>${esc(props.supplier || '—')}</td>
      <td>${esc(props.license || '—')}</td>
      <td>${esc(props.safety_class || '—')}</td>
      <td>
        <div>${esc(anomalies)}</div>
        <div class="text-sm-subtle mt-8">${esc(evaluation)}</div>
      </td>
      <td>
        <div>${declaredReqs.map(id => `<span class="bom-chip">${esc(id)}</span>`).join('') || '<span class="text-placeholder">No requirement IDs</span>'}</div>
        <div class="mt-8">${declaredTests.map(id => `<span class="bom-chip">${esc(id)}</span>`).join('') || '<span class="text-placeholder">No test IDs</span>'}</div>
      </td>
      <td>${(item.statuses || []).map(status => `<span class="bom-chip${status === 'SOUP_OK' ? '' : ' warn'}">${esc(status)}</span>`).join('')}</td>
    </tr>`;
  }

  async function loadSoupComponents() {
    const errEl = document.getElementById('soup-components-error');
    const resultEl = document.getElementById('soup-components-result');
    const productEl = document.getElementById('soup-components-product');
    const nameEl = document.getElementById('soup-components-name');
    const searchEl = document.getElementById('soup-components-search');
    const includeObsolete = !!document.getElementById('soup-components-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl || !searchEl) return;
    errEl.style.display = 'none';
    if (!productEl.value.trim() && soupState.selectedProduct) productEl.value = soupState.selectedProduct;
    if (!nameEl.value.trim() && soupState.selectedBomName) nameEl.value = soupState.selectedBomName;
    if (!productEl.value.trim()) {
      errEl.textContent = 'Provide a product full_identifier, or select a SOUP register first.';
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
      return;
    }
    const params = new URLSearchParams({ full_product_identifier: productEl.value.trim() });
    if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
    if (includeObsolete) params.set('include_obsolete', 'true');
    resultEl.innerHTML = '<div class="empty-state">Loading SOUP components…</div>';
    try {
      const res = await fetch(`/api/v1/soup/components?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const q = searchEl.value.trim().toLowerCase();
      const rows = (Array.isArray(data.components) ? data.components : []).filter(item => {
        if (!q) return true;
        const props = propsObj(item.properties);
        return [props.part, props.license, props.supplier, props.category, props.known_anomalies, props.anomaly_evaluation]
          .filter(Boolean)
          .some(value => String(value).toLowerCase().includes(q));
      });
      if (!rows.length) {
        resultEl.innerHTML = '<div class="empty-state">No matching SOUP components found.</div>';
        return;
      }
      resultEl.innerHTML = `<div class="table-scroll"><table>
        <thead>
          <tr>
            <th>Component</th>
            <th>Version</th>
            <th>Supplier</th>
            <th>Category</th>
            <th>License</th>
            <th>PURL</th>
            <th>Safety</th>
            <th>Req</th>
            <th>Test</th>
            <th>Statuses</th>
          </tr>
        </thead>
        <tbody>${rows.map(item => {
          const props = propsObj(item.properties);
          return `<tr>
            <td><span class="req-id">${esc(props.part || '—')}</span></td>
            <td>${esc(props.revision || '—')}</td>
            <td>${esc(props.supplier || '—')}</td>
            <td>${esc(props.category || '—')}</td>
            <td>${esc(props.license || '—')}</td>
            <td>${esc(props.purl || '—')}</td>
            <td>${esc(props.safety_class || '—')}</td>
            <td>${esc(String(item.linked_requirement_count || 0))}/${esc(String(item.declared_requirement_count || 0))}</td>
            <td>${esc(String(item.linked_test_count || 0))}/${esc(String(item.declared_test_count || 0))}</td>
            <td>${(item.statuses || []).map(status => `<span class="bom-chip${status === 'SOUP_OK' ? '' : ' warn'}">${esc(status)}</span>`).join('')}</td>
          </tr>`;
        }).join('')}</tbody>
      </table></div>`;
    } catch (e) {
      errEl.textContent = 'Failed to load SOUP components: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function loadSoupGaps() {
    const errEl = document.getElementById('soup-gaps-error');
    const resultEl = document.getElementById('soup-gaps-result');
    const productEl = document.getElementById('soup-gaps-product');
    const nameEl = document.getElementById('soup-gaps-name');
    const includeInactive = !!document.getElementById('soup-gaps-include-inactive')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl) return;
    errEl.style.display = 'none';
    const params = new URLSearchParams();
    if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
    if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
    if (includeInactive) params.set('include_inactive', 'true');
    resultEl.innerHTML = '<div class="empty-state">Loading SOUP gaps…</div>';
    try {
      const res = await fetch(`/api/v1/soup/gaps?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const gaps = Array.isArray(data.gaps) ? data.gaps : [];
      if (!gaps.length) {
        resultEl.innerHTML = '<div class="empty-state">No SOUP gaps found for the current filter.</div>';
        return;
      }
      resultEl.innerHTML = gaps.map(gap => {
        const props = propsObj(gap.properties);
        return `<div class="card card--padded">
          <div class="bom-tree-head">
            <span class="req-id">${esc(props.part || gap.item_id || '')}</span>
            <span class="bom-chip">${esc(props.revision || '-')}</span>
            <span class="bom-chip">${esc(gap.full_product_identifier || '')}</span>
            <span class="bom-chip">${esc(gap.bom_name || '')}</span>
          </div>
          <div class="mt-8">${(gap.statuses || []).map(status => `<span class="bom-chip warn">${esc(status)}</span>`).join('')}</div>
          <div class="text-sm-subtle mt-8">Anomalies: ${esc(props.known_anomalies || '—')}</div>
          <div class="text-sm-subtle">Evaluation: ${esc(props.anomaly_evaluation || '—')}</div>
          <div class="text-sm-subtle">Unresolved IDs: ${esc((gap.unresolved_requirement_ids || []).concat(gap.unresolved_test_ids || []).join(', ') || '—')}</div>
        </div>`;
      }).join('');
    } catch (e) {
      errEl.textContent = 'Failed to load SOUP gaps: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function loadSoupLicenses() {
    const errEl = document.getElementById('soup-licenses-error');
    const resultEl = document.getElementById('soup-licenses-result');
    const productEl = document.getElementById('soup-licenses-product');
    const licenseEl = document.getElementById('soup-licenses-license');
    const includeObsolete = !!document.getElementById('soup-licenses-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !licenseEl) return;
    errEl.style.display = 'none';
    const params = new URLSearchParams();
    if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
    if (licenseEl.value.trim()) params.set('license', licenseEl.value.trim());
    if (includeObsolete) params.set('include_obsolete', 'true');
    resultEl.innerHTML = '<div class="empty-state">Loading SOUP licenses…</div>';
    try {
      const res = await fetch(`/api/v1/soup/licenses?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const rows = Array.isArray(data.components) ? data.components : [];
      if (!rows.length) {
        resultEl.innerHTML = '<div class="empty-state">No SOUP components matched that license filter.</div>';
        return;
      }
      resultEl.innerHTML = `<div class="table-scroll"><table>
        <thead><tr><th>Product</th><th>BOM</th><th>Component</th><th>Version</th><th>License</th><th>Supplier</th></tr></thead>
        <tbody>${rows.map(row => {
          const props = propsObj(row.properties);
          return `<tr>
            <td>${esc(row.full_product_identifier || '—')}</td>
            <td>${esc(row.bom_name || '—')}</td>
            <td><span class="req-id">${esc(props.part || '—')}</span></td>
            <td>${esc(props.revision || '—')}</td>
            <td>${esc(props.license || '—')}</td>
            <td>${esc(props.supplier || '—')}</td>
          </tr>`;
        }).join('')}</tbody>
      </table></div>`;
    } catch (e) {
      errEl.textContent = 'Failed to load SOUP licenses: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function loadSoupSafetyClasses() {
    const errEl = document.getElementById('soup-safety-error');
    const resultEl = document.getElementById('soup-safety-result');
    const productEl = document.getElementById('soup-safety-product');
    const classEl = document.getElementById('soup-safety-class');
    const includeObsolete = !!document.getElementById('soup-safety-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !classEl) return;
    errEl.style.display = 'none';
    if (!productEl.value.trim() && soupState.selectedProduct) productEl.value = soupState.selectedProduct;
    if (!productEl.value.trim()) {
      errEl.textContent = 'Provide a product full_identifier, or select a SOUP register first.';
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
      return;
    }
    const params = new URLSearchParams({ full_product_identifier: productEl.value.trim() });
    if (classEl.value.trim()) params.set('safety_class', classEl.value.trim());
    if (includeObsolete) params.set('include_obsolete', 'true');
    resultEl.innerHTML = '<div class="empty-state">Loading SOUP safety classes…</div>';
    try {
      const res = await fetch(`/api/v1/soup/safety-classes?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const rows = Array.isArray(data.components) ? data.components : [];
      if (!rows.length) {
        resultEl.innerHTML = '<div class="empty-state">No SOUP components matched that safety class filter.</div>';
        return;
      }
      resultEl.innerHTML = rows.map(row => {
        const props = propsObj(row.properties);
        return `<div class="card card--padded">
          <div class="bom-tree-head">
            <span class="req-id">${esc(props.part || row.item_id || '')}</span>
            <span class="bom-chip">${esc(props.revision || '-')}</span>
            <span class="bom-chip">${esc(props.safety_class || '—')}</span>
            <span class="bom-chip">${esc(row.bom_name || '—')}</span>
          </div>
          <div class="text-sm-subtle">License: ${esc(props.license || '—')} · Supplier: ${esc(props.supplier || '—')}</div>
          <div class="text-sm-subtle">Known anomalies: ${esc(props.known_anomalies || '—')}</div>
        </div>`;
      }).join('');
    } catch (e) {
      errEl.textContent = 'Failed to load SOUP safety classes: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  function downloadSoupReport(format = 'md') {
    const productEl = document.getElementById('report-soup-product');
    const nameEl = document.getElementById('report-soup-name');
    const includeObsolete = !!document.getElementById('software-boms-include-obsolete')?.checked;
    const fullProductIdentifier = productEl?.value.trim() || soupState.selectedProduct || '';
    const bomName = nameEl?.value.trim() || soupState.selectedBomName || 'SOUP Components';
    if (!fullProductIdentifier) {
      alert('Select a SOUP register first, or enter a product full_identifier.');
      return;
    }
    if (productEl && !productEl.value.trim()) productEl.value = fullProductIdentifier;
    if (nameEl && !nameEl.value.trim()) nameEl.value = bomName;
    const query = new URLSearchParams({
      full_product_identifier: fullProductIdentifier,
      bom_name: bomName,
    });
    if (includeObsolete) query.set('include_obsolete', 'true');
    const path = format === 'pdf'
      ? '/report/soup'
      : (format === 'docx' ? '/report/soup.docx' : '/report/soup.md');
    window.location.href = `${path}?${query.toString()}`;
  }

  async function runBomPartUsage() {
    const errEl = document.getElementById('bom-usage-error');
    const resultEl = document.getElementById('bom-usage-result');
    const inputEl = document.getElementById('bom-usage-part');
    const includeObsolete = !!document.getElementById('bom-usage-include-obsolete')?.checked;
    if (!errEl || !resultEl || !inputEl) return;
    errEl.style.display = 'none';
    const part = inputEl.value.trim();
    if (!part) {
      errEl.textContent = 'Enter a part number.';
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
      return;
    }
    resultEl.innerHTML = '<div class="empty-state">Loading part usage…</div>';
    try {
      const query = includeObsolete
        ? `part=${encodeURIComponent(part)}&include_obsolete=true`
        : `part=${encodeURIComponent(part)}`;
      const res = await fetch(`/api/v1/bom/part-usage?${query}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const usages = Array.isArray(data.usages) ? data.usages : [];
      if (!usages.length) {
        resultEl.innerHTML = '<div class="empty-state">No Design BOM usage found for that part.</div>';
        return;
      }
      resultEl.innerHTML = usages.map(usage => {
        const designBom = propsObj(usage.design_bom);
        const parent = propsObj(usage.parent_properties);
        const edgeProps = propsObj(usage.edge_properties);
        return `<div class="card card--padded">
          <div class="bom-tree-head">
            <span class="req-id">${esc(usage.part || data.part || '')}</span>
            ${usage.revision ? `<span class="bom-chip">${esc(usage.revision)}</span>` : ''}
            <span class="bom-chip">${esc(designBom.full_product_identifier || '—')}</span>
            <span class="bom-chip">${esc(designBom.bom_name || '—')}</span>
          </div>
          <div class="text-sm-subtle">Parent: ${esc(parent.part || usage.parent_id || 'BOM root')}</div>
          <div class="text-sm-subtle">Quantity: ${esc(edgeProps.quantity || '—')} · Ref Des: ${esc(edgeProps.ref_designator || '—')} · Supplier: ${esc(edgeProps.supplier || '—')}</div>
        </div>`;
      }).join('');
    } catch (e) {
      errEl.textContent = 'Failed to load part usage: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function loadBomGaps() {
    const errEl = document.getElementById('bom-gaps-error');
    const resultEl = document.getElementById('bom-gaps-result');
    const productEl = document.getElementById('bom-gaps-product');
    const nameEl = document.getElementById('bom-gaps-name');
    const includeInactive = !!document.getElementById('bom-gaps-include-inactive')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl) return;
    errEl.style.display = 'none';
    const params = new URLSearchParams();
    if (productEl.value.trim()) params.set('full_product_identifier', productEl.value.trim());
    if (nameEl.value.trim()) params.set('bom_name', nameEl.value.trim());
    if (includeInactive) params.set('include_inactive', 'true');
    resultEl.innerHTML = '<div class="empty-state">Loading BOM gaps…</div>';
    try {
      const res = await fetch(`/api/v1/bom/gaps?${params.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const gaps = Array.isArray(data.gaps) ? data.gaps : [];
      if (!gaps.length) {
        resultEl.innerHTML = '<div class="empty-state">No BOM traceability gaps found for the current filter.</div>';
        return;
      }
      resultEl.innerHTML = gaps.map(gap => {
        const props = propsObj(gap.properties);
        return `<div class="card card--padded">
          <div class="bom-tree-head">
            <span class="req-id">${esc(props.part || gap.item_id || '')}</span>
            <span class="bom-chip">${esc(props.revision || '-')}</span>
            <span class="bom-chip">${esc(gap.full_product_identifier || '')}</span>
            <span class="bom-chip">${esc(gap.bom_name || '')}</span>
          </div>
          <div class="text-sm-subtle">Declared requirements: ${(props.requirement_ids || []).map(id => esc(id)).join(', ') || '—'}</div>
          <div class="text-sm-subtle">Declared tests: ${(props.test_ids || []).map(id => esc(id)).join(', ') || '—'}</div>
          <div class="mt-8">${(gap.unresolved_requirement_ids || []).concat(gap.unresolved_test_ids || []).map(id => `<span class="bom-chip warn">${esc(id)}</span>`).join('') || '<span class="text-placeholder">All declared refs currently resolve.</span>'}</div>
        </div>`;
      }).join('');
    } catch (e) {
      errEl.textContent = 'Failed to load BOM gaps: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  async function loadBomImpactAnalysis() {
    const errEl = document.getElementById('bom-impact-error');
    const resultEl = document.getElementById('bom-impact-result');
    const productEl = document.getElementById('bom-impact-product');
    const nameEl = document.getElementById('bom-impact-name');
    const includeObsolete = !!document.getElementById('bom-impact-include-obsolete')?.checked;
    if (!errEl || !resultEl || !productEl || !nameEl) return;
    errEl.style.display = 'none';
    if (!productEl.value.trim() && bomState.selectedProduct) productEl.value = bomState.selectedProduct;
    if (!nameEl.value.trim() && bomState.selectedBomName) nameEl.value = bomState.selectedBomName;
    if (!productEl.value.trim() || !nameEl.value.trim()) {
      errEl.textContent = 'Provide a product full_identifier and BOM name, or select a Design BOM first.';
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
      return;
    }
    resultEl.innerHTML = '<div class="empty-state">Loading BOM impact analysis…</div>';
    try {
      const query = new URLSearchParams({
        full_product_identifier: productEl.value.trim(),
        bom_name: nameEl.value.trim(),
      });
      if (includeObsolete) query.set('include_obsolete', 'true');
      const res = await fetch(`/api/v1/bom/impact-analysis?${query.toString()}`, { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const items = Array.isArray(data.items) ? data.items : [];
      if (!items.length) {
        resultEl.innerHTML = '<div class="empty-state">No impact records found for that Design BOM.</div>';
        return;
      }
      resultEl.innerHTML = items.map(item => {
        const props = propsObj(item.properties);
        return `<div class="card card--padded">
          <div class="bom-tree-head">
            <span class="req-id">${esc(props.part || item.item_id || '')}</span>
            <span class="bom-chip">${esc(props.revision || '-')}</span>
            <span class="bom-chip">${esc(String((item.linked_requirements || []).length))} requirements</span>
            <span class="bom-chip">${esc(String((item.linked_tests || []).length))} tests</span>
          </div>
          <div>${(item.linked_requirements || []).map(node => `<span class="bom-chip">${esc(node.id)}</span>`).join('') || '<span class="text-placeholder">No linked requirements</span>'}</div>
          <div class="mt-8">${(item.linked_tests || []).map(node => `<span class="bom-chip">${esc(node.id)}</span>`).join('') || '<span class="text-placeholder">No linked tests</span>'}</div>
        </div>`;
      }).join('');
    } catch (e) {
      errEl.textContent = 'Failed to load BOM impact analysis: ' + e.message;
      errEl.style.display = 'block';
      resultEl.innerHTML = '';
    }
  }

  function toggleDesignBomSyncKind() {
    const kind = document.getElementById('design-bom-sync-kind')?.value || 'local_xlsx';
    const localEl = document.getElementById('design-bom-sync-local');
    const providerEl = document.getElementById('design-bom-sync-provider');
    const googleEl = document.getElementById('design-bom-sync-google');
    const excelEl = document.getElementById('design-bom-sync-excel');
    if (localEl) localEl.classList.toggle('active', kind === 'local_xlsx');
    if (providerEl) providerEl.classList.toggle('active', kind !== 'local_xlsx');
    if (googleEl) googleEl.classList.toggle('active', kind === 'google');
    if (excelEl) excelEl.classList.toggle('active', kind === 'excel');
  }

  async function loadDesignBomSyncSettings(force = false) {
    const errEl = document.getElementById('design-bom-sync-error');
    const statusEl = document.getElementById('design-bom-sync-status');
    if (!errEl || !statusEl) return;
    if (!force) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/design-bom-sync', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      renderDesignBomSyncStatus(data);
      applyDesignBomSyncForm(data);
    } catch (e) {
      statusEl.innerHTML = '<dt>State</dt><dd>Unavailable</dd>';
      errEl.textContent = 'Failed to load Design BOM sync settings: ' + e.message;
      errEl.style.display = 'block';
    }
  }

  function renderDesignBomSyncStatus(data) {
    const statusEl = document.getElementById('design-bom-sync-status');
    if (!statusEl) return;
    if (!data.configured) {
      statusEl.innerHTML = '<dt>State</dt><dd>Not configured</dd><dt>Sync</dt><dd>No secondary Design BOM source attached.</dd>';
      return;
    }
    statusEl.innerHTML = `
      <dt>State</dt><dd>${esc(data.kind || 'unknown')}</dd>
      <dt>Display Name</dt><dd>${esc(data.display_name || '—')}</dd>
      <dt>Workbook</dt><dd>${esc(data.workbook_label || data.workbook_url || data.local_xlsx_path || '—')}</dd>
      <dt>Credential</dt><dd>${esc(data.credential_display || 'stored in secure store')}</dd>
      <dt>Last Sync</dt><dd>${esc(formatUnixTimestamp(data.last_sync_at))}</dd>
      <dt>Last Result</dt><dd>${data.last_sync_ok === '1' ? 'OK' : (data.last_error || 'No successful sync recorded')}</dd>
    `;
  }

  function applyDesignBomSyncForm(data) {
    const kind = data.configured ? (data.kind || 'local_xlsx') : 'local_xlsx';
    const kindEl = document.getElementById('design-bom-sync-kind');
    const displayNameEl = document.getElementById('design-bom-sync-display-name');
    const localPathEl = document.getElementById('design-bom-sync-local-path');
    const workbookUrlEl = document.getElementById('design-bom-sync-workbook-url');
    if (kindEl) kindEl.value = kind;
    if (displayNameEl) displayNameEl.value = data.display_name || 'Design BOM Workbook';
    if (localPathEl) localPathEl.value = data.local_xlsx_path || '';
    if (workbookUrlEl) workbookUrlEl.value = data.workbook_url || '';
    toggleDesignBomSyncKind();
  }

  function buildDesignBomSyncDraft() {
    const kind = document.getElementById('design-bom-sync-kind')?.value || 'local_xlsx';
    const displayName = document.getElementById('design-bom-sync-display-name')?.value.trim() || 'Design BOM Workbook';
    if (kind === 'local_xlsx') {
      const localPath = document.getElementById('design-bom-sync-local-path')?.value.trim() || '';
      if (!localPath) throw new Error('Enter a local XLSX path.');
      return { kind, display_name: displayName, local_xlsx_path: localPath };
    }
    const workbookUrl = document.getElementById('design-bom-sync-workbook-url')?.value.trim() || '';
    if (!workbookUrl) throw new Error('Enter a workbook URL.');
    if (kind === 'google') {
      const serviceAccountJson = document.getElementById('design-bom-sync-google-json')?.value.trim() || '';
      if (!serviceAccountJson) throw new Error('Paste the Google service account JSON.');
      return {
        kind,
        platform: 'google',
        workbook_url: workbookUrl,
        display_name: displayName,
        credentials: { service_account_json: serviceAccountJson },
      };
    }
    const tenantId = document.getElementById('design-bom-sync-excel-tenant')?.value.trim() || '';
    const clientId = document.getElementById('design-bom-sync-excel-client')?.value.trim() || '';
    const clientSecret = document.getElementById('design-bom-sync-excel-secret')?.value.trim() || '';
    if (!tenantId || !clientId || !clientSecret) throw new Error('Enter all Excel Online credentials.');
    return {
      kind,
      platform: 'excel',
      workbook_url: workbookUrl,
      display_name: displayName,
      credentials: {
        tenant_id: tenantId,
        client_id: clientId,
        client_secret: clientSecret,
      },
    };
  }

  async function validateDesignBomSync() {
    const errEl = document.getElementById('design-bom-sync-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const draft = buildDesignBomSyncDraft();
      const res = await fetch('/api/design-bom-sync/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      renderDesignBomSyncStatus({
        configured: true,
        kind: data.kind,
        display_name: data.display_name,
        workbook_label: data.workbook_label,
        workbook_url: draft.workbook_url,
        credential_display: data.credential_display,
        local_xlsx_path: draft.local_xlsx_path,
        last_sync_at: 0,
        last_sync_ok: null,
        last_error: null,
      });
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Validation failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function saveDesignBomSync() {
    const errEl = document.getElementById('design-bom-sync-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const draft = buildDesignBomSyncDraft();
      const res = await fetch('/api/design-bom-sync', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await loadDesignBomSyncSettings(true);
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to save Design BOM sync: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function deleteDesignBomSync() {
    const errEl = document.getElementById('design-bom-sync-error');
    if (!window.confirm('Remove the secondary Design BOM source from the active workbook?')) return;
    if (errEl) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/design-bom-sync', { method: 'DELETE' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await loadDesignBomSyncSettings(true);
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to remove Design BOM sync: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function toggleSoupSyncKind() {
    const kind = document.getElementById('soup-sync-kind')?.value || 'local_xlsx';
    const localEl = document.getElementById('soup-sync-local');
    const providerEl = document.getElementById('soup-sync-provider');
    const googleEl = document.getElementById('soup-sync-google');
    const excelEl = document.getElementById('soup-sync-excel');
    if (localEl) localEl.classList.toggle('active', kind === 'local_xlsx');
    if (providerEl) providerEl.classList.toggle('active', kind !== 'local_xlsx');
    if (googleEl) googleEl.classList.toggle('active', kind === 'google');
    if (excelEl) excelEl.classList.toggle('active', kind === 'excel');
  }

  async function loadSoupSyncSettings(force = false) {
    const errEl = document.getElementById('soup-sync-error');
    const statusEl = document.getElementById('soup-sync-status');
    if (!errEl || !statusEl) return;
    if (!force) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/soup-sync', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      renderSoupSyncStatus(data);
      applySoupSyncForm(data);
    } catch (e) {
      statusEl.innerHTML = '<dt>State</dt><dd>Unavailable</dd>';
      errEl.textContent = 'Failed to load SOUP sync settings: ' + e.message;
      errEl.style.display = 'block';
    }
  }

  function renderSoupSyncStatus(data) {
    const statusEl = document.getElementById('soup-sync-status');
    if (!statusEl) return;
    if (!data.configured) {
      statusEl.innerHTML = '<dt>State</dt><dd>Not configured</dd><dt>Sync</dt><dd>No secondary SOUP source attached.</dd>';
      return;
    }
    statusEl.innerHTML = `
      <dt>State</dt><dd>${esc(data.kind || 'unknown')}</dd>
      <dt>Display Name</dt><dd>${esc(data.display_name || '—')}</dd>
      <dt>Product Anchor</dt><dd>${esc(data.full_product_identifier || '—')}</dd>
      <dt>BOM Name</dt><dd>${esc(data.bom_name || 'SOUP Components')}</dd>
      <dt>Workbook</dt><dd>${esc(data.workbook_label || data.workbook_url || data.local_xlsx_path || '—')}</dd>
      <dt>Credential</dt><dd>${esc(data.credential_display || 'stored in secure store')}</dd>
      <dt>Last Sync</dt><dd>${esc(formatUnixTimestamp(data.last_sync_at))}</dd>
      <dt>Last Result</dt><dd>${data.last_sync_ok === '1' ? 'OK' : (data.last_error || 'No successful sync recorded')}</dd>
    `;
  }

  function applySoupSyncForm(data) {
    const kind = data.configured ? (data.kind || 'local_xlsx') : 'local_xlsx';
    const kindEl = document.getElementById('soup-sync-kind');
    const displayNameEl = document.getElementById('soup-sync-display-name');
    const productEl = document.getElementById('soup-sync-product');
    const bomNameEl = document.getElementById('soup-sync-bom-name');
    const localPathEl = document.getElementById('soup-sync-local-path');
    const workbookUrlEl = document.getElementById('soup-sync-workbook-url');
    if (kindEl) kindEl.value = kind;
    if (displayNameEl) displayNameEl.value = data.display_name || 'SOUP Workbook';
    if (productEl) productEl.value = data.full_product_identifier || '';
    if (bomNameEl) bomNameEl.value = data.bom_name || 'SOUP Components';
    if (localPathEl) localPathEl.value = data.local_xlsx_path || '';
    if (workbookUrlEl) workbookUrlEl.value = data.workbook_url || '';
    toggleSoupSyncKind();
  }

  function buildSoupSyncDraft() {
    const kind = document.getElementById('soup-sync-kind')?.value || 'local_xlsx';
    const displayName = document.getElementById('soup-sync-display-name')?.value.trim() || 'SOUP Workbook';
    const fullProductIdentifier = document.getElementById('soup-sync-product')?.value.trim() || '';
    const bomName = document.getElementById('soup-sync-bom-name')?.value.trim() || 'SOUP Components';
    if (!fullProductIdentifier) throw new Error('Enter the product full_identifier for this SOUP source.');
    if (kind === 'local_xlsx') {
      const localPath = document.getElementById('soup-sync-local-path')?.value.trim() || '';
      if (!localPath) throw new Error('Enter a local XLSX path.');
      return { kind, display_name: displayName, full_product_identifier: fullProductIdentifier, bom_name: bomName, local_xlsx_path: localPath };
    }
    const workbookUrl = document.getElementById('soup-sync-workbook-url')?.value.trim() || '';
    if (!workbookUrl) throw new Error('Enter a workbook URL.');
    if (kind === 'google') {
      const serviceAccountJson = document.getElementById('soup-sync-google-json')?.value.trim() || '';
      if (!serviceAccountJson) throw new Error('Paste the Google service account JSON.');
      return {
        kind,
        platform: 'google',
        workbook_url: workbookUrl,
        display_name: displayName,
        full_product_identifier: fullProductIdentifier,
        bom_name: bomName,
        credentials: { service_account_json: serviceAccountJson },
      };
    }
    const tenantId = document.getElementById('soup-sync-excel-tenant')?.value.trim() || '';
    const clientId = document.getElementById('soup-sync-excel-client')?.value.trim() || '';
    const clientSecret = document.getElementById('soup-sync-excel-secret')?.value.trim() || '';
    if (!tenantId || !clientId || !clientSecret) throw new Error('Enter all Excel Online credentials.');
    return {
      kind,
      platform: 'excel',
      workbook_url: workbookUrl,
      display_name: displayName,
      full_product_identifier: fullProductIdentifier,
      bom_name: bomName,
      credentials: {
        tenant_id: tenantId,
        client_id: clientId,
        client_secret: clientSecret,
      },
    };
  }

  async function validateSoupSync() {
    const errEl = document.getElementById('soup-sync-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const draft = buildSoupSyncDraft();
      const res = await fetch('/api/soup-sync/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      renderSoupSyncStatus({
        configured: true,
        kind: data.kind,
        display_name: data.display_name,
        workbook_label: data.workbook_label,
        workbook_url: draft.workbook_url,
        credential_display: data.credential_display,
        local_xlsx_path: draft.local_xlsx_path,
        full_product_identifier: draft.full_product_identifier,
        bom_name: draft.bom_name,
        last_sync_at: 0,
        last_sync_ok: null,
        last_error: null,
      });
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Validation failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function saveSoupSync() {
    const errEl = document.getElementById('soup-sync-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const draft = buildSoupSyncDraft();
      const res = await fetch('/api/soup-sync', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await loadSoupSyncSettings(true);
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to save SOUP sync: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function deleteSoupSync() {
    const errEl = document.getElementById('soup-sync-error');
    if (!window.confirm('Remove the secondary SOUP source from the active workbook?')) return;
    if (errEl) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/soup-sync', { method: 'DELETE' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await loadSoupSyncSettings(true);
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to remove SOUP sync: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function currentIngestToken() {
    const tokenEl = document.getElementById('test-results-token');
    const inline = tokenEl?.textContent?.trim();
    if (inline && inline !== 'Loading…' && inline !== '—' && inline !== 'unknown') return inline;
    const res = await fetch('/api/info', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const info = await res.json();
    if (!info.test_results_token) throw new Error('Missing ingestion token.');
    return info.test_results_token;
  }

  async function loadDesignArtifacts(force = false) {
    const errEl = document.getElementById('design-artifacts-error');
    const detailEl = document.getElementById('design-artifact-detail');
    if (errEl) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/v1/design-artifacts', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      artifactState.artifacts = Array.isArray(data) ? data : [];
      const stillSelected = artifactState.artifacts.some(item => item.artifact_id === artifactState.selectedArtifactId);
      if (force || !stillSelected) artifactState.selectedArtifactId = artifactState.artifacts[0]?.artifact_id || null;
      renderDesignArtifactList();
      if (artifactState.selectedArtifactId) {
        await loadSelectedDesignArtifactDetail();
      } else if (detailEl) {
        detailEl.innerHTML = '<div class="empty-state">No design artifacts ingested yet.</div>';
      }
    } catch (e) {
      artifactState.artifacts = [];
      artifactState.selectedArtifactId = null;
      renderDesignArtifactList();
      if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load design artifacts: ${esc(e.message)}</div>`;
      if (errEl) {
        errEl.textContent = 'Failed to load design artifacts: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function renderDesignArtifactList() {
    const bodyEl = document.getElementById('design-artifact-list-body');
    if (!bodyEl) return;
    if (!artifactState.artifacts.length) {
      bodyEl.innerHTML = '<tr><td colspan="9" class="empty-state">No design artifacts available for the active workbook.</td></tr>';
      return;
    }
    bodyEl.innerHTML = artifactState.artifacts.map(item => {
      const selected = item.artifact_id === artifactState.selectedArtifactId;
      const canReingest = !!item.reingestable;
      const reingestLabel = canReingest ? 'Re-ingest' : ((item.kind === 'rtm_workbook' && (item.ingest_source || '') === 'workbook_sync') ? 'Provider-managed' : 'Read-only');
      return `<tr${selected ? ' class="warning"' : ''}>
        <td>${esc(formatDesignArtifactKind(item.kind))}</td>
        <td>${esc(item.display_name || '—')}</td>
        <td><span class="req-id">${esc(item.logical_key || '—')}</span></td>
        <td>${esc(String(item.requirement_count || 0))}</td>
        <td>${esc(String(item.conflict_count || 0))}</td>
        <td>${esc(String(item.null_text_count || 0))}</td>
        <td>${esc(String(item.low_confidence_count || 0))}</td>
        <td>${esc(formatUnixTimestamp(item.last_ingested_at))}</td>
        <td>
          <div class="bom-inline-actions">
            <button class="btn" data-action="select-design-artifact" data-artifact-id="${esc(item.artifact_id || '')}">${selected ? 'Selected' : 'Inspect'}</button>
            <button class="btn" data-action="reingest-design-artifact" data-artifact-id="${esc(item.artifact_id || '')}"${canReingest ? '' : ' disabled title="This artifact cannot be re-ingested from the dashboard."'}>${reingestLabel}</button>
          </div>
        </td>
      </tr>`;
    }).join('');
  }

  async function selectDesignArtifact(artifactId) {
    artifactState.selectedArtifactId = artifactId || null;
    renderDesignArtifactList();
    await loadSelectedDesignArtifactDetail();
  }

  async function loadSelectedDesignArtifactDetail() {
    const detailEl = document.getElementById('design-artifact-detail');
    if (!detailEl) return;
    if (!artifactState.selectedArtifactId) {
      detailEl.innerHTML = '<div class="empty-state">Select a design artifact to inspect it.</div>';
      return;
    }
    detailEl.innerHTML = '<div class="empty-state">Loading design artifact detail…</div>';
    try {
      const res = await fetch(`/api/v1/design-artifacts/${encodeURIComponent(artifactState.selectedArtifactId)}`, { cache: 'no-store' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      const props = propsObj(data.properties);
      const assertions = Array.isArray(data.assertions) ? data.assertions : [];
      const extractionSummary = data.extraction_summary || {};
      const conflictRows = Array.isArray(data.conflicts) ? data.conflicts : [];
      const nullTextRows = assertions.filter(item => !item.text || item.parse_status === 'null_text');
      const lowConfidenceRows = assertions.filter(item => String(item.parse_status || '').startsWith('low_confidence_'));
      const newIds = Array.isArray(data.new_since_last_ingest) ? data.new_since_last_ingest : [];
      const ingestSummary = data.ingest_summary || null;
      detailEl.innerHTML = `
        <div class="toolbar card-toolbar">
          <span class="card-title">${esc(props.display_name || artifactState.selectedArtifactId || '')}</span>
        </div>
        <div class="bom-metrics">
          <div class="bom-metric"><div class="bom-metric-label">Kind</div><div class="bom-metric-value">${esc(formatDesignArtifactKind(props.kind || ''))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Requirements</div><div class="bom-metric-value">${esc(String(assertions.length))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Conflicts</div><div class="bom-metric-value">${esc(String(conflictRows.length))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Null Text</div><div class="bom-metric-value">${esc(String(nullTextRows.length))}</div></div>
          <div class="bom-metric"><div class="bom-metric-label">Low Confidence</div><div class="bom-metric-value">${esc(String(extractionSummary.low_confidence_count || lowConfidenceRows.length || 0))}</div></div>
        </div>
        <div class="repo-row repo-row--block">
          <div><strong>Path</strong> ${esc(props.path || '—')}</div>
          <div class="text-sm-subtle">Logical key ${esc(props.logical_key || '—')} · source ${esc(props.ingest_source || '—')} · last ingested ${esc(formatUnixTimestamp(props.last_ingested_at))}</div>
        </div>
        ${ingestSummary ? `<div class="repo-row repo-row--block"><div><strong>Last Ingest</strong> ${esc(String(ingestSummary.disposition || ''))}</div><div class="text-sm-subtle">seen ${esc(String(ingestSummary.requirements_seen || 0))} · added ${esc(String(ingestSummary.nodes_added || 0))} · updated ${esc(String(ingestSummary.nodes_updated || 0))} · deleted ${esc(String(ingestSummary.nodes_deleted || 0))} · unchanged ${esc(String(ingestSummary.unchanged || 0))}</div></div>` : ''}
        ${newIds.length ? `<div class="repo-row repo-row--block"><div><strong>New Since Last Ingest</strong></div><div class="text-sm-subtle">${newIds.map(id => `<span class="req-id">${esc(id)}</span>`).join(' ')}</div></div>` : ''}
        ${conflictRows.length ? `<div class="table-scroll mb-12"><table><thead><tr><th>Requirement</th><th>Other Artifact</th><th>Kind</th><th>Other Text</th></tr></thead><tbody>${conflictRows.map(item => `<tr><td><span class="req-id">${esc(item.req_id || '—')}</span></td><td>${esc(item.other_artifact_id || '—')}</td><td>${esc(formatDesignArtifactKind(item.other_source_kind || ''))}</td><td>${esc(item.other_text || '—')}</td></tr>`).join('')}</tbody></table></div>` : ''}
        ${nullTextRows.length ? `<div class="repo-row repo-row--block"><div><strong>Null Text Rows</strong></div><div class="text-sm-subtle">${nullTextRows.map(item => `<span class="req-id">${esc(item.req_id || '—')}</span>`).join(' ')}</div></div>` : ''}
        ${lowConfidenceRows.length ? `<div class="repo-row repo-row--block"><div><strong>Low Confidence Rows</strong></div><div class="text-sm-subtle">${lowConfidenceRows.map(item => `<span class="req-id">${esc(item.req_id || '—')}</span> (${esc(item.parse_status || '')})`).join(' · ')}</div></div>` : ''}
        ${assertions.length ? `<div class="table-scroll"><table>
          <thead>
            <tr>
              <th>Requirement</th>
              <th>Section</th>
              <th>Text</th>
              <th>Hash</th>
              <th>Status</th>
              <th>Occurrences</th>
            </tr>
          </thead>
          <tbody>
            ${assertions.map(item => `<tr>
              <td><span class="req-id">${esc(item.req_id || '—')}</span></td>
              <td>${esc(item.section || '—')}</td>
              <td>${esc(item.text || '—')}</td>
              <td>${esc(item.hash || '—')}</td>
              <td>${esc(item.parse_status || 'ok')}</td>
              <td>${esc(String(item.occurrence_count || 0))}</td>
            </tr>`).join('')}
          </tbody>
        </table></div>` : '<div class="empty-state">No extracted requirement assertions.</div>'}
      `;
    } catch (e) {
      detailEl.innerHTML = `<div class="empty-state">Failed to load design artifact detail: ${esc(e.message)}</div>`;
    }
  }

  async function uploadDesignArtifactFile(file) {
    const resultEl = document.getElementById('design-artifact-upload-result');
    const errEl = document.getElementById('design-artifacts-error');
    const kindEl = document.getElementById('design-artifact-kind');
    const displayNameEl = document.getElementById('design-artifact-display-name');
    if (!resultEl || !kindEl) return;
    if (errEl) errEl.style.display = 'none';
    resultEl.textContent = `Uploading ${file.name}…`;
    try {
      const token = await currentIngestToken();
      const formData = new FormData();
      formData.append('file', file, file.name);
      formData.append('kind', kindEl.value || 'srs_docx');
      if (displayNameEl?.value.trim()) formData.append('display_name', displayNameEl.value.trim());
      const res = await fetch('/api/v1/design-artifacts/upload', {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
        body: formData,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      resultEl.innerHTML = renderDesignArtifactUploadResult(data, file.name);
      await loadDesignArtifacts(true);
      if (data.artifact_id) {
        artifactState.selectedArtifactId = data.artifact_id;
        renderDesignArtifactList();
        await loadSelectedDesignArtifactDetail();
      }
    } catch (e) {
      resultEl.textContent = '';
      if (errEl) {
        errEl.textContent = 'Design artifact upload failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function renderDesignArtifactUploadResult(data, fallbackName) {
    return `<div class="repo-row repo-row--block">
      <div><strong>${esc(data.artifact_id || fallbackName || 'artifact')}</strong></div>
      <div class="text-sm-subtle">${esc(formatDesignArtifactKind(data.kind || ''))} · stored at ${esc(data.path || '—')}</div>
      ${data.ingest_summary ? `<div class="text-sm-subtle">seen ${esc(String(data.ingest_summary.requirements_seen || 0))} · conflicts ${esc(String(data.ingest_summary.conflicts_detected || 0))} · null text ${esc(String(data.ingest_summary.null_text_count || 0))} · low confidence ${esc(String(data.ingest_summary.low_confidence_count || 0))}</div>` : ''}
    </div>`;
  }

  async function reingestDesignArtifact(artifactId) {
    if (!artifactId) return;
    const errEl = document.getElementById('design-artifacts-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const token = await currentIngestToken();
      const res = await fetch(`/api/v1/design-artifacts/${encodeURIComponent(artifactId)}/reingest`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      artifactState.selectedArtifactId = artifactId;
      await loadDesignArtifacts();
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Re-ingest failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function formatDesignArtifactKind(kind) {
    if (kind === 'rtm_workbook') return 'RTM Workbook';
    if (kind === 'srs_docx') return 'SRS';
    if (kind === 'sysrd_docx') return 'SysRD / SRD';
    return kind || '—';
  }

  async function uploadBomArtifactFile(file) {
    const resultEl = document.getElementById('bom-upload-result');
    const errEl = document.getElementById('design-boms-error');
    if (!resultEl) return;
    if (errEl) errEl.style.display = 'none';
    resultEl.textContent = `Uploading ${file.name}…`;
    try {
      const token = await currentIngestToken();
      let res;
      if (file.name.toLowerCase().endsWith('.xlsx')) {
        const formData = new FormData();
        formData.append('file', file, file.name);
        res = await fetch('/api/v1/bom/xlsx', {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}` },
          body: formData,
        });
      } else {
        const body = await file.text();
        const contentType = file.name.toLowerCase().endsWith('.csv') ? 'text/csv' : 'application/json';
        res = await fetch('/api/v1/bom', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': contentType,
          },
          body,
        });
      }
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      resultEl.innerHTML = renderBomUploadResult(data);
      await loadDesignBomWorkspace(true);
    } catch (e) {
      resultEl.textContent = '';
      if (errEl) {
        errEl.textContent = 'BOM upload failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function uploadSoupArtifactFile(file) {
    const resultEl = document.getElementById('soup-upload-result');
    const errEl = document.getElementById('software-boms-error');
    if (!resultEl) return;
    if (errEl) errEl.style.display = 'none';
    resultEl.textContent = `Uploading ${file.name}…`;
    try {
      const token = await currentIngestToken();
      let res;
      if (file.name.toLowerCase().endsWith('.xlsx')) {
        const product = document.getElementById('soup-upload-product')?.value.trim() || soupState.selectedProduct || '';
        const bomName = document.getElementById('soup-upload-name')?.value.trim() || soupState.selectedBomName || 'SOUP Components';
        if (!product) throw new Error('Provide the product full_identifier for SOUP .xlsx uploads.');
        const formData = new FormData();
        formData.append('file', file, file.name);
        formData.append('full_product_identifier', product);
        if (bomName) formData.append('bom_name', bomName);
        res = await fetch('/api/v1/soup/xlsx', {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}` },
          body: formData,
        });
      } else {
        const body = await file.text();
        res = await fetch('/api/v1/soup', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body,
        });
      }
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      resultEl.innerHTML = renderSoupUploadResult(data);
      await loadSoupWorkspace(true);
    } catch (e) {
      resultEl.textContent = '';
      if (errEl) {
        errEl.textContent = 'SOUP upload failed: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  function renderBomUploadResult(data) {
    if (Array.isArray(data.groups)) {
      return data.groups.map(group => {
        const warningText = (group.warnings || []).map(w => w.code).join(', ');
        return `<div class="repo-row repo-row--block">
          <div><strong>${esc(group.full_product_identifier || '')}</strong> · ${esc(group.bom_name || '')}</div>
          <div class="text-sm-subtle">${esc(group.status || 'unknown')} · rows ${esc(String(group.rows_ingested || 0))} · nodes ${esc(String(group.inserted_nodes || 0))} · edges ${esc(String(group.inserted_edges || 0))}</div>
          <div class="text-sm-subtle">${group.error ? esc(`${group.error.code}: ${group.error.detail || ''}`) : (warningText ? esc(`warnings: ${warningText}`) : 'no warnings')}</div>
        </div>`;
      }).join('');
    }
    const warningText = (data.warnings || []).map(w => w.code).join(', ');
    return `<div class="repo-row repo-row--block">
      <div><strong>${esc(data.full_product_identifier || '')}</strong> · ${esc(data.bom_name || '')}</div>
      <div class="text-sm-subtle">nodes ${esc(String(data.inserted_nodes || 0))} · edges ${esc(String(data.inserted_edges || 0))}</div>
      <div class="text-sm-subtle">${warningText ? esc(`warnings: ${warningText}`) : 'no warnings'}</div>
    </div>`;
  }

  function renderSoupUploadResult(data) {
    const rowErrors = Array.isArray(data.row_errors) ? data.row_errors.map(err => `${err.code} row ${err.row}`).join(', ') : '';
    const warningText = (data.warnings || []).map(w => w.code).join(', ');
    return `<div class="repo-row repo-row--block">
      <div><strong>${esc(data.full_product_identifier || '')}</strong> · ${esc(data.bom_name || 'SOUP Components')}</div>
      <div class="text-sm-subtle">rows received ${esc(String(data.rows_received || 0))} · rows ingested ${esc(String(data.rows_ingested || 0))} · nodes ${esc(String(data.inserted_nodes || 0))} · edges ${esc(String(data.inserted_edges || 0))}</div>
      <div class="text-sm-subtle">${rowErrors ? esc(`row errors: ${rowErrors}`) : 'no row errors'}${warningText ? esc(` · warnings: ${warningText}`) : ''}</div>
    </div>`;
  }

  function renderTestResultsApiInfo(info, endpointEl, bomEndpointEl, tokenEl, inboxEl) {
    if (endpointEl) endpointEl.textContent = info.test_results_endpoint || 'unknown';
    if (bomEndpointEl) bomEndpointEl.textContent = info.bom_endpoint || 'unknown';
    if (tokenEl) tokenEl.textContent = info.test_results_token || 'unknown';
    if (inboxEl) inboxEl.textContent = info.inbox_dir || info.test_results_inbox_dir || 'unknown';
  }

  function copyTestResultsToken() {
    const value = document.getElementById('test-results-token')?.textContent;
    if (!value || value === 'Loading…' || value === '—') return;
    navigator.clipboard.writeText(value).catch(() => {});
  }

  async function regenerateTestResultsToken() {
    const errEl = document.getElementById('info-error');
    if (errEl) errEl.style.display = 'none';
    try {
      const res = await fetch('/api/v1/test-results/token/regenerate', { method: 'POST' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      await loadInfo();
    } catch (e) {
      if (errEl) {
        errEl.textContent = 'Failed to regenerate ingestion token: ' + e.message;
        errEl.style.display = 'block';
      }
    }
  }

  async function renderRequirements() {
    const errEl = document.getElementById('req-error');
    const tbody = document.getElementById('req-body');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="5" class="empty-state">Loading…</td></tr>';

    let rows;
    try {
      const res = await fetch('/query/rtm');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      rows = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load requirements: ' + e.message;
      errEl.style.display = 'block';
      tbody.innerHTML = '';
      return;
    }

    const summaries = new Map();
    for (const r of rows) {
      let summary = summaries.get(r.req_id);
      if (!summary) {
        summary = {
          req_id: r.req_id,
          statement: r.statement,
          status: r.status,
          user_need_id: r.user_need_id,
          suspect: !!r.suspect,
          test_group_ids: new Set(),
          test_ids: new Set(),
          hasEmptyTestGroup: false,
          hasConcreteTest: false,
          hasFail: false,
          hasNonPassConcreteResult: false,
        };
        summaries.set(r.req_id, summary);
      }
      if (r.user_need_id) summary.user_need_id = r.user_need_id;
      if (r.statement) summary.statement = r.statement;
      if (r.status) summary.status = r.status;
      if (r.suspect) summary.suspect = true;
      if (r.test_group_id) {
        summary.test_group_ids.add(r.test_group_id);
        if (!r.test_id) summary.hasEmptyTestGroup = true;
      }
      if (r.test_id) {
        summary.test_ids.add(r.test_id);
        summary.hasConcreteTest = true;
        if (r.result === 'FAIL') summary.hasFail = true;
        if (r.result !== 'PASS') summary.hasNonPassConcreteResult = true;
      }
    }
    const reqs = [...summaries.values()]
      .map(summary => {
        const test_group_ids = [...summary.test_group_ids].sort((a, b) => a.localeCompare(b));
        let aggregate_result = null;
        if (test_group_ids.length > 0) {
          if (summary.hasFail) {
            aggregate_result = 'FAIL';
          } else if (summary.hasConcreteTest && !summary.hasNonPassConcreteResult && !summary.hasEmptyTestGroup) {
            aggregate_result = 'PASS';
          } else {
            aggregate_result = 'PENDING';
          }
        }
        return {
          req_id: summary.req_id,
          statement: summary.statement,
          status: summary.status,
          user_need_id: summary.user_need_id,
          suspect: summary.suspect,
          test_group_ids,
          test_count: summary.test_ids.size,
          aggregate_result,
        };
      })
      .sort((a, b) => a.req_id.localeCompare(b.req_id));

    const issueCount = reqs.filter(r => rowSeverity(r) !== '').length;
    const badge = document.getElementById('gap-badge');
    badge.textContent = issueCount === 0 ? 'OK' : issueCount + ' issue' + (issueCount > 1 ? 's' : '');
    badge.className = 'badge' + (issueCount === 0 ? ' zero' : '');
    badge.style.display = 'inline-block';

    if (reqs.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" class="empty-state"><strong>No requirements</strong><br>Sync your Google Sheet or click Refresh.</td></tr>';
      return;
    }

    tbody.innerHTML = reqs.map(r => {
      const severity = rowSeverity(r);
      const rowClass = severity ? ` class="${severity}"` : '';
      const status = r.status || '—';
      const tgCell = r.test_group_ids.length > 0
        ? r.test_group_ids.map(tgId => `<span class="test-id">${esc(tgId)}</span>`).join(' ')
        : '<span class="result-missing">No Test</span>';
      const resultCell = resultBadge(r.aggregate_result, r.test_group_ids.length > 0);
      return `<tr${rowClass}>
        <td><button class="expand-btn" aria-label="Expand ${esc(r.req_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(r.req_id)}" data-colspan="5">${CHEVRON_SVG}</button><span class="req-id">${esc(r.req_id)}</span></td>
        <td>${esc(r.statement || '—')}</td>
        <td>${esc(status)}</td>
        <td>${tgCell}</td>
        <td>${resultCell}</td>
      </tr>`;
    }).join('');
  }

  async function renderUserNeeds() {
    const errEl = document.getElementById('un-error');
    const tbody = document.getElementById('un-body');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="4" class="empty-state">Loading…</td></tr>';
    let rows;
    try {
      const res = await fetch('/query/user-needs');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      rows = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load user needs: ' + e.message;
      errEl.style.display = 'block';
      tbody.innerHTML = '';
      return;
    }
    if (rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" class="empty-state"><strong>No user needs</strong><br>Check your sheet\'s User Needs tab.</td></tr>';
      return;
    }
    rows.sort((a, b) => a.id.localeCompare(b.id));
    tbody.innerHTML = rows.map(r => {
      const rowClass = r.suspect ? ' class="suspect"' : '';
      return `<tr${rowClass}>
        <td><button class="expand-btn" aria-label="Expand ${esc(r.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(r.id)}" data-colspan="4">${CHEVRON_SVG}</button><span class="req-id">${esc(r.id)}</span></td>
        <td>${esc(r.properties.statement || '—')}</td>
        <td>${esc(r.properties.source || '—')}</td>
        <td>${esc(r.properties.priority || '—')}</td>
      </tr>`;
    }).join('');
  }

  async function renderTests() {
    const errEl = document.getElementById('tests-error');
    const tbody = document.getElementById('tests-body');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="5" class="empty-state">Loading…</td></tr>';
    let rows;
    try {
      const res = await fetch('/query/tests');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      rows = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load tests: ' + e.message;
      errEl.style.display = 'block';
      tbody.innerHTML = '';
      return;
    }
    if (rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="5" class="empty-state"><strong>No tests</strong><br>Check your sheet\'s Tests tab.</td></tr>';
      return;
    }
    tbody.innerHTML = rows.map(r => {
      const rowClass = r.suspect ? ' class="suspect"' : '';
      const reqCell = (r.req_ids || []).length > 0
        ? r.req_ids.map(reqId => `<span class="req-id">${esc(reqId)}</span>`).join(' ')
        : '<span class="text-placeholder">—</span>';
      return `<tr${rowClass}>
        <td><button class="expand-btn" aria-label="Expand ${esc(r.test_id || r.test_group_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(r.test_id || r.test_group_id)}" data-colspan="5">${CHEVRON_SVG}</button><span class="test-id">${esc(r.test_group_id || '—')}</span></td>
        <td><span class="test-id">${esc(r.test_id || '—')}</span></td>
        <td>${esc(r.test_type || '—')}</td>
        <td>${esc(r.test_method || '—')}</td>
        <td>${reqCell}</td>
      </tr>`;
    }).join('');
  }

  async function renderRTM() {
    const errEl = document.getElementById('rtm-error');
    const tbody = document.getElementById('rtm-body');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="8" class="empty-state">Loading…</td></tr>';

    let rows;
    try {
      const res = await fetch('/query/rtm');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      rows = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load RTM: ' + e.message;
      errEl.style.display = 'block';
      tbody.innerHTML = '';
      return;
    }

    if (rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" class="empty-state"><strong>No RTM data</strong><br>Requirements and tests must both be loaded.</td></tr>';
      return;
    }

    tbody.innerHTML = rows.map(r => {
      const parentCell = r.user_need_id
        ? `<span class="test-id">${esc(r.user_need_id)}</span>`
        : '<span class="text-placeholder">—</span>';
      const tgCell = r.test_group_id
        ? `<span class="test-id">${esc(r.test_group_id)}</span>`
        : '<span class="result-missing">Untested</span>';
      const testCell = r.test_id ? `<span class="test-id">${esc(r.test_id)}</span>` : '';
      const resultCell = r.test_group_id ? resultBadge(r.result, true) : '';
      const severity = rowSeverity(r);
      const rowClass = r.suspect ? 'suspect' : (severity || '');
      return `<tr${rowClass ? ` class="${rowClass}"` : ''}>
        <td><button class="expand-btn" aria-label="Expand ${esc(r.req_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(r.req_id)}" data-colspan="8">${CHEVRON_SVG}</button><span class="req-id">${esc(r.req_id)}</span></td>
        <td>${parentCell}</td>
        <td>${esc(r.statement || '—')}</td>
        <td>${tgCell}</td>
        <td>${testCell}</td>
        <td>${esc(r.test_type || '')}</td>
        <td>${esc(r.test_method || '')}</td>
        <td>${resultCell}</td>
      </tr>`;
    }).join('');
  }

  async function renderRisks() {
    const errEl = document.getElementById('risks-error');
    const tbody = document.getElementById('risks-body');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="7" class="empty-state">Loading…</td></tr>';

    let rows;
    try {
      const res = await fetch('/query/risks');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      rows = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load risks: ' + e.message;
      errEl.style.display = 'block';
      tbody.innerHTML = '';
      return;
    }

    if (rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="empty-state"><strong>No risks</strong><br>Check your sheet\'s Risks tab.</td></tr>';
      return;
    }

    tbody.innerHTML = rows.map(r => {
      const initScore = (parseInt(r.initial_severity) || 0) * (parseInt(r.initial_likelihood) || 0);
      const scoreClass = s => s >= 12 ? 'result-fail' : s >= 6 ? 'result-missing' : '';
      const reqCell = r.req_id
        ? `<span class="test-id">${esc(r.req_id)}</span>`
        : '<span class="text-placeholder">—</span>';
      const rowClass = !r.req_id ? ' class="warning"' : '';
      return `<tr${rowClass}>
        <td><button class="expand-btn" aria-label="Expand ${esc(r.risk_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(r.risk_id)}" data-colspan="7">${CHEVRON_SVG}</button><span class="req-id">${esc(r.risk_id)}</span></td>
        <td>${esc(r.description || '—')}</td>
        <td class="text-center">${esc(r.initial_severity || '—')}</td>
        <td class="text-center">${esc(r.initial_likelihood || '—')}</td>
        <td class="text-center"><span class="${scoreClass(initScore)}">${initScore || '—'}</span></td>
        <td>${esc(r.mitigation || '—')}</td>
        <td>${reqCell}</td>
      </tr>`;
    }).join('');
  }

  // --- Helpers ---

  // error   = test result is FAIL
  // warning = gaps: no test linked or no parent user need
  // ""      = fully linked and passing
  function rowSeverity(r) {
    const result = r.aggregate_result || r.result;
    const hasTests = Array.isArray(r.test_group_ids) ? r.test_group_ids.length > 0 : !!r.test_group_id;
    if (result === 'FAIL') return 'error';
    if (!hasTests || !r.user_need_id) return 'warning';
    return '';
  }

  function resultBadge(result, hasTest) {
    if (!hasTest) return '';
    if (!result) return '<span class="result-pending">Pending</span>';
    if (result === 'PASS') return '<span class="result-pass">Pass</span>';
    if (result === 'FAIL') return '<span class="result-fail">Fail</span>';
    return `<span class="result-pending">${esc(result)}</span>`;
  }

  function esc(str) {
    if (str == null) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function propsObj(value) {
    if (!value) return {};
    if (typeof value === 'string') {
      try { return JSON.parse(value); } catch { return {}; }
    }
    return value;
  }

  function humanEdgeLabel(currentType, edge, dir) {
    const otherType = edge?.node?.type || '';
    const label = edge?.label || '';

    switch (label) {
      case 'DERIVES_FROM':
        if (currentType === 'UserNeed' && dir === 'in' && otherType === 'Requirement') return 'Derived Requirement';
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'UserNeed') return 'Source User Need';
        if (currentType === 'Requirement' && dir === 'in' && otherType === 'Requirement') return 'Child Requirement';
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'Requirement') return 'Parent Requirement';
        return 'Derivation Link';
      case 'REFINED_BY':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'Requirement') return 'Refined By Requirement';
        if (currentType === 'Requirement' && dir === 'in' && otherType === 'Requirement') return 'Refines Requirement';
        return 'Refinement Link';
      case 'TESTED_BY':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'TestGroup') return 'Verifying Test Group';
        if (currentType === 'TestGroup' && dir === 'in' && otherType === 'Requirement') return 'Verified Requirement';
        return 'Verification Link';
      case 'HAS_TEST':
        if (currentType === 'TestGroup' && dir === 'out' && otherType === 'Test') return 'Contained Test';
        if (currentType === 'Test' && dir === 'in' && otherType === 'TestGroup') return 'Parent Test Group';
        return 'Test Containment';
      case 'MITIGATED_BY':
        if (currentType === 'Requirement' && dir === 'in' && otherType === 'Risk') return 'Mitigates Risk';
        if (currentType === 'Risk' && dir === 'out' && otherType === 'Requirement') return 'Mitigated By Requirement';
        return 'Risk Mitigation Link';
      case 'ALLOCATED_TO':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'DesignInput') return 'Allocated Design Input';
        if (currentType === 'DesignInput' && dir === 'in' && otherType === 'Requirement') return 'Allocated Requirement';
        return 'Allocation Link';
      case 'SATISFIED_BY':
        if (currentType === 'DesignInput' && dir === 'out' && otherType === 'DesignOutput') return 'Satisfied By Design Output';
        if (currentType === 'DesignOutput' && dir === 'in' && otherType === 'DesignInput') return 'Satisfies Design Input';
        return 'Satisfaction Link';
      case 'CONTROLLED_BY':
        if (currentType === 'DesignOutput' && dir === 'out' && otherType === 'ConfigurationItem') return 'Controlled Configuration Item';
        if (currentType === 'ConfigurationItem' && dir === 'in' && otherType === 'DesignOutput') return 'Controls Design Output';
        return 'Configuration Control Link';
      case 'IMPLEMENTED_IN':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'SourceFile') return 'Implemented In Source File';
        if (currentType === 'SourceFile' && dir === 'in' && otherType === 'Requirement') return 'Implements Requirement';
        if (currentType === 'DesignOutput' && dir === 'out' && otherType === 'SourceFile') return 'Implemented In Source File';
        if (currentType === 'SourceFile' && dir === 'in' && otherType === 'DesignOutput') return 'Implements Design Output';
        return 'Implementation Link';
      case 'VERIFIED_BY_CODE':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'TestFile') return 'Verified By Test File';
        if (currentType === 'TestFile' && dir === 'in' && otherType === 'Requirement') return 'Verifies Requirement';
        if (currentType === 'SourceFile' && dir === 'out' && otherType === 'TestFile') return 'Verified By Test File';
        if (currentType === 'TestFile' && dir === 'in' && otherType === 'SourceFile') return 'Verifies Source File';
        return 'Code Verification Link';
      case 'ANNOTATED_AT':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'CodeAnnotation') return 'Code Annotation';
        if (currentType === 'CodeAnnotation' && dir === 'in' && otherType === 'Requirement') return 'Annotated Requirement';
        return 'Annotation Link';
      case 'CONTAINS':
        if ((currentType === 'SourceFile' || currentType === 'TestFile') && dir === 'out' && otherType === 'CodeAnnotation') return 'Contained Annotation';
        if (currentType === 'CodeAnnotation' && dir === 'in' && (otherType === 'SourceFile' || otherType === 'TestFile')) return 'Contained In File';
        return 'Containment Link';
      case 'COMMITTED_IN':
        if (currentType === 'Requirement' && dir === 'out' && otherType === 'Commit') return 'Implementing Commit';
        if (currentType === 'Commit' && dir === 'in' && otherType === 'Requirement') return 'Implements Requirement';
        return 'Commit Link';
      default:
        return label.replaceAll('_', ' ');
    }
  }

  function semanticEdgeDirection(currentType, edge, rawDir) {
    const relation = humanEdgeLabel(currentType, edge, rawDir);

    if (relation === 'Source User Need' || relation === 'Parent Requirement') {
      return 'up';
    }
    if (relation === 'Derived Requirement' || relation === 'Child Requirement') {
      return 'down';
    }

    return rawDir === 'out' ? 'down' : 'up';
  }

  function splitSemanticEdges(currentType, edgesOut, edgesIn) {
    const upstream = [];
    const downstream = [];

    for (const edge of edgesOut) {
      const item = { edge, rawDir: 'out' };
      (semanticEdgeDirection(currentType, edge, 'out') === 'up' ? upstream : downstream).push(item);
    }
    for (const edge of edgesIn) {
      const item = { edge, rawDir: 'in' };
      (semanticEdgeDirection(currentType, edge, 'in') === 'up' ? upstream : downstream).push(item);
    }

    return { upstream, downstream };
  }

  async function showLobby(mode = 'setup') {
    lobbyMode = mode;
    document.getElementById('lobby').classList.add('visible');
    _trapLobby();
    try {
      const status = await loadStatus(true);
      applyStatus(status);
      resetLobbyScreens(1);
      lobbyCurrentScreen = 1;
      if (mode === 'add') {
        lobbyState.sourceOfTruth = 'workbook_first';
      }
      if (lobbyState.sourceOfTruth) {
        selectSourceOfTruth(lobbyState.sourceOfTruth);
      } else {
        selectSourceOfTruth(mode === 'add' ? 'workbook_first' : null);
      }
      updateLobbyNav();
      return;
    } catch (_) {}
    resetLobbyScreens(1);
    lobbyCurrentScreen = 1;
    updateLobbyNav();
  }

  function clearProfileSelection() {
    lobbyState.profileId = null;
    document.querySelectorAll('.profile-row').forEach(row => {
      row.classList.remove('selected');
      row.setAttribute('aria-selected', 'false');
    });
  }

  function resetLobbyScreens(activeScreen) {
    document.querySelectorAll('.lobby-screen').forEach(screen => {
      screen.classList.remove('active', 'exit-fwd', 'exit-back', 'enter-back');
    });
    document.querySelector(`.lobby-screen[data-screen="${activeScreen}"]`)?.classList.add('active');
  }

  function connectionBlockMessage(status) {
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

  function updateLobbyConnectionMessage(status) {
    const errEl = document.getElementById('lobby-error');
    if (!errEl) return;
    const msg = connectionBlockMessage(status);
    if (!msg) return;
    errEl.textContent = msg;
    errEl.style.display = 'block';
  }

  function connectionErrorMessage(code, platform) {
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

  function licenseStateMessage(status) {
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

  function syncLicenseInfo(status) {
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

  function showLicenseGate(status, errorMessage = '') {
    licenseStatusCache = status || licenseStatusCache;
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
    gate.classList.add('visible');
    document.getElementById('license-import-btn')?.focus();
  }

  function hideLicenseGate() {
    document.getElementById('license-gate').classList.remove('visible');
  }

  async function loadLicenseStatus(force = false) {
    if (!force && licenseStatusCache) return licenseStatusCache;
    const res = await fetch('/api/license/status', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    licenseStatusCache = data.license || null;
    syncLicenseInfo(licenseStatusCache);
    return licenseStatusCache;
  }

  function chooseLicenseFile() {
    document.getElementById('license-file-input')?.click();
  }

  async function importLicenseFile(file) {
    const btn = document.getElementById('license-import-btn');
    if (!file) {
      showLicenseGate(licenseStatusCache, 'Please select a license.json file.');
      return;
    }

    btn.disabled = true;
    btn.textContent = 'Importing…';
    try {
      const licenseJson = await file.text();
      const res = await fetch('/api/license/import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ license_json: licenseJson }),
      });
      const data = await res.json().catch(() => ({}));
      const status = data.license || null;
      licenseStatusCache = status;
      syncLicenseInfo(status);
      if (!res.ok || !status || !status.permits_use) {
        showLicenseGate(status, status?.message || `License import failed (HTTP ${res.status})`);
        return;
      }
      hideLicenseGate();
      await refreshLicenseStatus();
    } catch (e) {
      showLicenseGate(licenseStatusCache, e.message);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Select License File';
      const input = document.getElementById('license-file-input');
      if (input) input.value = '';
    }
  }

  async function clearInstalledLicense() {
    if (!window.confirm('Clear the installed license on this machine?')) return;
    try {
      const res = await fetch('/api/license/clear', { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      const status = data.license || null;
      licenseStatusCache = status;
      syncLicenseInfo(status);
      showLicenseGate(status, status?.message || '');
    } catch (e) {
      showLicenseGate(licenseStatusCache, e.message);
    }
  }

  async function refreshLicenseStatus() {
    try {
      const status = await loadStatus(true);
      if (status.workspace_ready && document.getElementById('lobby').classList.contains('visible')) {
        showSuccess(status);
      } else if (status.workspace_ready) {
        await enterWorkspace(status);
      } else {
        hideLicenseGate();
      }
    } catch (e) {
      showLicenseGate(licenseStatusCache, e.message);
    }
  }

  document.getElementById('license-file-input')?.addEventListener('change', (event) => {
    const file = event.target?.files?.[0] || null;
    void importLicenseFile(file);
  });

  // --- Node drawer ---

  let _drawerHistory = [];
  let _drawerOpener = null;

  async function openNode(id) {
    _drawerOpener = document.activeElement;
    _drawerHistory = [id];
    await _renderDrawerNode(id);
    document.getElementById('node-drawer').classList.add('open');
    document.getElementById('drawer-overlay').classList.add('visible');
    document.getElementById('drawer-content')?.focus();
  }

  async function drawerNav(id) {
    _drawerHistory.push(id);
    await _renderDrawerNode(id);
  }

  async function drawerBack() {
    if (_drawerHistory.length <= 1) return;
    _drawerHistory.pop();
    await _renderDrawerNode(_drawerHistory[_drawerHistory.length - 1]);
  }

  function closeDrawer() {
    document.getElementById('node-drawer').classList.remove('open');
    document.getElementById('drawer-overlay').classList.remove('visible');
    _drawerHistory = [];
    _drawerOpener?.focus();
    _drawerOpener = null;
  }

  async function _renderDrawerNode(id) {
    const content = document.getElementById('drawer-content');
    const backBtn = document.getElementById('drawer-back');
    backBtn.disabled = _drawerHistory.length <= 1;
    content.innerHTML = '<div class="empty-state">Loading…</div>';

    let data;
    try {
      const res = await fetch('/query/node/' + encodeURIComponent(id));
      if (!res.ok) throw new Error('HTTP ' + res.status);
      data = await res.json();
    } catch (e) {
      content.innerHTML = '<div class="empty-state">Error: ' + esc(e.message) + '</div>';
      return;
    }

    try {
      const { node, edges_out, edges_in } = data;
      if (!node || !Array.isArray(edges_out) || !Array.isArray(edges_in)) {
        content.innerHTML = '<div class="empty-state">Error: invalid node payload</div>';
        console.error('invalid node payload', data);
        return;
      }

      const props = Object.entries(propsObj(node.properties))
        .filter(([, v]) => v !== '' && v != null)
        .map(([k, v]) => `<div class="prop-row">
          <span class="prop-key">${esc(k)}</span>
          <span class="prop-val">${esc(String(v))}</span>
        </div>`).join('');

      const { upstream, downstream } = splitSemanticEdges(node.type, edges_out, edges_in);

      const edgeRows = (items) => items.length
        ? items.map(({ edge: e, rawDir }) => {
            if (!e || !e.node || !e.node.id || !e.node.type) {
              throw new Error('invalid edge payload');
            }
            const label = humanEdgeLabel(node.type, e, rawDir);
            return `<div class="edge-row" data-action="drawer-nav" data-id="${esc(e.node.id)}">
              <span class="edge-label">${esc(label)}</span>
              <span class="node-id-link">${esc(e.node.id)}</span>
              <span class="node-type-badge">${esc(e.node.type)}</span>
            </div>`;
          }).join('')
        : '<div class="edge-empty">None</div>';

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
        <div class="edge-section">
          <div class="edge-section-title">Downstream (${downstream.length})</div>
          ${edgeRows(downstream)}
        </div>
        <div class="edge-section">
          <div class="edge-section-title">Upstream (${upstream.length})</div>
          ${edgeRows(upstream)}
        </div>`;
    } catch (e) {
      console.error('drawer render failure', e, data);
      content.innerHTML = '<div class="empty-state">Error: render failure: ' + esc(e.message) + '</div>';
    }
  }

  async function clearSuspect(id) {
    await fetch('/suspect/' + encodeURIComponent(id) + '/clear', {method: 'POST'});
    await _renderDrawerNode(id);
    loadData();
    if (document.getElementById('tab-review').classList.contains('active')) loadSuspects();
  }

  // --- Inline row expansion ---

  const _expanded = new Map();

  async function toggleRow(id, btn, colspan) {
    if (_expanded.has(id)) {
      _expanded.get(id).remove();
      _expanded.delete(id);
      btn.classList.remove('open');
      btn.setAttribute('aria-expanded', 'false');
      return;
    }
    btn.classList.add('open');
    btn.setAttribute('aria-expanded', 'true');

    const detailTr = document.createElement('tr');
    detailTr.className = 'detail-row';
    detailTr.innerHTML = `<td colspan="${colspan}"><div class="detail-inner"><span class="text-hint">Loading…</span></div></td>`;
    btn.closest('tr').after(detailTr);
    _expanded.set(id, detailTr);

    const inner = detailTr.querySelector('.detail-inner');
    await _fillNodeDetail(inner, id, false);
  }

  async function _fillNodeDetail(container, id, showProps = true) {
    let data;
    try {
      const res = await fetch('/query/node/' + encodeURIComponent(id));
      if (!res.ok) throw new Error('HTTP ' + res.status);
      data = await res.json();
    } catch (e) {
      container.innerHTML = `<span class="text-error-inline">Error: ${esc(e.message)}</span>`;
      return;
    }

    try {
      const { node, edges_out, edges_in } = data;
      if (!node || !Array.isArray(edges_out) || !Array.isArray(edges_in)) {
        container.innerHTML = '<span class="text-error-inline">Error: invalid node payload</span>';
        console.error('invalid node payload', data);
        return;
      }

      const props = Object.entries(propsObj(node.properties))
        .filter(([, v]) => v !== '' && v != null)
        .map(([k, v]) => `<div class="dp-row">
          <span class="dp-key">${esc(k)}</span>
          <span class="dp-val">${esc(String(v))}</span>
        </div>`).join('') || '';

      const suspect = node.suspect ? `
        <div class="di-suspect">
          <span><strong>SUSPECT</strong>${node.suspect_reason ? ' — ' + esc(node.suspect_reason) : ''}</span>
          <button data-action="clear-suspect" data-id="${esc(node.id)}">Mark Reviewed</button>
        </div>` : '';

      const { upstream, downstream } = splitSemanticEdges(node.type, edges_out, edges_in);

      container.innerHTML = `
        ${suspect}
        ${showProps ? `<div class="detail-props">${props}</div>` : ''}
        <div class="tree-sections">
          ${_treeSection(node.type, 'Downstream', downstream)}
          ${_treeSection(node.type, 'Upstream', upstream)}
        </div>`;
    } catch (e) {
      console.error('inline detail render failure', e, data);
      container.innerHTML = `<span class="text-error-inline">Error: render failure: ${esc(e.message)}</span>`;
    }
  }

  function _treeSection(currentType, label, edges) {
    const items = edges.map(({ edge, rawDir }) => _treeNodeHtml(currentType, edge, rawDir)).join('');
    return `
      <div class="tree-section">
        <div class="tree-section-header" data-action="toggle-tree-section">
          <button class="expand-btn" aria-label="Expand ${label}" aria-expanded="false">${CHEVRON_SVG}</button>
          <span class="tree-section-label">${label}</span>
          <span class="tree-count">${edges.length}</span>
        </div>
        <div class="tree-section-body" style="display:none">
          ${items || '<div class="de-none">—</div>'}
        </div>
      </div>`;
  }

  function _treeNodeHtml(currentType, e, dir) {
    const relation = humanEdgeLabel(currentType, e, dir);
    return `
      <div class="tree-node">
        <div class="tree-node-header">
          <button class="expand-btn" aria-label="Expand ${esc(e.node.id)}" aria-expanded="false" data-action="toggle-tree-node" data-id="${esc(e.node.id)}">${CHEVRON_SVG}</button>
          <span class="tree-edge-label">${esc(relation)}</span>
          <span class="tree-node-id">${esc(e.node.id)}</span>
          <span class="node-type-badge">${esc(e.node.type)}</span>
        </div>
        <div class="tree-node-body" style="display:none"></div>
      </div>`;
  }

  function toggleTreeSection(header) {
    const body = header.nextElementSibling;
    const btn = header.querySelector('.expand-btn');
    const opening = body.style.display === 'none';
    body.style.display = opening ? '' : 'none';
    btn.classList.toggle('open', opening);
    btn.setAttribute('aria-expanded', String(opening));
  }

  async function toggleTreeNode(btn, id) {
    const header = btn.closest('.tree-node-header');
    const body = header.nextElementSibling;
    const opening = body.style.display === 'none';
    body.style.display = opening ? '' : 'none';
    btn.classList.toggle('open', opening);
    btn.setAttribute('aria-expanded', String(opening));
    if (opening && !body.dataset.loaded) {
      body.dataset.loaded = '1';
      body.innerHTML = '<span class="text-hint">Loading…</span>';
      await _fillNodeDetail(body, id);
      // Auto-expand OUT and IN sections for nested nodes
      body.querySelectorAll('.tree-section-body').forEach(sec => {
        sec.style.display = '';
        const innerBtn = sec.previousElementSibling.querySelector('.expand-btn');
        if (innerBtn) { innerBtn.classList.add('open'); innerBtn.setAttribute('aria-expanded', 'true'); }
      });
    }
  }

  function _closeAllExpanded() {
    _expanded.forEach(tr => tr.remove());
    _expanded.clear();
  }

  // --- Impact analysis ---

  async function runImpact() {
    const id = document.getElementById('impact-input').value.trim();
    const errEl = document.getElementById('impact-error');
    const result = document.getElementById('impact-result');
    errEl.style.display = 'none';
    if (!id) return;
    result.innerHTML = '<div class="empty-state loading-pulse">Analyzing…</div>';

    let data;
    try {
      const url = new URL('/query/impact/' + encodeURIComponent(id), window.location.origin).toString();
      const res = await fetch(url, { cache: 'no-store' });
      if (res.status === 404) throw new Error(`Node "${id}" not found`);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      data = await res.json();
    } catch (e) {
      errEl.textContent = e.message;
      errEl.style.display = 'block';
      result.innerHTML = '';
      return;
    }

    if (data.length === 0) {
      result.innerHTML = '<div class="empty-state"><strong>No downstream impact</strong><br>Nothing depends on this node via traced edges.</div>';
      return;
    }

    result.innerHTML = `
      <p class="text-sm-muted mb-12">
        Changing <strong>${esc(id)}</strong> would affect <strong>${data.length}</strong> node${data.length === 1 ? '' : 's'}:
      </p>
      <div class="card">
        <table>
          <thead><tr><th>Node ID</th><th>Type</th><th>Via</th></tr></thead>
          <tbody>
            ${data.map(n => `<tr>
              <td><button class="expand-btn" aria-label="Expand ${esc(n.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(n.id)}" data-colspan="3">${CHEVRON_SVG}</button><span class="req-id">${esc(n.id)}</span></td>
              <td><span class="node-type-badge">${esc(n.type)}</span></td>
              <td><span class="tree-edge-label">${esc(n.dir)} ${esc(n.via)}</span></td>
            </tr>`).join('')}
          </tbody>
        </table>
      </div>`;
  }

  // --- Suspects / Review ---

  async function loadSuspects() {
    const errEl = document.getElementById('review-error');
    const result = document.getElementById('review-result');
    errEl.style.display = 'none';
    result.innerHTML = '<div class="empty-state loading-pulse">Loading…</div>';

    let data;
    try {
      const res = await fetch('/query/suspects');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      data = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load: ' + e.message;
      errEl.style.display = 'block';
      return;
    }

    _updateSuspectBadge(data.length);

    if (data.length === 0) {
      result.innerHTML = '<div class="empty-state"><strong>All clear</strong><br>No nodes flagged for review.</div>';
      return;
    }

    result.innerHTML = `
      <div class="card">
        <table>
          <thead><tr><th>Node ID</th><th>Type</th><th>Reason</th><th></th></tr></thead>
          <tbody>
            ${data.map(n => `<tr class="suspect">
              <td><button class="expand-btn" aria-label="Expand ${esc(n.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(n.id)}" data-colspan="4">${CHEVRON_SVG}</button><span class="req-id">${esc(n.id)}</span></td>
              <td><span class="node-type-badge">${esc(n.type)}</span></td>
              <td class="text-suspect">${esc(n.suspect_reason || '')}</td>
              <td><button class="suspect-clear" data-action="clear-suspect" data-id="${esc(n.id)}">Mark Reviewed</button></td>
            </tr>`).join('')}
          </tbody>
        </table>
      </div>`;
  }

  function _updateSuspectBadge(count) {
    const headerBadge = document.getElementById('suspect-header-badge');
    const navBadge = document.getElementById('suspect-nav-badge');
    const groupBadge = document.getElementById('suspect-group-badge');
    const prevCount = navBadge.dataset.count ? Number(navBadge.dataset.count) : -1;
    if (count > 0) {
      const label = count + ' suspect';
      headerBadge.textContent = '⚠ ' + label;
      headerBadge.style.display = 'inline';
      navBadge.textContent = count;
      navBadge.dataset.count = count;
      navBadge.style.display = 'inline';
      if (groupBadge) {
        groupBadge.textContent = count;
        groupBadge.className = navBadge.className;
        groupBadge.style.display = 'inline';
      }
      if (prevCount !== count) {
        [navBadge, headerBadge, groupBadge].forEach(el => {
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

  async function refreshSuspectBadge() {
    try {
      const res = await fetch('/query/suspects');
      const data = await res.json();
      _updateSuspectBadge(data.length);
    } catch (_) {}
  }

  // --- Lobby ---

  const lobbyState = {
    profileId: null,
    sourceOfTruth: null,
    provider: 'google',
    googleCredentialJson: '',
    googleCredentialEmail: '',
    excelTenantId: '',
    excelClientId: '',
    excelClientSecret: '',
    workbookUrl: '',
    sourceArtifactFileName: '',
    sourceArtifactKind: '',
  };

  let lobbyCurrentScreen = 1;
  let lobbyMode = 'setup';

  const LOBBY_PROFILES = [
    { id:'aerospace',  backendId:'aerospace', label:'Aerospace',                    standards:'DO-178C · AS9100D',                      tagline:'Authorize your DO-178C traceability instrument' },
    { id:'automotive', backendId:'automotive', label:'Automotive',                  standards:'ISO 26262 · ASPICE',                     tagline:'Authorize your ISO 26262 / ASPICE workspace' },
    { id:'defense',    backendId:'aerospace',  label:'Defense',                     standards:'DO-178C · MIL-STD-882 · DEF STAN 00-56', tagline:'Authorize your defense safety workspace' },
    { id:'industrial', backendId:'generic',    label:'Industrial Automation',       standards:'IEC 61511 · IEC 62443',                  tagline:'Authorize your functional safety workspace' },
    { id:'maritime',   backendId:'generic',    label:'Maritime & Offshore',         standards:'DNV GL · IEC 61508',                     tagline:'Authorize your maritime safety workspace' },
    { id:'medical',    backendId:'medical',    label:'Medical Device',              standards:'ISO 13485 · IEC 62304 · FDA 21 CFR Part 11', tagline:'Authorize your IEC 62304 / ISO 13485 workspace' },
    { id:'nuclear',    backendId:'generic',    label:'Nuclear',                     standards:'IEC 61513 · IEEE 603',                   tagline:'Authorize your nuclear I&C traceability workspace' },
    { id:'rail',       backendId:'generic',    label:'Rail',                        standards:'EN 50128 · EN 50129',                    tagline:'Authorize your EN 50128 workspace' },
    { id:'samd',       backendId:'medical',    label:'Software as a Medical Device',standards:'IEC 62304 · FDA SaMD · IMDRF',            tagline:'Authorize your FDA SaMD workspace' },
    { id:'space',      backendId:'aerospace',  label:'Space',                       standards:'ECSS · NASA-STD-8739',                   tagline:'Authorize your ECSS / NASA workspace' },
  ];

  const PROFILE_ICONS = {
    aerospace:  '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16l-9-13-9 13h4l5-7 5 7z"/><path d="M3 16h18"/></svg>',
    automotive: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><line x1="12" y1="3" x2="12" y2="9"/><line x1="12" y1="15" x2="12" y2="21"/><line x1="3" y1="12" x2="9" y2="12"/><line x1="15" y1="12" x2="21" y2="12"/></svg>',
    defense:    '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6l7-3z"/></svg>',
    industrial: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.07 4.93a10 10 0 010 14.14M4.93 4.93a10 10 0 000 14.14M12 2v2M12 20v2M2 12h2M20 12h2"/></svg>',
    maritime:   '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="5" r="2"/><line x1="12" y1="7" x2="12" y2="14"/><path d="M7 14c0 3 2.5 5 5 6 2.5-1 5-3 5-6H7z"/><line x1="7" y1="11" x2="17" y2="11"/></svg>',
    medical:    '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3H5a2 2 0 00-2 2v3m18 0V5a2 2 0 00-2-2h-3M3 16v3a2 2 0 002 2h3m8 0h3a2 2 0 002-2v-3M9 12h6M12 9v6"/></svg>',
    nuclear:    '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="2"/><path d="M12 2a10 10 0 100 20A10 10 0 0012 2z" stroke-dasharray="3 3"/><path d="M12 4v4M12 16v4M4 12h4M16 12h4"/></svg>',
    rail:       '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="13" rx="2"/><circle cx="8.5" cy="13.5" r="1.5"/><circle cx="15.5" cy="13.5" r="1.5"/><path d="M8 20l-2 2M16 20l2 2M5 20h14"/><line x1="4" y1="8" x2="20" y2="8"/></svg>',
    samd:       '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="13" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/><path d="M10 10h4M12 8v4"/></svg>',
    space:      '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2C8 2 5 7 5 12c0 2.5 1 5 3 7l4-4 4 4c2-2 3-4.5 3-7 0-5-3-10-7-10z"/><circle cx="12" cy="11" r="2"/><path d="M5 19l-2 2M19 19l2 2"/></svg>',
  };

  function renderProfileList() {
    const list = document.getElementById('profile-list');
    list.innerHTML = LOBBY_PROFILES.map(p => `
      <div class="profile-row${p.id === lobbyState.profileId ? ' selected' : ''}" data-action="select-profile" data-profile-id="${p.id}" role="option" aria-selected="${p.id === lobbyState.profileId}" tabindex="0">
        <span class="profile-row-icon">${PROFILE_ICONS[p.id]}</span>
        <span class="profile-row-name">${p.label}</span>
        <span class="profile-row-check"><svg width="10" height="8" viewBox="0 0 10 8" fill="none"><polyline points="1,4 4,7 9,1" stroke="white" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></span>
      </div>`).join('');
  }

  function selectProfile(id) {
    lobbyState.profileId = id;
    document.querySelectorAll('.profile-row').forEach(row => {
      const isSelected = row.dataset.profileId === id;
      row.classList.toggle('selected', isSelected);
      row.setAttribute('aria-selected', isSelected);
    });
  }

  function selectProvider(provider) {
    lobbyState.provider = provider;
    const googleTile = document.getElementById('tile-google');
    const excelTile = document.getElementById('tile-excel');
    const localTile = document.getElementById('tile-local');
    const googlePanel = document.getElementById('s3-google');
    const excelPanel = document.getElementById('s3-excel');
    const localPanel = document.getElementById('s3-local');
    const urlInput = document.getElementById('lobby-url');
    const urlWrap = document.getElementById('lobby-url-wrap');
    if (googleTile) googleTile.classList.toggle('selected', provider === 'google');
    if (excelTile) excelTile.classList.toggle('selected', provider === 'excel');
    if (localTile) localTile.classList.toggle('selected', provider === 'local');
    if (googlePanel) googlePanel.style.display = provider === 'google' ? '' : 'none';
    if (excelPanel) excelPanel.style.display = provider === 'excel' ? '' : 'none';
    if (localPanel) localPanel.style.display = provider === 'local' ? '' : 'none';
    if (urlWrap) urlWrap.style.display = provider === 'local' ? 'none' : '';
    if (urlInput) {
      urlInput.placeholder = provider === 'excel'
        ? 'https://tenant.sharepoint.com/:x:/r/sites/…'
        : 'https://docs.google.com/spreadsheets/d/…';
    }
    const localName = document.getElementById('local-db-name');
    if (localName) {
      localName.textContent = currentStatus?.active_workbook?.display_name || 'Current workspace database';
    }
  }

  function selectSourceOfTruth(source) {
    lobbyState.sourceOfTruth = source;
    const docTile = document.getElementById('tile-document-source');
    const workbookTile = document.getElementById('tile-workbook-source');
    if (docTile) docTile.classList.toggle('selected', source === 'document_first');
    if (workbookTile) workbookTile.classList.toggle('selected', source === 'workbook_first');
    const uploadPanel = document.getElementById('source-upload-panel');
    if (uploadPanel) uploadPanel.style.display = source === 'document_first' ? '' : 'none';
    if (lobbyMode === 'add') {
      document.getElementById('source-screen-headline').textContent = 'Connect another workbook';
      document.getElementById('source-tiles')?.classList.add('provider-tiles-single');
      if (docTile) docTile.style.display = 'none';
      if (workbookTile) workbookTile.style.display = '';
    } else {
      document.getElementById('source-screen-headline').textContent = 'What is your source of truth?';
      document.getElementById('source-tiles')?.classList.remove('provider-tiles-single');
      if (docTile) docTile.style.display = '';
      if (workbookTile) workbookTile.style.display = '';
    }
  }

  function visibleLobbyScreens() {
    if (lobbyMode === 'add') return [1, 3, 4];
    if (lobbyState.sourceOfTruth === 'document_first') return [1, 2, 4];
    return [1, 2, 3, 4];
  }

  function renderLobbyDots() {
    const dots = document.getElementById('lobby-dots');
    const screens = visibleLobbyScreens();
    dots.innerHTML = screens.map((screen) => `<div class="lobby-dot${screen === lobbyCurrentScreen ? ' active' : ''}" data-dot="${screen}"></div>`).join('');
    dots.style.visibility = lobbyCurrentScreen === 5 ? 'hidden' : '';
    document.getElementById('lobby-screen-label-1').textContent = `Step 1 of ${screens.length}`;
    document.getElementById('lobby-screen-label-2').textContent = `Step ${Math.max(2, screens.indexOf(2) + 1 || 2)} of ${screens.length}`;
    document.getElementById('lobby-screen-label-3').textContent = `Step ${screens.indexOf(3) + 1} of ${screens.length}`;
    document.getElementById('lobby-screen-label-4').textContent = `Step ${screens.indexOf(4) + 1} of ${screens.length}`;
  }

  function showScreen(n, direction) {
    if (direction === undefined) direction = 'forward';
    const prev = document.querySelector(`.lobby-screen[data-screen="${lobbyCurrentScreen}"]`);
    const next = document.querySelector(`.lobby-screen[data-screen="${n}"]`);
    const exitClass = direction === 'forward' ? 'exit-fwd' : 'exit-back';
    const enterClass = direction === 'back' ? 'enter-back' : '';

    prev.classList.add(exitClass);
    prev.addEventListener('animationend', function handler() {
      prev.removeEventListener('animationend', handler);
      prev.classList.remove('active', exitClass);
      next.classList.add('active');
      if (enterClass) {
        next.classList.add(enterClass);
        next.addEventListener('animationend', function h2() {
          next.removeEventListener('animationend', h2);
          next.classList.remove(enterClass);
        });
      }
    });

    lobbyCurrentScreen = n;
    updateLobbyNav();
    if (n === 4) renderLicenseStep();
  }

  function updateLobbyNav() {
    const backBtn = document.getElementById('lobby-back-btn');
    const onSuccess = lobbyCurrentScreen === 5;
    backBtn.classList.toggle('visible', visibleLobbyScreens()[0] !== lobbyCurrentScreen && !onSuccess);
    renderLobbyDots();
  }

  async function persistLobbyProfileSelection() {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId);
    if (!profile) throw new Error('Select a profile to continue.');
    const res = await fetch('/api/profile', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ profile: profile.backendId }),
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `HTTP ${res.status}`);
    }
  }

  async function lobbyNext(fromScreen) {
    const errEl = document.getElementById('lobby-error');
    errEl.style.display = 'none';
    if (fromScreen === 1) {
      if (!lobbyState.profileId) {
        errEl.textContent = 'Select a profile to continue.';
        errEl.style.display = 'block';
        return;
      }
      try {
        await persistLobbyProfileSelection();
      } catch (err) {
        errEl.textContent = 'Failed to save profile: ' + (err.message || err);
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

  function lobbyBack() {
    const screens = visibleLobbyScreens();
    const idx = screens.indexOf(lobbyCurrentScreen);
    if (idx > 0) showScreen(screens[idx - 1], 'back');
  }

  function lobbyStateFromInputs() {
    const workbookUrl = document.getElementById('lobby-url').value.trim();
    lobbyState.workbookUrl = workbookUrl;
    if (lobbyState.provider === 'excel') {
      lobbyState.excelTenantId = document.getElementById('excel-tenant-id').value.trim();
      lobbyState.excelClientId = document.getElementById('excel-client-id').value.trim();
      lobbyState.excelClientSecret = document.getElementById('excel-client-secret').value.trim();
    }
  }

  function toggleSecretVisibility() {
    const input = document.getElementById('excel-client-secret');
    const eye   = document.getElementById('secret-eye');
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

  function showSuccess(status = currentStatus || {}) {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId) || { label: '—', standards: '—' };
    const sourceLabel = status.source_of_truth === 'document_first'
      ? 'Requirements Artifact'
      : `${lobbyState.provider === 'google'
          ? 'Google Sheets'
          : (lobbyState.provider === 'local' ? 'Local DB' : 'Excel Online')} Workbook`;
    document.getElementById('success-title').textContent = status.hobbled_mode ? 'Preview workspace ready.' : 'Workspace ready.';
    document.getElementById('success-sub').textContent = `${profile.label} · ${sourceLabel}`;
    document.getElementById('success-detail').innerHTML = `
      <div class="success-detail-row"><span class="success-detail-key">Standard</span><span class="success-detail-val">${esc(profile.standards)}</span></div>
      <div class="success-detail-row"><span class="success-detail-key">Source</span><span class="success-detail-val">${esc(sourceLabel)}</span></div>
      <div class="success-detail-row"><span class="success-detail-key">Mode</span><span class="success-detail-val">${status.hobbled_mode ? 'Preview mode' : 'Licensed mode'}</span></div>`;
    showScreen(5, 'forward');
  }

  async function enterWorkspace(status = null) {
    if (!status) status = currentStatus || await loadStatus(true);
    hideLicenseGate();
    document.getElementById('lobby').classList.remove('visible');
    _releaseLobby();
    syncPreviewUi(status);
    await loadWorkbooksState();
    await loadData();
    const pendingTab = sessionStorage.getItem(PENDING_WORKSPACE_TAB_KEY);
    if (pendingTab && !window.location.hash.startsWith('#guide-code-')) {
      sessionStorage.removeItem(PENDING_WORKSPACE_TAB_KEY);
      showTab(pendingTab);
    }
    await handleGuideHash();
  }

  async function openWorkspace() {
    const status = await loadStatus(true).catch(() => currentStatus || {});
    document.getElementById('lobby').classList.remove('visible');
    _releaseLobby();
    syncPreviewUi(status);
    await loadWorkbooksState();
    await loadData();
    const pendingTab = sessionStorage.getItem(PENDING_WORKSPACE_TAB_KEY);
    if (pendingTab && !window.location.hash.startsWith('#guide-code-')) {
      sessionStorage.removeItem(PENDING_WORKSPACE_TAB_KEY);
      showTab(pendingTab);
    }
    await handleGuideHash();
  }

  function openAddWorkbook() {
    showSettingsTab('workbooks');
    void showLobby('add');
  }

  function clearCredential() {
    lobbyState.googleCredentialJson = '';
    lobbyState.googleCredentialEmail = '';
    document.getElementById('sa-upload-zone').style.display = '';
    document.getElementById('sa-loaded-chip').style.display = 'none';
    document.getElementById('lobby-share-hint').style.display = 'none';
  }

  function clearSourceArtifact() {
    lobbyState.sourceArtifactFileName = '';
    lobbyState.sourceArtifactKind = '';
    document.getElementById('source-upload-chip').classList.remove('visible');
    document.getElementById('source-artifact-zone').style.display = '';
  }

  function _trapLobby() {
    document.querySelector('main').inert = true;
    document.querySelector('header').inert = true;
    document.getElementById('preview-banner')?.classList.remove('visible');
    document.getElementById('attach-workbook-prompt')?.classList.remove('visible');
    document.querySelector('nav.nav-primary').inert = true;
    document.querySelectorAll('.nav-sub').forEach(n => { n.inert = true; });
    const first = document.querySelector('#lobby .profile-row');
    if (first) first.focus();
  }

  function _releaseLobby() {
    document.querySelector('main').inert = false;
    document.querySelector('header').inert = false;
    document.querySelector('nav.nav-primary').inert = false;
    document.querySelectorAll('.nav-sub').forEach(n => { n.inert = false; });
  }

  const PROFILE_DESCRIPTIONS = {
    generic: 'Basic requirements traceability',
    medical: 'ISO 13485 / IEC 62304 / FDA 21 CFR Part 11',
    aerospace: 'DO-178C / AS9100',
    automotive: 'ISO 26262 / ASPICE',
  };

  function applyStatus(status) {
    currentStatus = status || null;
    licenseStatusCache = status?.license || null;
    syncLicenseInfo(licenseStatusCache);
    syncPreviewUi(status || {});
    if (status?.platform) {
      lobbyState.provider = status.platform;
      selectProvider(status.platform);
    } else if (status?.source_of_truth === 'workbook_first') {
      lobbyState.provider = 'local';
      selectProvider('local');
    } else {
      selectProvider(lobbyState.provider || 'google');
    }
    if (status?.workbook_url) {
      lobbyState.workbookUrl = status.workbook_url;
      document.getElementById('lobby-url').value = status.workbook_url;
    }
    if (status?.platform === 'google' && status?.credential_display) {
      lobbyState.googleCredentialEmail = status.credential_display;
      document.getElementById('sa-loaded-email').textContent = status.credential_display;
      document.getElementById('sa-upload-zone').style.display = 'none';
      document.getElementById('sa-loaded-chip').style.display = '';
      document.getElementById('lobby-share-hint').style.display = 'block';
    }
    if (status?.profile) {
      const backendToUi = { medical: 'medical', aerospace: 'aerospace', automotive: 'automotive', generic: null };
      const uiId = backendToUi[status.profile] ?? null;
      if (uiId) selectProfile(uiId);
      else clearProfileSelection();
    } else {
      clearProfileSelection();
    }
    if (status?.source_of_truth) {
      lobbyState.sourceOfTruth = status.source_of_truth;
    }
    updateLobbyConnectionMessage(status);
  }

  async function loadStatus(force = false) {
    const res = await fetch('/api/status', { cache: force ? 'no-store' : 'default' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const status = await res.json();
    applyStatus(status);
    return status;
  }

  function syncPreviewUi(status) {
    const preview = document.getElementById('preview-banner');
    const prompt = document.getElementById('attach-workbook-prompt');
    const locked = status.license_required_features || [];
    if (preview) {
      preview.classList.toggle('visible', Boolean(status.hobbled_mode));
      document.getElementById('preview-banner-sub').textContent = status.hobbled_mode
        ? `Locked in preview: ${locked.join(', ') || 'Reports, MCP, repository scanning, code traceability, and background sync'}.`
        : 'Licensed features are active.';
    }
    if (prompt) {
      const showPrompt = status.source_of_truth === 'document_first' &&
        !status.connection_configured &&
        !status.attach_workbook_prompt_dismissed &&
        !document.getElementById('lobby').classList.contains('visible');
      prompt.classList.toggle('visible', Boolean(showPrompt));
    }

    const restricted = Boolean(status.hobbled_mode);
    document.querySelectorAll('button[data-group="code"], button[data-group="reports"], .nav-sub [data-tab="mcp-ai"]').forEach((btn) => {
      btn.disabled = restricted;
      btn.title = restricted ? 'Requires a license' : '';
    });
    if (restricted && (document.getElementById('tab-code').classList.contains('active') || document.getElementById('tab-reports').classList.contains('active') || document.getElementById('tab-mcp-ai').classList.contains('active'))) {
      showGroup('data');
    }
  }

  function showPreviewFeatureHelp() {
    const locked = (currentStatus?.license_required_features || []).join(', ') || 'Reports, MCP, repository scanning, code traceability, and background sync';
    window.alert(`Preview mode keeps the graph readable, but these features require a license: ${locked}.`);
  }

  async function dismissAttachWorkbookPrompt() {
    const prompt = document.getElementById('attach-workbook-prompt');
    prompt?.classList.remove('visible');
    try {
      await fetch('/api/workspace/preferences', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ attach_workbook_prompt_dismissed: true }),
      });
    } catch (_) {}
  }

  function buildDraftConnection() {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId);
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

  async function connectWorkbookSource() {
    const errEl = document.getElementById('lobby-error');
    const btn = document.getElementById('s3-continue-btn');
    const labelEl = btn?.querySelector('.authorize-btn-label');
    const draft = buildDraftConnection();
    if (!draft) {
      errEl.textContent = 'Complete all connection fields before continuing.';
      errEl.style.display = 'block';
      return;
    }
    errEl.style.display = 'none';
    btn.disabled = true;
    if (labelEl) labelEl.textContent = 'Connecting…';
    try {
      if (draft.platform === 'local') {
        const prefsRes = await fetch('/api/workspace/preferences', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({
            workspace_ready: true,
            workspace_source_of_truth: 'workbook_first',
          }),
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
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(draft),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        throw new Error(formatDiagnosticsError(data) || connectionErrorMessage(data.error, draft.platform) || data.detail || data.error || `HTTP ${res.status}`);
      }
      lobbyState.sourceOfTruth = 'workbook_first';
      await loadStatus(true);
      showScreen(4, 'forward');
    } catch (err) {
      errEl.textContent = 'Failed to connect: ' + (err.message || err);
      errEl.style.display = 'block';
    } finally {
      btn.disabled = false;
      if (labelEl) labelEl.textContent = 'Review →';
    }
  }

  async function continueInPreviewMode() {
    const errEl = document.getElementById('lobby-error');
    errEl.style.display = 'none';
    try {
      const status = await loadStatus(true);
      if (!status.workspace_ready) {
        throw new Error('Finish seeding the workspace before continuing.');
      }
      showSuccess(status);
    } catch (err) {
      errEl.textContent = err.message || String(err);
      errEl.style.display = 'block';
    }
  }

  function updateSourceArtifactChip(name, meta) {
    const chip = document.getElementById('source-upload-chip');
    document.getElementById('source-upload-name').textContent = name;
    document.getElementById('source-upload-meta').textContent = meta;
    chip.classList.add('visible');
    document.getElementById('source-artifact-zone').style.display = 'none';
  }

  async function uploadOnboardingSourceArtifact(file) {
    if (!file) return;
    const errEl = document.getElementById('lobby-error');
    errEl.style.display = 'none';
    const form = new FormData();
    form.append('file', file);
    form.append('display_name', file.name);
    try {
      const res = await fetch('/api/onboarding/source-artifact', {
        method: 'POST',
        body: form,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        throw new Error(data.detail || data.error || `HTTP ${res.status}`);
      }
      lobbyState.sourceArtifactFileName = file.name;
      lobbyState.sourceArtifactKind = data.kind || '';
      lobbyState.sourceOfTruth = data.source_of_truth || 'document_first';
      sessionStorage.setItem(PENDING_WORKSPACE_TAB_KEY, 'design-artifacts');
      updateSourceArtifactChip(file.name, `Classified as ${data.kind || 'artifact'} and ingested into the preview workspace.`);
      await loadStatus(true);
      showScreen(4, 'forward');
    } catch (err) {
      errEl.textContent = 'Failed to ingest artifact: ' + (err.message || err);
      errEl.style.display = 'block';
    }
  }

  function onSourceArtifactDragOver(e) {
    e.preventDefault();
    document.getElementById('source-artifact-zone').classList.add('drag-over');
  }

  function onSourceArtifactDragLeave(e) {
    if (!e.currentTarget.contains(e.relatedTarget)) {
      document.getElementById('source-artifact-zone').classList.remove('drag-over');
    }
  }

  async function onSourceArtifactDrop(e) {
    e.preventDefault();
    document.getElementById('source-artifact-zone').classList.remove('drag-over');
    const file = e.dataTransfer.files?.[0] || null;
    if (file) await uploadOnboardingSourceArtifact(file);
  }

  function onSaDragOver(e) {
    e.preventDefault();
    document.getElementById('sa-upload-zone').classList.add('drag-over');
  }

  function onSaDragLeave(e) {
    if (!e.currentTarget.contains(e.relatedTarget)) {
      document.getElementById('sa-upload-zone').classList.remove('drag-over');
    }
  }

  async function onSaDrop(e) {
    e.preventDefault();
    document.getElementById('sa-upload-zone').classList.remove('drag-over');
    const file = e.dataTransfer.files[0];
    if (lobbyState.provider === 'google' && file) await uploadSaFile(file);
  }

  async function uploadSaFile(file) {
    const errEl = document.getElementById('lobby-error');
    errEl.style.display = 'none';

    let text;
    try {
      text = await file.text();
    } catch {
      errEl.textContent = 'Could not read that file.';
      errEl.style.display = 'block';
      return;
    }

    try {
      const parsed = parseGoogleServiceAccountJson(text);
      lobbyState.googleCredentialEmail = parsed.client_email;
      lobbyState.googleCredentialJson = text;
    } catch (err) {
      errEl.textContent = err.message || 'Invalid Google service-account JSON.';
      errEl.style.display = 'block';
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
    if (!tenantId || !clientId || !clientSecret) {
      throw new Error('Enter all Azure credentials to continue.');
    }
    if (!tenantId.trim() || !clientId.trim() || !clientSecret.trim()) {
      throw new Error('Excel Online credentials cannot be blank.');
    }
    return {
      tenantId: tenantId.trim(),
      clientId: clientId.trim(),
      clientSecret: clientSecret.trim(),
    };
  }

  document.getElementById('sa-file-input').addEventListener('change', function() {
    if (this.files[0]) uploadSaFile(this.files[0]);
    this.value = '';
  });

  document.getElementById('source-artifact-file-input')?.addEventListener('change', function() {
    if (this.files?.[0]) void uploadOnboardingSourceArtifact(this.files[0]);
    this.value = '';
  });

  async function initApp() {
    try {
      const status = await loadStatus(true);
      await loadWorkbooksState();
      if (status.workspace_ready) {
        await enterWorkspace(status);
      } else {
        await showLobby();
      }
    } catch (e) {
      await showLobby();
    }
  }

  // --- Chain Gaps tab ---

  async function loadProfileState() {
    const select = document.getElementById('profile-select');
    if (!select) return;
    try {
      const res = await fetch('/api/profile');
      if (!res.ok) return;
      const data = await res.json();
      const profile = data.profile || 'generic';
      select.value = profile;
      document.getElementById('profile-desc').textContent = PROFILE_DESCRIPTIONS[profile] || '';
      await refreshDashboardProvisionPreview(profile);
    } catch (_) {}
  }

  async function refreshDashboardProvisionPreview(profile) {
    const previewEl = document.getElementById('profile-preview');
    const btn = document.getElementById('profile-provision-btn');
    try {
      const res = await fetch('/api/provision-preview?profile=' + encodeURIComponent(profile));
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (!data.ready) {
        previewEl.style.display = 'none';
        btn.style.display = 'none';
        return;
      }
      previewEl.textContent = provisionPreviewText(data);
      previewEl.style.display = 'block';
      btn.style.display = (data.missing_count || 0) > 0 ? 'inline-block' : 'none';
    } catch (_) {
      previewEl.style.display = 'none';
      btn.style.display = 'none';
    }
  }

  async function changeProfile() {
    const select = document.getElementById('profile-select');
    const errEl = document.getElementById('gaps-error');
    const profile = select.value;
    errEl.style.display = 'none';
    try {
      const res = await fetch('/api/profile', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({profile}),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      document.getElementById('profile-desc').textContent = PROFILE_DESCRIPTIONS[profile] || '';
      await refreshDashboardProvisionPreview(profile);
      await loadChainGaps();
    } catch (e) {
      errEl.textContent = 'Failed to change profile: ' + e.message;
      errEl.style.display = 'block';
    }
  }

  async function provisionMissingTabs() {
    const errEl = document.getElementById('gaps-error');
    errEl.style.display = 'none';
    try {
      const res = await fetch('/api/provision', { method: 'POST' });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      await refreshDashboardProvisionPreview(document.getElementById('profile-select').value);
      await loadChainGaps();
    } catch (e) {
      errEl.textContent = 'Provisioning failed: ' + e.message;
      errEl.style.display = 'block';
    }
  }

  async function loadChainGaps() {
    const errEl = document.getElementById('gaps-error');
    const tbody = document.getElementById('chain-gaps-body');
    const badge = document.getElementById('chain-gap-count');
    errEl.style.display = 'none';
    tbody.innerHTML = '<tr class="loading-row"><td colspan="6" class="empty-state">Loading…</td></tr>';

    let gaps;
    try {
      const res = await fetch('/query/chain-gaps');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      gaps = await res.json();
    } catch (e) {
      errEl.textContent = 'Failed to load chain gaps: ' + e.message;
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

    tbody.innerHTML = gaps.map((g) => {
      const sev = (g.severity || 'info').toLowerCase();
      return `<tr>
        <td><a href="#" class="guide-link" data-action="open-guide" data-guide-code="${esc(String(g.code || ''))}" data-guide-variant="${esc(g.gap_type || '')}">${esc(String(g.code || ''))}</a></td>
        <td><a href="#" class="guide-link" data-action="open-guide" data-guide-code="${esc(String(g.code || ''))}" data-guide-variant="${esc(g.gap_type || '')}">${esc(g.title || '')}</a></td>
        <td>${esc(g.gap_type || '')}</td>
        <td>${esc(g.node_id || '')}</td>
        <td><span class="gap-badge-sev ${sev}">${esc(sev)}</span></td>
        <td>${esc(g.message || '')}</td>
      </tr>`;
    }).join('');
  }

  // --- Code Traceability tab ---

  async function addRepo() {
    const input = document.getElementById('repo-path-input');
    const errEl = document.getElementById('repo-error');
    const path = input.value.trim();
    if (!path) return;
    errEl.style.display = 'none';

    try {
      const res = await fetch('/api/repos', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({path}),
      });
      const data = await res.json();
      if (!res.ok || data.ok === false) throw new Error(formatDiagnosticsError(data));
      input.value = '';
      await scanAndLoadCodeTraceability();
    } catch (e) {
      errEl.textContent = e.message;
      errEl.style.display = 'block';
    }
  }

  async function deleteRepo(slot) {
    await fetch('/api/repos/' + slot, { method: 'DELETE' });
    loadCodeTraceability();
  }

  function formatUnixTimestamp(ts) {
    if (!ts || Number(ts) <= 0) return 'never';
    try {
      return new Date(Number(ts) * 1000).toLocaleString();
    } catch (_) {
      return String(ts);
    }
  }

  async function loadCodeScanStatus() {
    const el = document.getElementById('code-scan-status');
    if (!el) return;
    try {
      const res = await fetch('/api/status');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const status = await res.json();
      if (status.repo_scan_in_progress) {
        const started = formatUnixTimestamp(status.repo_scan_last_started_at);
        el.textContent = `Scan in progress${started !== 'never' ? ` — started ${started}` : ''}`;
        return;
      }

      const finished = formatUnixTimestamp(status.repo_scan_last_finished_at);
      const fallback = formatUnixTimestamp(status.last_scan_at);
      const completed = finished !== 'never' ? finished : fallback;
      el.textContent = `Last completed scan: ${completed}`;
    } catch (e) {
      el.textContent = `Scan status unavailable: ${e.message}`;
    }
  }

  async function scanAndLoadCodeTraceability() {
    const btn = document.getElementById('code-scan-btn');
    const codeBody = document.getElementById('code-body');
    const commitsEl = document.getElementById('recent-commits');
    const statusEl = document.getElementById('code-scan-status');
    const prev = btn ? btn.textContent : '';
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'Scanning...';
    }
    if (statusEl) {
      statusEl.textContent = 'Scan in progress...';
    }
    if (codeBody) {
      codeBody.innerHTML = '<div class="empty-state">Scanning configured repositories…</div>';
    }
    if (commitsEl) {
      commitsEl.innerHTML = '<em class="text-hint">Scanning configured repositories…</em>';
    }
    try {
      const res = await fetch('/api/repos/scan', { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
      await loadCodeTraceability();
    } catch (e) {
      if (statusEl) {
        statusEl.textContent = `Scan failed: ${e.message}`;
      }
      if (codeBody) {
        codeBody.innerHTML = `<div class="empty-state">Scan failed: ${esc(e.message)}</div>`;
      }
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = prev || 'Scan Now';
      }
    }
  }

  async function loadRepos() {
    const el = document.getElementById('repos-list');
    if (!el) return;
    try {
      const res = await fetch('/api/repos');
      if (!res.ok) return;
      const data = await res.json();
      const repos = data.repos || [];
      if (repos.length === 0) {
        el.innerHTML = '<tr><td colspan="7" class="empty-state"><strong>No repos yet</strong><br>Add a local Git repository path above.</td></tr>';
        return;
      }
      el.innerHTML = repos.map((r) => `<tr>
        <td class="mono-sm">${esc(r.path)}</td>
        <td>${esc(formatUnixTimestamp(r.last_scan))}</td>
        <td>${esc(String(r.source_file_count || 0))}</td>
        <td>${esc(String(r.test_file_count || 0))}</td>
        <td>${esc(String(r.annotation_count || 0))}</td>
        <td>${esc(String(r.commit_count || 0))}</td>
        <td><button class="btn-danger" data-action="delete-repo" data-slot="${Number.isInteger(r.slot) ? r.slot : 0}" title="Remove repo">×</button></td>
      </tr>`).join('');
    } catch (_) {}
  }

  async function loadDiagnostics() {
    const el = document.getElementById('diagnostics-list');
    if (!el) return;
    try {
      const res = await fetch('/api/diagnostics?source=all');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const diagnostics = data.diagnostics || [];
      if (diagnostics.length === 0) {
        el.innerHTML = '<em class="text-hint">No diagnostics.</em>';
        return;
      }
      el.innerHTML = diagnostics.map(d => `<div class="repo-row repo-row--block">
        <div><a href="#" class="guide-link" data-action="open-guide" data-guide-code="E${esc(String(d.code))}"><strong>E${esc(String(d.code))}</strong></a> ${esc(d.title || '')} <span class="gap-badge-sev ${(d.severity || 'info').toLowerCase()}">${esc((d.severity || '').toLowerCase())}</span></div>
        <div class="text-sm-muted">${esc(d.message || '')}</div>
        ${d.subject ? `<div class="mono-sm text-sm-subtle">${esc(d.subject)}</div>` : ''}
      </div>`).join('');
    } catch (e) {
      el.innerHTML = `<div class="empty-state">Failed to load diagnostics: ${esc(e.message)}</div>`;
    }
  }

  async function loadCodeTraceability() {
    const container = document.getElementById('code-body');
    container.innerHTML = '<div class="empty-state loading-pulse">Loading…</div>';
    await Promise.all([loadRepos(), loadDiagnostics(), loadCoverageGaps(), loadRecentCommits(), loadCodeScanStatus()]);

    let files;
    try {
      const res = await fetch('/query/code-traceability');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      files = await res.json();
    } catch (e) {
      container.innerHTML = `<div class="empty-state">Error: ${esc(e.message)}</div>`;
      return;
    }

    const combined = [...(files.source_files || []), ...(files.test_files || [])];
    if (combined.length === 0) {
      container.innerHTML = '<div class="empty-state">No source files indexed yet.</div>';
      return;
    }

    const groups = new Map();
    combined.forEach(f => {
      const props = propsObj(f.properties);
      const repo = props.repo || 'Unknown Repo';
      if (!groups.has(repo)) groups.set(repo, []);
      groups.get(repo).push({ node: f, props });
    });

    container.innerHTML = Array.from(groups.entries()).map(([repo, entries]) => {
      const rows = entries.map(({node, props}) => {
        const filePath = props.path || node.id;
        return `<tr data-expanded="0" data-file-path="${esc(filePath)}">
          <td><button class="expand-btn" aria-label="Expand ${esc(filePath)}" aria-expanded="false" data-action="expand-file">${CHEVRON_SVG}</button></td>
          <td>${esc(node.type || '')}</td>
          <td class="mono-sm">${esc(filePath)}</td>
          <td>${esc(String(props.annotation_count || 0))}</td>
        </tr>`;
      }).join('');
      return `<div class="card card--mb">
        <div class="mono-sm card-title mb-8">${esc(repo)}</div>
        <table>
          <thead><tr><th></th><th>Type</th><th>Path</th><th>Annotations</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>`;
    }).join('');
  }

  async function expandFile(row, filePath) {
    const btn = row.querySelector('.expand-btn');
    if (row.dataset.expanded === '1') {
      row.nextElementSibling?.remove();
      row.dataset.expanded = '0';
      if (btn) { btn.classList.remove('open'); btn.setAttribute('aria-expanded', 'false'); }
      return;
    }
    let anns = [];
    try {
      const res = await fetch('/query/file-annotations?file_path=' + encodeURIComponent(filePath));
      if (res.ok) anns = await res.json();
    } catch (_) {}
    const detail = document.createElement('tr');
    detail.className = 'file-annotation-row';
    const annHtml = anns.length
      ? anns.map(a => {
          const p = propsObj(a.properties);
          return `<div class="ann-row">
            <code>${esc(p.req_id || a.id)}</code>
            <span class="ann-line">line ${esc(String(p.line_number || ''))}</span>
            <span class="ann-blame">${esc(p.blame_author || '')} ${esc(p.short_hash || '')}</span>
          </div>`;
        }).join('')
      : '<em class="text-hint">No annotations found.</em>';
    detail.innerHTML = `<td colspan="4"><div class="file-annotations">${annHtml}</div></td>`;
    row.parentNode.insertBefore(detail, row.nextSibling);
    row.dataset.expanded = '1';
    if (btn) { btn.classList.add('open'); btn.setAttribute('aria-expanded', 'true'); }
  }

  async function loadCoverageGaps() {
    const unimplementedEl = document.getElementById('unimplemented-list');
    const untestedEl = document.getElementById('untested-files-list');
    const [unimplementedRes, untestedRes] = await Promise.all([
      fetch('/query/unimplemented-requirements'),
      fetch('/query/untested-source-files'),
    ]);
    const unimplemented = unimplementedRes.ok ? await unimplementedRes.json() : [];
    const untested = untestedRes.ok ? await untestedRes.json() : [];
    unimplementedEl.innerHTML = renderSimpleNodeList(unimplemented, 'No unimplemented requirements.');
    untestedEl.innerHTML = renderSimpleNodeList(untested, 'No untested source files.');
  }

  async function loadRecentCommits() {
    const el = document.getElementById('recent-commits');
    try {
      const res = await fetch('/query/recent-commits');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const commits = await res.json();
      if (!commits.length) {
        el.innerHTML = '<em class="text-hint">No recent commits. Add a repo and run Scan Now.</em>';
        return;
      }
      el.innerHTML = commits.map(c => {
        const p = propsObj(c.properties);
        return `<div class="repo-row repo-row--block">
          <div><strong>${esc(p.short_hash || c.id)}</strong> ${esc(p.date || '')} ${esc(p.author || '')}</div>
          <div class="text-sm-muted">${esc(p.message || '')}</div>
          <div class="text-sm-subtle">${esc((p.req_ids || []).join(', '))}</div>
        </div>`;
      }).join('');
    } catch (e) {
      el.innerHTML = `<div class="empty-state">Failed to load commits: ${esc(e.message)}</div>`;
    }
  }

  function renderSimpleNodeList(nodes, emptyMessage) {
    if (!nodes || nodes.length === 0) {
      return `<em class="text-hint">${esc(emptyMessage)}</em>`;
    }
    return nodes.map(n => `<div class="repo-row repo-row--block">
      <div><strong>${esc(n.id || '')}</strong></div>
      <div class="text-sm-subtle">${esc(n.type || '')}</div>
    </div>`).join('');
  }

  function provisionPreviewText(data) {
    const missing = data.missing || [];
    const existing = data.existing || [];
    if ((data.missing_count || 0) === 0) return 'All required tabs already exist for this profile.';
    if ((data.existing_count || 0) === 0) return `This will create ${missing.length} tabs in your sheet: ${missing.join(', ')}`;
    return `Found ${existing.length} existing tabs. Will create ${missing.length} additional tabs: ${missing.join(', ')}`;
  }

  function formatDiagnosticsError(data) {
    const diagnostics = data.diagnostics || [];
    if (!diagnostics.length) return data.detail || '';
    return diagnostics.map(d => `E${d.code}: ${d.message}`).join(' ');
  }

  function copyEmail() {
    const value = document.getElementById('sa-loaded-email').textContent;
    if (!value) return;
    navigator.clipboard.writeText(value).catch(() => {});
  }

  // --- Init ---
  renderProfileList();
  const bomUploadInput = document.getElementById('bom-upload-input');
  if (bomUploadInput) {
    bomUploadInput.addEventListener('change', async function () {
      if (this.files && this.files[0]) await uploadBomArtifactFile(this.files[0]);
      this.value = '';
    });
  }
  const bomUploadZone = document.getElementById('bom-upload-zone');
  if (bomUploadZone) {
    bomUploadZone.addEventListener('dragover', (event) => {
      event.preventDefault();
      bomUploadZone.classList.add('drag-over');
    });
    bomUploadZone.addEventListener('dragleave', () => {
      bomUploadZone.classList.remove('drag-over');
    });
    bomUploadZone.addEventListener('drop', async (event) => {
      event.preventDefault();
      bomUploadZone.classList.remove('drag-over');
      const file = event.dataTransfer?.files?.[0];
      if (file) await uploadBomArtifactFile(file);
    });
  }
  const soupUploadInput = document.getElementById('soup-upload-input');
  if (soupUploadInput) {
    soupUploadInput.addEventListener('change', async function () {
      if (this.files && this.files[0]) await uploadSoupArtifactFile(this.files[0]);
      this.value = '';
    });
  }
  const soupUploadZone = document.getElementById('soup-upload-zone');
  if (soupUploadZone) {
    soupUploadZone.addEventListener('dragover', (event) => {
      event.preventDefault();
      soupUploadZone.classList.add('drag-over');
    });
    soupUploadZone.addEventListener('dragleave', () => {
      soupUploadZone.classList.remove('drag-over');
    });
    soupUploadZone.addEventListener('drop', async (event) => {
      event.preventDefault();
      soupUploadZone.classList.remove('drag-over');
      const file = event.dataTransfer?.files?.[0];
      if (file) await uploadSoupArtifactFile(file);
    });
  }
  const designArtifactUploadInput = document.getElementById('design-artifact-upload-input');
  if (designArtifactUploadInput) {
    designArtifactUploadInput.addEventListener('change', async function () {
      if (this.files && this.files[0]) await uploadDesignArtifactFile(this.files[0]);
      this.value = '';
    });
  }
  const designArtifactUploadZone = document.getElementById('design-artifact-upload-zone');
  if (designArtifactUploadZone) {
    designArtifactUploadZone.addEventListener('dragover', (event) => {
      event.preventDefault();
      designArtifactUploadZone.classList.add('drag-over');
    });
    designArtifactUploadZone.addEventListener('dragleave', () => {
      designArtifactUploadZone.classList.remove('drag-over');
    });
    designArtifactUploadZone.addEventListener('drop', async (event) => {
      event.preventDefault();
      designArtifactUploadZone.classList.remove('drag-over');
      const file = event.dataTransfer?.files?.[0];
      if (file) await uploadDesignArtifactFile(file);
    });
  }
  window.addEventListener('hashchange', () => {
    handleGuideHash();
  });
  initApp();
