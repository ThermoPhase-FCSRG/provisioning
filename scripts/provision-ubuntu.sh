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
  exec sudo bash "$0" "$@"
fi

# -------- defaults --------
PROFILE="default"
INSTALL_VSCODE=true
INSTALL_DOCKER=true
INSTALL_CUDA=false
INSTALL_DRIVER=false           # NVIDIA driver (bare metal only; ignored in WSL)
CUDA_TOOLKIT_PKG="cuda-toolkit"
NVIDIA_DRIVER_PKG="nvidia-open"

INSTALL_PYTHON=true            # system python3 + venv + pip
INSTALL_PIXI=true
INSTALL_OH_MY_ZSH=false        # explicit opt-in only; never enabled by a profile
TARGET_USER_OVERRIDE=""
TARGET_HOME_OVERRIDE=""

# CLI overrides are collected separately so profiles are applied first.
CLI_INSTALL_VSCODE=""
CLI_INSTALL_DOCKER=""
CLI_INSTALL_CUDA=""
CLI_INSTALL_DRIVER=""
CLI_CUDA_TOOLKIT_PKG=""
CLI_NVIDIA_DRIVER_PKG=""
CLI_INSTALL_PYTHON=""
CLI_INSTALL_PIXI=""
CLI_INSTALL_OH_MY_ZSH=""

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
    --install-vscode=*)      CLI_INSTALL_VSCODE=$(parse_bool "${arg#*=}");;
    --install-docker=*)      CLI_INSTALL_DOCKER=$(parse_bool "${arg#*=}");;
    --install-cuda=*)        CLI_INSTALL_CUDA=$(parse_bool "${arg#*=}");;
    --install-driver=*)      CLI_INSTALL_DRIVER=$(parse_bool "${arg#*=}");;
    --cuda-toolkit-pkg=*)    CLI_CUDA_TOOLKIT_PKG="${arg#*=}";;
    --nvidia-driver-pkg=*)   CLI_NVIDIA_DRIVER_PKG="${arg#*=}";;
    --install-python=*)      CLI_INSTALL_PYTHON=$(parse_bool "${arg#*=}");;
    --install-pixi=*)        CLI_INSTALL_PIXI=$(parse_bool "${arg#*=}");;
    --install-oh-my-zsh=*)   CLI_INSTALL_OH_MY_ZSH=$(parse_bool "${arg#*=}");;
    --target-user=*)         TARGET_USER_OVERRIDE="${arg#*=}";;
    --target-home=*)         TARGET_HOME_OVERRIDE="${arg#*=}";;
    -h|--help)
      cat <<'USAGE'
Usage: sudo bash provision-ubuntu.sh [flags]

Profiles (set sensible defaults; flags override):
  --profile=default    VS Code ON, Docker ON, Pixi ON
  --profile=minimal    VS Code ON, Docker OFF, Pixi ON
  --profile=gpu        VS Code ON, Docker ON, Pixi ON, NVIDIA driver/toolkit ON
  No profile enables Oh My Zsh; pass --install-oh-my-zsh=true explicitly.

Flags:
  --install-vscode=true|false
  --install-docker=true|false
  --install-cuda=true|false
  --install-driver=true|false
  --cuda-toolkit-pkg=cuda-toolkit
  --nvidia-driver-pkg=nvidia-open
  --install-python=true|false     # python3 + venv + pip (+ python-is-python3)
  --install-pixi=true|false
  --install-oh-my-zsh=true|false # explicit opt-in; installs Powerlevel10k/plugins
  --target-user=USER              # override the invoking non-root user
  --target-home=/absolute/path    # override home resolved through NSS/getent

Tips:
  sudo env VERIFY_STRICT=true bash provision-ubuntu.sh ...  # make verification failures exit non-zero
  Prebuilt PyTorch/Pixi environments normally need only a compatible NVIDIA
  driver; use --profile=gpu --install-cuda=false when no system nvcc is needed.
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
    INSTALL_DRIVER=true
    ;;
  default) ;;
  *) err "Invalid --profile: $PROFILE (use default|minimal|gpu)"; exit 2;;
esac

