  const CHEVRON_SVG = `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 1.5l4 3.5-4 3.5"/></svg>`;
  let licenseStatusCache = null;

  // --- Tab switching ---

  // Tab → group mapping
  const TAB_GROUP = {
    'requirements': 'data', 'user-needs': 'data', 'tests': 'data',
    'risks': 'data', 'rtm': 'data',
    'chain-gaps': 'analysis', 'impact': 'analysis', 'review': 'analysis',
    'guide-errors': 'guide', 'mcp-ai': 'guide',
    'code': 'code', 'reports': 'reports',
    'info': 'settings',
  };

  // Default sub-tab per group
  const GROUP_DEFAULTS = {
    data: 'requirements',
    analysis: 'chain-gaps',
    guide: 'guide-errors',
    code: 'code',
    reports: 'reports',
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
    try {
      const licenseStatus = await loadLicenseStatus(true);
      if (licenseStatus && licenseStatus.permits_use === false) {
        showLicenseGate(licenseStatus);
        return;
      }
    } catch (_) {}
    _closeAllExpanded();
    await Promise.all([renderRequirements(), renderUserNeeds(), renderTests(), renderRTM(), renderRisks(), refreshSuspectBadge()]);
    await loadProfileState();
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

  function renderTestResultsApiInfo(info, endpointEl, bomEndpointEl, tokenEl, inboxEl) {
    if (endpointEl) endpointEl.textContent = info.test_results_endpoint || 'unknown';
    if (bomEndpointEl) bomEndpointEl.textContent = info.bom_endpoint || 'unknown';
    if (tokenEl) tokenEl.textContent = info.test_results_token || 'unknown';
    if (inboxEl) inboxEl.textContent = info.test_results_inbox_dir || 'unknown';
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

  async function showLobby() {
    document.getElementById('lobby').classList.add('visible');
    _trapLobby();
    try {
      const res = await fetch('/api/status');
      const status = await res.json();
      licenseStatusCache = status.license || null;
      if (status.license && status.license.permits_use === false) {
        showLicenseGate(status.license);
        return;
      }
      applyStatus(status);
      resetLobbyScreens(1);
      lobbyCurrentScreen = 1;
      updateLobbyNav();
      if (!status.connection_block_reason && status.workbook_url && status.platform && lobbyState.profileId) {
        lobbyCurrentScreen = 1;
        showScreen(4, 'forward');
        return;
      }
    } catch (_) {}
    resetLobbyScreens(1);
    lobbyCurrentScreen = 1;
    updateLobbyNav();
  }

  function clearProfileSelection() {
    lobbyState.profileId = null;
    lobbyState.prefilledConnection = false;
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

  function applyStatus(status) {
    if (status.platform) {
      lobbyState.provider = status.platform;
      selectProvider(status.platform);
    }
    if (status.workbook_url) {
      lobbyState.workbookUrl = status.workbook_url;
      document.getElementById('lobby-url').value = status.workbook_url;
    }
    lobbyState.prefilledConnection = Boolean(status.platform && status.workbook_url);
    if (status.platform === 'google' && status.credential_display) {
      lobbyState.googleCredentialEmail = status.credential_display;
      document.getElementById('sa-loaded-email').textContent = status.credential_display;
      document.getElementById('sa-upload-zone').style.display = 'none';
      document.getElementById('sa-loaded-chip').style.display = '';
      document.getElementById('lobby-share-hint').style.display = 'block';
    }
    if (status.profile) {
      const backendToUi = { medical:'medical', aerospace:'aerospace', automotive:'automotive', generic:null };
      const uiId = backendToUi[status.profile] ?? null;
      if (uiId !== null) {
        lobbyState.profileId = uiId;
        document.querySelectorAll('.profile-row').forEach(row => {
          row.classList.toggle('selected', row.dataset.profileId === uiId);
          row.setAttribute('aria-selected', row.dataset.profileId === uiId ? 'true' : 'false');
        });
      } else {
        clearProfileSelection();
      }
      // generic → profileId stays null, user must re-select from the expanded list
    } else {
      clearProfileSelection();
    }
    updateLobbyConnectionMessage(status);
  }

  function connectionBlockMessage(status) {
    switch (status?.connection_block_reason) {
      case 'legacy_plaintext_credentials':
        return 'This workspace was configured before secure credential storage. Reconnect to store provider credentials outside SQLite.';
      case 'secure_storage_unsupported':
        return 'Secure credential storage is not available on this platform. RTMify Live cannot save provider credentials here.';
      case 'secret_not_found':
      case 'secret_store_error':
        return 'Stored provider credentials are unavailable. Reconnect to restore access.';
      case 'credential_ref_missing':
        return 'Stored provider credentials are incomplete. Reconnect to restore access.';
      default:
        return '';
    }
  }

  function updateLobbyConnectionMessage(status) {
    const errEl = document.getElementById('lobby-error');
    if (!errEl) return;
    const msg = connectionBlockMessage(status);
    errEl.textContent = msg;
    errEl.style.display = msg ? 'block' : 'none';
  }

  function connectionErrorMessage(code) {
    switch (code) {
      case 'secure_storage_unavailable':
        return 'Secure credential storage is not available on this platform.';
      case 'failed to persist secure credentials':
        return 'Provider credentials could not be saved securely.';
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
    const lobby = document.getElementById('lobby');
    if (lobby) lobby.classList.remove('visible');
    _releaseLobby();
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

  async function continueLicensedBoot(statusPayload = null) {
    const status = statusPayload || await (async () => {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    })();

    licenseStatusCache = status.license || licenseStatusCache;
    syncLicenseInfo(licenseStatusCache);
    hideLicenseGate();

    if (status.configured) {
      document.getElementById('lobby').classList.remove('visible');
      _releaseLobby();
      await loadData();
      await handleGuideHash();
      return;
    }

    await showLobby();
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
      await continueLicensedBoot();
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
      const status = await loadLicenseStatus(true);
      licenseStatusCache = status;
      syncLicenseInfo(status);
      if (status?.permits_use) {
        await continueLicensedBoot();
      } else {
        showLicenseGate(status, status?.message || '');
      }
    } catch (e) {
      showLicenseGate(licenseStatusCache, e.message);
    }
  }

  document.getElementById('license-file-input')?.addEventListener('change', (event) => {
    const file = event.target?.files?.[0] || null;
    void importLicenseFile(file);
  });

  // --- Service-account drag and drop ---

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
      JSON.parse(text);
    } catch {
      errEl.textContent = 'Invalid JSON file.';
      errEl.style.display = 'block';
      return;
    }

    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      errEl.textContent = 'Invalid Google service-account JSON.';
      errEl.style.display = 'block';
      return;
    }

    lobbyState.googleCredentialEmail = parsed.client_email || 'Loaded service account';
    lobbyState.googleCredentialJson  = text;

    document.getElementById('sa-loaded-email').textContent = lobbyState.googleCredentialEmail;
    document.getElementById('sa-upload-zone').style.display = 'none';
    document.getElementById('sa-loaded-chip').style.display = '';
    document.getElementById('lobby-share-hint').style.display = 'block';
  }

  document.getElementById('sa-file-input').addEventListener('change', function() {
    if (this.files[0]) uploadSaFile(this.files[0]);
    this.value = '';
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
    provider: 'google',
    googleCredentialJson: '',
    googleCredentialEmail: '',
    excelTenantId: '',
    excelClientId: '',
    excelClientSecret: '',
    workbookUrl: '',
    prefilledConnection: false,
  };

  let lobbyCurrentScreen = 1;

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
    lobbyState.prefilledConnection = false;
    document.querySelectorAll('.profile-row').forEach(row => {
      const isSelected = row.dataset.profileId === id;
      row.classList.toggle('selected', isSelected);
      row.setAttribute('aria-selected', isSelected);
    });
  }

  function selectProvider(provider) {
    lobbyState.provider = provider;
    lobbyState.prefilledConnection = false;
    document.getElementById('tile-google').classList.toggle('selected', provider === 'google');
    document.getElementById('tile-excel').classList.toggle('selected', provider === 'excel');
    document.getElementById('s3-google').style.display = provider === 'google' ? '' : 'none';
    document.getElementById('s3-excel').style.display = provider === 'excel' ? '' : 'none';
    document.getElementById('lobby-url').placeholder = provider === 'excel'
      ? 'https://tenant.sharepoint.com/:x:/r/sites/…'
      : 'https://docs.google.com/spreadsheets/d/…';
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
    if (n === 4) renderMissionBrief();
  }

  function updateLobbyNav() {
    const backBtn = document.getElementById('lobby-back-btn');
    const dots = document.getElementById('lobby-dots');
    const onSuccess = lobbyCurrentScreen === 5;
    backBtn.classList.toggle('visible', lobbyCurrentScreen > 1 && !onSuccess);
    dots.style.visibility = onSuccess ? 'hidden' : '';
    document.querySelectorAll('.lobby-dot').forEach(dot => {
      dot.classList.toggle('active', Number(dot.dataset.dot) === lobbyCurrentScreen);
    });
  }

  function lobbyNext(fromScreen) {
    const errEl = document.getElementById('lobby-error');
    errEl.style.display = 'none';
    if (fromScreen === 1) {
      if (!lobbyState.profileId) {
        errEl.textContent = 'Select a profile to continue.';
        errEl.style.display = 'block';
        return;
      }
      showScreen(2, 'forward');
    } else if (fromScreen === 2) {
      showScreen(3, 'forward');
    } else if (fromScreen === 3) {
      lobbyStateFromInputs();
      if (lobbyState.provider === 'google') {
        if (!lobbyState.googleCredentialJson) {
          errEl.textContent = 'Upload a service-account.json file to continue.';
          errEl.style.display = 'block';
          return;
        }
      } else {
        if (!lobbyState.excelTenantId || !lobbyState.excelClientId || !lobbyState.excelClientSecret) {
          errEl.textContent = 'Enter all Azure credentials to continue.';
          errEl.style.display = 'block';
          return;
        }
      }
      if (!lobbyState.workbookUrl) {
        errEl.textContent = 'Enter a workbook URL to continue.';
        errEl.style.display = 'block';
        return;
      }
      showScreen(4, 'forward');
    }
  }

  function lobbyBack() {
    if (lobbyCurrentScreen > 1) showScreen(lobbyCurrentScreen - 1, 'back');
  }

  function lobbyStateFromInputs() {
    const workbookUrl = document.getElementById('lobby-url').value.trim();
    if (workbookUrl !== lobbyState.workbookUrl) lobbyState.prefilledConnection = false;
    lobbyState.workbookUrl = workbookUrl;
    if (lobbyState.provider === 'excel') {
      const tenantId = document.getElementById('excel-tenant-id').value.trim();
      const clientId = document.getElementById('excel-client-id').value.trim();
      const clientSecret = document.getElementById('excel-client-secret').value.trim();
      if (tenantId !== lobbyState.excelTenantId || clientId !== lobbyState.excelClientId || clientSecret !== lobbyState.excelClientSecret) {
        lobbyState.prefilledConnection = false;
      }
      lobbyState.excelTenantId     = tenantId;
      lobbyState.excelClientId     = clientId;
      lobbyState.excelClientSecret = clientSecret;
    }
  }

  function toggleSecretVisibility() {
    const input = document.getElementById('excel-client-secret');
    const eye   = document.getElementById('secret-eye');
    const isPassword = input.type === 'password';
    input.type = isPassword ? 'text' : 'password';
    eye.style.opacity = isPassword ? '0.4' : '1';
  }

  function renderMissionBrief() {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId);
    if (!profile) return;
    document.getElementById('brief-headline').textContent = profile.tagline;
    const urlDisplay = lobbyState.workbookUrl.length > 44
      ? '…' + lobbyState.workbookUrl.slice(-42) : lobbyState.workbookUrl;
    const accountDisplay = lobbyState.provider === 'google'
      ? (lobbyState.googleCredentialEmail || '—')
      : (lobbyState.excelTenantId || '—');
    const providerLabel = lobbyState.provider === 'google' ? 'Google Sheets' : 'Excel Online';
    document.getElementById('mission-brief').innerHTML = `
      <div class="brief-row"><span class="brief-key">Profile</span><span class="brief-val plain">${profile.label}</span></div>
      <div class="brief-row"><span class="brief-key">Standard</span><span class="brief-val plain">${profile.standards}</span></div>
      <div class="brief-row"><span class="brief-key">Provider</span><span class="brief-val plain">${providerLabel}</span></div>
      <div class="brief-row"><span class="brief-key">Account</span><span class="brief-val">${esc(accountDisplay)}</span></div>
      <div class="brief-row"><span class="brief-key">Workbook</span><span class="brief-val">${esc(urlDisplay)}</span></div>`;
  }

  function showSuccess() {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId) || { label: '—', standards: '—' };
    document.getElementById('success-sub').textContent =
      `${profile.label} · ${lobbyState.provider === 'google' ? 'Google Sheets' : 'Excel Online'}`;
    document.getElementById('success-detail').innerHTML = `
      <div class="success-detail-row"><span class="success-detail-key">Standard</span><span class="success-detail-val">${esc(profile.standards)}</span></div>
      <div class="success-detail-row"><span class="success-detail-key">Account</span><span class="success-detail-val">${esc(lobbyState.googleCredentialEmail || lobbyState.excelTenantId || '—')}</span></div>
      <div class="success-detail-row"><span class="success-detail-key">Sync</span><span class="success-detail-val">Starting…</span></div>`;
    showScreen(5, 'forward');
  }

  function openWorkspace() {
    document.getElementById('lobby').classList.remove('visible');
    _releaseLobby();
    loadData();
  }

  function clearCredential() {
    lobbyState.googleCredentialJson = '';
    lobbyState.googleCredentialEmail = '';
    lobbyState.prefilledConnection = false;
    document.getElementById('sa-upload-zone').style.display = '';
    document.getElementById('sa-loaded-chip').style.display = 'none';
    document.getElementById('lobby-share-hint').style.display = 'none';
  }

  function _trapLobby() {
    document.querySelector('main').inert = true;
    document.querySelector('header').inert = true;
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

  async function initApp() {
    let status;
    try {
      const res = await fetch('/api/status');
      status = await res.json();
      licenseStatusCache = status.license || null;
      syncLicenseInfo(licenseStatusCache);
    } catch (e) {
      // Server unreachable — show main app and let loadData handle errors
      await loadData();
      await handleGuideHash();
      return;
    }

    if (status.license && status.license.permits_use === false) {
      showLicenseGate(status.license);
      return;
    }

    if (status.configured) {
      await loadData();
      await handleGuideHash();
      return;
    }

    // Show lobby
    const lobby = document.getElementById('lobby');
    lobby.classList.add('visible');
    _trapLobby();

    applyStatus(status);
  }

  const PROFILE_DESCRIPTIONS = {
    generic: 'Basic requirements traceability',
    medical: 'ISO 13485 / IEC 62304 / FDA 21 CFR Part 11',
    aerospace: 'DO-178C / AS9100',
    automotive: 'ISO 26262 / ASPICE',
  };

  function buildDraftConnection() {
    const profile = LOBBY_PROFILES.find(p => p.id === lobbyState.profileId);
    if (!profile) return null;
    const draft = {
      platform: lobbyState.provider,
      profile: profile.backendId,
      workbook_url: lobbyState.workbookUrl,
      credentials: {},
    };
    if (lobbyState.provider === 'google') {
      if (!lobbyState.googleCredentialJson) return null;
      draft.credentials.service_account_json = lobbyState.googleCredentialJson;
    } else {
      if (!lobbyState.excelTenantId || !lobbyState.excelClientId || !lobbyState.excelClientSecret) return null;
      draft.credentials.tenant_id     = lobbyState.excelTenantId;
      draft.credentials.client_id     = lobbyState.excelClientId;
      draft.credentials.client_secret = lobbyState.excelClientSecret;
    }
    if (!lobbyState.workbookUrl) return null;
    return draft;
  }

  async function connectSheet() {
    const btn    = document.getElementById('authorize-btn');
    const fill   = document.getElementById('authorize-fill');
    const label  = document.getElementById('authorize-label');
    const errEl  = document.getElementById('lobby-error');
    const draft  = buildDraftConnection();

    if (!draft && lobbyState.prefilledConnection && lobbyState.profileId && lobbyState.provider && lobbyState.workbookUrl) {
      errEl.style.display = 'none';
      btn.disabled = true;
      fill.style.width = '100%';
      label.textContent = 'Using saved connection…';
      await new Promise(r => setTimeout(r, 150));
      showSuccess();
      await loadData();
      await handleGuideHash();
      return;
    }

    if (!draft) {
      errEl.textContent = 'Complete all fields before connecting.';
      errEl.style.display = 'block';
      return;
    }
    errEl.style.display = 'none';
    btn.disabled = true;
    fill.style.width = '25%';
    label.textContent = 'Verifying credentials…';

    try {
      const res = await fetch('/api/connection', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(draft),
      });
      fill.style.width = '70%';
      label.textContent = 'Reading workbook…';
      const data = await res.json().catch(() => ({}));
      if (!res.ok || !data.ok) {
        throw new Error(formatDiagnosticsError(data) || connectionErrorMessage(data.error) || data.detail || data.error || `HTTP ${res.status}`);
      }
    } catch (e) {
      errEl.textContent = 'Failed to connect: ' + e.message;
      errEl.style.display = 'block';
      btn.disabled = false;
      fill.style.width = '0%';
      label.textContent = 'Authorize & Connect';
      return;
    }

    fill.style.width = '100%';
    label.textContent = 'Connected.';
    await new Promise(r => setTimeout(r, 300));
    showSuccess();
    await loadData();
    await handleGuideHash();
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
  window.addEventListener('hashchange', () => {
    handleGuideHash();
  });
  initApp();
