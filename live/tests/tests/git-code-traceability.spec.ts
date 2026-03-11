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

function makeTempDir(prefix = 'rtmify-live-dir-'): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
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

test('invalid repo path shows dashboard validation error', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const missingPath = path.join(os.tmpdir(), `rtmify-missing-${Date.now()}`);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await page.locator('#repo-path-input').fill(missingPath);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repo-error')).toBeVisible();
    await expect(page.locator('#repo-error')).toContainText('Repo path does not exist');
    await expect(page.locator('#repo-error')).toContainText('E901');
    await expect(page.locator('#repos-list')).not.toContainText(missingPath);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('non-git directory shows dashboard validation error', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const plainDir = makeTempDir('rtmify-non-git-');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await page.locator('#repo-path-input').fill(plainDir);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repo-error')).toBeVisible();
    await expect(page.locator('#repo-error')).toContainText('No .git directory found');
    await expect(page.locator('#repo-error')).toContainText('E903');
    await expect(page.locator('#repos-list')).not.toContainText(plainDir);
  } finally {
    await server.stop();
    fs.rmSync(plainDir, { recursive: true, force: true });
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

test('deleting first repo preserves later repo entry', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo1 = RepoFixture.create();
  const repo2 = RepoFixture.create();
  repo1.writeFile('src/one.c', '// REQ-001 implemented here\nint one(void) { return 1; }\n');
  repo1.commit('REQ-001 first repo', 'Alice', 'alice@example.com', '2026-03-06T10:00:00Z');
  repo2.writeFile('src/two.c', '// REQ-001 implemented here\nint two(void) { return 2; }\n');
  repo2.commit('REQ-001 second repo', 'Bob', 'bob@example.com', '2026-03-06T11:00:00Z');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();

    await page.locator('#repo-path-input').fill(repo1.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo1.path);

    await page.locator('#repo-path-input').fill(repo2.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo2.path);

    const row1 = page.locator('#repos-list tr', { hasText: repo1.path }).first();
    await row1.getByRole('button').click();
    await expect(page.locator('#repos-list')).not.toContainText(repo1.path);
    await expect(page.locator('#repos-list')).toContainText(repo2.path);
  } finally {
    await server.stop();
    repo1.cleanup();
    repo2.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('repo added in dashboard persists across server restart and is rescanned', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo = RepoFixture.create();
  repo.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 0; }\n');
  repo.commit('REQ-001 initial implementation', 'Alice', 'alice@example.com', '2026-03-06T12:00:00Z');
  const port = await findFreePort();
  let server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await page.locator('#repo-path-input').fill(repo.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo.path);

    await server.stop();
    server = await startServer({ dbPath, port });

    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo.path);
    await expect(page.locator('#code-body')).toContainText('src/foo.c', { timeout: 15000 });
  } finally {
    await server.stop();
    repo.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('multiple repos can be configured and both appear in Repo Status', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const repo1 = RepoFixture.create();
  const repo2 = RepoFixture.create();
  repo1.writeFile('src/foo.c', '// REQ-001 implemented here\nint main(void) { return 0; }\n');
  repo1.commit('REQ-001 repo one', 'Alice', 'alice@example.com', '2026-03-06T12:00:00Z');
  repo2.writeFile('tests/bar_test.c', '// REQ-001 verified here\nint bar_test(void) { return 0; }\n');
  repo2.commit('REQ-001 repo two', 'Bob', 'bob@example.com', '2026-03-06T13:00:00Z');
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });

  try {
    await page.goto(server.baseUrl);
    await page.getByRole('button', { name: /^Code$/ }).click();

    await page.locator('#repo-path-input').fill(repo1.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo1.path);

    await page.locator('#repo-path-input').fill(repo2.path);
    await page.getByRole('button', { name: /^Add Repo$/ }).click();
    await expect(page.locator('#repos-list')).toContainText(repo2.path);

    const rows = page.locator('#repos-list tr');
    await expect(rows).toHaveCount(2);
  } finally {
    await server.stop();
    repo1.cleanup();
    repo2.cleanup();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
