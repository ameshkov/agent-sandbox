// build-ubuntu.ts — the ubuntu-vmware build flow: the port of
// images/ubuntu-arm64-vmware/build.sh (the autoinstall seed server on a
// fixed port, the vmnet8 subnet read for the watchdog's grub command,
// the packer pipeline, the optional post-build hardware upgrade).

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { commandExists, isAlive, run, sleep, spawnDetached } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { type CatalogImage } from './catalog.js';
import {
  announceBuild,
  type BuildContext,
  buildDirLayout,
  type BuildDirLayout,
  ensureCacheDir,
  materializeContext,
  reportOutputDir,
  requireAppleSilicon,
  requireCmd,
  runPackerBuild,
  runPackerFmtCheck,
  runPackerInit,
  stringVar,
  upgradeArtifactHardware,
  verifyIsoSha256,
  vmnet8SubnetFromDhcpConf,
  watchdogBootCommand,
} from './build-shared.js';
import { clearBootTypedMarker, startBuildWatchdog, stopBuildWatchdog } from './build-watchdog.js';
import type { BuildFlowOptions } from './build-macos.js';

const DEFAULT_FUSION_APP = '/Applications/VMware Fusion.app';
/** The autoinstall seed port (pinned so the grub URL is known upfront). */
const SEED_PORT = 8004;
/** Fusion's vmnet8 DHCP config (the NAT subnet of the guest network). */
const VMNET8_DHCP = '/Library/Preferences/VMware Fusion/vmnet8/dhcpd.conf';

/** Builds an ubuntu-vmware image.
 *
 * @param image - The catalog image.
 * @param options - Force/watchdog overrides.
 */
export async function buildUbuntuImage(
  image: CatalogImage,
  options: BuildFlowOptions,
): Promise<void> {
  requireAppleSilicon(
    'the Ubuntu image can only be built on Apple Silicon (VMware\n' +
      '       Fusion cannot run ARM64 guests on Intel Macs).',
  );
  requireCmd('packer', 'brew install packer');
  const fusionPath = optionalFusionApp();
  const dirs = buildDirLayout('ubuntu-vmware');
  ensureCacheDir(dirs.cache);
  const context = materializeContext(image);
  announceBuild(image, context);

  const iso = requireUbuntuIso(image);
  await verifyIsoSha256(iso, stringVar(image, 'iso_sha256'), 'Ubuntu ISO', image.varsFile);
  await runUbuntuPacker(image, options, dirs, context, iso);
  await verifyUbuntuOutput(image, dirs, fusionPath);
}

/** The seed server + watchdog + packer pipeline (torn down after). */
async function runUbuntuPacker(
  image: CatalogImage,
  options: BuildFlowOptions,
  dirs: BuildDirLayout,
  context: BuildContext,
  iso: string,
): Promise<void> {
  const seedPid = await startSeedServer(context.platformDir, dirs.cache);
  let watchdogPid: number | undefined;
  try {
    await runPackerInit(context.templateFile);
    await runPackerFmtCheck(context.platformDir);
    if (options.watchdog !== false) {
      watchdogPid = await startWatchdogWithBootCmd(dirs.cache);
    }
    await runPackerBuild({
      platformDir: context.platformDir,
      templateFile: context.templateFile,
      varsFile: image.varsFile,
      buildDir: dirs.build,
      force: options.force,
      env: { PKR_VAR_iso_path: iso },
    });
  } finally {
    await stopBuildWatchdog(watchdogPid);
    await stopSeedServer(seedPid);
  }
}

/** Verifies the built vmx and upgrades/checks the hardware version. */
async function verifyUbuntuOutput(
  image: CatalogImage,
  dirs: BuildDirLayout,
  fusionPath: string | undefined,
): Promise<void> {
  const output = join(dirs.output, `${image.name}.vmx`);
  if (!existsSync(output)) {
    throw new Error(
      `build produced no ${output}\n` +
        `       Expected the vmware-iso builder's export in ${dirs.output}/.`,
    );
  }
  if (fusionPath) {
    await upgradeArtifactHardware(output, fusionPath);
  } else {
    logger.warn(`skipped the hardware upgrade (no Fusion at ${DEFAULT_FUSION_APP}).`);
  }
  await reportOutputDir(dirs.output);
  logger.ok(`Done: ${output} (export with agent-dev-env deploy ${image.name})`);
}

/** Upgrades the artifact to the host Fusion's hardware version. */

/** The bring-your-own Ubuntu ISO (UBUNTU_ISO_PATH).
 *
 * @param image - The catalog image (vars file for the error message).
 * @returns The ISO path.
 */
