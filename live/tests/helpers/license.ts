import type { Page, Route } from '@playwright/test';

function ensurePermittedLicense(payload: any): any {
  const license = payload?.license || {};
  return {
    ...payload,
    configured: true,
    license: {
      state: 'valid',
      permits_use: true,
      license_id: license.license_id || 'LIVE-TEST-0001',
      issued_to: license.issued_to || 'playwright@example.com',
      org: license.org || 'RTMify Test Harness',
      tier: license.tier || 'site',
      expires_at: license.expires_at ?? null,
      license_path: license.license_path || '/tmp/playwright-license.json',
      expected_key_fingerprint: license.expected_key_fingerprint || 'playwright-test-key',
      license_signing_key_fingerprint: license.license_signing_key_fingerprint || 'playwright-test-key',
      message: '',
    },
  };
}

async function fulfillPermittedJson(route: Route): Promise<void> {
  const response = await route.fetch();
  const data = await response.json().catch(() => ({}));
  await route.fulfill({
    status: response.status(),
    headers: {
      ...response.headers(),
      'content-type': 'application/json',
    },
    body: JSON.stringify(ensurePermittedLicense(data)),
  });
}

export async function bypassLicenseGate(page: Page): Promise<void> {
  await page.route('**/api/status', fulfillPermittedJson);
  await page.route('**/api/license/status', fulfillPermittedJson);
}
