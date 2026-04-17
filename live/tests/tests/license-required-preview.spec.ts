import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { seedConfiguredGraph } from '../helpers/db-seed';

function makeDbPath(prefix = 'rtmify-live-license-required-'): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return path.join(dir, 'graph.db');
}

test('restricted preview routes return the required feature in the 403 body', async () => {
  const dbPath = makeDbPath('rtmify-live-license-route-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    const repoResp = await fetch(`${server.baseUrl}/api/repos/scan`, { method: 'POST' });
    expect(repoResp.status).toBe(403);
    await expect(repoResp.json()).resolves.toMatchObject({
      error: 'license_required',
      license_state: 'not_licensed',
      required_feature: 'Repository Scanning',
    });

    const reportResp = await fetch(`${server.baseUrl}/report/rtm.md`);
    expect(reportResp.status).toBe(403);
    await expect(reportResp.json()).resolves.toMatchObject({
      error: 'license_required',
      required_feature: 'Reports',
    });
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('preview locked controls explain the license requirement and open the install flow', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-live-license-ui-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#preview-banner')).toHaveClass(/visible/, { timeout: 10_000 });

    const codeButton = page.locator('button[data-group="code"]');
    await expect(codeButton).toHaveAttribute('aria-disabled', 'true');
    await expect(codeButton).not.toHaveAttribute('disabled', /.*/);
    await codeButton.focus();
    await page.keyboard.press('Enter');

    await expect(page.locator('#license-required-prompt')).toHaveClass(/visible/);
    await expect(page.locator('#license-required-title')).toContainText('Code Traceability requires a license');
    await expect(page.locator('#license-required-summary')).toContainText('Repository Scanning');

    await page.getByRole('button', { name: 'Not now' }).click();
    await expect(page.locator('#license-required-prompt')).not.toHaveClass(/visible/);

    await page.getByRole('button', { name: 'Reports' }).click({ force: true });
    await expect(page.locator('#license-required-title')).toContainText('Reports requires a license');

    await page.getByRole('button', { name: 'Install License File' }).click();
    await expect(page.locator('#license-gate')).toHaveClass(/visible/);
    await expect(page.locator('#license-gate-state')).toContainText('Select a signed license file');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
