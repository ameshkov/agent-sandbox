#!/bin/bash
#
# guest-setup.sh — idempotent bridge setup inside the Ubuntu sandbox VM.
#
# THIS FILE IS A TEMPLATE: the sandbox runner renders the __-placeholders
# below (host NAT address + this run's bridge ports) with sed and pushes
# the result into the guest, where it is executed once per run. The guest
# always has socat (apt-installed in the image), systemd user services
# (linger is enabled in the image) and the Docker CLI.
#
# What it sets up (mirroring the Windows sandbox's named-pipe relays):
#
#   - agent-sandbox-ssh-agent.service: socat turns the host's SSH agent
#     bridge address (TCP __HOST_ALIAS__:__AGENT_PORT__) into a guest Unix
#     socket at /tmp/ssh-agent.sock, which the sandbox user's shells and
#     services use as SSH_AUTH_SOCK,
#   - agent-sandbox-docker.service: same for the host Docker engine at
#     /tmp/docker.sock (DOCKER_HOST + docker context 'host'),
#   - /etc/profile.d/agent-sandbox.sh: exports SSH_AUTH_SOCK, DOCKER_HOST
#     and TESTCONTAINERS_HOST_OVERRIDE for every login shell,
#   - restarts the OpenChamber systemd user unit once per boot, so the web
#     UI (started at boot without the bridges) picks up the agent/Docker
#     sockets,
#   - reports a machine-readable status line the runner greps:
#     bridge-status:installed;<docker-ok:VERSION|docker-fail>
#
# The script is idempotent: systemd units are rewritten (daemon-reload +
# enable --now), so re-runs converge. The status line always prints last.
#
# Note: the runner drives the SSH session without a remote pty (the raw
# stdin uploads depend on it), so sudo cannot prompt on a terminal: -S
# reads the password line from stdin, answered by the runner's expect
# session when it sees the sudo prompt.

set -euo pipefail

HOST_ALIAS=__HOST_ALIAS__
AGENT_PORT=__AGENT_PORT__
DOCKER_PORT=__DOCKER_PORT__
SSH_AGENT_SOCK=/tmp/ssh-agent.sock
DOCKER_SOCK=/tmp/docker.sock
UNIT_DIR="$HOME/.config/systemd/user"

# The OpenChamber service starts at boot (linger) — before the bridges
# exist. Restart it only when the agent socket was missing, i.e. once per
# boot, not on every run.
AGENT_WAS_UP=0
if [ -S "$SSH_AGENT_SOCK" ]; then
    AGENT_WAS_UP=1
fi

mkdir -p "$UNIT_DIR"

cat >"$UNIT_DIR/agent-sandbox-ssh-agent.service" <<UNIT
[Unit]
Description=Agent Sandbox SSH agent bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat UNIX-LISTEN:$SSH_AGENT_SOCK,fork,unlink-early,mode=600,reuseaddr TCP:$HOST_ALIAS:$AGENT_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT

cat >"$UNIT_DIR/agent-sandbox-docker.service" <<UNIT
[Unit]
Description=Agent Sandbox Docker engine bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat UNIX-LISTEN:$DOCKER_SOCK,fork,unlink-early,mode=660,reuseaddr TCP:$HOST_ALIAS:$DOCKER_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now agent-sandbox-ssh-agent.service
systemctl --user enable --now agent-sandbox-docker.service

# Login-shell exports (profile.d). sudo -S reads its password from stdin
# (sent by the runner's expect session), so stdin is NOT free for the
# data: write the file as the user first and install it with a copy-only
# command — `sudo -S tee <<EOF` would eat the first heredoc line as the
# password.
PROFILE_TMP="$HOME/.agent-sandbox-profile.sh"
cat >"$PROFILE_TMP" <<'PROFILE'
# agent-sandbox bridges — written by scripts/lib/ubuntu-vmware/guest-setup.sh
export SSH_AUTH_SOCK=/tmp/ssh-agent.sock
export DOCKER_HOST=unix:///tmp/docker.sock
export TESTCONTAINERS_HOST_OVERRIDE=unix:///tmp/docker.sock
PROFILE
sudo -S install -o root -g root -m 0644 "$PROFILE_TMP" /etc/profile.d/agent-sandbox.sh
rm -f "$PROFILE_TMP"

if [ "$AGENT_WAS_UP" = 0 ]; then
    systemctl --user restart agent-sandbox-openchamber.service 2>/dev/null || true
fi

# Docker engine reachability check (the host engine via the bridge).
if DOCKER_HOST=unix://$DOCKER_SOCK docker info --format '{{.ServerVersion}}' >/tmp/docker-ver 2>/dev/null; then
    echo "bridge-status:installed;docker-ok:$(cat /tmp/docker-ver)"
else
    echo "bridge-status:installed;docker-fail"
fi
