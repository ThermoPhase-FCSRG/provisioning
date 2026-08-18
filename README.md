# provisioning

Provisioning scripts for developer machines on Ubuntu, macOS, and Windows. They install common tooling (Git, VS Code, Docker), Pixi, a user-scoped Conda distribution, and optionally prepare NVIDIA drivers and CUDA.

These scripts are CLI-configurable and expose small profiles to make running them predictable and repeatable.

## Scripts

- `scripts/provision-ubuntu.sh` — Bash script intended to be run as root (sudo). Supports profiles and CLI flags.
- `scripts/provision-macos.sh` — Bash script intended to run on macOS (user context). Supports profiles and CLI flags. Installs Homebrew, common casks (VS Code, Docker), Miniforge (conda-forge), and developer tooling.
- `scripts/provision-win.ps1` — PowerShell script intended to run in an elevated PowerShell. Supports profiles and named parameters.

Quick reference

Ubuntu CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--profile` | `default` | profile preset: `default`, `minimal`, `gpu` |
| `--install-vscode` | `true` | Install Microsoft VS Code repo + `code` package |
| `--install-docker` | `true` | Install Docker Engine from Docker apt repo |
| `--install-cuda` | `false` | Install NVIDIA CUDA toolkit package |
| `--install-driver` | `false` | Install NVIDIA GPU driver on bare-metal Ubuntu; skipped on WSL |
| `--cuda-toolkit-pkg` | `cuda-toolkit` | Toolkit package from the NVIDIA repository; may be version-pinned |
| `--nvidia-driver-pkg` | `nvidia-open` | NVIDIA driver package used on bare-metal Ubuntu |
| `--install-python` | `true` | Install system Python3 + venv + pip |
| `--install-pixi` | `true` | Install Pixi for the invoking user |

macOS CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--profile` | `default` | profile preset: `default`, `minimal`, `gpu` |
| `--install-vscode` | `true` | Install Visual Studio Code via Homebrew cask |
| `--install-docker` | `true` | Install Docker Desktop via Homebrew cask |
| `--install-iterm2` | `true` | Install iTerm2 via Homebrew cask |
| `--install-rosetta` | `false` | Install Rosetta 2 on Apple Silicon |
| `--install-miniforge` | `true` | Install Miniforge (conda-forge) |
| `--miniforge-prefix` | `$HOME/miniforge3` | Install path for Miniforge |
| `--install-llvm` | `true` | Install Homebrew llvm and libomp |
| `--install-python` | `true` | Install Homebrew Python (includes venv) |
| `--install-pixi` | `true` | Install Pixi through Homebrew |

Windows PowerShell parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Profile` | `default` | profile preset: `default`, `minimal`, `gpu` |
| `-InstallVSCode` | `$true` | Install VS Code via Chocolatey |
| `-InstallDocker` | `$true` | Install Docker Desktop via Chocolatey |
| `-InstallWindowsTerminal` | `$true` | Install Windows Terminal |
| `-InstallCmder` | `$true` | Install Cmder (or CmderMini via `-CmderPackageId`) |
| `-InstallPixi` | `$true` | Install Pixi for the current user |
| `-InstallCUDA` | `$false` | Install CUDA toolkit via Chocolatey |
| `-InstallNvidiaDriver` | `$false` | Install NVIDIA display driver via Chocolatey |
| `-<Something>Version` | `$null` | Optional version pin (strings) for many packages (e.g., `-CudaToolkitVersion`) |


## What they install (summary)

- Ubuntu: base dev tools, Pixi, optional VS Code and Docker Engine, Miniconda for the invoking user, and independently selectable NVIDIA driver and CUDA Toolkit.
- macOS: Homebrew, Pixi, core dev tooling, common casks, and Miniforge installed into the user's home.
- Windows: core tools via Chocolatey, Pixi, optional desktop tools, Miniconda, and independently selectable NVIDIA driver and CUDA Toolkit.

## PyTorch and torch-flash recommendation

Prebuilt PyTorch, Conda, and Pixi packages normally provide their own CUDA user-space runtime. For a PyTorch workstation, install a current NVIDIA host driver and omit the system CUDA Toolkit unless `nvcc` or another Toolkit development tool is explicitly required.

After provisioning Linux or Windows, the `torch-flash` GPU environment can be created from its repository with:

```bash
pixi install -e gpu
pixi run -e gpu python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
```

On Apple Silicon, use the normal environment and PyTorch MPS instead:

```bash
pixi install
pixi run python -c "import torch; print(torch.backends.mps.is_available())"
```

## Ubuntu: usage, profiles and CLI flags

Run from the repository root. The script requires root to install system packages.

Basic run:

```bash
sudo bash scripts/provision-ubuntu.sh
```

Profiles

- `--profile=default`  (default) -> VS Code ON, Docker ON, Pixi ON
- `--profile=minimal`  -> VS Code ON, Docker OFF, Pixi ON
- `--profile=gpu`      -> VS Code ON, Docker ON, Pixi ON, NVIDIA driver ON, CUDA Toolkit ON

CLI flags (override profile defaults)

- `--install-vscode=true|false`
- `--install-docker=true|false`
- `--install-cuda=true|false`
- `--install-driver=true|false`
- `--cuda-toolkit-pkg=cuda-toolkit` (or an available version such as `cuda-toolkit-13-3`)
- `--nvidia-driver-pkg=nvidia-open` (use `cuda-drivers` for proprietary kernel modules)
- `--install-python=true|false`
- `--install-pixi=true|false`

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

- PyTorch GPU workstation: install the driver but leave CUDA runtime selection to Pixi:

```bash
sudo bash scripts/provision-ubuntu.sh \
  --profile=gpu \
  --install-docker=false \
  --install-cuda=false
