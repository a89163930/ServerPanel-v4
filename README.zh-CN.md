# 服务器管家（ServerPanel）

Windows 上的 Linux GPU 服务器监控面板。

每台远端主机维持一条常驻 SSH 流采集指标；网页界面只读本地缓存文件（请求线程零 SSH），
所有控制动作都作为独立异步子进程、针对命令白名单执行。

**版本 4.3** · 2026-11-22 · 发布历史：[CHANGELOG.md](CHANGELOG.md) · 安全策略：[SECURITY.md](SECURITY.md)

## 能干什么

- **实时监控** —— CPU（总量 + 每核负载）、内存、swap、各挂载点磁盘、网络速率、进程排行、
  systemd 单元与模式匹配的服务，全部来自常驻 SSH 流（远端只需 `bash + jq + coreutils +
  procps + iproute2`，`nvidia-smi` 可选）。
- **GPU 指标** —— 逐卡显存、温度、利用率、功耗；单进程显存份额并入进程表（如 `354M (1.4%)`）。
  支持多卡（主卡聚合 + 逐卡明细）。
- **告警** —— 规则 DSL（`metric op threshold forSec cooldownSec`，级别 `warn` / `bad`，
  `{value}` 模板），并且能检测「永远不会触发的死规则」并在界面上报出来。
- **远程控制** —— 启停 / kill 一律由 config 白名单解析，前端只传标识符；
  `denyKill`（PID、用户、命令模式）保护名单，特权操作走 `sudo -n`。
- **历史与图表** —— 三档历史（近期 / 瘦身 / 归档），页面内 uPlot 双轴图表渲染。
- **多主机管理** —— 界面内添加 / 编辑 / 启用停用 / 删除主机，含 SSH 连接测试（硬 18s 超时）。
  每台主机独立 agent 与 state 文件，无需改配置文件、无需重启。
- **审计留痕** —— 每次动作记录身份、时间戳、结果码与输出摘要；远端探测脚本一律 base64 传输。

## 快速开始

要求：Windows + PowerShell 7，各主机已配好免密 SSH。

```text
双击 ServerPanel.bat          # 隐藏窗口起后端 + Edge 应用模式窗口
pwsh -NoProfile -File panel.ps1   # 命令行方式
```

| 参数 | 作用 |
|---|---|
| `-NoBrowser` | 只起后端，不弹窗口（自动化 / 常驻用） |
| `-IdleSec <n>` | 覆盖空闲退出秒数；`-1` = 常驻不退出 |
| `-TestOnce` | 采一轮即退出（自检） |

已有面板在跑时再次启动：会探测到现有实例、把它的窗口置到前台，本实例干净退出。
每次启动后桌面上永远恰好一扇可见面板窗。

## 安全模型

- HTTP 只绑定回环地址（默认 `http://127.0.0.1:48732`）。
- 除 `/api/boot` 外所有 `/api/*` 需要 `X-Panel-Token` 头，token 每次启动随机生成。
- Host 白名单（421）、Origin 校验（403）、CSP `script-src 'self'`、无内联处理器。
- 远端命令只来自 config 白名单，请求体内容绝不拼进远端 shell。完整威胁模型见 [SECURITY.md](SECURITY.md)。

## 架构

```text
panel.ps1（hub，HTTP）
  只读 state/*.json 缓存      <- 由 agent.ps1（每台主机一个）写入
                                 常驻 SSH 流 -> collector.sh
                                 （每条流起流时上传一次）
动作经 action.ps1 执行（一次动作一个子进程），
结果落 state/actions/<id>.json
```

远端采集器只在起流时上传一次，远端不留任何文件；当前生效的采集器版本显示在
「告警与审计 → 采集健康 → Collector <哈希>」，等于 `collector.sh` 的 SHA256 前 12 位。

## 配置

把 `config.example.json` 复制为 `config.json` 后按需修改：

| 字段 | 用途 |
|---|---|
| `port` | 面板端口（默认 48732） |
| `activeHost` | 启动时跟踪的主机 |
| `sshOpts` | 附加 ssh 参数（如超时 / keepalive） |
| `idleExitSec` | 可选：采集全停后纯空闲多少秒退出；缺省 = 采集活着就不退出、常驻 |
| `hosts[]` | 单机设置：`id`、`label`、`sub`、`sshHost`（SSH 别名）、`intervalSec`、`historyEverySamples`、`enabled`、`services[]` |
| `services[]` | 可控条目：`id`、`kind`（`systemd` \| `pattern`）、`unit`/`pattern`、`startCmd`/`stopCmd`/`logCmd`、护栏（`warnIfActive`、`allowEnable`、`confirmStop`） |
| `denyKill` | kill 保护名单：`pids[]`、`userMatch[]`、`cmdMatch[]` |
| `alerts[]` | 告警规则：`metric`、`op`、`threshold`、`forSec`、`cooldownSec`、`level`、`text` |
| `history` | `keepDays`、`maxFileMB` |

界面添加主机无需改配置、无需重启：右上角 → 主机管理 → 填显示名与 SSH 目标 →
先「测试连接」再「添加」。主机标识走严格白名单正则，不可能被拼成 ssh 选项；
每次写盘前先备份（`config.json.bak`），删除只移配置、`history/` 归档保留，
孤儿 state 文件下次启动自动清理。

## 测试

一条命令跑完全部门禁：

```powershell
pwsh -File build/gate.ps1          # exit 0=全过、1=有失败、2=未执行（非通过）
pwsh -File build/gate.ps1 -Only hosts   # 单套调试
```

十三个门禁覆盖端到端验收、主机管理回归、采集器契约、注入拦截、启动器契约
（BAT 原样复制执行必须 rc=0 —— 防「双击没反应」这类解析期死亡）、环回真值表、
图表像素校验、语法门与审计卫生。

> 脚本与测试**必须用 pwsh 7 跑**。Windows PowerShell 5.1 会按本地 GBK 解析无 BOM 的
> UTF-8 脚本，中文串会被搞乱——历史上「主机名变问号」的根因在此，不在面板代码。

## 文档

- 表现层设计基线：[`docs/design-review-v4.1.md`](docs/design-review-v4.1.md)
- 发布历史：[`CHANGELOG.md`](CHANGELOG.md)
- 安全策略：[`SECURITY.md`](SECURITY.md)

## 已知限制

- 关掉面板窗口，采集随之停止；要 7×24 就常驻 + 计划任务开机自启（启动器也认系统变量
  `SP_IDLE=-1`）。
- 睡眠 / 恢复唤醒有宽限期：唤醒时的墙钟漂移不再触发误判空闲退出，恢复事件与退出原因都会留痕。
- 面板只能管远端 Linux 主机，本机 Windows 服务不在范围内；端口归属需要 root。
- 服务条目指向的远端路径若已失效，点「启动」会如实报错（记入审计，而不是静默吞掉）。
- 浏览器定时器节流（窗口最小化 / 标签页后台）只影响可见的「已同步」时间显示，
  不影响采集——以 `state/meta-<id>.json` 的 `ageSec` 为准。

## 致谢

本项目开发过程中使用了基元律动（[TokenRhythm](https://tokenrhythm.studio/)）的 **neohorse1.5** 模型，感谢模型支持。

本项目由单人维护。Bug 反馈与安全问题上报方式见 SECURITY.md。