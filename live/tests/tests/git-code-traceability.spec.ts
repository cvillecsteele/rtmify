import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { seedConfiguredGraph } from '../helpers/db-seed';
import { RepoFixture } from '../helpers/git-fixture';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

test('adding repo path shows it in Repo Status immediately', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo = RepoFixture.create();
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await page.locator('#repo-path-input').fill(repo.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo.path);
    await expect(page.locator('#repo-error')).toBeHidden();
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('source annotations appear in Code tab for repo-backed requirement evidence', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo = RepoFixture.create();
  repo.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 0; }\n');
  repo.commit('REQ-001 initial implementation', 'Alice', 'alice@example.com', '2026-03-06T12:00:00Z');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, repoPath: repo.path });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo.path);
    await expect(page.locator('#code-body')).toContainText('src/foo.c', { timeout: 15000 });
    await expect(page.locator('#code-body')).toContainText('SourceFile');
    const row = page.locator('#code-body tr', { hasText: `${repo.path}/src/foo.c` }).first();
    await row.locator('.expand-btn').click();
    await expect(page.locator('.file-annotation-row')).toBeVisible();
    await expect(page.locator('.file-annotations')).toContainText('REQ-001');
    await expect(page.locator('.file-annotations')).toContainText('line 1');
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('test-file annotations appear separately and historical deleted files stay out of current inventory', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo = RepoFixture.create();
  repo.writeFile('src/legacy.c', '// REQ-001 old implementation\nint legacy(void) { return 0; }\n');
  repo.commit('REQ-001 initial implementation', 'Alice', 'alice@example.com', '2026-03-05T09:00:00Z');
  repo.writeFile('tests/foo_test.c', '// REQ-001 verified here\nint test_foo(void) { return 0; }\n');
  repo.commit('test coverage', 'Alice', 'alice@example.com', '2026-03-06T09:00:00Z');
  repo.deleteFile('src/legacy.c');
  repo.commit('remove obsolete file', 'Bob', 'bob@example.com', '2026-03-07T09:00:00Z');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, repoPath: repo.path });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await expect(page.locator('#code-body')).toContainText('tests/foo_test.c', { timeout: 15000 });
    await expect(page.locator('#code-body')).toContainText('TestFile');
    await expect(page.locator('#code-body')).not.toContainText('src/legacy.c');
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
