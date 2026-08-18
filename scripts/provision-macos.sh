#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# Provision macOS for Dev + Miniforge (CLI)
# Profiles: default | minimal | gpu
# Flags override profile defaults.
# No Conda envs created; only Miniforge + conda-forge (strict) + conda init.
# ===========================================

# ---------- Defaults ----------
PROFILE="default"

INSTALL_VSCODE=true
INSTALL_DOCKER=true
INSTALL_ITERM2=true
INSTALL_ROSETTA=false          # Apple Silicon only; ignored on Intel

INSTALL_MINIFORGE=true
MINIFORGE_PREFIX="$HOME/miniforge3"

INSTALL_LLVM=true              # Installs llvm and libomp via Homebrew
INSTALL_PYTHON=true            # Homebrew Python (includes venv)
INSTALL_PIXI=true

# CLI overrides are collected separately so profiles are applied first.
CLI_INSTALL_VSCODE=""
CLI_INSTALL_DOCKER=""
CLI_INSTALL_ITERM2=""
CLI_INSTALL_ROSETTA=""
CLI_INSTALL_MINIFORGE=""
CLI_MINIFORGE_PREFIX=""
CLI_INSTALL_LLVM=""
CLI_INSTALL_PYTHON=""
CLI_INSTALL_PIXI=""

# ---------- Helpers ----------
log()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
is_arm() { [[ "$(uname -m)" == "arm64" ]]; }
need_admin() {
  if ! groups | grep -q admin; then
    warn "Your user is not in the admin group. Some steps may fail (casks, Rosetta)."
  fi
}

# Bash 3.2–compatible boolean parser (lowercase via tr)
parse_bool() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    true|1|yes|y|on)  echo "true" ;;
    false|0|no|n|off) echo "false" ;;
    *) err "Invalid boolean value: '$1' (use true/false)"; exit 2 ;;
  esac
}

# ---------- Parse CLI ----------
for arg in "$@"; do
  case "$arg" in
    --profile=*)              PROFILE="${arg#*=}";;
    --install-vscode=*)       CLI_INSTALL_VSCODE=$(parse_bool "${arg#*=}");;
    --install-docker=*)       CLI_INSTALL_DOCKER=$(parse_bool "${arg#*=}");;
    --install-iterm2=*)       CLI_INSTALL_ITERM2=$(parse_bool "${arg#*=}");;
    --install-rosetta=*)      CLI_INSTALL_ROSETTA=$(parse_bool "${arg#*=}");;
    --install-miniforge=*)    CLI_INSTALL_MINIFORGE=$(parse_bool "${arg#*=}");;
    --miniforge-prefix=*)     CLI_MINIFORGE_PREFIX="${arg#*=}";;
    --install-llvm=*)         CLI_INSTALL_LLVM=$(parse_bool "${arg#*=}");;
    --install-python=*)       CLI_INSTALL_PYTHON=$(parse_bool "${arg#*=}");;
    --install-pixi=*)         CLI_INSTALL_PIXI=$(parse_bool "${arg#*=}");;
    -h|--help)
      cat <<'USAGE'
Usage: bash provision-macos.sh [flags]

Profiles (defaults if you omit flags):
  --profile=default   VS Code ON, Docker ON, Pixi ON
  --profile=minimal   VS Code ON, Docker OFF, Pixi ON
  --profile=gpu       VS Code ON, Docker ON, Pixi ON (CUDA unsupported on macOS)

Flags (override profile defaults):
  --install-vscode=true|false
  --install-docker=true|false
  --install-iterm2=true|false
  --install-rosetta=true|false             # Apple Silicon only
  --install-miniforge=true|false
  --miniforge-prefix=/path/to/miniforge3   # default: $HOME/miniforge3
  --install-llvm=true|false
  --install-python=true|false              # Homebrew Python (with venv), default: true
  --install-pixi=true|false                # Pixi via Homebrew, default: true
USAGE
      exit 0;;
    *) err "Unknown flag: $arg"; exit 2;;
  esac
done

# ---------- Apply profile defaults ----------
case "$PROFILE" in
  minimal)
    INSTALL_DOCKER=false
    ;;
  gpu)
    : # kept for parity; CUDA not available on modern macOS
    ;;
  default) ;;
  *) err "Invalid --profile value: $PROFILE (use default|minimal|gpu)"; exit 2;;
esac

