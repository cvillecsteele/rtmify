import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';

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

export function seedConfiguredGraph(dbPath: string, options?: {
  requirementId?: string;
  userNeedId?: string;
  requirementStatement?: string;
  userNeedStatement?: string;
}): { requirementId: string; userNeedId: string } {
  initSchema(dbPath);
  const requirementId = options?.requirementId || 'REQ-001';
  const userNeedId = options?.userNeedId || 'UN-001';
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
