// runners/openchamber.ts — the OpenChamber verification step (everything
// after "Step 5/5" in the shell runners): an HTTP probe with retries
// (curl -fsS --max-time 3 parity, via fetch + AbortSignal.timeout) and
// the open-in-browser offer. Shared by the backends — only the URL (VM
// IP vs 127.0.0.1 vs guest IP) differs per platform.

import { run } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { confirmDefault } from '../lib/prompt.js';

/** Probes the OpenChamber URL until it answers (or the tries run out).
 *
 * @param url - e.g. `http://192.168.64.34:4000`.
 * @param tries - Poll attempts (60 = up to 120 s at 2 s apart).
 * @param delayMs - Delay between attempts.
 * @returns True when OpenChamber answered within the window.
 */
export async function waitForOpenchamber(
  url: string,
  tries = 60,
  delayMs = 2000,
): Promise<boolean> {
  logger.info(`Waiting for OpenChamber (up to ${Math.round((tries * delayMs) / 1000)} s)`);
  for (let attempt = 0; attempt < tries; attempt += 1) {
    if (await openchamberIsUp(url)) {
      logger.ok(`OpenChamber is up: ${url} (default password: sandbox)`);
      return true;
    }
    if (attempt < tries - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  logger.warn(
    `OpenChamber did not respond on ${url} within ${Math.round((tries * delayMs) / 1000)}s.`,
  );
  logger.warn('check it from inside the VM: openchamber status / openchamber logs');
  return false;
}

/** @internal — one HTTP probe (fetch in Node 20+; signal via
 *  AbortSignal.timeout like curl --max-time 3). */
export async function openchamberIsUp(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return res.ok;
  } catch {
    return false;
  }
}

/** The open-in-browser offer (+ confirm). Bypassed with `yes` or when
 *  the URL is empty.
 *
 * @param url - The OpenChamber URL.
 * @param yes - Skip the confirmation (--yes).
 */
export async function offerOpenInBrowser(url: string, yes: boolean): Promise<void> {
  if (!url) {
    return;
  }
  logger.info(`OpenChamber URL: ${url}`);
  if (!(await confirmDefault(`Open ${url} in your browser now?`, { default: 'y', yes }))) {
    return;
  }
  const res = await run('open', [url]);
  if (res.code !== 0) {
    logger.warn(`could not open a browser — open ${url} manually.`);
  }
}
