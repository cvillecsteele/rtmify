/**
 * Playwright spec: Lobby / onboarding wizard
 *
 * Covers the 5-screen setup wizard:
 *   1 → Profile selection
 *   2 → Provider (Google Sheets / Excel Online)
 *   3 → Credentials + workbook URL
 *   4 → Mission brief (review)
 *   5 → Success
 *
 * Also covers:
 *   - Reconnect flow (configured server → showLobby → lands on screen 4)
 *   - Keyboard accessibility on profile rows
 *   - Validation error messages
 *   - Connect error handling
 */

import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';
import { initSchema, seedConfiguredGraph } from '../helpers/db-seed';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-lobby-db-'));
  return path.join(dir, 'graph.db');
}

/** An unconfigured server: schema only, no platform/workbook_url in config. */
async function startUnconfiguredServer(): Promise<{ dbPath: string; server: Awaited<ReturnType<typeof startServer>> }> {
  const dbPath = makeDbPath();
  initSchema(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });
  return { dbPath, server };
}

/** A minimal valid service-account JSON file buffer. */
function fakeServiceAccountJson(email = 'svc@myproject.iam.gserviceaccount.com'): Buffer {
  return Buffer.from(JSON.stringify({
    type: 'service_account',
    project_id: 'my-project',
    client_email: email,
    private_key: '-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n',
  }));
}

/** Navigate through screens 1-3 (Google path) up to the Mission Brief. */
async function advanceToMissionBrief(page: import('@playwright/test').Page, opts: {
  profileId?: string;
  email?: string;
  workbookUrl?: string;
} = {}): Promise<void> {
  const profileId  = opts.profileId  ?? 'medical';
  const email      = opts.email      ?? 'svc@myproject.iam.gserviceaccount.com';
  const workbookUrl = opts.workbookUrl ?? 'https://docs.google.com/spreadsheets/d/fake-sheet/edit';

  // Screen 1 — pick profile
  await page.locator(`.profile-row[data-profile-id="${profileId}"]`).click();
  await page.locator('[data-screen="1"] .authorize-btn').click();

  // Screen 2 — keep Google (default), continue
  await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);
  await page.locator('[data-screen="2"] .authorize-btn').click();

  // Screen 3 — upload SA file + URL
  await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
  await page.setInputFiles('#sa-file-input', {
    name: 'service-account.json',
    mimeType: 'application/json',
    buffer: fakeServiceAccountJson(email),
  });
  await expect(page.locator('#sa-loaded-chip')).toBeVisible();
  await page.fill('#lobby-url', workbookUrl);
  await page.locator('#s3-continue-btn').click();

  // Now on screen 4
  await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/);
}

// ---------------------------------------------------------------------------
// Section 1: Lobby visibility & initial render
// ---------------------------------------------------------------------------

