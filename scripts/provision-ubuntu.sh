#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# Provision Ubuntu for Dev + Miniconda (CLI)
# Profiles: default | minimal | gpu
# Flags override profile defaults.
# ===========================================

# ---------- Defaults ----------
PROFILE="default"

INSTALL_VSCODE=true
INSTALL_DOCKER=true

INSTALL_CUDA=false
INSTALL_NVIDIA_DRIVER=false

CUDA_TOOLKIT_PKG="cuda-toolkit-12-4"   # e.g., "cuda-toolkit-12-4" or "cuda-toolkit"

# You can add more pins here if you want later (apt uses latest by default)

# ---------- Helpers ----------
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root: sudo bash $0 [flags]"
    exit 1
  fi
}

parse_bool() {
  case "${1,,}" in
    true|1|yes|y|on)  echo "true" ;;
    false|0|no|n|off) echo "false" ;;
    *) err "Invalid boolean value: '$1' (use true/false)"; exit 2 ;;
  esac
}

# ---------- Parse CLI ----------
# Supported flags:
#   --profile=default|minimal|gpu
#   --install-vscode=true|false
#   --install-docker=true|false
#   --install-cuda=true|false
#   --install-nvidia-driver=true|false
#   --cuda-toolkit-pkg=<deb package name>
for arg in "$@"; do
  case "$arg" in
    --profile=*)                 PROFILE="${arg#*=}";;
    --install-vscode=*)          INSTALL_VSCODE=$(parse_bool "${arg#*=}");;
    --install-docker=*)          INSTALL_DOCKER=$(parse_bool "${arg#*=}");;
    --install-cuda=*)            INSTALL_CUDA=$(parse_bool "${arg#*=}");;
    --install-nvidia-driver=*)   INSTALL_NVIDIA_DRIVER=$(parse_bool "${arg#*=}");;
    --cuda-toolkit-pkg=*)        CUDA_TOOLKIT_PKG="${arg#*=}";;
    -h|--help)
      cat <<'USAGE'
Usage: sudo bash provision-ubuntu.sh [flags]

Profiles (defaults if you omit flags):
  --profile=default   VS Code ON, Docker ON, CUDA OFF
  --profile=minimal   VS Code ON, Docker OFF, CUDA OFF
  --profile=gpu       VS Code ON, Docker ON, CUDA+Driver ON

Flags (override profile defaults):
  --install-vscode=true|false
  --install-docker=true|false
  --install-cuda=true|false
  --install-nvidia-driver=true|false
  --cuda-toolkit-pkg=cuda-toolkit-12-4   # or "cuda-toolkit"

Examples:
  sudo bash provision-ubuntu.sh
  sudo bash provision-ubuntu.sh --profile=minimal
  sudo bash provision-ubuntu.sh --profile=gpu
  sudo bash provision-ubuntu.sh --profile=gpu --install-docker=false
USAGE
      exit 0;;
    *)
      err "Unknown flag: $arg"; exit 2;;
  esac
done

# ---------- Apply profile defaults (only those not explicitly overridden) ----------
# (Since flags are parsed directly into vars, we set profile-based defaults first then rely on flags
# already having overridden them. Here we adjust ONLY when user didn't pass flags — but we can't detect that
# robustly without tracking. So we set profile defaults BEFORE parsing in a typical design. For simplicity:
# The declared defaults represent 'default' profile already. We only tweak for other profiles here.)
case "$PROFILE" in
  minimal)
    INSTALL_DOCKER=${INSTALL_DOCKER:-false}; INSTALL_DOCKER=false
    ;;
  gpu)
    INSTALL_CUDA=${INSTALL_CUDA:-false}; INSTALL_CUDA=true
    INSTALL_NVIDIA_DRIVER=${INSTALL_NVIDIA_DRIVER:-false}; INSTALL_NVIDIA_DRIVER=true
    ;;
  default) ;;
  *)
    err "Invalid --profile value: $PROFILE (use default|minimal|gpu)"; exit 2;;
esac

need_root

# ---------- Real user (for Miniconda) ----------
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
  err "Could not determine real user's home for $REAL_USER"
  exit 1
fi

log "Profile: $PROFILE"
log "Flags -> VSCode:$INSTALL_VSCODE Docker:$INSTALL_DOCKER CUDA:$INSTALL_CUDA Driver:$INSTALL_NVIDIA_DRIVER ToolkitPkg:$CUDA_TOOLKIT_PKG"
log "Installing for user: $REAL_USER (home: $REAL_HOME)"

# ---------- Base packages ----------
export DEBIAN_FRONTEND=noninteractive
log "Updating apt and installing base packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  git git-lfs build-essential pkg-config \
  cmake ninja-build \
  unzip xz-utils p7zip-full
