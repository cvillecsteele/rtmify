import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';

const DEV_LICENSE_HMAC_KEY_HEX = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

function sqlQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function nowTs(): number {
  return Math.floor(Date.now() / 1000);
}

function edgeId(fromId: string, toId: string, label: string): string {
  const hash = crypto.createHash('sha256');
  hash.update(fromId);
  hash.update('|');
  hash.update(toId);
  hash.update('|');
  hash.update(label);
  return hash.digest('hex');
}

function runSql(dbPath: string, sql: string): void {
  execFileSync('sqlite3', [dbPath, sql], { stdio: 'pipe' });
}

export function secureStoreFilePath(dbPath: string): string {
  return `${dbPath}.secure-store.json`;
}

export function writeSecureCredential(dbPath: string, credentialRef: string, secretJson: string): void {
  const filePath = secureStoreFilePath(dbPath);
  let current: Record<string, string> = {};
  if (fs.existsSync(filePath)) {
    current = JSON.parse(fs.readFileSync(filePath, 'utf8')) as Record<string, string>;
  }
  current[credentialRef] = secretJson;
  fs.writeFileSync(filePath, JSON.stringify(current));
}

export function clearSecureStoreFile(dbPath: string): void {
  const filePath = secureStoreFilePath(dbPath);
  if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
}

export function licenseFilePath(dbPath: string): string {
  return `${dbPath}.license.json`;
}

type TestLicenseProduct = 'live' | 'trace';
type TestLicenseTier = 'lab' | 'individual' | 'team' | 'site';

function canonicalPayloadJson(payload: {
  schema: number;
  license_id: string;
  product: TestLicenseProduct;
  tier: TestLicenseTier;
  issued_to: string;
  issued_at: number;
  expires_at: number | null;
  org: string | null;
}): string {
  return `{"expires_at":${payload.expires_at === null ? 'null' : String(payload.expires_at)},"issued_at":${payload.issued_at},"issued_to":${JSON.stringify(payload.issued_to)},"license_id":${JSON.stringify(payload.license_id)},"org":${payload.org === null ? 'null' : JSON.stringify(payload.org)},"product":${JSON.stringify(payload.product)},"schema":${payload.schema},"tier":${JSON.stringify(payload.tier)}}`;
}

export function writeTestLicenseFile(dbPath: string, options?: {
  product?: TestLicenseProduct;
  tier?: TestLicenseTier;
  issuedTo?: string;
  org?: string | null;
  expiresAt?: number | null;
  licenseId?: string;
}): string {
  const payload = {
    schema: 1,
    license_id: options?.licenseId ?? `${(options?.product ?? 'live').toUpperCase()}-TEST-0001`,
    product: options?.product ?? 'live',
    tier: options?.tier ?? 'site',
    issued_to: options?.issuedTo ?? 'playwright@example.com',
    issued_at: nowTs(),
    expires_at: options?.expiresAt ?? null,
    org: options?.org ?? 'RTMify Test Harness',
  } satisfies {
    schema: number;
    license_id: string;
    product: TestLicenseProduct;
    tier: TestLicenseTier;
    issued_to: string;
    issued_at: number;
    expires_at: number | null;
    org: string | null;
  };

  const canonical = canonicalPayloadJson(payload);
  const sig = crypto.createHmac('sha256', Buffer.from(DEV_LICENSE_HMAC_KEY_HEX, 'hex')).update(canonical).digest('hex');
  const filePath = licenseFilePath(dbPath);
  fs.writeFileSync(filePath, JSON.stringify({ payload, sig }));
  return filePath;
}

export function setConfig(dbPath: string, key: string, value: string): void {
  runSql(dbPath, `
INSERT OR REPLACE INTO config (key, value)
VALUES (${sqlQuote(key)}, ${sqlQuote(value)});
`);
}

export function initSchema(dbPath: string): void {
  runSql(dbPath, `
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  properties TEXT NOT NULL,
  row_hash TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  suspect INTEGER NOT NULL DEFAULT 0,
  suspect_reason TEXT
);
CREATE TABLE IF NOT EXISTS node_history (
  node_id TEXT NOT NULL,
  properties TEXT NOT NULL,
  superseded_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
  id TEXT PRIMARY KEY,
  from_id TEXT NOT NULL,
  to_id TEXT NOT NULL,
  label TEXT NOT NULL,
  properties TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_edges_from ON edges(from_id);
CREATE INDEX IF NOT EXISTS idx_edges_to ON edges(to_id);
CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_history_node ON node_history(node_id);
CREATE TABLE IF NOT EXISTS credentials (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runtime_diagnostics (
  dedupe_key TEXT PRIMARY KEY,
  code INTEGER NOT NULL,
  severity TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  source TEXT NOT NULL,
  subject TEXT,
  details_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_runtime_diag_source ON runtime_diagnostics(source);
CREATE INDEX IF NOT EXISTS idx_runtime_diag_subject ON runtime_diagnostics(subject);
`);
}