```

- Strict verification (optional):

```bash
sudo env VERIFY_STRICT=true bash scripts/provision-ubuntu.sh --profile=minimal
```

What the script does (high level)

- Detects the real (non-root) user who invoked sudo so Miniconda installs into their home.
- Adds/normalizes vendor apt repositories for Docker, Microsoft Code, and NVIDIA.
- Installs base packages and tooling via apt.
- Installs Pixi for the invoking non-root user.
- Optionally installs the NVIDIA driver and CUDA Toolkit as independent choices.
- Installs Miniconda into the invoking user's home and runs `conda init` for bash and zsh.

Notes & gotchas

- Must run as root (sudo). The script exits early if not run as root.
- The script bundles logic to detect and resolve conflicting VS Code apt repo entries before running `apt update`.
- Miniconda installer auto-selects x86_64/arm64.
- Docker: after install, log out/in or run `newgrp docker` to use Docker without sudo. On WSL, the script skips engine install and recommends Docker Desktop.
- NVIDIA packages: the script derives the repository from the Ubuntu release and architecture. A pinned Toolkit package must exist in that repository; the unversioned `cuda-toolkit` default tracks the latest supported release.
- CUDA driver: driver installation is for bare-metal Ubuntu only. On WSL2, use the Windows NVIDIA driver. Reboot after installing or changing the bare-metal driver.
- Pixi: installed under `~/.pixi`; open a new terminal if it is not immediately on `PATH`.

## macOS: usage, profiles and CLI flags

Run from the repository root on a macOS machine. This script is intended to be run as a normal user (not sudo). It installs Homebrew, user-scoped casks, Miniforge into your home by default, and optionally system Python and LLVM/libomp.

Basic run:

```bash
bash scripts/provision-macos.sh
```

Profiles

- `--profile=default`  (default) -> VS Code ON, Docker ON, Pixi ON
- `--profile=minimal`  -> VS Code ON, Docker OFF, Pixi ON
- `--profile=gpu`      -> VS Code ON, Docker ON, Pixi ON (CUDA unsupported on macOS; kept for parity)

CLI flags (override profile defaults)

- `--install-vscode=true|false`
- `--install-docker=true|false`
- `--install-iterm2=true|false`
- `--install-rosetta=true|false`  # Apple Silicon only
- `--install-miniforge=true|false`
- `--miniforge-prefix=/path/to/miniforge3`  # default: $HOME/miniforge3
- `--install-llvm=true|false`
- `--install-python=true|false`
- `--install-pixi=true|false`

What the script does (high level)

- Installs Homebrew if missing and wires it into your shell startup files.
- Installs dev tools via Homebrew (git, git-lfs, cmake, ninja, pkg-config, optional llvm/libomp, optional Python).
- Installs casks: VS Code, iTerm2, Docker Desktop (if enabled).
- Installs Miniforge into `--miniforge-prefix`, sets conda-forge (strict), runs `conda init` for bash and zsh.
- Installs Pixi through Homebrew.
- Optionally installs Rosetta 2 on Apple Silicon when requested.

Notes & gotchas

- Run as a normal user; Homebrew prefers user context.
- Do not use `sudo` to launch the script; it now exits early with a clear error because Homebrew does not support root execution.
- After installing Docker Desktop, launch the app once to finish setup and grant permissions.
- If Rosetta is enabled, you may be prompted for your password.
- Open a NEW terminal to get `conda` on PATH, or run `source "$MINIFORGE_PREFIX/etc/profile.d/conda.sh"` then `conda activate`.
- For Python venvs with Homebrew Python: `python3 -m venv .venv && source .venv/bin/activate`.
- CUDA is not supported on current macOS. For PyTorch on Apple Silicon, use MPS (`torch.device("mps")`).

## Windows: usage and parameters

Run from an elevated PowerShell (Admin). The script exposes a `param()` block so you can pass named parameters on the command line.

Basic run (default profile):

```powershell
# from repo root in elevated PowerShell
Set-ExecutionPolicy Bypass -Scope Process -Force
./scripts/provision-win.ps1
```

Profiles (use `-Profile <name>`) and parameters

- `-Profile default`  -> default toggles as declared in the script, including Pixi
- `-Profile minimal`  -> skips Docker but keeps Pixi enabled
- `-Profile gpu`      -> enables CUDA + NVIDIA driver and keeps Pixi enabled

Parameters (examples)

- `-InstallVSCode:$true/$false`
- `-InstallDocker:$true/$false`
- `-InstallWindowsTerminal:$true/$false`
- `-InstallCmder:$true/$false`
- `-InstallPixi:$true/$false`
- `-InstallCUDA:$true/$false`
- `-InstallNvidiaDriver:$true/$false`
- Version pins (strings): `-CudaToolkitVersion`, `-NvidiaDriverVersion`, `-GitVersion`, `-VSCodeVersion`, `-CMakeVersion`, `-NinjaVersion`, `-VSBuildToolsVersion`, `-MinicondaVersion`, `-WindowsTerminalVersion`, `-CmderVersion`

Example: GPU profile but skip Docker and pin CUDA version

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
./scripts/provision-win.ps1 -Profile gpu -InstallDocker:$false
```

