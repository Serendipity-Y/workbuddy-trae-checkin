# 自动签到与余额总览 · 增强版

本项目基于 **[ggzhzc/workbuddy-trae-checkin](https://github.com/ggzhzc/workbuddy-trae-checkin)**，在原作者的 Trae / WorkBuddy / Qoder 自动签到工具上新增了一些功能。原始签到、扫码登录、通知、加密存储及控制台主体由上游提供，感谢原作者 **[ggzhzc](https://github.com/ggzhzc)** 的分享。

此仓库保留上游提交历史和原有说明。以下先介绍本分支新增的余额查询、总览页面、AgentRouter 余额接入及本地部署文件；后文为上游用法说明，并对本分支的入口和余额含义作了必要更新。

> **许可状态**：截至 2026-11-16，上游仓库未提供 LICENSE 或明确的开源许可声明。本分支未擅自为上游代码添加 MIT、Apache 等许可证；公开 fork 不代表获得任意再分发或商用授权。后续许可安排以原作者明确授权为准。参见 [GitHub 对仓库许可的说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)。

> **2026-11-17 保守模式更新**：已按四个平台核对公开证据。每账号每天最多一轮主签到；失败不立即重试，中午 12:00 后按失败分类最多补偿一次；不确定结果先只读核对。刷新列表只读缓存。今日已签按已注册平台统计，只有明确的当日签到回执才计入，余额更新不直接算已签。详见 [证据与策略](docs/risk-evidence-2026-11-17.md)。低频运行不代表平台授权，也不能保证账号不受限制。当前版本对部分签到提交后的 HTTP 5xx 会按临时失败处理，中午可能直接补偿；详见 [更新说明](CHANGELOG.md)。

本次更新的功能、时间配置与验证范围见 [更新说明](CHANGELOG.md)。

## 本分支新增了什么

| 功能 | 上游提供的能力 | 本分支的增量 |
| --- | --- | --- |
| 余额查询 | Trae 已有余额；WorkBuddy 展示连签和累计；Qoder 记录领取量 | 增加 WorkBuddy、Qoder 的剩余余额查询，并保存最近查询时间 |
| 默认主页 | 三平台完整签到控制台 | `/`、`/index.html` 改为余额总览；完整控制台移至 `/console`，两页可互相跳转 |
| AgentRouter | 没有余额接入 | 增加余额推送与读取 API、总览显示，以及控制台第四个只读标签页 |
| 本地运行 | 单文件 Worker，可云端部署 | 增加 Wrangler 配置、依赖锁文件、密钥模板和 Windows 启停/计划任务脚本 |
| 交接与部署 | 上游 README | 增加 [AI 部署说明](DEPLOY-WITH-AI.md) 和 [项目交接文档](HANDOVER.md) |

### 1. WorkBuddy 与 Qoder 剩余余额

余额与“本次签到到账”“本工具累计领取”是不同指标：余额表示平台接口报告的可用额度，累计领取只表示本工具记下的领取总量，不会因后续消费而自动扣减。

| 平台 | 查询方式与取值 | 列表 API 字段 |
| --- | --- | --- |
| Trae（沿用上游） | `creditsOf` 查询 `usage_summary`，并以 `entitlement` 兜底 | `credits` |
| WorkBuddy（新增） | `POST https://copilot.tencent.com/billing/meter/get-user-resource-summary`，读取 `data.TotalCredits`；路径没有 `/v2` 前缀 | `balance`、`balanceAt` |
| Qoder 国内版（新增） | `GET https://openapi.qoder.com.cn/api/v2/quota/usage`，将 `userQuota.remaining` 与 `addOnQuota.remaining` 相加 | `balance`、`balanceAt` |

WorkBuddy、Qoder 在账号签到流程中查询余额，并随账号记录加密保存到 KV。余额请求异常不会中断原有签到流程；此前保存的余额可能继续显示，`balanceAt` 是最近一次成功查询所记录的时间（Unix 毫秒），列表中的余额保留两位小数；没有数据时为 `null`，页面显示 `—`。WorkBuddy 列表同时补充 `today`、`signedToday`、`ranToday`，便于总览按北京时间展示状态。

**更新时机**：打开页面只读取 KV 中已存数据，不会逐个访问平台或额外轮换令牌。非强制运行可能跳过当天已完成的账号，此时也不会重新查询其余额。Qoder 当前在领取活动之前查询余额，所以本轮刚领到的额度可能要到下次实际运行才体现在余额中。

### 2. 独立的余额总览主页

- `/`、`/index.html`：按账号显示平台、账号备注、剩余余额和今日状态，支持 Trae、WorkBuddy、Qoder，以及已推送数据的 AgentRouter。
- `/console`：保留原有完整控制台，用于扫码绑定、账号管理、手动签到及通知设置，并增加 AgentRouter 标签页。
- 两个页面共用控制台样式和管理员登录凭证，业务数据接口需要 `X-Admin-Token`；未登录时可打开登录页面，不能读取账号列表。
- 行数由已绑定账号及余额记录决定；未绑定的平台不会固定显示空行。

主页打开和“刷新列表”只读取已存余额，按 `balanceAt` 显示采集时间；不再周期轮询余额，也不会触发签到。各平台独立更新，失败时保留旧数据并显示错误。自动签到每账号每天最多一轮，强制参数不能绕过每日限制；中午按失败分类最多补偿一次；不确定结果需先只读核对，风险、验证码、限流和认证失效停止自动执行。Windows helper 的配套修复、适用条件及备份回滚见 [Windows 修复说明](windows/agentrouter/README.md)；未配置该服务时会明确提示失败。

### 3. AgentRouter 外部余额接入

本分支只提供 **接收余额、保存快照和显示结果**，不包含可独立使用的 AgentRouter 账号配置或完整登录程序；`windows/agentrouter/` 提供针对现有 Windows 安装的 helper 和 Python 修补工具。外部工具取得余额后，使用管理员口令推送到 Worker：

```bash
# 先在本机配置 CHECKIN_URL 与 ADMIN_TOKEN，避免把真实口令写入仓库。
curl -X POST "$CHECKIN_URL/agentrouter/api/balance" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"label":"示例账号","balance":25.5}'

curl "$CHECKIN_URL/agentrouter/api/list" \
  -H "X-Admin-Token: $ADMIN_TOKEN"
```

| 接口 | 行为 |
| --- | --- |
| `POST /agentrouter/api/balance` | 接收 `label` 和数值 `balance`；服务端生成时间 `at`，保存到 KV 的 `agentrouter:balance` |
| `GET /agentrouter/api/list` | 返回 `{count, today, accounts}`；每个账号对象含 `label`、`balance`、`balanceAt`、`updatedToday` |

读取结果示例（以下日期和余额仅为说明格式）：

```json
{
  "count": 1,
  "today": "2026-11-16",
  "accounts": [
    {
      "label": "示例账号",
      "balance": 25.5,
      "balanceAt": 1794787200000,
      "updatedToday": true
    }
  ]
}
```

- 当前只保存 **一个余额快照**，每次推送覆盖上一次；这不是多账号数据库。
- `label` 最多保留 40 个字符；空备注在读取时显示 `agentrouter`。余额应由调用方传入明确的 JSON 数值，接口拒绝转换后非有限的数值。
- `updatedToday` 按北京时间判断今天是否推送过；`signedToday` 表示是否有当日签到确认回执。两者不是同一状态。
- 页面按美元符号和两位小数显示 AgentRouter 余额；快照没有账号令牌，也不会触发平台登录。
- 控制台内提及的 `AgentRouter-CheckIn` 任务、时间和奖励来自原本的本机配套环境，不会由本仓库自动创建，也不保证任何平台当前仍发放相同奖励。

### 4. 本地部署与 Windows 便捷脚本

云端仍可按后文方式部署。Windows、macOS、Linux 的通用本地启动方式如下；当前锁文件中的 Wrangler 要求 **Node.js 22+**：

```bash
git clone https://github.com/Serendipity-Y/workbuddy-trae-checkin.git
cd workbuddy-trae-checkin
npm ci
# 复制 .dev.vars.example 为 .dev.vars，填写 MASTER_KEY、ADMIN_TOKEN，按需填写 CRON_SECRET。
npm start
```

访问 `http://127.0.0.1:8787/` 查看余额总览，访问 `/console` 绑定账号。`MASTER_KEY` 必须备份，丢失后无法解密已保存的令牌；不要提交 `.dev.vars`、`.wrangler/` 或日志。

| 文件 | 用途 |
| --- | --- |
| `wrangler.jsonc` | Worker 入口、`KV` 绑定和云端 Cron 配置；本地可使用占位 KV ID，云端需替换为自己的命名空间 ID |
| `.dev.vars.example` | 只含空值的密钥模板 |
| `start.cmd` / `service.cmd` | Windows 前台启动与后台服务入口，后者将输出写入 `service.log` |
| `start-hidden.vbs` | 隐藏启动后台服务 |
| `stop.cmd` / `stop.ps1` | 按当前项目路径匹配并停止其 Node/workerd 进程 |
| `run-cron.cmd` | 检查本地服务是否可达，必要时启动，再携带口令调用 `/cron`；记录到 `cron.log` |
| `setup-tasks.ps1` | 注册登录启动服务，以及每天本机时间 10:00 主签到、12:00 受限补偿任务；再次执行会覆盖同名任务 |

**监听范围**：`npm start` 只监听 `127.0.0.1`；现有 Windows `start.cmd`、`service.cmd` 监听 `0.0.0.0:8787`，可能允许局域网访问。选择脚本运行时应配合防火墙或私有网络限制访问，不要直接把管理端口暴露到公网。

**定时区别**：Wrangler 本地模拟服务本身不等于已安装每天运行的调度任务。Windows 可用 `setup-tasks.ps1` 配置；macOS/Linux 需自行配置调度。云端 Cron 为 `20 2 * * *`（北京 10:20 主签到）与 `0 4 * * *`（北京 12:00 受限补偿）。URL 调用 `POST /cron` 时也会按当前北京时间自动选择主流程或补偿流程。

**兼容与范围**：保留原来的三平台签到流程、KV 前缀和加密方案；余额功能是附加查询。原有截图来自上游，展示的是原版界面，未覆盖本分支总览和 AgentRouter 标签页。各平台接口可能随版本变化，本文说明代码当前行为，不保证真实平台随时可用。

---

## 原项目使用说明（保留并适配本分支入口）

# Trae + WorkBuddy + Qoder 每日签到 · Cloudflare Worker

把三个平台的每日签到搬到云端：**不用开电脑、不用装客户端、不用守时间**。各登录一次把账号托管进去，之后 Worker 自己续期令牌、按时签到。

全部代码在 `worker.js` 一个文件里，没有构建、没有依赖，粘进 Cloudflare 网页控制台就能跑。

|        | Trae    | WorkBuddy | Qoder           |
| ------ | ------- | --------- | --------------- |
| 加账号    | 抖音扫码    | 微信扫码      | 官网设备授权（国内版）     |
| 签到内容   | 每日积分领取  | 每日签到      | 每日活动领取（credits） |
| 列表额外信息 | 余额、本次到账 | 连签天数、本期累计 | 本次到账、累计领取       |

三个平台共用一套部署、一个 KV，数据按 `trae:` / `wb:` / `qoder:` 前缀隔离。

---

## 一、部署

全程在 Cloudflare 网页控制台完成，不用装工具、不用命令行。

1. [Cloudflare Dashboard](https://dash.cloudflare.com/) → **Workers & Pages** → **Create**，起个名字（如 `signin-all`）
2. 点 **Edit code**，把 `worker.js` 全文粘进去 → **Deploy**
3. 回 Worker 设置页，加这几个绑定：

| 类型              | 名称            | 值                                            |
| --------------- | ------------- | -------------------------------------------- |
| KV Namespace 绑定 | `KV`          | 先到 **Storage & Databases → KV** 建一个命名空间，回来选中 |
| Secret          | `MASTER_KEY`  | 32 字节随机值的 base64，用来加密所有令牌                    |
| Secret          | `ADMIN_TOKEN` | 你自己定的**页面登录密码**                              |

生成主密钥：浏览器 F12 → Console 里跑

```js
btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))
```

> 结果一定是 **44 个字符、以 `=` 结尾**。`MASTER_KEY` 丢了 = KV 里的令牌全解不开，只能重新扫码，**存进密码管理器**。

1. **Settings → Triggers → Cron Triggers** 加两条：`20 2 * * *`（北京 10:20 主签到）和 `0 4 * * *`（北京 12:00 受限补偿）

---

## 二、添加账号

打开 `https://signin-all.<你的子域>.workers.dev/console`，输入 `ADMIN_TOKEN` 登录，然后按平台添加。

### Trae：抖音扫码

点「添加账号」→ 抖音扫码确认 → 浏览器会跳到一个**打不开的** `127.0.0.1` 页面（正常）→ 复制地址栏整段链接，回控制台粘到右侧输入框（粘贴即生效，不用点按钮）。

![从浏览器地址栏复制 127.0.0.1 那整段链接，粘到控制台右侧「扫码登录 · TRAE」下方的输入框](screenshot-console-trae.png)

要注意的是：**粘的是扫码之后那个 `127.0.0.1:17388/...` 的地址**，不是前面授权页的地址——图里输入框的提示文字写的也是这个。

### WorkBuddy：微信扫码

点「添加账号」→ 新窗口打开官方登录页 → 微信扫码确认 → 账号自动出现，窗口自动关闭。二维码约 5–6 分钟有效。

> 官方登录页禁止被内嵌，所以是新窗口而不是弹窗内嵌。

### Qoder：国内版设备授权

点「添加账号（国内版）」→ 在新窗口登录并确认授权 → Worker 轮询到结果后自动入库。

## 三、控制台

![签到控制台：左侧账号列表，右侧登录区](screenshot-console.png)

顶栏「今日已签」按已注册平台统计，当前为四个平台；平台下全部账号当日已确认完成才计入分子。平台注册表同时驱动余额列表、路由和调度，新增平台无需修改统计常量。账号明细数量在统计提示中显示。

![Qoder 标签页：添加账号入口、账号表与右侧卡片](screenshot-console-qoder.png)

| 标签      | 含义                       |
| ------- | ------------------------ |
| 已签      | 今天签上了，下方显示到账金额           |
| 今日未签    | 还没跑，或还没到定时时间             |
| 无可领     | 接口通了但没有可领项，下方一行写明接口返回了什么 |
| 限流 N 分钟 | 服务端限流，已按账号冷却；保守模式不自动重试        |
| 待确认     | 提交结果不明确，中午先只读核对，确认未签才允许补偿     |
| 签到失败    | 请求出错，下方显示原因              |
| 令牌失效    | 登录态失效（改过密码、在别处登出），删掉重新添加 |

> 备注名优先取账号昵称，取不到时是 `Trae-xxxx` 这类占位名。点名字或右边的铅笔可以就地改名。
>
> 「累计」是本工具自己记的领取量；本分支新增的剩余余额见主页「签到总览」，两者口径不同。

---

## 四、定时任务

### 方式一：Cloudflare 自带的 Cron（推荐）

Cloudflare 的 Cron **只认 UTC**：

| 设置 | Cron         | 北京时间  | 作用       |
| -- | ------------ | ----- | -------- |
| 主签到 | `20 2 * * *` | 10:20 | 三个内置平台各跑一轮 |
| 受限补偿 | `0 4 * * *` | 12:00 | 按失败分类最多补一次；不确定结果先核对 |

配置位置：Cloudflare 控制台 → Workers → 你的 Worker → **Settings → Triggers → Cron Triggers → Add**。

> 换算：**北京 = UTC + 8**。主签到每账号每天最多一轮；补偿每账号每天最多一次，已成功、风险、限流、认证失效或结果不明确都不补跑。

### 方式二：外部定时器

#### 1. 先设口令

Cloudflare 控制台 → Workers → 你的 Worker → **Settings → Variables and Secrets**，加一个：

| 变量名           | 类型     | 值                                        |
| ------------- | ------ | ---------------------------------------- |
| `CRON_SECRET` | Secret | 随便一串长随机字符串，比如 `openssl rand -hex 24` 的输出 |

> 不设也行，会回退用 `ADMIN_TOKEN`。但单独设一个更安全——这样定时器口令泄露了不会连带后台也被登进去。

#### 2. 调用

有两种传口令的方式，任选一种：

**方式 A：请求头（推荐）**

```bash
curl -X POST https://你的域名/cron \
  -H "X-Cron-Secret: 你的CRON_SECRET"
```

**方式 B：URL 参数**

```bash
curl -X POST "https://你的域名/cron?key=你的CRON_SECRET"
```

方式 B 适合那些不方便自定义请求头的调度器（比如某些面板的「URL 定时任务」）。

#### 3. 接到各个调度器上

**Linux / macOS 的 crontab**（北京时间 10:20 主签到、12:00 受限补偿）

```cron
20 10 * * * curl -s -X POST https://你的域名/cron -H "X-Cron-Secret: 你的CRON_SECRET" > /dev/null 2>&1
0 12 * * * curl -s -X POST https://你的域名/cron -H "X-Cron-Secret: 你的CRON_SECRET" > /dev/null 2>&1
```

**Windows 任务计划**（两次任务，或直接用仓库里的 `setup-tasks.ps1`）

```powershell
schtasks /Create /SC DAILY /ST 10:20 /TN "签到-主" /TR "curl.exe -s -X POST https://你的域名/cron?key=你的CRON_SECRET"
schtasks /Create /SC DAILY /ST 12:00 /TN "签到-补偿" /TR "curl.exe -s -X POST https://你的域名/cron?key=你的CRON_SECRET"
```



#### 4. 返回什么

```json
{
  "at": "2026-10-24 16:42:00 +08:00",
  "trae": { "accounts": 1, "checked": 1, "already": 0, "failed": 0, "results": [...] },
  "wb":   { "accounts": 1, "checked": 0, "already": 1, "failed": 0, "results": [...] },
  "qoder":{ "count": 2, "results": [...] }
}
```

各平台的 `results` 里每个账号带 `state` / `msg` / `lastCredit`。如果配了通知渠道，这里还会多一个 `notifyError`（仅当发送失败时出现）。

#### 5. 几个注意点

- **不会重复加分**：签到接口是幂等的，多调几次只是多跑几遍流程，已经领过的会显示「今日已签」。
- **同一次调用会串行跑三个平台**，整体耗时取决于账号数量，通常几秒。如果调度器有超时限制（比如 5 秒），调大一点。
- **口令错了返回 401** `{"error":"口令不对"}`；没配任何口令返回 500。
- **`/cron` 走的是 `force=false`**：账号在冷却期内、或今天已签，会直接跳过，不会硬刷接口。保守模式下不提供强制重复执行；当天失败或不确定时不自动重试。12:00 后调用会自动进入受限补偿：临时失败可直接补一次；结果不确定时先用状态接口核对，确认未签才补。

---

## 五、签到结果通知

点顶栏「通知」打开配置，两个渠道各自独立，填完点「发测试」就能立刻验证。

![通知设置：Telegram 与 QQ 机器人，密钥明文回显，下方是本机取 OpenID 的命令](screenshot-notify.png)

每轮跑完（定时任务或「全部签到」）推一条汇总，两个渠道各管各的，都不配就静默跳过。

### Telegram

1. 找 [@BotFather](https://t.me/BotFather) 发 `/newbot`，拿到 `123456:ABC...` → 填 **Bot Token**
2. 先给你的 bot 发一条消息，再打开 `https://api.telegram.org/bot<token>/getUpdates`，找 `"chat":{"id":123456789}` → 填 **Chat ID**

### QQ 官方机器人

到 [q.qq.com](https://q.qq.com) 建一个机器人，拿 **AppID** 和 **AppSecret** 填进页面。

**OpenID 用一个本机脚本拿**，不需要域名、不需要备案：

```bash
curl -O https://你的域名/qq/openid-helper.mjs && node openid-helper.mjs <AppID> <AppSecret>
```

（弹窗里有 **Windows / macOS·Linux** 切换，两条命令都按你当前系统准备好，点「复制」即可。Windows 用 `curl.exe`（PowerShell 里 `curl` 是 `Invoke-WebRequest` 的别名，不认 `-O`），macOS / Linux 用 `curl`。）

脚本会连上 QQ 的 WebSocket 网关，等你 60 秒——这期间用手机 QQ 给机器人发一条私聊消息，它就会把 `user_openid` 打印出来，然后自己退出。复制那串填进页面，保存。

### 通知长什么样

```
📋 签到完成 · 10-24 13:55
Trae  ✅ 1/1
   · 我的号 领取成功 +50 积分
WorkBuddy  ✅ 0/1 · 已签 1
Qoder  ⚠️ 1/2 · 失败 1
   · 备用号 没有可领取的活动
```

通道全部失败不影响签到结果，错误只会记在接口返回的 `notifyError` 里。

---

## 六、常见问题

| 现象                                     | 处理                                        |
| -------------------------------------- | ----------------------------------------- |
| 提示 `未配置 ADMIN_TOKEN` / `缺少 MASTER_KEY` | Secret 名字要**完全一致**，区分大小写                  |
| 提示 `MASTER_KEY 必须是 32 字节`              | 重新生成，确认 44 字符且以 `=` 结尾                    |
| 提示 `未绑定 KV`                            | KV 绑定名必须**完全等于** `KV`                     |
| 列表是空的                                  | 还没加账号，或 cron 还没到点                         |
| Trae 扫码后停在「无法访问此网站」                    | 正常，官网只回送 127.0.0.1，复制地址栏整段链接回来粘           |
| 粘贴后报「没找到 authCodeInfo」                 | 复制时漏了 `?` 后面的部分，重新全选地址栏                   |
| Trae 显示「限流 N 分钟」                       | 服务端限流，保守模式当天不自动补；先核对官方状态，次日再跑          |
| Qoder 显示「无可领」                          | 看下面那行诊断：`返回 0 条` 多为当天没活动，`CLAIMED` 说明今天已领 |
| 删掉账号重新添加却直接是「已绑定」                      | 旧版本的问题，本版已修；已出现的点「解除绑定」重来                 |
| 一直没动静                                  | 检查 cron 是否配了，注意填的是 UTC                    |
| 令牌失效                                   | 改过密码或在别处登出，删掉账号重新添加                       |

排障时可以看 Worker 详情页的 **Logs**；Qoder 的细节用 `GET /qoder/api/inspect?id=<账号id>` 看，它会返回接口实际给了几条、分别是什么类型。

---

## 七、说明

**安全**：KV 里存的是 AES-256-GCM 密文（每条记录独立 salt + IV，密钥由 `MASTER_KEY` 经 HKDF 派生）；接口不返回任何令牌；登录密码和账号令牌分离，泄露密码不等于丢号。边界是：令牌在 Worker 内存里必然有一刻是明文，云端能看到什么取决于你是否信任它——介意就部署到自己账号下。

**限制**：三个平台的接口都是逆向得到的，客户端升级可能需要跟进适配；只做签到，没做成长期任务/兑换那套；扫码依赖官方登录页。

**风险**：本项目为非官方工具， Trae、WorkBuddy、Qoder 使用风险自负。建议只给自己的账号用，多账号大规模刷积分更容易触发风控。
