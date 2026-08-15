# Cursor → API（本地 Stage A POC）

把 Cursor 变成本机 OpenAI 兼容接口，方便你先试用功能。

```
本机客户端 → 127.0.0.1:18765 → Cursor Bridge 容器 :8765 → 官方 Cursor CLI/API
```

这是**内部一次性试验**，不是线上产品。不要接到现有 `cli-proxy-manager`、Nginx、CPA Manager Plus、Sub2API，也不要把 `18765` 暴露到公网。

## 你需要准备什么

1. Docker Desktop 已启动，`docker version` 和 `docker compose version` 可用。
2. PowerShell 7（`pwsh`）。
3. 一张 **Cursor Dashboard** 的 API key：<https://cursor.com/dashboard/integrations>  
   不要用 CPA / 本仓库 `.env` 里的 key。

不要把任何 key 粘贴到聊天里。

## Windows 上怎么跑

在 **这个 worktree** 里操作，不要用主仓库目录：

```powershell
cd F:\gen2_code\mayke\cli-proxy-deploy\.worktrees\cursor-bridge-poc-stage-a\poc\cursor-bridge

.\poc.ps1 init
```

用编辑器打开同目录的 `poc.env`，**只改这一行**：

```
CURSOR_API_KEY=你的 Cursor Dashboard key
```

`CURSOR_BRIDGE_API_KEY` 已由 `init` 生成，不要改成和 Cursor key 相同，也不要提交这个文件。

然后：

```powershell
.\poc.ps1 build    # 第一次会较慢：按锁定 commit 构建镜像
.\poc.ps1 start
.\poc.ps1 doctor
.\poc.ps1 smoke
```

Linux / macOS 用 `bash poc.sh` 代替 `.\poc.ps1`，命令相同。

## 怎么调用

- Base URL：`http://127.0.0.1:18765/v1`
- Header：`Authorization: Bearer <poc.env 里的 CURSOR_BRIDGE_API_KEY>`
- 不要用 `CURSOR_API_KEY` 当 Bearer；那是容器拿去登录 Cursor 的。

```powershell
$key = (Get-Content .\poc.env | Where-Object { $_ -like 'CURSOR_BRIDGE_API_KEY=*' }) -replace '^[^=]+=',''
$headers = @{ Authorization = "Bearer $key" }

Invoke-RestMethod http://127.0.0.1:18765/v1/models -Headers $headers

Invoke-RestMethod http://127.0.0.1:18765/v1/chat/completions -Headers $headers -Method Post -ContentType application/json -Body (@{
  model = 'auto'
  messages = @(@{ role = 'user'; content = '用一句话介绍你自己' })
  stream = $false
} | ConvertTo-Json)
```

任意 OpenAI SDK 也可：`baseURL=http://127.0.0.1:18765/v1`，`apiKey=CURSOR_BRIDGE_API_KEY`。

## 常用命令

| 命令 | 作用 |
|---|---|
| `init` | 生成本地 `poc.env`（已存在会失败） |
| `build` | 构建锁定镜像，不拉 `latest` |
| `start` / `stop` | 启动 / 停止容器 |
| `status` / `logs` | 看状态和日志 |
| `doctor` | 检查只绑 loopback、健康检查、未授权 401 |
| `smoke` | 一次同步 + 一次流式对话 |
| `destroy` | 只拆这个 POC 的 Compose 项目，不删镜像和卷 |

## 这能做什么 / 不能做什么

能：本机把 Cursor 当 OpenAI Chat Completions 来试。

不能保证：和 Cursor IDE 一样的仓库上下文、原生 tool-call、计费精度、多账号、MCP、agent/plan 模式。当前强制 `ask`、chat-only 空工作区。

测完用 `.\poc.ps1 destroy` 停掉。不要把这个栈并进线上 CPA。

云端第一版怎么挂到已有 CPA：见仓库根目录 [`docs/plans/2026-08-15-cursor-bridge-cpa-sidecar-design.md`](../../docs/plans/2026-08-15-cursor-bridge-cpa-sidecar-design.md)。换电脑接着做：[`docs/handoff/2026-08-15-cursor-bridge.md`](../../docs/handoff/2026-08-15-cursor-bridge.md)。
