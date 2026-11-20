# ============================================================================
#  ServerPanel v4 · 采集代理 (agent) —— 每台主机一个独立进程
#  维持一条常驻 SSH 流式会话（不反复握手），把 JSON lines 落成：
#    state/latest-<id>.json   最新完整样本（HTTP 层零解析直读）
#    state/meta-<id>.json     健康元信息（新鲜度/重连次数/错误）
#    state/alerts-<id>.json   告警状态
#    history/<date>.jsonl     瘦历史（24h 曲线 + 当时谁在吃显存）
#    alerts.log               告警事件流水
#  原则：断线自动重连；缺失值保持 null 绝不用 0 冒充；父面板死了自杀不留孤儿
# ============================================================================
param(
  [Parameter(Mandatory = $true)][string]$HostId,
  [string]$Root = $PSScriptRoot,
  [int]$SelfExitAfterSec = 25
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# ---------- 基础设施 ----------
function Read-JsonFile($p, $dflt, [switch]$Hashtable) {
  if (-not (Test-Path -LiteralPath $p)) { return $dflt }
  try {
    if ($Hashtable) { return (Read-SharedText $p | ConvertFrom-Json -AsHashtable) }
    return (Read-SharedText $p | ConvertFrom-Json)
  } catch { return $dflt }
}
# P1-3：共享读（FileShare.ReadWrite|Delete），与并发覆盖写/改名不阻塞
function Read-SharedText($p) {
  $fs = [IO.FileStream]::new($p, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)); try { return $sr.ReadToEnd() } finally { $sr.Dispose() } } finally { $fs.Dispose() }
}
function Write-AtomicText($p, $s) {
  # tmp + Move-Item -Force（[IO.File]::Replace 在本机抛异常，失败会留下 .tmp 垃圾）
  $tmp = "$p.tmp$PID"
  try {
    [IO.File]::WriteAllText($tmp, $s, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $p, $true)   # P1-3：MoveFileEx REPLACE_EXISTING，不强求独占
  } catch {
    try { [IO.File]::WriteAllText($p, $s, [Text.UTF8Encoding]::new($false)) } catch {}
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
  }
}
foreach ($d in 'state', 'history', 'log') { $x = Join-Path $Root $d; if (-not (Test-Path $x)) { New-Item -ItemType Directory -Path $x | Out-Null } }

$cfg = Read-JsonFile (Join-Path $Root 'config.json') $null
if (-not $cfg) { exit 1 }
$H = @($cfg.hosts | Where-Object { $_.id -eq $HostId })[0]
if (-not $H) { exit 1 }

$collPath = Join-Path $Root 'collector.sh'
if (-not (Test-Path -LiteralPath $collPath)) { exit 1 }

$interval = [int]$H.intervalSec; if ($interval -lt 1) { $interval = 3 }
$histEvery = [int]$H.historyEverySamples; if ($histEvery -lt 1) { $histEvery = 3 }
$units = (@($H.services | Where-Object { $_.kind -eq 'systemd' } | ForEach-Object { $_.unit }) -join ' ')
$pats  = @($H.services | Where-Object { $_.kind -eq 'pattern' } | ForEach-Object { $_.pattern })

$latestF = Join-Path $Root "state\latest-$HostId.json"
$metaF   = Join-Path $Root "state\meta-$HostId.json"
$alertF  = Join-Path $Root "state\alerts-$HostId.json"
$hubBeat = Join-Path $Root 'state\hub.json'
$alertLog = Join-Path $Root 'alerts.log'

# ---------- 可变状态（必须 $script: 显式作用域） ----------
$script:prevCpu = $null; $script:prevNet = $null; $script:prevTs = $null
$script:sampleIdx = 0;   $script:histCount = 0
$script:proc = $null
$lines = $null   # 已改用 ReadLineAsync 泵，保留占位避免旧引用
$script:outTask = $null; $script:errTask = $null
$alertSt = Read-JsonFile $alertF @{} -Hashtable
if ($alertSt -isnot [hashtable]) { $alertSt = @{} }