# Explicit flags override profile defaults.
[[ -n "$CLI_INSTALL_VSCODE" ]] && INSTALL_VSCODE="$CLI_INSTALL_VSCODE"
[[ -n "$CLI_INSTALL_DOCKER" ]] && INSTALL_DOCKER="$CLI_INSTALL_DOCKER"
[[ -n "$CLI_INSTALL_ITERM2" ]] && INSTALL_ITERM2="$CLI_INSTALL_ITERM2"
[[ -n "$CLI_INSTALL_ROSETTA" ]] && INSTALL_ROSETTA="$CLI_INSTALL_ROSETTA"
[[ -n "$CLI_INSTALL_MINIFORGE" ]] && INSTALL_MINIFORGE="$CLI_INSTALL_MINIFORGE"
[[ -n "$CLI_MINIFORGE_PREFIX" ]] && MINIFORGE_PREFIX="$CLI_MINIFORGE_PREFIX"
[[ -n "$CLI_INSTALL_LLVM" ]] && INSTALL_LLVM="$CLI_INSTALL_LLVM"
[[ -n "$CLI_INSTALL_PYTHON" ]] && INSTALL_PYTHON="$CLI_INSTALL_PYTHON"
[[ -n "$CLI_INSTALL_PIXI" ]] && INSTALL_PIXI="$CLI_INSTALL_PIXI"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  err "Run this script as a normal user, not with sudo; Homebrew does not support root execution."
  exit 1
fi

need_admin
log "Profile: $PROFILE"
log "Flags -> VSCode:$INSTALL_VSCODE Docker:$INSTALL_DOCKER iTerm2:$INSTALL_ITERM2 Miniforge:$INSTALL_MINIFORGE LLVM:$INSTALL_LLVM Python:$INSTALL_PYTHON Pixi:$INSTALL_PIXI Rosetta:$INSTALL_ROSETTA"
log "Miniforge prefix -> $MINIFORGE_PREFIX"
log "Architecture: $(uname -m)"

# ---------- 1) Ensure Xcode Command Line Tools ----------
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  SW_UPDATE_LIST=$(/usr/sbin/softwareupdate -l 2>/dev/null)
  CLT_LINES=$(echo "$SW_UPDATE_LIST" | awk -F'*' '/\* Command Line (Developer )?Tools/ {print $2}')
  CLT_PRODUCTS=$(echo "$CLT_LINES" | sed -e 's/^ *//')
  PROD=$(echo "$CLT_PRODUCTS" | tail -n1 || true)
  if [[ -n "${PROD:-}" ]]; then
    sudo /usr/sbin/softwareupdate -i "$PROD" -v || true
    sudo /usr/bin/xcode-select --switch /Library/Developer/CommandLineTools || true
  else
    xcode-select --install || true
    warn "If a dialog popped up, please click 'Install'. You can re-run this script afterwards."
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress || true
else
  log "Xcode Command Line Tools already installed."
fi

# ---------- 2) Ensure Homebrew ----------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Wire brew into THIS shell and future shells
if is_arm; then
  BREW_PATH="/opt/homebrew/bin/brew"
  eval "$(${BREW_PATH} shellenv)"
  grep -q "${BREW_PATH} shellenv" "${ZDOTDIR:-$HOME}"/.zprofile 2>/dev/null || {
    echo "eval \"\$(${BREW_PATH} shellenv)\"" >> "${ZDOTDIR:-$HOME}"/.zprofile
  }
  grep -q "${BREW_PATH} shellenv" "$HOME/.bash_profile" 2>/dev/null || {
    echo "eval \"\$(${BREW_PATH} shellenv)\"" >> "$HOME/.bash_profile"
  }
else
  BREW_PATH="/usr/local/bin/brew"
  eval "$(${BREW_PATH} shellenv)"
  grep -q "${BREW_PATH} shellenv" "${ZDOTDIR:-$HOME}"/.zprofile 2>/dev/null || {
    echo "eval \"\$(${BREW_PATH} shellenv)\"" >> "${ZDOTDIR:-$HOME}"/.zprofile
  }
  grep -q "${BREW_PATH} shellenv" "$HOME/.bash_profile" 2>/dev/null || {
    echo "eval \"\$(${BREW_PATH} shellenv)\"" >> "$HOME/.bash_profile"
  }
fi

BREW="$(command -v brew)"
log "Homebrew at: $BREW"
brew update

brew_install() {
  local pkg="$1"
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    log "Formula already installed: $pkg"
  else
    brew install "$pkg"
  fi
}
brew_install_cask() {
  local cask="$1"
  if brew list --cask "$cask" >/dev/null 2>&1; then
    log "Cask already installed: $cask"
  else
    brew install --cask "$cask"
  fi
}

