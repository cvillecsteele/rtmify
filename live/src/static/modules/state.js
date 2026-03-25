export let licenseStatusCache = null;
export let currentStatus = null;
export const PENDING_WORKSPACE_TAB_KEY = 'rtmify.pendingWorkspaceTab';

export const TAB_GROUP = {
  requirements: 'data',
  'user-needs': 'data',
  'design-artifacts': 'data',
  tests: 'data',
  risks: 'data',
  rtm: 'data',
  'design-boms': 'bom',
  'bom-components': 'bom',
  'bom-coverage': 'bom',
  'bom-usage': 'bom',
  'bom-gaps': 'bom',
  'bom-impact': 'bom',
  'software-boms': 'soup',
  'soup-components': 'soup',
  'soup-gaps': 'soup',
  'soup-licenses': 'soup',
  'soup-safety': 'soup',
  'chain-gaps': 'analysis',
  impact: 'analysis',
  review: 'analysis',
  'guide-errors': 'guide',
  'mcp-ai': 'guide',
  code: 'code',
  reports: 'reports',
  workbooks: 'settings',
  'design-bom-sync': 'settings',
  'soup-sync': 'settings',
  info: 'settings',
};

export const GROUP_DEFAULTS = {
  data: 'user-needs',
  bom: 'design-boms',
  soup: 'software-boms',
  analysis: 'chain-gaps',
  guide: 'guide-errors',
  code: 'code',
  reports: 'reports',
};

export const workbookState = {
  activeWorkbookId: null,
  workbooks: [],
  removedWorkbooks: [],
  switching: false,
};

export const bomState = {
  designBoms: [],
  selectedProduct: null,
  selectedBomName: null,
};

export const soupState = {
  softwareBoms: [],
  selectedProduct: null,
  selectedBomName: null,
};

export const artifactState = {
  artifacts: [],
  selectedArtifactId: null,
};

export let guideErrorsCache = null;
export let guideLookupByAnchor = new Map();
export let guideLookupByKey = new Map();
export let pendingGuideAnchor = null;

export const lobbyState = {
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

export const LOBBY_PROFILES = [
  { id: 'aerospace', backendId: 'aerospace', label: 'Aerospace', standards: 'DO-178C · AS9100D', tagline: 'Authorize your DO-178C traceability instrument' },
  { id: 'automotive', backendId: 'automotive', label: 'Automotive', standards: 'ISO 26262 · ASPICE', tagline: 'Authorize your ISO 26262 / ASPICE workspace' },
  { id: 'defense', backendId: 'aerospace', label: 'Defense', standards: 'DO-178C · MIL-STD-882 · DEF STAN 00-56', tagline: 'Authorize your defense safety workspace' },
  { id: 'industrial', backendId: 'generic', label: 'Industrial Automation', standards: 'IEC 61511 · IEC 62443', tagline: 'Authorize your functional safety workspace' },
  { id: 'maritime', backendId: 'generic', label: 'Maritime & Offshore', standards: 'DNV GL · IEC 61508', tagline: 'Authorize your maritime safety workspace' },
  { id: 'medical', backendId: 'medical', label: 'Medical Device', standards: 'ISO 13485 · IEC 62304 · FDA 21 CFR Part 11', tagline: 'Authorize your IEC 62304 / ISO 13485 workspace' },
  { id: 'nuclear', backendId: 'generic', label: 'Nuclear', standards: 'IEC 61513 · IEEE 603', tagline: 'Authorize your nuclear I&C traceability workspace' },
  { id: 'rail', backendId: 'generic', label: 'Rail', standards: 'EN 50128 · EN 50129', tagline: 'Authorize your EN 50128 workspace' },
  { id: 'samd', backendId: 'medical', label: 'Software as a Medical Device', standards: 'IEC 62304 · FDA SaMD · IMDRF', tagline: 'Authorize your FDA SaMD workspace' },
  { id: 'space', backendId: 'aerospace', label: 'Space', standards: 'ECSS · NASA-STD-8739', tagline: 'Authorize your ECSS / NASA workspace' },
];

export const PROFILE_ICONS = {
  aerospace: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16l-9-13-9 13h4l5-7 5 7z"/><path d="M3 16h18"/></svg>',
  automotive: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><line x1="12" y1="3" x2="12" y2="9"/><line x1="12" y1="15" x2="12" y2="21"/><line x1="3" y1="12" x2="9" y2="12"/><line x1="15" y1="12" x2="21" y2="12"/></svg>',
  defense: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6l7-3z"/></svg>',
  industrial: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.07 4.93a10 10 0 010 14.14M4.93 4.93a10 10 0 000 14.14M12 2v2M12 20v2M2 12h2M20 12h2"/></svg>',
  maritime: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="5" r="2"/><line x1="12" y1="7" x2="12" y2="14"/><path d="M7 14c0 3 2.5 5 5 6 2.5-1 5-3 5-6H7z"/><line x1="7" y1="11" x2="17" y2="11"/></svg>',
  medical: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3H5a2 2 0 00-2 2v3m18 0V5a2 2 0 00-2-2h-3M3 16v3a2 2 0 002 2h3m8 0h3a2 2 0 002-2v-3M9 12h6M12 9v6"/></svg>',
  nuclear: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="2"/><path d="M12 2a10 10 0 100 20A10 10 0 0012 2z" stroke-dasharray="3 3"/><path d="M12 4v4M12 16v4M4 12h4M16 12h4"/></svg>',
  rail: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="13" rx="2"/><circle cx="8.5" cy="13.5" r="1.5"/><circle cx="15.5" cy="13.5" r="1.5"/><path d="M8 20l-2 2M16 20l2 2M5 20h14"/><line x1="4" y1="8" x2="20" y2="8"/></svg>',
  samd: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="13" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/><path d="M10 10h4M12 8v4"/></svg>',
  space: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2C8 2 5 7 5 12c0 2.5 1 5 3 7l4-4 4 4c2-2 3-4.5 3-7 0-5-3-10-7-10z"/><circle cx="12" cy="11" r="2"/><path d="M5 19l-2 2M19 19l2 2"/></svg>',
};

export const PROFILE_DESCRIPTIONS = {
  generic: 'Basic requirements traceability',
  medical: 'ISO 13485 / IEC 62304 / FDA 21 CFR Part 11',
  aerospace: 'DO-178C / AS9100',
  automotive: 'ISO 26262 / ASPICE',
};

export function setCurrentStatus(value) {
  currentStatus = value;
}

export function setLicenseStatusCache(value) {
  licenseStatusCache = value;
}

export function setGuideErrorsCache(value) {
  guideErrorsCache = value;
}

export function setGuideLookupByAnchor(value) {
  guideLookupByAnchor = value;
}

export function setGuideLookupByKey(value) {
  guideLookupByKey = value;
}

export function setPendingGuideAnchor(value) {
  pendingGuideAnchor = value;
}
