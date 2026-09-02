// ghcr.ts — GHCR owner resolution and registry refs.
//
// Port of the owner discovery in scripts/deploy.sh / the runners, with one
// planned change: the fallback is the default owner constant (ameshkov)
// instead of dying — the CLI is a published package and cannot require a
// checkout.
//
// Order: GHCR_OWNER env -> --owner flag -> git remote (inside a checkout)
//        -> DEFAULT_GHCR_OWNER.

import { gitConfigGet } from './git.js';

/** @internal */
export const DEFAULT_GHCR_OWNER = 'ameshkov';

/** @internal */
export const GHCR_REGISTRY = 'ghcr.io';

/** Extracts the owner from a git remote URL. Mirrors the sed in
 *  scripts/deploy.sh:
 *
 *    s#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##   (strip the host part)
 *    s#/[^/]*$##                                     (strip the repo name)
 */
/** @internal — Extracts the owner from a git remote URL (sed parity).
 * @param remoteUrl - The remote.url value.
 * @returns The owner slug, or undefined when it cannot be extracted.
 */
export function ownerFromGitRemote(remoteUrl: string): string | undefined {
  const afterHost = remoteUrl.replace(/^(https?:\/\/[^/]+\/|git@[^:]+:|ssh:\/\/[^/]+\/)/, '');
  const owner = afterHost.replace(/\/[^/]*$/, '');
  // A real owner is a plain slug; the sed would emit garbage for a URL
  // without a path (e.g. "https://github.com" -> "https:/"), which is
  // never a valid GHCR owner — guard instead of shipping it.
  return /^[A-Za-z0-9_.-]+$/.test(owner) ? owner : undefined;
}

interface ResolveOwnerInput {
  env?: Record<string, string | undefined>;
  /** --owner flag value. */
  owner?: string;
  /** remote.origin.url (already resolved). */
  remoteUrl?: string;
}

/** @internal — Pure resolution given the three inputs; synchronous and
 *  testable.
 * @param input - env / flag owner / remoteUrl.
 * @returns The resolved owner (defaults to DEFAULT_GHCR_OWNER).
 */
export function resolveOwnerFrom(input: ResolveOwnerInput = {}): string {
  const env = input.env ?? process.env;
  const parts: string[] = [];
  if (input.owner) parts.push('flag');
  if (env.GHCR_OWNER) parts.push('env');

  if (env.GHCR_OWNER) {
    return env.GHCR_OWNER;
  }
  if (input.owner) {
    return input.owner;
  }
  if (input.remoteUrl) {
    const owner = ownerFromGitRemote(input.remoteUrl);
    if (owner) {
      return owner;
    }
  }
  return DEFAULT_GHCR_OWNER;
}

/** Full resolution: env -> flag -> git remote in the repo ->
 *  default.
 * @param options - Flag owner / repo root / env overrides.
 * @returns The resolved owner.
 */
export async function resolveOwner(
  options: {
    owner?: string;
    repoRoot?: string;
    env?: Record<string, string | undefined>;
  } = {},
): Promise<string> {
  const remoteUrl = options.repoRoot
    ? await gitConfigGet('remote.origin.url', { repoRoot: options.repoRoot })
    : await gitConfigGet('remote.origin.url');
  return resolveOwnerFrom({
    env: options.env ?? process.env,
    owner: options.owner,
    remoteUrl,
  });
}

/** ghcr.io/<owner>/<image>:<tag>
 * @param image - The image name.
 * @param tag - The tag.
 * @param owner - The GHCR owner.
 * @returns The full registry ref.
 */
export function registryRef(image: string, tag: string, owner: string): string {
  return `${GHCR_REGISTRY}/${owner}/${image}:${tag}`;
}
