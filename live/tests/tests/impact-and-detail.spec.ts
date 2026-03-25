import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { seedConfiguredGraph } from '../helpers/db-seed';
import { RepoFixture } from '../helpers/git-fixture';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { gotoWorkspace } from '../helpers/workspace';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

test('requirement detail renders upstream user needs separately from downstream evidence', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath, { requirementId: 'REQ-001', userNeedId: 'UN-001' });
  const repo = RepoFixture.create();
  repo.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 0; }\n');
  repo.commit('REQ-001 initial implementation', 'Alice', 'alice@example.com', '2026-03-06T12:00:00Z');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, repoPath: repo.path });

  try {
    await gotoWorkspace(page, server.baseUrl);
    await expect(page.locator('#req-body')).toContainText('REQ-001', { timeout: 15000 });
    await page.locator('#req-body tr').first().locator('.expand-btn').click();
    await expect(page.locator('.detail-row')).toContainText('src/foo.c', { timeout: 15000 });
    await expect(page.locator('.detail-row')).not.toContainText('Loading…');
    const detail = page.locator('.detail-row').first();
    const downstreamSection = detail.locator('.tree-section').nth(0);
    const upstreamSection = detail.locator('.tree-section').nth(1);
    await expect(downstreamSection).toContainText('Downstream');
    await expect(downstreamSection).toContainText('src/foo.c');
    await expect(downstreamSection).not.toContainText('UN-001');
    await expect(upstreamSection).toContainText('Upstream');
    await expect(upstreamSection).toContainText('UN-001');
    await expect(upstreamSection).toContainText('Source User Need');

    await page.getByRole('button', { name: /^User Needs$/ }).click();
    await expect(page.locator('#un-body')).toContainText('UN-001', { timeout: 15000 });
    await page.locator('#un-body tr').first().locator('.expand-btn').click();
    const needDetail = page.locator('#un-body').locator('tr.detail-row').first();
    const needDownstreamSection = needDetail.locator('.tree-section').nth(0);
    const needUpstreamSection = needDetail.locator('.tree-section').nth(1);
    await expect(needDownstreamSection).toContainText('Downstream');
    await expect(needDownstreamSection).toContainText('REQ-001');
    await expect(needDownstreamSection).toContainText('Derived Requirement');
    await expect(needUpstreamSection).toContainText('Upstream');
    await expect(needUpstreamSection).not.toContainText('REQ-001');

    await page.getByRole('button', { name: /^Analysis/ }).click();
    await page.getByRole('button', { name: /^Impact$/ }).click();
    await page.locator('#impact-input').fill('UN-001');
    await page.getByRole('button', { name: /^Analyze$/ }).click();
    await expect(page.locator('#impact-result')).toContainText('REQ-001', { timeout: 15000 });
    await expect(page.locator('#impact-result')).not.toContainText('Failed to fetch');
    await expect(page.locator('#impact-result')).not.toContainText('No downstream impact');
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
