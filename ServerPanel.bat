# ============================================================================
#  ServerPanel v4 · 面板主进程 (hub)
#  原则：HTTP 层只读缓存文件，永不在此进程里跑 SSH —— 所以界面不可能卡
#  动作走独立子进程 (action.ps1)，异步轮询结果；指标流由 agent.ps1 常驻维持
#  安全：Host 白名单(防 DNS 重绑定) + Origin 校验(防 CSRF) + 随机 token(所有 /api)
#  生命周期：窗口关闭后 90s 无访问自动退出，并带走 agent 与 ssh 子进程树
# ============================================================================
param(
  [string]$Root = $PSScriptRoot,
  [switch]$NoBrowser,
  [switch]$TestOnce,
  [int]$IdleSec = -999      # 覆盖 config.idleExitSec；传 -1 表示常驻不退出
)
$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 7) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
  if ($pwsh) { & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters; exit $LASTEXITCODE }
  Write-Host 'ServerPanel v4 需要 PowerShell 7 (pwsh)。安装: winget install Microsoft.PowerShell' -ForegroundColor Red
  exit 1
}
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
function Read-JsonFile($p, $dflt) {
  if (-not (Test-Path -LiteralPath $p)) { return $dflt }
  try { return (Read-SharedText $p | ConvertFrom-Json) } catch { return $dflt }
}
# P1-3：共享读（FileShare.ReadWrite|Delete），与 agent 覆盖写/改名并发时不阻塞，避免静默丢样本
function Read-SharedText($p) {
  $fs = [IO.FileStream]::new($p, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)); try { return $sr.ReadToEnd() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
}
function Read-SharedBytes($p) {
  $fs = [IO.FileStream]::new($p, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $ms = [IO.MemoryStream]::new(); try { $fs.CopyTo($ms); return $ms.ToArray() } finally { $ms.Dispose() } } finally { $fs.Dispose() }
}
function Write-AtomicText($p, $s) {
  # tmp + Move-Item -Force（[IO.File]::Replace 在本机抛异常，失败会留下 .tmp 垃圾）
  $tmp = "$p.tmp$PID"
  try {
    [IO.File]::WriteAllText($tmp, $s, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $p, $true)   # P1-3：MoveFileEx REPLACE_EXISTING，不强求独占，配合共享读不丢样本
  } catch {
    try { [IO.File]::WriteAllText($p, $s, [Text.UTF8Encoding]::new($false)) } catch {}
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
  }
}
foreach ($d in 'state', 'history', 'log') { $x = Join-Path $Root $d; if (-not (Test-Path $x)) { New-Item -ItemType Directory -Path $x | Out-Null } }

# 启动留痕：BAT 以隐藏窗口拉起，崩溃/端口冲突原本无任何痕迹可查。
# R-87b：每实例独立转录文件（panel-run.<pid>.log）——多个实例（含被互斥体拒掉的重复启动）
# 并发写同一个文件会把转录搅成乱序/残缺，事后取证互相矛盾（本轮排查亲眼所见）。
# 生命周期标记（PANEL-READY/RESUME-GAP/PANEL-EXIT 等）仍由持锁的唯一实例单写 panel-run.log。
try {
  $runLog = Join-Path $Root ('log\panel-run.' + $PID + '.log')
  if ((Test-Path $runLog) -and (Get-Item $runLog).Length -gt 4MB) { Move-Item $runLog "$runLog.1" -Force -ErrorAction SilentlyContinue }
  Start-Transcript -Path $runLog -Append | Out-Null
} catch {}

$cfg = Read-JsonFile (Join-Path $Root 'config.json') $null
if (-not $cfg) { Write-Host 'config.json 读取失败' -ForegroundColor Red; exit 1 }
$Port = [int]$cfg.port; if ($Port -lt 1) { $Port = 48732 }
# R-85（用户定夺，2026-11-22）：默认语义改为「采集活着就不退出」。
# idleLimit 现在表示「采集全部停摆后，纯空闲多少秒才退出」；未配置即 -1 常驻。
# config 里显式写了 >=0 秒数仍按旧式纯空闲语义尊重；命令行 -IdleSec 显式覆盖一切（-1=常驻）。
$idleLimit = -1
if ($cfg.PSObject.Properties['idleExitSec'] -and $null -ne $cfg.idleExitSec) {
  $v = 0
  if ([int]::TryParse("" + $cfg.idleExitSec, [ref]$v)) { $idleLimit = $v }
}
if ($PSBoundParameters.ContainsKey('IdleSec')) { $idleLimit = $IdleSec }   # -IdleSec -1 => 常驻
$Token = [guid]::NewGuid().ToString('N')
$hosts = @($cfg.hosts | Where-Object { $_.enabled -ne $false })
$actionDir = Join-Path $Root 'state\actions'
if (-not (Test-Path $actionDir)) { New-Item -ItemType Directory -Path $actionDir | Out-Null }
$auditLog = Join-Path $Root 'actions.log'
# P0-4：启动时清一次孤儿 .running（上一代被强杀残留，mtime 超 120s），避免面板永不空闲退出
Get-ChildItem $actionDir -Filter '*.running' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 120 } | Remove-Item -Force -ErrorAction SilentlyContinue

# R-86：定位「我们自己的」Edge 面板窗口。只认「标题是面板页面」的顶层窗口。
# 早期版本用「命令行带 ServerPanelV4Edge」做特征，实测脏会话下 --app 会起一整个栈却只建出
# 标题为空的空白窗，句柄非空+命令行特征把它误判成有效窗口，重试逻辑永远轮不到执行。
# R-87a：再叠加一层专用 profile 特征，排除用户日常 Edge 恰好开着同名页面的极小概率；
# 空标题窗仍被「标题非空且匹配」挡掉，两层条件互补。
# 注意必须定义在互斥体分支之前——PowerShell 函数不跨执行顺序提升，晚于调用点定义等于不存在。
function Find-PanelEdgeWindow {
  try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop | Out-Null } catch {}
  try {
    $w = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
      $_.MainWindowHandle -ne 0 -and (('' + $_.MainWindowTitle) -match '服务器管家 v4|ServerPanel') })
    if ($w.Count -gt 0) {
      $own = @($w | Where-Object {
        try { [bool]((Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -match 'ServerPanelV4Edge') } catch { $false }
      })
      if ($own.Count -gt 0) { return $own[0] }
    }
  } catch {}
  return $null
}
# R-87e：轻量版（无 CIM 全机枚举）。轮询热路径必须用它——每次 300-800ms 的 Win32_Process
# 枚举在负载高时会拖长检测间隔，且本身就是窗口迟迟“看不到”的元凶之一。只匹配标题。
function Find-PanelEdgeWindowFast {
  try {
    $w = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
      $_.MainWindowHandle -ne 0 -and (('' + $_.MainWindowTitle) -match '服务器管家 v4|ServerPanel') })
    if ($w.Count -gt 0) { return $w[0] }
  } catch {}
  return $null
}
# R-88b：归属版。必须在「决定要不要新起一个 --app 窗」时用它——只认命令行带专用 profile
# 的顶层窗。否则用户日常 Edge 里恰好开着同名页面的旧标签页（例如上次兜底用默认浏览器打开
# 留下的）会被误认为“已有面板窗”，导致专用窗口永远不被创建、用户看到的始终是旧标签页。
# 单进程 CIM 查询很快（~百毫秒），带两次重试抗高负载抖动。
function Find-PanelEdgeWindowOwned {
  foreach ($try in 1..3) {
    try {
      $w = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and (('' + $_.MainWindowTitle) -match '服务器管家 v4|ServerPanel') })
      foreach ($p in $w) {
        try {
          $cl = '' + (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
          if ($cl -match 'ServerPanelV4Edge') { return $p }
        } catch {}
      }
    } catch {}
    Start-Sleep -Milliseconds 350
  }
  return $null
}

