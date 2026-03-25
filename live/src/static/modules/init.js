import { bindGuideNavigation, handleGuideHash, loadGuideErrors, openGuideForCode } from '/modules/guide.js';
import { renderRequirements, renderRisks, renderRTM, renderTests, renderUserNeeds } from '/modules/rtm-tables.js';
import { closeDrawer, drawerBack, drawerNav, openNode, renderDrawerNode } from '/modules/node-drawer.js';
import { closeAllExpandedRows, toggleRow, toggleTreeNode, toggleTreeSection } from '/modules/row-expand.js';
import { runImpact } from '/modules/impact.js';
import { bindSuspectHooks, clearSuspect, loadSuspects, refreshSuspectBadge } from '/modules/suspects.js';
import { loadBomGaps, loadBomImpactAnalysis, runBomPartUsage } from '/modules/bom-queries.js';
import { bindWorkbookHooks, loadWorkbooksState, loadWorkbooksView, purgeWorkbook, removeWorkbook, renameWorkbook, switchWorkbook, switchWorkbookFromHeader } from '/modules/workbooks.js';
import { loadDesignArtifacts, reingestDesignArtifact, selectDesignArtifact, uploadDesignArtifactFile } from '/modules/artifacts.js';
import { bindUploadHooks, copyTestResultsToken, regenerateTestResultsToken, uploadBomArtifactFile, uploadSoupArtifactFile } from '/modules/uploads.js';
import { bindDesignBomHooks, deleteDesignBomSync, downloadDesignBomReport, inspectBomComponent, loadBomComponents, loadBomCoverage, loadDesignBomSyncSettings, loadDesignBomWorkspace, saveDesignBomSync, selectDesignBom, toggleDesignBomSyncKind, validateDesignBomSync } from '/modules/design-bom.js';
import { deleteSoupSync, downloadSoupReport, loadSelectedSoupDetail, loadSoupComponents, loadSoupGaps, loadSoupLicenses, loadSoupSafetyClasses, loadSoupSyncSettings, loadSoupWorkspace, saveSoupSync, selectSoftwareBom, toggleSoupSyncKind, validateSoupSync } from '/modules/soup.js';
import { addRepo, deleteRepo, expandFile, loadCodeTraceability, scanAndLoadCodeTraceability } from '/modules/code.js';
import { changeProfile, loadChainGaps, loadProfileState, provisionMissingTabs } from '/modules/chain-gaps.js';
import { bindStatusUiHooks, loadInfo, loadMcpHelp, loadStatus, showPreviewFeatureHelp, updateLobbyConnectionMessage } from '/modules/status.js';
import { bindLicenseHooks, chooseLicenseFile, clearInstalledLicense, hideLicenseGate, importLicenseFile, loadLicenseStatus, refreshLicenseStatus, showLicenseGate, syncLicenseInfo } from '/modules/license.js';
import { bindLobbyHooks, clearCredential, clearProfileSelection, clearSourceArtifact, connectWorkbookSource, continueInPreviewMode, copyEmail, dismissAttachWorkbookPrompt, enterWorkspace, lobbyBack, lobbyNext, onSaDragLeave, onSaDragOver, onSaDrop, onSourceArtifactDragLeave, onSourceArtifactDragOver, onSourceArtifactDrop, openAddWorkbook, openWorkspace, renderProfileList, selectProfile, selectProvider, selectSourceOfTruth, showLobby, showSuccess, toggleSecretVisibility, uploadOnboardingSourceArtifact, uploadSaFile } from '/modules/lobby.js';
import { createNavigationController } from '/modules/nav.js';

function bindClick(id, handler) {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('click', (event) => {
    event.preventDefault();
    void handler(event);
  });
}

function bindChange(id, handler) {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('change', (event) => void handler(event));
}

function bindEnter(id, handler) {
  const el = document.getElementById(id);
  if (!el) return;
  el.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      void handler(event);
    }
  });
}

function bindFileInput(id, handler) {
  const input = document.getElementById(id);
  if (!input) return;
  input.addEventListener('change', async function () {
    if (this.files && this.files[0]) await handler(this.files[0]);
    this.value = '';
  });
}

