// build-windows-vmware.ts — the windows-vmware build flow: the port of
// images/windows-arm64-vmware/build.sh (Fusion app + ARM64 boot-driver
// paths, the vmxnet3 trio staged into the unattend CD, the watchdog,
// packer with the vmware-iso builder, the post-build hardware upgrade).

import { existsSync, mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { run, runChecked } from '../lib/exec.js';
import { logger } from '../lib/logger.js';
import { type CatalogImage } from './catalog.js';
import {
  announceBuild,
  buildDirLayout,
  ensureCacheDir,
  materializeContext,
  reportOutputDir,
  requireAppleSilicon,
  requireCommands,
  requireWindowsIso,
  runPackerBuild,
  runPackerFmtCheck,
  runPackerInit,
  stringVar,
  unzipVmxnet3Args,
  upgradeArtifactHardware,
  verifyIsoSha256,
} from './build-shared.js';
import { startBuildWatchdog, stopBuildWatchdog } from './build-watchdog.js';
import type { BuildFlowOptions } from './build-macos.js';

const DEFAULT_FUSION_APP = '/Applications/VMware Fusion.app';

/** Builds a windows-vmware image.
 *
 * @param image - The catalog image.
 * @param options - Force/watchdog overrides.
 */
export async function buildWindowsVmwareImage(
  image: CatalogImage,
  options: BuildFlowOptions,
): Promise<void> {
  requireAppleSilicon(
    'the Windows image can only be built on Apple Silicon (VMware\n' +
      '       Fusion cannot run ARM64 guests on Intel Macs).',
  );
  requireCommands([
    ['packer', 'brew install packer'],
    ['unzip', 'comes with macOS'],
    ['xmllint', 'comes with macOS'],
  ]);
  const fusion = requireFusion(image);
  const dirs = buildDirLayout('windows-vmware');
  ensureCacheDir(dirs.cache);
  const context = materializeContext(image);
  announceBuild(image, context);

  const winIso = requireWindowsIso(image);
  await verifyIsoSha256(winIso, stringVar(image, 'iso_sha256'), 'Windows ISO', image.varsFile);
  stageVmxnet3(fusion.driversZip, dirs.staging);

  let watchdogPid: number | undefined;
  if (options.watchdog !== false) {
    watchdogPid = await startBuildWatchdog({ cacheDir: dirs.cache });
  }
  try {
    logger.step('xmllint autounattend.xml');
    await runChecked('xmllint', ['--noout', join(context.platformDir, 'autounattend.xml')]);
    await runPackerInit(context.templateFile);
    await runPackerFmtCheck(context.platformDir);
    await runPackerBuild({
      platformDir: context.platformDir,
      templateFile: context.templateFile,
      varsFile: image.varsFile,
      buildDir: dirs.build,
      force: options.force,
      env: {
        PKR_VAR_iso_path: winIso,
        PKR_VAR_vmware_fusion_app_path: fusion.path,
      },
    });
  } finally {
    await stopBuildWatchdog(watchdogPid);
  }

  const output = requireVmxOutput(dirs.output, image.name);
  await upgradeArtifactHardware(output, fusion.path);
  await reportOutputDir(dirs.output);
  logger.ok(`Done: ${output} (export with agent-dev-env deploy ${image.name})`);
}

/** The Fusion app + the build-time ARM64 assets it must ship. */
interface FusionAssets {
  path: string;
  driversZip: string;
}

/** Resolves the Fusion app (FUSION_APP_PATH → vars → default) and checks
 *  the ARM64 drivers zip + tools ISO exist.
 *
 * @param image - The catalog image.
 * @returns The fusion paths.
 */
function requireFusion(image: CatalogImage): FusionAssets {
  const path =
    process.env.FUSION_APP_PATH ?? stringVar(image, 'vmware_fusion_app_path') ?? DEFAULT_FUSION_APP;
  if (!existsSync(path)) {
    throw new Error(
      `VMware Fusion not found at ${path}.\n       Install VMware Fusion (free, Broadcom) or set FUSION_APP_PATH.`,
    );
  }
  logger.step(`using VMware Fusion at ${path}`);
  const driversZip = join(path, 'Contents', 'Library', 'isoimages', 'arm64', 'drivers-arm64.zip');
  const toolsIso = join(path, 'Contents', 'Library', 'isoimages', 'arm64', 'windows.iso');
  if (!existsSync(driversZip)) {
    throw new Error(
      `ARM64 boot drivers not found at ${driversZip}.\n` +
        '       This Fusion version does not ship the ARM64 Windows drivers —\n' +
        '       use Fusion 13.6+ (checked from the app bundle).',
    );
  }
  if (!existsSync(toolsIso)) {
    throw new Error(
      `ARM64 VMware Tools ISO not found at ${toolsIso}.\n` +
        '       This Fusion version does not ship ARM64 tools —\n' +
        '       use Fusion 13.6+ (checked from the app bundle).',
    );
  }
  return { path, driversZip };
}

/** Extracts the vmxnet3 ARM64 inf/sys/cat trio flat into the staging dir
 *  (packed into the unattend CD).
 *
 * @param driversZip - Fusion's drivers-arm64.zip.
 * @param stagingDir - The staging dir.
 */
async function stageVmxnet3(driversZip: string, stagingDir: string): Promise<void> {
  logger.step(`staging vmxnet3 ARM64 drivers into ${stagingDir}`);
  rmSync(stagingDir, { recursive: true, force: true });
  mkdirSync(stagingDir, { recursive: true });
  const res = await run('unzip', unzipVmxnet3Args(driversZip, stagingDir));
  if (res.code !== 0) {
    throw new Error(
      `vmxnet3 ARM64 driver missing from ${driversZip}.\n` +
        '       Expected vmxnet3/Win10_1709/ARM64/vmxnet3.{inf,sys,cat}.',
    );
  }
}

/** The built vmx (must exist after the vmware-iso build). */
function requireVmxOutput(outputDir: string, imageName: string): string {
  const output = join(outputDir, `${imageName}.vmx`);
  if (!existsSync(output)) {
    throw new Error(
      `build produced no ${output}\n` +
        `       Expected the vmware-iso builder's export in ${outputDir}/.`,
    );
  }
  return output;
}
