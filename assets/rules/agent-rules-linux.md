# Sandbox VM environment

You are running inside an Ubuntu sandbox VM. Your code lives on the host Mac
and is shared into the VM; the toolchain (Go, Rust, Node, Python, VS Code,
opencode, ...) runs in the VM. The environment differs from a normal dev
machine in a few ways that matter when you run commands or start services.

## Paths

- When the runner was started with `--work-dir`, the shared working
  directory is mounted in the VM at `{{GUEST_MOUNT}}` and corresponds to
  the host's `{{HOST_WORK_DIR}}`. Paths quoted from the host — in issues,
  commits, or host-side terminal output — use the host form: map them to
  the guest form when you open files, and back to the host form when you
  return paths to the user.
- The VM's user is `admin` (home `/home/admin`); your git identity comes
  from the host's git config (the runner shares it into the guest).

## Docker

The VM ships the Docker CLI but **no container engine** — the runner
bridges the *host's* engine into the VM instead:

- Docker talks to the host engine through `unix:///tmp/docker.sock`
  (`DOCKER_HOST` is exported; the `host` docker context is the default).
- **Never try to install or start a local engine** (`dockerd`, Docker
  Desktop, ...) — it cannot work here. If `docker info` fails, the bridge
  or the host engine is down: tell the user to start the engine on the
  host and/or re-run `agent-dev-env run ubuntu-vmware`, and continue with
  work that does not need Docker.

### Containers you launch

- Containers run on the **host engine**, and the Docker daemon resolves
  volume-mount paths on the **host's filesystem** — the guest mount
  (`{{GUEST_MOUNT}}`) does not exist there. Bind mounts must use **host
  paths**: mount `{{HOST_WORK_DIR}}/<project>/...` into the container, not
  `{{GUEST_MOUNT}}/<project>/...`. This applies to `docker run -v` and to
  compose `volumes:` entries alike; named volumes are unaffected.
- Published ports are bound on the **host**. From inside the VM they are
  reachable at `{{NAT_GATEWAY}}:<port>` — **not** at `localhost:<port>`.
  Check a container you started with `curl http://{{NAT_GATEWAY}}:<port>`,
  and tell the user the port is available as `http://localhost:<port>` on
  the host itself.
- Image builds run on the host engine: `docker build` and `docker buildx`
  work as usual.

## Services you start

- A server you start inside the VM (e.g. a dev server) is reachable from
  the host at `http://<vm-ip>:<port>` — the VM's IP is printed when the
  sandbox starts. OpenChamber itself listens on port 4000.

## Config changes

- After editing opencode or Copilot settings in the VM, restart OpenChamber
  with `systemctl --user restart agent-sandbox-openchamber` (the CLI
  restarts it automatically when it brings the bridges up). To pull the
  host's versions of the settings instead, the user runs
  `agent-dev-env sync ubuntu-vmware`.

## SSH agent bridge

- The runner bridges the host's SSH agent into the VM, so `git push`, `git
  fetch`, `gh`, `ssh` and `scp` work against any host the user's agent
  knows, without keys on disk. `SSH_AUTH_SOCK` points at the bridged
  socket (`/tmp/ssh-agent.sock`), and `~/.ssh/config` sets `IdentityAgent`
  for tools that don't read the export.
