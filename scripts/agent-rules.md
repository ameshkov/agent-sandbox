# Sandbox VM environment

You are running inside a macOS sandbox VM. Your code lives on the host Mac and
is shared into the VM; the toolchain (Xcode, Homebrew, Node, Python, VS Code,
opencode, ...) runs in the VM. The environment differs from a normal dev
machine in a few ways that matter when you run commands or start services.

## Paths

- The shared working directory is mounted in the VM at `{{GUEST_MOUNT}}` and
  corresponds to the host's `{{HOST_WORK_DIR}}`. Paths quoted from the host —
  in issues, commits, or host-side terminal output — use the host form: map
  them to the guest form when you open files, and back to the host form when
  you return paths to the user.
- The VM's user is `admin` (home `/Users/admin`); your git identity, aliases
  and signing config come from `~/.gitconfig` (synced from the host with the
  user settings).

## Docker

The VM ships the Docker CLI but **no container engine** — macOS guests cannot
nest VMs, so Docker Desktop, Colima and OrbStack do not run inside the VM. The
runner bridges the *host's* engine into the VM instead:

- The `host` docker context is the default; `docker`, `docker compose` and
  `docker buildx` talk to the host engine via `~/.docker/run/docker.sock`
  (`DOCKER_HOST` and `TESTCONTAINERS_HOST_OVERRIDE` are exported for clients
  that ignore contexts, e.g. testcontainers).
- **Never try to install or start a local engine** (`colima start`, Docker
  Desktop, ...) — it cannot work here. If `docker info` fails, the bridge or
  the host engine is down: tell the user to start the engine on the host
  and/or re-run `./scripts/run-macos-sandbox.sh`, and continue with work
  that does not need Docker.

### Containers you launch

- Containers run on the **host engine**, and the Docker daemon resolves
  volume-mount paths on the **host's filesystem** — the guest mount
  (`{{GUEST_MOUNT}}`) does not exist there. Bind mounts must use **host
  paths**: mount `{{HOST_WORK_DIR}}/<project>/...` into the container, not
  `{{GUEST_MOUNT}}/<project>/...`. This applies to `docker run -v` and to
  compose `volumes:` entries alike (compose resolves relative mount paths in
  the guest before the daemon sees them); named volumes are unaffected.
- Published ports are bound on the **host**. From inside the VM they are
  reachable at the NAT gateway — `192.168.64.1:<port>` (verify with `route -n
  get default`) — **not** at `localhost:<port>`. Check a container you
  started with `curl http://192.168.64.1:<port>`, and tell the user the port
  is available as `http://localhost:<port>` on the host itself.
- Image builds run on the host engine: `docker build` and `docker buildx`
  work as usual.

## Services you start

- A server you start inside the VM (e.g. a dev server) is reachable from the
  host at `http://<vm-ip>:<port>` — the VM's IP is printed when the sandbox
  starts, or ask the user to run `tart ip <vm>`. OpenChamber itself listens
  on port 4000.

## Config changes

- After editing opencode or Copilot settings in the VM, restart OpenChamber
  with `openchamber restart`; to pull the host's versions of the settings
  instead, the user re-runs `./scripts/sync-macos-sandbox.sh`.

## SSH agent bridge

- The runner bridges the host's SSH agent into the VM, so `git push`, `git
  fetch`, `gh`, `ssh` and `scp` work against any host the user's agent knows,
  without keys on disk. `SSH_AUTH_SOCK` points at the bridged socket
  (`/tmp/ssh-agent.sock`), and `~/.ssh/config` sets `IdentityAgent` for tools
  that don't read the export.
