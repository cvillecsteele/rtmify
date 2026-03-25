import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { initSchema, seedConfiguredGraph } from '../helpers/db-seed';

function makeDbPath(prefix = 'rtmify-lobby-db-'): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  return path.join(dir, 'graph.db');
}

function fakeServiceAccountJson(email = 'svc@myproject.iam.gserviceaccount.com'): Buffer {
  return Buffer.from(JSON.stringify({
    type: 'service_account',
    project_id: 'my-project',
    client_email: email,
    private_key: '-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n',
  }));
}

test('unlicensed first boot opens the lobby instead of the license gate', async ({ page }) => {
  const dbPath = makeDbPath();
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/, { timeout: 10_000 });
    await expect(page.locator('#license-gate')).not.toHaveClass(/visible/);
    await expect(page.locator('.lobby-screen[data-screen="1"]')).toHaveClass(/active/);
    await expect(page.getByRole('heading', { name: 'What standard governs your work?' })).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('profile selection advances to the source-of-truth step', async ({ page }) => {
  const dbPath = makeDbPath();
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);
    await expect(page.getByRole('heading', { name: 'What is your source of truth?' })).toBeVisible();
    await expect(page.locator('#tile-document-source')).toBeVisible();
    await expect(page.locator('#tile-workbook-source')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('document-first upload flows to the license step and can continue in preview', async ({ page }) => {
  const dbPath = makeDbPath();
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    let statusCall = 0;
    await page.route('**/api/status', async (route) => {
      statusCall += 1;
      const ready = statusCall >= 2;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          configured: ready,
          workspace_ready: ready,
          connection_configured: false,
          source_of_truth: ready ? 'document_first' : null,
          hobbled_mode: true,
          license_required_features: ['MCP', 'Reports', 'Repository Scanning', 'Code Traceability', 'Background Sync'],
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

    await page.route('**/api/onboarding/source-artifact', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          artifact_id: 'artifact://srs_docx/demo',
          path: '/tmp/demo.docx',
          kind: 'srs_docx',
          source_of_truth: 'document_first',
          ingest_summary: { artifact_id: 'artifact://srs_docx/demo' },
        }),
      });
    });

    await page.goto(server.baseUrl);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('#tile-document-source').click();
    await page.setInputFiles('#source-artifact-file-input', {
      name: 'V1_SRS_FOOBarProduct.docx',
      mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      buffer: Buffer.from('fake'),
    });

    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/);
    await expect(page.getByRole('heading', { name: 'Install a license now or continue in Preview Mode' })).toBeVisible();

    await page.locator('#preview-continue-btn').click();
    await expect(page.getByText('Preview workspace ready.')).toBeVisible();
    await page.getByRole('button', { name: 'Open Workspace' }).click();
    await expect(page.locator('#tab-design-artifacts')).toHaveClass(/active/);
    await expect(page.locator('[data-tab="design-artifacts"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('workbook-first onboarding reaches the connection step and then the license step', async ({ page }) => {
  const dbPath = makeDbPath();
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    let statusCall = 0;
    await page.route('**/api/status', async (route) => {
      statusCall += 1;
      const ready = statusCall >= 2;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          configured: ready,
          workspace_ready: ready,
          connection_configured: ready,
          source_of_truth: ready ? 'workbook_first' : null,
          platform: ready ? 'google' : null,
          workbook_url: ready ? 'https://docs.google.com/spreadsheets/d/fake-sheet/edit' : null,
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
    await page.locator('.profile-row[data-profile-id="aerospace"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('#tile-workbook-source').click();
    await page.locator('#s2-continue-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    await page.setInputFiles('#sa-file-input', {
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: fakeServiceAccountJson(),
    });
    await page.fill('#lobby-url', 'https://docs.google.com/spreadsheets/d/fake-sheet/edit');
    await page.locator('#s3-continue-btn').click();

    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/);
    await expect(page.getByText('No active license is installed. You can continue in preview mode.')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('workbook-first local DB branch skips credentials and reaches the license step', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-local-db-');
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await page.locator('.profile-row[data-profile-id="rail"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('#tile-workbook-source').click();
    await page.locator('#s2-continue-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    await page.locator('#tile-local').click();
    await expect(page.locator('#s3-local')).toBeVisible();
    await page.locator('#s3-continue-btn').click();

    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/);
    await expect(page.getByText('No active license is installed. You can continue in preview mode.')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('unlicensed but already seeded workspace opens directly in preview mode', async ({ page }) => {
  const dbPath = makeDbPath('rtmify-preview-ready-');
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, licensed: false });

  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).not.toHaveClass(/visible/, { timeout: 10_000 });
    await expect(page.locator('#preview-banner')).toHaveClass(/visible/, { timeout: 10_000 });
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
