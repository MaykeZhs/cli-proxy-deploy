# 优化执行清单

> 项目：`cli-proxy-manager`
> 审查日期：2026-06-25
> 当前代码：已更新到 `origin/main` 最新提交 `a9bc803`
> 文档用途：把代码审查结果整理成可执行的优化清单，方便后续逐项处理。
> 说明：本清单基于静态审查和Git变更分析，未运行完整部署流程。

---

## 0. 当前状态摘要

### 0.1 最新远端变化

已从远端拉取最新代码：

```text
63cd675..a9bc803  main -> origin/main
```

最新提交主要修改：

```text
README.md |  19 +++++++++
deploy.sh | 136 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
```

主要新增能力：

```bash
bash deploy.sh auto-update
bash deploy.sh enable-auto-update [计划]
bash deploy.sh disable-auto-update
```

也就是说，自动更新能力已经从独立脚本方向，转为集成到 `deploy.sh` 中。

### 0.2 当前未跟踪文件

当前工作区仍有两个未跟踪文件：

```text
?? REVIEW.md
(已处理) auto-update.sh 已合并进 deploy.sh 并删除独立脚本
```

说明：

- `REVIEW.md`：本优化清单。
- `auto-update.sh`：已将有价值的计划别名、状态查看、日志查看和cron环境PATH逻辑合并进 `deploy.sh`，独立脚本已删除。

### 0.3 总体判断

项目当前的核心定位更像：

> 一个用于部署、配置、管理和增强 CLI Proxy API 的辅助项目。

它不是 Antigravity CLI 本体，也不应该让用户误解为官方 CLI 或客户端本身。因此项目命名、README描述、脚本输出中的措辞建议进一步收敛为“部署器/管理器/增强工具”，而不是“Antigravity CLI”。

---

## 1. P0：必须优先处理

### P0-1 合并并删除本地 `auto-update.sh`

- 现状：
  - 最新 `deploy.sh` 已内置：
    - `auto-update`
    - `enable-auto-update`
    - `disable-auto-update`
  - 原本地未跟踪文件 `auto-update.sh` 已合并进 `deploy.sh`。

- 风险：
  - 两套自动更新逻辑并存，后续容易漂移。
  - 如果保留独立脚本，用户会不知道应该使用 `auto-update.sh` 还是 `deploy.sh auto-update`。
  - 如果误提交，README与实际推荐用法可能冲突。

- 建议：
  - 已将计划别名、状态查看、日志查看、cron运行提醒和cron PATH补全合并进 `deploy.sh`。
  - 已删除独立 `auto-update.sh`，避免维护两个自动更新入口。

- 涉及文件：
  - `deploy.sh`
  - `README.md`

- 验证方式：

```bash
git status --short
bash -n deploy.sh
bash deploy.sh help
```

---

### P0-2 加强 `deploy.sh auto-update` 的失败处理

- 现状：
  - 新增的 `auto-update` 会先比较本地和远端镜像 digest。
  - 如果有新镜像，会执行：

```bash
docker pull "${DOCKER_IMAGE}" 2>&1 | tail -1
CPA_PORT="${CPA_PORT}" $COMPOSE_CMD -f "${COMPOSE_FILE}" up -d 2>&1 | tail -1
```

- 风险：
  - 失败时只显示最后一行，排查信息不足。
  - `update` 和 `auto-update` 更新逻辑重复。
  - Bash版仍未复用更完整的镜像拉取逻辑。
  - 更新完成后只读取镜像 digest，没有确认服务真正可用。

- 建议：
  - 抽出统一更新函数，例如 `perform_update`。
  - `update` 和 `auto-update` 共同复用。
  - 失败时输出最近若干行日志，而不是只输出 `tail -1`。
  - 更新后做轻量健康检查，例如访问 `/v1/models`。
  - 失败时返回非零状态，方便 cron 捕获。

- 涉及文件：
  - `deploy.sh`

- 验证方式：

```bash
bash -n deploy.sh
bash deploy.sh check-update
bash deploy.sh auto-update
bash deploy.sh status
```

