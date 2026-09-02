// lib/ssh.ts — the ssh2 transport: the unified replacement for the shell
// runners' expect/perl/system-ssh glue (guest_sh, settings_ssh,
// settings_scp and the BatchMode sshd probe). Password auth only (the
// sandbox images' fixed user/password from the vars file), host-key
// verification skipped (StrictHostKeyChecking=no + UserKnownHostsFile=
// /dev/null parity), commands run pty-less so `sudo -S` reads the
// password from stdin — the same semantics as the shell's expect sessions.
//
// The runner-facing surface is the SshSession interface (exec + sftpWrite
// + end), implemented on top of a single ssh2 Client per session, so the
// guest-side modules never touch ssh2 directly and can be unit-tested
// with a fake session.

import { Client } from 'ssh2';

/** The credential set to reach a guest's sshd (vars-file values). */
export interface SshCredentials {
  host: string;
  port: number;
  username: string;
  password: string;
}

/** Result of a remote command (ssh2 collects stdout/stderr; the exit
 *  code is the remote command's). */
interface SshExecResult {
  code: number;
  stdout: string;
  stderr: string;
}

/** The transport surface the runners/guest modules use. */
export interface SshSession {
  /** Runs a command in the guest (no pty; `input` → remote stdin, e.g.
   *  the sudo -S password; `sentinel` → a marker echoed at the end of the
   *  remote command that ends the exec early — the Windows OpenSSH
   *  channel-close workaround, see below). */
  exec(
    command: string,
    options?: { input?: string; timeoutMs?: number; sentinel?: string },
  ): Promise<SshExecResult>;
  /** Uploads a buffer to a remote path (SFTP writeFile). */
  sftpWrite(remotePath: string, data: Buffer): Promise<void>;
  /** Ends the session (idempotent). */
  end(): void;
}

const DEFAULT_READY_TIMEOUT_MS = 15_000;

/** Outcome classification of a connect failure — the BatchMode parity:
 *  an auth failure proves sshd is up (the server answered), a connect
 *  error proves it is not.
 */
export type SshProbeOutcome = 'up' | 'down' | 'unknown';

/** @internal — classifies a connection-error message (exported for the
 *  co-located unit tests; the transport keeps it internal).
 *
 * @param message - The Error message from ssh2's `error` event.
 * @returns `up` when sshd answered (auth failed / handshake started),
 *   `down` on connect-level failures, `unknown` otherwise.
 */
export function sshProbeOutcome(message: string): SshProbeOutcome {
  if (/authentication|permission denied|key exchange|protocol/i.test(message)) {
    return 'up';
  }
  if (/ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH/i.test(message)) {
    return 'down';
  }
  return 'unknown';
}

/** Opens a password-authenticated session.
 *
 * @param credentials - Host/port/user/password.
 * @param readyTimeoutMs - Connect handshake budget (default 15 s).
 * @returns A connected session (throws when the handshake fails).
 */
export async function openSshSession(
  credentials: SshCredentials,
  readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
): Promise<SshSession> {
  return new Promise((resolve, reject) => {
    const client = new Client();
    let settled = false;
    client.on('error', (err) => {
      if (settled) {
        // Post-ready errors surface on the channels; a listener must stay
        // attached or the event would crash the process.
        return;
      }
      settled = true;
      reject(err);
    });
    client.once('ready', () => {
      settled = true;
      resolve(createSession(client));
    });
    client.connect({
      host: credentials.host,
      port: credentials.port,
      username: credentials.username,
      password: credentials.password,
      readyTimeout: readyTimeoutMs,
      // StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null parity.
      hostVerifier: () => true,
    });
  });
}

function createSession(client: Client): SshSession {
  let ended = false;
  return {
    exec: (command, options = {}) => execOn(client, command, options),
    sftpWrite: (remotePath, data) => sftpWrite(client, remotePath, data),
    end: () => {
      if (!ended) {
        ended = true;
        client.end();
      }
    },
  };
}

/** One remote command via `client.exec` — the expect `spawn ssh … $cmd`
 *  equivalent. Safe against the legacy hang edge cases: a watchdog
 *  terminates the session when the remote never closes the channel, and a
 *  sentinel ends the exec as soon as the remote command echoes it (the
 *  Windows OpenSSH channel never closes on its own when guest background
 *  relays hold the console handles — the shell's `echo $sentinel` trick).
 *
 * @param client - The connected ssh2 client.
 * @param command - The remote shell command.
 * @param options - stdin payload, a hard timeout and/or the completion
 *   sentinel.
 * @returns The remote exit code + collected output.
 */