# ---------- 打开独立窗口（Edge 应用模式） ----------
# 注意：本块必须整体定义在下方互斥体分支之前——PowerShell 函数不跨执行顺序提升，
# 晚于调用点定义等于不存在（R-89b 起拒绝分支也要调 Open-PanelWindow 补开窗口）。
# R-89a：Reset-PanelEdgeProfile 只在「起窗失败后的重试换代」时调用，不再每次开窗前无条件清。
# 该目录是本工具的可弃隔离 profile（%LOCALAPPDATA%\ServerPanelV4Edge，页面上没有任何需要跨次
# 保留的状态），但把 profile 反复删除重建会让 Edge 每次都从零初始化一套全新 user-data-dir
# （无缓存/无组件），实测冷启动要几十秒，期间窗口以「URL 主机名 + 转圈」的加载态出现在桌面，
# 用户以为坏了。上代强杀留下的脏会话数据是「--app 起一栈却只剩空白窗」的根因，只在重试时清，
# 从根上消灭该形态又不牺牲常态启动速度。只在本 profile 无存活进程后删除，不波及用户日常浏览器。
function Reset-PanelEdgeProfile {
  try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'msedge.exe' -and ('' + $_.CommandLine -match 'ServerPanelV4Edge') } | ForEach-Object { try { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {} }
    Start-Sleep -Milliseconds 500
    if (-not ((Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'msedge.exe' -and ('' + $_.CommandLine -match 'ServerPanelV4Edge') }))) {
      $prof = "$env:LOCALAPPDATA\ServerPanelV4Edge"
      if (Test-Path -LiteralPath $prof) { Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}
# R-86a：若上一代会话残留的面板窗口还在桌面（或重复实例撞见），先聚焦它，不叠开新窗
# （旧逻辑会为重复启动再开第二个同样窗口，且专用 profile 被占时退化成「空白 Edge 窗」）。
function Open-PanelWindow([string]$Url) {
  # R-88b：认「我们自己的」窗口必须走归属版，不能只看标题——日常 Edge 里的同名旧标签页会骗过它。
  $hits = Find-PanelEdgeWindowOwned
  if ($hits) { try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$hits.Id); return } catch {} }
  $edge = @("$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $edge) { Start-Process $Url | Out-Null; return }
  # R-86c：每代都从「干净 profile」起窗（Reset-PanelEdgeProfile 先清残留再开），从根上消灭脏会话
  # 建不出初始窗口的空白形态；再用「--app 是否被接受」（进程命令行出现 --app=URL + 专用 profile）验证；
  # 两次都失败则兑底用默认浏览器打开——保证用户双击后每次都看得见面板。
  # R-87d：一律禁用扩展——--app 面板页不需要任何扩展，且专用 profile 会被 Edge 预装组件复制进
  # 一整盒扩展（如 Zotero/Scholarscope/Forest 等），个别扩展会在启动瞬间抢占新标签/改写窗口标题，
  # 是「起了栈却迟迟建不出带标题的面板窗」的候选干扰源之一。关掉它们，窗口状态与标题才可预期。
  # R-89a：常态（attempt=1）不再预先 wipe profile——每代从零重建 user-data-dir 要几十秒，期间
  # 桌面只有「URL 主机名 + 转圈」的加载态。只有起窗失败后的重试才清脏会话换代。两阶段判据不变。
  foreach ($attempt in 1..2) {
    Write-Output "WIN-OPEN attempt=$attempt"
    if ($attempt -gt 1) { Reset-PanelEdgeProfile }
    Start-Process $edge -ArgumentList "--app=$Url/", "--window-size=1320,860", "--window-position=60,40", "--user-data-dir=$env:LOCALAPPDATA\ServerPanelV4Edge", '--no-first-run', '--disable-features=Translate', '--disable-extensions' | Out-Null
    # R-87a：成功判据升级为「真实带标题的面板窗出现」，旧口径在「进程起了、窗口还没建出来」
    # 的中间态就报 ok，重复启动撞上这个状态就可能叠开第二个窗口。分两阶段等待，既不早退也不误杀：
    # 阶段1（≤5s）只看进程是否被接受——没起或秒退（profile 被占）立即换代重试；
    # 阶段2（≤30s）等真实带标题窗口——栈健康就不打断，冷启动慢不再被 12s 上限误杀而自我拆台。
    $accepted = $false; $w1 = 0
    while ($w1 -lt 5000) {
      Start-Sleep -Milliseconds 400
      if (@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'msedge.exe' -and ('' + $_.CommandLine -like "*--app=$Url*") -and ('' + $_.CommandLine -match 'ServerPanelV4Edge') }).Count -gt 0) { $accepted = $true; break }
      $w1 += 400
    }
    if (-not $accepted) { Write-Output ('WIN-OPEN fail-fast attempt=' + $attempt); try { Add-Content -LiteralPath (Join-Path $Root 'log\_winlog.txt') -Value ((Get-Date).ToString('HH:mm:ss')) -Encoding utf8 } catch {}; continue }
    $w2 = 0
    while ($w2 -lt 30000) {
      Start-Sleep -Milliseconds 500
      if (Find-PanelEdgeWindowFast) { Write-Output 'WIN-OPEN ok'; return }
      $w2 += 500
    }
    Write-Output ('WIN-OPEN fail-window attempt=' + $attempt)
    try { Add-Content -LiteralPath (Join-Path $Root 'log\_winlog.txt') -Value ((Get-Date).ToString('HH:mm:ss')) -Encoding utf8 } catch {}
  }
  Start-Process $Url | Out-Null
}