$state = [ordered]@{
  hostId = $HostId; started = (Get-Date).ToString('s')
  # 字段存的是本地时间（Get-Date 's' 无偏移）。旧名叫 *Utc 是错的，任何信它的消费者会差 8 小时（R-45/DR-45）
  lastLineLocal = $null; lastSampleLocal = $null; ageSec = $null
  restarts = 0; samples = 0; sshPid = 0; stderr = ''; err = ''; exitReason = ''
  lastDropAt = ''; lastDropWhy = ''   # 会话中断的本地时刻与原因（重连后会清零 err/stderr，靠这两个字段保留痕迹）
  collectorHash = ''   # 当前这条 SSH 流实际在用哪一版 collector.sh(只上传一次, 改文件不会自动生效)
  everConnected = $false; running = $true
  intervalSec = $interval; host = $H.sshHost; label = $H.label
}

function Save-Meta {
  $now = Get-Date
  if ($state.lastSampleLocal) { $state.ageSec = [int]($now - [datetime]$state.lastSampleLocal).TotalSeconds }
  $state.running = ($null -ne $script:proc) -and (-not $script:proc.HasExited)
  Write-AtomicText $metaF ($state | ConvertTo-Json -Compress -Depth 5)
}

function Num($v) { if ($null -eq $v -or "$v" -eq '') { return $null } try { return [double]$v } catch { return $null } }

# ---------- 标量指标（告警规则 DSL 的取值面） ----------
function Get-Scalars($s) {
  $d = @{}
  $d['gpu.util']   = Num $s.gpu.util
  $d['gpu.tempC']  = Num $s.gpu.tempC
  $d['gpu.memPct'] = $s.derived.gpuMemPct
  $d['mem.pct']    = $s.derived.memPct
  $d['swap.pct']   = $s.derived.swapPct
  $d['cpu.pct']    = Num $s.derived.cpuPct
  $d['net.rxKBs']  = [math]::Round(((Num $s.derived.rxRateBps) ?? 0) / 1024, 1)
  $d['net.txKBs']  = [math]::Round(((Num $s.derived.txRateBps) ?? 0) / 1024, 1)
  if ($s.cpu.cores -and $null -ne $s.cpu.load1) { $d['cpu.loadPerCore'] = [math]::Round([double]$s.cpu.load1 / [double]$s.cpu.cores, 2) }
  $dp = 0
  foreach ($x in @($s.disk)) {
    $tt = Num $x.total; $uu = Num $x.used
    if ($tt -gt 0) { $p = [math]::Round($uu / $tt * 100, 1); if ($p -gt $dp) { $dp = $p; $d['disk.maxMp'] = $x.mp } }
  }
  $d['disk.maxPct'] = $dp
  # P1-7：从未连上时用「距启动时长」（成长值），让 agent.ageSec>20 规则在 SSH 从未建立时也能触发
  $d['agent.ageSec'] = if ($state.ageSec) { $state.ageSec } else { [int]((Get-Date) - [datetime]$state.started).TotalSeconds }
  foreach ($sv in @($s.services)) { $d["service.$($sv.unit)"] = $sv.state }
  foreach ($pt in @($s.patterns)) { $d["service.$($pt.pattern)"] = $pt.state }
  return $d
}

