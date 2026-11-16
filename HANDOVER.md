# 项目交接提示词（HANDOVER）

> 用途：把本仓库交接给另一位工程师或 AI 编码助手时，把下面「提示词正文」整段发给它，让它快速理解项目、接手维护与继续开发。全文已脱敏，不含任何账号/密钥/主机信息。

---

## 提示词正文

你正在接手一个名为 **workbuddy-trae-checkin** 的开源项目：一个基于 **Cloudflare Worker** 的单文件服务，为 **Trae / WorkBuddy / Qoder** 三个平台做每日自动签到，并提供一个 Web 控制台和一个「余额总览」仪表盘。请先完整阅读本文件与 `worker.js`，再动手改动。

### 1. 运行形态与技术栈
- 单文件 Worker：`worker.js`，标准 `export default { fetch, scheduled }`，**无构建、无第三方运行时依赖**（只用到 Web 标准 API：`fetch`、`crypto.subtle`、`TextEncoder`、`URL`、`Response` 等）。
- 运行方式有两种：
  - **本地模拟**：`wrangler dev`（workerd），KV 落在本地 `.wrangler/state`。
  - **云端**：部署到 Cloudflare Workers + KV，Cron `10 0 * * *`。
- `package.json` 只有 devDependency `wrangler`；`wrangler.jsonc` 里 KV 绑定名必须叫 `KV`。

### 2. 代码地图（按功能，不依赖行号）
`worker.js` 由三块平台模块 + 一段顶层装配组成，三个平台都是 IIFE（`const Trae = (() => {...})()` 这类），各自导出 `fetch` / `scheduled`：
- **Trae 模块**：扫码授权、PKCE/ECDSA、令牌交换、签到（`checkin_credits`）、余额 `creditsOf`（`usage_summary` + `entitlement` 兜底）。
- **WorkBuddy 模块**：微信扫码登录、`/v2/billing/meter/daily-checkin` 签到、`checkin-activity-status` 状态、余额 `resourceBalance`（`/billing/meter/get-user-resource-summary`，注意**不带 `/v2`**）。
- **Qoder 模块**：国内版设备授权、`campaigns` 领取、余额 `quotaBalance`（`/api/v2/quota/usage`，`userQuota.remaining + addOnQuota.remaining`）。
- 顶层：`runAll()` 串行跑三个平台；`PAGE`（完整控制台 `/console`）；`DASHBOARD`（默认主页 `/`，复用 `PAGE` 的 `<style>`）；路由分发；AgentRouter 余额的推送/读取接口。

### 3. 数据与 KV
- KV 以前缀隔离：`trae:` / `wb:` / `qoder:`。
- 每个账号一条记录键：`<prefix>acct:<id>`；索引键：`<prefix>index:accounts`。
- 通知配置：`notify:config`。
- AgentRouter 余额快照：`agentrouter:balance`（`{label, balance, at}`）。
- 账号记录经 **AES-256-GCM** 加密后存储，密文盒格式 `{v:1, s:salt, i:iv, d:ct}`；密钥由 `MASTER_KEY` 经 **HKDF-SHA256** 派生，`info` 字符串按平台不同（如 `trae-signin/v1/account`、`wb-signin/v1/account`、`qoder-signin/v1/account`）。
- **重要**：`MASTER_KEY` 丢失 = 所有已存令牌不可解密，只能重新绑定；请务必提示用户备份，且永远不要把令牌/密钥回显到页面或日志。

### 4. 路由清单
- `/`、`/index.html`：余额仪表盘（`DASHBOARD`）。
- `/console`：完整控制台（`PAGE`）。
- `/cron`：定时入口，口令走 `X-Cron-Secret` 头或 `?key=`（未配置则回退 `ADMIN_TOKEN`）。
- `/oauth/callback`、`/oauth/probe`：Trae 授权回调与探活。
- `/api/ping`、`/api/run-all?force=1`、`/api/notify`(GET/POST)、`/api/notify/test`：管理接口（需 `X-Admin-Token`）。
- `/trae/api/*`、`/wb/api/*`、`/qoder/api/*`：转发到各平台模块内部的 `/api/*`（list/run/rename/remove/login 等）。
- `/agentrouter/api/balance`(POST) 与 `/agentrouter/api/list`(GET)：接收/读取**外部本机脚本**推送的 AgentRouter 余额。

### 5. 余额口径（已实测）
- Trae：列表字段 `credits`。
- WorkBuddy：`POST https://copilot.tencent.com/billing/meter/get-user-resource-summary` → `data.TotalCredits`（**路径不带 `/v2`，带就 404**）。
- Qoder：`GET https://openapi.qoder.com.cn/api/v2/quota/usage` → `userQuota.remaining + addOnQuota.remaining`。
- 余额在每次签到运行时抓取并写入账号记录（`balance` / `balanceAt` 或 `credits`），列表接口透出；仪表盘与 `/console` 的 AgentRouter 标签据此展示。**不要**在每次打开页面时重新抓余额（会触发令牌轮换与额外请求）。

