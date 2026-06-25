# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

**CLI Proxy Manager** — shell scripts and Docker Compose config that wrap [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) to provide a one-click reverse proxy for Antigravity, Claude Code, Gemini CLI, and Codex. There is no application code compiled here; the logic lives entirely in `deploy.sh` (Bash) and `deploy.ps1` (PowerShell 7+), with `docker-compose.yml` driving the container.

## Key Commands

### Syntax-check the scripts (no Docker needed)

```bash
bash -n deploy.sh && bash -n install.sh
```

```powershell
pwsh -NoProfile -Command "try { . .\deploy.ps1 } catch {}"
```

```bash
docker compose -f docker-compose.yml config --quiet
```

### Deploy / manage the proxy

| Action | Linux/macOS | Windows |
|---|---|---|
| Full interactive deploy | `bash deploy.sh` | `.\deploy.ps1` |
| OAuth login | `bash deploy.sh login` | `.\deploy.ps1 login` |
| Start | `bash deploy.sh start` | `.\deploy.ps1 start` |
| Stop | `bash deploy.sh stop` | `.\deploy.ps1 stop` |
| Restart | `bash deploy.sh restart` | `.\deploy.ps1 restart` |
| Status + API test | `bash deploy.sh status` | `.\deploy.ps1 status` |
| Logs | `bash deploy.sh logs` | `.\deploy.ps1 logs` |
| Update image | `bash deploy.sh update` | `.\deploy.ps1 update` |
| Uninstall | `bash deploy.sh uninstall` | `.\deploy.ps1 uninstall` |
| Setup Claude Code | `bash deploy.sh setup-claude` | `.\deploy.ps1 setup-claude` |

Custom port: `CPA_PORT=9000 bash deploy.sh start` / `$env:CPA_PORT=9000; .\deploy.ps1 start`

## Architecture

```
deploy.sh / deploy.ps1
  └─ config_wizard()        → writes config.yaml from config.example.yaml template
  └─ do_login()             → runs a one-off `docker run --rm -it` container to handle OAuth,
                              stores credentials in Docker volume `cli-proxy-manager-auth`
  └─ start_service()        → docker compose up -d using docker-compose.yml
                              polls GET /v1/models to confirm readiness
```

**Configuration flow:**
1. `deploy.sh` / `deploy.ps1` reads `.env` (if present) for `CPA_PORT`, `CPA_API_KEY`, `CPA_MANAGEMENT_KEY`.
2. Config wizard generates `config.yaml` (never committed — in `.gitignore`).
3. `docker-compose.yml` bind-mounts `./config.yaml` into the container at `/CLIProxyAPI/config.yaml` with `create_host_path: false` (prevents Docker auto-creating a directory if the file is missing — a common footgun).
4. OAuth credentials are persisted in the named volume `cli-proxy-manager-auth` (mounted at `/root/.cli-proxy-api` inside the container).

**Docker image:** `eceasy/cli-proxy-api:latest`
**Default port:** `8317` (host-bound to `127.0.0.1` by default via `CPA_BIND_HOST`)
**Container name:** `cli-proxy-manager`
**Auth volume:** `cli-proxy-manager-auth`

**OAuth port quirk:** Codex uses callback port `1455`; all other providers use `51121`. The deploy scripts map the correct port for each provider at login time.

## config.yaml vs config.example.yaml

- `config.example.yaml` — committed template, edit to update defaults.
- `config.yaml` — generated at deploy time, gitignored. Never commit it.
- If `config.yaml` doesn't exist before `docker compose up`, Docker creates a directory with that name instead of a file. The scripts detect and handle this.

## Environment Variables (.env)

Copy `.env.example` to `.env` to override defaults without touching scripts:

| Variable | Default | Notes |
|---|---|---|
| `CPA_BIND_HOST` | `127.0.0.1` | Use `0.0.0.0` only to intentionally expose the proxy |
| `CPA_PORT` | `8317` | Host port |
| `CPA_API_KEY` | *(auto-generated)* | Fixed API key |
| `CPA_MANAGEMENT_KEY` | *(auto-generated)* | Management panel password |

## Useful Prompts

Use these prompts when asking Claude to work on this repository:

- "Check whether the Bash and PowerShell deploy scripts behave the same for start, stop, restart, status, logs, update, and uninstall."
- "Review the README commands against deploy.sh and deploy.ps1, and update any stale instructions."
- "Add a feature to both deploy.sh and deploy.ps1, keeping the user-facing messages and behavior consistent across platforms."
- "Run the release checklist for this repo and tell me what still needs to be fixed before publishing."
- "Investigate why the proxy is not starting, using docker compose status, logs, config.yaml, and the /v1/models health check."
- "Check whether this change could expose the proxy outside localhost or accidentally commit config.yaml/secrets."
- "Improve the Windows PowerShell instructions for users who are not familiar with pwsh or Docker Desktop."
- "Make the English and Chinese README sections consistent without changing the technical meaning."

## Publish Checklist

Before releasing/announcing:
- Confirm repo URLs in `README.md`, `install.sh`, `install.ps1`, and deploy script help text.
- Confirm `config.yaml` is not committed.
- Run the three syntax-check commands above.
- Run `bash deploy.sh status` / `.\deploy.ps1 status` and confirm API test returns `200`.
- Test a fresh clone path.
