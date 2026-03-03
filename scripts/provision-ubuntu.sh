#!/usr/bin/env bash
# Provision Ubuntu (incl. WSL) for Dev + Python + Miniconda (CLI flags + profiles)
# Profiles: default | minimal | gpu
# Flags override profile defaults.

set -Eeuo pipefail

# -------- pretty logs --------
log()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

# ---- traps: show failing line/cmd; show SUCCESS on exit 0 ----
on_err()  { ec=$?; printf "\033[1;31m[FAIL]\033[0m line=%s cmd=%s exit=%s\n" "$1" "$2" "$ec"; }
on_exit() { ec=$?; if [ "$ec" -eq 0 ]; then printf "\033[1;32m[SUCCESS]\033[0m Provisioning completed.\n"; fi; }
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap 'on_exit' EXIT

# -------- require root (re-exec with sudo) --------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# -------- defaults --------
PROFILE="default"
INSTALL_VSCODE=true
INSTALL_DOCKER=true
INSTALL_CUDA=false
INSTALL_DRIVER=false           # NVIDIA driver (bare metal only; ignored in WSL)
CUDA_TOOLKIT_PKG="cuda-toolkit-12-4"

INSTALL_PYTHON=true            # system python3 + venv + pip

# ------- parse flags (bash 4/5 compatible; no ${var,,}) -------
parse_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on)  echo true ;;
    false|0|no|n|off) echo false ;;
    *) err "Invalid boolean for flag: $1 (use true/false)"; exit 2 ;;
  esac
}

for arg in "$@"; do
  case "$arg" in
    --profile=*)             PROFILE="${arg#*=}";;
    --install-vscode=*)      INSTALL_VSCODE=$(parse_bool "${arg#*=}");;
    --install-docker=*)      INSTALL_DOCKER=$(parse_bool "${arg#*=}");;
    --install-cuda=*)        INSTALL_CUDA=$(parse_bool "${arg#*=}");;
    --install-driver=*)      INSTALL_DRIVER=$(parse_bool "${arg#*=}");;
    --cuda-toolkit-pkg=*)    CUDA_TOOLKIT_PKG="${arg#*=}";;
    --install-python=*)      INSTALL_PYTHON=$(parse_bool "${arg#*=}");;
    -h|--help)
      cat <<'USAGE'
Usage: sudo -E bash provision-ubuntu.sh [flags]

Profiles (set sensible defaults; flags override):
  --profile=default    VS Code ON, Docker ON
  --profile=minimal    VS Code ON, Docker OFF
  --profile=gpu        VS Code ON, Docker ON, CUDA toolkit ON (driver optional)

Flags:
  --install-vscode=true|false
  --install-docker=true|false
  --install-cuda=true|false
  --install-driver=true|false
  --cuda-toolkit-pkg=cuda-toolkit-12-4
  --install-python=true|false     # python3 + venv + pip (+ python-is-python3)

Tips:
  VERIFY_STRICT=true sudo -E bash provision-ubuntu.sh ...   # make verification failures exit non-zero
USAGE
      exit 0;;
    *) err "Unknown flag: $arg"; exit 2;;
  esac
done

# -------- apply profile defaults --------
case "$PROFILE" in
  minimal)
    INSTALL_DOCKER=false
    ;;
  gpu)
    INSTALL_CUDA=true
    ;;
  default) ;;
  *) err "Invalid --profile: $PROFILE (use default|minimal|gpu)"; exit 2;;
esac

# -------- detect env --------
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=true; fi

# -------- target user (for user-level conda) --------
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TARGET_HOME="$(eval echo ~"$TARGET_USER")"

log "Profile: $PROFILE"
log "Flags -> VSCode:$INSTALL_VSCODE Docker:$INSTALL_DOCKER CUDA:$INSTALL_CUDA Driver:$INSTALL_DRIVER ToolkitPkg:$CUDA_TOOLKIT_PKG Python:$INSTALL_PYTHON"
log "Installing for user: $TARGET_USER (home: $TARGET_HOME)"

