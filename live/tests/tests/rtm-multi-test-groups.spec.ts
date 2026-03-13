import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { insertEdge, insertNode, seedConfiguredGraph } from '../helpers/db-seed';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

test('tests tab renders shared test groups against multiple linked requirements', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath, { requirementId: 'REQ-001', userNeedId: 'UN-001' });
  insertNode(dbPath, 'REQ-002', 'Requirement', {
    statement: 'The system SHALL record an audit trail.',
    status: 'Approved',
  });
  insertNode(dbPath, 'TG-001', 'TestGroup', {});
  insertNode(dbPath, 'TG-002', 'TestGroup', {});
  insertNode(dbPath, 'T-001-01', 'Test', {
    test_type: 'Validation',
    test_method: 'Demonstration',
    result: 'PASS',
  });
  insertNode(dbPath, 'T-002-01', 'Test', {
    test_type: 'Verification',
    test_method: 'Inspection',
    result: 'PENDING',
  });
  insertEdge(dbPath, 'REQ-001', 'TG-001', 'TESTED_BY');
  insertEdge(dbPath, 'REQ-001', 'TG-002', 'TESTED_BY');
  insertEdge(dbPath, 'REQ-002', 'TG-001', 'TESTED_BY');
  insertEdge(dbPath, 'TG-001', 'T-001-01', 'HAS_TEST');
  insertEdge(dbPath, 'TG-002', 'T-002-01', 'HAS_TEST');

  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);

    const reqRows = page.locator('#req-body tr').filter({ hasText: 'REQ-001' });
    await expect(reqRows).toHaveCount(1);
    const reqRow = reqRows.first();
    await expect(reqRow).toContainText('TG-001');
    await expect(reqRow).toContainText('TG-002');
    await expect(reqRow).toContainText('PENDING');

    await page.getByRole('button', { name: /^RTM$/ }).click();
    await expect(page.locator('#rtm-body')).toContainText('REQ-001');
    await expect(page.locator('#rtm-body')).toContainText('TG-001');
    await expect(page.locator('#rtm-body')).toContainText('TG-002');

    await page.getByRole('button', { name: /^Tests$/ }).click();
    const testRow = page.locator('#tests-body tr').filter({ hasText: 'T-001-01' }).first();
    await expect(testRow).toContainText('REQ-001');
    await expect(testRow).toContainText('REQ-002');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
