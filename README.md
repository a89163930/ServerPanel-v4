# 服务器管家 v4 · ServerPanel v4

**当前版本：4.3**（2026-11-22，R-83~R-89 长期加固系列；发布史见发布仓库 CHANGELOG）
**Current version: 4.3** (2026-11-22, R-83…R-89 long-term hardening series; release history in the publishing repository's CHANGELOG)

Windows 侧的 Linux GPU 服务器监控面板。PowerShell 7 后端 + 原生 HTML/JS 前端 + uPlot 曲线，通过常驻 SSH 流采集远端指标，界面只读本地缓存，动作走独立子进程异步执行。

**English** — Windows-hosted monitor for Linux GPU servers. PowerShell 7 backend + native HTML/JS frontend + uPlot charts. Metrics are streamed over persistent SSH sessions; the UI reads local cache files only, and every action runs as a separate asynchronous child process.

## 启动 · Startup

- 双击启动器 BAT（开发仓库 `启动-服务器管家v4.bat`，发布包 `ServerPanel.bat`）或桌面快捷方式：隐藏窗口起面板，并弹出 Edge 应用模式界面。
- 命令行：`pwsh -NoProfile -File panel.ps1`
  - `-NoBrowser`：只起后端，不弹窗口（自动化/常驻用）。
  - `-IdleSec <n>`：覆盖空闲退出秒数；`-1` 表示常驻不退出。
  - `-TestOnce`：采一轮即退出（自检）。
- 已有面板在跑时再次启动：探测到现有实例后直接为其开窗口、本实例干净退出（双启动保护）。

**English**

- Double-click the launcher BAT (`启动-服务器管家v4.bat` in the dev tree, shipped as `ServerPanel.bat`) or the desktop shortcut: starts the panel hidden and opens an app-mode Edge window.
- Command line: `pwsh -NoProfile -File panel.ps1`
  - `-NoBrowser`: backend only, no window (for automation / always-on use).
  - `-IdleSec <n>`: override idle-exit seconds; `-1` means resident, never exit.
  - `-TestOnce`: collect one round then exit (self-check).
- Re-launching while a panel is already running: detects the existing instance, opens its window directly, and this instance exits cleanly (dual-launch protection).

## 端口与访问 · Port & access

- 默认 `http://127.0.0.1:48732`（`config.json` 的 `port`）。仅绑定回环地址。
- 所有 `/api/*`（除 `/api/boot`）需 `X-Panel-Token` 头，token 每次启动随机生成，由 `/api/boot` 下发。

**English**

- Default `http://127.0.0.1:48732` (the `port` field of `config.json`). Loopback-only binding.
- Every `/api/*` endpoint except `/api/boot` requires an `X-Panel-Token` header; the token is regenerated per launch and delivered by `/api/boot`.

## 架构 · Architecture（三条主链路，勿把阻塞塞回请求线程）

- `panel.ps1`（hub）：HTTP 层只读 `state/` 缓存文件，零 SSH、零重解析。
- `agent.ps1`（每台主机一个）：维持一条常驻 SSH 流式会话，落 `latest/meta/alerts/rollup` 与瘦历史。
- `action.ps1`（每次动作一个子进程）：异步执行 kill/服务开关，结果写 `state/actions/<id>.json`。
- `collector.sh`：远端采集器（schema sp2），零安装依赖（bash+jq+coreutils+procps+iproute2，nvidia-smi 可选）。
  单进程 GPU 口径为显存（NVIDIA 不向 nvidia-smi CLI 暴露单进程算力利用率，实测 driver 580.178.04 报 "not a valid field"），并入 `procs[].gpuMemMiB`，进程表「GPU·显存」列显示 `354M (1.4%)`。
  注意：脚本只在**起流时上传一次**，改完必须重启 agent（或等会话断开重连）才生效；
  当前生效版本看「告警与审计 → 采集健康 → 采集器 <哈希>」，它等于 `collector.sh` 的 SHA256 前 12 位。

**English** (three main paths — never push blocking work back onto request threads)

- `panel.ps1` (hub): the HTTP layer reads only `state/` cache files; zero SSH, zero re-parsing.
- `agent.ps1` (one per host): maintains one persistent SSH streaming session, writing `latest/meta/alerts/rollup` plus slimmed history.
- `action.ps1` (one child process per action): asynchronously performs kill / service toggles; results land in `state/actions/<id>.json`.
- `collector.sh`: remote collector (schema sp2), zero-install dependencies (bash + jq + coreutils + procps + iproute2; nvidia-smi optional).
  Single-process GPU accounting is VRAM-based (NVIDIA does not expose per-process SM utilization through the nvidia-smi CLI — driver 580.178.04 reports "not a valid field"); values are merged into `procs[].gpuMemMiB` and shown in the process table's GPU·VRAM column as e.g. `354M (1.4%)`.
  Note: the script is uploaded once when a stream starts; after editing it you must restart the agent (or wait for the session to drop and reconnect) for changes to take effect.
  The currently effective version is visible under Alerts & Audit → Collector Health → `Collector <hash>`, equal to the first 12 hex characters of `collector.sh`'s SHA256.

## config.json 字段 · Configuration reference

- `port` / `activeHost` / `sshOpts`（`idleExitSec` 可选：给出秒数=采集全停后纯空闲多少秒退出，缺省=采集活着就不退出常驻）
- `hosts[]`：`id` `label` `sub` `sshHost`(SSH 别名) `intervalSec` `historyEverySamples` `enabled` `services[]`
  - `services[]`：`id` `kind`(systemd|pattern) `unit`/`pattern` `label` `desc` `warnIfActive` `allowEnable` `confirmStop` `startCmd`/`stopCmd`/`logCmd`
- `denyKill`：`pids[]` `userMatch[]` `cmdMatch[]`（kill 保护名单）
- `alerts[]`：`metric` `op` `threshold` `forSec` `cooldownSec` `level` `text`
- `history`：`keepDays` `maxFileMB`

**English**

- `port` / `activeHost` / `sshOpts` (`idleExitSec` optional: seconds of pure idleness after all collection stops before exiting; omitted = stay resident while any collection is alive)
- `hosts[]`: `id` `label` `sub` `sshHost` (SSH alias) `intervalSec` `historyEverySamples` `enabled` `services[]`
  - `services[]`: `id` `kind` (systemd|pattern) `unit`/`pattern` `label` `desc` `warnIfActive` `allowEnable` `confirmStop` `startCmd`/`stopCmd`/`logCmd`
- `denyKill`: `pids[]` `userMatch[]` `cmdMatch[]` (kill-protection list)
- `alerts[]`: `metric` `op` `threshold` `forSec` `cooldownSec` `level` `text`
- `history`: `keepDays` `maxFileMB`

接入新服务器：启动面板 → 右上角「主机管理」→ 填写显示名与 SSH 目标 → 先「测试连接」再「添加」，无需改配置文件、无需重启。
每台主机独立 agent 与 state 文件，前端顶部下拉切换（多项时自动变下拉，单项时只显示状态点）。

**English**

Adding a server: start the panel → top-right Host management → enter display name and SSH target → Test connection first, then Add. No config-file edit, no restart required.
Each host has its own agent and state files; the frontend switches hosts via the top dropdown (multi-host: dropdown; single host: status dot only).

## 主机管理 · Host management (v4.2)

- 界面支持：添加 / 编辑 / 启用停用 / 删除，以及添加前的 SSH 连接测试（18s 超时强杀，不会卡在密码提示上）。
- 生效时机：新主机的 agent 由面板巡检（约 700ms）自动拉起；改连接参数或停用会杀掉旧 agent 再用新配置重起。
- 安全：`sshHost`/`id` 走白名单正则（禁空白、元字符与首字符 `-`，否则可能被拼成 ssh 选项或 `-HostId` 参数）；远端探测脚本固定且 base64 传输；每次变更写 `actions.log` 审计。改坏可回滚：`Save-Config` 会先备份为 `config.json.bak`。
- 删除只移配置，`history/` 里的归档保留；`state/` 下残留的孤儿文件在下次启动时自动清理。
- 前提是该机器已配免密 SSH，弹窗底部有可直接复制的命令清单。

**English**

- UI support: add / edit / enable-disable / delete, plus an SSH connectivity test before adding (hard 18s timeout with force-kill, never hangs on a password prompt).
- Timing: a new host's agent is launched automatically by the panel's sweep (~700ms); changing connection parameters or disabling kills the old agent and relaunches with the new config.
- Safety: `sshHost`/`id` pass whitelist regex (no whitespace, metacharacters, or leading `-`, otherwise they could be spliced into ssh options or the `-HostId` parameter); the remote probe script is fixed and base64-transported; every change is audited to `actions.log`. Broken edits can roll back: `Save-Config` first backs up to `config.json.bak`.
- Deletion only removes config; archives under `history/` are kept, and orphaned files under `state/` are cleaned automatically on next start.
- Prerequisite: passwordless SSH configured on that machine; the dialog bottom shows ready-to-copy command list.

## 动作白名单 · Action whitelist（安全模型）

- 前端只传 ID（服务 id / PID），真实命令一律来自 config 白名单；远端脚本一律 base64 传输。
- kill 前校验：PID 必须在最近快照 + 不命中 denyKill；特权命令一律 `sudo -n`。
- Host 白名单(421) / Origin 校验(403) / CSP `script-src 'self'` / 无内联 onclick。

**English**

- The frontend sends identifiers only (service id / PID); real commands always come from the config whitelist; remote scripts are always base64-transported.
- Kill guard: the PID must appear in the latest snapshot and must not match `denyKill`; privileged commands always run via `sudo -n`.
- Host whitelist (421) / Origin check (403) / CSP `script-src 'self'` / no inline onclick handlers.

## 测试 · Tests

优先跑总入口：`pwsh -File build/gate.ps1`（一次跑完下面全部门禁并出汇总；exit 0=全过、1=有失败、2=有门禁因缺依赖未执行而**不是通过**）。单套调试可用 `build/gate.ps1 -Only hosts`。

- `pwsh -File build/test.ps1`：端到端验收（鉴权/采集/三档历史/kill 白名单/真实 kill/服务审计/CSP）。
- `pwsh -File build/test-hosts.ps1`：主机管理回归（中文无损落盘/15 例注入拦截/agent 随配置起停/删除回收/activeHost 迁移）。
- `pwsh -File build/test-auditpill.ps1`：app.js 呈现单元单测（审计徐章映射 + 采集健康卡片渲染，含转义与字段缺失降级，需 node）。
- `pwsh -File build/test-collector-errors.ps1`：远端采集器契约（`errors[]` 不跨样本累积 / `procTotal>=procCount` / schema sp2 / 单进程显存并入 procs 的真机金丝雀）；需免密 SSH，不满足时 exit=2 报「未执行」而非静默通过。
- `pwsh -File build/test-jsonfold.ps1`：配置写回折叠器单测（语义不变 / 危险串 / 嵌套不误折 / 幂等）。
- `pwsh -File build/test-launcher.ps1`：启动器契约——BAT 纯 ASCII/CRLF、echo 行禁圆括号，且原样复制到临时目录执行必须 rc=0（防「双击没反应」这类解析期死亡）。
- `pwsh -File build/test-loopback.ps1`：环回地址判定真值表（11 项，含 `[2001:db8::1]` / `[fe80::1]` 这类易误杀样本）。
- `pwsh -File build/test-collector-conns.ps1`：用构造样本验证外连管线（ss 列位、聚合、环回排除）——真连接不可控，静默空表只能这样锁。
- `pwsh -File build/check-live.ps1`：实时链路契约（schema / errors / portsTotal / procTotal / conns / collectorHash 是否等于当前工作区版本）。
- `pwsh -File build/test-audit-hygiene.ps1`：审计卫生门——所有测试发的 `/api/action` 必须带 `tag`，默认审计视图不得出现测试记录。
- `pwsh -File build/verify-p0.ps1`：P0 验收（forensics 契约/rollup 去重/action 竞态/exitReason）。
- `pwsh -File build/verify-chart.ps1`：图表像素级校验（DR-32）。颜色从 app.js 现场解析；温度线用「点图例前/后」差分确认像素可归属到该曲线（单靠数颜色会把右轴算进去），同时顺带验 DR-19 图例开关。
- `pwsh -File build/syntax-check.ps1`：语法门（panel/agent/action + 全部 `build/*.ps1`）。
- `build/restart.ps1`：精确识别并重启自己的 panel/agent 进程。

> 脚本与测试**必须用 pwsh 7 跑**。Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按本地 GBK 解析（中文串误报语法错），发 HTTP 请求时也会把中文请求体编码成 `?`——历史上「主机名变问号」的根因在此，不在面板代码。

**English**

Prefer the master entry: `pwsh -File build/gate.ps1` (runs all gates below in one pass and prints a summary; exit 0 = all pass, 1 = failures, 2 = a gate did not run due to missing dependency — which is **not** a pass). Single-suite debugging: `build/gate.ps1 -Only hosts`.

- `pwsh -File build/test.ps1`: end-to-end acceptance (auth / collection / three-tier history / kill whitelist / real kill / service audit / CSP).
- `pwsh -File build/test-hosts.ps1`: host-management regression (lossless Chinese write / 15 injection cases blocked / agent start-stop with config / deletion reclaim / activeHost migration).
- `pwsh -File build/test-auditpill.ps1`: app.js presentation unit tests (audit section mapping + collector-health card rendering, incl. escaping and degrade-on-missing-fields; requires node).
- `pwsh -File build/test-collector-errors.ps1`: remote-collector contract (`errors[]` never accumulates across samples / `procTotal>=procCount` / schema sp2 / live-canary merging per-process VRAM into procs); needs passwordless SSH — otherwise exit=2 reports "not executed" instead of silently passing.
- `pwsh -File build/test-jsonfold.ps1`: config-write folder unit tests (semantic invariance / dangerous strings / nested values never wrongly folded / idempotence).
- `pwsh -File build/test-launcher.ps1`: launcher contract — BAT pure ASCII/CRLF, echo lines banned from parentheses, and a verbatim copy executed from a temp dir must return rc=0 (guards against parse-time death such as "double-click does nothing").
- `pwsh -File build/test-loopback.ps1`: loopback-address decision truth table (11 rows incl. easy-to-wrongly-kill samples like `[2001:db8::1]` / `[fe80::1]`).
- `pwsh -File build/test-collector-conns.ps1`: external-connection pipeline verified with constructed samples (ss column positions, aggregation, loopback exclusion) — real connections aren't controllable, so a silent empty table can only be locked this way.
- `pwsh -File build/check-live.ps1`: live-chain contract (schema / errors / portsTotal / procTotal / conns / collectorHash equality against the current workspace version).
- `pwsh -File build/test-audit-hygiene.ps1`: audit-hygiene gate — every test-sent `/api/action` must carry a `tag`, and test records must never appear in the default audit view.
- `pwsh -File build/verify-p0.ps1`: P0 acceptance (forensics contract / rollup dedup / action race / exitReason).
- `pwsh -File build/verify-chart.ps1`: pixel-level chart verification (DR-32). Colors parsed on the fly from app.js; the temperature line is confirmed via before/after-legend-click differential that pixels belong to that curve (counting colors alone would include the right axis), while also covering the DR-19 legend toggle.
- `pwsh -File build/syntax-check.ps1`: syntax gate (panel/agent/action + all `build/*.ps1`).
- `build/restart.ps1`: precisely identifies and restarts your own panel/agent processes.

> Scripts and tests **must run under pwsh 7**. Windows PowerShell 5.1 parses BOM-less UTF-8 scripts as local GBK (false syntax errors on Chinese strings) and encodes Chinese request bodies as `?` in HTTP requests — historically the root cause of "host names turned into question marks", not a panel-code bug.

## 设计文档 · Design documentation

- 表现层设计需求与验收基线见 `docs/设计需求与评审-v4.1.md`（v4.1 已按其重构：设计系统 token、去 emoji、一主四辅、双轴图表、三态空/骨架/陈旧态、Toast 栈、就地反馈、键盘可达等）。

**English**

- Presentation-layer design requirements and acceptance baseline: `docs/设计需求与评审-v4.1.md` (v4.1 was refactored per it: design-system tokens, no emoji, one primary + four accents, dual-axis charts, empty/skeleton/stale states, toast stack, inline feedback, keyboard reachability, etc.).

## 已知限制 · Known limitations

- 关窗空闲退出后采集随之停止（如需 7×24 采集与告警，用 `-NoBrowser -IdleSec -1` 常驻 + 计划任务开机自启）。双击启动器时也可给系统设置环境变量 `SP_IDLE=-1` 再双击，实现常驻（BAT 会把它透传给面板）。
- v4.2.1 起对睡眠/挂起恢复做了宽限：机器从睡眠醒来时不会因「墙钟漂移」被空闲判定当场收走，恢复事件与退出原因都会留痕到 `log/panel-run.log`。
- 双击启动器时若已有面板在跑，不会再开第二个同样的窗口，而是把现有面板窗口置到前台；若面板活着但 --app 窗口已被关掉（或残留空白僵尸栈），会清掉旧会话后补开一扇新窗——每次双击后桌面永远恰好一扇可见面板窗（R-89）。专用 profile 默认复用不重建，常态启动秒级出现标题窗，不再长时间显示「URL 主机名 + 转圈」的冷加载态（R-89a）；开窗一律禁用扩展（`--disable-extensions`）并等「真实带标题的面板窗」出现才判定成功，Edge 预装扩展抢占标签/改写标题不再干扰起窗（R-87/R-88b）。日志按实例分文件：`log\panel-run.<pid>.log`，生命周期标记仍单写 `log\panel-run.log`。
- 多卡已支持（`gpus[]` 数组，GPU 主卡聚合+逐卡明细）；端口归属需 root，非 root 时界面明确标注「需 root 查看归属」。
- 窗口最小化或标签页切到后台时，浏览器会节流定时器，“已同步”时间看起来会停止刷新；回到前台或刷新即恢复，不是采集塔了（看 `state/meta-<id>.json` 的 `ageSec` 为准）。
- 面板只能管远端 Linux 主机，本机（Windows）服务不在可见范围内；OpenSquilla 网关实际跑在本机 `127.0.0.1:18791`，而 `config.json` 中 `gpu3090` 的 `gateway` 服务条目仍指向服务器上的旧路径（该目录不存在），点「启动」会如实报告失败（见设计文档 R-44/DR-37）。

**English**

- After an idle exit triggered by closing the window, collection stops too (for 7×24 collection and alerting, run resident with `-NoBrowser -IdleSec -1` plus a scheduled task at boot). You can also set the system environment variable `SP_IDLE=-1` and double-click again to run resident (the BAT passes it through to the panel).
- Since v4.2.1, sleep/resume wakes get a grace period: waking from sleep won't have the panel killed on the spot by an idle decision caused by wall-clock drift; resume events and exit reasons are both logged to `log/panel-run.log`.
- Double-clicking the launcher while a panel is already running brings the existing panel window to the foreground instead of opening a second identical window; if the panel is alive but its --app window was closed (or a blank zombie stack remains), the old session is cleared and one fresh window opens — exactly one visible panel window on the desktop after every double-click (R-89). The dedicated profile is reused rather than rebuilt by default, so normal starts show a titled window within seconds instead of lingering in the cold-loading "URL hostname + spinner" state (R-89a); windows always open with extensions disabled (`--disable-extensions`) and success requires a real titled panel window to appear, so Edge preinstalled extensions grabbing tabs/rewriting titles no longer interfere (R-87/R-88b). Logs are per-instance: `log\panel-run.<pid>.log`; lifecycle markers still go to `log\panel-run.log`.
- Multi-GPU is supported (`gpus[]` array, primary-card aggregation + per-card detail); port ownership needs root — the UI explicitly labels "needs root to view ownership" for non-root users.
- When the window is minimized or its tab goes background, browsers throttle timers, so the "synced" timestamp may appear frozen; returning to the foreground or refreshing restores it — collection is not stalled (use `ageSec` in `state/meta-<id>.json` as the source of truth).
- The panel manages remote Linux hosts only; local (Windows) services are out of scope; the OpenSquilla gateway actually runs on this machine at `127.0.0.1:18791`, while the `gateway` service entry under `gpu3090` in `config.json` still points to a stale path on the server (that directory doesn't exist), so clicking Start reports the failure honestly (see the design doc R-44/DR-37).