# R-84：双启动防护改走内核互斥体，不依赖「端口占用」。实测 Windows http.sys 允许两个 HttpListener
# 同时注册同一前址（新实例照样 PANEL-READY），旧路径“绑定失败→探测已有实例”在本机永不触发，
# 双实例会双写 hub.json、双起 agent（SSH 会话翻倍）。命名互斥体随进程死亡由内核自动释放，
# 上代崩溃留下的 abandoned 锁会自动接管，不会误伤下一轮启动。放在 Start-Agents 之前：重复实例根本轮不到起 agent。
try {
  $panelMutex = [System.Threading.Mutex]::new($false, "Global\ServerPanelV4-$Port")
  if (-not $panelMutex.WaitOne(0)) {        # 返回 false = 已有活实例持锁 => 本实例就是重复启动
    # R-86：连续两次启动（如双击两下 BAT、或两秒内的重复拉起）时，若已有面板窗则只把它置前、
    # 静默不叠窗；若窗口不在（用户关掉了 --app 窗但采集仍在跑，或上代留下空白僵尸栈），
    # 则清僵尸栈后由本实例开一扇新窗再退出——R-89b：保证每次双击后桌面永远恰好有一扇可见面板窗。
    $existingWin = Find-PanelEdgeWindow
    if (-not $existingWin) {
      # R-87f：所有权 CIM 单进程查询在高负载下会超时失败，导致明明有面板窗也报 DUP-FOCUS:NO。
      # 兑底口径：只要机器上还存在本专用 profile 的 Edge 栈，任何标题命中的顶层窗就当作我们的面板窗来聚焦。
      # 查询带一次 400ms 重试：拒绝分支几乎总在面板活着的时候发生，值得多花半秒换置前台成功率。
      foreach ($try in 1..2) {
        try {
          if (@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'msedge.exe' -and ('' + $_.CommandLine -match 'ServerPanelV4Edge') }).Count -gt 0) {
            $anyWin = @(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and (('' + $_.MainWindowTitle) -match '服务器管家 v4|ServerPanel') })
            if ($anyWin.Count -gt 0) { $existingWin = $anyWin[0]; break }
          }
        } catch {}
        Start-Sleep -Milliseconds 400
      }
    }
    $focused = $false
    if ($existingWin) {
      try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$existingWin.Id); $focused = $true } catch {}
    }
    else {
      # R-89b：既找不到可聚焦的面板窗、又确认面板活着 —— 补开一扇新 --app 窗再退出。
      # 有专用 profile 栈却没标题窗 = 空白僵尸（上代强杀/关窗残留），先整体清掉再开，
      # 否则新 --app 会挂在脏会话上再起一栈却只剩空白窗。没有栈则是用户干净关掉了窗口，直接开。
      try {
        if (@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'msedge.exe' -and ('' + $_.CommandLine -match 'ServerPanelV4Edge') }).Count -gt 0) { Reset-PanelEdgeProfile }
        Open-PanelWindow ("http://127.0.0.1:$Port")
      } catch {}
    }
    Write-Output ("PANEL-ALREADY-RUNNING http://127.0.0.1:$Port DUP-FOCUS:" + $(if ($focused) { 'YES' } else { 'NO' }) + " (另一实例仍在运行" + $(if ($focused) { '，已置前台' } else { '，本实例静默退出' }) + ")")
    exit 0
  }
  $script:mutexHeld = $true
} catch [System.Threading.AbandonedMutexException] {
  $script:mutexHeld = $true   # 上代实例崩溃遗留的锁：内核已释放，直接接管
}