function bindDropZone(id, handler, options = {}) {
  const zone = document.getElementById(id);
  if (!zone) return;
  zone.addEventListener('dragover', (event) => {
    event.preventDefault();
    zone.classList.add('drag-over');
    options.onDragOver?.(event);
  });
  zone.addEventListener('dragleave', (event) => {
    zone.classList.remove('drag-over');
    options.onDragLeave?.(event);
  });
  zone.addEventListener('drop', async (event) => {
    event.preventDefault();
    zone.classList.remove('drag-over');
    if (options.onDrop) {
      await options.onDrop(event);
      return;
    }
    const file = event.dataTransfer?.files?.[0];
    if (file) await handler(file);
  });
}

async function loadData() {
  closeAllExpandedRows();
  await Promise.all([
    renderRequirements(),
    renderUserNeeds(),
    renderTests(),
    renderRTM(),
    renderRisks(),
    refreshSuspectBadge(),
  ]);
  await loadProfileState();
  await loadWorkbooksState();
  await loadDesignArtifacts();
  await loadDesignBomWorkspace();
  loadMcpHelp();
  await loadInfo();
}

function bindStaticActions(nav) {
  document.querySelectorAll('.nav-primary button[data-group]').forEach((btn) => {
    btn.addEventListener('click', () => nav.showGroup(btn.dataset.group));
  });
  document.querySelectorAll('.nav-sub button[data-tab]').forEach((btn) => {
    btn.addEventListener('click', () => nav.showTab(btn.dataset.tab));
  });
  document.querySelectorAll('[data-settings-tab]').forEach((btn) => {
    btn.addEventListener('click', () => nav.showSettingsTab(btn.dataset.settingsTab));
  });
  document.querySelectorAll('[data-provider]').forEach((el) => {
    el.addEventListener('click', () => selectProvider(el.dataset.provider));
  });
  document.querySelectorAll('[data-source-of-truth]').forEach((el) => {
    el.addEventListener('click', () => selectSourceOfTruth(el.dataset.sourceOfTruth));
  });
}

