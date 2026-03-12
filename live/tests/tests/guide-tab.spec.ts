import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { insertNode, insertEdge, insertRuntimeDiagnostic, seedConfiguredGraph, setConfig } from '../helpers/db-seed';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-guide-db-'));
  return path.join(dir, 'graph.db');
}

test('runtime diagnostic link opens the Guide entry', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  insertRuntimeDiagnostic(dbPath, {
    dedupeKey: 'repo-validation-missing',
    code: 901,
    severity: 'err',
    title: 'Repository path does not exist',
    message: 'Repo path does not exist: /tmp/missing-repo',
    source: 'repo_validation',
    subject: '/tmp/missing-repo',
  });
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await page.getByRole('link', { name: 'E901' }).click();
    await expect(page.locator('#tab-guide-errors')).toHaveClass(/active/);
    await expect(page).toHaveURL(/#guide-code-E901$/);
    await expect(page.locator('#guide-code-E901')).toBeVisible();
    await expect(page.locator('#guide-code-E901')).toContainText('Repository path does not exist');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('chain gap link opens the exact guide variant and Explain button is gone', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  setConfig(dbPath, 'profile', 'aerospace');
  insertNode(dbPath, 'src/foo.c', 'SourceFile', { path: 'src/foo.c' });
  insertEdge(dbPath, 'REQ-001', 'src/foo.c', 'IMPLEMENTED_IN');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, extraArgs: ['--profile', 'aerospace'] });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Analysis/ }).click();
    const row = page.locator('#chain-gaps-body tr', { hasText: 'uncommitted_requirement' }).first();
    await expect(row).toBeVisible();
    await expect(page.getByRole('button', { name: 'Explain' })).toHaveCount(0);
    await row.getByRole('link', { name: '1206' }).click();
    await expect(page.locator('#tab-guide-errors')).toHaveClass(/active/);
    await expect(page).toHaveURL(/#guide-code-1206-uncommitted_requirement$/);
    await expect(page.locator('#guide-code-1206-uncommitted_requirement')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('direct guide hash opens the Guide tab on load', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(`${server.baseUrl}/#guide-code-1206-uncommitted_requirement`);
    await expect(page.locator('#tab-guide-errors')).toHaveClass(/active/);
    await expect(page.locator('#guide-code-1206-uncommitted_requirement')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
