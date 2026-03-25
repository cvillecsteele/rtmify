import { expect, type Page } from '@playwright/test';

export async function gotoWorkspace(page: Page, url: string): Promise<void> {
  await page.goto(url);
  const lobby = page.locator('#lobby');
  const lobbyVisible = await lobby.evaluate((el) => el.classList.contains('visible')).catch(() => false);
  if (lobbyVisible) {
    await page.evaluate(() => {
      (window as Window & { openWorkspace?: () => void }).openWorkspace?.();
    });
    await expect(lobby).not.toHaveClass(/visible/, { timeout: 5000 });
    if (new URL(page.url()).hash) {
      await page.evaluate(async () => {
        await (window as Window & { handleGuideHash?: () => Promise<void> }).handleGuideHash?.();
      });
    }
  }
}
