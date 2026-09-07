# sandbox-setup — one-command dev machines

Reproducible setup for throwaway VMs. Same script everywhere: GCP today, Daytona tomorrow.

## New machine (GCP / any Debian/Ubuntu)

```bash
git clone https://github.com/ahmadjavaiddev/sandbox-setup.git && cd sandbox-setup && ./setup.sh
# unattended (curl | bash, GCP startup-script):
curl -fsSL raw.githubusercontent.com/ahmadjavaiddev/sandbox-setup/main/setup.sh | bash -s -- --yes
```

Re-run anytime to sync N machines: `git pull && ./setup.sh` (idempotent, dotfiles never clobbered without backup).

## Daytona (one command)

Create the 4 vCPU / 8 GiB RAM / 50 GiB disk sandbox:

`ash
DAYTONA_API_KEY=\your-key\ ./bin/daytona-setup [sandbox-name]
`

The key is read from the environment and never written to the repository. The image-based sandbox uses explicit resources because Daytona does not allow disk overrides on snapshots. The sandbox installs git/gh, 3@nightly, and Codex CLI, with Codex pointed at https://ai.tunly.cloud/v1.

## Daytona (zero setup per workspace)

1. Push this repo to GitHub.
2. Daytona Dashboard → Prebuilds → add this repo (it uses `.devcontainer/devcontainer.json`, which just runs `setup.sh --yes`).
3. Every new workspace from now on boots with docker, gh, node 24, cloudflared, zsh preinstalled.

For project repos, add the same one-liner as that repo's `postCreateCommand`, or set this repo as your Daytona dotfiles repo.

## First-login checklist (per machine, 2 min)

```bash
gh auth login
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"   # if setup.sh didn't create one
gh ssh-key add ~/.ssh/id_ed25519.pub -t "$(hostname)"
git config --file ~/.gitconfig.local user.name "Your Name"
git config --file ~/.gitconfig.local user.email "you@example.com"
sudo tailscale up   # optional, connects parallel machines
```

## cloudflared Zero Trust (named tunnel, persistent domain)

One-time per Cloudflare account:

```bash
cloudflared tunnel login          # opens browser, writes ~/.cloudflared/cert.pem
bin/cf-tunnel create myapp        # prints tunnel UUID
# edit ~/.cloudflared/config.yml: set tunnel: <uuid>, credentials-file, hostnames
bin/cf-tunnel dns myapp app.example.com
bin/cf-tunnel run myapp           # foreground; use systemd below for persistent
```

Persistent service (survives reboot):

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Config lives in `~/.cloudflared/config.yml` (templated from `dotfiles/.cloudflared/config.yml.example`). Credentials (`*.json`, `cert.pem`) are gitignored — copy them via `scp`/`sops`/1Password when adding a second parallel machine, don't commit them.

## What's inside

| File | Purpose |
|---|---|
| `setup.sh` | idempotent bootstrap: apt, docker, cloudflared, mise+node 24, zsh+starship, tailscale, dotfile symlinks |
| `mise.toml` | runtime pins (single source of truth) |
| `dotfiles/` | `.zshrc`, `.gitconfig`, `starship.toml`, cloudflared config template |
| `.devcontainer/devcontainer.json` | Daytona prebuild entrypoint (calls `setup.sh --yes`) |
| `bin/cf-tunnel` | Zero Trust helper (create/dns/run) |

## Conventions

- `zsh` is the interactive default; `.bashrc.snippet` keeps `bash` logins (GCP startup, scripts) working with mise on PATH.
- Per-machine overrides → `~/.zshrc.local`, `~/.gitconfig.local` (never committed).
- `--minimal` flag skips tailscale/extras for tiny boxes.