# Explicit flags override profile defaults.
[ -n "$CLI_INSTALL_VSCODE" ] && INSTALL_VSCODE="$CLI_INSTALL_VSCODE"
[ -n "$CLI_INSTALL_DOCKER" ] && INSTALL_DOCKER="$CLI_INSTALL_DOCKER"
[ -n "$CLI_INSTALL_CUDA" ] && INSTALL_CUDA="$CLI_INSTALL_CUDA"
[ -n "$CLI_INSTALL_DRIVER" ] && INSTALL_DRIVER="$CLI_INSTALL_DRIVER"
[ -n "$CLI_CUDA_TOOLKIT_PKG" ] && CUDA_TOOLKIT_PKG="$CLI_CUDA_TOOLKIT_PKG"
[ -n "$CLI_NVIDIA_DRIVER_PKG" ] && NVIDIA_DRIVER_PKG="$CLI_NVIDIA_DRIVER_PKG"
[ -n "$CLI_INSTALL_PYTHON" ] && INSTALL_PYTHON="$CLI_INSTALL_PYTHON"
[ -n "$CLI_INSTALL_PIXI" ] && INSTALL_PIXI="$CLI_INSTALL_PIXI"
[ -n "$CLI_INSTALL_OH_MY_ZSH" ] && INSTALL_OH_MY_ZSH="$CLI_INSTALL_OH_MY_ZSH"

# -------- detect env --------
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=true; fi

# -------- target user/home for user-level tools --------
TARGET_USER="${TARGET_USER_OVERRIDE:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}"
id "$TARGET_USER" >/dev/null 2>&1 || { err "Unknown target user: $TARGET_USER"; exit 1; }
if [ -n "$TARGET_HOME_OVERRIDE" ]; then
  TARGET_HOME="$TARGET_HOME_OVERRIDE"
