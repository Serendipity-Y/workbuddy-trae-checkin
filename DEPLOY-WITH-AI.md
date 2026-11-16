# 供 AI 一键部署的提示词（DEPLOY-WITH-AI）

> 把下面「提示词正文」整段复制给你的 AI 编码助手（Qoder / Claude Code / Cursor Agent 等），它即可按步骤在本机完成部署。

---

## 提示词正文

你是一个部署助手。请在用户本机（Windows 10/11）部署本项目：一个基于 Cloudflare Worker 的单文件服务，用于 **Trae / WorkBuddy / Qoder** 三个平台的每日自动签到，带 Web 控制台与「签到总览」余额仪表盘。

项目根目录即当前目录，核心文件：
- `worker.js`：全部后端逻辑（无构建、无依赖，标准 `export default { fetch, scheduled }`）。
- `wrangler.jsonc`：本地/云端运行配置（KV 绑定名必须是 `KV`，cron `10 0 * * *`）。
- `.dev.vars.example`：密钥模板；复制为 `.dev.vars` 后填写。
- `package.json`：仅 devDependency `wrangler`。
- `start.cmd` / `service.cmd` / `stop.cmd` / `run-cron.cmd` / `start-hidden.vbs` / `setup-tasks.ps1`：Windows 启动、停止、每日触发与计划任务脚本（路径无关，使用 `%~dp0` / `$PSScriptRoot`）。
- `README.md`：功能与用法说明；`screenshot-*.png`：界面截图。

### 目标
1. 在本机用 Wrangler 本地模拟运行该 Worker（监听 `127.0.0.1:8787`）。
2. 生成密钥、写入 `.dev.vars`，启动服务并在浏览器验证控制台。
3. 配置 Windows 计划任务：登录自启 + 每天 10:00 主签到 + 11:00 备份。
4. 不把任何密钥提交进 git。

### 前置条件
- 已安装 Node.js 22+（当前锁文件中的 Wrangler 要求）（`node -v`、`npm -v` 可用）。
- 本机可访问外网（各平台均为 HTTPS 接口）。

### 步骤

**1. 安装依赖**
```
cd <项目目录>
npm install --no-audit --no-fund
npx wrangler --version
```

**2. 生成密钥并写 `.dev.vars`**
- 复制 `.dev.vars.example` → `.dev.vars`。
- 生成 MASTER_KEY（32 字节 base64，44 字符、以 `=` 结尾）：
  `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`
- 生成 ADMIN_TOKEN（控制台登录密码）：
  `node -e "console.log(require('crypto').randomBytes(12).toString('hex'))"`
- CRON_SECRET（可选；留空则回退用 ADMIN_TOKEN）。
- 关键提醒：`MASTER_KEY` 用于 AES-256-GCM 加密所有账号令牌，丢失后已存账号无法解密，只能重新扫码；请提示用户备份。

**3. KV 配置**
- 本地开发不需要真实 KV id，`wrangler.jsonc` 中的占位 id 即可。
- 部署到 Cloudflare 时：`npx wrangler kv namespace create KV`，把真实 id 填入 `wrangler.jsonc` 的 `kv_namespaces[0].id`。

**4. 本地启动并验证**
```
npx wrangler dev --ip 127.0.0.1 --port 8787
```
验证：
- `curl -s http://127.0.0.1:8787/` 返回「签到总览」仪表盘。
- `curl -s -H "X-Admin-Token: <ADMIN_TOKEN>" http://127.0.0.1:8787/api/ping` 返回 `{"ok":true}`。
- `GET /trae/api/list`、`/wb/api/list`、`/qoder/api/list`（带 `X-Admin-Token`），初始 `count: 0`。

**5. 浏览器验证**
- 打开 `http://127.0.0.1:8787/`，用 ADMIN_TOKEN 登录，默认页是「签到总览」；点「完整控制台」进入 `/console` 扫码绑定账号。

**6. 计划任务（Windows）**
```
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-tasks.ps1
```
注册 `WorkBuddyCheckin-Service`（登录自启）与 `WorkBuddyCheckin-Daily`（每天 10:00 + 11:00）。`.\stop.cmd` 停止，`.\start.cmd` 前台调试。

### 路由与余额来源
- `/`：签到总览仪表盘（表格：平台/账号/剩余余额/今日状态）。
- `/console`：完整控制台（账号绑定、通知配置、手动签到）。
- `/cron`：定时入口（`X-Cron-Secret` 或 `?key=`）。
- 余额接口（已在项目内验证）：
  - Trae：`creditsOf`（usage_summary / entitlement）→ 列表 `credits`。
  - WorkBuddy：`POST https://copilot.tencent.com/billing/meter/get-user-resource-summary`（**不带 `/v2`**）→ `data.TotalCredits`。
  - Qoder：`GET https://openapi.qoder.com.cn/api/v2/quota/usage` → `userQuota.remaining + addOnQuota.remaining`。
- AgentRouter（可选扩展）：本仓库含 `/agentrouter/api/balance`(POST) 与 `/agentrouter/api/list`(GET)，用于接收外部本机脚本推送的余额并在仪表盘/控制台展示；不含 AgentRouter 的签到逻辑，需另配本机脚本。

### 安全要求
- 绝不提交 `.dev.vars`、`.wrangler/`、`*.log`（`.gitignore` 已覆盖）。
- 接口不返回令牌；不要在任何页面/日志回显令牌。
- 远程访问控制台时优先用私有网络（如 Tailscale），并按网段限制端口暴露。
- 完成后向用户汇报：控制台地址、密码存放位置、计划任务名称、MASTER_KEY 备份提醒。

### 排障
- `未配置 ADMIN_TOKEN` / `缺少 MASTER_KEY` / `未绑定 KV`：检查 `.dev.vars` 大小写与 KV 绑定名是否为 `KV`。
- `MASTER_KEY 必须是 32 字节`：重新生成 44 字符、以 `=` 结尾的 base64。
- 端口占用：改 `--port` 或先运行 `stop.cmd`。

---

## 提示词正文结束

把上面内容整段发给 AI 即可开始。
