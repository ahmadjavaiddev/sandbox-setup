# sandbox-setup zshrc — shared across GCP + Daytona boxes
# CliproxyProject endpoint for Codex/OpenAI-compatible clients.
export OPENAI_BASE_URL=" \
export CODEX_API_BASE=\\n
export PATH="$HOME/.local/bin:$HOME/go/bin:$HOME/.cloudflared:$PATH"

# mise (node 24) — single version source is ../mise.toml
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

# starship prompt (installed by setup.sh)
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# debian plugin paths for autosuggestions / syntax-highlighting (apt versions)
for f in /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
         /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
  [ -r "$f" ] && source "$f"
done

# --- aliases ---
alias g='git'
alias gs='git status -sb'
alias gp='git pull --ff-only'
alias dc='docker compose'
alias cf='cloudflared'
alias k='kubectl 2>/dev/null'

# per-machine overrides (not committed): ~/.zshrc.local
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