test('unconfigured server: lobby is visible and screen 1 is active on load', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/, { timeout: 10_000 });
    await expect(page.locator('.lobby-screen[data-screen="1"]')).toHaveClass(/active/);
    await expect(page.locator('[data-screen="1"]')).toContainText('What standard governs your work?');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('configured server: lobby is hidden on load, main app renders', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });
  try {
    await page.goto(server.baseUrl);
    // Lobby must not be visible
    await expect(page.locator('#lobby')).not.toHaveClass(/visible/, { timeout: 10_000 });
    // Main content loaded
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 2: Profile screen (screen 1)
// ---------------------------------------------------------------------------

test('profile list renders all 10 mission profiles', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    const rows = page.locator('.profile-row');
    await expect(rows).toHaveCount(10);

    const expectedIds = [
      'aerospace', 'automotive', 'defense', 'industrial', 'maritime',
      'medical', 'nuclear', 'rail', 'samd', 'space',
    ];
    for (const id of expectedIds) {
      await expect(page.locator(`.profile-row[data-profile-id="${id}"]`)).toBeVisible();
    }
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('continuing without selecting a profile shows validation error', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    // No profile selected — click Continue
    await page.locator('[data-screen="1"] .authorize-btn').click();

    await expect(page.locator('#lobby-error')).toBeVisible();
    await expect(page.locator('#lobby-error')).toContainText('Select a profile to continue');
    // Still on screen 1
    await expect(page.locator('.lobby-screen[data-screen="1"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('selecting a profile highlights it and clears the error', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    // Trigger error first
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('#lobby-error')).toBeVisible();

    // Now pick Medical Device
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await expect(page.locator('.profile-row[data-profile-id="medical"]')).toHaveClass(/selected/);
    // Other profiles not selected
    await expect(page.locator('.profile-row[data-profile-id="aerospace"]')).not.toHaveClass(/selected/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('selecting a profile and clicking Continue advances to screen 2', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="aerospace"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);
    // Step dot 2 active
    await expect(page.locator('.lobby-dot[data-dot="2"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 3: Provider screen (screen 2)
// ---------------------------------------------------------------------------

test('provider screen shows Google Sheets selected by default', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);
    await expect(page.locator('#tile-google')).toHaveClass(/selected/);
    await expect(page.locator('#tile-excel')).not.toHaveClass(/selected/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('switching to Excel provider shows Azure credential inputs on screen 3', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="automotive"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);

    await page.locator('#tile-excel').click();
    await expect(page.locator('#tile-excel')).toHaveClass(/selected/);
    await expect(page.locator('#tile-google')).not.toHaveClass(/selected/);

    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
    await expect(page.locator('#s3-excel')).toBeVisible();
    await expect(page.locator('#s3-google')).not.toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Back button on screen 2 returns to screen 1', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="rail"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="2"]')).toHaveClass(/active/);

    await page.locator('#lobby-back-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="1"]')).toHaveClass(/active/);
    // Dot 1 is active
    await expect(page.locator('.lobby-dot[data-dot="1"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 4: Credentials screen (screen 3) — Google path
// ---------------------------------------------------------------------------

test('screen 3 Google: continuing without SA file shows error', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    // Fill URL but no SA file
    await page.fill('#lobby-url', 'https://docs.google.com/spreadsheets/d/abc/edit');
    await page.locator('#s3-continue-btn').click();

    await expect(page.locator('#lobby-error')).toBeVisible();
    await expect(page.locator('#lobby-error')).toContainText('Upload a service-account.json');
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('screen 3 Google: continuing without workbook URL shows error', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    // Upload SA file but no URL
    await page.setInputFiles('#sa-file-input', {
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: fakeServiceAccountJson(),
    });
    await expect(page.locator('#sa-loaded-chip')).toBeVisible();
    await page.locator('#s3-continue-btn').click();

    await expect(page.locator('#lobby-error')).toBeVisible();
    await expect(page.locator('#lobby-error')).toContainText('Enter a workbook URL');
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('screen 3 Google: SA file upload shows loaded chip with email', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    // Upload zone visible initially
    await expect(page.locator('#sa-upload-zone')).toBeVisible();
    await expect(page.locator('#sa-loaded-chip')).not.toBeVisible();

    const email = 'my-svc@project-123.iam.gserviceaccount.com';
    await page.setInputFiles('#sa-file-input', {
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: fakeServiceAccountJson(email),
    });

    await expect(page.locator('#sa-loaded-chip')).toBeVisible();
    await expect(page.locator('#sa-loaded-email')).toHaveText(email);
    await expect(page.locator('#sa-upload-zone')).not.toBeVisible();
    await expect(page.locator('#lobby-share-hint')).toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('screen 3 Google: Change link clears the loaded credential', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="medical"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    await page.setInputFiles('#sa-file-input', {
      name: 'service-account.json',
      mimeType: 'application/json',
      buffer: fakeServiceAccountJson(),
    });
    await expect(page.locator('#sa-loaded-chip')).toBeVisible();

    // Click "Change"
    await page.locator('.sa-loaded-change').click();
    await expect(page.locator('#sa-upload-zone')).toBeVisible();
    await expect(page.locator('#sa-loaded-chip')).not.toBeVisible();
    await expect(page.locator('#lobby-share-hint')).not.toBeVisible();
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 5: Credentials screen (screen 3) — Excel path
// ---------------------------------------------------------------------------

test('screen 3 Excel: continuing without all Azure fields shows error', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="automotive"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('#tile-excel').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    // Fill only tenant ID, leave client ID + secret blank
    await page.fill('#excel-tenant-id', 'my-tenant-id');
    await page.fill('#lobby-url', 'https://myorg.sharepoint.com/workbook.xlsx');
    await page.locator('#s3-continue-btn').click();

    await expect(page.locator('#lobby-error')).toBeVisible();
    await expect(page.locator('#lobby-error')).toContainText('Enter all Azure credentials');
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('screen 3 Excel: secret visibility toggle changes input type', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await page.locator('.profile-row[data-profile-id="automotive"]').click();
    await page.locator('[data-screen="1"] .authorize-btn').click();
    await page.locator('#tile-excel').click();
    await page.locator('[data-screen="2"] .authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);

    const secretInput = page.locator('#excel-client-secret');
    await expect(secretInput).toHaveAttribute('type', 'password');
    await page.locator('.password-toggle').click();
    await expect(secretInput).toHaveAttribute('type', 'text');
    await page.locator('.password-toggle').click();
    await expect(secretInput).toHaveAttribute('type', 'password');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 6: Mission brief screen (screen 4)
// ---------------------------------------------------------------------------

test('mission brief shows profile label, standards, and provider', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await advanceToMissionBrief(page, { profileId: 'medical' });

    await expect(page.locator('#mission-brief')).toContainText('Medical Device');
    await expect(page.locator('#mission-brief')).toContainText('ISO 13485');
    await expect(page.locator('#mission-brief')).toContainText('Google Sheets');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('mission brief tagline appears as the headline', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await advanceToMissionBrief(page, { profileId: 'aerospace' });

    await expect(page.locator('#brief-headline')).toContainText('DO-178C traceability');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Back from mission brief returns to credentials screen', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await advanceToMissionBrief(page, { profileId: 'medical' });

    await page.locator('#lobby-back-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="3"]')).toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 7: Connect flow — success and failure
// ---------------------------------------------------------------------------

test('successful connect shows success screen with workspace info', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    // Mock /api/connection to succeed
    await page.route('**/api/connection', async (route) => {
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    });

    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await advanceToMissionBrief(page, { profileId: 'medical', email: 'svc@myproject.iam.gserviceaccount.com' });

    await page.locator('#authorize-btn').click();

    await expect(page.locator('.lobby-screen[data-screen="5"]')).toHaveClass(/active/, { timeout: 10_000 });
    await expect(page.locator('.success-title')).toContainText('Workspace authorized');
    await expect(page.locator('#success-sub')).toContainText('Medical Device');
    await expect(page.locator('#success-sub')).toContainText('Google Sheets');
    // Step dots hidden on success screen
    await expect(page.locator('#lobby-dots')).toHaveCSS('visibility', 'hidden');
    // Back button hidden on success screen
    await expect(page.locator('#lobby-back-btn')).not.toHaveClass(/visible/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('connect failure shows error message and resets the authorize button', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.route('**/api/connection', async (route) => {
      await route.fulfill({
        status: 400,
        contentType: 'application/json',
        body: JSON.stringify({ ok: false, detail: 'Invalid service-account credentials' }),
      });
    });

    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await advanceToMissionBrief(page, { profileId: 'medical' });

    await page.locator('#authorize-btn').click();

    await expect(page.locator('#lobby-error')).toBeVisible({ timeout: 10_000 });
    await expect(page.locator('#lobby-error')).toContainText('Failed to connect');
    await expect(page.locator('#lobby-error')).toContainText('Invalid service-account credentials');
    // Still on screen 4
    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/);
    // Button re-enabled
    await expect(page.locator('#authorize-btn')).not.toBeDisabled();
    await expect(page.locator('#authorize-label')).toContainText('Authorize');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Open Workspace button dismisses lobby and shows main app', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, extraArgs: ['--profile', 'medical'] });
  try {
    // Mock /api/connection so the connect step succeeds
    await page.route('**/api/connection', async (route) => {
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    });

    await page.goto(server.baseUrl);
    // Configured server: app loads, lobby hidden
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });

    // User triggers reconnect via header button
    await page.locator('.header-home-btn').click();
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    // Should land on screen 4 (mission brief) since server is configured
    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/, { timeout: 10_000 });

    // Click Authorize & Connect
    await page.locator('#authorize-btn').click();

    // Success screen
    await expect(page.locator('.lobby-screen[data-screen="5"]')).toHaveClass(/active/, { timeout: 10_000 });

    // Open Workspace dismisses lobby
    await page.locator('.open-workspace-btn').click();
    await expect(page.locator('#lobby')).not.toHaveClass(/visible/);
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 8: Reconnect flow (P1b — lobby strand fix)
// ---------------------------------------------------------------------------

test('reconnect via header button on configured server lands on mission brief (screen 4)', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, extraArgs: ['--profile', 'medical'] });
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });
    // Lobby hidden initially
    await expect(page.locator('#lobby')).not.toHaveClass(/visible/);

    // Click RTMify header button to open lobby
    await page.locator('.header-home-btn').click();
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    // Should jump straight to screen 4 (mission brief for the configured workspace)
    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/, { timeout: 10_000 });
    // Screen 5 must NOT be active (strand fix)
    await expect(page.locator('.lobby-screen[data-screen="5"]')).not.toHaveClass(/active/);
    // Screen 1 must NOT be active
    await expect(page.locator('.lobby-screen[data-screen="1"]')).not.toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('reconnect after successful connect does not strand on screen 5', async ({ page }) => {
  const dbPath = makeDbPath();
  seedConfiguredGraph(dbPath);
  const port = await findFreePort();
  const server = await startServer({ dbPath, port, extraArgs: ['--profile', 'medical'] });
  try {
    await page.route('**/api/connection', async (route) => {
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    });

    await page.goto(server.baseUrl);
    await expect(page.locator('#req-body')).toBeVisible({ timeout: 10_000 });

    // First reconnect → screen 4
    await page.locator('.header-home-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/, { timeout: 10_000 });

    // Connect → screen 5
    await page.locator('#authorize-btn').click();
    await expect(page.locator('.lobby-screen[data-screen="5"]')).toHaveClass(/active/, { timeout: 10_000 });

    // Open Workspace
    await page.locator('.open-workspace-btn').click();
    await expect(page.locator('#lobby')).not.toHaveClass(/visible/);

    // Second reconnect → must land on screen 4, NOT screen 5
    await page.locator('.header-home-btn').click();
    await expect(page.locator('#lobby')).toHaveClass(/visible/);
    await expect(page.locator('.lobby-screen[data-screen="4"]')).toHaveClass(/active/, { timeout: 10_000 });
    await expect(page.locator('.lobby-screen[data-screen="5"]')).not.toHaveClass(/active/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Section 9: Keyboard accessibility (P2)
// ---------------------------------------------------------------------------

test('profile rows have tabindex="0" and are focusable via keyboard', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    // Every profile row must have tabindex="0"
    const rows = page.locator('.profile-row');
    const count = await rows.count();
    expect(count).toBe(10);
    for (let i = 0; i < count; i++) {
      await expect(rows.nth(i)).toHaveAttribute('tabindex', '0');
    }
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Enter key on a profile row selects it', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    const spaceRow = page.locator('.profile-row[data-profile-id="space"]');
    await spaceRow.focus();
    await spaceRow.press('Enter');
    await expect(spaceRow).toHaveClass(/selected/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('Space key on a profile row selects it', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    const nuclearRow = page.locator('.profile-row[data-profile-id="nuclear"]');
    await nuclearRow.focus();
    await nuclearRow.press(' ');
    await expect(nuclearRow).toHaveClass(/selected/);
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});

test('profile rows have role="option" and aria-selected attribute', async ({ page }) => {
  const { dbPath, server } = await startUnconfiguredServer();
  try {
    await page.goto(server.baseUrl);
    await expect(page.locator('#lobby')).toHaveClass(/visible/);

    const rows = page.locator('.profile-row');
    const count = await rows.count();
    for (let i = 0; i < count; i++) {
      await expect(rows.nth(i)).toHaveAttribute('role', 'option');
      // All start unselected (lobbyState.profileId is null)
      await expect(rows.nth(i)).toHaveAttribute('aria-selected', 'false');
    }

    // After selecting one, aria-selected updates
    await page.locator('.profile-row[data-profile-id="maritime"]').click();
    await expect(page.locator('.profile-row[data-profile-id="maritime"]')).toHaveAttribute('aria-selected', 'true');
    await expect(page.locator('.profile-row[data-profile-id="medical"]')).toHaveAttribute('aria-selected', 'false');
  } finally {
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
