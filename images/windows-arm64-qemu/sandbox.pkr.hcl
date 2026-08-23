packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
#
# Most variables mirror the macOS template (images/mac/sandbox.pkr.hcl) so
# the vars files look and feel the same. The Windows build differs in the
# mechanics: the OS comes from a bring-your-own ISO instead of a GHCR base
# image, provisioning happens over WinRM instead of SSH, and the image is a
# qcow2 disk instead of a Tart VM.

variable "windows_version" {
  type        = string
  description = "Windows guest version, e.g. '11'; part of the image name (sandbox-windows-<windows_version>)."
}

variable "image_version" {
  type        = string
  description = "Semantic version this image is published under; bump it + add a CHANGELOG.md entry per release."
}

# --- Windows install ISO (bring-your-own, see images/windows-arm64-qemu/README.md) ---

variable "iso_path" {
  type        = string
  description = "Absolute path to the Windows 11 ARM64 ISO. Set by images/windows-arm64-qemu/build.sh (PKR_VAR_iso_path); the ISO is not redistributable so it cannot live in the repo. Required — validate with `-var iso_path=/path/to/iso`."
}

variable "iso_sha256" {
  type        = string
  default     = ""
  description = "SHA256 of the Windows ISO as published on the Microsoft download page. Read by images/windows-arm64-qemu/build.sh for verification, not by Packer itself (iso_checksum is 'none')."
}

# --- virtio-win drivers (ARM64) ---

variable "virtio_win_iso_path" {
  type        = string
  default     = ""
  description = "Absolute path to virtio-win.iso (release 0.1.240+). Set by images/windows-arm64-qemu/build.sh; the wrapper stages the ARM64 driver subset into drivers/staging/ and qemu-with-tpm.sh attaches the full ISO as a CD."
}

variable "virtio_win_url" {
  type        = string
  default     = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  description = "Download URL used by images/windows-arm64-qemu/build.sh when VIRTIO_WIN_ISO_PATH is unset."
}

variable "virtio_win_sha256" {
  type        = string
  default     = ""
  description = "SHA256 of virtio-win.iso. Read by images/windows-arm64-qemu/build.sh for verification (empty = skip)."
}

# --- Toolchain versions (installed via Chocolatey) ---

variable "nodejs_version" {
  type        = string
  description = "Node.js version, e.g. '22.23.2' (choco package version)."
}

variable "python_version" {
  type        = string
  description = "Python version, e.g. '3.13.1' (choco package version)."
}

variable "github_cli_version" {
  type        = string
  description = "GitHub CLI version, e.g. '2.97.0' (choco package version)."
}

variable "ripgrep_version" {
  type        = string
  description = "ripgrep version, e.g. '15.2.0' (choco package version)."
}

variable "git_version" {
  type        = string
  description = "Git version, e.g. '2.55.0.4' (choco package version)."
}

variable "jq_version" {
  type        = string
  description = "jq version, e.g. '1.8.1' (choco package version)."
}

variable "open_code_review_version" {
  type        = string
  description = "open-code-review (ocr) version installed via npm."
}

variable "chrome_version" {
  type        = string
  description = "Google Chrome version (Chrome for Testing snapshot, e.g. '152.0.7977.54')."
}

variable "chrome_sha256" {
  type        = string
  description = "SHA256 of the CfT chrome-win64.zip for chrome_version."
}

# --- VM resources ---

variable "disk_size" {
  type        = number
  default     = 100
  description = "VM disk size in GB."
}

variable "cpu_count" {
  type        = number
  default     = 4
  description = "CPU count of the VM."
}

variable "memory_gb" {
  type        = number
  default     = 8
  description = "RAM of the VM in GB."
}

# --- WinRM credentials (baked into autounattend.xml — keep in sync) ---

variable "winrm_username" {
  type        = string
  default     = "Administrator"
  description = "User used for WinRM provisioning; must match the account autounattend.xml creates."
}

variable "winrm_password" {
  type        = string
  default     = "sandbox1"
  sensitive   = true
  description = "Password of the provisioning account; must match autounattend.xml."
}

