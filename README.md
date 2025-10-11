# provisioning

Provisioning scripts for developer machines on Ubuntu and Windows. They install common tooling (Git, VS Code, Docker), set up a user-scoped Miniconda with conda-forge, and optionally prepare CUDA.

These scripts are CLI-configurable and expose small profiles to make running them predictable and repeatable.

## Scripts

- `scripts/provision-ubuntu.sh` — Bash script intended to be run as root (sudo). Supports profiles and CLI flags.
- `scripts/provision-win.ps1` — PowerShell script intended to run in an elevated PowerShell. Supports profiles and named parameters.

Quick reference

Ubuntu CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--profile` | `default` | profile preset: `default`, `minimal`, `gpu` |
| `--install-vscode` | `true` | Install Microsoft VS Code repo + `code` package |
| `--install-docker` | `true` | Install Docker Engine from Docker apt repo |
| `--install-cuda` | `false` | Install NVIDIA CUDA toolkit package |
| `--install-nvidia-driver` | `false` | Run `ubuntu-drivers autoinstall` to install GPU driver |
| `--cuda-toolkit-pkg` | `cuda-toolkit-12-4` | Specific CUDA toolkit package name to install |

Windows PowerShell parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Profile` | `default` | profile preset: `default`, `minimal`, `gpu` |
| `-InstallVSCode` | `$true` | Install VS Code via Chocolatey |
| `-InstallDocker` | `$true` | Install Docker Desktop via Chocolatey |
| `-InstallWindowsTerminal` | `$true` | Install Windows Terminal |
| `-InstallCmder` | `$true` | Install Cmder (or CmderMini via `-CmderPackageId`) |
| `-InstallCUDA` | `$false` | Install CUDA toolkit via Chocolatey |
| `-InstallNvidiaDriver` | `$false` | Install NVIDIA display driver via Chocolatey |
| `-<Something>Version` | `$null` | Optional version pin (strings) for many packages (e.g., `-CudaToolkitVersion`) |


## What they install (summary)

- Ubuntu: base dev tools (git, git-lfs, build-essential, cmake, ninja, unzip/xz/7zip), optional VS Code, optional Docker Engine, Miniconda for the invoking user (conda-forge configured), optional CUDA toolkit + driver.
- Windows: core tools via Chocolatey (git, 7zip, cmake, ninja, Visual Studio Build Tools), optional VS Code, Windows Terminal, Cmder, Docker Desktop, Miniconda, optional CUDA toolkit + driver.

## Ubuntu: usage, profiles and CLI flags

Run from the repository root. The script requires root to install system packages.

Basic run:

```bash
sudo bash scripts/provision-ubuntu.sh
```

Profiles

- `--profile=default`  (default) -> VS Code ON, Docker ON, CUDA OFF
- `--profile=minimal`  -> VS Code ON, Docker OFF, CUDA OFF
- `--profile=gpu`      -> VS Code ON, Docker ON, CUDA+Driver ON

CLI flags (override profile defaults)

- `--install-vscode=true|false`
- `--install-docker=true|false`
- `--install-cuda=true|false`
- `--install-nvidia-driver=true|false`
- `--cuda-toolkit-pkg=cuda-toolkit-12-4` (or `cuda-toolkit`)

Examples

- Default profile (VS Code + Docker):

```bash
sudo bash scripts/provision-ubuntu.sh
```

- Minimal profile (skip Docker):

```bash
sudo bash scripts/provision-ubuntu.sh --profile=minimal
```

- GPU profile but explicitly disable Docker:

```bash
sudo bash scripts/provision-ubuntu.sh --profile=gpu --install-docker=false
```

What the script does (high level)

- Detects the real (non-root) user who invoked sudo so Miniconda installs into their home.
- Adds/normalizes vendor apt repositories (Docker, Microsoft Code, NVIDIA CUDA) in an idempotent way.
- Installs base packages and tooling via apt.
- Installs Miniconda into the invoking user's home and runs `conda init` for bash and zsh.

Notes & gotchas

- Must run as root (sudo). The script exits early if not run as root.
- The script bundles logic to detect and resolve conflicting VS Code apt repo entries before running `apt update`.
- Miniconda installer URL targets x86_64 by default; change the URL in the script if you need aarch64/ARM builds.
- Docker: after install, log out/in or run `newgrp docker` to use Docker without sudo.
- CUDA: if the NVIDIA driver is installed, a reboot is recommended.

## Windows: usage and parameters

Run from an elevated PowerShell (Admin). The script exposes a `param()` block so you can pass named parameters on the command line.

Basic run (default profile):

```powershell
# from repo root in elevated PowerShell
./scripts/provision-win.ps1
```

Profiles (use `-Profile <name>`) and parameters

- `-Profile default`  -> default toggles as declared in the script
- `-Profile minimal`  -> skips Docker by default
- `-Profile gpu`      -> enables CUDA + NVIDIA driver by default

Parameters (examples)

- `-InstallVSCode:$true/$false`
- `-InstallDocker:$true/$false`
- `-InstallWindowsTerminal:$true/$false`
- `-InstallCmder:$true/$false`
- `-InstallCUDA:$true/$false`
- `-InstallNvidiaDriver:$true/$false`
- Version pins (strings): `-CudaToolkitVersion`, `-NvidiaDriverVersion`, `-GitVersion`, `-VSCodeVersion`, `-CMakeVersion`, `-NinjaVersion`, `-VSBuildToolsVersion`, `-MinicondaVersion`, `-WindowsTerminalVersion`, `-CmderVersion`

Example: GPU profile but skip Docker and pin CUDA version

```powershell
./scripts/provision-win.ps1 -Profile gpu -InstallDocker:$false -CudaToolkitVersion 12.4.1
```

What the script does (high level)

- Installs Chocolatey if missing, then uses it to install packages. Visual Studio Build Tools are installed with package parameters to include MSVC/MSBuild components.
- Installs Miniconda (choco package) and runs `conda init` for PowerShell and cmd.
- Ensures ExecutionPolicy for the CurrentUser is set so PowerShell profiles load (required for conda init to be effective).

Notes

- Must run in an elevated PowerShell. The script will throw if not elevated.
- If Docker Desktop is installed and your account was added to `docker-users`, sign out/in.
- If NVIDIA driver is installed, reboot is recommended.

## Verification

After running either script, open a new shell and verify the main tools are available:

Ubuntu (new terminal):

```bash
git --version
code --version        # if VS Code enabled
docker --version      # if Docker enabled
conda --version
python -V
nvcc --version        # if CUDA installed
```

Windows (open a new elevated PowerShell or normal PowerShell after admin tasks complete):

```powershell
git --version
code --version        # if VS Code enabled
docker --version      # if Docker Desktop enabled
conda --version
python -V
nvcc --version        # if CUDA installed
```

## Troubleshooting

- Run as admin/root: Ubuntu requires `sudo`; Windows requires an elevated PowerShell.
- New shells required: Open a new terminal to pick up `conda init` changes and updated PATH.
- Docker group (Ubuntu): If `docker` commands require sudo after install, log out/in or run `newgrp docker`.
- VS Code apt repo conflicts: the Ubuntu script tries to detect and normalize duplicate Microsoft Code repo entries before `apt update` to avoid signed-by problems.
- Corporate proxies: Configure system proxy and git proxy settings before running the scripts.

## Uninstall/rollback (brief)

These scripts use the system package managers (apt/Chocolatey) and vendor installers. Use those package managers to remove installed packages. To remove Miniconda, delete the installation path (e.g., `~/miniconda3`) and remove the `conda init` lines from the user's shell profile.

## License

See `LICENSE` in this repository.

