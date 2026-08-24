# guest-setup.ps1 -- runs the sandbox bridge setup in the guest (once,
# from the runner; the ONLOGON task does the same at every logon).
#
# The runner already wrote C:\tools\bridge-relay.js, bridges.ps1 and
# start-relays.cmd (each via its own small SSH exec -- the combined
# payload overran the Windows OpenSSH exec-request command line). This
# script only: ensures the execution policy, registers + runs the
# detached relay task (SYSTEM ONCE -> start-relays.cmd), registers the
# logon task (ONLOGON -> bridges.ps1), runs bridges.ps1 once (user parts:
# SSH_AUTH_SOCK, docker context), probes docker info and reports
# bridge-status:installed;<docker-ok:VERSION|docker-fail>.
#
# Keep this file short: the runner sends it as one SSH exec.
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction SilentlyContinue

# --- the detached relay start: a SYSTEM ONCE task running a .cmd ---
# Relays started from an ssh session die when sshd tears the session down
# (its job kills the children). SYSTEM tasks are outside that job, and
# ONCE tasks execute on manual /Run (ONLOGON tasks silently no-op).
$startRelays = 'C:\tools\start-relays.cmd'
schtasks /Create /TN agent-sandbox-relays /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F /TR $startRelays 2>$null | Out-Null
schtasks /Run /TN agent-sandbox-relays 2>$null | Out-Null

# --- logon persistence (user context): ONLOGON task re-runs the logic ---
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\tools\bridges.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'agent-sandbox-bridges' -Action $action -Trigger $trigger -Force -ErrorAction SilentlyContinue | Out-Null

# --- user parts now (env var, docker context) -- the relays were already
# started detached, so Ensure-Relay skips them ---
Start-Sleep -Seconds 3
& 'C:\tools\bridges.ps1'
$installed = 'installed'
$v = $null
for ($i = 0; $i -lt 20 -and -not $v; $i++) {
  Start-Sleep -Milliseconds 1000
  $v = docker info --format '{{.ServerVersion}}' 2>$null
}
if ($v) { $dockerStatus = "docker-ok:$v" } else { $dockerStatus = 'docker-fail' }
Write-Output "bridge-status:$installed;$dockerStatus"