# ---------- 代理进程管理 ----------
$script:agents = @{}
$script:agentMeta = @{}   # P1-4：每主机 lastStart/failCount/nextTry，失败退避防进程风暴
function Start-Agents {
  foreach ($h in $hosts) {
    $alive = $script:agents[$h.id]
    if ($alive -and -not $alive.HasExited) { continue }
    $am = $script:agentMeta[$h.id]
    if (-not $am) { $am = @{ lastStart = $null; failCount = 0; nextTry = [datetime]::MinValue }; $script:agentMeta[$h.id] = $am }
    if ((Get-Date) -lt $am.nextTry) { continue }   # 退避中
    # 上一进程实际运行 <10s 即退出视为快速失败（config/host/collector 缺失），累加退避；跑久了才断则重置。
    # 用 ExitTime 算真实运行时长，不能用「距上次启动」（那会把退避等待时间算进去，导致 failCount 被误重置）
    if ($am.lastStart -and $alive -and $alive.HasExited) { $runSec = 999; try { $runSec = ($alive.ExitTime - $am.lastStart).TotalSeconds } catch {}; if ($runSec -lt 10) { $am.failCount++ } else { $am.failCount = 0 } }
    # R-88：跨代去重。上代 hub 被杀/被回收后，其 agent 可能变孤儿继续写 state（实测：本会话
    # 一个孤儿 agent 在 hub 死后又采集了几分钟）。本代再拉起时若不清掉它们，会出现两个 agent
    # 同写 latest-/meta-/rollup-<id>.json（样本翻倍、SSH 会话翻倍、告警状态互相覆盖）。
    # 只清命令行同为 agent.ps1 且 -HostId 相同的其它 pwsh；本代已跟踪的活进程（PID 相同）不动。
    try {
      $myPid = if ($alive) { [int]$alive.Id } else { 0 }
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'pwsh.exe' -and ('' + $_.CommandLine -match 'agent\.ps1') -and ('' + $_.CommandLine -match ('-HostId\s+' + [regex]::Escape($h.id) + '([\s"]|$)')) -and [int]$_.ProcessId -ne [int]$myPid
      } | ForEach-Object { try { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {} }
    } catch {}
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
    $psi.FileName = if ($pwsh) { $pwsh.Source } else { 'powershell.exe' }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\agent.ps1`" -HostId $($h.id) -Root `"$Root`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    try {
      $p = [Diagnostics.Process]::Start($psi)
      $script:agents[$h.id] = $p
      $am.lastStart = Get-Date
      $am.nextTry = (Get-Date).AddSeconds([Math]::Min(15, [Math]::Max(1, [Math]::Pow(2, $am.failCount))))
      if ($am.failCount -ge 5) {
        # 连续快速失败：写 meta 让前端显式提示（agent 没在跑，不会与它抢写）
        Write-AtomicText (Join-Path $Root "state\meta-$($h.id).json") (@{ hostId = $h.id; host = $h.sshHost; label = $h.label; running = $false; samples = 0; restarts = $am.failCount; ageSec = $null; exitReason = ''; err = "agent 反复启动失败（连续 $($am.failCount) 次），检查 config.json / collector.sh / 主机配置" } | ConvertTo-Json -Compress)
      }
    } catch {
      $am.failCount++
      $am.nextTry = (Get-Date).AddSeconds([Math]::Min(15, [Math]::Max(1, [Math]::Pow(2, $am.failCount))))
      Write-Host "启动代理失败 $($h.id): $_" -ForegroundColor Yellow
    }
  }
}
function Stop-Agents {
  foreach ($h in $hosts) {
    $p = $script:agents[$h.id]
    if ($p) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {} }
  }
}
# ---------- 主机管理（运行时增删改，无需重启面板） ----------
function Stop-Agent([string]$id) {
  $p = $script:agents[$id]
  if ($p) { try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {} }
  $script:agents.Remove($id)
  $script:agentMeta.Remove($id)   # 清退避计数，配置变更后立即可重启
}
# R-50/DR-50：ConvertTo-Json 会把每个标量元素/键独占一行，而 config.json 是人手维护的文件，
# 改一次主机就能产生上百行无意义 diff。写盘前把「纯标量」的数组/对象折回单行。
# 安全红线：只在开括号独占一行、成员行全是纯标量字面量、闭括号独占一行时才折；
# 任何一行不合格式（嵌套对象、混合内容）整块原样保留；折出来过长也不折（人可读比短 diff 重要）。
function Format-CompactJson([string]$json, [int]$maxFoldWidth = 200) {
  $scalar = '"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|true|false|null'
  $lines = $json -split "`r?`n"
  $out = [Collections.Generic.List[string]]::new()
  $i = 0
  while ($i -lt $lines.Count) {
    $l = $lines[$i]
    $mOpen = [regex]::Match($l, ('^(\s*(?:"(?:[^"\\]|\\.)*"\s*:\s*)?)(\[|\{)\s*$'))
    if ($mOpen.Success) {
      $prefix = $mOpen.Groups[1].Value
      $open = $mOpen.Groups[2].Value
      $close = if ($open -eq '[') { ']' } else { '}' }
      $itemPat = if ($open -eq '[') { '^\s*(' + $scalar + '),?\s*$' } else { '^\s*("(?:[^"\\]|\\.)*"\s*:\s*(?:' + $scalar + ')),?\s*$' }
      $items = [Collections.Generic.List[string]]::new()
      $j = $i + 1; $closed = $false; $tail = ''
      while ($j -lt $lines.Count) {
        $mc = [regex]::Match($lines[$j], ('^\s*' + [regex]::Escape($close) + '(\s*,)?\s*$'))
        if ($mc.Success) { $closed = $true; if ($mc.Groups[1].Success) { $tail = ',' }; break }
        $mi = [regex]::Match($lines[$j], $itemPat)
        if (-not $mi.Success) { break }
        $items.Add($mi.Groups[1].Value)
        $j++
      }
      if ($closed -and $items.Count -gt 0) {
        # 数组无内边距(贴近本仓库 config.json 的既有写法 ["a", "b"])，对象保留 { ... } 空格
        $pad = if ($open -eq '[') { '' } else { ' ' }
        $folded = $prefix + $open + $pad + ($items -join ', ') + $pad + $close + $tail
        if ($folded.Length -le $maxFoldWidth) { $out.Add($folded); $i = $j + 1; continue }
      }
    }
    $out.Add($l)
    $i++
  }
  return ($out -join "`n")
}
function Save-Config {
  $p = Join-Path $Root 'config.json'
  try { Copy-Item -LiteralPath $p -Destination "$p.bak" -Force } catch {}   # 改坏可回滚
  # 末尾补一个换行：POSIX 文本文件约定，否则 diff 会多出一对毫无信息的 }
  Write-AtomicText $p ((Format-CompactJson ($cfg | ConvertTo-Json -Depth 12)) + "`n")
}
function Sync-Hosts { $script:hosts = @($cfg.hosts | Where-Object { $_.enabled -ne $false }) }
# 统一属性写入：OrderedDictionary 上 Add-Member 只改适配器属性，ConvertTo-Json 仍序列化旧键（实测），必须按键写；
# 而 PSCustomObject 上对已有键用 Add-Member -Force 会把它挑到对象末尾，值未变却制造假 diff（config 是人手维护的文件）。
function Set-HostProp($o, [string]$n, $v) {
  if ($o -is [System.Collections.IDictionary]) { $o[$n] = $v }
  elseif ($o.PSObject.Properties[$n]) { $o.$n = $v }                                        # 原地赋值，保留键顺序
  else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }                        # 仅新键才追加
}
# P1-5：端口空闲（无面板在跑）时清理上一代残留 agent——面板被强杀时 agent 没被带走，会存活到心跳超时(25s)，
# 期间重开面板会双 agent 覆写同一份 state。有面板在跑则跳过（双启动保护接管）。
$existingPanel = $null
try { $existingPanel = Invoke-RestMethod "http://127.0.0.1:$Port/api/boot" -TimeoutSec 3 } catch {}
if (-not ($existingPanel -and $existingPanel.ok)) {
  $safeRoot = [regex]::Escape($Root)
  foreach ($h in $hosts) {
    $apat = "-File\s+`"?$safeRoot\\agent\.ps1`"?\s+-HostId\s+$([regex]::Escape($h.id))(\s|`"|$)"
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('pwsh.exe','powershell.exe') -and ('' + $_.CommandLine) -match $apat } | ForEach-Object {
      try { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {}
    }
  }
  # 主机管理加入后的新坑：删除主机会把 state/ 里该主机的文件永久留下（反复增删就堆垃圾）。
  # 仅在本实例是唯一面板时清（否则可能与上一代 agent 抢写）；history/ 里的归档按设计保留。
  $knownIds = @($cfg.hosts | ForEach-Object { '' + $_.id })
  foreach ($f in @(Get-ChildItem (Join-Path $Root 'state') -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -match '^(latest|meta|alerts|rollup)-(.+)\.json$' -and $knownIds -notcontains $matches[2]) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}
Start-Agents

# ---------- 测试模式：采一轮就退出 ----------
if ($TestOnce) {
  Start-Sleep -Seconds 12
  foreach ($h in $hosts) {
    $meta = Read-JsonFile (Join-Path $Root "state\meta-$($h.id).json") $null
    $lat  = Read-JsonFile (Join-Path $Root "state\latest-$($h.id).json") $null
    "== $($h.id): running=$($meta.running) samples=$($meta.samples) age=$($meta.ageSec)s restarts=$($meta.restarts) err=$($meta.err)$($meta.stderr)"
    if ($lat) { "   gpu.util=$($lat.gpu.util) mem=$($lat.gpu.memUsedMiB)/$($lat.gpu.memTotalMiB) procs=$($lat.procCount) cpu%=$($lat.derived.cpuPct) errors=[$($lat.errors -join ',')]" }
  }
  Stop-Agents; exit 0
}

# ---------- 监听 ----------
$listener = [System.Net.HttpListener]::new()
$prefixes = $null
try {
  $listener.Prefixes.Add("http://127.0.0.1:$Port/"); $listener.Prefixes.Add("http://localhost:$Port/")
  $listener.Start()
  $prefixes = @('127.0.0.1', 'localhost')
} catch {
  try { $listener.Close(); $listener = [System.Net.HttpListener]::new(); $listener.Prefixes.Add("http://localhost:$Port/"); $listener.Start(); $prefixes = @('localhost') }
  catch {
    # 端口被占：先探测是不是已有一个 v4 面板在跑——是的话直接给现有面板开窗口、本实例干净退出。
    # 否则旧面板占着端口时，双击 BAT 会「黑框一闪、啥也没有」（新面板绑定失败就静默退出，走不到开窗口那步）。
    $existing = $null
    try { $existing = Invoke-RestMethod "http://127.0.0.1:$Port/api/boot" -TimeoutSec 4 } catch {}
    if ($existing -and $existing.ok -and [int]$existing.port -eq $Port) {
      Stop-Agents   # 杀掉本实例刚起的 agent，避免双代理并发覆写同一份 state
      # R-86：此路径也是「重复启动」，与互斥体分支一致——只聚焦现有面板窗，不开第二个
      if (-not $NoBrowser) { $fw = Find-PanelEdgeWindow; if ($fw) { try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$fw.Id) } catch {} } }
      Write-Output ("PANEL-ALREADY-RUNNING http://127.0.0.1:$Port" + $(if ($NoBrowser) { ' (已有面板在跑，本实例退出)' } else { ' (已聚焦现有面板，本实例退出)' }))
      exit 0
    }
    Write-Host "端口 $Port 监听失败：$_" -ForegroundColor Red; Stop-Agents; exit 1
  }
}
$openHost = if ($prefixes -contains '127.0.0.1') { '127.0.0.1' } else { 'localhost' }
$base = "http://$openHost`:$Port"