# --- OpenChamber web UI ---

variable "openchamber_ui_password" {
  type        = string
  default     = "sandbox"
  description = "Password protecting the OpenChamber web UI; required because the server binds to 0.0.0.0 (host access: http://127.0.0.1:4000)."
}

variable "openchamber_port" {
  type        = number
  default     = 4000
  description = "TCP port the OpenChamber web UI listens on inside the guest."
}

# --- QEMU specifics ---

variable "qemu_binary" {
  type        = string
  default     = "./qemu-with-tpm.sh"
  description = "qemu binary (or wrapper) Packer invokes. The wrapper appends the TPM/ramfb/USB/CD rewrites Packer's qemuargs option cannot express (it replaces the generated args)."
}

variable "efi_firmware_code" {
  type        = string
  default     = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
  description = "UEFI firmware (read-only code image) for the ARM64 guest; ships with Homebrew's qemu."
}

variable "efi_firmware_vars" {
  type        = string
  default     = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"
  description = "UEFI firmware template for the writable NVRAM store; Packer copies it per build."
}

# ---------------------------------------------------------------------------
# Source: QEMU (aarch64 + Apple Silicon HVF)
# ---------------------------------------------------------------------------
#
# The recipe is proven on Apple Silicon (HVF can only virtualize ARM64
# guests, so x86_64 Windows would run under slow TCG emulation):
#   - machine "virt,gic-version=max", cpu "host" (required by HVF; do NOT
#     add virtualization=on — HVF cannot pass nested virt through),
#   - UEFI via edk2 AAVMF firmware + swtpm TPM 2.0 (Win11 system
#     requirements; swtpm is started by images/windows-arm64-qemu/build.sh),
#   - all CD-ROMs attached as usb-storage (the virt machine has no
#     IDE/SATA controller and WinPE has in-box xHCI drivers) — done by
#     qemu-with-tpm.sh because the plugin's qemuargs option would replace
#     its auto-generated args,
#   - the ARM64 virtio drivers (viostor/vioscsi/NetKVM) are staged into
#     the same CD as autounattend.xml (drivers/staging/), because WinPE
#     drive-letter enumeration on ARM64 + EFI is non-deterministic.
#
# See images/windows-arm64-qemu/README.md and DEVELOPMENT.md for the full flow.

