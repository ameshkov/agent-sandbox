# Sharing the SSH agent with the sandbox

Your SSH keys can live in a password manager on the host — Bitwarden, 1Password,
KeePassXC, ... — while the coding agent inside the sandbox VM uses them for
`git push`, `ssh`, `scp`, and anything else that needs authentication. This
guide explains how to expose the host's SSH agent socket to the guest.

## Why a shared directory won't work

`SSH_AUTH_SOCK` points to a Unix domain socket. The socket "file" is only a
pointer to a socket endpoint inside the kernel of the machine that created it
(your host). A directory mount (`tart run --dir=...`, virtiofs) moves file
contents, not kernel objects — so mounting the directory that contains the
socket and pointing `SSH_AUTH_SOCK` at it fails (`connect: No such file or
directory`). The guest needs a **real socket in its own kernel**, backed by a
transport to the host.

> Note: the `launchctl setenv SSH_AUTH_SOCK ...` trick some setup guides show
> only makes host GUI apps use the agent — it has nothing to do with the guest.
> Not needed here.

## Requirements

- The password manager must run on the host with its SSH agent enabled, e.g.
  Bitwarden: Settings → Vault → SSH Agent (approve the approval requests it
  shows, or enable auto-approval).
- `socat` on both sides. The sandbox image ships it (macOS images from the
  current version on); for older VMs and for the host itself:
  `brew install socat`.

## Recommended: socat socket bridge

```text
 guest (sandbox VM)                          host (your Mac)
 ─────────────────                           ─────────────────
 git / ssh / opencode
   │
   ▼
 /tmp/ssh-agent.sock  (Unix socket in guest)
   │
 socat UNIX-LISTEN ──► TCP ──► gateway IP ──► socat TCP-LISTEN ──► agent socket
```

The bridge is two `socat` processes: the host turns the agent socket into a TCP
port on Tart's VM network; the guest turns that port back into a Unix socket at
a fixed path.

### Host

```bash
GW=$(tart ip sandbox | awk -F. '{print $1"."$2"."$3".1"}')   # host's address on Tart's bridge
socat TCP-LISTEN:4100,reuseaddr,fork,bind="$GW" \
    UNIX-CONNECT:"$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"
```

- The gateway derivation works because every VM on Tart's default shared
  network lives on the same /24, and the host is always `.1`. There is no
  `tart` command that returns the host-facing address directly.
- `bind="$GW"` keeps the listener off your LAN: only the VM bridge can reach
  it. With **bridged** networking the `.1` assumption breaks — use the guest's
  default gateway
  (`netstat -nr | awk '/default/{print $2; exit}'`) to find the host address
  instead.
- The Bitwarden socket path is an example; other managers use different paths
  (e.g. 1Password's CLI agent lives at `~/.1password/agent.sock`). Find yours
  with `ls "$HOME"/Library/Containers/*/Data/*.sock` or in the manager's docs.

### Guest

```bash
HOST_GW=$(netstat -nr | awk '/default/{print $2; exit}')     # the host = default gateway
socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,unlink-early,mode=600 \
    TCP:"$HOST_GW":4100 &
export SSH_AUTH_SOCK=/tmp/ssh-agent.sock   # add to ~/.zprofile so every shell gets it
printf 'Host *\n    IdentityAgent /tmp/ssh-agent.sock\n' >> ~/.ssh/config
```

`HOST_GW` is the authoritative address the guest uses to reach the host — no
hardcoding, and it stays correct on any network layout.

The `IdentityAgent` line in `~/.ssh/config` makes `ssh(1)` reach the bridged
socket directly, so authentication keeps working even where `SSH_AUTH_SOCK` is
not exported (cron jobs, launchd agents, GUI tools, `tart exec` commands).

### Verify

```bash
ssh-add -l                    # should list the keys stored in Bitwarden
ssh -T git@github.com         # or whatever server you actually use
```

### Making it persistent

- **Guest**: put the `export` in `~/.zprofile`; add the `IdentityAgent` line
  to `~/.ssh/config`; run the guest `socat` as a background job or a
  LaunchAgent (a LaunchAgent survives reboots — `/tmp` is cleared per boot, so
  the socket must be recreated after every boot).
- **Host**: keep the `socat` line in your `run-sandbox.sh` next to `tart run`,
  or run it as a LaunchAgent. One host-side listener can serve all your
  sandboxes. The repo's [`scripts/run-macos-sandbox.sh`](../scripts/run-macos-sandbox.sh)
  automates the whole flow: it detects the host agent socket and starts the
  host bridge for the current run (nothing is written to the host's shell
  profile), then sets up the guest bridge and persists it in the guest's
  `~/.zprofile` and `~/.ssh/config` (the `IdentityAgent` patch), so it
  survives guest reboots.

Tip: with the bridge in place, even `tart exec` commands can use the agent,
e.g. `tart exec sandbox git push` — the `~/.ssh/config` `IdentityAgent` patch
removes the need for an explicit `SSH_AUTH_SOCK` there.
