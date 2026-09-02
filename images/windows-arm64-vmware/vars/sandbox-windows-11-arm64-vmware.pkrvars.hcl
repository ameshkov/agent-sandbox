# Windows 11 (ARM64) sandbox image — VMware (Fusion) build.
#
# Built with the Packer vmware-iso plugin on Apple Silicon (the vmware-iso
# builder drives VMware Fusion, which virtualizes ARM64 guests natively):
# Windows 11 ARM64 ISO + Fusion's ARM64 boot drivers + VMware Tools. See
# images/windows-arm64-vmware/README.md for the full build flow — the
# Windows ISO is bring-your-own (Microsoft does not permit redistribution),
# so it is not part of this repo.

windows_version = "11"

# SHA256 of the Windows 11 ARM64 ISO. Microsoft publishes the hash on the
# download page (https://www.microsoft.com/software-download/windows11arm64);
# paste it here to enable integrity verification. Set WINDOWS_ISO_PATH to
# the local ISO path when building. Empty = skip verification.
iso_sha256 = "638AA2C88E94385B00F4F178D071E3DF0B7D9E335577A83BD533B7F2EB65ADF0"

# VMware Fusion installation that supplies the ARM64 boot drivers
# (Contents/Library/isoimages/arm64/drivers-arm64.zip) and the ARM64 VMware
# Tools ISO (Contents/Library/isoimages/arm64/windows.iso) during the build;
# the sandbox runner needs the same Fusion to run the VM.
# Fusion 13.6+ is required (the Packer vmware plugin's minimum).
vmware_fusion_app_path = "/Applications/VMware Fusion.app"

# Toolchain versions installed via Chocolatey (choco package versions —
# must exist in the community repository).
nodejs_version = "22.23.2"
python_version = "3.13.15"
github_cli_version = "2.97.0"
ripgrep_version = "15.2.0"
git_version = "2.55.0.4"
jq_version = "1.8.1"
open_code_review_version = "1.9.5"

# C/C++ + cross-language toolchains (brought over from AdGuard's
# build-agent-images windows2022-vs2022 / windows2022-go images).
# VS2022 Build Tools (choco package version; the finalizer adds the .NET
# SDKs + VC++ workload + Win11 SDK) and Rust (via rustup, not choco) are
# installed by dedicated provisioners.
go_version = "1.27.0"
rust_version = "1.95"
wixtoolset_version = "3.14.1.20250415"
protoc_version = "36.0.0"
nasm_version = "3.2.0"
llvm_version = "22.1.7"
vim_version = "9.2.995"
nuget_version = "7.9.0"
mingw_version = "16.1.0"
make_version = "4.4.1"
vs_buildtools_version = "117.14.37"

# Google Chrome: installed from the Chrome for Testing (CfT) snapshot
# archive instead of choco — choco's googlechrome package always downloads
# the live dl.google.com MSI whose hash rotates on every Chrome release,
# so the pinned package hash breaks between releases. CfT serves versioned
# zips at storage.googleapis.com/chrome-for-testing-public/<version>/,
# which stay downloadable and hash-stable. The x64 build runs under Windows
# on ARM emulation, like the choco MSI did.
chrome_version = "152.0.7977.54"
chrome_sha256 = "91850065e6b80bba0c752e17a150fe1b9e39bba51ed705640c1273f565950dda"

# VM resources
disk_size = 100
cpu_count = 4
memory_gb = 8

# WinRM credentials used for provisioning. They are baked into
# images/windows-arm64-vmware/autounattend.xml (Administrator password) and
# become the sandbox's login (SSH/RDP) — keep the two files in sync.
winrm_username = "Administrator"
winrm_password = "sandbox1"

# OpenChamber web UI password + port. The runner advertises the UI at
# http://<guest-ip>:4000 (password "sandbox" by default). OpenChamber
# refuses to serve on the network without a password.
openchamber_ui_password = "sandbox"
openchamber_port = 4000

# Semantic version this image is published under (also the GHCR push tag,
# besides :latest). For every release: bump it, add a CHANGELOG.md entry,
# and create the windows-arm64-vmware-v<version> git tag
# (npx agent-dev-env tag <image>).
image_version = "1.0.0"