# ---------- 打开独立窗口 ----------
if (-not $NoBrowser) { Open-PanelWindow $base }
Write-Output "PANEL-READY $base"
try { Add-Content -LiteralPath (Join-Path $Root 'log\panel-run.log') -Value ((Get-Date).ToString('s') + ' PANEL-READY ' + $base + ' pid=' + $PID) -Encoding utf8 } catch {}

# ---------- 请求辅助 ----------
function Send-Bytes($res, [byte[]]$b, [string]$ctype, [int]$code = 200, $headers = @{}) {
  $res.StatusCode = $code
  $res.ContentType = $ctype
  $res.Headers.Add('X-Content-Type-Options', 'nosniff')
  $res.Headers.Add('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'")
  $res.Headers.Add('Cache-Control', 'no-store')
  foreach ($k in $headers.Keys) { try { $res.Headers.Add($k, [string]$headers[$k]) } catch {} }
  $res.ContentLength64 = $b.Length
  $res.OutputStream.Write($b, 0, $b.Length)
  $res.Close()
}
function Send-Text($res, [string]$s, [string]$ctype, [int]$code = 200, $headers = @{}) {
  Send-Bytes $res ([Text.UTF8Encoding]::new($false).GetBytes($s)) $ctype $code $headers
}
function Send-Json($res, $obj, [int]$code = 200) {
  Send-Text $res ($obj | ConvertTo-Json -Compress -Depth 10) 'application/json; charset=utf-8' $code
}
function Send-Err($res, [int]$code, [string]$msg) { Send-Json $res @{ ok = $false; error = $msg } $code }

function Get-Meta($id) { Read-JsonFile (Join-Path $Root "state\meta-$id.json") $null }
function Host-Valid($id) { [bool](@($hosts | Where-Object { $_.id -eq $id }).Count) }

# 历史汇总：由 agent 预聚合成 fine/mid/coarse 三档，hub 只做切片，绝不扫大文件
function Get-Rollup($id) {
  $p = Join-Path $Root "state\rollup-$id.json"
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) } catch { return $null }
}
function Select-Window($rawJson, $w) {
  $o = $rawJson | ConvertFrom-Json
  $sec = switch ($w) { '5m' { 300 } '15m' { 900 } '1h' { 3600 } '6h' { 21600 } '24h' { 86400 } '7d' { 604800 } default { 900 } }
  $tier = if ($sec -le 1800) { 'fine' } elseif ($sec -le 21600) { 'mid' } else { 'coarse' }
  $pts = @($o.$tier)
  $cut = [DateTimeOffset]::Now.ToUnixTimeSeconds() - $sec
  $sel = @($pts | Where-Object { [double]$_[0] -ge $cut })
  @{ ok = $true; window = $w; tier = $tier; cols = @('t', 'cpu', 'gpu', 'gpct', 'mem', 'load', 'rx', 'tx', 'gtemp'); points = $sel } | ConvertTo-Json -Compress -Depth 6
}
function Send-File($res, $p, $ctype, $headers = @{}) {
  if (-not (Test-Path -LiteralPath $p)) { Send-Err $res 404 "missing $([IO.Path]::GetFileName($p))"; return }
  Send-Bytes $res (Read-SharedBytes $p) $ctype 200 $headers
}
# P1-1：尾部读日志（Seek 到末尾 64KB 按行切），避免每 6s 全量读几百 MB；P1-2：过滤坏行解析出的 null
function Read-LogTail($path, [int]$maxLines, [int]$tailBytes = 65536) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
      $start = [Math]::Max(0, $fs.Length - $tailBytes)
      $fs.Seek($start, 'Begin') | Out-Null
      $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false))
      $text = $sr.ReadToEnd(); $sr.Dispose()
      $lines = $text -split "`r?`n"
      if ($start -gt 0) { $lines = @($lines | Select-Object -Skip 1) }  # 丢掉可能被截断的首行
      return @($lines | Select-Object -Last $maxLines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    } finally { $fs.Dispose() }
  } catch { return @() }
}

# ---------- 主循环 ----------
$script:lastActive = Get-Date
$script:busyAgents = $false
$script:lastTickAt = Get-Date     # R-83：每拍墙钟，用于识别「睡眠/挂起恢复」
$script:exitWhy = ''             # R-83：退出原因留痕（idle / 未设）
$script:lastCleanup = Get-Date
Write-AtomicText (Join-Path $Root 'state\hub.json') (@{ ts = (Get-Date).ToString('s'); pid = $PID; port = $Port } | ConvertTo-Json -Compress)