function requireUbuntuIso(image: CatalogImage): string {
  const iso = process.env.UBUNTU_ISO_PATH;
  if (!iso) {
    throw new Error(
      'UBUNTU_ISO_PATH is not set.\n' +
        '       Download the Ubuntu Server 24.04 ARM64 ISO (live-server-arm64)\n' +
        '       from https://cdimage.ubuntu.com/releases/24.04/release/,\n' +
        '       then set UBUNTU_ISO_PATH to its absolute path.\n' +
        '       Paste the SHA256 from the release SHA256SUMS into iso_sha256 in\n' +
        `       ${image.varsFile} to enable integrity verification.`,
    );
  }
  if (!existsSync(iso)) {
    throw new Error(`UBUNTU_ISO_PATH points to a file that does not exist:\n       ${iso}`);
  }
  return iso;
}

/** Optional Fusion (the build works without it; only the post-build
 *  hardware upgrade is skipped).
 *
 * @returns The Fusion app path, or undefined when missing (warns).
 */
function optionalFusionApp(): string | undefined {
  const path = process.env.FUSION_APP_PATH ?? DEFAULT_FUSION_APP;
  if (!existsSync(path)) {
    logger.warn(
      `VMware Fusion not found at ${path} —\n` +
        '      the post-build hardware upgrade will be skipped.\n' +
        '      Install VMware Fusion (free, Broadcom) or set FUSION_APP_PATH.',
    );
    return undefined;
  }
  return path;
}

/** Serves the autoinstall seed on the fixed port (the vmware plugin's
 *  http_directory port is random; the grub URL must be known upfront).
 *
 * @param platformDir - The materialized platform dir (autoinstall/).
 * @param cacheDir - The build cache dir (seed-server.log lands there).
 * @returns The server pid.
 */
async function startSeedServer(platformDir: string, cacheDir: string): Promise<number> {
  const logFile = join(cacheDir, 'seed-server.log');
  const taken = await run('lsof', ['-nP', `-iTCP:${SEED_PORT}`, '-sTCP:LISTEN']);
  if (taken.code === 0) {
    throw new Error(
      `port ${SEED_PORT} is taken (something else is listening).\n` +
        '       Stop the other listener before building.',
    );
  }
  if (!commandExists('python3')) {
    throw new Error('python3 is required to serve the autoinstall seed.');
  }
  logger.step(`serving the autoinstall seed at http://<host>:${SEED_PORT}/ (autoinstall/ dir)`);
  const pid = spawnDetached(
    'python3',
    [
      '-m',
      'http.server',
      String(SEED_PORT),
      '--bind',
      '0.0.0.0',
      '--directory',
      join(platformDir, 'autoinstall'),
    ],
    { logFile },
  );
  await sleep(1000);
  if (!isAlive(pid)) {
    throw new Error(`the seed server exited — see ${logFile}.`);
  }
  return pid;
}

/** Kills the seed server when still alive. */
async function stopSeedServer(pid: number): Promise<void> {
  if (isAlive(pid)) {
    try {
      process.kill(pid);
    } catch {
      // already gone
    }
  }
}

/** Reads the vmnet8 subnet from Fusion's dhcpd.conf (best effort). */
function readVmnet8Subnet(): string | undefined {
  try {
    return vmnet8SubnetFromDhcpConf(readFileSync(VMNET8_DHCP, 'utf8'));
  } catch {
    return undefined;
  }
}

/** Starts the watchdog with the grub autoinstall command (typed once per
 *  build; the seed URL points at the vmnet8 host address).
 *
 * @param cacheDir - The build cache dir.
 * @returns The watchdog pid, or undefined when skipped.
 */
async function startWatchdogWithBootCmd(cacheDir: string): Promise<number | undefined> {
  const env: Record<string, string | undefined> = {};
  const subnet = readVmnet8Subnet();
  if (!subnet) {
    logger.warn(
      "could not read the vmnet8 subnet from Fusion's DHCP config —\n" +
        '      the watchdog will not type the autoinstall command.',
    );
  } else {
    const natHost = `${subnet.slice(0, subnet.lastIndexOf('.'))}.1`;
    env.WATCH_BUILD_BOOT_CMD = watchdogBootCommand(natHost, SEED_PORT);
    clearBootTypedMarker(cacheDir);
    logger.step(
      `watchdog will type the autoinstall command for grub (seed at http://${natHost}:${SEED_PORT}/)`,
    );
  }
  return startBuildWatchdog({ cacheDir, env });
}