function bindAppEvents(nav) {
  bindStaticActions(nav);
  bindClick('drawer-overlay', closeDrawer);
  bindClick('drawer-back', drawerBack);
  bindClick('drawer-close', closeDrawer);
  bindClick('lobby-back-btn', lobbyBack);
  bindClick('s1-continue-btn', () => lobbyNext(1));
  bindClick('s2-continue-btn', () => lobbyNext(2));
  bindClick('s3-continue-btn', () => lobbyNext(3));
  bindClick('preview-continue-btn', continueInPreviewMode);
  bindClick('open-workspace-btn', openWorkspace);
  bindClick('refresh-license-status-btn', refreshLicenseStatus);
  bindClick('license-import-btn', chooseLicenseFile);
  bindClick('license-clear-btn', clearInstalledLicense);
  bindClick('header-home-btn', showLobby);
  bindChange('workbook-switcher', switchWorkbookFromHeader);
  bindClick('suspect-header-badge', () => nav.showTab('review'));
  bindClick('preview-install-license-btn', async () => showLicenseGate(await loadLicenseStatus(true)));
  bindClick('preview-feature-help-btn', showPreviewFeatureHelp);
  bindClick('attach-workbook-btn', openAddWorkbook);
  bindClick('attach-workbook-dismiss-btn', dismissAttachWorkbookPrompt);
  bindClick('settings-toggle-btn', nav.toggleSettings);
  bindClick('requirements-refresh-btn', loadData);
  bindClick('design-boms-refresh-btn', () => loadDesignBomWorkspace(true));
  bindClick('bom-upload-browse-btn', () => document.getElementById('bom-upload-input')?.click());
  bindChange('design-boms-include-obsolete', () => loadDesignBomWorkspace(true));
  bindClick('bom-components-refresh-btn', loadBomComponents);
  bindEnter('bom-components-search', loadBomComponents);
  bindClick('bom-coverage-refresh-btn', loadBomCoverage);
  bindClick('bom-usage-run-btn', runBomPartUsage);
  bindEnter('bom-usage-part', runBomPartUsage);
  bindClick('bom-gaps-refresh-btn', loadBomGaps);
  bindClick('bom-impact-run-btn', loadBomImpactAnalysis);
  bindClick('software-boms-refresh-btn', () => loadSoupWorkspace(true));
  bindClick('soup-upload-browse-btn', () => document.getElementById('soup-upload-input')?.click());
  bindChange('software-boms-include-obsolete', () => loadSoupWorkspace(true));
  bindClick('soup-components-refresh-btn', loadSoupComponents);
  bindEnter('soup-components-search', loadSoupComponents);
  bindClick('soup-gaps-refresh-btn', loadSoupGaps);
  bindClick('soup-licenses-refresh-btn', loadSoupLicenses);
  bindEnter('soup-licenses-license', loadSoupLicenses);
  bindClick('soup-safety-refresh-btn', loadSoupSafetyClasses);
  bindEnter('soup-safety-class', loadSoupSafetyClasses);
  bindClick('design-artifacts-refresh-btn', () => loadDesignArtifacts(true));
  bindClick('design-artifact-upload-browse-btn', () => document.getElementById('design-artifact-upload-input')?.click());
  bindEnter('impact-input', runImpact);
  bindClick('impact-run-btn', runImpact);
  bindClick('review-refresh-btn', loadSuspects);
  bindClick('chain-gaps-refresh-btn', loadChainGaps);
  bindChange('profile-select', changeProfile);
  bindClick('profile-provision-btn', provisionMissingTabs);
  bindClick('guide-errors-refresh-btn', () => loadGuideErrors(true));
  bindClick('repo-add-btn', addRepo);
  bindClick('code-scan-btn', scanAndLoadCodeTraceability);
  bindClick('copy-test-results-token-btn', copyTestResultsToken);
  bindClick('regenerate-test-results-token-btn', regenerateTestResultsToken);
  bindClick('add-workbook-btn', openAddWorkbook);
  bindClick('workbooks-refresh-btn', loadWorkbooksView);
  bindClick('design-bom-sync-refresh-btn', () => loadDesignBomSyncSettings(true));
  bindChange('design-bom-sync-kind', toggleDesignBomSyncKind);
  bindClick('design-bom-sync-validate-btn', validateDesignBomSync);
  bindClick('design-bom-sync-save-btn', saveDesignBomSync);
  bindClick('design-bom-sync-delete-btn', deleteDesignBomSync);
  bindClick('soup-sync-refresh-btn', () => loadSoupSyncSettings(true));
  bindChange('soup-sync-kind', toggleSoupSyncKind);
  bindClick('soup-sync-validate-btn', validateSoupSync);
  bindClick('soup-sync-save-btn', saveSoupSync);
  bindClick('soup-sync-delete-btn', deleteSoupSync);
  bindClick('info-refresh-btn', loadInfo);
  bindClick('info-license-refresh', refreshLicenseStatus);
  bindClick('info-license-import', chooseLicenseFile);
  bindClick('info-license-clear', clearInstalledLicense);
  bindClick('license-gate-refresh-btn', refreshLicenseStatus);
  bindClick('report-design-bom-pdf-btn', () => downloadDesignBomReport('pdf'));
  bindClick('report-design-bom-md-btn', () => downloadDesignBomReport());
  bindClick('report-design-bom-docx-btn', () => downloadDesignBomReport('docx'));
  bindClick('report-soup-pdf-btn', () => downloadSoupReport('pdf'));
  bindClick('report-soup-md-btn', () => downloadSoupReport());
  bindClick('report-soup-docx-btn', () => downloadSoupReport('docx'));
  bindClick('source-artifact-change-btn', clearSourceArtifact);
  bindClick('source-artifact-zone', () => document.getElementById('source-artifact-file-input')?.click());
  bindClick('sa-upload-zone', () => document.getElementById('sa-file-input')?.click());
  bindClick('sa-loaded-change-btn', clearCredential);
  bindClick('secret-toggle-btn', toggleSecretVisibility);
  bindClick('license-gate-open-btn', async () => showLicenseGate(await loadLicenseStatus(true)));
  bindClick('copy-email-btn', copyEmail);
}