export function insertNode(dbPath: string, id: string, type: string, properties: Record<string, unknown>): void {
  const ts = nowTs();
  const props = JSON.stringify(properties);
  runSql(dbPath, `
INSERT OR REPLACE INTO nodes (id, type, properties, row_hash, created_at, updated_at, suspect, suspect_reason)
VALUES (${sqlQuote(id)}, ${sqlQuote(type)}, ${sqlQuote(props)}, NULL, ${ts}, ${ts}, 0, NULL);
`);
}

export function insertEdge(dbPath: string, fromId: string, toId: string, label: string): void {
  const ts = nowTs();
  runSql(dbPath, `
INSERT OR REPLACE INTO edges (id, from_id, to_id, label, properties, created_at)
VALUES (${sqlQuote(edgeId(fromId, toId, label))}, ${sqlQuote(fromId)}, ${sqlQuote(toId)}, ${sqlQuote(label)}, NULL, ${ts});
`);
}

export function insertRuntimeDiagnostic(dbPath: string, input: {
  dedupeKey: string;
  code: number;
  severity: 'info' | 'warn' | 'err';
  title: string;
  message: string;
  source: string;
  subject?: string | null;
  detailsJson?: string;
}): void {
  const ts = nowTs();
  runSql(dbPath, `
INSERT OR REPLACE INTO runtime_diagnostics (dedupe_key, code, severity, title, message, source, subject, details_json, updated_at)
VALUES (
  ${sqlQuote(input.dedupeKey)},
  ${input.code},
  ${sqlQuote(input.severity)},
  ${sqlQuote(input.title)},
  ${sqlQuote(input.message)},
  ${sqlQuote(input.source)},
  ${input.subject == null ? 'NULL' : sqlQuote(input.subject)},
  ${sqlQuote(input.detailsJson || '{}')},
  ${ts}
);
`);
}

export function seedConfiguredGraph(dbPath: string, options?: {
  requirementId?: string;
  userNeedId?: string;
  requirementStatement?: string;
  userNeedStatement?: string;
}): { requirementId: string; userNeedId: string } {
  initSchema(dbPath);
  clearSecureStoreFile(dbPath);
  const requirementId = options?.requirementId || 'REQ-001';
  const userNeedId = options?.userNeedId || 'UN-001';
  const credentialRef = 'cred_google_seeded';
  writeSecureCredential(dbPath, credentialRef, '{"platform":"google","client_email":"svc@example.com","private_key":"pem"}');
  runSql(dbPath, `
INSERT OR REPLACE INTO config (key, value) VALUES
('platform', 'google'),
('workbook_url', 'https://docs.google.com/spreadsheets/d/fake-sheet/edit'),
('workbook_label', 'fake-sheet'),
('credential_display', 'svc@example.com'),
('google_sheet_id', 'fake-sheet'),
('credential_ref', '${credentialRef}'),
('credential_backend', 'test_memory'),
('credential_store_version', '1'),
('profile', 'generic');
`);
  insertNode(dbPath, userNeedId, 'UserNeed', {
    statement: options?.userNeedStatement || 'The system shall be easy to install by a non-technical user.',
    source: 'Customer',
    priority: 'High',
  });
  insertNode(dbPath, requirementId, 'Requirement', {
    statement: options?.requirementStatement || 'The mobile app SHALL display a notification within 1 seconds of a breach.',
    status: 'Approved',
    test_group: 'TG-001',
    result: 'PENDING',
  });
  insertEdge(dbPath, requirementId, userNeedId, 'DERIVES_FROM');
  return { requirementId, userNeedId };
}

export function seedLegacyPlaintextConnection(dbPath: string): void {
  initSchema(dbPath);
  clearSecureStoreFile(dbPath);
  const now = nowTs();
  runSql(dbPath, `
INSERT OR REPLACE INTO credentials (id, content, created_at)
VALUES ('cred-google', '{"platform":"google","client_email":"svc@example.com","private_key":"pem"}', ${now});
INSERT OR REPLACE INTO config (key, value) VALUES
('platform', 'google'),
('workbook_url', 'https://docs.google.com/spreadsheets/d/fake-sheet/edit'),
('workbook_label', 'fake-sheet'),
('credential_display', 'svc@example.com'),
('google_sheet_id', 'fake-sheet'),
('profile', 'generic');
`);
}
