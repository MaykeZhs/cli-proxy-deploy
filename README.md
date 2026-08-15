<div align="center">

# 🚀 CLI Proxy Manager

**一键部署和管理 CLIProxyAPI，支持 Antigravity / Claude Code / Gemini CLI / Codex 等 Provider**

**One-click CLIProxyAPI deployment and management for Antigravity / Claude Code / Gemini CLI / Codex providers**

> 本项目不是 Antigravity CLI 本体，也不是官方客户端。它是用于部署、配置和管理 CLIProxyAPI 的辅助工具。
>
> This project is not the Antigravity CLI itself or an official client. It is a helper toolkit for deploying, configuring, and managing CLIProxyAPI.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker&logoColor=white)](docker-compose.yml)
[![CLIProxyAPI](https://img.shields.io/badge/Powered%20by-CLIProxyAPI-orange)](https://github.com/router-for-me/CLIProxyAPI)

[中文](#-快速开始) · [English](#-quick-start) · [Configuration / 配置](#-配置--configuration)

</div>

---

## ✨ 功能特性 / Features

| 功能 / Feature | 说明 / Description |
|---|---|
| 🐳 Docker 一键部署 / One-click Docker deploy | 无需安装 Go 环境，一行命令启动 / No Go required, one command to start |
| 🔐 交互式配置向导 / Interactive wizard | 自动生成配置文件、API 密钥 / Auto-generate config & API keys |
| 🔄 多 Provider 支持 / Multi-provider | Antigravity, Claude Code, Gemini CLI, Codex |
| 🎯 Claude Code for VS Code 适配 / VS Code ready | 开箱即用的环境变量配置 / Ready-to-use env config |
| 📊 管理面板 / Management panel | 内置 Web UI 监控 / Built-in Web UI monitoring |
| 🔁 完整生命周期管理 / Full lifecycle | start / stop / restart / update / uninstall |
| 🩺 一键自检 / One-command doctor | 检查 Docker、配置、凭证和 `/v1/models` / Check Docker, config, credentials, and `/v1/models` |
| 💾 备份恢复 / Backup & restore | 备份 `config.yaml` 和 OAuth 凭证卷 / Back up `config.yaml` and OAuth credential volume |
| 🌉 可选 Sub2API 栈 / Optional Sub2API stack | 独立部署 Sub2API + PostgreSQL + Redis / Isolated Sub2API + PostgreSQL + Redis deployment |
| 🪟 Windows 原生支持 / Windows native | PowerShell 部署脚本 / PowerShell deploy scripts |

实验性 Cursor → API 本地 POC（仅 loopback，不接线上 CPA）：[`poc/cursor-bridge/README.md`](poc/cursor-bridge/README.md)。

可选云端 Cursor Bridge sidecar（不改现网 CPA 容器，经守卫接入）：[`docs/cursor-bridge.md`](docs/cursor-bridge.md)。

---

## 📋 前置要求 / Prerequisites

| 平台 / Platform | 要求 / Requirements |
|---|---|
| **All** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **Linux / macOS** | Bash (built-in) |
| **Windows** | [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`) |

> **开始前 / Before you start:** 请先启动 Docker Desktop，并确认 `docker version` 和 `docker compose version` 都能正常运行。Windows 用户请使用 PowerShell 7 (`pwsh`)，不要使用旧版 Windows PowerShell 5.1。
>
> Start Docker Desktop first and confirm that both `docker version` and `docker compose version` work. On Windows, use PowerShell 7 (`pwsh`), not the older Windows PowerShell 5.1.

---

## 🚀 快速开始


### 方式一：远程一键安装

默认安装到 `~/.cli-proxy-manager`（Windows 为 `%USERPROFILE%\.cli-proxy-manager`），再次运行会自动更新。

**Linux / macOS:**

```bash
# Download the installer and run it with Bash
curl -fsSL https://raw.githubusercontent.com/MaykeZhs/cli-proxy-deploy/main/install.sh | bash
```

**Windows (PowerShell 7+ / pwsh):**

```powershell
# Download the installer to the current folder, then run it
Invoke-WebRequest -Uri https://raw.githubusercontent.com/MaykeZhs/cli-proxy-deploy/main/install.ps1 -OutFile install.ps1; .\install.ps1
```

> 如果执行策略阻止脚本，请使用：`pwsh -ExecutionPolicy Bypass -File .\install.ps1`

### 方式二：手动安装

**Linux / macOS:**

```bash
# Download the project
git clone https://github.com/MaykeZhs/cli-proxy-deploy.git

# Enter the project folder
cd cli-proxy-deploy

# Start the interactive deployment
bash deploy.sh
```

**Windows (PowerShell 7+ / pwsh):**

```powershell
# Download the project
git clone https://github.com/MaykeZhs/cli-proxy-deploy.git

# Enter the project folder
cd cli-proxy-deploy

# Start the interactive deployment
.\deploy.ps1
```

> 如果执行策略阻止脚本：`pwsh -ExecutionPolicy Bypass -File .\deploy.ps1`

部署脚本会引导你完成：

1. ✅ 检查 Docker 环境
2. ✅ 交互式配置（端口、API 密钥、管理面板）
3. ✅ 选择 Provider 并完成 OAuth 登录
4. ✅ 启动代理服务
5. ✅ 输出 Claude Code for VS Code 配置

> **提示 / Tip:** 部署完成后运行 `bash deploy.sh setup-claude` / `.\deploy.ps1 setup-claude` 可一键写入 Claude Code CLI 配置。

> **首次部署 vs 日常管理：** 如果已有 `config.yaml`，`bash deploy.sh` / `.\deploy.ps1`（不带参数）会先询问"重新配置"或"保留并仅启动"，默认保留现有配置和全部 API key。

---

## 🚀 Quick Start

### Option 1: Remote One-Click Install

Installs to `~/.cli-proxy-manager` (Windows: `%USERPROFILE%\.cli-proxy-manager`). Running again auto-updates.

**Linux / macOS:**

```bash
# Download the installer and run it with Bash
curl -fsSL https://raw.githubusercontent.com/MaykeZhs/cli-proxy-deploy/main/install.sh | bash
```

**Windows (PowerShell 7+ / pwsh):**

```powershell
# Download the installer to the current folder, then run it
Invoke-WebRequest -Uri https://raw.githubusercontent.com/MaykeZhs/cli-proxy-deploy/main/install.ps1 -OutFile install.ps1; .\install.ps1
```

> If the execution policy blocks the script: `pwsh -ExecutionPolicy Bypass -File .\install.ps1`

### Option 2: Manual Install

**Linux / macOS:**

```bash
# Download the project
git clone https://github.com/MaykeZhs/cli-proxy-deploy.git

# Enter the project folder
cd cli-proxy-deploy

# Start the interactive deployment
bash deploy.sh
```

**Windows (PowerShell 7+ / pwsh):**

```powershell
# Download the project
git clone https://github.com/MaykeZhs/cli-proxy-deploy.git

# Enter the project folder
cd cli-proxy-deploy

# Start the interactive deployment
.\deploy.ps1
```

> If the execution policy blocks the script: `pwsh -ExecutionPolicy Bypass -File .\deploy.ps1`

The deployment script will guide you through:

1. ✅ Docker environment check
2. ✅ Interactive configuration (port, API key, management panel)
3. ✅ Provider selection & OAuth login
4. ✅ Start the proxy service
5. ✅ Output Claude Code for VS Code configuration

> **Tip:** After deployment, run `bash deploy.sh setup-claude` / `.\deploy.ps1 setup-claude` to auto-configure Claude Code CLI.

> **First deploy vs daily use:** If `config.yaml` already exists, running without arguments asks whether to reconfigure or preserve and start. The default is to preserve your existing config and all API keys.

---

## ✅ 验证部署 / Verify Deployment

启动后先运行 `doctor`。它会检查 Docker、容器、`config.yaml`、端口、OAuth 凭证，以及 `/v1/models` 是否返回非空模型列表。

After startup, run `doctor` first. It checks Docker, the container, `config.yaml`, port mapping, OAuth credentials, and whether `/v1/models` returns a non-empty model list.

**Linux / macOS:**

```bash
cd cli-proxy-deploy
bash deploy.sh doctor

# Service status and loaded credentials
bash deploy.sh status

# Docker container status
docker compose -f docker-compose.yml ps

# Config must be a file inside the container, not a directory
docker compose -f docker-compose.yml exec -T cliproxyapi sh -lc \
'test -f /CLIProxyAPI/config.yaml && ls -l /CLIProxyAPI/config.yaml'

# API model list
API_KEY=$(awk -F'"' '/^[[:space:]]*-[[:space:]]*"/{print $2; exit}' config.yaml)
curl -i http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer ${API_KEY}"
```

**Windows (PowerShell):**

```powershell
cd cli-proxy-deploy
.\deploy.ps1 doctor

# Service status and loaded credentials
.\deploy.ps1 status

# Docker container status
docker compose -f docker-compose.yml ps

# Config must be a file inside the container, not a directory
docker compose -f docker-compose.yml exec -T cliproxyapi sh -lc "test -f /CLIProxyAPI/config.yaml && ls -l /CLIProxyAPI/config.yaml"

# API model list
$apiKey = (Select-String -Path config.yaml -Pattern '^\s*-\s*"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value
Invoke-WebRequest -Uri "http://127.0.0.1:8317/v1/models" `
  -Headers @{ Authorization = "Bearer $apiKey" }
```

成功时 `/v1/models` 会返回真实模型列表，而不是空数组：

On success, `/v1/models` returns real model IDs instead of an empty list:

```json
{
  "object": "list",
  "data": [
    { "id": "claude-sonnet-4-6", "owned_by": "antigravity" }
  ]
}
```

---

## 🧭 部署后如何使用 / How to Use After Deployment

部署完成后，你会得到两个关键信息：

After deployment, you need two values:

| 项目 / Item | 默认值 / Default | 说明 / Description |
|---|---|---|
| Base URL | `http://127.0.0.1:8317` | CLIProxyAPI endpoint |
| API Key | `config.yaml` 里的 `api-keys` | Client authentication token |

> **示例中的占位符 / Placeholders in examples**
>
> - 将 `your-api-key` 替换为 `config.yaml` 中的真实 API Key。Replace `your-api-key` with the real API key from `config.yaml`.
> - 将 `user@your-server` 替换为远程服务器的 SSH 用户名和地址。Replace `user@your-server` with your remote server's SSH user and address.
> - 模型名称只是示例；请优先使用 `/v1/models` 返回的模型 `id`。Model names are examples; prefer an exact model `id` returned by `/v1/models`.
> - Linux/macOS 示例使用 `${API_KEY}`；PowerShell 示例使用 `$apiKey`。These variable names are platform-specific.

### 1. 获取 API Key / Get the API Key

**Linux / macOS:**

```bash
# Read the first API key from config.yaml and save it in this shell
API_KEY=$(awk -F'"' '/^[[:space:]]*-[[:space:]]*"/{print $2; exit}' config.yaml)

# Print the value so you can confirm it was loaded
echo "$API_KEY"
```

**Windows (PowerShell):**

```powershell
# Read the first API key from config.yaml and save it in this PowerShell session
$apiKey = (Select-String -Path config.yaml -Pattern '^\s*-\s*"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value

# Print the value so you can confirm it was loaded
$apiKey
```

### 2. 查看可用模型 / List Available Models

Use this first. The model IDs returned here are the safest values to use in clients.

**Linux / macOS:**

```bash
curl http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer ${API_KEY}"
```

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri "http://127.0.0.1:8317/v1/models" `
  -Headers @{ Authorization = "Bearer $apiKey" }
```

### 3. 发送测试请求 / Send a Test Request

**OpenAI-compatible `/v1/chat/completions`:**

```bash
curl http://127.0.0.1:8317/v1/chat/completions \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [
      { "role": "user", "content": "Say hello in one sentence." }
    ],
    "stream": false
  }'
```

**Anthropic-compatible `/v1/messages`:**

```bash
curl http://127.0.0.1:8317/v1/messages \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 256,
    "messages": [
      { "role": "user", "content": "Say hello in one sentence." }
    ]
  }'
```

Replace `claude-sonnet-4-6` with a model ID returned by `/v1/models`.

### 4. 配置客户端 / Configure Clients

For Claude Code, Cursor, or other Anthropic-compatible tools:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8317"
export ANTHROPIC_AUTH_TOKEN="${API_KEY}"
```

For OpenAI-compatible clients, use:

```bash
export OPENAI_BASE_URL="http://127.0.0.1:8317/v1"
export OPENAI_API_KEY="${API_KEY}"
```

On Windows PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
$env:ANTHROPIC_AUTH_TOKEN = $apiKey
$env:OPENAI_BASE_URL = "http://127.0.0.1:8317/v1"
$env:OPENAI_API_KEY = $apiKey
```

### 5. 远程服务器使用 / Use from a Remote Server

For security, keep the proxy bound to localhost and use SSH port forwarding from your local machine:

```bash
# Run this on your local computer and keep the terminal open
# Local port 8317 will forward to port 8317 on the remote server
ssh -L 8317:127.0.0.1:8317 user@your-server -p 22
```

Then your local client can still use:

```text
http://127.0.0.1:8317
```

### 6. 常见问题 / Common Checks

- `401` means the client API key is wrong. Check `config.yaml`.
- Empty `/v1/models` usually means OAuth login did not finish or no credential was loaded. Run `.\deploy.ps1 login` / `bash deploy.sh login`.
- Connection refused means the service is not running or the port is different. Run `.\deploy.ps1 status` / `bash deploy.sh status`.
- If the proxy runs on a server, do not use the server IP directly unless you intentionally expose the port. Prefer SSH forwarding.

---

## ⚙️ 配置 / Configuration

### Claude Code for VS Code

部署完成后，在 VS Code `settings.json` 中添加：

After deployment, add to your VS Code `settings.json`:

```json
{
  "claude-code.env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
    "ANTHROPIC_AUTH_TOKEN": "your-api-key",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7"
  }
}
```

或者在 `~/.zshrc` / `~/.bashrc` 中添加 / Or add to your shell profile:

**Linux / macOS:**

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8317"
export ANTHROPIC_AUTH_TOKEN="your-api-key"
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-7"
```

**Windows (PowerShell profile):**

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
$env:ANTHROPIC_AUTH_TOKEN = "your-api-key"
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-4-6"
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-4-7"
```

### 指定模型 / Specify Models (Claude Code v2.x.x)

先用 `/v1/models` 查看当前账号可用模型，然后使用返回的精确 `id`：

First check available models with `/v1/models`, then use the exact returned `id`:

```bash
# Claude-compatible models via Antigravity
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-7"

# Gemini models can also be used if your client supports the selected model id
export ANTHROPIC_DEFAULT_SONNET_MODEL="gemini-3-flash"
```

---

## 📋 命令参考 / Command Reference

| 命令 / Command | Linux / macOS | Windows |
|---|---|---|
| 交互式完整部署 / Full interactive deployment | `bash deploy.sh` | `.\deploy.ps1` |
| OAuth 登录 Provider / OAuth login | `bash deploy.sh login` | `.\deploy.ps1 login` |
| 退出 Provider 账号 / Logout provider | `bash deploy.sh logout` | `.\deploy.ps1 logout` |
| 启动服务 / Start service | `bash deploy.sh start` | `.\deploy.ps1 start` |
| 停止服务 / Stop service | `bash deploy.sh stop` | `.\deploy.ps1 stop` |
| 重启服务 / Restart service | `bash deploy.sh restart` | `.\deploy.ps1 restart` |
| 查看状态 / Check status | `bash deploy.sh status` | `.\deploy.ps1 status` |
| 实时日志 / Real-time logs | `bash deploy.sh logs` | `.\deploy.ps1 logs` |
| 只读能力检查 / Read-only capabilities | `bash deploy.sh capabilities [--json]` | `.\deploy.ps1 capabilities [--json]` |
| 一键自检 / Doctor check | `bash deploy.sh doctor` | `.\deploy.ps1 doctor` |
| 备份配置和凭证 / Backup config and credentials | `bash deploy.sh backup` | `.\deploy.ps1 backup` |
| 恢复配置和凭证 / Restore config and credentials | `bash deploy.sh restore <file>` | `.\deploy.ps1 restore <file>` |
| 检查镜像更新 / Check image update | `bash deploy.sh check-update` | `.\deploy.ps1 check-update` |
| 更新到最新版 / Update to latest | `bash deploy.sh update` | `.\deploy.ps1 update` |
| 回滚到上一个镜像 / Roll back image | `bash deploy.sh rollback` | `.\deploy.ps1 rollback` |
| 有新镜像时才更新 / Update only if needed | `bash deploy.sh auto-update` | — |
| 启用自动更新 / Enable auto-update | `bash deploy.sh enable-auto-update [计划]` | — |
| 查看自动更新状态 / Auto-update status | `bash deploy.sh auto-update-status` | — |
| 禁用自动更新 / Disable auto-update | `bash deploy.sh disable-auto-update` | — |
| Sub2API 一键部署 / Deploy Sub2API | `bash deploy.sh sub2api deploy` | `.\deploy.ps1 sub2api deploy` |
| Sub2API 启动 / Start Sub2API | `bash deploy.sh sub2api start` | `.\deploy.ps1 sub2api start` |
| Sub2API 停止 / Stop Sub2API | `bash deploy.sh sub2api stop` | `.\deploy.ps1 sub2api stop` |
| Sub2API 重建 / Recreate Sub2API | `bash deploy.sh sub2api restart` | `.\deploy.ps1 sub2api restart` |
| Sub2API 状态 / Sub2API status | `bash deploy.sh sub2api status` | `.\deploy.ps1 sub2api status` |
| Sub2API 日志 / Sub2API logs | `bash deploy.sh sub2api logs` | `.\deploy.ps1 sub2api logs` |
| Sub2API 更新 / Update Sub2API | `bash deploy.sh sub2api update` | `.\deploy.ps1 sub2api update` |
| Sub2API 自检 / Sub2API doctor | `bash deploy.sh sub2api doctor` | `.\deploy.ps1 sub2api doctor` |
| Sub2API 卸载 / Uninstall Sub2API | `bash deploy.sh sub2api uninstall` | `.\deploy.ps1 sub2api uninstall` |
| 完全卸载 / Full uninstall | `bash deploy.sh uninstall` | `.\deploy.ps1 uninstall` |
| 配置 Claude Code / Setup Claude Code | `bash deploy.sh setup-claude` | `.\deploy.ps1 setup-claude` |
| 显示帮助 / Show help | `bash deploy.sh help` | `.\deploy.ps1 help` |

### 更新 Docker 镜像 / Update Docker Image

先用 `check-update` 只检查远端镜像 digest，不下载镜像层；确认有新版本后再运行 `update`。

Use `check-update` to compare the remote image digest without downloading image layers. Run `update` only when a newer image is available.

**Linux / macOS:**

```bash
# Check metadata only; no image layers are downloaded
bash deploy.sh check-update

# Save the current image, pull latest, recreate, and run a health check
bash deploy.sh update

# Switch to the image saved before the last update
bash deploy.sh rollback

# Cron-safe update: only pulls and recreates when the remote image digest changed
bash deploy.sh auto-update

# Enable daily auto-update at 04:20 and write logs to logs/auto-update.log
bash deploy.sh enable-auto-update

# Schedule aliases: daily, 12h, 6h, hourly, weekly
bash deploy.sh enable-auto-update 12h

# Or use a custom cron schedule
bash deploy.sh enable-auto-update "20 4 * * *"

# Show schedule and recent auto-update logs
bash deploy.sh auto-update-status

# Disable the managed auto-update cron entry
bash deploy.sh disable-auto-update

# Verify the updated service is running
bash deploy.sh status
```

`update` and `auto-update` first tag the currently running image as `eceasy/cli-proxy-api:rollback`. After the new container starts, they require `/v1/models` to respond successfully. If startup or the health check fails, the script automatically restores the saved image and recreates the container. The rollback tag is not removed by `docker image prune`.

When `auto-update` rejects an image, it records that remote digest and skips it on later scheduled runs. On Linux/macOS, a manual `rollback` also marks the image being left. The updater tries again automatically after the publisher provides a different digest. A manual `update` still lets an operator retry immediately.

`rollback` manually swaps the current and saved images, recreates the service, and runs the same health check. Because the two image tags are swapped, running `rollback` again switches back. Only one previous image is kept; configuration and OAuth credential data are not changed.

`auto-update` is designed for cron. It compares the local and remote Docker image digest first. If they match, it exits without pulling, recreating, or restarting the container. `enable-auto-update` accepts schedule aliases (`daily`, `12h`, `6h`, `hourly`, `weekly`) or a custom 5-field cron expression, and writes a marked crontab block so running it again safely replaces the previous schedule without touching your other cron jobs. Use `auto-update-status` to view the current schedule and recent logs.

The scheduling commands, `enable-auto-update` and `disable-auto-update`, are Linux/macOS only because they use `crontab`.

**Windows (PowerShell):**

```powershell
# Check metadata only; no image layers are downloaded
.\deploy.ps1 check-update

# Save the current image, pull latest, recreate, and run a health check
.\deploy.ps1 update

# Switch to the image saved before the last update
.\deploy.ps1 rollback

# Verify the updated service is running
.\deploy.ps1 status
```

### 自检、备份和恢复 / Doctor, Backup, and Restore

`capabilities` 是严格只读探针：它不会拉取镜像、创建辅助容器、启动/停止服务、打开浏览器或修改配置。它只输出 Provider 数量和脱敏后的插件摘要，不输出凭证文件名、邮箱、账号/模型 ID、插件配置、密钥或哈希。

`capabilities` is a strictly read-only probe. It does not pull images, create helper containers, change service state, open a browser, or edit configuration. It uses local GET requests only. It reports provider and plugin summaries plus redacted routing booleans, never credential filenames, emails, account/model IDs, priority/weight values, plugin configuration, keys, or hashes.

```bash
bash deploy.sh capabilities
bash deploy.sh capabilities --json
```

```powershell
.\deploy.ps1 capabilities
.\deploy.ps1 capabilities --json
```

The JSON contract uses `schema_version: 1`. Unavailable values are `null`. Both scripts use the same top-level objects:

| Object | Fields |
|---|---|
| `manager` | Manager script `version` |
| `container` | Container `name` and `running` state |
| `network` | Configured/actual address and port, plus `exposure_mode` |
| `image` | Image reference, local image ID, and local repository digest |
| `cpa` | CPA version and commit from safe startup-log parsing or authenticated CPA response headers |
| `release_contract` | Exact CPA v7.2.111 and Management Center v1.20.4 tag commits, source, target-pair compatibility, and observed runtime compatibility |
| `api` | Health status, HTTP status codes, and model count only |
| `remote_management` | Enabled settings as booleans; no key or hash |
| `management_ui` | Enabled/reachable state, safely detected Management Center version, HTTP status, safe loopback URL, remote-access setting, external HTTPS verification, and public warning state |
| `official_capabilities` | Audited Management API, auth-files, account-status, priority, quota-reset, routing, and plugin support flags |
| `routing` | Strategy, WRR/priority/weight configuration booleans, session-affinity state and TTL, automatic-failover support, and WRR traffic-validation state |
| `plugins` | Authenticated inspection state and safe plugin ID/name/version/enabled/menu-count fields only |
| `security` | Whether plugin resource pages use management authentication and whether direct-public exposure is critical |
| `credentials` | API-first provider counts for Antigravity, Claude, Codex, Gemini, Kimi, xAI, and future types; filename counting is a labeled fallback |
| `recovery` | Latest CPA backup time and previous-image availability |
| `warnings` | Stable warning code, severity (`warning`, `critical`, or `failure`), and safe message |

The D2.2 source contract is pinned to [CLIProxyAPI v7.2.111 at `4a31513`](https://github.com/router-for-me/CLIProxyAPI/commit/4a315136730baa8b3a436d12b74e5a702c70be5c) and [Management Center v1.20.4 at `826ea3c`](https://github.com/router-for-me/Cli-Proxy-API-Management-Center/commit/826ea3c0d0bdd6409a0a2703ada90faaf5aede2d), not newer default branches. `wrr_traffic_validation` remains `not_run`; capability support is not traffic acceptance, especially when no credentials or models exist.

Exposure modes are `local`, `direct-public`, `public-proxy`, or `unknown`. `public-proxy` requires a loopback binding plus the optional read-only hint `CPA_EXPOSURE_MODE=public-proxy`; this hint never changes Docker networking.

External HTTPS protection is `null` when the local probe cannot verify it. The probe never treats `CPA_EXPOSURE_MODE=public-proxy` as proof that HTTPS exists.

When a plaintext `CPA_MANAGEMENT_KEY` is available in the process environment or the local `.env`, the probe uses authenticated read-only GET requests to `/v0/management/auth-files`, `/v0/management/plugins`, and `/v0/management/routing/strategy`. If the key is unavailable, it does not call protected Management API routes. Provider counts may then use the clearly marked `filename_fallback`; plugin inventory stays unavailable.

Write-capability flags are contract information only. For the audited CLIProxyAPI `v7.2.102` build (`8423cce`), the probe can report priority-write and quota-reset support without sending a write request. It never sends POST, PUT, PATCH, or DELETE.

Security note: in the audited `v7.2.102` route contract, plugin resource pages under `/v0/resource/plugins/...` are outside Management API authentication. Doctor reports a critical warning when those pages and remote management are exposed through direct-public HTTP.

`doctor` reuses the same probe and adds clear pass, warning, and failure messages for Docker, Compose, configuration, the actual port binding, recovery, and the local CPA API.

```bash
bash deploy.sh doctor
```

```powershell
.\deploy.ps1 doctor
```

`backup` 默认写入 `backups/cli-proxy-manager-backup-YYYYmmdd-HHMMSS.tgz`，包含 `config.yaml` 和 Docker volume `cli-proxy-manager-auth` 中的 OAuth 凭证（如果存在）。`backups/` 已被 `.gitignore` 忽略。

`backup` writes to `backups/cli-proxy-manager-backup-YYYYmmdd-HHMMSS.tgz` by default. It includes `config.yaml` and OAuth credentials from the Docker volume `cli-proxy-manager-auth` when present. `backups/` is ignored by Git.

```bash
bash deploy.sh backup
bash deploy.sh backup backups/before-upgrade.tgz
bash deploy.sh restore backups/before-upgrade.tgz
```

```powershell
.\deploy.ps1 backup
.\deploy.ps1 backup backups\before-upgrade.tgz
.\deploy.ps1 restore backups\before-upgrade.tgz
```

Recommended times to back up:

- Before `uninstall`
- Before moving to a new machine
- Before testing a risky config change
- Before updating the Docker image

### 环境变量 / Environment Variables

复制 `.env.example` 为 `.env` 即可覆盖默认配置，无需修改脚本或 `docker-compose.yml`。

Copy `.env.example` to `.env` to override defaults without editing scripts or `docker-compose.yml`.

```bash
cp .env.example .env
```

| 变量 / Variable | 默认值 / Default | 说明 / Description |
|---|---|---|
| `CPA_BIND_HOST` | `127.0.0.1` | 监听地址。本机使用保持默认；云服务器需外部访问时改为 `0.0.0.0` / Bind address. Keep default for local; set `0.0.0.0` to expose on cloud servers |
| `CPA_EXPOSURE_MODE` | *(auto-detected)* | 可选只读分类提示。CPA 绑定 loopback 并位于 HTTPS 反向代理后时设为 `public-proxy`；不会修改端口 / Optional read-only classification hint; use `public-proxy` only for loopback CPA behind an HTTPS reverse proxy |
| `CPA_PORT` | `8317` | 服务端口 / Service port |
| `CPA_IMAGE` | `eceasy/cli-proxy-api:latest` | 容器镜像；Docker Hub 不可用时可改为可信镜像代理 / Container image; may use a trusted registry proxy when Docker Hub is unavailable |
| `CPA_PULL_POLICY` | `always` | 直接运行 Compose 时检查并拉取镜像；部署脚本会先显式拉取，成功后以 `never` 启动，事务更新和回滚也使用 `never` / Direct Compose starts pull first; deploy scripts explicitly pull before starting with `never`, and transactional update/rollback also use `never` |

| `CPA_API_KEY` | *(auto-generated)* | API 密钥 / API key |

| `CPA_MANAGEMENT_KEY` | *(auto-generated)* | 管理面板密码 / Management panel password |

> **注意 / Note:** `CPA_API_KEY` 和 `CPA_MANAGEMENT_KEY` 仅在配置向导生成 `config.yaml` 时写入。如果 `config.yaml` 已存在，修改 `.env` 中的这两个值不会自动更新配置文件，需要手动编辑 `config.yaml` 或重新运行完整部署。
>
> `CPA_API_KEY` and `CPA_MANAGEMENT_KEY` are only written into `config.yaml` during the config wizard. Changing them in `.env` after `config.yaml` already exists has no effect — edit `config.yaml` directly or re-run the full deploy.

> **安全提醒 / Security note:** 将 `CPA_BIND_HOST` 设为 `0.0.0.0` 会对外暴露代理，请确保设置强 API Key 并通过防火墙/安全组限制端口访问。
>
> Setting `CPA_BIND_HOST` to `0.0.0.0` exposes the proxy externally. Make sure you use a strong API key and restrict port access via firewall or security groups.

**修改 `.env` 后需要重建容器（`restart` 不会更新端口绑定）：**

**After changing `.env`, recreate the container (`restart` does not update port bindings):**

```bash
bash deploy.sh stop && bash deploy.sh start
```

```powershell
.\deploy.ps1 stop; .\deploy.ps1 start
```

```bash
# 自定义端口启动 / Start with custom port
CPA_PORT=9000 bash deploy.sh start
```

**Windows:**

```powershell
# 自定义端口启动 / Start with custom port
$env:CPA_PORT=9000; .\deploy.ps1 start
```

### 可选 Sub2API 一键部署 / Optional Sub2API One-Click Deployment

本项目可以把 [Sub2API](https://github.com/Wei-Shaw/sub2api) 作为**独立 companion stack** 按需部署。它不会加入 CLIProxyAPI 的 Compose project，也不会读取 `config.yaml` 或 OAuth 凭证卷。PostgreSQL 和 Redis 可以分别选择由本项目托管，或连接外部服务。

This project can deploy [Sub2API](https://github.com/Wei-Shaw/sub2api) as an **isolated, on-demand companion stack**. It does not join the CLIProxyAPI Compose project and does not read `config.yaml` or the OAuth credential volume. PostgreSQL and Redis can each be managed by this project or supplied as an external service.

- `sub2api-manager` — Sub2API Web/API service
- `sub2api-manager-postgres` — optional managed PostgreSQL 18 database
- `sub2api-manager-redis` — optional managed Redis 8 cache
- Named volumes for the application and any managed dependencies

首次运行会生成 Git 忽略的 `sub2api.env`，其中包含 PostgreSQL、Redis、管理员、JWT 和 TOTP 密钥。默认自动部署 PostgreSQL 和 Redis，并从 `8321`、`18321`、`28321`、`38321`、`48321` 中选择第一个空闲宿主端口。Sub2API 容器内部仍使用官方端口 `8080`，不会占用宿主机的 `8080`。PostgreSQL 和 Redis 不会映射到宿主机端口。

On first run, the script creates a Git-ignored `sub2api.env` with PostgreSQL, Redis, admin, JWT, and TOTP secrets. It manages both dependencies by default and selects the first free host port from `8321`, `18321`, `28321`, `38321`, and `48321`. The container still uses the official internal port `8080`; host port `8080` is not used. PostgreSQL and Redis are not published to host ports.

**Linux / macOS:**

```bash
bash deploy.sh sub2api deploy
bash deploy.sh sub2api status
```

**Windows (PowerShell 7+):**

```powershell
.\deploy.ps1 sub2api deploy
.\deploy.ps1 sub2api status
```

如果要在第一次启动前选择混合依赖模式，先只生成安全配置，再编辑并部署：

```bash
bash deploy.sh sub2api init
nano sub2api.env
bash deploy.sh sub2api deploy
```

```powershell
.\deploy.ps1 sub2api init
notepad sub2api.env
.\deploy.ps1 sub2api deploy
```

首次部署成功后，终端会显示自动生成的管理员密码。以后可以在本机的 `sub2api.env` 中查看或修改管理员邮箱、端口、依赖模式和连接信息。修改后运行 `sub2api restart` 重建容器。

After the first successful deployment, the terminal shows the generated admin password. Later, edit the local `sub2api.env` to change the admin email, port, dependency modes, or connection settings, then run `sub2api restart` to recreate the containers.

```dotenv
# Local-only by default
SUB2API_BIND_HOST=127.0.0.1
SUB2API_PORT=8321

# Use 0.0.0.0 only behind a firewall and HTTPS reverse proxy
# SUB2API_BIND_HOST=0.0.0.0
```

PostgreSQL 和 Redis 的模式互相独立，因此支持四种组合：

| PostgreSQL | Redis | Result |
|---|---|---|
| `managed` | `managed` | 默认；自动部署两个依赖 |
| `managed` | `external` | 只自动部署 PostgreSQL，连接外部 Redis |
| `external` | `managed` | 连接外部 PostgreSQL，只自动部署 Redis |
| `external` | `external` | 两个依赖都由服务器或其他平台提供 |

例如，只部署 PostgreSQL，并连接服务器已有的 Redis：

```dotenv
SUB2API_POSTGRES_MODE=managed
SUB2API_DATABASE_HOST=postgres

SUB2API_REDIS_MODE=external
SUB2API_REDIS_HOST=host.docker.internal
SUB2API_REDIS_PORT=6379
SUB2API_REDIS_PASSWORD=your-existing-redis-password
SUB2API_REDIS_DB=0
```

例如，只部署 Redis，并连接外部 PostgreSQL：

```dotenv
SUB2API_POSTGRES_MODE=external
SUB2API_DATABASE_HOST=host.docker.internal
SUB2API_DATABASE_PORT=5432
SUB2API_POSTGRES_USER=sub2api
SUB2API_POSTGRES_PASSWORD=your-existing-postgres-password
SUB2API_POSTGRES_DB=sub2api
SUB2API_DATABASE_SSLMODE=disable

SUB2API_REDIS_MODE=managed
SUB2API_REDIS_HOST=redis
```

如果外部服务直接安装在同一台 Docker 宿主机上，使用 `host.docker.internal`，不要使用 `127.0.0.1` 或 `localhost`，因为容器中的 localhost 指向容器自己。远程数据库则直接填写内网 IP 或域名。当前官方 Sub2API 部署要求 PostgreSQL；MySQL 不能直接替代。

If an external service runs directly on the Docker host, use `host.docker.internal`, not `127.0.0.1` or `localhost`, because localhost inside the container means the container itself. For a remote service, enter its private IP address or DNS name. The current official Sub2API deployment requires PostgreSQL; MySQL is not a drop-in replacement.

For public API access, keep `SUB2API_BIND_HOST=127.0.0.1` and proxy an HTTPS domain to the selected local port with Nginx or Caddy. Set `0.0.0.0` only when direct port access is intentional and protected by a firewall.

Minimal Nginx example (replace the domain and port with your real values):

```nginx
server {
    listen 443 ssl;
    server_name sub2api.example.com;

    location / {
        proxy_pass http://127.0.0.1:8321;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Update the complete stack with:

```bash
bash deploy.sh sub2api update
```

```powershell
.\deploy.ps1 sub2api update
```

`sub2api uninstall` removes containers and the private network first. It asks separately before deleting the application and managed dependency volumes or `sub2api.env`, so normal uninstall does not silently delete data.

The Compose contract follows the official Sub2API deployment: `AUTO_SETUP=true`, PostgreSQL, Redis, stable JWT/TOTP secrets, and the `/health` health check. The local integration uses named volumes instead of host directories for more consistent behavior across Docker Desktop and Linux.

### 管理面板 / Management Panel

部署时配置向导会询问是否启用管理面板并生成密码。启用后可通过 Web UI 查看代理状态。

The deploy wizard asks whether to enable the management panel and generates a password. Once enabled, you can monitor proxy status via a Web UI.

**访问地址 / Access URL:**

```
http://127.0.0.1:8317/management.html
```

**密码 / Password:** 部署时显示的 `CPA_MANAGEMENT_KEY`，也保存在 `config.yaml` 的 `remote-management.secret-key` 中。

The password is the `CPA_MANAGEMENT_KEY` shown during deployment, also stored in `config.yaml` under `remote-management.secret-key`.

### 一键配置 Claude Code / Setup Claude Code

部署完成后，运行 `setup-claude` 自动将代理地址和 API Key 写入 Claude Code CLI 的全局配置（`~/.claude/settings.json`），同时启用 [Everything Claude Code (ECC)](https://github.com/affaan-m/everything-claude-code) 插件市场。

After deployment, run `setup-claude` to automatically write the proxy URL and API key into Claude Code CLI's global config (`~/.claude/settings.json`), and enable the [Everything Claude Code (ECC)](https://github.com/affaan-m/everything-claude-code) plugin marketplace.

**Linux / macOS:**

```bash
bash deploy.sh setup-claude
```

**Windows (PowerShell):**

```powershell
.\deploy.ps1 setup-claude
```

运行后无需手动设置环境变量或编辑 VS Code 配置，直接在终端运行 `claude` 即可使用代理。

After running, you can use `claude` directly in the terminal without manually setting environment variables or editing VS Code settings.

---

## 🏗️ 项目结构 / Project Structure

```
cli-proxy-deploy/
├── deploy.sh              # 主部署脚本 (Linux/macOS) / Main deployment script
├── deploy.ps1             # 主部署脚本 (Windows) / Main deployment script (Windows)
├── install.sh             # 远程安装脚本 (Linux/macOS) / Remote installer
├── install.ps1            # 远程安装脚本 (Windows) / Remote installer (Windows)
├── docker-compose.yml     # 基础 Docker 编排 / Base Docker Compose
├── docker-compose.sub2api.yml # 独立 Sub2API stack / Isolated Sub2API stack
├── docker-compose.cursor-bridge.yml # 可选 Cursor Bridge sidecar / Optional Cursor Bridge sidecar
├── cursor-bridge.env.example # Cursor Bridge 非敏感模板 / Non-secret Cursor Bridge template
├── cursor-bridge/         # 守卫配置 / Guard config
├── config.example.yaml    # 配置模板 / Config template
├── .env.example           # 可选环境变量示例 / Optional env example
├── sub2api.env.example    # Sub2API 非敏感模板 / Non-secret Sub2API template
├── .claude/settings.json  # Claude Code 共享配置 (ECC) / Shared Claude Code config
├── SECURITY.md            # 安全说明 / Security notes
├── LICENSE
└── README.md
```

---

## 🧯 常见问题 / Troubleshooting

First run:

```bash
bash deploy.sh doctor
```

```powershell
.\deploy.ps1 doctor
```

This usually points to the exact broken layer before you inspect logs manually.

<details>
<summary><b>Codex OAuth authentication fails</b></summary>

Codex uses a different local OAuth callback port from Antigravity. CLIProxyAPI's Codex OAuth flow uses port `1455`, so this project maps `1455:1455` only for Codex login.

If the terminal asks you to paste the callback URL, paste the callback URL from the same login attempt. The `state=...` value must match the auth URL printed by that current run. Do not reuse a callback URL from a previous attempt.

Use Bash to run the script:

```bash
bash deploy.sh login
```

Do not paste OAuth callback URLs into public issues or screenshots because the `code=...` value is sensitive.

</details>

<details>
<summary><b>container name "/cli-proxy-manager" is already in use</b></summary>

这通常发生在你重命名项目目录、复制项目目录，或从另一个 Compose project 启动过同一个容器名之后。`docker ps` 只显示运行中的容器，所以冲突容器可能是 stopped 状态。

This usually happens after renaming/copying the project folder or starting the same container from a different Compose project. `docker ps` only shows running containers, so the conflicting container may be stopped.

```bash
docker ps -a --filter name=cli-proxy-manager
docker rm cli-proxy-manager
docker compose up -d
```

**Windows:**

```powershell
docker ps -a --filter name=cli-proxy-manager
docker rm cli-proxy-manager
docker compose up -d
```

如果你想保留 OAuth 登录状态，不要删除 `cli-proxy-manager-auth` volume。

Do not remove the `cli-proxy-manager-auth` volume if you want to keep OAuth credentials.

If Docker shows a warning that this volume was created for another project name, it is usually safe to keep using it. The warning means Compose is reusing the existing credential volume.

</details>

<details>
<summary><b>config.yaml: is a directory</b></summary>

这通常是因为在 `config.yaml` 文件存在前直接运行了 `docker compose up`，Docker 自动创建了同名目录。

This usually happens when `docker compose up` is run before the real `config.yaml` file exists.

```bash
docker compose down
rmdir config.yaml
bash deploy.sh
```

**Windows:**

```powershell
docker compose down
Remove-Item config.yaml
.\deploy.ps1
```

`deploy.sh` 也会自动检测并提示删除空目录。

</details>

<details>
<summary><b>/v1/models returns {"data":[]}</b></summary>

代理服务已经启动，但还没有加载 OAuth 凭证。运行：

The proxy is running, but no OAuth credential has been loaded yet. Run:

**Linux / macOS:**

```bash
bash deploy.sh login
bash deploy.sh status
```

**Windows:**

```powershell
.\deploy.ps1 login
.\deploy.ps1 status
```

看到 `已登录凭证` 或 `loaded 1 file-based clients` 后，再请求 `/v1/models`。

</details>

<details>
<summary><b>OAuth login URL appears in the terminal</b></summary>

这是正常行为。登录容器运行在 Docker 中，不能稳定地自动打开 macOS 浏览器。复制终端中的 URL 到浏览器完成授权即可。

This is expected. The one-off login container runs inside Docker, so it prints a URL instead of opening your macOS browser directly.

</details>

---

## 🔧 高级配置 / Advanced Configuration

<details>
<summary><b>自定义 config.yaml / Custom config.yaml</b></summary>

部署脚本会自动生成 `config.yaml`，你也可以基于 `config.example.yaml` 手动编辑：

The deploy script auto-generates `config.yaml`. You can also manually edit based on `config.example.yaml`:

```yaml
# Empty means the app uses its default bind address inside the container
host: ""

# Internal service port; normally keep this value unchanged
port: 8317

# OAuth credential folder inside the container
auth-dir: "/root/.cli-proxy-api"

# Keys that clients must send in the Authorization header
api-keys:
  - "your-custom-key"

# Enable only when you need detailed troubleshooting logs
debug: false

# Retry temporary upstream request failures up to three times
request-retry: 3
max-retry-interval: 30

# Decide when the proxy may switch account/project or model
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true

# Share requests across multiple logged-in accounts
routing:
  strategy: "round-robin"

# Keep long streaming responses alive
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1
nonstream-keepalive-interval: 30

# Management panel settings
remote-management:
  allow-remote: false
  secret-key: "your-panel-password"
  disable-control-panel: false
```

完整配置选项参考 / Full config reference: [CLIProxyAPI Docs](https://help.router-for.me/configuration/basic.html)

</details>

<details>
<summary><b>多账号负载均衡 / Multi-account Load Balancing</b></summary>

CLIProxyAPI 支持多个 OAuth 账号轮询。多次运行 login 命令即可添加多个账号：

CLIProxyAPI supports round-robin across multiple OAuth accounts. Run login multiple times to add accounts:

**Linux / macOS:**

```bash
bash deploy.sh login   # 登录第一个账号 / Login first account
bash deploy.sh login   # 登录第二个账号 / Login second account
```

**Windows:**

```powershell
.\deploy.ps1 login   # 登录第一个账号 / Login first account
.\deploy.ps1 login   # 登录第二个账号 / Login second account
```

</details>

<details>
<summary><b>在 Cursor 中使用 / Use with Cursor</b></summary>

Cursor 也支持通过环境变量配置自定义 API 端点：

Cursor also supports custom API endpoints via environment variables:

**Linux / macOS:**

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8317"
export ANTHROPIC_AUTH_TOKEN="your-api-key"
```

**Windows:**

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8317"
$env:ANTHROPIC_AUTH_TOKEN = "your-api-key"
```

</details>

---

## 🔒 安全 / Security

- `config.yaml`、`.env`、`sub2api.env` 和 `cursor-bridge.env` 包含本地密钥，已被 `.gitignore` 忽略。
- OAuth 凭证保存在 Docker volume `cli-proxy-manager-auth` 中；`backup` 生成的归档也包含敏感信息，不要上传到公开仓库。
- Sub2API 数据保存在三个 `sub2api-manager-*` volumes 中。删除 volumes 前先确认已有备份。
- 发布截图、日志、README 示例时，不要包含真实 API key、OAuth 邮箱或凭证文件名。

See [SECURITY.md](SECURITY.md) for the full checklist.

---

## 🚢 发布前检查 / Publish Checklist

- Confirm repository URLs in `README.md`, `install.sh`, `install.ps1`, and deploy script help output.
- Confirm `config.yaml` is not committed.
- Run `bash -n deploy.sh` and `bash -n install.sh`.
- Run `pwsh -NoProfile -Command "try { . .\deploy.ps1 } catch {}"` (syntax check).
- Run `docker compose -f docker-compose.yml config --quiet`.
- Run `docker compose --env-file sub2api.env.example -f docker-compose.sub2api.yml config --quiet`.
- Run `bash tests/test-cursor-bridge-sidecar-contract.sh`.
- Run `bash deploy.sh status` / `.\deploy.ps1 status` and confirm the API test returns `200`.
- Test a fresh clone path before announcing the repo.

---

## 🤝 致谢 / Credits

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — 底层代理引擎 / The underlying proxy engine
- [Sub2API](https://github.com/Wei-Shaw/sub2api) — 可选的订阅配额分发 API 网关 / Optional subscription-quota API gateway

---

## 📄 License

[MIT](LICENSE)
