#!/usr/bin/env bash
# sandbox-setup / setup.sh
# One-command dev machine bootstrap. Idempotent. Safe to re-run.
# Usage:
#   curl -fsSL raw.githubusercontent.com/ahmadjavaiddev/sandbox-setup/main/setup.sh | bash
#   git clone https://github.com/ahmadjavaiddev/sandbox-setup.git && cd sandbox-setup && ./setup.sh [--yes] [--minimal]
#
# Tested on: Debian 12/13, Ubuntu 22.04/24.04 (x86_64 + arm64)
# Covers: git/gh, docker, cloudflared (Zero Trust), zsh+starship, mise+node, tailscale, dotfiles

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NONINTERACTIVE=0
MINIMAL=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes|--non-interactive) NONINTERACTIVE=1 ;;
    --minimal) MINIMAL=1 ;;
    -h|--help)
      echo "Usage: ./setup.sh [--yes] [--minimal]"
      echo "  --yes       non-interactive (for curl|bash, GCP startup-script, Daytona prebuild)"
      echo "  --minimal   skip tailscale, neovim, tmux extras"
      exit 0
      ;;
  esac
done

# --- helpers ---------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo -E"
fi

# PRIV=0 when there is no way to elevate (no passwordless sudo + non-interactive):
# privileged steps are skipped with a warning, user-level steps still apply.
PRIV=1
if [ "$(id -u)" -ne 0 ] && ! $SUDO -n true 2>/dev/null && [ "$NONINTERACTIVE" -eq 1 ]; then
  PRIV=0
  warn "no passwordless sudo in non-interactive mode — apt/docker/system steps will be skipped"
  warn "re-run with sudo access (or interactively, entering your password) for full setup"
fi

apt_install() {
  # apt_install pkg1 pkg2 ... — installs only missing debs
  local missing=()
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "apt install: ${missing[*]}"
    $SUDO apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "${missing[@]}"
  fi
}

# --- 0. sanity -------------------------------------------------------------
if [ ! -f /etc/debian_version ] && ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  warn "Not Debian/Ubuntu — apt steps will be skipped, dotfiles + mise still applied."
fi
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64|arm64) DEB_ARCH="arm64" ;;
  *) warn "Unknown arch $ARCH, cloudflared/docker debs may fail"; DEB_ARCH="amd64" ;;
esac

# --- 1. base apt -----------------------------------------------------------
log "1/8 base packages"
if have apt-get && [ "$PRIV" -eq 1 ]; then
  apt_install ca-certificates curl wget gnupg lsb-release \
    git gh jq unzip zip htop tmux fzf ripgrep fd-find \
    build-essential zsh stow \
    zsh-autosuggestions zsh-syntax-highlighting
  ok "base packages present"
elif ! have apt-get; then
  warn "no apt-get — skipping system packages"
else
  warn "skipped (no privilege elevation) — need: git gh curl zsh stow fzf ripgrep"
fi

# --- 2. docker (official repo, idempotent) ----------------------------------
log "2/8 docker"
if ! have docker; then
  if [ "$PRIV" -eq 0 ]; then
    warn "skipped docker install (no privilege elevation)"
  else
  log "installing docker from docker.com repo"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  CODENAME="$(lsb_release -cs 2>/dev/null || echo stable)"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi
# docker group + daemon, even if docker already existed
if getent group docker >/dev/null; then
  if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
    $SUDO usermod -aG docker "$USER" || true
    warn "added $USER to docker group — re-login (or 'newgrp docker') to use docker without sudo"
  fi
fi
if have systemctl && [ -d /run/systemd/system ]; then
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
fi
have docker && ok "docker $(docker --version 2>/dev/null || echo present)"

# --- 3. cloudflared (official deb, idempotent) -------------------------------
log "3/8 cloudflared (Zero Trust)"
if ! have cloudflared; then
  if [ "$PRIV" -eq 0 ]; then
    warn "skipped cloudflared install (no privilege elevation)"
  else
  log "installing cloudflared ($DEB_ARCH)"
  TMPDEB="$(mktemp /tmp/cloudflared-XXXXXX.deb)"
  curl -fsSL -o "$TMPDEB" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${DEB_ARCH}.deb"
  $SUDO dpkg -i "$TMPDEB" || { $SUDO apt-get install -f -y -qq; }
  rm -f "$TMPDEB"
  fi
fi
have cloudflared && ok "cloudflared $(cloudflared --version 2>/dev/null | head -1)"
# config template — never overwrites existing config (holds tunnel UUID + credentials)
mkdir -p "$HOME/.cloudflared"
if [ ! -f "$HOME/.cloudflared/config.yml" ]; then
  if [ -f "$REPO_DIR/dotfiles/.cloudflared/config.yml.example" ]; then
    cp "$REPO_DIR/dotfiles/.cloudflared/config.yml.example" "$HOME/.cloudflared/config.yml"
    warn "created ~/.cloudflared/config.yml from example — edit with your tunnel UUID, then: cloudflared tunnel login && cloudflared tunnel run"
  fi
else
  ok "~/.cloudflared/config.yml kept (not overwritten)"