---

### P0-3 修改 crontab 前自动备份

- 现状：
  - `enable-auto-update` 使用标记块管理 crontab：

```text
# >>> cli-proxy-manager auto-update >>>
...
# <<< cli-proxy-manager auto-update <<<
```

- 优点：
  - 不会简单覆盖整份 crontab。
  - 再次启用时可以替换旧的自动更新块。

- 风险：
  - 任何自动修改 crontab 的操作都有误伤风险。
  - 当前没有先备份用户已有 crontab。

- 建议：
  - 修改前保存一份 crontab 备份，例如：

```text
logs/crontab-backup-YYYYmmdd-HHMMSS.txt
```

  - 启用成功后显示：
    - 写入的计划。
    - 日志位置。
    - 备份文件位置。

- 涉及文件：
  - `deploy.sh`
  - `README.md`

- 验证方式：

```bash
bash deploy.sh enable-auto-update
crontab -l
bash deploy.sh disable-auto-update
```

---

### P0-4 默认隐藏完整密钥

- 现状：
  - 脚本和README中仍会直接显示：
    - API Key。
    - 管理面板密码。
    - `ANTHROPIC_AUTH_TOKEN` 示例。

- 风险：
  - 密钥可能出现在终端滚动历史、录屏、截图、远程协助画面或CI日志中。

- 建议：
  - 默认只显示掩码，例如：

```text
sk-abc...xyz
```

  - 如果确实需要完整显示，增加显式参数，例如：

```bash
bash deploy.sh info --show-secrets
bash deploy.sh config --show-secrets
```

  - README中避免建议用户直接：

```bash
echo "$API_KEY"
```

  - 可改为：

```bash
[ -n "$API_KEY" ] && echo "API key loaded"
```

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`
  - `README.md`
  - `SECURITY.md`

- 验证方式：

```bash
bash deploy.sh status
bash deploy.sh config
```

检查默认输出中是否不再出现完整密钥。

---

### P0-5 生成 `config.yaml` 后设置安全权限

- 现状：
  - `config.yaml` 包含 API Key、管理密钥和Provider登录相关信息。
  - Bash版初始生成后建议显式设置权限。

- 风险：
  - 在多用户机器上，文件权限如果过宽，可能导致密钥泄露。

- 建议：
  - Bash版生成后执行：

```bash
chmod 600 "${CONFIG_FILE}"
```

  - PowerShell版可以尽量设置当前用户ACL，或至少在文档中说明Windows权限注意事项。

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`
  - `SECURITY.md`

- 验证方式：

```bash
ls -l config.yaml
```

预期权限类似：

```text
-rw-------
```

---

### P0-6 加强 `.env` 解析和端口校验

- 现状：
  - `.env` 没有直接 `source`，这是优点。
  - 但目前仍建议限制允许的变量名，避免意外变量影响脚本行为。

- 风险：
  - 非法端口导致 Docker Compose 或 curl 报错。
  - 未知环境变量影响子进程行为。
  - 用户误写变量时不容易发现。

- 建议：
  - 只允许以下变量：

```text
CPA_PORT
CPA_API_KEY
CPA_MANAGEMENT_KEY
CPA_BIND_HOST
TZ
CPA_UPDATE_LOG
```

  - 增加校验：