# -------- VS Code repo: make it canonical & conflict-free --------
setup_code_repo() {
  install -d -m 0755 /etc/apt/keyrings
  install -d -m 0755 /usr/share/keyrings

  # Single canonical keyring path for VS Code
  local keyring="/usr/share/keyrings/microsoft.gpg"
  if [ ! -f "$keyring" ]; then
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >"$keyring"
    chmod 0644 "$keyring"
  fi

  # 1) Comment Code repo lines in the main sources.list
  if grep -qs 'packages.microsoft.com/repos/code' /etc/apt/sources.list 2>/dev/null; then
    sed -i 's|^\s*deb .*packages.microsoft.com/repos/code.*|# commented by provisioner: conflicting CODE repo|g' /etc/apt/sources.list
  fi

  # 2) Disable any *.sources files referencing the Code repo
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if grep -qs 'packages.microsoft.com/repos/code' "$f"; then
      mv -f "$f" "${f}.disabled"
      log "Disabled conflicting sources file: ${f} -> ${f}.disabled"
    fi
  done

  # 3) Comment conflicting entries in other .list files
  for f in /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    [ "$f" = "/etc/apt/sources.list.d/vscode.list" ] && continue
    if grep -qs 'packages.microsoft.com/repos/code' "$f"; then
      sed -i 's|^\s*deb .*packages.microsoft.com/repos/code.*|# commented by provisioner: conflicting CODE repo|g' "$f"
      log "Commented conflicting entry in: $f"
    fi
  done

  # 4) Write the single canonical VS Code repo file
  cat >/etc/apt/sources.list.d/vscode.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://packages.microsoft.com/repos/code stable main
EOF

  log "Set VS Code repo at /etc/apt/sources.list.d/vscode.list (signed-by=$keyring)"
}

# -------- Docker repo (skip in WSL unless you really want engine inside WSL) --------
setup_docker_repo() {
  if $IS_WSL; then
    warn "Detected WSL2. Skipping Docker Engine repo; prefer Docker Desktop on Windows."
    return 0
  fi
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor >/etc/apt/keyrings/docker.gpg
    chmod 0644 /etc/apt/keyrings/docker.gpg
  fi
  codename="$(. /etc/os-release && echo "$UBUNTU_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
    >/etc/apt/sources.list.d/docker.list
}

# -------- base packages + git-lfs init --------
setup_code_repo
log "Updating apt and installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  git git-lfs build-essential flex gfortran bison pkg-config cmake ninja-build \
  unzip xz-utils p7zip-full

# -------- Scientific / HPC libraries --------
log "Installing scientific/HPC libraries..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libopenblas-dev libopenmpi-dev \
  libfftw3-dev libfftw3-mpi-dev \
  libhwloc-dev libhdf5-mpi-dev \
  libmumps-ptscotch-dev libmetis-dev \
  libnetcdf-dev libpnetcdf-dev \
  libptscotch-dev libscalapack-openmpi-dev \
  libsuitesparse-dev libsuperlu-dev libsuperlu-dist-dev
sudo -u "$TARGET_USER" git lfs install || true
log "Updated git hooks."
log "Git LFS initialized."

# -------- VS Code --------
if [ "$INSTALL_VSCODE" = "true" ]; then
  log "Installing VS Code (Microsoft repo)..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y code
fi

# -------- System Python (python3 + venv + pip + 'python' shim) --------
if [ "$INSTALL_PYTHON" = "true" ]; then
  log "Installing system Python (python3, venv, pip)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-dev python3-venv python3-pip
  DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3 || true
fi

# -------- Docker Engine (skip in WSL by default) --------
if [ "$INSTALL_DOCKER" = "true" ]; then
  setup_docker_repo
  if ! $IS_WSL; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker || true
    usermod -aG docker "$TARGET_USER" || true
  else
    warn "Docker install skipped in WSL. Use Docker Desktop on Windows with WSL integration."
  fi
fi

# -------- CUDA Toolkit (driver optional; in WSL2 use Windows driver + Linux toolkit) --------
if [ "$INSTALL_CUDA" = "true" ]; then
  if [ "$INSTALL_DRIVER" = "true" ]; then
    warn "Driver install is for bare-metal Ubuntu only. On WSL2, the NVIDIA driver must be on Windows."
  fi
  log "Installing CUDA toolkit package: $CUDA_TOOLKIT_PKG"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$CUDA_TOOLKIT_PKG"
fi

# -------- Miniconda (user-level) --------
install_miniconda_user() {
  local u="$1" h="$2"
  local prefix="$h/miniconda3"

  # Detect an existing conda installation (any common prefix) before downloading
  local existing_conda=""
  for _p in "$prefix/bin/conda" \
            "$h/miniforge3/bin/conda" \
            "$h/anaconda3/bin/conda" \
            "/opt/conda/bin/conda"; do
    [ -x "$_p" ] && { existing_conda="$_p"; break; }
  done

  if [ -n "$existing_conda" ]; then
    log "Conda already found at $existing_conda — skipping Miniconda download/install."
  else
    log "Installing Miniconda for user: $u"
    if [ ! -d "$prefix" ]; then
      local url arch installer
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) installer="Miniconda3-latest-Linux-x86_64.sh" ;;
        aarch64|arm64) installer="Miniconda3-latest-Linux-aarch64.sh" ;;
        *) err "Unsupported arch for Miniconda: $arch"; return 1 ;;
      esac
      url="https://repo.anaconda.com/miniconda/$installer"
      tmp="/tmp/$installer"
      curl -fsSL "$url" -o "$tmp"
      chown "$u":"$u" "$tmp"
      sudo -H -u "$u" bash "$tmp" -b -p "$prefix"
      rm -f "$tmp"
    else
      log "Miniconda already present at $prefix"
    fi
  fi

  local conda_bin="${existing_conda:-$prefix/bin/conda}"
  if [ ! -x "$conda_bin" ]; then
    err "Conda binary not found at $conda_bin"
    return 1
  fi

  log "Configuring conda-forge (strict) and initializing shells..."
  sudo -H -u "$u" "$conda_bin" config --set channel_priority strict
  sudo -H -u "$u" "$conda_bin" config --add channels conda-forge || true
  sudo -H -u "$u" "$conda_bin" init bash || true
  sudo -H -u "$u" "$conda_bin" init zsh  || true
}