### 6. 定时、幂等与 force
- 计划任务建议：登录自启 + 每天 10:00 主签到 + 11:00 备份（Qoder 领取窗口约 10:00 开启）。
- `/cron` 走 `force=false`：账号当天已成功或处于冷却期会跳过；`/api/run-all?force=1` 强制重跑。
- 各平台签到接口幂等，重复跑不会重复加分。
- 注意 Qoder 的 `already`（活动已是 CLAIMED）**不应**当作"今天已完成"而跳过——官方可能在 10:00 后补发新活动。

### 7. 部署
- 本地：`npm install` → 复制 `.dev.vars.example` 为 `.dev.vars` 并填 `MASTER_KEY`/`ADMIN_TOKEN`(/`CRON_SECRET`) → `npx wrangler dev --ip 127.0.0.1 --port 8787`。
- 云端：创建 KV、填真实 id、`wrangler deploy`，并配置 Cron。
- Windows 便捷脚本：`start.cmd` / `service.cmd` / `stop.cmd` / `run-cron.cmd` / `start-hidden.vbs` / `setup-tasks.ps1`（均为路径无关）。
- 详细部署步骤见 `DEPLOY-WITH-AI.md`。

### 8. 安全边界
- 仅管理员（`ADMIN_TOKEN`）可访问控制台/列表；接口不返回令牌。
- 不要把控制台直接暴露公网；远程访问建议用私有网络（如 Tailscale）并按网段限制端口。
- `.dev.vars`、`.wrangler/`、`*.log` 不入库（`.gitignore` 已覆盖）。

### 9. 相对上游的定制（维护时注意）
本仓库在原始 `worker.js` 基础上新增：
1. **余额抓取**：WorkBuddy `resourceBalance`、Qoder `quotaBalance`，并在 `signinOne` 后落库；列表透出 `balance`/`balanceAt`。
2. **余额仪表盘**：默认 `/` 为极简余额表，`/console` 保留完整控制台；`DASHBOARD` 通过正则复用 `PAGE` 的 `<style>`。
3. **AgentRouter 展示**：`/agentrouter/api/balance`(POST) + `/agentrouter/api/list`(GET)，以及 `/console` 的 AgentRouter 标签（只读）。**注意**：AgentRouter 的真实签到逻辑不在本仓库，由外部本机脚本执行后把余额推送到该接口。

升级上游或重构时，请保留以上行为与接口契约（尤其 `agentrouter:balance` 的字段、`/agentrouter/api/list` 的返回结构）。

### 10. 验证清单（改完必跑）
1. `curl -s http://127.0.0.1:8787/` 含「签到总览」。
2. `curl -s -H "X-Admin-Token: <token>" http://127.0.0.1:8787/api/ping` → `{"ok":true}`。
3. 三个 `/<p>/api/list` 正常返回；`/agentrouter/api/list` 返回推送的余额。
4. `POST /cron`（带上口令）返回三平台 summary，`failed` 为 0。
5. 浏览器：`/` 仪表盘四行（含 AgentRouter）、`/console` 四个标签页、`余额总览`↔`完整控制台` 互跳正常。

### 11. 已知限制 / 易踩坑
- 三个平台的接口均为逆向，客户端/官网升级可能失效，需按新抓包调整常量与路径。
- WorkBuddy 资源汇总接口**没有** `/v2` 前缀；Qoder 余额在 `/api/v2/quota/*`（不是 `/sash/api/v1/me/*`）。
- 本地若 shell 导出了异常 `NO_PROXY`（含 `[::1]` 等），基于 httpx 的第三方脚本可能报 `Invalid port`；本 Worker 不读环境代理。
- Trae 扫码回调固定 `http://127.0.0.1:17388/...`，需用户把地址栏整段链接粘回控制台绑定。
- 令牌轮换：刷新令牌后必须把新令牌落库，否则令牌链会断。

### 12. 扩展新平台的建议步骤
1. 新建 IIFE 模块，实现 `fetch`/`scheduled`，复用 `kvScope` 前缀、`sealRecord`/`openRecord` 加密。
2. 在顶层 `runAll` 与路由 `/<name>/api/*` 中接入。
3. 在 `handleList` 中透出 `balance`，并在 `signinOne` 后抓余额落库。
4. 前端：在 `PAGE` 增加标签页与渲染函数；在 `DASHBOARD` 增加一行。
5. 跑第 10 节验证清单。

### 13. 交接自检
- [ ] 已能本地启动并登录控制台
- [ ] 已理解 KV 键与加密方案
- [ ] 已理解三个平台的余额来源与签到幂等语义
- [ ] 已确认 AgentRouter 为"外部脚本推送"模式
- [ ] 已跑通第 10 节验证清单

---

## 提示词正文结束

把上面内容整段发给接手方即可。维护时请同步更新本文件与 `DEPLOY-WITH-AI.md`。
