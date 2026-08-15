# Cursor Bridge 接入云端 CPA（第一版）

**状态：** 设计已定，待另一台机器按本文实现  
**日期：** 2026-08-15  
**前提：** Stage A 本机已跑通（鉴权、拉模型、同步、流式）

## 一句话

云端已经在跑的 CPA **不用重装**。Cursor Bridge 做成和 Sub2API 一样的**可选 sidecar**：CPA 把它当成一个自定义 OpenAI 兼容上游。整座桥第一版只代表 **一把 Cursor key、一个 Cursor 身份**。

```
客户端（现有 CPA API key）
  → 云端已部署的 cli-proxy-manager :8317
  → 私有 Docker 网
  → cursor-bridge-guard（8MiB / 单并发 / 路径白名单）
  → cursor-bridge :8765
  → 官方 Cursor（CURSOR_API_KEY × 1）
```

## 已拍板的范围

做：

- 新文件：`docker-compose.cursor-bridge.yml`、守卫配置、`cursor-bridge.env.example`
- 现有 `cli-proxy-manager` **只多连一张网、`config.yaml` 多一段 `openai-compatibility`**
- 桥不映射公网端口；云主机调试最多 `127.0.0.1`
- 模型用前缀，避免和现有 Claude / Gemini / Codex 抢名字，例如 `cursor/auto`

不做（第一版）：

- 不改现网 `deploy.sh` / `deploy.ps1` 的默认 start 路径（可后补子命令）
- 不重建、不改名现网容器 `cli-proxy-manager`
- 不把 `18765` / `8765` 绑到 `0.0.0.0`
- 不开 `CURSOR_CONFIG_DIRS` / `CURSOR_ACCOUNT_DIRS` / `CURSOR_BRIDGE_MULTI_PORT`
- 不做多把 `crsr_` 轮询、账号池、配额规避
- 不把上游源码 vendoring 进本仓库
- 不接 CPAMP / Sub2API / 现网 Nginx 直接打到桥

## 和现网怎么拼

沿用 Sub2API 的「第二份 Compose」模式，但网络策略更严：

| 栈 | Compose 项目名 | 容器 | 主机端口 |
|---|---|---|---|
| 现网 CPA（已有） | `cli-proxy-manager` | `cli-proxy-manager` | 已有，例如 `8317` |
| 新增桥 | `cursor-bridge` | `cursor-bridge`、`cursor-bridge-guard` | **不对外** |

新网：`cpa-cursor-bridge`（普通 bridge，**不能** `internal: true`，桥要访问 `cursor.com`）。

现网 CPA 用 `docker network connect cpa-cursor-bridge cli-proxy-manager` 挂上去，**不要** `compose up` 重建它。

CPA `config.yaml` 只追加（key 用桥的 Bearer，不是 `crsr_`）：

```yaml
openai-compatibility:
  - name: cursor-bridge
    prefix: cursor
    base-url: http://cursor-bridge-guard:8080/v1
    api-key-entries:
      - api-key: "<CURSOR_BRIDGE_API_KEY>"
    models:
      - name: auto
        alias: cursor-auto
```

客户端继续用原来的 CPA key。调用 `cursor/auto` 或 `cursor-auto`（以实现时 CPA 前缀规则为准）。

改完 `config.yaml` 需要重启 CPA 进程才能加载，会有短暂中断。先在低峰做，并准备回滚：删掉这一段、再重启。

## 镜像与密钥

- 镜像继续钉死：`cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f`  
  上游 commit：`c0ff1f941215027c0a8f658ca5d01f806559208f`（2026-08-15 仍是 main HEAD）
