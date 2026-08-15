# 交接：Cursor Bridge → 云端 CPA

给**另一台电脑、同一个仓库**接着做。写于 2026-08-15，远程 Windows 试验机。

不要把任何 API key 拷进聊天、邮件或这份文件。

## 你接到的是什么

目标已经定死：

> 云端已有 CPA 保持不动。加一个 Cursor Bridge sidecar。CPA 把它当成自定义 OpenAI 兼容上游。第一版只有一把 Cursor key。

完整设计：[`docs/plans/2026-08-15-cursor-bridge-cpa-sidecar-design.md`](../plans/2026-08-15-cursor-bridge-cpa-sidecar-design.md)

本机 Stage A **已经用真实 Cursor key 跑通**，不是纸面设计。

## 两台机器分别干什么

| 机器 | 角色 | 不要做什么 |
|---|---|---|
| 这台远程 Windows（当前） | Stage A 试验：本机 `127.0.0.1:18765` 已验证 | 不要在这台改云端现网 CPA |
| 你的下一台电脑 | 按设计实现 sidecar，部署到**已有云端 CPA 的那台服务器** | 不要把本机 `poc.env` 提交或发给别人 |

## 仓库怎么拿

远程机上的 git：

| 检出 | 路径 | 分支 | HEAD（交接时） |
|---|---|---|---|
| 主目录 | `F:\gen2_code\mayke\cli-proxy-deploy` | `main` | `1b5f9a7` |
| Stage A worktree | `F:\gen2_code\mayke\cli-proxy-deploy\.worktrees\cursor-bridge-poc-stage-a` | `codex/cursor-bridge-poc-stage-a` | `7f5df2a` + **未提交的 Stage A 实现** |

另一台电脑：

```bash
git fetch origin
git checkout codex/cursor-bridge-poc-stage-a
```

若该分支还没 push，先在**这台远程机**提交并 `git push -u origin HEAD`，再在另一台拉。  
主目录 `main` 上还有与 Cursor **无关**的脏文件，不要打进 Cursor 的 commit：

- 已改：`README.md`
- 未跟踪：`AGENTS.md`、`docs/gpt-image-2-integration.md`、`docs/grok-imagine-*-integration.md`

`.worktrees/` 在 gitignore 里。worktree 里的文件要靠 **在 worktree 里 commit** 才会进仓库；主窗口看不见不等于没做。

## Stage A 现在在哪（已完成）

Worktree 里：

- `poc/cursor-bridge/docker-compose.yml`
- `poc/cursor-bridge/poc.env.example`
- `poc/cursor-bridge/poc.sh` / `poc.ps1`
- `poc/cursor-bridge/README.md`
- `tests/test-cursor-bridge-poc-contract.sh` / `.ps1`
- `.gitignore`、`SECURITY.md` 的 POC 段

本机真实结果（2026-08-14）：

- 镜像：`cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f`
- 容器：`cursor-bridge-poc`，`127.0.0.1:18765->8765`，user=`app`
- `doctor` PASS，`smoke` PASS
- `/v1/models` 有 `auto`、`gpt-5.3-codex*` 等
- 对话有正常中文回复

`poc.env` 只在这台机器，**gitignore**。另一台和云端各自新建，不要拷这个文件。

本机试调用（在 worktree 的 `poc/cursor-bridge`）：

```powershell
$key = (Get-Content .\poc.env | Where-Object { $_ -like 'CURSOR_BRIDGE_API_KEY=*' }) -replace '^[^=]+=',''
$h = @{ Authorization = "Bearer $key" }
Invoke-RestMethod http://127.0.0.1:18765/v1/models -Headers $h
```

停本机试验：`.\poc.ps1 stop` 或 `.\poc.ps1 destroy`（destroy 只下这个 Compose 项目）。

## 下一台电脑要做的（第一版实现）

按设计文档从头做，**不要**把 Stage A 的 `poc/` 原样接到现网。

1. 读完 sidecar 设计（尤其「不重建 CPA」「守卫必须有」「单 key」）。
2. 新增 `docker-compose.cursor-bridge.yml` + 守卫 + `cursor-bridge.env.example`。
3. 在**云端 CPA 那台 Linux 主机**构建钉死镜像、起 sidecar、`docker network connect` 到现有 `cli-proxy-manager`。
4. `config.yaml` **只追加** `openai-compatibility`，然后重启 CPA。
5. 用现有 CPA key 测 `cursor-auto`；确认 Claude/Gemini/Codex 没坏；确认桥没有公网端口。
6. 更新 `SECURITY.md`。不要改默认 `deploy.sh` 向导，除非另开一票。

钉死值：

- 上游：`https://github.com/anyrobert/cursor-api-proxy`
- commit：`c0ff1f941215027c0a8f658ca5d01f806559208f`
- 镜像 tag：`cursor-api-proxy:poc-c0ff1f941215027c0a8f658ca5d01f806559208f`
- 现网容器名：`cli-proxy-manager`（不要改）
- 新网名：`cpa-cursor-bridge`
- 守卫上游：`http://cursor-bridge-guard:8080/v1`

Cursor key 从 https://cursor.com/dashboard/api 现开，弹窗里复制完整 `crsr_...`。

## 明确不要做

- 不要 `docker compose -f docker-compose.yml down` 现网 CPA
- 不要删卷 `cli-proxy-manager-auth`
- 不要把 `CURSOR_API_KEY` 写进 CPA 的 `api-keys`
- 不要开多账号轮询 / `CURSOR_ACCOUNT_DIRS`
- 不要 amend `7f5df2a`（不是你在这台机器上的提交）
- 不要把 `poc.env`、`config.yaml`、`.env` 提交上去

## 未来（只写在计划里，先别做）

见设计文档「未来展望」：v1.1 补部署子命令；v2 再考虑 fork 补安全；官方若出真 OpenAI 上游再评估拆桥。多账号额度池一直不做。

## 交接检查

- [ ] 这台远程机：Stage A 相关改动已 commit（且尽量已 push）
- [ ] 本设计 + 本交接已在仓库里，另一台 `git pull` 能看到
- [ ] 另一台能打开 sidecar 设计
- [ ] `poc.env` / 云端 `cursor-bridge.env` 没有进 git
- [ ] 实现者知道：只 `network connect`，不重建 `cli-proxy-manager`
