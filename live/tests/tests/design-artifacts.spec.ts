import { test, expect, type Page } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  insertEdge,
  insertNode,
  insertRequirementAssertion,
  seedConfiguredGraph,
} from '../helpers/db-seed';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { gotoWorkspace } from '../helpers/workspace';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

async function openDesignArtifacts(page: Page, baseUrl: string): Promise<void> {
  await gotoWorkspace(page, baseUrl);
  await page.getByRole('button', { name: /^Design Controls$/ }).click();
  await page.getByRole('button', { name: /^Design Artifacts$/ }).click();
  await expect(page.locator('#design-artifact-list-body')).toContainText('RTM Workbook', { timeout: 15000 });
}

test('design artifacts tab shows seeded SRS assertions and low-confidence rows', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath, { requirementId: 'REQ-001', userNeedId: 'UN-001' });

  insertNode(dbPath, 'SRS-101', 'Requirement', {
    status: 'Approved',
    text_status: 'single_source',
    authoritative_source: 'artifact://srs_docx/foobar-srs',
    source_count: 1,
  });
  insertRequirementAssertion(dbPath, {
    requirementId: 'SRS-101',
    text: 'SRS-101 The software SHALL record the operator ID inside each audit-trail entry.',
    artifactKind: 'srs_docx',
    logicalKey: 'foobar-srs',
    displayName: 'FooBar SRS',
    section: '4.2 Audit Trail',
    parseStatus: 'low_confidence_nested_ids',
  });

  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await openDesignArtifacts(page, server.baseUrl);

    const srsRow = page.locator('#design-artifact-list-body tr').filter({ hasText: 'FooBar SRS' }).first();
    await expect(srsRow).toContainText('SRS');
    await expect(srsRow).toContainText('foobar-srs');
    await expect(srsRow).toContainText('1');
    await srsRow.locator('[data-action="select-design-artifact"]').click();

    const detail = page.locator('#design-artifact-detail');
    await expect(detail).toContainText('FooBar SRS');
    await expect(detail).toContainText('Path');
    await expect(detail).toContainText('/tmp/foobar-srs.docx');
    await expect(detail).toContainText('Low Confidence Rows');
    await expect(detail).toContainText('SRS-101');
    await expect(detail).toContainText('low_confidence_nested_ids');
    await expect(detail).toContainText('4.2 Audit Trail');
    await expect(detail).toContainText('The software SHALL record the operator ID inside each audit-trail entry.');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('design artifacts detail shows cross-source conflicts against RTM assertions', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath, {
    requirementId: 'REQ-001',
    userNeedId: 'UN-001',
    requirementStatement: 'The system SHALL display a notification within 1 seconds of a breach.',
  });

  insertNode(dbPath, 'REQ-001', 'Requirement', {
    status: 'Approved',
    text_status: 'conflict',
    authoritative_source: 'artifact://rtm/fake-sheet',
    source_count: 2,
  });
  const srsAssertion = insertRequirementAssertion(dbPath, {
    requirementId: 'REQ-001',
    text: 'The software SHALL display a notification within 5 seconds of a breach.',
    artifactKind: 'srs_docx',
    logicalKey: 'foobar-srs',
    displayName: 'FooBar SRS',
    section: '3.1 Alarm Response',
  });
  insertEdge(dbPath, srsAssertion.requirementTextId, 'artifact://rtm/fake-sheet:REQ-001', 'CONFLICTS_WITH');
  insertEdge(dbPath, 'artifact://rtm/fake-sheet:REQ-001', srsAssertion.requirementTextId, 'CONFLICTS_WITH');

  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await openDesignArtifacts(page, server.baseUrl);

    const srsRow = page.locator('#design-artifact-list-body tr').filter({ hasText: 'FooBar SRS' }).first();
    await expect(srsRow).toContainText('1');
    await srsRow.locator('[data-action="select-design-artifact"]').click();

    const detail = page.locator('#design-artifact-detail');
    await expect(detail).toContainText('Conflicts');
    await expect(detail).toContainText('REQ-001');
    await expect(detail).toContainText('artifact://rtm/fake-sheet');
    await expect(detail).toContainText('RTM Workbook');
    await expect(detail).toContainText('The system SHALL display a notification within 1 seconds of a breach.');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
