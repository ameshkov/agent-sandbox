@echo off
rem start-relays.cmd -- starts the sandbox bridge relays detached from any
rem ssh session (a SYSTEM scheduled task runs this; see guest-setup.ps1).
rem Rendered by scripts/run-windows-vmware-sandbox.sh.
start "" /b "C:\Program Files\nodejs\node.exe" C:\tools\bridge-relay.js \\.\pipe\openssh-ssh-agent __HOST_ALIAS__ __AGENT_PORT__
start "" /b "C:\Program Files\nodejs\node.exe" C:\tools\bridge-relay.js \\.\pipe\docker_engine __HOST_ALIAS__ __DOCKER_PORT__
