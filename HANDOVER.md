# 项目交接提示词（HANDOVER）

> 用途：把本仓库交接给另一位工程师或 AI 编码助手时，把下面「提示词正文」整段发给它，让它快速理解项目、接手维护与继续开发。全文已脱敏，不含任何账号/密钥/主机信息。

---

## 提示词正文

你正在接手一个名为 **workbuddy-trae-checkin** 的开源项目：一个基于 **Cloudflare Worker** 的单文件服务，为 **Trae / WorkBuddy / Qoder** 三个平台做每日自动签到，并提供一个 Web 控制台和一个「余额总览」仪表盘。请先完整阅读本文件与 `worker.js`，再动手改动。

### 1. 运行形态与技术栈
- 单文件 Worker：`worker.js`，标准 `export default { fetch, scheduled }`，**无构建、无第三方运行时依赖**（只用到 Web 标准 API：`fetch`、`crypto.subtle`、`TextEncoder`、`URL`、`Response` 等）。
- 运行方式有两种：
  - **本地模拟**：`wrangler dev`（workerd），KV 落在本地 `.wrangler/state`。
  - **云端**：部署到 Cloudflare Workers + KV，Cron `20 2 * * *`（北京 10:20 主签到）+ `0 4 * * *`（北京 12:00 受限补偿）。
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
- 计划任务：登录自启 + 每天 10:00 主签到 + 12:00 受限补偿（Qoder 领取窗口约 10:00 开启）。Cloudflare Cron 对应 `20 2 * * *`（北京 10:20）与 `0 4 * * *`（北京 12:00）。
- `/cron` 在 12:00 前走主流程，12:00 后走 `compensate`；账号当天已成功或处于冷却期会跳过。`/api/run-all?force=1` 不能绕过当日尝试，也不触发补偿。
- 补偿按结果分类：`transient` 可直接补一次；`uncertain` 先只读核对，确认未签才补；风控/验证码/限流/令牌失效停止。提交后 HTTP 5xx 的分类存在重复提交风险，详见 `CHANGELOG.md`。
- 各平台签到接口幂等，但补偿仍限制为每账号每天最多一次。
- 注意 Qoder 的 `already`（活动已是 CLAIMED）**不应**当作"今天已完成"而跳过——官方可能在 10:00 后补发新活动。当前用 `wait` 等状态表达，并在中午只读核对一次。

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

### 9.1 AgentRouter 可靠性修复（2026-11-17）
- 总览每 30 秒及重新激活时只读 KV；各平台独立读取，显示余额实际采集时间及错误，请求有超时。
- `windows/agentrouter/` 提供 helper、原有 Python 的定点修补工具和验证；helper 与计划任务复用同一执行入口；页面刷新只读缓存。缺余额/推送失败不能返回成功，零余额有效，OS 文件锁防止并发登录。
- `repair-agentrouter.ps1` 针对已核对的 Windows 目录安装，校验输入/原文件、备份、替换后检查，仅重启目标 helper，并提供限定文件范围的回滚。配置和密钥不被替换。详见 `windows/agentrouter/README.md`。

### 9.2 中午受限补偿（2026-11-17.3）
- 主签到仍为每账号每天最多一轮；失败当天不自动重试。12:00 后 `/cron` 以 `compensate` 模式运行，只对 `transient`（普通网络/服务端暂时失败）允许一次。
- Trae 用 `checkin_credits/status`、WorkBuddy 用 `checkin-activity-status`、Qoder 用活动列表做只读核对；`uncertain` 结果先核对，确认已签则本地补记，确认未签才补一次，核对不可用则停止。
- AgentRouter 的 `/agentrouter/api/permit` 返回 `run` / `sync` / `none`；Python 通过 `/agentrouter/api/attempt` 上报 `transient|uncertain|rejected|blocked|success|success_unsynced`。登录成功但推送失败时写本机 `last_result.json`，中午只补推送，不重新登录。
- Windows 安装脚本默认将 `AgentRouter-CheckIn` 和 `WorkBuddyCheckin-Daily` 的第二个触发时间设为 12:00。若手动设置错峰，以本机任务计划为准；再次运行安装脚本可能恢复默认时间。修复脚本保存原始任务 XML，回滚时一并恢复。

