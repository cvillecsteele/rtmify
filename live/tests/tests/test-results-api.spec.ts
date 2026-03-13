import { test, expect, type Page } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { seedConfiguredGraph } from '../helpers/db-seed';

const DEV_LICENSE_KEY = 'RTMIFY-DEV-0000-0000';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-test-results-api-'));
  return path.join(dir, 'graph.db');
}

async function ensureLicensed(page: Page): Promise<void> {
  const gate = page.locator('#license-gate');
  if (!(await gate.isVisible())) return;
  await page.locator('#license-key-input').fill(DEV_LICENSE_KEY);
  await page.getByRole('button', { name: 'Activate' }).click();
  await expect(gate).toBeHidden();
}

test('MCP & AI tab shows the test-results endpoint and token can be regenerated', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await ensureLicensed(page);

    await page.getByRole('button', { name: /^Guide$/ }).click();
    await page.getByRole('button', { name: 'MCP & AI' }).click();

    await expect(page.locator('#test-results-endpoint')).toContainText('/api/v1/test-results');
    await expect(page.locator('#test-results-inbox')).toContainText('.inbox');
    const before = (await page.locator('#test-results-token').textContent())?.trim() || '';
    expect(before).toMatch(/^[a-f0-9]{64}$/);

    await page.getByRole('button', { name: 'Regenerate Token' }).click();
    await expect.poll(async () => ((await page.locator('#test-results-token').textContent()) || '').trim()).not.toBe(before);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
