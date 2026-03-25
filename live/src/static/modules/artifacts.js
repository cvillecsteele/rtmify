import { esc, formatUnixTimestamp, propsObj } from '/modules/helpers.js';
import { artifactState } from '/modules/state.js';
import { currentIngestToken } from '/modules/uploads.js';

export async function loadDesignArtifacts(force = false) {
  const errEl = document.getElementById('design-artifacts-error');
  const detailEl = document.getElementById('design-artifact-detail');
  if (errEl) errEl.style.display = 'none';
  try {
    const res = await fetch('/api/v1/design-artifacts', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    artifactState.artifacts = Array.isArray(data) ? data : [];
    const stillSelected = artifactState.artifacts.some((item) => item.artifact_id === artifactState.selectedArtifactId);
    if (force || !stillSelected) artifactState.selectedArtifactId = artifactState.artifacts[0]?.artifact_id || null;
    renderDesignArtifactList();
    if (artifactState.selectedArtifactId) {
      await loadSelectedDesignArtifactDetail();
    } else if (detailEl) {
      detailEl.innerHTML = '<div class="empty-state">No design artifacts ingested yet.</div>';
    }
  } catch (error) {
    artifactState.artifacts = [];
    artifactState.selectedArtifactId = null;
    renderDesignArtifactList();
    if (detailEl) detailEl.innerHTML = `<div class="empty-state">Failed to load design artifacts: ${esc(error.message)}</div>`;
    if (errEl) {
      errEl.textContent = 'Failed to load design artifacts: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export function renderDesignArtifactList() {
  const bodyEl = document.getElementById('design-artifact-list-body');
  if (!bodyEl) return;
  if (!artifactState.artifacts.length) {
    bodyEl.innerHTML = '<tr><td colspan="9" class="empty-state">No design artifacts available for the active workbook.</td></tr>';
    return;
  }
  bodyEl.innerHTML = artifactState.artifacts.map((item) => {
    const selected = item.artifact_id === artifactState.selectedArtifactId;
    const canReingest = !!item.reingestable;
    const reingestLabel = canReingest ? 'Re-ingest' : ((item.kind === 'rtm_workbook' && (item.ingest_source || '') === 'workbook_sync') ? 'Provider-managed' : 'Read-only');
    return `<tr${selected ? ' class="warning"' : ''} data-action="select-design-artifact" data-artifact-id="${esc(item.artifact_id || '')}">
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

export async function selectDesignArtifact(artifactId) {
  artifactState.selectedArtifactId = artifactId || null;
  renderDesignArtifactList();
  await loadSelectedDesignArtifactDetail();
}

export async function loadSelectedDesignArtifactDetail() {
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
    const conflictRequirementIds = new Set(conflictRows.map((item) => item.req_id).filter(Boolean));
    const nullTextRows = assertions.filter((item) => !item.text || item.parse_status === 'null_text');
    const ambiguousRows = assertions.filter((item) => item.parse_status === 'ambiguous_within_artifact');
    const lowConfidenceRows = assertions.filter((item) => String(item.parse_status || '').startsWith('low_confidence_'));
    const newIds = Array.isArray(data.new_since_last_ingest) ? data.new_since_last_ingest : [];
    const ingestSummary = data.ingest_summary || null;
    detailEl.innerHTML = `
      <div class="toolbar card-toolbar">
        <span class="card-title">${esc(props.display_name || artifactState.selectedArtifactId || '')}</span>
      </div>
      <div class="bom-metrics">
        <div class="bom-metric"><div class="bom-metric-label">Kind</div><div class="bom-metric-value">${esc(formatDesignArtifactKind(props.kind || ''))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Requirements</div><div class="bom-metric-value">${esc(String(assertions.length))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Conflicts</div><div class="bom-metric-value">${esc(String(conflictRequirementIds.size))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Null Text</div><div class="bom-metric-value">${esc(String(nullTextRows.length))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Ambiguous</div><div class="bom-metric-value">${esc(String(extractionSummary.ambiguous_within_artifact_count || ambiguousRows.length || 0))}</div></div>
        <div class="bom-metric"><div class="bom-metric-label">Low Confidence</div><div class="bom-metric-value">${esc(String(extractionSummary.low_confidence_count || lowConfidenceRows.length || 0))}</div></div>
      </div>
      <div class="repo-row repo-row--block">
        <div><strong>Path</strong> ${esc(props.path || '—')}</div>
        <div class="text-sm-subtle">Logical key ${esc(props.logical_key || '—')} · source ${esc(props.ingest_source || '—')} · last ingested ${esc(formatUnixTimestamp(props.last_ingested_at))}</div>
      </div>
      ${ingestSummary ? `<div class="repo-row repo-row--block"><div><strong>Last Ingest</strong> ${esc(String(ingestSummary.disposition || ''))}</div><div class="text-sm-subtle">seen ${esc(String(ingestSummary.requirements_seen || 0))} · added ${esc(String(ingestSummary.nodes_added || 0))} · updated ${esc(String(ingestSummary.nodes_updated || 0))} · deleted ${esc(String(ingestSummary.nodes_deleted || 0))} · unchanged ${esc(String(ingestSummary.unchanged || 0))}</div></div>` : ''}
      ${newIds.length ? `<div class="repo-row repo-row--block"><div><strong>New Since Last Ingest</strong></div><div class="text-sm-subtle">${newIds.map((id) => `<span class="req-id">${esc(id)}</span>`).join(' ')}</div></div>` : ''}
      ${conflictRows.length ? `<div class="repo-row repo-row--block"><div><strong>Cross-Source Conflicts</strong></div><div class="text-sm-subtle">${esc(String(conflictRequirementIds.size))} requirement${conflictRequirementIds.size === 1 ? '' : 's'} conflict with another artifact source.</div></div><div class="table-scroll mb-12"><table><thead><tr><th>Requirement</th><th>Other Artifact</th><th>Kind</th><th>Other Text</th></tr></thead><tbody>${conflictRows.map((item) => `<tr><td><span class="req-id">${esc(item.req_id || '—')}</span></td><td>${esc(item.other_artifact_id || '—')}</td><td>${esc(formatDesignArtifactKind(item.other_source_kind || ''))}</td><td>${esc(item.other_text || '—')}</td></tr>`).join('')}</tbody></table></div>` : ''}
      ${nullTextRows.length ? `<div class="repo-row repo-row--block"><div><strong>Null Text Rows</strong></div><div class="text-sm-subtle">${nullTextRows.map((item) => `<span class="req-id">${esc(item.req_id || '—')}</span>`).join(' ')}</div></div>` : ''}
      ${ambiguousRows.length ? `<div class="repo-row repo-row--block"><div><strong>Ambiguous Rows</strong></div><div class="text-sm-subtle">${ambiguousRows.map((item) => `<span class="req-id">${esc(item.req_id || '—')}</span>`).join(' ')}</div></div>` : ''}
      ${lowConfidenceRows.length ? `<div class="repo-row repo-row--block"><div><strong>Low Confidence Rows</strong></div><div class="text-sm-subtle">${lowConfidenceRows.map((item) => `<span class="req-id">${esc(item.req_id || '—')}</span> (${esc(item.parse_status || '')})`).join(' · ')}</div></div>` : ''}
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
          ${assertions.map((item) => `<tr>
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
  } catch (error) {
    detailEl.innerHTML = `<div class="empty-state">Failed to load design artifact detail: ${esc(error.message)}</div>`;
  }
}

export async function uploadDesignArtifactFile(file) {
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
  } catch (error) {
    resultEl.textContent = '';
    if (errEl) {
      errEl.textContent = 'Design artifact upload failed: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export function renderDesignArtifactUploadResult(data, fallbackName) {
  return `<div class="repo-row repo-row--block">
    <div><strong>${esc(data.artifact_id || fallbackName || 'artifact')}</strong></div>
    <div class="text-sm-subtle">${esc(formatDesignArtifactKind(data.kind || ''))} · stored at ${esc(data.path || '—')}</div>
    ${data.ingest_summary ? `<div class="text-sm-subtle">seen ${esc(String(data.ingest_summary.requirements_seen || 0))} · conflicts ${esc(String(data.ingest_summary.conflicts_detected || 0))} · null text ${esc(String(data.ingest_summary.null_text_count || 0))} · low confidence ${esc(String(data.ingest_summary.low_confidence_count || 0))}</div>` : ''}
  </div>`;
}

export async function reingestDesignArtifact(artifactId) {
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
  } catch (error) {
    if (errEl) {
      errEl.textContent = 'Re-ingest failed: ' + error.message;
      errEl.style.display = 'block';
    }
  }
}

export function formatDesignArtifactKind(kind) {
  if (kind === 'rtm_workbook') return 'RTM Workbook';
  if (kind === 'urs_docx') return 'URS';
  if (kind === 'srs_docx') return 'SRS';
  if (kind === 'swrs_docx') return 'SwRS';
  if (kind === 'hrs_docx') return 'HRS';
  if (kind === 'sysrd_docx') return 'SysRD / SRD';
  return kind || '—';
}