# P1-1：日志按大小轮转（2MB×3），防无界增长
function Rotate-Log($path, [long]$maxBytes = 2MB, [int]$keep = 3) {
  try {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt $maxBytes)) {
      for ($i = $keep - 1; $i -ge 1; $i--) { if (Test-Path -LiteralPath "$path.$i") { Move-Item -LiteralPath "$path.$i" -Destination "$path.$($i + 1)" -Force } }
      Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
  } catch {}
}
# ---------- 告警评估（forSec 去抖 + cooldown + resolved 事件） ----------
function Eval-Alerts($s) {
  $sc = Get-Scalars $s
  $now = Get-Date
  Rotate-Log $alertLog
  foreach ($r in @($cfg.alerts)) {
    if (-not $r -or -not $r.id) { continue }
    $v = $sc[$r.metric]
    if (-not $alertSt.ContainsKey($r.id)) { $alertSt[$r.id] = @{ since = $null; active = $false; lastFire = $null; value = $null; miss = 0 } }
    $st = $alertSt[$r.id]
    # R-78：区分「这台机器暂时没这个数据」与「这个指标名从来没出现过」。
    # 键不存在(指标名写错、或引用了未配置的 service.xxx)时这条规则永远不可能触发，
    # 而用户是靠告警知道过热/满盘的 —— 静默失效比误报危险，必须显式报出来。
    if ($sc.ContainsKey($r.metric)) { $st.miss = 0 } else { $st.miss = [int]($st.miss ?? 0) + 1 }
    if ($null -eq $v) { continue }
    $hit = switch ($r.op) {
      '>'  { $v -gt  [double]$r.threshold }
      '>=' { $v -ge [double]$r.threshold }
      '<'  { $v -lt  [double]$r.threshold }
      '<=' { $v -le [double]$r.threshold }
      '==' { "$v" -eq "$($r.threshold)" }
      default { "$v" -ne "$($r.threshold)" }
    }
    $cd = [int]($r.cooldownSec ?? 600)
    if ($hit) {
      if (-not $st.since) { $st.since = $now.ToString('s') }
      $dur = ($now - [datetime]$st.since).TotalSeconds
      $sinceFire = if ($st.lastFire) { ($now - [datetime]$st.lastFire).TotalSeconds } else { 1e9 }
      if ($dur -ge [int]($r.forSec ?? 0) -and (-not $st.active) -and $sinceFire -ge $cd) {
        $st.active = $true; $st.lastFire = $now.ToString('s'); $st.value = $v
        $msg = ("" + $r.text) -replace '\{value\}', $v
        # P1-7：从未连上时给更明确的文案（指向 SSH 配置而非「中断」）
        if ($r.id -eq 'agent' -and -not $state.everConnected) { $msg = "SSH 从未建立（检查 sshOpts / 免密 / 主机名），已尝试 $($v)s" }
        Add-Content -LiteralPath $alertLog -Value (([ordered]@{ ts = $now.ToString('s'); host = $HostId; rule = $r.id; level = $r.level; state = 'fired'; value = $v; text = $msg } | ConvertTo-Json -Compress)) -Encoding utf8
      }
      $st.value = $v
    }
    elseif ($st.active) {
      $st.active = $false; $st.since = $null
      Add-Content -LiteralPath $alertLog -Value (([ordered]@{ ts = $now.ToString('s'); host = $HostId; rule = $r.id; level = $r.level; state = 'resolved'; value = $v; text = (("" + $r.text) -replace '\{value\}', $v) } | ConvertTo-Json -Compress)) -Encoding utf8
    }
    else { $st.since = $null }
  }
  Write-AtomicText $alertF ($alertSt | ConvertTo-Json -Compress -Depth 5)
}

# ---------- 瘦历史 ----------
function Rotate-History {
  $keep = [int]($cfg.history.keepDays ?? 7)
  $cut = (Get-Date).Date.AddDays(-$keep)
  Get-ChildItem (Join-Path $Root 'history') -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Where-Object { try { [datetime]$_.BaseName -lt $cut } catch { $false } } | Remove-Item -Force -ErrorAction SilentlyContinue
  $max = [double]($cfg.history.maxFileMB ?? 64) * 1MB
  Get-ChildItem (Join-Path $Root 'history') -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt $max } | ForEach-Object {
      $all = [IO.File]::ReadAllLines($_.FullName)
      if ($all.Count -gt 20000) { [IO.File]::WriteAllLines($_.FullName, $all[($all.Count - 20000)..($all.Count - 1)]) }
    }
}