export async function initApp() {
  const nav = createNavigationController({
    loadSuspects,
    loadDesignArtifacts,
    loadDesignBomWorkspace,
    loadBomComponents,
    loadBomCoverage,
    loadBomGaps,
    loadBomImpactAnalysis,
    loadSoupWorkspace,
    loadSoupComponents,
    loadSoupGaps,
    loadSoupLicenses,
    loadSoupSafetyClasses,
    loadProfileState,
    loadChainGaps,
    loadGuideErrors,
    loadCodeTraceability,
    loadMcpHelp,
    loadInfo,
    openGuideForCode,
    toggleRow,
    drawerNav,
    clearSuspect,
    toggleTreeSection,
    toggleTreeNode,
    selectProfile,
    deleteRepo,
    switchWorkbook,
    selectDesignBom,
    selectSoftwareBom,
    selectDesignArtifact,
    reingestDesignArtifact,
    inspectBomComponent,
    renameWorkbook,
    removeWorkbook,
    purgeWorkbook,
    expandFile,
    loadWorkbooksView,
    loadDesignBomSyncSettings,
    loadSoupSyncSettings,
  });

  bindGuideNavigation({ showTab: nav.showTab });
  bindSuspectHooks({ rerenderNode: renderDrawerNode, refreshAll: loadData });
  bindWorkbookHooks({ reloadWorkspace: loadData, loadInfo });
  bindUploadHooks({ loadDesignBomWorkspace, loadSoupWorkspace, loadInfo });
  bindDesignBomHooks({ showTab: nav.showTab });
  bindStatusUiHooks({
    syncLicenseInfo,
    selectProvider,
    selectProfile,
    clearProfileSelection,
    updateLobbyConnectionMessage,
    showGroup: nav.showGroup,
  });
  bindLicenseHooks({ loadStatus, showSuccess, enterWorkspace });
  bindLobbyHooks({
    loadWorkbooksState,
    loadData,
    handleGuideHash,
    showTab: nav.showTab,
    showSettingsTab: nav.showSettingsTab,
  });

  renderProfileList();
  bindAppEvents(nav);

  document.addEventListener('click', (event) => {
    const handled = nav.handleActionClick(event);
    const panel = document.getElementById('settings-panel');
    if (panel) panel.style.display = 'none';
    if (handled) return;
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && document.getElementById('node-drawer')?.classList.contains('open')) {
      closeDrawer();
    }
    const profileRow = event.target instanceof Element ? event.target.closest('[data-action="select-profile"]') : null;
    if (profileRow && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      selectProfile(profileRow.dataset.profileId || '');
    }
  });

  bindFileInput('bom-upload-input', uploadBomArtifactFile);
  bindDropZone('bom-upload-zone', uploadBomArtifactFile);
  bindFileInput('soup-upload-input', uploadSoupArtifactFile);
  bindDropZone('soup-upload-zone', uploadSoupArtifactFile);
  bindFileInput('design-artifact-upload-input', uploadDesignArtifactFile);
  bindDropZone('design-artifact-upload-zone', uploadDesignArtifactFile);
  bindFileInput('sa-file-input', uploadSaFile);
  bindDropZone('sa-upload-zone', uploadSaFile, {
    onDragOver: onSaDragOver,
    onDragLeave: onSaDragLeave,
    onDrop: onSaDrop,
  });
  bindFileInput('source-artifact-file-input', uploadOnboardingSourceArtifact);
  bindDropZone('source-artifact-zone', uploadOnboardingSourceArtifact, {
    onDragOver: onSourceArtifactDragOver,
    onDragLeave: onSourceArtifactDragLeave,
    onDrop: onSourceArtifactDrop,
  });
  bindChange('license-file-input', (event) => importLicenseFile(event.target?.files?.[0] || null));
  document.getElementById('sa-help-link')?.addEventListener('click', (event) => event.stopPropagation());

  window.addEventListener('hashchange', () => {
    void handleGuideHash();
  });

  try {
    const status = await loadStatus(true);
    await loadWorkbooksState();
    if (status.workspace_ready) {
      await enterWorkspace(status);
    } else {
      await showLobby();
    }
  } catch {
    await showLobby();
  }
}
