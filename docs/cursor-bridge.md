# Cursor Bridge sidecar（第一版）

把 Cursor 做成和 Sub2API 一样的**可选 sidecar**。现网 `cli-proxy-manager` 不用重装、不用重建。CPA 把它当成自定义 OpenAI 兼容上游。第一版只有一把 Cursor key、一个 Cursor 身份。

```
客户端（现有 CPA API key）
  → 已有 cli-proxy-manager :8317
  → 私有网 cpa-cursor-bridge
  → cursor-bridge-guard:8080
  → cursor-bridge:8765（只在 cursor-bridge-backend 上）
  → 官方 Cursor（CURSOR_API_KEY × 1）
```

CPA 只连 `cpa-cursor-bridge`，解析得到守卫，**解析不到** `cursor-bridge:8765`。

完整设计：[2026-08-15-cursor-bridge-cpa-sidecar-design.md](plans/2026-08-15-cursor-bridge-cpa-sidecar-design.md)。  
本机 Stage A 试验：[../poc/cursor-bridge/README.md](../poc/cursor-bridge/README.md)（不要把 `poc/` 接到现网）。

## 不要做

- 不要 `docker compose -f docker-compose.yml down`
- 不要删卷 `cli-proxy-manager-auth`
- 不要改现网 `docker-compose.yml` 的 ports / volumes / image
- 不要把 `18765` / `8765` 绑到 `0.0.0.0`，不要让现网 Nginx 直接反代桥
- 不要开 `CURSOR_CONFIG_DIRS` / `CURSOR_ACCOUNT_DIRS` / `MULTI_PORT`
- 不要多账号轮询、账号池、配额规避、`reset-hwid`、agent/plan/MCP、真实工作区
- 不要接 CPAMP / Sub2API
- 不要把 key 写进聊天、git、日志
- 不要改 `deploy.sh` / `deploy.ps1` 默认向导（v1.1 再说）

## 云端落地

在**已经在跑 CPA 的那台 Linux 主机**、本仓库目录操作。

### 1. 同步代码

```bash
git pull
```

确认有 `docker-compose.cursor-bridge.yml`、`cursor-bridge/nginx-guard.conf`、`cursor-bridge.env.example`。

### 2. 打开 cursor-bridge.env 填两行

```bash
cp cursor-bridge.env.example cursor-bridge.env
chmod 600 cursor-bridge.env
```

打开 `cursor-bridge.env` 填两行：

- `CURSOR_API_KEY`：Cursor Dashboard https://cursor.com/dashboard/api ，弹窗里复制完整 `crsr_...`
- `CURSOR_BRIDGE_API_KEY`：本机执行 `openssl rand -hex 32`，必须和上一把不同

不要复用 `CPA_API_KEY` / `CPA_MANAGEMENT_KEY`。不要把 key 发到聊天里。`poc.env` 不用拷过来。

### 3. 构建钉死镜像

```bash
docker buildx build --load \
  --label org.opencontainers.image.source=https://github.com/anyrobert/cursor-api-proxy \
  --label org.opencontainers.image.revision=c0ff1f941215027c0a8f658ca5d01f806559208f \
  -t cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f \
  https://github.com/anyrobert/cursor-api-proxy.git#c0ff1f941215027c0a8f658ca5d01f806559208f
```

禁止 `:latest`，禁止改 tag，禁止用别的 commit。

### 4. 启动 sidecar（不动 CPA）

```bash
docker compose -f docker-compose.cursor-bridge.yml up -d
docker network connect cpa-cursor-bridge cli-proxy-manager
```

如果提示 already connected，可以忽略。

### 5. 从 CPA 容器内打守卫（先不要改 config）

```bash
docker exec cli-proxy-manager wget -qS -O- http://cursor-bridge-guard:8080/v1/models \
  || docker exec cli-proxy-manager curl -sS -D- -o /dev/null http://cursor-bridge-guard:8080/v1/models
```

无 Bearer 应为 **401**。  
这时 CPA 还解析不到 `cursor-bridge`（它不在 `cpa-cursor-bridge` 上）。

### 6. 追加 openai-compatibility，低峰重启 CPA

在现网 `config.yaml` **只追加** Cursor 这一项。不要改现有 `api-keys` / OAuth。  
`api-key` 填 `cursor-bridge.env` 里的 `CURSOR_BRIDGE_API_KEY`（不是 `crsr_`，也不是 CPA key）。