source "qemu" "windows" {
  vm_name          = "sandbox-windows-${var.windows_version}.qcow2"
  output_directory = "output"

  # The wrapper (images/windows-arm64-qemu/build.sh) verifies the ISO against
  # var.iso_sha256 before Packer runs; iso_checksum is "none" so Packer
  # does not re-verify.
  iso_url      = var.iso_path
  iso_checksum = "none"

  cpus           = var.cpu_count
  memory         = var.memory_gb * 1024
  disk_size      = "${var.disk_size}G"
  format         = "qcow2"
  disk_interface = "virtio"
  net_device     = "virtio-net-pci"

  machine_type = "virt,gic-version=max"
  accelerator  = "hvf"
  cpu_model    = "host"

  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars

  qemu_binary = var.qemu_binary

  # Unattend CD: Windows Setup probes attached media for Autounattend.xml
  # at the root and applies it before the language picker, so no keyboard
  # input is needed — except for the firmware's ~5 s "Press any key to
  # boot from CD" prompt, hence the enter-spam below.
  cd_files = ["./autounattend.xml", "./drivers"]
  cd_label = "UNATTEND"

  # WinRM, not SSH: it comes up via autounattend's FirstLogonCommands
  # before any OpenSSH server exists, and DISM online servicing needs the
  # elevated token the provisioners request.
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "90m"
  winrm_port     = 5985

  # Headless: no QEMU window, so the cocoa quit-confirmation dialog can
  # never stall a build (it popped up on every windowed run). Progress is
  # still watchable via the plugin's VNC server (e.g. vncdotool captures).
  headless = true

  # Enter-spam: answers the firmware's "Press ESC in 1 second" shell prompt
  # AND Windows' "Press any key to boot from CD or DVD" prompt on the first
  # boot. Without it, a boot that lands in the EFI shell stalls forever
  # (Windows cannot be booted reliably from the shell). The keys are typed
  # within the first ~15 s, long before Setup's UI appears, so the Cancel
  # dialog they trigger on the "Installing Windows 11" screen is auto-
  # dismissed by the build watchdog (see scripts/watch-build.sh on the host).
  boot_wait = "1s"
  boot_command = [
    "<enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter>",
  ]
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  sources = ["source.qemu.windows"]

  # ===== Preamble: settle after OOBE, dump versions =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$ProgressPreference = 'SilentlyContinue'",
      "$os = Get-CimInstance Win32_OperatingSystem",
      "Write-Host \"Windows install complete: $($os.Caption) build $($os.BuildNumber) ($env:PROCESSOR_ARCHITECTURE)\"",
      "Write-Host 'Waiting 30s for post-OOBE first-logon scripts to settle...'",
      "Start-Sleep -Seconds 30",
    ]
  }

  # ===== VirtIO guest tools (full driver suite + qemu guest agent) =====
  # The MSI lives on the virtio-win CD attached by qemu-with-tpm.sh (the
  # last usb-storage device). WinPE got the boot-critical drivers from the
  # unattend CD; this registers everything else in the installed OS.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      # The virtio-win CD may not be mounted yet right after first logon;
      # retry for up to ~2 min before giving up.
      "$msi = $null",
      "for ($try = 0; $try -lt 8 -and -not $msi; $try++) {",
      "  $cdroms = Get-WmiObject Win32_CDROMDrive | Select-Object -ExpandProperty Drive",
      "  foreach ($drive in $cdroms) {",
      "    $msi = Get-ChildItem $drive -Filter 'virtio-win-guest-tools*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1",
      "    if ($msi) { break }",
      "  }",
      "  if (-not $msi) { Start-Sleep -Seconds 15 }",
      "}",
      "if (-not $msi) {",
      "  Write-Warning 'virtio-win-guest-tools MSI not found on any CD-ROM; skipping guest tools'",
      "} else {",
      "  Write-Host \"Installing $($msi.Name)\"",
      "  Start-Process msiexec.exe -ArgumentList \"/i `\"$($msi.FullName)`\" /qn /norestart\" -Wait",
      "  Start-Sleep -Seconds 5",
      "}",
      "$ga = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue",
      "if ($ga) { Set-Service 'QEMU-GA' -StartupType Automatic; Start-Service 'QEMU-GA' -ErrorAction SilentlyContinue }",
    ]
  }

  # ===== Chocolatey + .NET strong crypto =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072",
      "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
      "if ($LASTEXITCODE -ne 0) { throw \"chocolatey install failed: $LASTEXITCODE\" }",
      "choco feature enable -n allowGlobalConfirmation",
      "# Legacy .NET strong-crypto: without it, older TLS stacks fail against modern hosts",
      "reg add 'HKLM\\SOFTWARE\\Microsoft\\.NETFramework\\v4.0.30319' /v SchUseStrongCrypto /t REG_DWORD /d 1 /f",
      "reg add 'HKLM\\SOFTWARE\\Wow6432Node\\Microsoft\\.NETFramework\\v4.0.30319' /v SchUseStrongCrypto /t REG_DWORD /d 1 /f",
    ]
  }

  # ===== Toolchain via Chocolatey (versions from the vars file) =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      $ProgressPreference = 'SilentlyContinue'
      choco install nodejs --version=${var.nodejs_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco nodejs failed: $LASTEXITCODE" }
      choco install gh --version=${var.github_cli_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco gh failed: $LASTEXITCODE" }
      choco install ripgrep --version=${var.ripgrep_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco ripgrep failed: $LASTEXITCODE" }
      choco install git --version=${var.git_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco git failed: $LASTEXITCODE" }
      choco install jq --version=${var.jq_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco jq failed: $LASTEXITCODE" }
      choco install python --version=${var.python_version} -y
      if ($LASTEXITCODE -ne 0) { throw "choco python failed: $LASTEXITCODE" }
      choco install firefox curl docker-cli docker-compose -y
      if ($LASTEXITCODE -ne 0) { throw "choco browsers/docker failed: $LASTEXITCODE" }

      # ===== Google Chrome (CfT snapshot, hash-pinned) =====
      # choco's googlechrome package downloads the live dl.google.com MSI,
      # whose binary rotates with every Chrome release — the pinned hash
      # breaks between releases (observed with 152.0.7977.54). Instead we
      # fetch the versioned Chrome for Testing archive, verify the SHA256,
      # and extract it into the standard install location.
      $chromeUrl = "https://storage.googleapis.com/chrome-for-testing-public/${var.chrome_version}/win64/chrome-win64.zip"
      $chromeZip = "$env:TEMP\chrome-win64.zip"
      $chromeAppDir = 'C:\Program Files\Google\Chrome\Application'
      $chromeExe = Join-Path $chromeAppDir 'chrome.exe'
      # 202 MB over usermode networking can drop mid-transfer; retry.
      $downloaded = $false
      for ($try = 1; $try -le 3 -and -not $downloaded; $try++) {
        try {
          Invoke-WebRequest -UseBasicParsing -Uri $chromeUrl -OutFile $chromeZip -ErrorAction Stop
          $downloaded = $true
        } catch {
          Write-Host "chrome download attempt $try failed: $($_.Exception.Message)"
          if ($try -lt 3) { Start-Sleep -Seconds 10 }
        }
      }
      if (-not $downloaded) { throw "chrome download failed after 3 attempts" }
      $actual = (Get-FileHash -Path $chromeZip -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne '${var.chrome_sha256}') {
        throw "chrome checksum mismatch: expected ${var.chrome_sha256}, got $actual"
      }
      New-Item -ItemType Directory -Force -Path "$env:TEMP\chrome-x" | Out-Null
      Expand-Archive -Path $chromeZip -DestinationPath "$env:TEMP\chrome-x" -Force
      New-Item -ItemType Directory -Force -Path $chromeAppDir | Out-Null
      Copy-Item -Path "$env:TEMP\chrome-x\chrome-win64\*" -Destination $chromeAppDir -Recurse -Force
      Remove-Item -Path "$env:TEMP\chrome-x", $chromeZip -Recurse -Force
      # Register App Paths so `start chrome` / shell launchers resolve it
      $appPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
      New-Item -Path $appPaths -Force | Out-Null
      New-ItemProperty -Path $appPaths -Name '(Default)' -Value $chromeExe -PropertyType String -Force | Out-Null
      if (-not (Test-Path $chromeExe)) { throw "chrome.exe not found after extraction" }
      $toolPaths = @(
        'C:\Program Files\nodejs',
        'C:\ProgramData\chocolatey\bin',
        'C:\Program Files\Git\cmd',
        'C:\Program Files\Git\bin',
        'C:\Program Files\Google\Chrome\Application',
        "$env:APPDATA\npm"
      )
      $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine').TrimEnd(';')
      foreach ($toolPath in $toolPaths) {
        if ((Test-Path $toolPath) -and -not (($machinePath -split ';') -contains $toolPath)) {
          $machinePath = $machinePath + ';' + $toolPath
        }
      }
      [System.Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
      $env:Path = $machinePath + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
      node --version
      git --version
      gh --version
      rg --version
      jq --version
      python --version
      END
    ]
  }

  # ===== Visual Studio Code (native arm64, direct download) =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      $ProgressPreference = 'SilentlyContinue'
      $installer = "$env:TEMP\vscode-arm64-user-setup.exe"
      $downloaded = $false
      for ($try = 1; $try -le 3 -and -not $downloaded; $try++) {
        try {
          Invoke-WebRequest -UseBasicParsing -Uri 'https://update.code.visualstudio.com/latest/win32-arm64-user/stable' -OutFile $installer -ErrorAction Stop
          $downloaded = $true
        } catch {
          Write-Host "vscode download attempt $try failed: $($_.Exception.Message)"
          if ($try -lt 3) { Start-Sleep -Seconds 10 }
        }
      }
      if (-not $downloaded) { throw "vscode download failed after 3 attempts" }
      Start-Process $installer -ArgumentList '/VERYSILENT /NORESTART /MERGETASKS=!runcode' -Wait
      Remove-Item $installer -Force
      $codeBin = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin"
      if (Test-Path $codeBin) {
        $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine').TrimEnd(';')
        if (-not (($machinePath -split ';') -contains $codeBin)) {
          [System.Environment]::SetEnvironmentVariable('Path', $machinePath + ';' + $codeBin, 'Machine')
        }
      }
      END
    ]
  }

  # ===== OpenCode, OpenCodeReview, OpenChamber web UI =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      # EAP=Continue, not Stop: this script runs many native commands
      # (schtasks, npm, openchamber) whose stderr lines become terminating
      # errors under Stop in Windows PowerShell 5.1 (the 2>$null / 2>&1
      # native-stderr bug). All failure handling is explicit below.
      $ErrorActionPreference = 'Continue'
      $ProgressPreference = 'SilentlyContinue'
      $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine').TrimEnd(';')
      $env:Path = $machinePath + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
      # The openchamber scheduled task launches at logon and locks its
      # node_modules — kill it before reinstalling, and retry npm installs
      # (the guest's usermode networking drops large transfers).
      try { schtasks /End /TN dev.openchamber.web 2>&1 | Out-Null } catch {}
      Stop-Process -Name node -Force -ErrorAction SilentlyContinue
      function Invoke-NpmRetry([string]$argsLine) {
        for ($try = 1; $try -le 3; $try++) {
          cmd /c "npm $argsLine" 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) { return }
          Write-Host "npm $argsLine attempt $try failed ($LASTEXITCODE); retrying"
          Start-Sleep -Seconds 10
        }
        throw "npm $argsLine failed after 3 attempts"
      }
      Invoke-NpmRetry "install -g opencode-ai"
      New-Item -ItemType Directory -Force -Path C:\npm-global | Out-Null
      Invoke-NpmRetry "install -g --prefix C:\npm-global --ignore-scripts @alibaba-group/open-code-review@${var.open_code_review_version}"
      foreach ($toolPath in @('C:\npm-global')) {
        if ((Test-Path $toolPath) -and -not (($machinePath -split ';') -contains $toolPath)) {
          $machinePath = $machinePath + ';' + $toolPath
        }
      }
      [System.Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
      Invoke-NpmRetry "install -g @openchamber/web"
      $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
      opencode --version
      ocr --version
      # Web UI as a native service (Windows: scheduled task). Snapshot the
      # absolute opencode path like the macOS template does.
      $opencodeBin = (Get-Command opencode -ErrorAction Stop).Source
      $env:OPENCODE_BINARY = $opencodeBin
      # openchamber's own `startup enable` writes startup.env but then fails
      # to register the task — its schtasks /TR command exceeds the 261-char
      # limit and the failure aborts the whole provisioner. So: let it write
      # the env file, ignore the failure, and register a compact task that
      # runs a small wrapper script instead of a giant inline command.
      try {
        openchamber startup enable --port ${var.openchamber_port} --lan --ui-password "${var.openchamber_ui_password}" 2>$null | Out-Null
      } catch {}
      $LASTEXITCODE = 0
      $envFile = 'C:\Users\Administrator\.config\openchamber\startup.env'
      if (-not (Test-Path $envFile)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $envFile) | Out-Null
        @"
OPENCHAMBER_UI_PASSWORD='${var.openchamber_ui_password}'
OPENCODE_BINARY='$opencodeBin'
"@ | Set-Content -Path $envFile -Encoding UTF8
      }
      New-Item -ItemType Directory -Force -Path C:\tools | Out-Null
      $wrapper = @'
$envFile = 'C:\Users\Administrator\.config\openchamber\startup.env'
if (Test-Path $envFile) {
  Get-Content $envFile | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
      $v = $matches[2]
      if ($v.StartsWith("'") -and $v.EndsWith("'")) {
        $v = $v.Substring(1, $v.Length - 2).Replace("'\''", "'")
      }
      [Environment]::SetEnvironmentVariable($matches[1], $v, 'Process')
    }
  }
}
& 'C:\Program Files\nodejs\node.exe' 'C:\Users\Administrator\AppData\Roaming\npm\node_modules\@openchamber\web\bin\cli.js' serve --foreground --port ${var.openchamber_port} --host 0.0.0.0
'@
      Set-Content -Path C:\tools\openchamber-startup.ps1 -Value $wrapper -Encoding UTF8
      # Register the logon task. schtasks.exe from the elevated WinRM
      # session can be flaky (silent /Create failures, /Run "file not
      # found"); fall back to the PowerShell-native Register-ScheduledTask
      # (same mechanism the build-agent-images repo uses). Never fail the
      # build here — worst case the web UI starts at first login.
      $taskRegistered = $false
      try {
        schtasks /Create /TN dev.openchamber.web /SC ONLOGON /RL LIMITED /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\tools\openchamber-startup.ps1" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          schtasks /Run /TN dev.openchamber.web 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) { $taskRegistered = $true }
        }
        $LASTEXITCODE = 0
      } catch {
        Write-Warning "schtasks registration failed ($($_.Exception.Message)); trying Register-ScheduledTask"
        $LASTEXITCODE = 0
      }
      if (-not $taskRegistered) {
        try {
          $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\tools\openchamber-startup.ps1'
          $trigger = New-ScheduledTaskTrigger -AtLogOn
          Register-ScheduledTask -TaskName 'dev.openchamber.web' -Action $action -Trigger $trigger -Force | Out-Null
          Start-ScheduledTask -TaskName 'dev.openchamber.web'
          $taskRegistered = $true
        } catch {
          Write-Warning "Register-ScheduledTask also failed: $($_.Exception.Message); the web UI will start at first login instead"
          $LASTEXITCODE = 0
        }
      }
      if ($taskRegistered) { Write-Host "OpenChamber task registered: $taskRegistered" }
      # Windows' firewall "TCP/UDP Query User" rules for node.exe default to
      # BLOCK when the allow prompt goes unanswered (headless build) — the
      # web UI then only answers on the guest loopback. Remove them and
      # allow port 4000 explicitly so the host can reach the UI.
      Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Query User*node.exe*' } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
      New-NetFirewallRule -DisplayName 'OpenChamber' -Direction Inbound -Action Allow -Protocol TCP -LocalPort ${var.openchamber_port} -Profile Any -ErrorAction SilentlyContinue | Out-Null
      $LASTEXITCODE = 0
      END
    ]
  }

  # ===== OpenSSH Server + RDP =====
  # sshd gives the host a management channel (scripts/run-windows-sandbox.sh
  # forwards guest 22 to host 2222); RDP gives a desktop session. Password
  # auth is enabled for the Administrator account so the fixed sandbox
  # credentials from the vars file work.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      # Note: Add-WindowsCapability is a cmdlet — it does NOT set
      # $LASTEXITCODE (a stale $null made the old `if ($LASTEXITCODE -ne 0)`
      # check false-fire and abort the build even on success). Failures
      # surface as terminating errors via -ErrorAction Stop instead.
      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
      Set-Service -Name sshd -StartupType Automatic
      $cfg = 'C:\ProgramData\ssh\sshd_config'
      if (Test-Path $cfg) {
        (Get-Content $cfg) -replace '#PasswordAuthentication yes','PasswordAuthentication yes' `
          -replace 'Match Group administrators','#Match Group administrators' `
          -replace '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys','#       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys' `
          | Set-Content $cfg
      }
      # PowerShell as the default SSH shell
      New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
      New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
      Start-Service sshd
      # RDP
      Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
      Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
      END
    ]
  }

  # ===== Bridge tooling: socat + npiperelay (best-effort) =====
  # Used by the SSH-agent bridge on the host side of the sandbox runner
  # (see docs/windows.md once the runner lands). Not load-bearing for the
  # image itself, so a download failure only warns.
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      $ProgressPreference = 'SilentlyContinue'
      try {
        New-Item -ItemType Directory -Force -Path C:\tools | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip' -OutFile "$env:TEMP\npiperelay.zip"
        Expand-Archive "$env:TEMP\npiperelay.zip" -DestinationPath C:\tools -Force
        Remove-Item "$env:TEMP\npiperelay.zip" -Force
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/valorisa/socat-1.8.0.1_for_Windows/raw/main/socat.exe' -OutFile 'C:\tools\socat.exe'
        $machinePath = [System.Environment]::GetEnvironmentVariable('Path','Machine').TrimEnd(';')
        if (-not (($machinePath -split ';') -contains 'C:\tools')) {
          [System.Environment]::SetEnvironmentVariable('Path', $machinePath + ';C:\tools', 'Machine')
        }
        Write-Host 'Bridge tooling installed: C:\tools\npiperelay.exe, C:\tools\socat.exe'
      } catch {
        Write-Warning "Bridge tooling install failed (bridges will be unavailable): $($_.Exception.Message)"
      }
      END
    ]
  }

  # ===== Performance & privacy hardening =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      # --- Disable Defender realtime scanning (speed + flakiness) ---
      Set-MpPreference -DisableRealtimeMonitoring $true
      reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender' /v DisableAntiSpyware /t REG_DWORD /d 1 /f
      # --- Disable heavyweight / telemetry services ---
      $disableServices = @(
        'WSearch',       # Windows Search indexer
        'SysMain',       # Superfetch
        'DiagTrack',     # Diagnostics Tracking (telemetry)
        'dmwappushservice',
        'MapsBroker',    # Downloaded Maps Manager
        'lfsvc',         # Geolocation
        'RetailDemo',
        'wisvc'          # Windows Insider
      )
      foreach ($svc in $disableServices) {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) {
          Stop-Service $svc -Force -ErrorAction SilentlyContinue
          Set-Service $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
      }
      # --- Scheduled telemetry tasks ---
      @(
        '\\Microsoft\\Windows\\Application Experience\\',
        '\\Microsoft\\Windows\\Customer Experience Improvement Program\\'
      ) | ForEach-Object {
        Get-ScheduledTask -TaskPath $_ -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
      }
      # --- Filesystem + boot + power ---
      fsutil behavior set disablelastaccess 1 | Out-Null
      fsutil behavior set disable8dot3 1 | Out-Null
      bcdedit /timeout 0 | Out-Null
      powercfg /h off | Out-Null
      Set-TimeZone -Id 'UTC'
      END
    ]
  }

  # ===== Final verification & cleanup =====
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    inline = [<<-END
      $ErrorActionPreference = 'Stop'
      Write-Host '=== Versions ==='
      $os = Get-CimInstance Win32_OperatingSystem
      Write-Host "Windows: $($os.Caption) build $($os.BuildNumber)"
      node --version
      npm --version
      python --version
      git --version
      gh --version
      rg --version
      jq --version
      opencode --version
      ocr --version
      openchamber --version
      docker --version
      docker compose version
      Write-Host "Chrome: $(Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe')"
      Write-Host "Firefox: $(Test-Path 'C:\Program Files\Mozilla Firefox\firefox.exe')"
      Write-Host "VS Code: $(Test-Path "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd")"
      # Cleanup — must never fail the build: choco cleanup can exit non-zero
      # (locked files etc.) and that $LASTEXITCODE would otherwise propagate
      # as the script's exit code even though everything succeeded.
      choco cleanup -y 2>&1 | Out-Null
      $LASTEXITCODE = 0
      Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host 'Windows sandbox image complete'
      END
    ]
  }
}