### 10. 验证清单（改完必跑）
1. `curl -s http://127.0.0.1:8787/` 含「签到总览」。
2. `curl -s -H "X-Admin-Token: <token>" http://127.0.0.1:8787/api/ping` → `{"ok":true}`。
3. 三个 `/<p>/api/list` 正常返回；`/agentrouter/api/list` 返回推送的余额。
4. `POST /cron`（带上口令）返回三平台 summary，`failed` 为 0；12:00 后返回 `mode: "compensate"`，已成功账号不产生平台请求。
5. 浏览器：`/` 仪表盘四行（含 AgentRouter）、`/console` 四个标签页、`余额总览`↔`完整控制台` 互跳正常。
6. 补偿演练（离线）：构造 `lastAttemptOutcome` 为 `transient` / `uncertain` / `blocked` 的账号，确认 `transient` 最多补一次，`uncertain` 必须核对，`blocked` 停止。

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

### 2026-11-17.2 保守模式与统计
- 以 `docs/risk-evidence-2026-11-17.md` 的证据和适用范围为准；每天最多一轮是用户选择的减量策略，不是官方安全阈值。
- `PLATFORMS` 是平台清单的唯一来源，`/api/platforms` 提供发现，`/api/summary` 从本地缓存生成平台完成数。未来平台实现必须复用每日工作流保护及缓存列表/确认回执契约。
- 页面“刷新列表”不触发签到；重复执行和force参数不能绕过当日尝试。旧记录当天已执行过时也跳过，主流程失败不自动重试（.3 起仅增加中午一次受限补偿）。
- AgentRouter 接收独立的签到确认，不再把updatedToday当作signedToday。迁移仅匹配本机既有日志及缓存，不发平台请求。

### 2026-11-17.3 中午补偿
- 主签到后中午增加一次受限补偿，所有状态持久化：`lastAttemptOutcome`、`compensationDate`。只有 `transient` 可直接补；`uncertain` 必须先只读核对，核对不可用或结果不明时停止。
- `/api/platforms` 的 policy 增加 `noonCompensationsPerAccountPerDay: 1`；Dashboard meta 为 `daily-once-with-noon-compensation-2026-11-17.3`。
- AgentRouter 的补偿动作由本地 Worker 决定：`run`、`sync`、`none`；Python 只执行返回的动作，不自行猜测。
- 新增平台时需同时实现：主签到结果分类（至少 success/transient/uncertain/rejected/blocked）和可选的只读核对函数；否则不确定结果不会补跑。

### 2026-11-17 运维增强：错峰、邮件提醒与基线自维护
- 安装脚本默认触发时间：`AgentRouter-CheckIn` 10:20 + 12:00；`WorkBuddyCheckin-Daily` 10:00 + 12:00。实际任务可能经过手动调整，以本机任务计划为准；默认策略标记为 `daily-once-with-noon-compensation-2026-11-17.3`。
- 可按需配置计划任务运行 `notify-daily.ps1`（例如每日 12:30）；该脚本读本机 `/api/summary`（`ADMIN_TOKEN` 取自 `.dev.vars`），发送 HTML 卡片邮件（`smtp.qq.com:587` STARTTLS）；4/4 主题为 `[签到完成]`，否则为 `[签到异常]` 并列出未完成平台。只读缓存，不产生平台请求。
- 邮件凭据：`mail.config.json` 中为 Windows DPAPI 加密串，绑定当前用户；由 `setup-mail-config.ps1` 交互录入（`Read-Host -AsSecureString`），脚本不含地址与授权码。更换授权码后重跑该脚本即可。
- `repair-agentrouter.ps1`：每次运行额外写 `agentrouter-repair-<时间戳>.log` 保留历史；安装成功后 `Update-Baseline` 把本次 Worker/Helper/Run 的归一化哈希追加进 `windows/agentrouter/manifest.json`，避免下一版因“基线漏收上一版产出”而中断。
- manifest 中允许的旧版本基线应来自已核对的安装产物；部署前请结合本机备份中的 `manifest.json` 校验。
- 环境注意：部分工具终端中的 PowerShell `Add-Content` 曾出现异常；邮件脚本使用 `[IO.File]::AppendAllText`，目标机器的运行效果应自行验证。
- 邮件与任务回滚：如已创建 `Checkin-Daily-Email`，可用 `Unregister-ScheduledTask` 停止该任务；任务触发时间可由本次备份目录中的任务 XML 用 `Register-ScheduledTask -Xml` 还原。