| 变量 | 校验建议 |
|---|---|
| `CPA_PORT` | 必须是 `1-65535` 的整数 |
| `CPA_BIND_HOST` | 如果是 `0.0.0.0`，明确提示公网暴露风险 |
| 未知变量 | 提示后跳过，不直接导出 |
| 空值 | 根据变量类型决定是否允许 |

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`
  - `.env.example`
  - `README.md`

- 验证方式：

```bash
bash -n deploy.sh
bash deploy.sh doctor
bash deploy.sh status
```

---

## 2. P1：建议近期处理

### P1-1 项目命名和定位调整

- 现状：
  - 当前项目名是 `cli-proxy-manager`。
  - 文档或命令中可能出现 `cli-proxy-manager`、`Antigravity` 等表述。
  - 项目实际功能不是 Antigravity CLI 本体，而是部署、配置和增强 CLI Proxy API 的工具集合。

- 风险：
  - 用户误以为这是 Antigravity CLI 客户端。
  - 项目定位不清晰。
  - 如果涉及第三方名称，可能带来品牌或归属误解。

- 建议：
  - README开头明确说明：

```markdown
本项目不是 Antigravity CLI 本体，也不是官方客户端。
本项目是一个用于部署、配置和管理 CLI Proxy API 的辅助工具。
```

  - 项目命名建议偏向“部署/管理/增强”，避免像客户端本体。
  - 候选名称见本文第5节。

- 涉及文件：
  - `README.md`
  - `deploy.sh`
  - `deploy.ps1`
  - `docker-compose.yml`
  - `CLAUDE.md`
  - GitHub仓库名称

- 验证方式：
  - README首屏能看懂项目定位。
  - 用户不会把它理解成CLI客户端本体。

---

### P1-2 `cmd_update` 和 `cmd_auto_update` 逻辑合并

- 现状：
  - 普通更新和自动更新都有拉取镜像、重建容器的逻辑。

- 风险：
  - 一处修复错误处理，另一处可能忘记同步。
  - Bash和PowerShell行为继续漂移。

- 建议：
  - 抽出内部函数：

```bash
perform_update() {
    pull_image
    compose_up
    verify_service
}
```

  - `update` 直接执行 `perform_update`。
  - `auto-update` 先比较digest，有变化才执行 `perform_update`。

- 涉及文件：
  - `deploy.sh`

- 验证方式：

```bash
bash -n deploy.sh
bash deploy.sh update
bash deploy.sh auto-update
```

---

### P1-3 Bash临时目录和临时文件清理

- 现状：
  - `backup`、`restore`、`doctor` 使用了临时目录或临时文件。
  - 某些失败路径下可能留下临时文件。

- 风险：
  - 临时文件残留。
  - 包含敏感信息时存在泄露风险。

- 建议：

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' RETURN
```

或在函数内定义明确的 cleanup 逻辑。

- 涉及文件：
  - `deploy.sh`

- 验证方式：

```bash
bash -n deploy.sh
bash deploy.sh backup
bash deploy.sh doctor
```

---

### P1-4 `restore` 解压前校验tar内容

- 现状：
  - 恢复命令会直接解压tar包。

- 风险：
  - 恶意tar包可能包含 `../` 或绝对路径。

- 建议：
  - 解压前先查看内容：

```bash
tar -tzf "$source_file"
```

  - 只允许：

```text
config.yaml
auth/...
```

  - 拒绝：

```text
../
/absolute/path
```

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`

- 验证方式：

```bash
bash deploy.sh backup
bash deploy.sh restore <backup-file>
```

并增加恶意路径样例测试。

---

### P1-5 `setup-claude` 修改配置前备份和原子写入

- 现状：
  - `setup-claude` 会修改：

```text
~/.claude/settings.json
```

- 风险：
  - 原配置JSON无效时，可能处理不符合用户预期。
  - 写入过程中失败可能损坏配置文件。

- 建议：
  1. 如果文件存在，先备份。
  2. 校验原JSON是否有效。
  3. 生成新的临时JSON文件。
  4. 校验新JSON是否有效。
  5. 再替换原文件。

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`

- 验证方式：

```bash
bash deploy.sh setup-claude
```

并分别测试：

- settings不存在。
- settings存在且JSON合法。
- settings存在但JSON非法。

---

### P1-6 增加PowerShell版本检查

- 现状：
  - README要求 PowerShell 7+。
  - 脚本开头最好也显式检查。

- 风险：
  - Windows PowerShell 5.1 用户可能遇到难懂错误。

- 建议：

```powershell
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "需要 PowerShell 7 或更高版本" -ForegroundColor Red
    exit 1
}
```

- 涉及文件：
  - `deploy.ps1`
  - `install.ps1`

