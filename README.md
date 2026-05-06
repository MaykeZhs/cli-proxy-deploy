<div align="center">

# 🚀 Antigravity Proxy

**一键部署 CLIProxyAPI，反代 Antigravity / Claude Code / Gemini CLI / Codex**

**One-click CLIProxyAPI deployment to reverse proxy Antigravity / Claude Code / Gemini CLI / Codex**

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
| 🪟 Windows 原生支持 / Windows native | PowerShell 部署脚本 / PowerShell deploy scripts |

---

## 📋 前置要求 / Prerequisites

| 平台 / Platform | 要求 / Requirements |
|---|---|
| **All** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **Linux / macOS** | Bash (built-in) |
| **Windows** | [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`) |

---

## 🚀 快速开始


### 方式一：远程一键安装

**Linux / macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.ps1 -OutFile install.ps1; .\install.ps1
```

### 方式二：手动安装

**Linux / macOS:**

```bash
git clone https://github.com/MaykeZhs/antigravity-proxy.git
cd antigravity-proxy
bash deploy.sh
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/MaykeZhs/antigravity-proxy.git
cd antigravity-proxy
.\deploy.ps1
```

部署脚本会引导你完成：

1. ✅ 检查 Docker 环境
2. ✅ 交互式配置（端口、API 密钥、管理面板）
3. ✅ 选择 Provider 并完成 OAuth 登录
4. ✅ 启动代理服务
5. ✅ 输出 Claude Code for VS Code 配置

---

## 🚀 Quick Start

### Option 1: Remote One-Click Install

**Linux / macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri https://raw.githubusercontent.com/MaykeZhs/antigravity-proxy/main/install.ps1 -OutFile install.ps1; .\install.ps1
```

### Option 2: Manual Install

**Linux / macOS:**

```bash
git clone https://github.com/MaykeZhs/antigravity-proxy.git
cd antigravity-proxy
bash deploy.sh
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/MaykeZhs/antigravity-proxy.git
cd antigravity-proxy
.\deploy.ps1
```

The deployment script will guide you through:

1. ✅ Docker environment check
2. ✅ Interactive configuration (port, API key, management panel)
3. ✅ Provider selection & OAuth login
4. ✅ Start the proxy service
5. ✅ Output Claude Code for VS Code configuration

---

## ✅ 验证部署 / Verify Deployment

启动后先检查容器、配置挂载、凭证和模型列表：

After startup, verify the container, config mount, credential, and model list:

**Linux / macOS:**

```bash
cd antigravity-proxy

# Service status and loaded credentials
bash deploy.sh status

# Docker container status
docker compose -f docker-compose.yml ps

# Config must be a file inside the container, not a directory
docker compose -f docker-compose.yml exec -T cliproxyapi sh -lc \
'test -f /CLIProxyAPI/config.yaml && ls -l /CLIProxyAPI/config.yaml'

# API model list
API_KEY=$(awk -F'"' '/- "sk-/{print $2; exit}' config.yaml)
curl -i http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer ${API_KEY}"
```

**Windows (PowerShell):**

```powershell
cd antigravity-proxy

# Service status and loaded credentials
.\deploy.ps1 status

# Docker container status
docker compose -f docker-compose.yml ps

# Config must be a file inside the container, not a directory
docker compose -f docker-compose.yml exec -T cliproxyapi sh -lc "test -f /CLIProxyAPI/config.yaml && ls -l /CLIProxyAPI/config.yaml"

# API model list
$apiKey = (Select-String -Path config.yaml -Pattern '- "sk-([^"]+)"').Matches.Groups[1].Value
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

### 1. 获取 API Key / Get the API Key

**Linux / macOS:**

```bash
API_KEY=$(awk -F'"' '/- "sk-/{print $2; exit}' config.yaml)
echo "$API_KEY"
```

**Windows (PowerShell):**

```powershell
$apiKey = (Select-String -Path config.yaml -Pattern '- "sk-([^"]+)"').Matches.Groups[1].Value
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
| 启动服务 / Start service | `bash deploy.sh start` | `.\deploy.ps1 start` |
| 停止服务 / Stop service | `bash deploy.sh stop` | `.\deploy.ps1 stop` |
| 重启服务 / Restart service | `bash deploy.sh restart` | `.\deploy.ps1 restart` |
| 查看状态 / Check status | `bash deploy.sh status` | `.\deploy.ps1 status` |
| 实时日志 / Real-time logs | `bash deploy.sh logs` | `.\deploy.ps1 logs` |
| 更新到最新版 / Update to latest | `bash deploy.sh update` | `.\deploy.ps1 update` |
| 完全卸载 / Full uninstall | `bash deploy.sh uninstall` | `.\deploy.ps1 uninstall` |
| 显示帮助 / Show help | `bash deploy.sh help` | `.\deploy.ps1 help` |

### 更新 Docker 镜像 / Update Docker Image

`update` 命令会拉取 `eceasy/cli-proxy-api:latest` 最新镜像，并用 Docker Compose 重新创建/更新服务。

Use the `update` command when you want to upgrade the running proxy to the latest `eceasy/cli-proxy-api:latest` Docker image. It pulls the newest image and recreates the service with Docker Compose while keeping your `config.yaml` and OAuth credential volume.

**Linux / macOS:**

```bash
# Pull the latest image and recreate the service
bash deploy.sh update

# Verify the updated service is running
bash deploy.sh status
```

**Windows (PowerShell):**

```powershell
# Pull the latest image and recreate the service
.\deploy.ps1 update

# Verify the updated service is running
.\deploy.ps1 status
```

### 环境变量 / Environment Variables

| 变量 / Variable | 默认值 / Default | 说明 / Description |
|---|---|---|
| `CPA_PORT` | `8317` | 服务端口 / Service port |
| `CPA_API_KEY` | *(auto-generated)* | API 密钥 / API key |

```bash
# 自定义端口启动 / Start with custom port
CPA_PORT=9000 bash deploy.sh start
```

**Windows:**

```powershell
# 自定义端口启动 / Start with custom port
$env:CPA_PORT=9000; .\deploy.ps1 start
```

---

## 🏗️ 项目结构 / Project Structure

```
antigravity-proxy/
├── deploy.sh              # 主部署脚本 (Linux/macOS) / Main deployment script
├── deploy.ps1             # 主部署脚本 (Windows) / Main deployment script (Windows)
├── install.sh             # 远程安装脚本 (Linux/macOS) / Remote installer
├── install.ps1            # 远程安装脚本 (Windows) / Remote installer (Windows)
├── docker-compose.yml     # Docker 编排 / Docker Compose
├── config.example.yaml    # 配置模板 / Config template
├── .env.example           # 可选环境变量示例 / Optional env example
├── SECURITY.md            # 安全说明 / Security notes
├── LICENSE
└── README.md
```

---

## 🧯 常见问题 / Troubleshooting

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
<summary><b>container name "/antigravity-proxy" is already in use</b></summary>

这通常发生在你重命名项目目录、复制项目目录，或从另一个 Compose project 启动过同一个容器名之后。`docker ps` 只显示运行中的容器，所以冲突容器可能是 stopped 状态。

This usually happens after renaming/copying the project folder or starting the same container from a different Compose project. `docker ps` only shows running containers, so the conflicting container may be stopped.

```bash
docker ps -a --filter name=antigravity-proxy
docker rm antigravity-proxy
docker compose up -d
```

**Windows:**

```powershell
docker ps -a --filter name=antigravity-proxy
docker rm antigravity-proxy
docker compose up -d
```

如果你想保留 OAuth 登录状态，不要删除 `antigravity-proxy-auth` volume。

Do not remove the `antigravity-proxy-auth` volume if you want to keep OAuth credentials.

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
host: ""
port: 8317
auth-dir: "/root/.cli-proxy-api"
api-keys:
  - "your-custom-key"
debug: false
request-retry: 3
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
routing:
  strategy: "round-robin"
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1
remote-management:
  allow-remote: false
  secret-key: "your-panel-password"
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

- `config.yaml` 和 `.env` 包含本地密钥，已被 `.gitignore` 忽略。
- OAuth 凭证保存在 Docker volume `antigravity-proxy-auth` 中，不要上传或备份到公开仓库。
- 发布截图、日志、README 示例时，不要包含真实 API key、OAuth 邮箱或凭证文件名。

See [SECURITY.md](SECURITY.md) for the full checklist.

---

## 🚢 发布前检查 / Publish Checklist

- Confirm repository URLs in `README.md`, `install.sh`, `install.ps1`, and deploy script help output.
- Confirm `config.yaml` is not committed.
- Run `bash -n deploy.sh` and `bash -n install.sh`.
- Run `pwsh -NoProfile -Command "try { . .\deploy.ps1 } catch {}"` (syntax check).
- Run `docker compose -f docker-compose.yml config --quiet`.
- Run `bash deploy.sh status` / `.\deploy.ps1 status` and confirm the API test returns `200`.
- Test a fresh clone path before announcing the repo.

---

## 🤝 致谢 / Credits

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — 底层代理引擎 / The underlying proxy engine

---

## 📄 License

[MIT](LICENSE)
