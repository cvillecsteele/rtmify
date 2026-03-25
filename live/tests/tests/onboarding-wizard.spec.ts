import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { initSchema, seedConfiguredGraph } from '../helpers/db-seed';

function makeDbPath(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return path.join(dir, 'graph.db');
}

test('configured generic workspace reopens setup at profile selection with no stale choice', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-onboarding-generic-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);

    await page.locator('.header-home-btn').click();
    await expect(page.getByRole('heading', { name: 'What standard governs your work?' })).toBeVisible();
    await expect(page.locator('.profile-row.selected')).toHaveCount(0);

    const aerospaceRow = page.locator('.profile-row', { hasText: 'Aerospace' }).first();
    await aerospaceRow.focus();
    await page.keyboard.press('Enter');
    await expect(aerospaceRow).toHaveAttribute('aria-selected', 'true');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Add Workbook uses workbook-only mode and skips the source-of-truth fork', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-add-workbook-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await page.locator('#settings-toggle-btn').click();
    await page.locator('[data-settings-tab="workbooks"]').click();
    await page.getByRole('button', { name: 'Add Workbook' }).click();

    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();

    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
    await expect(page.getByRole('heading', { name: 'Connect your workbook' })).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('preview banner can open the manual license gate', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-preview-banner-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#preview-banner')).toHaveClass(/visible/, { timeout: 10_000 });
    await page.getByRole('button', { name: 'Install License' }).click();
    await expect(page.locator('#license-gate')).toHaveClass(/visible/);
    await expect(page.locator('#license-gate-state')).toContainText('Select a signed license file');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('document-first preview workspace shows the attach-workbook prompt', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-attach-prompt-');
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.route('**/api/status', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          configured: true,
          workspace_ready: true,
          connection_configured: false,
          source_of_truth: 'document_first',
          attach_workbook_prompt_dismissed: false,
          hobbled_mode: true,
          license_required_features: ['MCP', 'Reports'],
          license: {
            state: 'not_licensed',
            permits_use: false,
            using_free_run: false,
            license_path: path.join(path.dirname(dbPath), 'license.json'),
            expected_key_fingerprint: 'test',
            license_signing_key_fingerprint: null,
            issued_to: null,
            org: null,
            license_id: null,
            product: null,
            tier: null,
            issued_at: null,
            expires_at: null,
            detail_code: 'not_licensed',
            message: null,
          },
        }),
      });
    });

    await page.goto(server.baseUrl);
    await expect(page.locator('#attach-workbook-prompt')).toHaveClass(/visible/, { timeout: 10_000 });
    await page.getByRole('button', { name: 'Dismiss' }).click();
    await expect(page.locator('#attach-workbook-prompt')).not.toHaveClass(/visible/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