- 验证方式：

```powershell
.\deploy.ps1 help
```

---

## 3. P2：后续优化

### P2-1 支持镜像版本固定

- 现状：
  - 当前Docker镜像使用：

```text
eceasy/cli-proxy-api:latest
```

- 风险：
  - 不利于复现。
  - 回滚不方便。
  - 每次更新实际版本不明确。

- 建议：
  - 支持：

```env
CPA_IMAGE=eceasy/cli-proxy-api:某个版本
```

或：

```env
CPA_IMAGE=eceasy/cli-proxy-api@sha256:...
```

- 涉及文件：
  - `deploy.sh`
  - `deploy.ps1`
  - `docker-compose.yml`
  - `.env.example`
  - `README.md`

- 验证方式：

```bash
CPA_IMAGE=eceasy/cli-proxy-api:latest bash deploy.sh check-update
```

---

### P2-2 README补充Git依赖

- 现状：
  - README重点写了Docker、Bash、PowerShell。
  - 安装脚本和手动安装实际依赖Git。

- 建议：
  - 在前置依赖里补充：

```text
Git
```

  - 说明：使用一键安装脚本或 `git clone` 时需要Git；直接下载ZIP则不需要。

- 涉及文件：
  - `README.md`

---

### P2-3 README补充运行时生成文件说明

- 现状：
  - 项目结构主要列源文件。
  - 用户运行后会看到额外文件和目录。

- 建议补充：

```text
config.yaml    本地配置，包含密钥，不应提交
.env           本地环境变量，不应提交
backups/       备份目录
logs/          自动更新等日志
Docker volume  OAuth/provider登录数据
```

- 涉及文件：
  - `README.md`

---

### P2-4 `SECURITY.md` 补充PowerShell命令

- 现状：
  - 安全文档偏Bash。

- 建议补充PowerShell对应命令：

```powershell
.\deploy.ps1 stop
.\deploy.ps1 login
.\deploy.ps1 restart
```

- 涉及文件：
  - `SECURITY.md`

---

### P2-5 `CLAUDE.md` 同步命令列表

- 现状：
  - `CLAUDE.md`里的命令列表比实际脚本功能少。

- 建议补充：

```text
doctor
backup
restore
check-update
update
auto-update
enable-auto-update
auto-update-status
disable-auto-update
logout
```

- 涉及文件：
  - `CLAUDE.md`

---

### P2-6 Docker绑定地址说明更清晰

- 现状：
  - `config.example.yaml` 中的 `host: ""` 容易让用户误以为它控制宿主机暴露范围。
  - Docker宿主机监听地址实际主要由 `CPA_BIND_HOST` 控制。

- 建议说明两层含义：

| 配置 | 作用 |
|---|---|
| `config.yaml` 中的 `host` | 容器内部服务监听地址 |
| `.env` 中的 `CPA_BIND_HOST` | Docker映射到宿主机的监听地址 |

- 涉及文件：
  - `config.example.yaml`
  - `.env.example`
  - `README.md`

---

### P2-7 Docker Compose调用封装

- 现状：
  - 脚本里多处直接调用Compose。

- 建议抽一个helper：

```bash
compose() {
    CPA_PORT="${CPA_PORT}" "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" "$@"
}
```

- 收益：
  - 减少重复代码。
  - 统一错误处理。
  - 后续扩展更方便。

- 涉及文件：
  - `deploy.sh`

---

### P2-8 `COMPOSE_CMD` 改为数组

- 现状：
  - Bash中如果用字符串保存 `docker compose`，执行时依赖word splitting。

- 建议：

```bash
COMPOSE_CMD=(docker compose)
"${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d
```

- 涉及文件：
  - `deploy.sh`

---

### P2-9 Docker Compose healthcheck

- 现状：
  - `docker-compose.yml` 暂无 healthcheck。

- 建议：
  - 如果镜像内有 `curl` 或 `wget`，可以加：

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://127.0.0.1:8317/v1/models"]
  interval: 30s
  timeout: 5s
  retries: 3