fi
chmod 600 "$HOME/.cloudflared/config.yml" 2>/dev/null || true

# --- 4. mise + node ----------------------------------------------------------
log "4/8 mise + node"
if ! have mise; then
  log "installing mise"
  curl -fsSL https://mise.run | sh
fi
# ensure mise on PATH for this run + future shells (dotfiles also do this)
export PATH="$HOME/.local/bin:$PATH"
if have mise; then
  ok "mise $(mise --version 2>/dev/null | head -1)"
  if [ -f "$REPO_DIR/mise.toml" ]; then
    # trust + install declared tools (currently: node 24)
    mise trust "$REPO_DIR/mise.toml" 2>/dev/null || true
    (cd "$REPO_DIR" && mise install) || warn "mise install had warnings (check network)"
  fi
else
  warn "mise not on PATH — open a new shell and re-run ./setup.sh"
fi

# --- 5. shell: zsh default + starship ----------------------------------------
log "5/8 shell (zsh + starship)"
if ! have starship && [ "$MINIMAL" -eq 0 ]; then
  if [ "$PRIV" -eq 0 ]; then
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin" >/dev/null 2>&1 || warn "starship install failed (non-fatal)"
  else
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes >/dev/null 2>&1 || warn "starship install failed (non-fatal)"
  fi
fi
have starship && ok "starship present" || true
# zsh as default (skip in containers without chsh permission)
if have zsh && [ "${SHELL:-}" != "$(command -v zsh)" ]; then
  if $SUDO -n true 2>/dev/null || [ "$NONINTERACTIVE" -eq 0 ]; then
    chsh -s "$(command -v zsh)" "$USER" 2>/dev/null && ok "default shell -> zsh (takes effect next login)" || warn "could not chsh — run manually: chsh -s \$(which zsh)"
  else
    warn "skipping chsh in non-interactive mode"
  fi
fi

# --- 6. dotfiles (symlink, never clobber without backup) ----------------------
log "6/8 dotfiles"
link_dotfile() {
  local src="$1" dest="$2"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.pre-setup-$(date +%Y%m%d-%H%M%S).bak"
    warn "backed up existing $dest"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}
if [ -d "$REPO_DIR/dotfiles" ]; then
  link_dotfile "$REPO_DIR/dotfiles/.zshrc"                 "$HOME/.zshrc"
  link_dotfile "$REPO_DIR/dotfiles/.gitconfig"             "$HOME/.gitconfig"
  link_dotfile "$REPO_DIR/dotfiles/.config/starship.toml"  "$HOME/.config/starship.toml"
  # bash gets a snippet that also loads mise — keeps GCP default-shell logins working
  if [ -f "$REPO_DIR/dotfiles/.bashrc.snippet" ]; then
    touch "$HOME/.bashrc"
    if ! grep -q "sandbox-setup" "$HOME/.bashrc"; then
      cat "$REPO_DIR/dotfiles/.bashrc.snippet" >> "$HOME/.bashrc"
      ok "~/.bashrc snippet appended"
    fi
  fi
  ok "dotfiles linked"
fi

# --- 7. extras (tailscale for multi-machine, skipped with --minimal) ----------
if [ "$MINIMAL" -eq 0 ]; then
  log "7/8 tailscale (multi-machine mesh)"
  if ! have tailscale; then
    if [ "$PRIV" -eq 0 ]; then
      warn "skipped tailscale install (no privilege elevation)"
    else
      curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || warn "tailscale install failed (non-fatal)"
    fi
  fi
  have tailscale && ok "tailscale present — run: sudo tailscale up" || true
else
  log "7/8 skipped (--minimal)"
fi

# --- 8. auth status (never stores secrets) ------------------------------------
log "8/8 auth checklist"
if have gh; then
  if gh auth status >/dev/null 2>&1; then ok "gh authenticated ($(gh api user -q .login 2>/dev/null || echo ok))"
  else warn "gh not logged in — run: gh auth login   (then: gh ssh-key add ~/.ssh/id_ed25519.pub -t \$(hostname))"; fi
fi
if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    warn "no ssh key — run on next login: ssh-keygen -t ed25519 -C \"\$(whoami)@\$(hostname)\""
  else
    printf "No SSH key found. Generate one now? [Y/n] "
    read -r ans || true
    if [[ ! "$ans" =~ ^[Nn] ]]; then
      ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519" -N ""
      ok "ssh key created — add it: gh ssh-key add ~/.ssh/id_ed25519.pub -t $(hostname)"
    fi
  fi
else
  ok "ssh key exists"
fi
if have cloudflared; then
  if [ -f "$HOME/.cloudflared/cert.pem" ]; then ok "cloudflared logged in (cert.pem present)"
  else warn "cloudflared not logged in — run: cloudflared tunnel login   (Zero Trust: creates cert.pem, then 'cloudflared tunnel create <name>')"; fi
fi

echo ""
echo "Done. Next: newgrp docker (if group was added) • restart shell (zsh) • gh auth login • cloudflared tunnel login"
echo "Re-run anytime: cd $REPO_DIR && git pull && ./setup.sh"