while ($listener.IsListening) {
  $now = Get-Date
  if (($now - $script:lastTickAt).TotalSeconds -gt 10) {   # 拍长只有 ~0.7s，漂过 10s 只可能是睡眠/挂起/长卡顿
    # R-83：不清零的话，恢复瞬间墙钟早已 ≫ idleLimit，整机被「空闲」当场收走——用户看到的就是跑着跑着断线
    try { Add-Content -LiteralPath (Join-Path $Root 'log\panel-run.log') -Value ((($now - $script:lastTickAt).TotalSeconds).ToString('N0') + ' RESUME-GAP ' + $now.ToString('s') + '（睡眠/挂起恢复，空闲计时重置）') -Encoding utf8 } catch {}
    $script:lastActive = $now
  }
  $script:lastTickAt = $now
  $ar = $listener.BeginGetContext($null, $null)
  $stopping = $false
  while (-not $ar.AsyncWaitHandle.WaitOne(700)) {
    try {
      Write-AtomicText (Join-Path $Root 'state\hub.json') (@{ ts = (Get-Date).ToString('s'); pid = $PID; port = $Port } | ConvertTo-Json -Compress)
      Start-Agents
      # P1-1：每小时清一次 state/actions 里超过 24h 的 job 文件
      if (((Get-Date) - $script:lastCleanup).TotalSeconds -ge 3600) {
        $script:lastCleanup = Get-Date
        Get-ChildItem $actionDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalHours -gt 24 } | Remove-Item -Force -ErrorAction SilentlyContinue
      }
      if ($idleLimit -ge 0 -and ((Get-Date) - $script:lastActive).TotalSeconds -gt $idleLimit) {
        # P0-4：.running 存在但 mtime 超 120s 视为孤儿（action 被强杀残留），删掉放行退出
        $running = @(Get-ChildItem $actionDir -Filter '*.running' -ErrorAction SilentlyContinue | Where-Object {
          if (((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 120) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $false } else { $true }
        })
        if ($running.Count -eq 0) {
          # R-85：只要还有主机在正常采集就不算空闲——数据还在流就说明它还需要被记录，不能收摊
          $collecting = @($hosts | ForEach-Object { $m = Get-Meta $_.id; if ($m -and $m.running -and $null -ne $m.ageSec -and [int]$m.ageSec -lt 30) { $true } })
          if ($collecting.Count -eq 0) { $script:exitWhy = 'idle'; $stopping = $true; break }
        }
      }
    } catch {
      # 防护：巡检异常不允许静默杀死整个面板——留痕后继续（此前出现过一次无痕迹退出，无法定位）
      try { Add-Content -LiteralPath (Join-Path $Root 'log\panel-run.log') -Value ((Get-Date).ToString('s') + ' loop-error: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) -Encoding utf8 } catch {}
    }
  }
  if ($stopping) { break }
  $ctx = $listener.EndGetContext($ar)
  $script:lastActive = Get-Date
  $req = $ctx.Request; $res = $ctx.Response
  try {
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq '') { $path = '/' }
    $origin = $req.Headers['Origin']
    $referer = $req.Headers['Referer']

    # --- Host 白名单：挡 DNS 重绑定 ---
    $reqHost = ("" + $req.Headers['Host']) -replace ':\d+$', ''
    if (-not ($reqHost -in @('127.0.0.1', 'localhost', '::1'))) { Send-Err $res 421 'bad host'; continue }

    # --- Origin 校验：只在浏览器会带这个头时生效，挡跨站 POST ---
    #     不带 Origin 的客户端（curl / 脚本）不会被误伤，但仍必须带对 token；
    #     而跨站页面拿不到 token（/api/boot 无 CORS 头，读不到响应），所以这条链路是闭合的
    if ($origin) {
      $oh = ($origin -replace '^https?://', '') -replace ':\d+$', ''
      if ($oh -notin @('127.0.0.1', 'localhost', '::1')) { Send-Err $res 403 'cross-origin blocked'; continue }
    }

    # --- 静态资源 ---
    if ($path -eq '/' -or $path -eq '/index.html') { Send-File $res (Join-Path $Root 'dashboard.html') 'text/html; charset=utf-8'; continue }
    if ($path -eq '/app.js') { Send-File $res (Join-Path $Root 'app.js') 'application/javascript; charset=utf-8'; continue }
    if ($path -like '/vendor/*') {
      $f = Join-Path $Root ("vendor\" + ($path -replace '^/vendor/', ''))
      if (Test-Path -LiteralPath $f) {
        $ct = if ($f -like '*.css') { 'text/css; charset=utf-8' } elseif ($f -like '*.html') { 'text/html; charset=utf-8' } else { 'application/javascript; charset=utf-8' }
        Send-File $res $f $ct
      } else { Send-Err $res 404 'not found' }
      continue
    }

    # --- 所有 /api/* 需要 token ---
    if ($path -like '/api/*' -and $path -ne '/api/boot') {
      $tk = $req.Headers['X-Panel-Token']
      if ($tk -ne $Token) { Send-Err $res 401 'bad token'; continue }
    }
    switch ($path) {
      '/api/boot' {
        $hostsOut = @($hosts | ForEach-Object {
          [ordered]@{
            id = $_.id; label = $_.label; sub = $_.sub; intervalSec = [int]$_.intervalSec
            services = @($_.services | ForEach-Object {
              [ordered]@{
                id = $_.id; label = $_.label; desc = $_.desc; kind = $_.kind
                matchKey = $(if ($_.kind -eq 'systemd') { $_.unit } else { $_.pattern })
                warnIfActive = [bool]$_.warnIfActive; confirmStop = $_.confirmStop; hasLog = [bool]$_.logCmd
              }
            })
          }
        })
        # DR-26：下发告警规则，前端才能渲染规则表/阈值参考带/解释预警
        $alertsOut = @($cfg.alerts | ForEach-Object { [ordered]@{ id = $_.id; metric = $_.metric; op = $_.op; threshold = $_.threshold; level = $_.level; text = $_.text; forSec = $_.forSec; cooldownSec = $_.cooldownSec } })
        Send-Json $res @{ ok = $true; token = $Token; port = $Port; version = '4.1'; active = $cfg.activeHost; idleExitSec = $idleLimit; hosts = $hostsOut; alerts = $alertsOut }
        continue
      }
      '/api/status' {
        $arr = @()
        foreach ($h in $hosts) {
          $m = Get-Meta $h.id
          $up = $m.running -and ($m.ageSec -ne $null) -and ($m.ageSec -lt ([int]$h.intervalSec * 4 + 10))
          $arr += [ordered]@{
            id = $h.id; label = $h.label; sub = $h.sub; sshHost = $h.sshHost; intervalSec = [int]$h.intervalSec
            running = [bool]$m.running; fresh = $up; ageSec = $m.ageSec; samples = $m.samples
            restarts = $m.restarts; err = ($m.err ?? $m.stderr); exitReason = ($m.exitReason ?? ''); lastDropAt = ($m.lastDropAt ?? ''); lastDropWhy = ($m.lastDropWhy ?? ''); collectorHash = ($m.collectorHash ?? ''); staleSec = [int]$h.intervalSec * 4 + 10
          }
        }
        $act = @()
        $deadByHost = @{}
        foreach ($h in $hosts) {
          $al = Read-JsonFile (Join-Path $Root "state\alerts-$($h.id).json") $null
          $dr = @()
          if ($al) {
            # DR-78 指标名从未在任何样本里出现过的规则 = 永远不可能触发(名字写错、或引用了未配置的 service.xxx)。
            # 连续 20 个样本仍取不到键才判死，避免刚起流时误报。
            foreach ($p in @($al.PSObject.Properties)) {
              $mi = [int]($p.Value.miss ?? 0)
              if ($mi -ge 20) { $dr += [ordered]@{ id = $p.Name; miss = $mi } }
            }
          }
          $deadByHost[$h.id] = $dr
          if (-not $al) { continue }
          foreach ($p in @($al.PSObject.Properties)) {
            if (-not $p.Value.active) { continue }
            $rule = @($cfg.alerts | Where-Object { $_.id -eq $p.Name })[0]
            $txt = if ($rule) { ("" + $rule.text) -replace '\{value\}', ("" + $p.Value.value) } else { $p.Name }
            $dur = $null
            if ($p.Value.since) { try { $dur = [int](((Get-Date) - [datetime]$p.Value.since).TotalSeconds) } catch {} }
            $act += [ordered]@{ host = $h.id; rule = $p.Name; level = $(if ($rule) { $rule.level } else { 'warn' }); value = $p.Value.value; since = $p.Value.since; durSec = $dur; text = $txt }
          }
        }
        # OrderedDictionary 必须按 key 赋值；点号赋值只改适配器成员，ConvertTo-Json 时会被吞(本仓库实测两次)
        foreach ($e in $arr) { $e['deadRules'] = @($deadByHost[$e.id]) }
        Send-Json $res @{ ok = $true; hosts = $arr; activeAlerts = $act; idleSec = [int]((Get-Date) - $script:lastActive).TotalSeconds; idleLimit = $idleLimit }
        continue
      }
      '/api/snapshot' {
        $id = $req.QueryString['host']; if (-not $id) { $id = $cfg.activeHost }
        if (-not (Host-Valid $id)) { Send-Err $res 400 'unknown host'; continue }
        $f = Join-Path $Root "state\latest-$id.json"
        if (-not (Test-Path -LiteralPath $f)) { Send-Json $res @{ ok = $false; error = 'no_data_yet'; host = $id }; continue }
        $m = Get-Meta $id
        $age = if ($m.ageSec -ne $null) { $m.ageSec } else { 9999 }
        $stale = ($age -gt ([int](($hosts | Where-Object { $_.id -eq $id }).intervalSec) * 4 + 10))
        $h2 = @{ 'X-Sample-Age' = $age; 'X-Sample-Stale' = $(if ($stale) { '1' } else { '0' }) }
        Send-File $res $f 'application/json; charset=utf-8' $h2
        continue
      }
      '/api/history' {
        $id = $req.QueryString['host']; if (-not $id) { $id = $cfg.activeHost }
        $w = $req.QueryString['window']; if (-not $w) { $w = '15m' }
        $raw = Get-Rollup $id
        if (-not $raw) { Send-Json $res @{ ok = $false; error = 'no_history'; window = $w }; continue }
        Send-Text $res (Select-Window $raw $w) 'application/json; charset=utf-8'
        continue
      }
      '/api/alerts' {
        $n = 60
        $log = Join-Path $Root 'alerts.log'
        $ev = @(Read-LogTail $log $n)   # @() 强制数组上下文：空结果不致被解卷成 null
        Send-Json $res @{ ok = $true; events = $ev }
        continue
      }
      '/api/forensics' {
        # 「昨天 15:20 谁在吃显存」——按时间点在原始 JSONL 里找最近的一条
        $id = $req.QueryString['host']; if (-not $id) { $id = $cfg.activeHost }
        $ts = [double]($req.QueryString['t'] ?? 0)
        $dayStr = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts).ToLocalTime().ToString('yyyy-MM-dd')   # 注意：DateTimeOffset 没有 .LocalDate，别用
        $f = Join-Path $Root "history\$dayStr.jsonl"
        if (-not (Test-Path -LiteralPath $f)) { Send-Json $res @{ ok = $false; matched = $false; t = $ts; error = 'no_match'; note = '该日期没有历史归档（本机只保留最近 ' + [int]($cfg.history.keepDays ?? 7) + ' 天）' }; continue }
        # 性能：一天 ~9000 行，先用正则抽 t 做最近邻，只有命中那一行才做完整 JSON 解析
        # 并发：agent 正在追加同一文件，必须 FileShare.ReadWrite 打开，否则间歇性 500
        $rx = [regex]'"t":(\d+)'
        $best = $null; $bd = [double]::MaxValue; $scanned = 0
        try {
          $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
          $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false))
          try {
            while ($null -ne ($l = $sr.ReadLine())) {
              if (-not $l -or $l[0] -ne '{') { continue }
              $scanned++
              $m = $rx.Match($l); if (-not $m.Success) { continue }
              $d = [math]::Abs([double]$m.Groups[1].Value - $ts)
              if ($d -lt $bd) { $bd = $d; $best = $l }
            }
          } finally { $sr.Dispose(); $fs.Dispose() }
        } catch { Send-Err $res 500 "history read failed: $($_.Exception.Message)"; continue }
        if (-not $best) { Send-Json $res @{ ok = $false; matched = $false; t = $ts; scanned = $scanned; error = 'no_match'; note = '归档里没有这条记录' }; continue }
        # 契约：样本包在 match 里（app.js forensic 读 r.match）；ok/matched/deltaSec/scanned 在顶层
        try { $bo = $best | ConvertFrom-Json } catch { Send-Err $res 500 'history line corrupt'; continue }
        Send-Json $res @{ ok = $true; matched = $true; deltaSec = [int]$bd; scanned = $scanned; match = $bo }
        continue
      }
      '/api/action' {
        if ($req.HttpMethod -eq 'GET') {
          $jid = $req.QueryString['id']
          $jf = Join-Path $actionDir "$jid.json"
          if ($jid -notmatch '^[0-9a-f]{8,32}$' -or -not (Test-Path -LiteralPath $jf)) { Send-Json $res @{ ok = $false; error = 'no_job' }; continue }
          Send-Text $res ([IO.File]::ReadAllText($jf, [Text.UTF8Encoding]::new($false))) 'application/json; charset=utf-8'
          continue
        }
        if ($req.HttpMethod -ne 'POST') { Send-Err $res 405 'method'; continue }
        $sr = [IO.StreamReader]::new($req.InputStream, [Text.UTF8Encoding]::new($false))
        $body = $sr.ReadToEnd(); $sr.Close()
        $jid = [guid]::NewGuid().ToString('N').Substring(0, 16)
        # 异步派给独立子进程，HTTP 层立刻返回 —— 这是「界面不卡」的关键
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
        $psi.FileName = if ($pwsh) { $pwsh.Source } else { 'powershell.exe' }
        $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($body))
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\action.ps1`" -Root `"$Root`" -JobId $jid -PayloadB64 $b64"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        # P0-4：先写 running 再起子进程——否则 action 极快完成（拒绝/非法参数）时 done 会被随后的 running 覆盖
        Write-AtomicText (Join-Path $actionDir "$jid.json") (@{ ok = $true; status = 'running'; id = $jid } | ConvertTo-Json -Compress)
        [void][Diagnostics.Process]::Start($psi)
        Send-Json $res @{ ok = $true; id = $jid; status = 'running' }
        continue
      }
      '/api/hosts' {
        # 主机管理：GET 全量（含禁用）+实时状态；POST add/update/remove/setActive
        if ($req.HttpMethod -eq 'GET') {
          $arr = @($cfg.hosts | ForEach-Object {
            $m = Get-Meta $_.id
            $up = $m.running -and ($m.ageSec -ne $null) -and ($m.ageSec -lt ([int]$_.intervalSec * 4 + 10))
            [ordered]@{ id = $_.id; label = $_.label; sub = $_.sub; sshHost = $_.sshHost; intervalSec = [int]$_.intervalSec; enabled = ($_.enabled -ne $false); running = [bool]$m.running; fresh = [bool]$up; ageSec = $m.ageSec; samples = $m.samples; err = ($m.err ?? $m.stderr); exitReason = ($m.exitReason ?? '') }
          })
          Send-Json $res @{ ok = $true; hosts = $arr; active = $cfg.activeHost }
          continue
        }
        if ($req.HttpMethod -ne 'POST') { Send-Err $res 405 'method'; continue }
        $sr = [IO.StreamReader]::new($req.InputStream, [Text.UTF8Encoding]::new($false))
        $body = $sr.ReadToEnd(); $sr.Close()
        $p = $null
        try { $p = $body | ConvertFrom-Json } catch { Send-Err $res 400 'bad json'; continue }
        $op = "" + $p.op; $hid = "" + $p.id
        $ho = @($cfg.hosts | Where-Object { $_.id -eq $hid })[0]
        $auditH = [ordered]@{ ts = (Get-Date).ToString('s'); host = $hid; act = "host_$op"; result = 'ok' }
        if ("" + $p.tag) { $auditH.tag = "" + $p.tag }   # 同 action.ps1：测试记录不占用默认可见窗口
        # sshHost 会被拼进 ssh 参数串（agent/action），白名单正则杜绝空格/引号/元字符注入；
        # 额外禁首字符 '-'：否则 "-oProxyCommand=…" 之类会被 ssh 当成选项而非主机名
        $sshRx = '^(?!-)[A-Za-z0-9_.@-]{1,128}$'
        if ($op -eq 'add') {
          # id 会进 -HostId 参数与 state\meta-<id>.json 文件名；禁首字符 '-' 防被 PowerShell 当成参数名
          if ($hid -notmatch '^(?!-)[A-Za-z0-9_-]{1,32}$') { Send-Err $res 400 'ID 只允许字母/数字/_/-（1-32 位，不能以 - 开头）'; continue }
          if ($ho) { Send-Err $res 400 "ID 已存在: $hid"; continue }
          $ssh = "" + $p.sshHost
          if ($ssh -notmatch $sshRx) { Send-Err $res 400 'SSH 目标格式非法：只允许字母/数字/_ . @ -（别名或 user@IP）'; continue }
          $label = ("" + $p.label).Trim()
          if ($label.Length -lt 1 -or $label.Length -gt 64) { Send-Err $res 400 '显示名需 1-64 字符'; continue }
          $iv = 3
          if ($p.PSObject.Properties['intervalSec']) { if (-not [int]::TryParse("" + $p.intervalSec, [ref]$iv) -or $iv -lt 1 -or $iv -gt 300) { Send-Err $res 400 '采集间隔需 1-300 秒'; continue } }
          $sub = ("" + $p.sub).Trim(); if (-not $sub) { $sub = $ssh }
          if ($sub.Length -gt 120) { Send-Err $res 400 '备注最长 120 字符'; continue }
          $en = $true; if ($p.PSObject.Properties['enabled']) { $en = [bool]$p.enabled }
          $cfg.hosts = @($cfg.hosts) + [pscustomobject][ordered]@{ id = $hid; label = $label; sub = $sub; sshHost = $ssh; intervalSec = $iv; historyEverySamples = 3; enabled = $en; services = @() }
          if (-not $cfg.activeHost -or $cfg.activeHost -eq '') { $cfg.activeHost = $hid }
          Save-Config; Sync-Hosts   # Start-Agents 每 700ms 巡检，会自动拉起新 agent
          Add-Content -LiteralPath $auditLog -Value ($auditH | ConvertTo-Json -Compress) -Encoding utf8
          Send-Json $res @{ ok = $true; id = $hid }
          continue
        }
        elseif ($op -eq 'update') {
          if (-not $ho) { Send-Err $res 404 "未知主机: $hid"; continue }
          $restart = $false
          if ($p.PSObject.Properties['label']) {
            $label = ("" + $p.label).Trim()
            if ($label.Length -lt 1 -or $label.Length -gt 64) { Send-Err $res 400 '显示名需 1-64 字符'; continue }
            Set-HostProp $ho 'label' $label
          }
          if ($p.PSObject.Properties['sub']) {
            $sub = ("" + $p.sub).Trim()
            if ($sub.Length -gt 120) { Send-Err $res 400 '备注最长 120 字符'; continue }
            Set-HostProp $ho 'sub' $sub
          }
          if ($p.PSObject.Properties['sshHost']) {
            $ssh = "" + $p.sshHost
            if ($ssh -notmatch $sshRx) { Send-Err $res 400 'SSH 目标格式非法：只允许字母/数字/_ . @ -'; continue }
            if ($ssh -ne $ho.sshHost) { $restart = $true }
            Set-HostProp $ho 'sshHost' $ssh
          }
          if ($p.PSObject.Properties['intervalSec']) {
            $iv = 3
            if (-not [int]::TryParse("" + $p.intervalSec, [ref]$iv) -or $iv -lt 1 -or $iv -gt 300) { Send-Err $res 400 '采集间隔需 1-300 秒'; continue }
            if ($iv -ne [int]$ho.intervalSec) { $restart = $true }
            Set-HostProp $ho 'intervalSec' $iv
          }
          $nowEnabled = ($ho.enabled -ne $false)
          if ($p.PSObject.Properties['enabled']) { $nowEnabled = [bool]$p.enabled; Set-HostProp $ho 'enabled' $nowEnabled }
          if ($cfg.activeHost -eq $hid -and -not $nowEnabled) { $cfg.activeHost = "" + (@($cfg.hosts | Where-Object { $_.enabled -ne $false })[0].id) }
          Save-Config; Sync-Hosts   # 单次落盘：中途崩溃不会留下「activeHost 指向已禁用主机」的半套配置
          if (-not $nowEnabled) { Stop-Agent $hid }          # 禁用：停采集
          elseif ($restart) { Stop-Agent $hid }              # 改了连接参数：杀掉让 Start-Agents 用新配置重拉
          Add-Content -LiteralPath $auditLog -Value ($auditH | ConvertTo-Json -Compress) -Encoding utf8
          Send-Json $res @{ ok = $true; id = $hid }
          continue
        }
        elseif ($op -eq 'remove') {
          if (-not $ho) { Send-Err $res 404 "未知主机: $hid"; continue }
          $cfg.hosts = @($cfg.hosts | Where-Object { $_.id -ne $hid })
          Stop-Agent $hid
          if ($cfg.activeHost -eq $hid) { $cfg.activeHost = "" + (@($cfg.hosts | Where-Object { $_.enabled -ne $false })[0].id) }
          Save-Config; Sync-Hosts   # 历史数据文件保留，不删
          Add-Content -LiteralPath $auditLog -Value ($auditH | ConvertTo-Json -Compress) -Encoding utf8
          Send-Json $res @{ ok = $true; id = $hid }
          continue
        }
        elseif ($op -eq 'setActive') {
          if (-not $ho -or $ho.enabled -eq $false) { Send-Err $res 400 '只能切换到已启用主机'; continue }
          $cfg.activeHost = $hid; Save-Config
          Send-Json $res @{ ok = $true; active = $hid }
          continue
        }
        Send-Err $res 400 "未知操作: $op"
        continue
      }
      '/api/audit' {
        $log = Join-Path $Root 'actions.log'
        $showAll = ('' + $req.QueryString['all']) -eq '1'
        # 先取足够多的原始行再过滤，否则隐藏测试记录后会不足 80 条
        $ev = @(Read-LogTail $log 800)
        $hidden = 0
        if (-not $showAll) {
          $hidden = @($ev | Where-Object { '' + $_.tag }).Count
          $kept = @($ev | Where-Object { -not ('' + $_.tag) })
          if ($kept.Count -gt 80) { $kept = $kept[($kept.Count - 80)..($kept.Count - 1)] }
          Send-Json $res @{ ok = $true; events = $kept; hiddenTest = $hidden; all = $false }
        } else {
          if ($ev.Count -gt 200) { $ev = $ev[($ev.Count - 200)..($ev.Count - 1)] }
          Send-Json $res @{ ok = $true; events = $ev; all = $true }
        }
        continue
      }
      default { Send-Err $res 404 'not found' }
    }
  } catch {
    try { Send-Err $res 500 ("panel error: " + $_.Exception.Message) } catch { try { $res.Abort() } catch {} }
  }
}

# R-83：退出必须留痕——此前只打裸 PANEL-EXIT，事后无法回答「为什么没了、最后一次被访问是什么时候」
try { Add-Content -LiteralPath (Join-Path $Root 'log\panel-run.log') -Value ((Get-Date).ToString('s') + ' PANEL-EXIT why=' + $script:exitWhy + ' sinceActive=' + [int]((Get-Date) - $script:lastActive).TotalSeconds + 's pid=' + $PID) -Encoding utf8 } catch {}
Stop-Agents
try { $listener.Stop() } catch {}
Write-Output 'PANEL-EXIT'