else
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi
[ -n "$TARGET_HOME" ] || { err "Could not resolve home directory for user: $TARGET_USER"; exit 1; }
case "$TARGET_HOME" in
  /*) ;;
  *) err "Target home must be an absolute path: $TARGET_HOME"; exit 1 ;;
esac
sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" test -d "$TARGET_HOME" \
  || { err "Target home does not exist, is not mounted, or is inaccessible to $TARGET_USER: $TARGET_HOME"; exit 1; }

log "Profile: $PROFILE"
log "Flags -> VSCode:$INSTALL_VSCODE Docker:$INSTALL_DOCKER CUDA:$INSTALL_CUDA Driver:$INSTALL_DRIVER ToolkitPkg:$CUDA_TOOLKIT_PKG DriverPkg:$NVIDIA_DRIVER_PKG Python:$INSTALL_PYTHON Pixi:$INSTALL_PIXI OhMyZsh:$INSTALL_OH_MY_ZSH"
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

# -------- NVIDIA CUDA/driver repo --------
setup_nvidia_repo() {
  local distro repo_arch keyring_deb

  if $IS_WSL; then
    distro="wsl-ubuntu"
  else
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] || [ -z "${VERSION_ID:-}" ]; then
      err "CUDA repository setup supports Ubuntu only (detected ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})."
      return 1
    fi
    distro="ubuntu$(printf '%s' "$VERSION_ID" | tr -d '.')"
  fi

  case "$(dpkg --print-architecture)" in
    amd64) repo_arch="x86_64" ;;
    arm64)
      if $IS_WSL; then
        err "The NVIDIA WSL repository is not supported on arm64 by this script."
        return 1
      fi
      repo_arch="sbsa"
      ;;
    *)
      err "Unsupported architecture for the NVIDIA repository: $(dpkg --print-architecture)"
      return 1
      ;;
  esac

  keyring_deb="$(mktemp /tmp/cuda-keyring.XXXXXX.deb)"
  log "Configuring NVIDIA repository for $distro/$repo_arch..."
  if ! curl -fsSL \
      "https://developer.download.nvidia.com/compute/cuda/repos/$distro/$repo_arch/cuda-keyring_1.1-1_all.deb" \
      -o "$keyring_deb"; then
    rm -f "$keyring_deb"
    err "No NVIDIA repository found for $distro/$repo_arch. Check NVIDIA's supported distributions."
    return 1
  fi
  dpkg -i "$keyring_deb"
  rm -f "$keyring_deb"
  apt-get update
}

# -------- base packages + git-lfs init --------
if [ "$INSTALL_VSCODE" = "true" ]; then
  setup_code_repo
fi
log "Updating apt and installing base packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  git git-lfs build-essential pkg-config cmake ninja-build unzip xz-utils p7zip-full
sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" git lfs install || true
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip
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

# -------- NVIDIA driver and CUDA Toolkit --------
# The driver is a host concern. The Toolkit is optional because prebuilt
# PyTorch/Conda/Pixi packages normally supply their own CUDA user-space runtime.
if [ "$INSTALL_CUDA" = "true" ] || { [ "$INSTALL_DRIVER" = "true" ] && ! $IS_WSL; }; then
  setup_nvidia_repo
fi

REBOOT_REQUIRED=false
if [ "$INSTALL_DRIVER" = "true" ]; then
  if $IS_WSL; then
    warn "Skipping Linux NVIDIA driver in WSL2; install/update the NVIDIA driver on Windows."
  else
    log "Installing NVIDIA driver package: $NVIDIA_DRIVER_PKG"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      "linux-headers-$(uname -r)" "$NVIDIA_DRIVER_PKG"
    REBOOT_REQUIRED=true
  fi
fi

if [ "$INSTALL_CUDA" = "true" ]; then
  if ! apt-cache show "$CUDA_TOOLKIT_PKG" >/dev/null 2>&1; then
    err "CUDA toolkit package '$CUDA_TOOLKIT_PKG' is unavailable for this Ubuntu release."
    err "Use --cuda-toolkit-pkg=cuda-toolkit for the latest supported release, or disable the system Toolkit."
    exit 1
  fi
  log "Installing CUDA toolkit package: $CUDA_TOOLKIT_PKG"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$CUDA_TOOLKIT_PKG"
fi

# -------- Miniconda (user-level) --------
install_miniconda_user() {
  local u="$1" h="$2" group
  local prefix="$h/miniconda3"
  group="$(id -gn "$u")"
  log "Installing Miniconda for user: $u"
  if ! sudo -H -u "$u" env HOME="$h" test -d "$prefix"; then
    local url arch installer tmp
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) installer="Miniconda3-latest-Linux-x86_64.sh" ;;
      aarch64|arm64) installer="Miniconda3-latest-Linux-aarch64.sh" ;;
      *) err "Unsupported arch for Miniconda: $arch"; return 1 ;;
    esac
    url="https://repo.anaconda.com/miniconda/$installer"
    tmp="$(mktemp "/tmp/${installer}.XXXXXX")"
    curl -fsSL "$url" -o "$tmp"
    chown "$u":"$group" "$tmp"
    sudo -H -u "$u" env HOME="$h" bash "$tmp" -b -p "$prefix"
    rm -f "$tmp"
  else
    log "Miniconda already present at $prefix"
  fi

  local conda_bin="$prefix/bin/conda"
  if ! sudo -H -u "$u" env HOME="$h" test -x "$conda_bin"; then
    err "Conda binary not found at $conda_bin"
    return 1
  fi

  log "Configuring conda-forge (strict) and initializing shells..."
  sudo -H -u "$u" env HOME="$h" "$conda_bin" config --set channel_priority strict
  sudo -H -u "$u" env HOME="$h" "$conda_bin" config --add channels conda-forge || true
  sudo -H -u "$u" env HOME="$h" "$conda_bin" init bash || true
  sudo -H -u "$u" env HOME="$h" "$conda_bin" init zsh  || true
}

install_miniconda_user "$TARGET_USER" "$TARGET_HOME"

# -------- Pixi (user-level) --------
install_pixi_user() {
  local u="$1" h="$2" pixi_bin="$2/.pixi/bin/pixi" installer group
  if sudo -H -u "$u" env HOME="$h" test -x "$pixi_bin"; then
    log "Pixi already present ($(sudo -H -u "$u" env HOME="$h" "$pixi_bin" --version 2>/dev/null))."
    return 0
  fi

  log "Installing Pixi for user: $u"
  installer="$(mktemp /tmp/pixi-install.XXXXXX.sh)"
  curl -fsSL https://pixi.sh/install.sh -o "$installer"
  group="$(id -gn "$u")"
  chown "$u":"$group" "$installer"
  sudo -H -u "$u" env HOME="$h" bash "$installer"
  rm -f "$installer"

  if ! sudo -H -u "$u" env HOME="$h" test -x "$pixi_bin"; then
    err "Pixi binary not found at $pixi_bin after installation."
    return 1
  fi
}

if [ "$INSTALL_PIXI" = "true" ]; then
  install_pixi_user "$TARGET_USER" "$TARGET_HOME"
fi

# -------- Optional terminal customization (explicit opt-in; runs last) --------
install_git_repo_user() {
  local u="$1" h="$2" url="$3" dest="$4"
  if sudo -H -u "$u" env HOME="$h" test -d "$dest/.git"; then
    log "Already installed: $dest"
  elif sudo -H -u "$u" env HOME="$h" test -e "$dest"; then
    err "Cannot install $url: path exists and is not a Git checkout: $dest"
    return 1
  else
    sudo -H -u "$u" env HOME="$h" git clone --depth=1 "$url" "$dest"
  fi
}

install_bash_zsh_fallback_user() {
  local u="$1" h="$2" bashrc marker
  bashrc="$h/.bashrc"
  marker="# >>> ThermoPhase Zsh fallback >>>"

  if sudo -H -u "$u" env HOME="$h" test -f "$bashrc" \
    && sudo -H -u "$u" env HOME="$h" grep -Fqx "$marker" "$bashrc"; then
    log "Bash-to-Zsh fallback already present in: $bashrc"
    return 0
  fi

  sudo -H -u "$u" env HOME="$h" tee -a "$bashrc" >/dev/null <<'BASHRC'

# >>> ThermoPhase Zsh fallback >>>
# Start Zsh for interactive TTYs when the institutional login shell cannot be changed.
if [ -t 1 ] && [ -z "${ZSH_VERSION:-}" ] && command -v zsh >/dev/null 2>&1; then
  exec zsh
fi
# <<< ThermoPhase Zsh fallback <<<
BASHRC
  log "Installed Bash-to-Zsh fallback in: $bashrc"
}

install_oh_my_zsh_user() {
  local u="$1" h="$2" custom_dir fonts_dir zshrc_tmp backup conda_bin zsh_bin login_shell updated_shell font font_url
  custom_dir="$h/.oh-my-zsh/custom"
  fonts_dir="$h/.local/share/fonts"

  log "Installing Zsh, terminal font support, and Pygments..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y zsh fontconfig python3-pygments

  log "Installing Oh My Zsh and the requested theme/plugins for $u..."
  install_git_repo_user "$u" "$h" https://github.com/ohmyzsh/ohmyzsh.git "$h/.oh-my-zsh"
  install_git_repo_user "$u" "$h" https://github.com/romkatv/powerlevel10k.git "$custom_dir/themes/powerlevel10k"
  install_git_repo_user "$u" "$h" https://github.com/zsh-users/zsh-autosuggestions.git "$custom_dir/plugins/zsh-autosuggestions"
  install_git_repo_user "$u" "$h" https://github.com/zsh-users/zsh-syntax-highlighting.git "$custom_dir/plugins/zsh-syntax-highlighting"

  sudo -H -u "$u" env HOME="$h" mkdir -p "$fonts_dir"
  for font in \
    "MesloLGS NF Regular.ttf" \
    "MesloLGS NF Bold.ttf" \
    "MesloLGS NF Italic.ttf" \
    "MesloLGS NF Bold Italic.ttf"; do
    if ! sudo -H -u "$u" env HOME="$h" test -f "$fonts_dir/$font"; then
      font_url="https://github.com/romkatv/powerlevel10k-media/raw/master/$(printf '%s' "$font" | sed 's/ /%20/g')"
      sudo -H -u "$u" env HOME="$h" curl -fsSL "$font_url" -o "$fonts_dir/$font"
    fi
  done
  sudo -H -u "$u" env HOME="$h" fc-cache -f "$fonts_dir" >/dev/null 2>&1 || true

  if sudo -H -u "$u" env HOME="$h" test -f "$h/.zshrc"; then
    backup="$h/.zshrc.pre-thermophase.$(date +%Y%m%d-%H%M%S)"
    sudo -H -u "$u" env HOME="$h" cp -p "$h/.zshrc" "$backup"
    log "Existing .zshrc backed up to: $backup"
  fi

  zshrc_tmp="$(sudo -H -u "$u" env HOME="$h" mktemp "$h/.zshrc.thermophase.XXXXXX")"
  sudo -H -u "$u" env HOME="$h" tee "$zshrc_tmp" >/dev/null <<'ZSHRC'
# Managed by ThermoPhase provisioning

# Powerlevel10k instant prompt must stay near the top of this file.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"
[[ -d /opt/homebrew/opt/unzip/bin ]] && export PATH="/opt/homebrew/opt/unzip/bin:$PATH"

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
ZSH_PYENV_QUIET=true
plugins=(
  git
  colored-man-pages
  colorize
  python
  pyenv
  virtualenv
  conda-env
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source "$ZSH/oh-my-zsh.sh"

[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

function activate_firedrake() {
  local activate_script="$HOME/firedrake/venv-firedrake/bin/activate"
  if [[ ! -f "$activate_script" ]]; then
    print -u2 "Firedrake environment not found: $activate_script"
    return 1
  fi
  source "$activate_script"
}
ZSHRC
  sudo -H -u "$u" env HOME="$h" chmod 0644 "$zshrc_tmp"
  sudo -H -u "$u" env HOME="$h" mv "$zshrc_tmp" "$h/.zshrc"

  conda_bin="$h/miniconda3/bin/conda"
  [ -x "$conda_bin" ] || conda_bin="$h/miniforge3/bin/conda"
  if [ -x "$conda_bin" ]; then
    sudo -H -u "$u" env HOME="$h" "$conda_bin" init zsh || warn "conda init zsh failed."
  fi

  zsh_bin="$(command -v zsh)"
  login_shell="$(getent passwd "$u" | cut -d: -f7)"
  if [ "$login_shell" != "$zsh_bin" ]; then
    if grep -Fqx "$zsh_bin" /etc/shells 2>/dev/null && chsh -s "$zsh_bin" "$u"; then
      updated_shell="$(getent passwd "$u" | cut -d: -f7)"
      if [ "$updated_shell" = "$zsh_bin" ]; then
        log "Changed the login shell for $u to: $zsh_bin"
        return 0
      fi
      warn "chsh completed, but NSS still reports ${updated_shell:-an unknown shell} for $u."
    else
      warn "Could not change the login shell (common with LDAP/centrally managed accounts)."
    fi
    install_bash_zsh_fallback_user "$u" "$h"
    warn "The institutional login shell remains ${login_shell:-unchanged}; interactive Bash terminals will start Zsh via $h/.bashrc."
  fi
}

if [ "$INSTALL_OH_MY_ZSH" = "true" ]; then
  install_oh_my_zsh_user "$TARGET_USER" "$TARGET_HOME"
fi

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
for p in "$TARGET_HOME/miniconda3/bin/conda" "$TARGET_HOME/miniforge3/bin/conda"; do
  if sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" test -x "$p"; then
    CONDA_BIN="$p"
    break
  fi
done
if [ -z "$CONDA_BIN" ] && [ -x /opt/conda/bin/conda ]; then
  CONDA_BIN=/opt/conda/bin/conda
fi
if [ -z "$CONDA_BIN" ]; then
  CONDA_BIN="$(sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" sh -c 'command -v conda 2>/dev/null || true')"
fi

if [ -n "$CONDA_BIN" ]; then
  pass "conda present ($(sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$CONDA_BIN" --version 2>/dev/null))"
else
  warnv "conda not found (open a NEW shell or verify Miniconda path)"
fi

if [ "$INSTALL_PIXI" = "true" ]; then
  PIXI_BIN="$TARGET_HOME/.pixi/bin/pixi"
  if sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" test -x "$PIXI_BIN"; then
    pass "pixi present ($(sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" "$PIXI_BIN" --version 2>/dev/null))"
  else
    warnv "pixi not found at $PIXI_BIN"
  fi
fi

if [ "$INSTALL_OH_MY_ZSH" = "true" ]; then
  sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    test -f "$TARGET_HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" \
    && pass "Oh My Zsh and Powerlevel10k configured" \
    || warnv "Oh My Zsh or Powerlevel10k is incomplete"
fi

if [ "$INSTALL_DOCKER" = "true" ]; then
  if command -v docker >/dev/null 2>&1; then
    pass "docker present ($(docker --version 2>/dev/null))"
  else
    $IS_WSL && warnv "docker not on PATH in WSL (expected if using Docker Desktop on Windows)"
    $IS_WSL || warnv "docker not found on PATH"
  fi
fi

if [ "$INSTALL_CUDA" = "true" ]; then
  NVCC_BIN="$(command -v nvcc 2>/dev/null || true)"
  if [ -z "$NVCC_BIN" ] && [ -x /usr/local/cuda/bin/nvcc ]; then
    NVCC_BIN="/usr/local/cuda/bin/nvcc"
  fi
  if [ -n "$NVCC_BIN" ]; then
    pass "nvcc present ($("$NVCC_BIN" --version | tail -n1))"
  else
    warnv "nvcc not found; add /usr/local/cuda/bin to PATH if the Toolkit installed successfully"
  fi
fi

if [ "$INSTALL_CUDA" = "true" ] || [ "$INSTALL_DRIVER" = "true" ]; then
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    pass "NVIDIA driver operational ($(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | sed -n '1p'))"
  elif $IS_WSL; then
    warnv "nvidia-smi is unavailable in WSL; install/update the NVIDIA driver on Windows"
  else
    warnv "nvidia-smi is unavailable; a reboot may be required after driver installation"
  fi
fi

if [ "$ok" -ne 0 ]; then
  printf "\n\033[1;33m[VERIFY]\033[0m Some items are missing or not yet on PATH.\n"
  [ "$VERIFY_STRICT" = "true" ] && exit 1
else
  printf "\n\033[1;32m[VERIFY]\033[0m All expected tools detected.\n"
fi

if [ "$INSTALL_OH_MY_ZSH" = "true" ]; then
  warn "Select 'MesloLGS NF' in the terminal profile if glyphs are not rendered correctly."
  if [ -t 0 ] && [ -t 1 ]; then
    log "Launching the Powerlevel10k configuration wizard after dependency installation..."
    sudo -H -u "$TARGET_USER" env HOME="$TARGET_HOME" ZDOTDIR="$TARGET_HOME" \
      zsh -ic 'p10k configure' || warn "Powerlevel10k wizard did not complete; run 'p10k configure' later."
  else
    warn "No interactive terminal detected. Open Zsh and run: p10k configure"
  fi
fi

# -------- summary --------
echo
log "Provisioning complete."
[ "$INSTALL_PIXI" = "true" ] && echo "• Pixi installed for $TARGET_USER: $TARGET_HOME/.pixi/bin/pixi."
[ "$INSTALL_OH_MY_ZSH" = "true" ] && echo "• Oh My Zsh, Powerlevel10k, plugins, and MesloLGS NF fonts installed for $TARGET_USER."
[ "$INSTALL_CUDA" = "true" ] && echo "• CUDA Toolkit package installed: $CUDA_TOOLKIT_PKG."
[ "$INSTALL_DRIVER" = "true" ] && ! $IS_WSL && echo "• NVIDIA driver package installed: $NVIDIA_DRIVER_PKG."
$REBOOT_REQUIRED && warn "Reboot required to load the newly installed NVIDIA driver."
echo "• Miniconda for $TARGET_USER: $TARGET_HOME/miniconda3"
echo "• conda-forge enabled (strict), conda init done for bash, zsh."
[ "$INSTALL_PYTHON" = "true" ] && echo "• System Python installed: python3 + venv + pip (use: 'python3 -m venv .venv')."
[ "$INSTALL_VSCODE" = "true" ] && echo "• VS Code installed (code)."
[ "$INSTALL_DOCKER" = "true" ] && $IS_WSL && echo "• Docker: use Docker Desktop w/ WSL integration."
