#!/usr/bin/env bash
set -euo pipefail

# -------------------- CONFIG --------------------
INSTALL_VSCODE=true
INSTALL_DOCKER=true

INSTALL_CUDA=false           # true => install CUDA toolkit (and driver if enabled below)
INSTALL_NVIDIA_DRIVER=false  # true => run ubuntu-drivers autoinstall

# Optional pins (leave empty for latest)
CUDA_TOOLKIT_PKG="cuda-toolkit-12-4"  # e.g., cuda-toolkit-12-4 or just "cuda-toolkit"
# ------------------------------------------------

# Detect the invoking user (so Miniconda lands in the right $HOME)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use: sudo bash $0)"; exit 1
fi

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

# --- Base packages & updates ---
log "Updating apt and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  git git-lfs ca-certificates curl wget gnupg lsb-release \
  build-essential pkg-config \
  cmake ninja-build \
  unzip xz-utils p7zip-full \
  software-properties-common

git lfs install || true

# --- VS Code (optional) ---
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

# --- Docker Engine (optional, official repo) ---
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

# --- Miniconda (user scope), conda-forge, conda init ---
log "Installing Miniconda for user: $REAL_USER"
CONDA_DIR="${REAL_HOME}/miniconda3"
if [[ ! -d "$CONDA_DIR" ]]; then
  tmp_installer="/tmp/miniconda.sh"
  # Use latest Miniconda installer (x86_64) – change URL if you’re on a different arch
  curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o "$tmp_installer"
  chown "$REAL_USER":"$REAL_USER" "$tmp_installer"
  sudo -u "$REAL_USER" bash "$tmp_installer" -b -p "$CONDA_DIR"
  rm -f "$tmp_installer"
else
  log "Miniconda already present at $CONDA_DIR"
fi

# Conda config and init (bash & zsh) for the real user
CONDA_BIN="${CONDA_DIR}/bin/conda"
if [[ ! -x "$CONDA_BIN" ]]; then
  err "Conda binary not found at $CONDA_BIN"; exit 1
fi

log "Configuring conda-forge (strict) and initializing shells..."
sudo -u "$REAL_USER" "$CONDA_BIN" config --set channel_priority strict
sudo -u "$REAL_USER" "$CONDA_BIN" config --add channels conda-forge || true

# init for bash
sudo -u "$REAL_USER" "$CONDA_BIN" init bash || true
# init for zsh (only if zsh exists)
if command -v zsh >/dev/null 2>&1; then
  sudo -u "$REAL_USER" "$CONDA_BIN" init zsh || true
fi

# --- CUDA (optional): NVIDIA driver + CUDA Toolkit via NVIDIA repo ---
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
  # Determine correct repo path (e.g., ubuntu2204 or ubuntu2404)
  ver_id="$(. /etc/os-release && echo "$VERSION_ID")"          # e.g., 22.04
  ver_nodot="${ver_id//./}"                                   # e.g., 2204
  cuda_keyring="cuda-keyring_1.1-1_all.deb"

  # Add NVIDIA CUDA repo via cuda-keyring (idempotent)
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

  # Install CUDA toolkit package
  apt-get install -y "${CUDA_TOOLKIT_PKG}" || {
    warn "Failed to install ${CUDA_TOOLKIT_PKG}. Trying generic 'cuda-toolkit'..."
    apt-get install -y cuda-toolkit || {
      err "CUDA toolkit installation failed."; exit 1;
    }
  }

  # Convenience: set CUDA paths in /etc/profile.d for all users
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

# --- Final messages ---
log "Provisioning complete."
echo "• Miniconda for ${REAL_USER}: ${CONDA_DIR}"
echo "• conda-forge enabled (strict), conda init done for bash$(command -v zsh >/dev/null 2>&1 && echo ', zsh')."
[[ "$INSTALL_VSCODE" == "true" ]] && echo "• VS Code installed (code)."
[[ "$INSTALL_DOCKER" == "true" ]] && echo "• Docker Engine installed. Log out/in (or newgrp docker) to use without sudo."
[[ "$INSTALL_CUDA" == "true" ]]  && echo "• CUDA toolkit installed. Reboot after driver install."