# ---------- 3) Core dev tools ----------
log "Installing core dev tools..."
brew_install git
brew_install git-lfs
git lfs install || true
brew_install cmake
brew_install ninja
brew_install pkg-config
if [[ "$INSTALL_LLVM" == "true" ]]; then
  brew_install llvm
  brew_install libomp
fi

if [[ "$INSTALL_PYTHON" == "true" ]]; then
  log "Installing Homebrew Python (includes venv)..."
  brew_install python
fi
if [[ "$INSTALL_PIXI" == "true" ]]; then
  log "Installing Pixi via Homebrew..."
  brew_install pixi
fi

# ---------- 4) Apps (casks) ----------
if [[ "$INSTALL_VSCODE" == "true" ]]; then
  brew_install_cask visual-studio-code
fi
if [[ "$INSTALL_ITERM2" == "true" ]]; then
  brew_install_cask iterm2
fi
if [[ "$INSTALL_DOCKER" == "true" ]]; then
  brew_install_cask docker
  warn "After installation, launch Docker.app once to finish setup and grant permissions."
fi

# ---------- 5) Rosetta 2 (Apple Silicon only) ----------
if is_arm && [[ "$INSTALL_ROSETTA" == "true" ]]; then
  if /usr/bin/pgrep oahd >/dev/null 2>&1; then
    log "Rosetta 2 already installed."
  else
    log "Installing Rosetta 2..."
    sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license || warn "Rosetta install may have been skipped."
  fi
fi

# ---------- 6) Miniforge (Conda, conda-forge strict, init shells) ----------
if [[ "$INSTALL_MINIFORGE" == "true" ]]; then
  log "Installing Miniforge at: $MINIFORGE_PREFIX"
  if [[ ! -d "$MINIFORGE_PREFIX" ]]; then
    tmp_inst="$(mktemp /tmp/miniforge.XXXXXX.sh)"
    if is_arm; then
      url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-arm64.sh"
    else
      url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-x86_64.sh"
    fi
    curl -fsSL "$url" -o "$tmp_inst"
    bash "$tmp_inst" -b -p "$MINIFORGE_PREFIX"
    rm -f "$tmp_inst"
  else
    log "Miniforge already present."
  fi

  CONDA_BIN="$MINIFORGE_PREFIX/bin/conda"
  if [[ ! -x "$CONDA_BIN" ]]; then
    err "Conda binary not found at $CONDA_BIN"; exit 1
  fi

  log "Configuring conda-forge (strict) and initializing shells..."
  "$CONDA_BIN" config --set channel_priority strict
  "$CONDA_BIN" config --add channels conda-forge || true
  "$CONDA_BIN" init zsh || true
  "$CONDA_BIN" init bash || true
fi

# ---------- 7) Final ----------
echo
log "Provisioning complete (profile: $PROFILE)."
echo "• Homebrew: $(brew --version | head -n1)"
core_tools="git, git-lfs, cmake, ninja, pkg-config"
if [[ "$INSTALL_LLVM" == "true" ]]; then
  core_tools="$core_tools, llvm, libomp"
fi
if [[ "$INSTALL_PYTHON" == "true" ]]; then
  core_tools="$core_tools, python (with venv)"
fi
echo "• Core tools: $core_tools."
if [[ "$INSTALL_PIXI" == "true" ]]; then
  if command -v pixi >/dev/null 2>&1; then
    echo "• Pixi: $(pixi --version)"
  else
    warn "Pixi was requested but is not on PATH. Open a new terminal and run 'pixi --version'."
  fi
fi
[[ "$INSTALL_VSCODE" == "true" ]] && echo "• VS Code installed (launch: 'Visual Studio Code')."
[[ "$INSTALL_ITERM2"  == "true" ]] && echo "• iTerm2 installed."
[[ "$INSTALL_DOCKER"  == "true" ]] && echo "• Docker Desktop installed (launch 'Docker' once to finish setup)."
if [[ "$INSTALL_MINIFORGE" == "true" ]]; then
  echo "• Miniforge: $MINIFORGE_PREFIX"
  echo "  - conda-forge enabled (strict), shells initialized (zsh & bash)."
  echo "  - Open a NEW terminal to get 'conda' on PATH, or run: 'source \"$MINIFORGE_PREFIX/etc/profile.d/conda.sh\"' then 'conda activate'."
fi

warn "CUDA is not supported on current macOS. For PyTorch on Apple Silicon, use the MPS (Metal) device."