```

  - 如果镜像没有这些工具，则不建议强行加。

- 涉及文件：
  - `docker-compose.yml`

---

## 4. 建议实施顺序

### 第一批：自动更新收尾

1. 合并并删除本地 `auto-update.sh`。（已完成）
2. 加强 `deploy.sh auto-update` 的失败日志和退出码。
3. `enable-auto-update` 修改 crontab 前自动备份。
4. README补充自动更新日志、cron查看和失败排查说明。

### 第二批：安全加固

5. 默认隐藏完整密钥。
6. `config.yaml` 设置 `chmod 600`。
7. `.env` 白名单和端口校验。
8. `update` 与 `auto-update` 复用统一更新函数。

### 第三批：配置和恢复安全

9. Bash临时文件清理。
10. restore解压前校验tar内容。
11. `setup-claude` 备份和原子写入。
12. PowerShell版本检查。

### 第四批：文档和长期维护

13. README补充Git依赖。
14. SECURITY补充PowerShell。
15. CLAUDE.md同步命令列表。
16. README补充运行时生成文件说明。
17. Bash/PowerShell行为对齐。
18. Compose调用封装。
19. 镜像版本固定支持。
20. Docker Compose healthcheck。

---

## 5. 项目命名和定位状态

### 5.1 已采用名称

已决定将项目统一命名为：

```text
cli-proxy-manager
```

展示名称统一为：

```text
CLI Proxy Manager
```

### 5.2 定位说明

这个项目不应该让人理解成“Antigravity CLI”。

它更准确的定位是：

> 部署、配置和管理 CLIProxyAPI 的辅助工具，并提供 Provider 登录、备份恢复、健康检查、自动更新等增强能力。

因此文档和脚本中应优先使用：

- CLI Proxy Manager
- cli-proxy-manager
- CLIProxyAPI deployment and management
- 部署和管理 CLIProxyAPI

不应把项目本身描述为：

- Antigravity CLI
- Antigravity 客户端
- 官方客户端

### 5.3 允许保留的 Antigravity 表述

以下内容可以继续保留 `Antigravity`，因为它们指的是 Provider 或 CLIProxyAPI 的配置项，而不是项目名称：

- Provider 选择菜单中的 `Antigravity`。
- `antigravity` 登录参数。
- `antigravity-credits` 配置项。
- 模型示例中的 `owned_by: "antigravity"`。
- Codex 与 Antigravity OAuth callback port 的区别说明。

### 5.4 已更新范围

本次改名应覆盖：

- README标题和安装路径。
- 安装脚本默认仓库地址。
- Docker Compose project name。
- 容器名。
- Docker volume名。
- 备份文件名前缀。
- 自动更新cron marker。
- SECURITY、CLAUDE、REVIEW中的项目名。

README首屏推荐保持类似说明：

```markdown
# CLI Proxy Manager

本项目不是 Antigravity CLI 本体，也不是官方客户端。

它是用于部署、配置和管理 CLIProxyAPI 的辅助工具。
```

---

## 6. 最推荐先做的5个事项

如果只想先挑最有价值的，我建议先做这五个：

1. 合并并删除本地 `auto-update.sh`，避免和最新 `deploy.sh` 自动更新重复。（已完成）
2. 加强 `deploy.sh auto-update` 的失败处理和日志输出。
3. 默认隐藏完整密钥。
4. `.env` 加白名单和端口校验。
5. 明确项目命名和README首屏定位，避免被理解成 Antigravity CLI 本体。

这五项性价比最高，能同时提升：

- 安全性。
- 稳定性。
- 用户体验。
- 项目定位清晰度。

---

## 7. 备注

当前shell每次执行命令会出现：

```text
/c/Users/admin/.bashrc: line 1: $'\357\273\277alias': command not found
```

这通常是 `.bashrc` 文件开头存在 UTF-8 BOM 导致的。

它不影响项目代码，但会污染命令输出。建议后续把：

```text
C:\Users\admin\.bashrc
```

保存为 **UTF-8 无 BOM**。
