import { GROUP_DEFAULTS, TAB_GROUP } from '/modules/state.js';
import { closestActionElement } from '/modules/helpers.js';

export function createNavigationController(deps) {
  function showGroup(name) {
    document.querySelectorAll('.nav-primary button[data-group]').forEach((btn) =>
      btn.classList.toggle('active', btn.dataset.group === name));
    document.querySelectorAll('.nav-sub').forEach((nav) =>
      nav.classList.toggle('active', nav.dataset.group === name));
    if (GROUP_DEFAULTS[name]) showTab(GROUP_DEFAULTS[name]);
  }

  function showTab(name) {
    document.querySelectorAll('section').forEach((section) => section.classList.remove('active'));
    document.getElementById('tab-' + name)?.classList.add('active');

    const group = TAB_GROUP[name];
    document.querySelectorAll('.nav-primary button[data-group]').forEach((btn) =>
      btn.classList.toggle('active', btn.dataset.group === group));
    document.querySelectorAll('.nav-sub').forEach((nav) => {
      const isActive = nav.dataset.group === group;
      nav.classList.toggle('active', isActive);
      if (isActive) {
        nav.querySelectorAll('button[data-tab]').forEach((btn) =>
          btn.classList.toggle('active', btn.dataset.tab === name));
      }
    });

    const loaders = {
      review: deps.loadSuspects,
      'design-artifacts': deps.loadDesignArtifacts,
      'design-boms': deps.loadDesignBomWorkspace,
      'bom-components': deps.loadBomComponents,
      'bom-coverage': deps.loadBomCoverage,
      'bom-gaps': deps.loadBomGaps,
      'bom-impact': deps.loadBomImpactAnalysis,
      'software-boms': deps.loadSoupWorkspace,
      'soup-components': deps.loadSoupComponents,
      'soup-gaps': deps.loadSoupGaps,
      'soup-licenses': deps.loadSoupLicenses,
      'soup-safety': deps.loadSoupSafetyClasses,
      'guide-errors': deps.loadGuideErrors,
      code: deps.loadCodeTraceability,
      info: deps.loadInfo,
    };
    if (name === 'chain-gaps') {
      deps.loadProfileState?.();
      deps.loadChainGaps?.();
    } else if (name === 'mcp-ai') {
      deps.loadMcpHelp?.();
      deps.loadInfo?.();
    } else {
      loaders[name]?.();
    }
  }

  function showSettingsTab(name) {
    document.getElementById('settings-panel')?.style.setProperty('display', 'none');
    document.querySelectorAll('section').forEach((section) => section.classList.remove('active'));
    document.getElementById('tab-' + name)?.classList.add('active');
    document.querySelectorAll('.nav-primary button[data-group]').forEach((btn) => btn.classList.remove('active'));
    document.querySelectorAll('.nav-sub').forEach((nav) => nav.classList.remove('active'));
    if (name === 'workbooks') deps.loadWorkbooksView?.();
    if (name === 'design-bom-sync') deps.loadDesignBomSyncSettings?.();
    if (name === 'soup-sync') deps.loadSoupSyncSettings?.();
    if (name === 'info') deps.loadInfo?.();
  }

  function toggleSettings(event) {
    event?.stopPropagation();
    const panel = document.getElementById('settings-panel');
    if (!panel) return;
    panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
  }

  function handleActionClick(event) {
    const actionEl = closestActionElement(event.target);
    if (!actionEl) return false;
    switch (actionEl.dataset.action) {
      case 'open-guide':
        event.preventDefault();
        void deps.openGuideForCode?.(actionEl.dataset.guideCode, actionEl.dataset.guideVariant ? { variant: actionEl.dataset.guideVariant } : {});
        return true;
      case 'toggle-row':
        event.preventDefault();
        void deps.toggleRow?.(actionEl.dataset.id || '', actionEl, Number(actionEl.dataset.colspan || 0));
        return true;
      case 'drawer-nav':
        event.preventDefault();
        void deps.drawerNav?.(actionEl.dataset.id || '');
        return true;
      case 'clear-suspect':
        event.preventDefault();
        void deps.clearSuspect?.(actionEl.dataset.id || '');
        return true;
      case 'toggle-tree-section':
        event.preventDefault();
        deps.toggleTreeSection?.(actionEl);
        return true;
      case 'toggle-tree-node':
        event.preventDefault();
        void deps.toggleTreeNode?.(actionEl, actionEl.dataset.id || '');
        return true;
      case 'select-profile':
        event.preventDefault();
        deps.selectProfile?.(actionEl.dataset.profileId || '');
        return true;
      case 'delete-repo':
        event.preventDefault();
        void deps.deleteRepo?.(Number(actionEl.dataset.slot || 0));
        return true;
      case 'switch-workbook':
        event.preventDefault();
        void deps.switchWorkbook?.(actionEl.dataset.id || '');
        return true;
      case 'select-design-bom':
        event.preventDefault();
        void deps.selectDesignBom?.(actionEl.dataset.product || '', actionEl.dataset.bomName || '');
        return true;
      case 'select-software-bom':
        event.preventDefault();
        void deps.selectSoftwareBom?.(actionEl.dataset.product || '', actionEl.dataset.bomName || '');
        return true;
      case 'select-design-artifact':
        event.preventDefault();
        void deps.selectDesignArtifact?.(actionEl.dataset.artifactId || '');
        return true;
      case 'reingest-design-artifact':
        event.preventDefault();
        void deps.reingestDesignArtifact?.(actionEl.dataset.artifactId || '');
        return true;
      case 'inspect-bom-component':
        event.preventDefault();
        void deps.inspectBomComponent?.(
          actionEl.dataset.itemId || '',
          actionEl.dataset.part || '',
          actionEl.dataset.product || '',
          actionEl.dataset.bomName || '',
        );
        return true;
      case 'rename-workbook':
        event.preventDefault();
        void deps.renameWorkbook?.(actionEl.dataset.id || '');
        return true;
      case 'remove-workbook':
        event.preventDefault();
        void deps.removeWorkbook?.(actionEl.dataset.id || '');
        return true;
      case 'purge-workbook':
        event.preventDefault();
        void deps.purgeWorkbook?.(actionEl.dataset.id || '', actionEl.dataset.name || '');
        return true;
      case 'expand-file': {
        event.preventDefault();
        const row = actionEl.closest('tr');
        if (row) void deps.expandFile?.(row, row.dataset.filePath || actionEl.dataset.filePath || '');
        return true;
      }
      default:
        return false;
    }
  }

  return { showGroup, showTab, showSettingsTab, toggleSettings, handleActionClick };
}