# ---------- 三档预聚合（分层汇总，hub 永不扫原始文件） ----------
# 点序: [t, cpu, gpu, gpct, mem, load, rxKBs, txKBs, gtemp]  —— 与 panel.ps1 的 cols 一致
$COLS = 9
function New-Roll {
  @{ fine = [Collections.Generic.List[object]]::new()
     mid = [Collections.Generic.List[object]]::new()
     coarse = [Collections.Generic.List[object]]::new()
     mb = $null; cb = $null }
}
function Load-Rollup {
  $r = New-Roll
  $o = Read-JsonFile (Join-Path $Root "state\rollup-$HostId.json") $null -Hashtable
  if ($o) {
    foreach ($k in 'fine', 'mid', 'coarse') {
      if ($o[$k]) { foreach ($p in @($o[$k])) { $r[$k].Add($p) } }
    }
  }
  # P0-2：按桶时间戳去重（保留最后一次出现），清理历史遗留的重复桶
  foreach ($k in 'fine', 'mid', 'coarse') {
    $list = $r[$k]
    if ($list.Count -lt 2) { continue }
    $seen = @{}; $dd = [Collections.Generic.List[object]]::new()
    for ($i = $list.Count - 1; $i -ge 0; $i--) { $t = [long]$list[$i][0]; if (-not $seen.ContainsKey($t)) { $seen[$t] = $true; $dd.Add($list[$i]) } }
    $dd.Reverse(); $r[$k] = $dd
  }
  # P0-2：丢掉未闭合的当前桶——重启后 mb/cb 内存状态丢失，保留它会让下个样本新建同桶重复行。
  # 删掉后下个样本会重建，损失 ≤60s/≤600s 聚合值，换回无重复。
  $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
  foreach ($pair in @(@('mid', 60), @('coarse', 600))) {
    $list = $r[$pair[0]]; $size = [long]$pair[1]
    $cur = [long]([Math]::Floor([double]$now / $size) * $size)
    if ($list.Count -gt 0 -and [long]$list[$list.Count - 1][0] -eq $cur) { $list.RemoveAt($list.Count - 1) }
  }
  return $r
}
function Trim-List($list, [int]$keepSec, [int]$maxN) {
  $cut = [DateTimeOffset]::Now.ToUnixTimeSeconds() - $keepSec
  while ($list.Count -gt 0 -and [double]$list[0][0] -lt $cut) { $list.RemoveAt(0) }
  while ($list.Count -gt $maxN) { $list.RemoveAt(0) }
}
function Avg-From($sum, $cnt, [long]$b) {
  $avg = [object[]]::new($COLS); $avg[0] = $b
  for ($i = 1; $i -lt $COLS; $i++) { $avg[$i] = if ($cnt[$i] -gt 0) { [math]::Round($sum[$i] / $cnt[$i], 2) } else { $null } }
  return , $avg
}
function Push-Bucket($tierKey, $metaKey, $pt, [long]$size) {
  $b = [long]([Math]::Floor([double]$pt[0] / $size) * $size)
  $m = $script:roll[$metaKey]
  if ($m -and $m.k -eq $b) {
    for ($i = 1; $i -lt $COLS; $i++) { if ($null -ne $pt[$i]) { $m.sum[$i] += [double]$pt[$i]; $m.cnt[$i]++ } }
    $avg = Avg-From $m.sum $m.cnt $b
    $list = $script:roll[$tierKey]
    if ($list.Count -gt 0) { $list[$list.Count - 1] = $avg } else { $list.Add($avg) }
  } else {
    $sum = [double[]]::new($COLS); $cnt = [int[]]::new($COLS)
    for ($i = 1; $i -lt $COLS; $i++) { if ($null -ne $pt[$i]) { $sum[$i] = [double]$pt[$i]; $cnt[$i] = 1 } }
    $avg = Avg-From $sum $cnt $b
    $list = $script:roll[$tierKey]
    # P0-2 保险：列表最后一项已是同一桶（重启丢 mb/cb 后的首样本）则替换，不新建
    if ($list.Count -gt 0 -and [long]$list[$list.Count - 1][0] -eq $b) { $list[$list.Count - 1] = $avg } else { $list.Add($avg) }
    $script:roll[$metaKey] = @{ k = $b; sum = $sum; cnt = $cnt }
  }
}
function Add-Roll($pt) {
  $script:roll.fine.Add($pt)
  Trim-List $script:roll.fine 1800 700
  Push-Bucket 'mid' 'mb' $pt 60
  Push-Bucket 'coarse' 'cb' $pt 600
  Trim-List $script:roll.mid 21600 400
  Trim-List $script:roll.coarse 604800 1100
}
function Save-Rollup {
  Write-AtomicText (Join-Path $Root "state\rollup-$HostId.json") (@{ fine = $script:roll.fine; mid = $script:roll.mid; coarse = $script:roll.coarse } | ConvertTo-Json -Compress -Depth 5)
}
$script:roll = Load-Rollup

