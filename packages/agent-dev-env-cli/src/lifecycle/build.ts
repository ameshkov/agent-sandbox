// build.ts — `agent-dev-env build`: the dispatcher (the port of
// scripts/build.sh). Resolves the requested images (all catalog images
// when none are given), then runs the per-platform build flow; the first
// failure aborts the run (the CLI's top level turns the throw into
// die()).

import { logger } from '../lib/logger.js';
import { buildMacosImage, type BuildFlowOptions } from './build-macos.js';
import { buildQemuImage } from './build-qemu.js';
import { buildUbuntuImage } from './build-ubuntu.js';
import { buildWindowsVmwareImage } from './build-windows-vmware.js';
import { type CatalogImage, resolveRequestedImages } from './catalog.js';

/** The build command options. */
export interface BuildOptions {
  /** Rebuild over an existing artifact (packer -force). */
  force?: boolean;
  /** Run the VNC build watchdog (default true; --no-watchdog skips). */
  watchdog?: boolean;
}

/** Builds one image with its platform's flow.
 *
 * @param image - The catalog image.
 * @param options - Force/watchdog overrides.
 */
async function buildImage(image: CatalogImage, options: BuildOptions): Promise<void> {
  const flow: BuildFlowOptions = {
    force: options.force,
    watchdog: options.watchdog !== false,
  };
  switch (image.platform) {
    case 'macos':
      await buildMacosImage(image, flow);
      return;
    case 'windows-qemu':
      await buildQemuImage(image, flow);
      return;
    case 'windows-vmware':
      await buildWindowsVmwareImage(image, flow);
      return;
    case 'ubuntu-vmware':
      await buildUbuntuImage(image, flow);
      return;
  }
}

/** `agent-dev-env build [image...] [--force] [--no-watchdog]`.
 *
 * @param requested - Image names (all images when empty).
 * @param options - Force/watchdog overrides.
 * @returns The exit code (0 on success).
 */
export async function buildCmd(
  requested: string[] = [],
  options: BuildOptions = {},
): Promise<number> {
  const targets = resolveRequestedImages(requested);
  if (requested.length === 0) {
    logger.title('Building all images:');
    for (const image of targets) {
      logger.info(image.name);
    }
  }
  for (const image of targets) {
    await buildImage(image, options);
  }
  return 0;
}
