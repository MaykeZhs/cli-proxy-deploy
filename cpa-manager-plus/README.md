# CPA-Manager-Plus（用量统计 + 计费预估面板）

外置监控面板：读取 CLIProxyAPI 的 **usage 队列**，做请求监控 + 用量/成本分析（按模型、provider、凭证、API key、项目、渠道、时间窗口拆分成本/tokens/缓存/延迟/失败率），可**编辑各模型单价来估算花费**。

独立进程运行，**不装进代理、不接管你的凭证**，比代理内的第三方插件安全。

## 前置条件

- CLIProxyAPI 已开启 `usage-statistics-enabled: true`（本项目已在线上打开）。
- CPA 版本 ≥ v6.10.8（HTTP usage 队列）；你线上是 v7.2.47 ✓，且 v7.0.7+ 还支持 Redis 实时推送。
- 一台装了 Docker、且能访问到你 CPA 的主机。
- ⚠️ 同一个 CPA 队列**只跑一个** CPA-Manager-Plus 实例（队列是消费型，多个实例会把记录分走、统计不全）。

## 1) 启动容器

在能访问 CPA 的主机上（本仓库 `cpa-manager-plus/` 目录里）：

```bash
docker compose up -d
```

## 2) 拿到面板 admin key（首次必看）

首次启动时，Manager Server 会把 **admin key（形如 `cmp_admin_...`）打印在日志里**：

```bash
docker logs cpa-manager-plus | grep -i admin
```

把这个 `cmp_admin_...` 记下来 —— 这是登录面板用的密钥（和 CPA 的 management key 不是一回事）。

## 3) 打开面板并完成首次连接

面板默认只监听服务器本机，避免把管理入口直接暴露到公网。先在你的电脑上建立 SSH 转发：

```bash
ssh -N -L 18317:127.0.0.1:18317 root@<服务器IP>
```

保持 SSH 连接运行，然后在本机浏览器打开 `http://127.0.0.1:18317`，首次进入按向导填：

- **Admin Key**：上一步 `cmp_admin_...`
- **CPA 地址 / Base URL**：
  - 跑在**别的机器 / 你本地 Windows Docker Desktop** → 填公网地址 `https://api.raytrade.cloud`
  - 跑在**CPA 同一台服务器**上 → 填 `http://127.0.0.1:8317`
  - （Docker Desktop 连宿主机 CPA 也可用 `http://host.docker.internal:8317`）
- **CPA Management Key**：你 CPA 的管理密钥（会被加密存进 `/data`）

以后登录只需要 Admin Key。连上后它就开始消费 CPA 的 HTTP usage 队列，写进本地 SQLite，做实时监控与历史分析。

## 4) 计费预估

在面板的 **定价 / Pricing** 设置里给用到的模型填单价（如 `gpt-5-codex`、`glm-5.2`），面板用 token 用量 × 单价算出预估花费。

> GLM Coding Plan 是固定套餐、不按 token 计费，所以 GLM 的“花费”只是参考；套餐额度以智谱控制台为准。Codex/按量类的才是真实计费预估。

## 参考

- 项目：https://github.com/seakee/CPA-Manager-Plus
- 部署与排错见其 Wiki。