- 云主机上 `docker buildx build --load` 一次，`pull_policy: never`
- `cursor-bridge.env`：`chmod 600`，只进 gitignore
  - `CURSOR_API_KEY`：Cursor Dashboard → [API Keys](https://cursor.com/dashboard/api)，`crsr_` 开头，创建弹窗里复制完整值
  - `CURSOR_BRIDGE_API_KEY`：本机生成的 64 位 hex，和上一把必须不同
- 禁止复用现网 `CPA_API_KEY` / `CPA_MANAGEMENT_KEY`

## 守卫（第一版必须有）

上游没有请求体上限、没有全局并发上限，部分路由在 Bearer 之前。CPA 不能直连 `:8765`。

守卫（Nginx 或同等）只在私有网上听 `8080`：

- `client_max_body_size 8m`
- 全局限 1 个并发连接
- 只放行 `GET /v1/models`、`POST /v1/chat/completions`（含流式）
- 不转发 `X-Cursor-Mode`、`X-Cursor-Workspace`
- 超时 ≥ 300s（和桥的 `CURSOR_BRIDGE_TIMEOUT_MS` 对齐）
- 不写 Authorization / `crsr_` / 请求体到日志

桥容器保持 Stage A 硬化：`user: app`、`cap_drop: ALL`、`no-new-privileges`、2GiB / 2 CPU / 128 PID、`init: true`、chat-only + `ask`。

## 云端落地顺序（实现时按此勾）

1. 在云主机仓库目录新增 compose / 守卫 / `cursor-bridge.env.example`，gitignore `cursor-bridge.env`。
2. 填 `cursor-bridge.env`（两把不同的 key）。
3. 构建钉死镜像；`docker compose -f docker-compose.cursor-bridge.yml up -d`。
4. `docker network connect cpa-cursor-bridge cli-proxy-manager`。
5. 从 CPA 容器内探测守卫：`wget`/`curl` `http://cursor-bridge-guard:8080/v1/models`（无 Bearer 应为 401）。
6. 追加 `openai-compatibility`，重启 CPA。
7. 用**现有 CPA key** 打 `GET /v1/models`，应能看到 `cursor-auto`（或带 `cursor/` 前缀的名字）。
8. 再打一条非流式、一条流式 `chat/completions`。
9. 确认主机 `ss`/`docker port`：**没有** `0.0.0.0:8765` / `0.0.0.0:18765`。
10. 回滚演练：去掉 yaml 段、重启 CPA、`compose down` 桥（不要 `--volumes` 去动 CPA 的 auth 卷）。

## 验收

- 现网 Claude / Gemini / Codex 行为与接入前一致
- 未带 CPA key → 401
- 带 CPA key、模型 `cursor-auto` → 能通
- 未授权打守卫 → 401
- 主机上看不到桥的公网端口
- `docker inspect cli-proxy-manager` 名称、卷、现网端口与接入前相同
- 日志里没有两把 key、没有 prompt 正文

## 未来展望（不进第一版）

| 阶段 | 做什么 | 不做什么 |
|---|---|---|
| **v1** | 本文：sidecar + 守卫 + 单 key + 前缀模型 | 现网大改、多账号 |
| **v1.1** | `deploy.sh` / `deploy.ps1` 增加 `cursor-bridge` 的 start/stop/status/doctor，和 Sub2API 体验对齐 | 改默认一键部署必装桥 |
| **v2 补上游** | fork 或补丁：鉴权顺序、应用层 body/并发限制、钉死 Cursor CLI 安装、补 LICENSE、密钥改 file/secret 不进 `inspect` | 继续跟无 pin 的 `latest` |
| **v2 产品** | 从 `/v1/models` 同步别名；CPA 重试/超时按 300s 调；文档里写清「这不是 Cursor IDE」 | 对外卖 Cursor、公开 `/api/*` |
| **以后再说** | 若官方提供真正的 OpenAI chat 上游，评估丢掉这座桥 | 多账号目录轮询、配额池、`reset-hwid`、agent/plan/MCP/真实工作区 |

v2 之前，上游仍是个人仓库、无根 LICENSE、Docker 里 `curl | bash` 装 CLI。第一版能用，不能当付费公网产品。

## STOP（出现就停、回滚）

- 桥端口出现在 `0.0.0.0` 或被现网 Nginx 直接反代
- 现网 CPA 被重建、auth 卷被删、现有 provider 挂了
- 打开多账号目录 / multi-port / force / MCP / 真实工作区
- key 进 git、进聊天、进日志
- 用这座桥做公开、共享、转售、规避额度

## 实现落点（给下一台电脑）

新建（建议路径）：

- `docker-compose.cursor-bridge.yml`
- `cursor-bridge/nginx-guard.conf`（或 Caddyfile）
- `cursor-bridge.env.example`
- `.gitignore` 增加 `cursor-bridge.env`
- `SECURITY.md` 补一段 sidecar 边界
- 可选：`docs/cursor-bridge.md` 操作说明

不改（除非单独评审）：

- 现网 `docker-compose.yml` 的 ports / volumes / image
- `config.yaml` 里现有 `api-keys` 和 OAuth 段的值（只**追加** openai-compatibility）
- `deploy.sh` / `deploy.ps1` 默认向导
- Stage A worktree 里正在跑的本机 POC（那是试验机，不是云端）

参考：

- Stage A 设计：`docs/plans/2026-08-14-cursor-bridge-internal-poc-design.md`（在分支 `codex/cursor-bridge-poc-stage-a`）
- 本机试验：`.worktrees/cursor-bridge-poc-stage-a/poc/cursor-bridge/`
- CPA 上游字段：[openai-compatibility](https://help.router-for.me/configuration/basic.html)
- 钉死上游：https://github.com/anyrobert/cursor-api-proxy/tree/c0ff1f941215027c0a8f658ca5d01f806559208f