# ---------- 单个样本处理 ----------
function Handle-Sample($s) {
  $now = Get-Date

  # CPU% —— 差值在代理端算，前端刷新不再丢基线（v3 的 bug 之一）
  $cpuPct = $null
  $cs = @($s.cpu.stat | ForEach-Object { Num $_ })
  if ($cs.Count -ge 5 -and $null -eq ($cs | Where-Object { $null -eq $_ })) {
    $idle = $cs[3] + $cs[4]; $tot = ($cs | Measure-Object -Sum).Sum
    if ($script:prevCpu) {
      $di = $idle - $script:prevCpu.idle; $dt = $tot - $script:prevCpu.tot
      if ($dt -gt 0) { $cpuPct = [math]::Max(0, [math]::Min(100, (1 - $di / $dt) * 100)) }
    }
    $script:prevCpu = @{ idle = $idle; tot = $tot }
  }

  $rxR = $null; $txR = $null
  $rx = Num $s.net.rx; $tx = Num $s.net.tx
  if ($null -ne $rx -and $null -ne $tx) {
    if ($script:prevNet -and $script:prevTs) {
      $dtS = ($now - $script:prevTs).TotalSeconds
      if ($dtS -gt 0.5) {
        $rxR = [math]::Max(0, ($rx - $script:prevNet.rx) / $dtS)
        $txR = [math]::Max(0, ($tx - $script:prevNet.tx) / $dtS)
      }
    }
    $script:prevNet = @{ rx = $rx; tx = $tx }; $script:prevTs = $now
  }

  # 派生指标
  $mt = Num $s.mem.total; $mu = Num $s.mem.used
  $memPct = if ($mt -gt 0) { [math]::Round($mu / $mt * 100, 1) } else { $null }
  $stt = Num $s.mem.swapTotal; $stu = Num $s.mem.swapUsed
  $swapPct = if ($stt -gt 0) { [math]::Round($stu / $stt * 100, 1) } else { 0 }
  $gt = Num $s.gpu.memTotalMiB; $gu = Num $s.gpu.memUsedMiB
  $gpuMemPct = if ($gt -gt 0) { [math]::Round($gu / $gt * 100, 1) } else { $null }

  # pid -> 命令，给历史里的 gpu 占用者补名字
  $pidCmd = @{}
  foreach ($p in @($s.procs)) { $pidCmd[[string]$p.pid] = "" + $p.cmd }

  $s | Add-Member -Force -NotePropertyMembers ([ordered]@{
    derived = [ordered]@{
      cpuPct = $cpuPct; rxRateBps = $rxR; txRateBps = $txR
      memPct = $memPct; swapPct = $swapPct; gpuMemPct = $gpuMemPct
      agentTs = $now.ToString('s'); hostId = $HostId
    }
  })

  Write-AtomicText $latestF ($s | ConvertTo-Json -Compress -Depth 8)
  $state.lastSampleLocal = $now.ToString('s')
  $state.everConnected = $true
  $state.samples = [int]$state.samples + 1
  $script:sampleIdx++

  Add-Roll ([object[]]@(
    [double]$s.ts,
    $(if ($null -ne $cpuPct) { [math]::Round($cpuPct, 1) } else { $null }),
    $(Num $s.gpu.util), $gpuMemPct, $memPct, $(Num $s.cpu.load1),
    [math]::Round(($rxR ?? 0) / 1024, 1), [math]::Round(($txR ?? 0) / 1024, 1), $(Num $s.gpu.tempC)
  ))

  Eval-Alerts $s

  if (($script:sampleIdx % $histEvery) -eq 0) {
    $rec = [ordered]@{
      t = $s.ts; cpu = $cpuPct; gpu = (Num $s.gpu.util)
      gmem = $gu; gpct = $gpuMemPct; gtemp = (Num $s.gpu.tempC); gpw = (Num $s.gpu.powerW)
      mem = $memPct; load = (Num $s.cpu.load1)
      rx = [math]::Round(($rxR ?? 0) / 1024, 1); tx = [math]::Round(($txR ?? 0) / 1024, 1)
      disk = @($s.disk | ForEach-Object { $tt = Num $_.total; $uu = Num $_.used; if ($tt -gt 0) { [ordered]@{ mp = $_.mp; pct = [math]::Round($uu / $tt * 100, 1) } } })
      gproc = @($s.gpu.procs | ForEach-Object { [ordered]@{ pid = $_.pid; m = $_.memMiB; c = ($pidCmd[[string]$_.pid] ?? ('pid ' + $_.pid)) } })
      top = @($s.procs | Select-Object -First 5 | ForEach-Object { $k = "" + $_.cmd; [ordered]@{ pid = $_.pid; u = $_.user; c = $_.pcpu; m = $_.pmem; k = $k.Substring(0, [Math]::Min(70, $k.Length)) } })
    }
    Add-Content -LiteralPath (Join-Path $Root ("history\{0}.jsonl" -f $now.ToString('yyyy-MM-dd'))) -Value ($rec | ConvertTo-Json -Compress -Depth 6) -Encoding utf8
    $script:histCount++
    if (($script:histCount % 200) -eq 0) { Rotate-History }
  }
}

