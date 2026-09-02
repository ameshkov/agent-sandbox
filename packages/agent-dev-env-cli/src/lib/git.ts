// git.ts — git helpers. Phase 1 landed the repo-root walk and git config
// reads (GHCR owner discovery); Phase 7 adds the release-tag helpers
// (clean-tree check, annotated tag creation/push, CHANGELOG entry
// validation) — the port of scripts/tag.sh.

import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { run } from './exec.js';

/** Walks up from startDir to the first directory with a .git entry (a
 *  checkout or a worktree).
 *
 * @param startDir - Directory to start the walk from.
 * @returns The repo root, or null when nothing found.
 */
export function findRepoRoot(startDir: string = process.cwd()): string | null {
  let dir = resolve(startDir);
  for (;;) {
    if (existsSync(join(dir, '.git'))) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      return null;
    }
    dir = parent;
  }
}

/** `git config --get <key>` in the repo, first line;
 *  undefined when the key is unset or git is unavailable. */
export async function gitConfigGet(
  key: string,
  options: { repoRoot?: string } = {},
): Promise<string | undefined> {
  const root = options.repoRoot ?? findRepoRoot();
  if (!root) {
    return undefined;
  }
  const res = await run('git', ['-C', root, 'config', '--get', key]);
  return res.code === 0 ? res.stdout.trim().split('\n')[0] : undefined;
}

/** Whether the repo has no uncommitted changes (worktree and index) —
 *  `git diff --quiet` + `git diff --cached --quiet`.
 *
 * @param repoRoot - The repo to check.
 * @returns True when the tree is clean.
 */
export async function isWorkingTreeClean(repoRoot: string): Promise<boolean> {
  const dirty = await run('git', ['-C', repoRoot, 'diff', '--quiet']);
  if (dirty.code !== 0) {
    return false;
  }
  const staged = await run('git', ['-C', repoRoot, 'diff', '--cached', '--quiet']);
  return staged.code === 0;
}

/** Whether a tag already exists (`git rev-parse --verify --quiet`).
 *
 * @param repoRoot - The repo to check.
 * @param tag - The tag name.
 * @returns True when the tag exists.
 */
export async function tagExists(repoRoot: string, tag: string): Promise<boolean> {
  const res = await run('git', [
    '-C',
    repoRoot,
    'rev-parse',
    '--verify',
    '--quiet',
    `refs/tags/${tag}`,
  ]);
  return res.code === 0;
}

/** The shell's `grep -q "## [<tag>]"` check: the changelog must contain a
 *  `## [<tag>]` heading line.
 *
 * @param changelogContent - The changelog file content.
 * @param tag - The tag name to look for.
 * @returns True when the changelog has the entry.
 */
export function changelogHasTagEntry(changelogContent: string, tag: string): boolean {
  return changelogContent.includes(`## [${tag}]`);
}

/** Creates an annotated tag (`git tag -a <tag> -m <message>`).
 *
 * @param repoRoot - The repo to tag.
 * @param tag - The tag name.
 * @param message - The annotation message.
 */
export async function createAnnotatedTag(
  repoRoot: string,
  tag: string,
  message: string,
): Promise<void> {
  const res = await run('git', ['-C', repoRoot, 'tag', '-a', tag, '-m', message]);
  if (res.code !== 0) {
    throw new Error(`git tag failed: ${res.stderr.trim() || res.stdout.trim()}`);
  }
}

/** Pushes a tag to origin (`git push origin <tag>`); throws on failure.
 *
 * @param repoRoot - The repo with the tag.
 * @param tag - The tag name to push.
 */
export async function pushTag(repoRoot: string, tag: string): Promise<void> {
  const res = await run('git', ['-C', repoRoot, 'push', 'origin', tag]);
  if (res.code !== 0) {
    throw new Error(`git push origin ${tag} failed: ${res.stderr.trim() || res.stdout.trim()}`);
  }
}
