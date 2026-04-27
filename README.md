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

---

## 🚀 快速开始

> 发布到你自己的 GitHub 前，请把下面命令中的 `YOUR_USER` 替换为你的 GitHub 用户名或组织名。
>
> Before publishing, replace `YOUR_USER` with your GitHub username or organization.

### 方式一：远程一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/antigravity-proxy/main/install.sh | bash
```

### 方式二：手动安装

```bash
git clone https://github.com/YOUR_USER/antigravity-proxy.git
cd antigravity-proxy
bash deploy.sh
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

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/antigravity-proxy/main/install.sh | bash
```

### Option 2: Manual Install

```bash
git clone https://github.com/YOUR_USER/antigravity-proxy.git
cd antigravity-proxy
bash deploy.sh
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
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6-thinking"
  }
}
```

或者在 `~/.zshrc` / `~/.bashrc` 中添加 / Or add to your shell profile:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8317"
export ANTHROPIC_AUTH_TOKEN="your-api-key"
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-6-thinking"
```

### 指定模型 / Specify Models (Claude Code v2.x.x)

先用 `/v1/models` 查看当前账号可用模型，然后使用返回的精确 `id`：

First check available models with `/v1/models`, then use the exact returned `id`:

```bash
# Claude-compatible models via Antigravity
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-6-thinking"

# Gemini models can also be used if your client supports the selected model id
export ANTHROPIC_DEFAULT_SONNET_MODEL="gemini-3-flash"
```

---

## 📋 命令参考 / Command Reference

| 命令 / Command | 说明 / Description |
|---|---|
| `bash deploy.sh` | 交互式完整部署 / Full interactive deployment |
| `bash deploy.sh login` | OAuth 登录 Provider / OAuth login |
| `bash deploy.sh start` | 启动服务 / Start service |
| `bash deploy.sh stop` | 停止服务 / Stop service |
| `bash deploy.sh restart` | 重启服务 / Restart service |
| `bash deploy.sh status` | 查看状态 / Check status |
| `bash deploy.sh logs` | 实时日志 / Real-time logs |
| `bash deploy.sh update` | 更新到最新版 / Update to latest |
| `bash deploy.sh uninstall` | 完全卸载 / Full uninstall |
| `bash deploy.sh help` | 显示帮助 / Show help |

### 环境变量 / Environment Variables

| 变量 / Variable | 默认值 / Default | 说明 / Description |
|---|---|---|
| `CPA_PORT` | `8317` | 服务端口 / Service port |
| `CPA_API_KEY` | *(auto-generated)* | API 密钥 / API key |

```bash
# 自定义端口启动 / Start with custom port
CPA_PORT=9000 bash deploy.sh start
```

---

## 🏗️ 项目结构 / Project Structure

```
antigravity-proxy/
├── deploy.sh              # 主部署脚本 / Main deployment script
├── install.sh             # 远程安装脚本 / Remote installer
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
<summary><b>config.yaml: is a directory</b></summary>

这通常是因为在 `config.yaml` 文件存在前直接运行了 `docker compose up`，Docker 自动创建了同名目录。

This usually happens when `docker compose up` is run before the real `config.yaml` file exists.

```bash
docker compose down
rmdir config.yaml
bash deploy.sh
```

`deploy.sh` 也会自动检测并提示删除空目录。

</details>

<details>
<summary><b>/v1/models returns {"data":[]}</b></summary>

代理服务已经启动，但还没有加载 OAuth 凭证。运行：

The proxy is running, but no OAuth credential has been loaded yet. Run:

```bash
bash deploy.sh login
bash deploy.sh status
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

```bash
bash deploy.sh login   # 登录第一个账号 / Login first account
bash deploy.sh login   # 登录第二个账号 / Login second account
```

</details>

<details>
<summary><b>在 Cursor 中使用 / Use with Cursor</b></summary>

Cursor 也支持通过环境变量配置自定义 API 端点：

Cursor also supports custom API endpoints via environment variables:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:8317"
export ANTHROPIC_AUTH_TOKEN="your-api-key"
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

- Replace `YOUR_USER` in `README.md`, `install.sh`, and `deploy.sh`.
- Confirm `config.yaml` is not committed.
- Run `bash -n deploy.sh` and `bash -n install.sh`.
- Run `docker compose -f docker-compose.yml config --quiet`.
- Run `bash deploy.sh status` and confirm the API test returns `200`.
- Test a fresh clone path before announcing the repo.

---

## 🤝 致谢 / Credits

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — 底层代理引擎 / The underlying proxy engine

---

## 📄 License

[MIT](LICENSE)
