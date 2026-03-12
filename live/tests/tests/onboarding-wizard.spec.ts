import { test, expect, type Page } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { initSchema, seedConfiguredGraph, seedLegacyPlaintextConnection } from '../helpers/db-seed';

const DEV_LICENSE_KEY = 'RTMIFY-DEV-0000-0000';

function makeDbPath(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return path.join(dir, 'graph.db');
}

async function ensureLicensed(page: Page): Promise<void> {
  const gate = page.locator('#license-gate');
  if (!(await gate.isVisible())) return;
  await page.locator('#license-key-input').fill(DEV_LICENSE_KEY);
  await page.getByRole('button', { name: 'Activate' }).click();
  await expect(gate).toBeHidden();
}

test('configured generic workspace reopens setup at profile selection with no stale choice', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-onboarding-generic-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await ensureLicensed(page);

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

test('wizard can be reopened after a successful connect flow', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-onboarding-success-');
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.route('**/api/connection', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          ok: true,
          platform: 'google',
          credential_display: 'svc@example.com',
          workbook_label: 'fake-sheet',
        }),
      });
    });

    await page.goto(server.baseUrl);
    await ensureLicensed(page);

    await expect(page.getByRole('heading', { name: 'What standard governs your work?' })).toBeVisible();
    await page.locator('.profile-row', { hasText: 'Aerospace' }).first().click();
    await page.locator('.lobby-screen.active').getByRole('button', { name: 'Continue →' }).click();
    await expect(page.getByRole('heading', { name: 'Where is your workbook?' })).toBeVisible();
    await page.locator('.lobby-screen.active').getByRole('button', { name: 'Continue →' }).click();
    await expect(page.getByRole('heading', { name: 'Connect your workbook' })).toBeVisible();

    await page.locator('#sa-file-input').setInputFiles({
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify({
        client_email: 'svc@example.com',
        private_key: 'pem',
      })),
    });
    await page.locator('#lobby-url').fill('https://docs.google.com/spreadsheets/d/fake-sheet/edit');
    await page.getByRole('button', { name: 'Review →' }).click();
    await expect(page.locator('#mission-brief')).toContainText('Aerospace');

    await page.getByRole('button', { name: 'Authorize & Connect' }).click();
    await expect(page.getByText('Workspace authorized.')).toBeVisible();
    await page.getByRole('button', { name: 'Open Workspace' }).click();

    await page.locator('.header-home-btn').click();
    await expect(page.getByRole('heading', { name: 'What standard governs your work?' })).toBeVisible();
    await expect(page.locator('.profile-list')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('legacy plaintext connection shows reconnect-required message', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-legacy-plaintext-');
  seedLegacyPlaintextConnection(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await ensureLicensed(page);

    await expect(page.getByText('This workspace was configured before secure credential storage.')).toBeVisible();
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await expect(page.locator('#req-body')).not.toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('unsupported secure storage shows explicit connect failure', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-unsupported-store-');
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({
    dbPath,
    port,
    env: { RTMIFY_SECURE_STORE_BACKEND: 'unsupported' },
  });

  try {
    await page.goto(server.baseUrl);
    await ensureLicensed(page);
    await expect(page.getByRole('heading', { name: 'What standard governs your work?' })).toBeVisible();

    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await page.setInputFiles('#sa-file-input', {
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify({
        client_email: 'svc@example.com',
        private_key: 'pem',
      })),
    });
    await page.locator('#lobby-url').fill('https://docs.google.com/spreadsheets/d/fake-sheet/edit');
    await page.getByRole('button', { name: 'Review →' }).click();
    await page.getByRole('button', { name: 'Authorize & Connect' }).click();

    await expect(page.locator('#lobby-error')).toContainText('Secure credential storage is not available on this platform.');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
