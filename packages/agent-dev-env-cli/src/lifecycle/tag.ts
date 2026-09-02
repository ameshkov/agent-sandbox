// tag.ts — `agent-dev-env tag`: creates and pushes the git release tag
// for an image (the port of scripts/tag.sh). The tag is
// <platform>-v<image_version>, where <platform> is the image's directory
// under images/ (e.g. `mac` → `mac-v1.2.0`). The release convention is
// enforced: clean working tree, no existing tag, and a `[<tag>]` entry in
// the platform's CHANGELOG.md. Requires a repo checkout or --repo.

import { existsSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import {
  changelogHasTagEntry,
  createAnnotatedTag,
  findRepoRoot,
  isWorkingTreeClean,
  pushTag,
  tagExists,
} from '../lib/git.js';
import { logger } from '../lib/logger.js';
import { type CatalogImage, imageVersion, resolveRequestedImages } from './catalog.js';

/** The tag command options. */
export interface TagOptions {
  /** Explicit repo checkout (default: walk up from cwd). */
  repo?: string;
}

/** @internal — the platform name (the images/<dir> basename, e.g. `mac`;
 *  test-only export).
 *
 * @param image - The catalog image.
 * @returns The platform dir name.
 */
export function platformTagName(image: CatalogImage): string {
  return basename(dirname(dirname(image.varsFile)));
}

/** @internal — the release tag for an image (<platform>-v<image_version>;
 *  test-only export).
 *
 * @param image - The catalog image.
 * @returns The tag name.
 */
export function releaseTag(image: CatalogImage): string {
  return `${platformTagName(image)}-v${imageVersion(image)}`;
}

/** @internal — creates and pushes the tag for one image (test-only
 *  export).
 *
 * @param image - The catalog image.
 * @param repoRoot - The repo checkout.
 */
export async function tagImage(image: CatalogImage, repoRoot: string): Promise<void> {
  const tag = releaseTag(image);
  const version = imageVersion(image);
  const changelog = join(dirname(dirname(image.varsFile)), 'CHANGELOG.md');
  if (!(await isWorkingTreeClean(repoRoot))) {
    throw new Error('Working tree is dirty — commit the version bump and CHANGELOG entry first.');
  }
  if (await tagExists(repoRoot, tag)) {
    throw new Error(`Tag '${tag}' already exists.`);
  }
  const content = existsSync(changelog) ? readFileSync(changelog, 'utf8') : '';
  if (!changelogHasTagEntry(content, tag)) {
    throw new Error(
      `No CHANGELOG entry for [${tag}] in ${changelog}.\n` +
        'Add it (and bump image_version) before tagging.',
    );
  }
  logger.step(`Tagging: ${tag} (${image.name} v${version})`);
  await createAnnotatedTag(repoRoot, tag, `Release ${image.name} v${version}`);
  await pushTag(repoRoot, tag);
}

/** `agent-dev-env tag [image...] [--repo PATH]`.
 *
 * @param requested - Image names (all images when empty).
 * @param options - Repo override.
 * @returns The exit code (0 on success).
 */
export async function tagCmd(requested: string[] = [], options: TagOptions = {}): Promise<number> {
  const repoRoot = options.repo ?? findRepoRoot();
  if (!repoRoot) {
    throw new Error(
      'tag needs a checkout of the agent-sandbox repo (pass --repo or run it inside the repo).',
    );
  }
  const targets = resolveRequestedImages(requested);
  if (requested.length === 0) {
    logger.title('Tagging all images:');
    for (const image of targets) {
      logger.info(image.name);
    }
  }
  for (const image of targets) {
    await tagImage(image, repoRoot);
  }
  return 0;
}
