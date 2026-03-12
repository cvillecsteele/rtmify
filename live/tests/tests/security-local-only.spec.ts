import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { findFreePort } from '../helpers/ports';
import { startServer } from '../helpers/server';

function makeDbPath(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rtmify-live-db-'));
  return path.join(dir, 'graph.db');
}

async function startHostileSite(targetBaseUrl: string): Promise<{ url: string; close(): Promise<void> }> {
  const port = await findFreePort();
  const html = `<!doctype html>
<html>
  <body data-result="pending">
    <div id="result">pending</div>
    <script>
      (async () => {
        try {
          const res = await fetch(${JSON.stringify(`${targetBaseUrl}/api/status`)}, { cache: 'no-store' });
          const text = await res.text();
          document.body.dataset.result = 'read';
          document.getElementById('result').textContent = 'READ ' + res.status + ' ' + text.slice(0, 120);
        } catch (err) {
          document.body.dataset.result = 'blocked';
          document.getElementById('result').textContent = String(err);
        }
      })();
    </script>
  </body>
</html>`;

  const server = http.createServer((_, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  });

  await new Promise<void>((resolve) => server.listen(port, '127.0.0.1', resolve));

  return {
    url: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

test('Live stays loopback-only and rejects foreign-origin browser/API access', async ({ page }) => {
  const dbPath = makeDbPath();
  const port = await findFreePort();
  const server = await startServer({ dbPath, port });
  const hostile = await startHostileSite(server.baseUrl);

  try {
    expect(server.baseUrl).toMatch(/^http:\/\/127\.0\.0\.1:/);

    await page.goto(hostile.url);
    await expect.poll(async () => page.locator('body').getAttribute('data-result')).toBe('blocked');
    await expect(page.locator('#result')).toContainText(/TypeError|Failed to fetch|NetworkError/i);

    const resp = await fetch(`${server.baseUrl}/api/repos/scan`, {
      method: 'POST',
      headers: {
        Origin: 'http://evil.test',
      },
    });
    expect(resp.status).toBe(403);
    await expect(resp.text()).resolves.toContain('forbidden_origin');
  } finally {
    await hostile.close();
    await server.stop();
    fs.rmSync(path.dirname(dbPath), { recursive: true, force: true });
  }
});