PyTorch GPU workstation with driver only:

```powershell
./scripts/provision-win.ps1 -Profile gpu -InstallDocker:$false -InstallCUDA:$false
```

What the script does (high level)

- Installs Chocolatey if missing, then uses it to install packages. Visual Studio Build Tools are installed with package parameters to include MSVC/MSBuild components.
- Installs system Python first (optional), then installs Miniconda using the official latest installer by default (or Chocolatey if configured), and runs `conda init` for PowerShell and cmd.
- Installs Pixi for the current user using the official installer.
- Treats the NVIDIA driver and CUDA Toolkit as independent options.
- Ensures ExecutionPolicy for the CurrentUser is set so PowerShell profiles load (required for conda init to be effective).

Notes

- Must run in an elevated PowerShell. The script will throw if not elevated.
- If Docker Desktop is installed and your account was added to `docker-users`, sign out/in.
- If NVIDIA driver is installed, reboot is recommended.
- The script supports parameters for Miniconda installation: direct official installer by default (`-MinicondaUseDirectInstaller`), install directory, forced reinstall, and conda self-update.

## Verification

After running either script, open a new shell and verify the main tools are available:

Ubuntu (new terminal):

```bash
git --version
pixi --version
code --version        # if VS Code enabled
docker --version      # if Docker enabled
conda --version
python -V
nvidia-smi            # if NVIDIA driver/CUDA enabled
nvcc --version        # if CUDA installed
```

macOS (new terminal):

```bash
git --version
pixi --version
code --version        # if VS Code enabled
docker --version      # if Docker Desktop enabled
conda --version
python -V
# nvcc not expected on macOS; CUDA is unsupported
```

Windows (open a new elevated PowerShell or normal PowerShell after admin tasks complete):

```powershell
git --version
pixi --version
code --version        # if VS Code enabled
docker --version      # if Docker Desktop enabled
conda --version
python -V
nvidia-smi            # if NVIDIA driver/CUDA enabled
nvcc --version        # if CUDA installed
```

## Troubleshooting

- Run as admin/root: Ubuntu requires `sudo`; Windows requires an elevated PowerShell.
- New shells required: Open a new terminal to pick up `conda init` changes and updated PATH.
- Docker group (Ubuntu): If `docker` commands require sudo after install, log out/in or run `newgrp docker`.
- VS Code apt repo conflicts: the Ubuntu script tries to detect and normalize duplicate Microsoft Code repo entries before `apt update` to avoid signed-by problems.
- CUDA package not found on Ubuntu: prefer `--cuda-toolkit-pkg=cuda-toolkit`, or inspect available pins with `apt-cache search '^cuda-toolkit-[0-9]'` after the NVIDIA repository is configured.
- PyTorch reports no GPU: run `nvidia-smi`, then check `torch.cuda.is_available()` and `torch.version.cuda` inside the same Pixi/Conda environment. The CUDA version printed by `nvidia-smi` is the driver's maximum supported API, not necessarily a system Toolkit installation.
- Pixi not on `PATH`: open a new terminal. On Ubuntu it is installed under `~/.pixi/bin`; on macOS Homebrew provides it; on Windows the official installer normally uses `%LOCALAPPDATA%\pixi\bin` and updates the user `PATH`.
- Corporate proxies: Configure system proxy and git proxy settings before running the scripts.

## Uninstall/rollback (brief)

These scripts use the system package managers (apt/Chocolatey) and vendor installers. Use those package managers to remove installed packages. To remove Miniconda, delete the installation path (e.g., `~/miniconda3`) and remove the `conda init` lines from the user's shell profile.

## License

See `LICENSE` in this repository.

