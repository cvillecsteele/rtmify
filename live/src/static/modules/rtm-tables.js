import { CHEVRON_SVG, esc, resultBadge, rowSeverity } from '/modules/helpers.js';

async function loadTableJson({ url, tbodyId, errorId, loadingColspan, onData, onErrorPrefix }) {
  const errEl = document.getElementById(errorId);
  const tbody = document.getElementById(tbodyId);
  if (!errEl || !tbody) return null;

  errEl.style.display = 'none';
  tbody.innerHTML = `<tr class="loading-row"><td colspan="${loadingColspan}" class="empty-state">Loading…</td></tr>`;
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const rows = await res.json();
    return onData(rows, tbody, errEl);
  } catch (error) {
    errEl.textContent = `${onErrorPrefix}${error.message}`;
    errEl.style.display = 'block';
    tbody.innerHTML = '';
    return null;
  }
}

export async function renderRequirements() {
  return loadTableJson({
    url: '/query/rtm',
    tbodyId: 'req-body',
    errorId: 'req-error',
    loadingColspan: 5,
    onErrorPrefix: 'Failed to load requirements: ',
    onData(rows, tbody) {
      const summaries = new Map();
      for (const row of rows) {
        let summary = summaries.get(row.req_id);
        if (!summary) {
          summary = {
            req_id: row.req_id,
            statement: row.statement,
            status: row.status,
            user_need_id: row.user_need_id,
            suspect: !!row.suspect,
            test_group_ids: new Set(),
            test_ids: new Set(),
            hasEmptyTestGroup: false,
            hasConcreteTest: false,
            hasFail: false,
            hasNonPassConcreteResult: false,
          };
          summaries.set(row.req_id, summary);
        }
        if (row.user_need_id) summary.user_need_id = row.user_need_id;
        if (row.statement) summary.statement = row.statement;
        if (row.status) summary.status = row.status;
        if (row.suspect) summary.suspect = true;
        if (row.test_group_id) {
          summary.test_group_ids.add(row.test_group_id);
          if (!row.test_id) summary.hasEmptyTestGroup = true;
        }
        if (row.test_id) {
          summary.test_ids.add(row.test_id);
          summary.hasConcreteTest = true;
          if (row.result === 'FAIL') summary.hasFail = true;
          if (row.result !== 'PASS') summary.hasNonPassConcreteResult = true;
        }
      }

      const requirements = [...summaries.values()]
        .map((summary) => {
          const test_group_ids = [...summary.test_group_ids].sort((a, b) => a.localeCompare(b));
          let aggregate_result = null;
          if (test_group_ids.length > 0) {
            if (summary.hasFail) aggregate_result = 'FAIL';
            else if (summary.hasConcreteTest && !summary.hasNonPassConcreteResult && !summary.hasEmptyTestGroup) aggregate_result = 'PASS';
            else aggregate_result = 'PENDING';
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

      const issueCount = requirements.filter((row) => rowSeverity(row) !== '').length;
      const badge = document.getElementById('gap-badge');
      if (badge) {
        badge.textContent = issueCount === 0 ? 'OK' : issueCount + ' issue' + (issueCount > 1 ? 's' : '');
        badge.className = 'badge' + (issueCount === 0 ? ' zero' : '');
        badge.style.display = 'inline-block';
      }

      if (requirements.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty-state"><strong>No requirements</strong><br>Sync your Google Sheet or click Refresh.</td></tr>';
        return requirements;
      }

      tbody.innerHTML = requirements.map((row) => {
        const severity = rowSeverity(row);
        const rowClass = severity ? ` class="${severity}"` : '';
        const status = row.status || '—';
        const tgCell = row.test_group_ids.length > 0
          ? row.test_group_ids.map((tgId) => `<span class="test-id">${esc(tgId)}</span>`).join(' ')
          : '<span class="result-missing">No Test</span>';
        const resultCell = resultBadge(row.aggregate_result, row.test_group_ids.length > 0);
        return `<tr${rowClass}>
          <td><button class="expand-btn" aria-label="Expand ${esc(row.req_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(row.req_id)}" data-colspan="5">${CHEVRON_SVG}</button><span class="req-id">${esc(row.req_id)}</span></td>
          <td>${esc(row.statement || '—')}</td>
          <td>${esc(status)}</td>
          <td>${tgCell}</td>
          <td>${resultCell}</td>
        </tr>`;
      }).join('');
      return requirements;
    },
  });
}

export async function renderUserNeeds() {
  return loadTableJson({
    url: '/query/user-needs',
    tbodyId: 'un-body',
    errorId: 'un-error',
    loadingColspan: 4,
    onErrorPrefix: 'Failed to load user needs: ',
    onData(rows, tbody) {
      if (rows.length === 0) {
        tbody.innerHTML = '<tr><td colspan="4" class="empty-state"><strong>No user needs</strong><br>Check your sheet\'s User Needs tab.</td></tr>';
        return rows;
      }
      rows.sort((a, b) => a.id.localeCompare(b.id));
      tbody.innerHTML = rows.map((row) => {
        const rowClass = row.suspect ? ' class="suspect"' : '';
        return `<tr${rowClass}>
          <td><button class="expand-btn" aria-label="Expand ${esc(row.id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(row.id)}" data-colspan="4">${CHEVRON_SVG}</button><span class="req-id">${esc(row.id)}</span></td>
          <td>${esc(row.properties.statement || '—')}</td>
          <td>${esc(row.properties.source || '—')}</td>
          <td>${esc(row.properties.priority || '—')}</td>
        </tr>`;
      }).join('');
      return rows;
    },
  });
}

export async function renderTests() {
  return loadTableJson({
    url: '/query/tests',
    tbodyId: 'tests-body',
    errorId: 'tests-error',
    loadingColspan: 5,
    onErrorPrefix: 'Failed to load tests: ',
    onData(rows, tbody) {
      if (rows.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5" class="empty-state"><strong>No tests</strong><br>Check your sheet\'s Tests tab.</td></tr>';
        return rows;
      }
      tbody.innerHTML = rows.map((row) => {
        const rowClass = row.suspect ? ' class="suspect"' : '';
        const reqCell = (row.req_ids || []).length > 0
          ? row.req_ids.map((reqId) => `<span class="req-id">${esc(reqId)}</span>`).join(' ')
          : '<span class="text-placeholder">—</span>';
        return `<tr${rowClass}>
          <td><button class="expand-btn" aria-label="Expand ${esc(row.test_id || row.test_group_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(row.test_id || row.test_group_id)}" data-colspan="5">${CHEVRON_SVG}</button><span class="test-id">${esc(row.test_group_id || '—')}</span></td>
          <td><span class="test-id">${esc(row.test_id || '—')}</span></td>
          <td>${esc(row.test_type || '—')}</td>
          <td>${esc(row.test_method || '—')}</td>
          <td>${reqCell}</td>
        </tr>`;
      }).join('');
      return rows;
    },
  });
}

export async function renderRTM() {
  return loadTableJson({
    url: '/query/rtm',
    tbodyId: 'rtm-body',
    errorId: 'rtm-error',
    loadingColspan: 8,
    onErrorPrefix: 'Failed to load RTM: ',
    onData(rows, tbody) {
      if (rows.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty-state"><strong>No RTM data</strong><br>Requirements and tests must both be loaded.</td></tr>';
        return rows;
      }

      tbody.innerHTML = rows.map((row) => {
        const parentCell = row.user_need_id ? `<span class="test-id">${esc(row.user_need_id)}</span>` : '<span class="text-placeholder">—</span>';
        const tgCell = row.test_group_id ? `<span class="test-id">${esc(row.test_group_id)}</span>` : '<span class="result-missing">Untested</span>';
        const testCell = row.test_id ? `<span class="test-id">${esc(row.test_id)}</span>` : '';
        const resultCell = row.test_group_id ? resultBadge(row.result, true) : '';
        const severity = rowSeverity(row);
        const rowClass = row.suspect ? 'suspect' : (severity || '');
        return `<tr${rowClass ? ` class="${rowClass}"` : ''}>
          <td><button class="expand-btn" aria-label="Expand ${esc(row.req_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(row.req_id)}" data-colspan="8">${CHEVRON_SVG}</button><span class="req-id">${esc(row.req_id)}</span></td>
          <td>${parentCell}</td>
          <td>${esc(row.statement || '—')}</td>
          <td>${tgCell}</td>
          <td>${testCell}</td>
          <td>${esc(row.test_type || '')}</td>
          <td>${esc(row.test_method || '')}</td>
          <td>${resultCell}</td>
        </tr>`;
      }).join('');
      return rows;
    },
  });
}

export async function renderRisks() {
  return loadTableJson({
    url: '/query/risks',
    tbodyId: 'risks-body',
    errorId: 'risks-error',
    loadingColspan: 7,
    onErrorPrefix: 'Failed to load risks: ',
    onData(rows, tbody) {
      if (rows.length === 0) {
        tbody.innerHTML = '<tr><td colspan="7" class="empty-state"><strong>No risks</strong><br>Check your sheet\'s Risks tab.</td></tr>';
        return rows;
      }

      tbody.innerHTML = rows.map((row) => {
        const initScore = (parseInt(row.initial_severity) || 0) * (parseInt(row.initial_likelihood) || 0);
        const scoreClass = (score) => (score >= 12 ? 'result-fail' : score >= 6 ? 'result-missing' : '');
        const reqCell = row.req_id ? `<span class="test-id">${esc(row.req_id)}</span>` : '<span class="text-placeholder">—</span>';
        const rowClass = !row.req_id ? ' class="warning"' : '';
        return `<tr${rowClass}>
          <td><button class="expand-btn" aria-label="Expand ${esc(row.risk_id)}" aria-expanded="false" data-action="toggle-row" data-id="${esc(row.risk_id)}" data-colspan="7">${CHEVRON_SVG}</button><span class="req-id">${esc(row.risk_id)}</span></td>
          <td>${esc(row.description || '—')}</td>
          <td class="text-center">${esc(row.initial_severity || '—')}</td>
          <td class="text-center">${esc(row.initial_likelihood || '—')}</td>
          <td class="text-center"><span class="${scoreClass(initScore)}">${initScore || '—'}</span></td>
          <td>${esc(row.mitigation || '—')}</td>
          <td>${reqCell}</td>
        </tr>`;
      }).join('');
      return rows;
    },
  });
}
