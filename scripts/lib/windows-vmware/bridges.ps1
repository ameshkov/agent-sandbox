# bridges.ps1 -- the idempotent sandbox bridge logic (guest side).
#
# Runs at every logon via the 'agent-sandbox-bridges' ONLOGON scheduled
# task, and once right after installation by guest-setup.ps1. It:
#   - starts the Node relays for both bridges (one pipe each) when the
#     pipe is not serviced yet (Ensure-Relay),
#   - points the user's SSH_AUTH_SOCK at the agent pipe,
#   - creates and activates the docker context 'host' that dials the
#     docker_engine pipe.
#
# Rendered by scripts/run-windows-vmware-sandbox.sh: __AGENT_PORT__ and
# __DOCKER_PORT__ are the runner's bridge ports, __HOST_ALIAS__ is the
# host's NAT-segment address the guest reaches directly (the guest's
# default gateway is x.y.z.2, the host alias x.y.z.1).
$agentPort = __AGENT_PORT__
$dockerPort = __DOCKER_PORT__
$hostAlias = '__HOST_ALIAS__'
$node = 'C:\Program Files\nodejs\node.exe'
$relay = 'C:\tools\bridge-relay.js'
function Ensure-Relay([string]$pipe, [int]$port) {
  $running = $false
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -like "*$relay*$pipe*") { $running = $true }
  }
  if (-not $running -and (Test-Path $relay) -and (Test-Path $node)) {
    Start-Process -WindowStyle Hidden -FilePath $node -ArgumentList @($relay, $pipe, $hostAlias, "$port")
  }
}
Ensure-Relay '\\.\pipe\openssh-ssh-agent' $agentPort
Ensure-Relay '\\.\pipe\docker_engine' $dockerPort
$current = [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'User')
if ($current -ne '\\.\pipe\openssh-ssh-agent') {
  [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', '\\.\pipe\openssh-ssh-agent', 'User')
  $env:SSH_AUTH_SOCK = '\\.\pipe\openssh-ssh-agent'
}
if (Get-Command docker -ErrorAction SilentlyContinue) {
  docker context create host --docker "host=npipe:////./pipe/docker_engine" 2>$null | Out-Null
  docker context update host --docker "host=npipe:////./pipe/docker_engine" 2>$null | Out-Null
  docker context use host 2>$null | Out-Null
}