install_miniconda_user "$TARGET_USER" "$TARGET_HOME"

# -------- pixi (user-level) --------
log "Installing pixi for user: $TARGET_USER"
sudo -H -u "$TARGET_USER" bash -c 'curl -fsSL https://pixi.sh/install.sh | bash' || \
  warn "pixi install returned non-zero; it may already be present."

# =========================
# Verification (non-strict)
# =========================
VERIFY_STRICT=${VERIFY_STRICT:-false}  # set true to make failures exit non-zero

ok=0
pass(){ printf "  \033[1;32m[OK]\033[0m   %s\n" "$1"; }
warnv(){ printf "  \033[1;33m[WARN]\033[0m %s\n" "$1"; ok=1; }
fail(){ printf "  \033[1;31m[FAIL]\033[0m %s\n" "$1"; ok=1; }

check_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then pass "$name present"
  else warnv "$name not found on PATH"
  fi
}

echo
echo "[INFO] Verifying installation…"

check_cmd git
check_cmd cmake
check_cmd ninja

# pixi installs into ~/.pixi/bin; check there if not yet on PATH
if command -v pixi >/dev/null 2>&1; then
  pass "pixi present ($(pixi --version 2>/dev/null))"
elif [ -x "$TARGET_HOME/.pixi/bin/pixi" ]; then
  pass "pixi present at $TARGET_HOME/.pixi/bin/pixi (open a NEW shell to get it on PATH)"
else
  warnv "pixi not found"
fi

if [ "$INSTALL_PYTHON" = "true" ]; then
  if command -v python3 >/dev/null 2>&1; then
    pass "python3 present ($(python3 --version 2>/dev/null))"
    if python3 -c 'import venv' 2>/dev/null; then
      pass "python3 venv module available"
    else
      fail "python3 venv module missing"
    fi
  else
    fail "python3 not found"
  fi
fi

if [ "$INSTALL_VSCODE" = "true" ]; then
  if command -v code >/dev/null 2>&1; then
    pass "code present ($(code --version | head -n1))"
  else
    warnv "code not found on PATH"
  fi
fi

# Conda check (robust to PATH)
CONDA_BIN=""
for p in "$TARGET_HOME/miniconda3/bin/conda" "$TARGET_HOME/miniforge3/bin/conda" "/opt/conda/bin/conda"; do
  [ -x "$p" ] && { CONDA_BIN="$p"; break; }
done
command -v conda >/dev/null 2>&1 && CONDA_BIN="${CONDA_BIN:-$(command -v conda)}"

if [ -n "$CONDA_BIN" ] && [ -x "$CONDA_BIN" ]; then
  pass "conda present ($("$CONDA_BIN" --version 2>/dev/null))"
else
  warnv "conda not found (open a NEW shell or verify Miniconda path)"
fi

if [ "$INSTALL_DOCKER" = "true" ]; then
  if command -v docker >/dev/null 2>&1; then
    pass "docker present ($(docker --version 2>/dev/null))"
  else
    $IS_WSL && warnv "docker not on PATH in WSL (expected if using Docker Desktop on Windows)"
    $IS_WSL || warnv "docker not found on PATH"
  fi
fi

if [ "$ok" -ne 0 ]; then
  printf "\n\033[1;33m[VERIFY]\033[0m Some items are missing or not yet on PATH.\n"
  [ "$VERIFY_STRICT" = "true" ] && exit 1
else
  printf "\n\033[1;32m[VERIFY]\033[0m All expected tools detected.\n"
fi

# -------- summary --------
echo
log "Provisioning complete."
echo "• Miniconda for $TARGET_USER: $TARGET_HOME/miniconda3"
echo "• conda-forge enabled (strict), conda init done for bash, zsh."
echo "• pixi installed for $TARGET_USER: $TARGET_HOME/.pixi (open a NEW shell or add ~/.pixi/bin to PATH)."
[ "$INSTALL_PYTHON" = "true" ] && echo "• System Python installed: python3 + venv + pip (use: 'python3 -m venv .venv')."
[ "$INSTALL_VSCODE" = "true" ] && echo "• VS Code installed (code)."
[ "$INSTALL_DOCKER" = "true" ] && $IS_WSL && echo "• Docker: use Docker Desktop w/ WSL integration."
