# provisioning

Minimal, repeatable provisioning scripts for developer machines on Ubuntu and Windows. They install common tooling (Git, VS Code, Docker), set up a Python environment via Miniconda with conda-forge, and optionally prepare CUDA.

Works well for fresh machines or CI images. Re-runnable and idempotent-ish.

## What these scripts install

- Ubuntu (`scripts/provision-ubuntu.sh`):
  - Base tools: git, git-lfs, build-essential, cmake, ninja, unzip/xz/7zip
  - Optional: VS Code (Microsoft repo)
  - Optional: Docker Engine (Docker official apt repo) and user group membership
  - Miniconda for the invoking user, conda-forge enabled (strict priority), shell init (bash/zsh)
  - Optional: CUDA toolkit via NVIDIA apt repo and (optionally) NVIDIA driver

- Windows (`scripts/provision-win.ps1`):
  - Git, 7zip, CMake, Ninja
  - Visual Studio 2022 Build Tools (MSVC, MSBuild, CMake integration, Win11 SDK)
  - Optional: VS Code, Windows Terminal, Cmder, Docker Desktop
  - Miniconda, conda-forge enabled (strict), shell init for PowerShell and cmd
  - Optional: CUDA toolkit and (optionally) NVIDIA display driver

## Supported platforms

- Ubuntu 22.04/24.04 x86_64 (bare metal or VM). For WSL2, read the Docker note below.
- Windows 10/11 x64 with administrative rights.

ARM64: The Ubuntu script currently downloads the x86_64 Miniconda installer. If you are on ARM, change the installer URL in the script accordingly.

## Quick start

### Ubuntu

Prerequisites:

- Run as root (use sudo). Internet access. Fresh or existing system is fine.

1. Optionally adjust configuration flags at the top of `scripts/provision-ubuntu.sh`:

- INSTALL_VSCODE, INSTALL_DOCKER, INSTALL_CUDA, INSTALL_NVIDIA_DRIVER
- CUDA_TOOLKIT_PKG (e.g., `cuda-toolkit-12-4` or `cuda-toolkit`)

1. Run the script:


```bash
sudo bash scripts/provision-ubuntu.sh
```

Notes:

- If Docker is enabled, the invoking user is added to the `docker` group. Log out/in (or run `newgrp docker`) for it to take effect.
- If CUDA driver installation runs, a reboot is recommended.

### Windows

Prerequisites:

- Open an elevated PowerShell (Run as Administrator). Internet access.

1. Optionally adjust the `$Cfg` object at the top of `scripts/provision-win.ps1` to toggle installs, and pin versions if needed.

1. From an elevated PowerShell in the repository root, run:


```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
./scripts/provision-win.ps1
```

Notes:

- If Docker Desktop is installed and you were added to `docker-users`, sign out/in once.
- If NVIDIA driver was installed, a reboot may be required.

## Configuration flags (overview)

Ubuntu (`provision-ubuntu.sh`):

- INSTALL_VSCODE=true|false
- INSTALL_DOCKER=true|false
- INSTALL_CUDA=true|false
- INSTALL_NVIDIA_DRIVER=true|false
- CUDA_TOOLKIT_PKG="cuda-toolkit-12-4" (or empty for latest `cuda-toolkit`)

Windows (`provision-win.ps1`, within `$Cfg`):

- InstallVSCode, InstallDocker, InstallWindowsTerminal, InstallCmder
- InstallCUDA, InstallNvidiaDriver
- Optional version pins: GitVersion, VSCodeVersion, CMakeVersion, NinjaVersion, VSBuildToolsVersion, MinicondaVersion, WindowsTerminalVersion, CmderVersion, CudaToolkitVersion, NvidiaDriverVersion

## Verification

After the script completes, open a new terminal session and verify:

Ubuntu:

```bash
git --version
code --version        # if VS Code enabled
docker --version      # if Docker enabled
conda --version
python -V
nvcc --version        # if CUDA toolkit enabled
```

Windows (new PowerShell/Terminal tab):

```powershell
git --version
code --version        # if VS Code enabled
docker --version      # if Docker Desktop enabled
conda --version
python -V
nvcc --version        # if CUDA toolkit enabled
```

## Docker on WSL2 (note)

On Windows with WSL2 Ubuntu, prefer Docker Desktop integration rather than installing Docker Engine inside WSL. If you still enable Docker in WSL with this script, make sure the WSL kernel supports it and expect additional setup.

## Troubleshooting

- Must run as admin/root: Ubuntu requires `sudo`; Windows requires an elevated PowerShell.
- New shells required: Open a new terminal to pick up `conda init` changes and updated PATH.
- Docker group (Ubuntu): If `docker` commands require sudo after install, log out/in or run `newgrp docker`.
- NVIDIA driver/toolkit:
  - Ubuntu: Ensure your GPU is supported on the selected CUDA toolkit; use the correct Ubuntu version repo. Reboot after driver install.
  - Windows: If driver install was requested, reboot once before using CUDA.
- Corporate proxies: Configure system proxy and git proxy settings before running the scripts.

## Uninstall/rollback (brief)

These scripts use the system package managers (apt/Chocolatey) and vendor installers. Use those tools to uninstall if needed. For Miniconda, you can remove the install directory and undo shell init lines in your shell profiles.

## License

See `LICENSE` in this repository.