# ---------- 常驻流 + 重连 ----------
function New-RemoteCmd {
  $patB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($pats -join "`n")))
  $head = "export PANEL_UNITS=`"$units`"`nexport PANEL_PATTERNS=`"`$(printf '%s' '$patB64' | base64 -d)`"`n"
  $raw = ([IO.File]::ReadAllText($collPath)) -replace "`r`n", "`n" -replace "`r", "`n"
  $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($head + "`n" + $raw))
  return "echo $b64 | base64 -d | bash -s -- $interval"
}

function Start-Stream {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'ssh'
  $psi.Arguments = ((@($cfg.sshOpts) + @($H.sshHost, (New-RemoteCmd))) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $script:proc = [Diagnostics.Process]::new()
  $script:proc.StartInfo = $psi
  [void]$script:proc.Start()
  # 用 ReadLineAsync 轮询泵，不用 .NET 事件：事件回调在非主线程上没有 PowerShell runspace，会直接把进程搞崩
  $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
  $script:errTask = $script:proc.StandardError.ReadLineAsync()
  $state.sshPid = $script:proc.Id
  # 把生效版本写进 meta：否则改了 collector.sh 但流未重连时，界面无法分辨跑的是新一版依旧版
  try { $state.collectorHash = (Get-FileHash -LiteralPath $collPath -Algorithm SHA256).Hash.Substring(0, 12).ToLower() } catch { $state.collectorHash = '' }
  $state.err = ''; $state.exitReason = ''
  $script:prevCpu = $null; $script:prevNet = $null; $script:prevTs = $null
}

function Handle-Line($ln) {
  $state.lastLineLocal = (Get-Date).ToString('s')
  if ($ln -notmatch '^\s*\{') {
    if ("" + $ln) { $t = "" + $ln; $state.stderr = $t.Substring(0, [Math]::Min(220, $t.Length)) }
    return
  }
  $s = $null
  try { $s = $ln | ConvertFrom-Json } catch { $state.err = 'JSON 解析失败: ' + $_.Exception.Message; return }
  # R-80：procs[] 并入单进程显存后升到 sp2；仍接受 sp1，避免新 agent 先于远端 collector 重连时被误杀(升级窗口)
  if ("$($s.schema)" -notin @('sp1', 'sp2')) { $state.err = "未知 schema: $($s.schema)"; return }
  try { Handle-Sample $s } catch { $state.err = "样本处理出错: $($_.Exception.Message)" }
}

Start-Stream
$lastBeat = Get-Date; $lastMeta = Get-Date; $lastRoll = Get-Date; $backoff = 1
while ($true) {
  if ($script:outTask -and $script:outTask.Wait(0)) {
    $ln = $script:outTask.Result
    if ($null -eq $ln) { $script:outTask = $null }
    else { Handle-Line $ln; $backoff = 1; if ($script:proc -and -not $script:proc.HasExited) { $script:outTask = $script:proc.StandardOutput.ReadLineAsync() } else { $script:outTask = $null } }
  }
  if ($script:errTask -and $script:errTask.Wait(0)) {
    $el = $script:errTask.Result
    if ($null -eq $el) { $script:errTask = $null }
    else { if ("" + $el) { $t = "" + $el; $state.stderr = $t.Substring(0, [Math]::Min(220, $t.Length)) }; $script:errTask = if ($script:proc -and -not $script:proc.HasExited) { $script:proc.StandardError.ReadLineAsync() } else { $null } }
  }

  $dead = ($null -eq $script:outTask) -or ($null -ne $script:proc -and $script:proc.HasExited)
  if ($dead) {
    # DR-44：重连成功会清空 err/stderr，不留痕迹就无法回答「昨晚抖动那几次到底断在哪、为什么断」
    $why = '' + $state.stderr
    if (-not $why) {
      $rcTxt = $null
      try { if ($script:proc -and $script:proc.HasExited) { $rcTxt = '' + $script:proc.ExitCode } } catch {}
      $why = if ($null -ne $rcTxt) { "ssh 退出 rc=$rcTxt" } elseif ($null -eq $script:outTask) { 'stdout 结束(EOF)' } else { '会话中断' }
    }
    $state.lastDropAt = (Get-Date).ToString('s'); $state.lastDropWhy = $why.Substring(0, [Math]::Min(200, $why.Length))
    $state.restarts = [int]$state.restarts + 1
    $state.err = "SSH 会话中断，$($backoff)s 后重连(累计第 $($state.restarts) 次)"
    Save-Meta
    try { if ($script:proc) { $script:proc.Kill($true) } } catch {}
    try { if ($script:proc) { $script:proc.Dispose() } } catch {}
    $script:proc = $null; $script:errTask = $null
    Start-Sleep -Seconds $backoff
    $backoff = [Math]::Min(15, $backoff * 2)
    try { Start-Stream } catch { $state.err = "重连失败: $($_.Exception.Message)"; $script:outTask = $null }
  }

  if (((Get-Date) - $lastMeta).TotalSeconds -ge 1) { Save-Meta; $lastMeta = Get-Date }
  if (((Get-Date) - $lastRoll).TotalSeconds -ge 10) { Save-Rollup; $lastRoll = Get-Date }

  if (((Get-Date) - $lastBeat).TotalSeconds -ge 3) {
    $lastBeat = Get-Date
    $hb = Read-JsonFile $hubBeat $null
    if ($hb -and $hb.ts) {
      try { $age = ((Get-Date) - [datetime]$hb.ts).TotalSeconds } catch { $age = 0 }
      if ($age -gt $SelfExitAfterSec) {
        try { $script:proc.Kill($true) } catch {}
        # P0-5：空闲随面板退出是正常生命周期，不是故障——写 exitReason，err 只留真正的传输/解析错误
        $state.running = $false; $state.exitReason = 'idle_heartbeat_lost'; $state.err = ''
        Save-Meta; Save-Rollup; exit 0
      }
    }
  }
  Start-Sleep -Milliseconds 100
}
