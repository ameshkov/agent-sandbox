#!/usr/bin/env node
//
// cli.ts — the agent-dev-env CLI entry point (commander).
//
// The surface is registered in commands/register.ts (small register
// functions, one per group): the lifecycle commands (build/deploy/tag),
// the diagnostic commands (list/status/doctor), and the VM commands
// (run/stop/delete/sync/watch-build) — all implemented for every
// platform; `sync` is limited to the tart/ssh2 transports (macos,
// ubuntu-vmware).

import { Command, CommanderError } from 'commander';
import { createRequire } from 'node:module';
import {
  registerDoctorCommands,
  registerLifecycleCommands,
  registerStatusCommands,
  registerVmCommands,
} from './commands/register.js';
import { logger } from './lib/logger.js';

// dist/cli.js -> ../package.json is the package root; src/cli.ts ->
// ../package.json is the repo root. Both work because package.json and
// dist/ sit next to each other in the published npm package.
const pkg = createRequire(import.meta.url)('../package.json') as {
  version: string;
};

function buildProgram(): Command {
  const program = new Command();
  program
    .name('agent-dev-env')
    .description(
      'Sandbox VM runner and image lifecycle CLI. Builds, runs, and wires ' +
        'up sandbox VMs (macOS via Tart, Windows via QEMU/VMware, Ubuntu via ' +
        'VMware) and manages their image releases on GHCR.',
    )
    .version(pkg.version)
    .showSuggestionAfterError();

  registerVmCommands(program);
  registerStatusCommands(program);
  registerLifecycleCommands(program);
  registerDoctorCommands(program);

  // Errors: commander messages are printed by commander itself; our own
  // throws go through die().
  program.exitOverride();
  return program;
}

async function main(): Promise<void> {
  const program = buildProgram();
  try {
    await program.parseAsync(process.argv);
  } catch (err) {
    if (err instanceof CommanderError) {
      process.exit(err.exitCode);
    }
    if (err instanceof Error) {
      logger.die(err.message);
    }
    process.exit(1);
  }
}

void main();