function execOn(
  client: Client,
  command: string,
  options: { input?: string; timeoutMs?: number; sentinel?: string },
): Promise<SshExecResult> {
  return new Promise((resolve) => {
    let settled = false;
    let watchdog: NodeJS.Timeout | undefined;
    if (options.timeoutMs !== undefined) {
      watchdog = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve({
            code: -1,
            stdout: '',
            stderr: `remote command timed out (${options.timeoutMs} ms): ${command}`,
          });
          client.destroy();
        }
      }, options.timeoutMs);
    }
    const finish = (result: SshExecResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (watchdog !== undefined) {
        clearTimeout(watchdog);
      }
      resolve(result);
    };
    client.exec(command, (err, stream) => {
      if (err) {
        finish({ code: -1, stdout: '', stderr: err.message });
        return;
      }
      runChannel(stream, options.input, options.sentinel, finish);
    });
  });
}

/** Collects one exec channel: stdout/stderr until close, stdin payload
 *  written and ended. When a sentinel is given, the exec finishes (and the
 *  channel is destroyed) as soon as the sentinel shows up on stdout — the
 *  completion marker the command echoed after its payload exited; the
 *  leftover output after it belongs to the guest's background relays.
 *
 * @param stream - The ssh2 exec channel.
 * @param input - Optional remote stdin payload.
 * @param sentinel - Optional completion marker to look for on stdout.
 * @param finish - The single-settle callback.
 */
function runChannel(
  stream: import('ssh2').ClientChannel,
  input: string | undefined,
  sentinel: string | undefined,
  finish: (result: SshExecResult) => void,
): void {
  let stdout = '';
  let stderr = '';
  stream.on('data', (chunk: Buffer | string) => {
    stdout += chunk.toString();
    if (sentinel && stdout.includes(sentinel)) {
      finish({ code: 0, stdout, stderr });
      // Under the guest's control now — killing the channel is exactly
      // what the shell's `exec kill [exp_pid]` did: sshd cleans up the
      // hung session instead of our client waiting for a close that never
      // comes.
      stream.destroy();
    }
  });
  stream.stderr.on('data', (chunk: Buffer | string) => {
    stderr += chunk.toString();
  });
  stream.on('error', (streamErr: Error) => {
    finish({ code: -1, stdout, stderr: streamErr.message });
  });
  stream.on('close', (code: number | null) => {
    finish({ code: code ?? -1, stdout, stderr });
  });
  if (input !== undefined) {
    stream.write(input);
  }
  stream.end();
}

/** Uploads bytes to a remote file (SFTP writeFile; parent dirs must
 *  exist — the callers mkdir first).
 *
 * @param client - The connected ssh2 client.
 * @param remotePath - The destination path in the guest.
 * @param data - The file content.
 */
function sftpWrite(client: Client, remotePath: string, data: Buffer): Promise<void> {
  return new Promise((resolve, reject) => {
    client.sftp((err, sftp) => {
      if (err) {
        reject(err);
        return;
      }
      sftp.writeFile(remotePath, data, (writeErr) => {
        sftp.end();
        if (writeErr) {
          reject(writeErr);
          return;
        }
        resolve();
      });
    });
  });
}

/** Probes whether sshd is up at a host — one connect attempt. An auth
 *  error means the server answered (the legacy "Permission denied →
 *  ready" semantics); anything else depends on the failure kind.
 *  Exported for the QEMU backend's boot loop, which interleaves the
 *  probe with a qemu-alive check (waitForSshd polls unattended).
 *
 * @param credentials - The probe target.
 * @param readyTimeoutMs - Handshake budget (default 15 s).
 * @returns The classified outcome.
 */
export async function probeSshd(
  credentials: SshCredentials,
  readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
): Promise<SshProbeOutcome> {
  try {
    const session = await openSshSession(credentials, readyTimeoutMs);
    session.end();
    return 'up';
  } catch (err) {
    return sshProbeOutcome((err as Error).message);
  }
}

/** Polls until sshd answers (the legacy wait_for_sshd, 150 x 4 s).
 *
 * @param credentials - The guest to probe.
 * @param options - Poll count/delay + per-attempt budget.
 * @returns True when sshd came up within the window.
 */
export async function waitForSshd(
  credentials: SshCredentials,
  options: { tries?: number; delayMs?: number; readyTimeoutMs?: number } = {},
): Promise<boolean> {
  const tries = options.tries ?? 150;
  const delayMs = options.delayMs ?? 4000;
  for (let attempt = 0; attempt < tries; attempt += 1) {
    const outcome = await probeSshd(credentials, options.readyTimeoutMs);
    if (outcome === 'up') {
      return true;
    }
    if (attempt < tries - 1) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  return false;
}
