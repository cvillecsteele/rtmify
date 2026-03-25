import { CHEVRON_SVG, esc, formatDiagnosticsError, formatUnixTimestamp, propsObj, renderSimpleNodeList } from '/modules/helpers.js';

export async function addRepo() {
  const input = document.getElementById('repo-path-input');
  const errEl = document.getElementById('repo-error');
  const path = input?.value.trim();
  if (!path || !errEl) return;
  errEl.style.display = 'none';

  try {
    const res = await fetch('/api/repos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path }),
    });
    const data = await res.json();
    if (!res.ok || data.ok === false) throw new Error(formatDiagnosticsError(data));
    if (input) input.value = '';
    await scanAndLoadCodeTraceability();
  } catch (error) {
    errEl.textContent = error.message;
    errEl.style.display = 'block';
  }
}

export async function deleteRepo(slot) {
  await fetch('/api/repos/' + slot, { method: 'DELETE' });
  await loadCodeTraceability();
}

export async function loadCodeScanStatus() {
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
  } catch (error) {
    el.textContent = `Scan status unavailable: ${error.message}`;
  }
}

export async function scanAndLoadCodeTraceability() {
  const btn = document.getElementById('code-scan-btn');
  const codeBody = document.getElementById('code-body');
  const commitsEl = document.getElementById('recent-commits');
  const statusEl = document.getElementById('code-scan-status');
  const prev = btn ? btn.textContent : '';
  if (btn) {
    btn.disabled = true;
    btn.textContent = 'Scanning...';
  }
  if (statusEl) statusEl.textContent = 'Scan in progress...';
  if (codeBody) codeBody.innerHTML = '<div class="empty-state">Scanning configured repositories…</div>';
  if (commitsEl) commitsEl.innerHTML = '<em class="text-hint">Scanning configured repositories…</em>';
  try {
    const res = await fetch('/api/repos/scan', { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
    await loadCodeTraceability();
  } catch (error) {
    if (statusEl) statusEl.textContent = `Scan failed: ${error.message}`;
    if (codeBody) codeBody.innerHTML = `<div class="empty-state">Scan failed: ${esc(error.message)}</div>`;
  } finally {
    if (btn) {
      btn.disabled = false;
      btn.textContent = prev || 'Scan Now';
    }
  }
}

export async function loadRepos() {
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
    el.innerHTML = repos.map((repo) => `<tr>
      <td class="mono-sm">${esc(repo.path)}</td>
      <td>${esc(formatUnixTimestamp(repo.last_scan))}</td>
      <td>${esc(String(repo.source_file_count || 0))}</td>
      <td>${esc(String(repo.test_file_count || 0))}</td>
      <td>${esc(String(repo.annotation_count || 0))}</td>
      <td>${esc(String(repo.commit_count || 0))}</td>
      <td><button class="btn-danger" data-action="delete-repo" data-slot="${Number.isInteger(repo.slot) ? repo.slot : 0}" title="Remove repo">×</button></td>
    </tr>`).join('');
  } catch {}
}

export async function loadDiagnostics() {
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
    el.innerHTML = diagnostics.map((diagnostic) => `<div class="repo-row repo-row--block">
      <div><a href="#" class="guide-link" data-action="open-guide" data-guide-code="E${esc(String(diagnostic.code))}"><strong>E${esc(String(diagnostic.code))}</strong></a> ${esc(diagnostic.title || '')} <span class="gap-badge-sev ${(diagnostic.severity || 'info').toLowerCase()}">${esc((diagnostic.severity || '').toLowerCase())}</span></div>
      <div class="text-sm-muted">${esc(diagnostic.message || '')}</div>
      ${diagnostic.subject ? `<div class="mono-sm text-sm-subtle">${esc(diagnostic.subject)}</div>` : ''}
    </div>`).join('');
  } catch (error) {
    el.innerHTML = `<div class="empty-state">Failed to load diagnostics: ${esc(error.message)}</div>`;
  }
}

