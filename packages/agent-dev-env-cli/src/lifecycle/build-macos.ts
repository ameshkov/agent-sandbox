// build-macos.ts — the macOS build flow: the plain `packer init` +
// `packer build -var-file` path of scripts/build.sh's fallback (no
// staging, no swtpm — the tart plugin owns the VM under ~/.tart/vms/).

import { logger } from '../lib/logger.js';
import { type CatalogImage } from './catalog.js';
import {
  announceBuild,
  materializeContext,
  requireCmd,
  runPackerBuild,
  runPackerInit,
} from './build-shared.js';

/** The per-build flow options (shared by all platforms). */
export interface BuildFlowOptions {
  force?: boolean;
  watchdog?: boolean;
}

/** Builds a macOS image with Packer.
 *
 * @param image - The catalog image.
 * @param options - Force/watchdog overrides.
 */
export async function buildMacosImage(
  image: CatalogImage,
  options: BuildFlowOptions,
): Promise<void> {
  requireCmd('packer', 'brew install packer');
  const context = materializeContext(image);
  announceBuild(image, context);
  await runPackerInit(context.templateFile);
  await runPackerBuild({
    platformDir: context.platformDir,
    templateFile: context.templateFile,
    varsFile: image.varsFile,
    force: options.force,
  });
  logger.ok(`Done: ${image.name}`);
}
