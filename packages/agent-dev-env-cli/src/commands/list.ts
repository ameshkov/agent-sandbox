// commands/list.ts — `agent-dev-env list`: the bundled images (name,
// platform, image_version) from the per-image vars files, replacing
// list_images()/find_vars_file() in build.sh/deploy.sh/tag.sh.

import { imageVersion, listImages } from '../lifecycle/catalog.js';
import { logger } from '../lib/logger.js';

/** Prints the bundled images as a NAME / PLATFORM / VERSION table.
 *
 * @returns Exit code: 0 on success, 1 when no images are in the catalog.
 */
export async function listCmd(): Promise<number> {
  const images = listImages();
  if (images.length === 0) {
    logger.warn('No images found: no vars files under images/*/vars/.');
    return 1;
  }

  const header = ['NAME', 'PLATFORM', 'VERSION'];
  const rows = images.map((image) => {
    let version = '?';
    try {
      version = imageVersion(image);
    } catch {
      // vars file without image_version — show '?' and let the caller
      // (deploy/tag) fail with the precise error.
    }
    return [image.name, image.platform, version];
  });

  const widths = header.map((h, i) => Math.max(h.length, ...rows.map((row) => row[i].length)));
  const fmt = (cols: string[]): string =>
    cols
      .map((c, i) => c.padEnd(widths[i]))
      .join('  ')
      .replace(/\s+$/, '');

  logger.out(fmt(header));
  for (const row of rows) {
    logger.out(fmt(row));
  }
  return 0;
}