export async function loadCodeTraceability() {
  const container = document.getElementById('code-body');
  if (!container) return;
  container.innerHTML = '<div class="empty-state loading-pulse">Loading…</div>';
  await Promise.all([loadRepos(), loadDiagnostics(), loadCoverageGaps(), loadRecentCommits(), loadCodeScanStatus()]);

  let files;
  try {
    const res = await fetch('/query/code-traceability');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    files = await res.json();
  } catch (error) {
    container.innerHTML = `<div class="empty-state">Error: ${esc(error.message)}</div>`;
    return;
  }

  const combined = [...(files.source_files || []), ...(files.test_files || [])];
  if (combined.length === 0) {
    container.innerHTML = '<div class="empty-state">No source files indexed yet.</div>';
    return;
  }

  const groups = new Map();
  combined.forEach((file) => {
    const props = propsObj(file.properties);
    const repo = props.repo || 'Unknown Repo';
    if (!groups.has(repo)) groups.set(repo, []);
    groups.get(repo).push({ node: file, props });
  });

  container.innerHTML = Array.from(groups.entries()).map(([repo, entries]) => {
    const rows = entries.map(({ node, props }) => {
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

export async function expandFile(row, filePath) {
  const btn = row.querySelector('.expand-btn');
  if (row.dataset.expanded === '1') {
    row.nextElementSibling?.remove();
    row.dataset.expanded = '0';
    if (btn) {
      btn.classList.remove('open');
      btn.setAttribute('aria-expanded', 'false');
    }
    return;
  }

  let annotations = [];
  try {
    const res = await fetch('/query/file-annotations?file_path=' + encodeURIComponent(filePath));
    if (res.ok) annotations = await res.json();
  } catch {}

  const detail = document.createElement('tr');
  detail.className = 'file-annotation-row';
  const annHtml = annotations.length
    ? annotations.map((annotation) => {
      const props = propsObj(annotation.properties);
      return `<div class="ann-row">
        <code>${esc(props.req_id || annotation.id)}</code>
        <span class="ann-line">line ${esc(String(props.line_number || ''))}</span>
        <span class="ann-blame">${esc(props.blame_author || '')} ${esc(props.short_hash || '')}</span>
      </div>`;
    }).join('')
    : '<em class="text-hint">No annotations found.</em>';
  detail.innerHTML = `<td colspan="4"><div class="file-annotations">${annHtml}</div></td>`;
  row.parentNode.insertBefore(detail, row.nextSibling);
  row.dataset.expanded = '1';
  if (btn) {
    btn.classList.add('open');
    btn.setAttribute('aria-expanded', 'true');
  }
}

export async function loadCoverageGaps() {
  const unimplementedEl = document.getElementById('unimplemented-list');
  const untestedEl = document.getElementById('untested-files-list');
  if (!unimplementedEl || !untestedEl) return;
  const [unimplementedRes, untestedRes] = await Promise.all([
    fetch('/query/unimplemented-requirements'),
    fetch('/query/untested-source-files'),
  ]);
  const unimplemented = unimplementedRes.ok ? await unimplementedRes.json() : [];
  const untested = untestedRes.ok ? await untestedRes.json() : [];
  unimplementedEl.innerHTML = renderSimpleNodeList(unimplemented, 'No unimplemented requirements.');
  untestedEl.innerHTML = renderSimpleNodeList(untested, 'No untested source files.');
}

export async function loadRecentCommits() {
  const el = document.getElementById('recent-commits');
  if (!el) return;
  try {
    const res = await fetch('/query/recent-commits');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const commits = await res.json();
    if (!commits.length) {
      el.innerHTML = '<em class="text-hint">No recent commits. Add a repo and run Scan Now.</em>';
      return;
    }
    el.innerHTML = commits.map((commit) => {
      const props = propsObj(commit.properties);
      return `<div class="repo-row repo-row--block">
        <div><strong>${esc(props.short_hash || commit.id)}</strong> ${esc(props.date || '')} ${esc(props.author || '')}</div>
        <div class="text-sm-muted">${esc(props.message || '')}</div>
        <div class="text-sm-subtle">${esc((props.req_ids || []).join(', '))}</div>
      </div>`;
    }).join('');
  } catch (error) {
    el.innerHTML = `<div class="empty-state">Failed to load commits: ${esc(error.message)}</div>`;
  }
}
