# Windows AgentRouter 与四平台保守模式修复

适用目标是已诊断的 Windows 安装：`C:\agentrouter-checkin`（含 `.venv`、`login_checkin.py`、`.env`、helper 和两个计划任务）以及 `C:\workbuddy-trae-checkin`（Wrangler、Worker 和 `.dev.vars`）。不识别缺失或意外修改的版本时停止，不安装依赖、不覆盖账号配置或密钥。

## 应用与验收

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-agentrouter.ps1
```

先执行输入和旧版本哈希校验、Python生成/编译、Node/Python离线回归测试、备份与恢复自检；通过后备份并替换四个目标文件：`worker.js`、`helper.mjs`、`login_checkin.py`、`run-checkin.cmd`，并把 `AgentRouter-CheckIn`（10:20）和 `WorkBuddyCheckin-Daily`（10:00）的第二个触发时间统一调整为 12:00。只重启身份已确认的 helper，Wrangler自行加载 Worker。复制或改任务失败时恢复本次已触碰的文件和任务定义；恢复不完整会明确报告。

版本 `2026-11-17.3` 不触发真实平台验收，即使旧命令带 `-VerifyRefresh` 也不执行登录。它只读取本机缓存/汇总，并通过 `--reconcile-local` 将已匹配的历史日志补为真实回执：当天登录HTTP200、checked_in=True、余额及推送确认必须与当前快照匹配。不会修改原始余额采集时间；证据不足保持未确认，不能为显示4/4补签到。

## 每日执行规则

用户选择主签到每账号按北京时间每天最多一轮；失败后当天不自动重试，只在中午 12:00 增加一次受限补偿。Python先向本地Worker申请当日动作，再联系AgentRouter；本地不可用时不联系平台。任务和helper共用OS文件锁；成功或失败的尝试都会消耗当天额度。

中午补偿只允许以下情况：
- 主签到是普通网络/服务端暂时失败（`transient`），且当天尚未用过补偿：允许再登录一次。
- 登录已确认 `checked_in=True`、余额也已取得，但推送本地 Worker 失败（`success_unsynced`）：只从本机 `last_result.json` 补推送，不重新登录。
- 已确认成功、风险/验证码/限流/认证失效、结果不确定或已拒绝：不联系平台。

明确认证、验证码、风控、限流响应会暂停自动执行，人工核查后才能解除本地暂停。保守策略是减量措施，不是平台许可或防封承诺。

页面打开和“刷新列表”只读取已存数据，不执行签到、不周期轮询余额。平台清单来自后端注册表；按平台统计完成数，平台内全部账号有明确当日成功才计入。账号数量在提示中单独显示。余额的updatedToday与签到的signedToday不是同一字段。

当前验证目标是单机workerd；Cloudflare KV不具备分布式事务锁，多实例严格全局一次需要原子协调。未来平台适配器必须复用每日保护与缓存/确认回执契约，不能把任意外部脚本自动当成可信签到结果。

## 备份、报告与回滚

报告保存到已忽略的 `agentrouter-repair.log`。原文件、校验值、目标清单和两个计划任务的原始 XML 保存到命令打印的 `C:\agentrouter-checkin\repair-backups\<timestamp>`。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-agentrouter.ps1 -Rollback 'C:\agentrouter-checkin\repair-backups\<timestamp>'
```

只恢复本次清单里的四个文件和两个计划任务定义；目标文件若在安装后又被修改，拒绝覆盖。配置、密钥、KV历史回执和日志保留。

## 测试与证据

```sh
node tests/platforms.mjs
node tests/worker_policy.mjs
node tests/dashboard.mjs
node tests/helper.mjs
python3 tests/login_patch.py
python3 tests/manifest.py
```

测试使用模拟账号、响应和子进程，没有真实平台调用；Windows安装时会在本机运行同一组测试，并使用原生OS锁检查。安装验收读取真实本机缓存，不是新的平台签到实测。[四平台证据及适用边界](../../docs/risk-evidence-2026-11-17.md)。