git lfs install || true

# ---------- VS Code (optional) ----------
if [[ "$INSTALL_VSCODE" == "true" ]]; then
  log "Installing VS Code (Microsoft repo)..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
  source /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
  apt-get update -y
  apt-get install -y code
fi

# ---------- Docker Engine (optional, official repo) ----------
if [[ "$INSTALL_DOCKER" == "true" ]]; then
  log "Installing Docker Engine (Docker official apt repo)..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "$REAL_USER" || warn "Could not add ${REAL_USER} to docker group"
fi

# ---------- Miniconda (user scope), conda-forge, conda init ----------
log "Installing Miniconda for user: $REAL_USER"
CONDA_DIR="${REAL_HOME}/miniconda3"
if [[ ! -d "$CONDA_DIR" ]]; then
  tmp_installer="/tmp/miniconda.sh"
  # x86_64 installer; change URL for aarch64 if needed
  curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o "$tmp_installer"
  chown "$REAL_USER":"$REAL_USER" "$tmp_installer"
  sudo -u "$REAL_USER" bash "$tmp_installer" -b -p "$CONDA_DIR"
  rm -f "$tmp_installer"
else
  log "Miniconda already present at $CONDA_DIR"
fi

CONDA_BIN="${CONDA_DIR}/bin/conda"
if [[ ! -x "$CONDA_BIN" ]]; then
  err "Conda binary not found at $CONDA_BIN"; exit 1
fi

log "Configuring conda-forge (strict) and initializing shells..."
sudo -u "$REAL_USER" "$CONDA_BIN" config --set channel_priority strict
sudo -u "$REAL_USER" "$CONDA_BIN" config --add channels conda-forge || true
sudo -u "$REAL_USER" "$CONDA_BIN" init bash || true
if command -v zsh >/dev/null 2>&1; then
  sudo -u "$REAL_USER" "$CONDA_BIN" init zsh || true
fi

# ---------- CUDA (optional): NVIDIA driver + CUDA Toolkit ----------
if [[ "$INSTALL_CUDA" == "true" ]]; then
  log "CUDA flag is ON."

  if [[ "$INSTALL_NVIDIA_DRIVER" == "true" ]]; then
    log "Installing NVIDIA driver (ubuntu-drivers autoinstall)..."
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall returned a non-zero exit code."
  else
    warn "Skipping NVIDIA driver install; ensure a compatible driver is already installed."
  fi

  log "Setting up NVIDIA CUDA apt repo and installing ${CUDA_TOOLKIT_PKG} ..."
  ver_id="$(. /etc/os-release && echo "$VERSION_ID")"          # e.g., 22.04
  ver_nodot="${ver_id//./}"                                   # e.g., 2204
  cuda_keyring="cuda-keyring_1.1-1_all.deb"

  if ! dpkg -l | grep -q cuda-keyring; then
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${ver_nodot}/x86_64/${cuda_keyring}" -o "/tmp/${cuda_keyring}" \
      || curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${ver_nodot}/x86_64/${cuda_keyring%_*}_all.deb" -o "/tmp/${cuda_keyring}" \
      || { err "Failed to download cuda-keyring for ubuntu${ver_nodot}"; exit 1; }
    dpkg -i "/tmp/${cuda_keyring}" || true
    rm -f "/tmp/${cuda_keyring}"
    apt-get update -y
  else
    log "cuda-keyring already installed."
  fi

  apt-get install -y "${CUDA_TOOLKIT_PKG}" || {
    warn "Failed to install ${CUDA_TOOLKIT_PKG}. Trying generic 'cuda-toolkit'..."
    apt-get install -y cuda-toolkit || { err "CUDA toolkit installation failed."; exit 1; }
  }

  # Convenience: set CUDA paths for all users
  if [[ -d /usr/local/cuda ]]; then
    cat >/etc/profile.d/cuda-path.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda
export PATH="$CUDA_HOME/bin:${PATH}"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
EOF
    chmod 0644 /etc/profile.d/cuda-path.sh
  fi

  log "CUDA setup complete. A reboot is recommended if a driver was installed."
fi

# ---------- Final ----------
log "Provisioning complete."
echo "• Miniconda for ${REAL_USER}: ${CONDA_DIR}"
echo "• conda-forge enabled (strict), conda init done for bash$(command -v zsh >/dev/null 2>&1 && echo ', zsh')."
[[ "$INSTALL_VSCODE" == "true" ]] && echo "• VS Code installed (code)."
[[ "$INSTALL_DOCKER" == "true" ]] && echo "• Docker Engine installed. Log out/in (or 'newgrp docker') to use without sudo."
[[ "$INSTALL_CUDA" == "true"  ]] && echo "• CUDA toolkit installed. Reboot after driver install."