如果文件里还没有 `openai-compatibility:`，把下面整段加到末尾。  
如果已经有这个 key，只把 `- name: cursor-bridge` 这一项追加进列表，不要再写第二个顶层 `openai-compatibility:`。

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

低峰重启（短中断）。下面两种都**不会**拆掉手动挂上的网：

```bash
docker restart cli-proxy-manager
# 或
bash deploy.sh restart
```

不要 `docker compose -f docker-compose.yml up -d` 来“重启”。如果容器被重建了，再执行一次：

```bash
docker network connect cpa-cursor-bridge cli-proxy-manager
```

### 7. 用现有 CPA key 验收

把 CPA key 留在你自己的终端里，不要贴到聊天。

```bash
# 应能看到 cursor-auto 或 cursor/auto
curl -sS -H "Authorization: Bearer <CPA_API_KEY>" http://127.0.0.1:8317/v1/models

# 非流式
curl -sS -H "Authorization: Bearer <CPA_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"cursor-auto","messages":[{"role":"user","content":"用一句话介绍你自己"}],"stream":false}' \
  http://127.0.0.1:8317/v1/chat/completions

# 流式
curl -sSN -H "Authorization: Bearer <CPA_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"cursor-auto","messages":[{"role":"user","content":"用一句话介绍你自己"}],"stream":true}' \
  http://127.0.0.1:8317/v1/chat/completions
```

再确认：

```bash
# 主机不能出现 0.0.0.0:8765 / 0.0.0.0:18765
ss -lntup | grep -E '8765|18765' || true
docker port cursor-bridge
docker port cursor-bridge-guard

# 现有 Claude / Gemini / Codex 仍可用（用原来的模型名打一条）
docker inspect cli-proxy-manager --format '{{.Name}} {{json .HostConfig.Binds}} {{json .HostConfig.PortBindings}}'
```

`docker inspect cli-proxy-manager` 的名称、卷、现网端口应和接入前相同。

## 回滚

1. 从 `config.yaml` **删掉**刚加的 `openai-compatibility` 段（或其中的 `cursor-bridge` 项）。
2. `docker restart cli-proxy-manager` 或 `bash deploy.sh restart`。
3. 只下桥，不要带 `--volumes`，不要动 CPA 的 compose：

```bash
docker compose -f docker-compose.cursor-bridge.yml down --remove-orphans
```

4. 可选：`docker network disconnect cpa-cursor-bridge cli-proxy-manager`

现网 Claude / Gemini / Codex 应恢复为接入前的行为。

## 日常命令

| 动作 | 命令 |
|---|---|
| 看桥状态 | `docker compose -f docker-compose.cursor-bridge.yml ps` |
| 看桥日志 | `docker compose -f docker-compose.cursor-bridge.yml logs --tail 200` |
| 停桥 | `docker compose -f docker-compose.cursor-bridge.yml stop` |
| 起桥 | `docker compose -f docker-compose.cursor-bridge.yml up -d` |
| 拆桥 | `docker compose -f docker-compose.cursor-bridge.yml down --remove-orphans` |

日志里不应出现 Authorization、`crsr_`、两把 key、或 prompt 正文。

云上调试最多把守卫临时映到 `127.0.0.1`，不要映 `0.0.0.0`，不要映 `:8765`。默认 compose **不映射任何主机端口**。

## 以后再说（第一版不要做）

| 阶段 | 做什么 | 不做什么 |
|---|---|---|
| **v1.1** | `deploy.sh` / `deploy.ps1` 增加 cursor-bridge 的 start/stop/status/doctor | 改默认一键部署必装桥 |
| **v2 补上游** | fork 或补丁：鉴权顺序、应用层 body/并发、钉死 Cursor CLI、密钥不进 `inspect` | 继续跟无 pin 的 `latest` |
| **v2 产品** | 从 `/v1/models` 同步别名；按 300s 调 CPA 重试 | 对外卖 Cursor、公开 `/api/*` |
| **以后** | 若官方提供真正的 OpenAI chat 上游，评估拆桥 | 多账号目录轮询、配额池、`reset-hwid`、agent/plan/MCP/真实工作区 |

v2 之前，上游仍是个人仓库、无根 LICENSE、镜像构建里 `curl | bash` 装 CLI。第一版能用，不能当付费公网产品。
