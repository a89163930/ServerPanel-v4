# ============================================================================
#  ServerPanel v4 · 动作子进程 (action worker)
#  由 panel.ps1 异步派生，跑完把结果写 state/actions/<id>.json
#  安全模型（对 v3 的三处修补）：
#    1) 前端只允许传 ID（服务 id / PID），真正的命令一律来自 config.json 白名单
#    2) 杀进程前校验：PID 必须出现在最近一次快照里 + 不命中 denyKill 名单
#    3) 所有特权命令加 sudo -n（绝不挂住等密码），全部动作写 actions.log 审计
# ============================================================================
param(
  [Parameter(Mandatory = $true)][string]$JobId,
  [string]$Root = $PSScriptRoot,
  [Parameter(Mandatory = $true)][string]$PayloadB64
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$jobFile = Join-Path $Root "state\actions\$JobId.json"
$runFlag = Join-Path $Root "state\actions\$JobId.running"
function Write-Json($p, $obj) {
  # tmp + Move-Item -Force：实测并发读不阻塞写；[IO.File]::Replace 在本机抛异常且会留下 .tmp 垃圾
  $tmp = "$p.tmp$PID"
  $txt = $obj | ConvertTo-Json -Compress -Depth 8
  try {
    [IO.File]::WriteAllText($tmp, $txt, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $p, $true)   # P1-3：MoveFileEx REPLACE_EXISTING，不强求独占
  } catch {
    try { [IO.File]::WriteAllText($p, $txt, [Text.UTF8Encoding]::new($false)) } catch {}
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
  }
}
New-Item -ItemType File -Path $runFlag -Force | Out-Null

function Finish($obj) {
  Write-Json $jobFile $obj
  Remove-Item -LiteralPath $runFlag -Force -ErrorAction SilentlyContinue
  exit 0
}
# P1-1：actions.log 按大小轮转（2MB×3）
function Rotate-Log($path, [long]$maxBytes = 2MB, [int]$keep = 3) {
  try {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt $maxBytes)) {
      for ($i = $keep - 1; $i -ge 1; $i--) { if (Test-Path -LiteralPath "$path.$i") { Move-Item -LiteralPath "$path.$i" -Destination "$path.$($i + 1)" -Force } }
      Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
  } catch {}
}
Rotate-Log (Join-Path $Root 'actions.log')

try {
  $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadB64)) | ConvertFrom-Json
} catch { Finish @{ ok = $false; status = 'failed'; error = 'payload 解析失败' } }

$cfg = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw -Encoding utf8 | ConvertFrom-Json
$act = "" + $payload.act

# ---------- 远端执行：一律 base64 传脚本，杜绝引号/注入 ----------
# $target 仅供 sshTest（目标主机可能尚未入 config）；其余动作用白名单主机 $H
function Ssh-Run([string]$script, [int]$timeoutSec = 45, [string]$target = '') {
  $dst = if ($target) { $target } else { $H.sshHost }
  $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($script -replace "`r`n", "`n")))
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'ssh'
  $psi.Arguments = ((@($cfg.sshOpts) + @($dst, "`"echo $b64 | base64 -d | bash`"")) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill($true) } catch {}
    return [pscustomobject]@{ rc = 124; out = ''; err = "执行超时 ${timeoutSec}s，已终止" }
  }
  return [pscustomobject]@{ rc = $p.ExitCode; out = $outTask.Result; err = $errTask.Result }
}

# ---------- 自报失败识别 ----------
# pattern 服务的 startCmd/stopCmd 与 kill 脚本用输出文本报告结果，末尾那句 echo 的 exit code 恒为 0。
# 只看 $r.rc 会把「FAIL: 启动失败」/「WARN: 进程仍在运行」当成成功上报，界面打绿勾而实际没做成。
# 大小写敏感：只认脚本约定的大写标记，避免被远端普通 stderr（如小写 warning: ）误伤。
function Get-FailMark([string]$t) { if ($t -match '\b(FAIL|ERROR|ERR|WARN):') { return $matches[1] } return $null }

# ---------- SSH 连接测试（主机管理：添加前先试连，目标可不在 config 里） ----------
# 安全：命令是固定探测脚本（base64 传输），只有目的地来自前端且经白名单正则严校验；
#       sshOpts 带 BatchMode=yes，绝不挂起等密码；18s 超时强杀。
if ($act -eq 'sshTest') {
  $target = "" + $payload.sshHost
  if ($target -notmatch '^(?!-)[A-Za-z0-9_.@-]{1,128}$') { Finish @{ ok = $false; status = 'failed'; error = 'SSH 目标格式非法：只允许字母/数字/_ . @ -（别名或 user@IP），且不能以 - 开头' } }
  $probe = "echo SP_SSH_OK; hostname; uname -sr; if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -4; fi"
  $r = Ssh-Run $probe 18 $target
  $text = (("" + $r.out).Trim() + "`n" + ("" + $r.err).Trim()).Trim()
  $okT = ($r.rc -eq 0) -and ($text -match 'SP_SSH_OK')
  $auditT = [ordered]@{ ts = (Get-Date).ToString('s'); host = $target; act = 'sshTest'; job = $JobId; result = $(if ($okT) { 'ok' } else { "rc=$($r.rc)" }); out = $text.Substring(0, [Math]::Min(300, $text.Length)) }
  if ("" + $payload.tag) { $auditT.tag = "" + $payload.tag }
  Add-Content -LiteralPath (Join-Path $Root 'actions.log') -Value ($auditT | ConvertTo-Json -Compress) -Encoding utf8
  if ($okT) { Finish @{ ok = $true; status = 'done'; text = ($text -replace 'SP_SSH_OK\r?\n?', '') } }
  Finish @{ ok = $false; status = 'failed'; error = $(if ($text) { $text } else { '连接失败（无输出）' }); text = $text; hint = '检查：SSH 别名/user@IP 是否正确、是否已配免密（ssh-copy-id）、服务器是否可达' }
}

$hId = "" + $payload.host; if (-not $hId) { $hId = $cfg.activeHost }
$H = @($cfg.hosts | Where-Object { $_.id -eq $hId -and $_.enabled -ne $false })[0]
if (-not $H) { Finish @{ ok = $false; status = 'failed'; error = "未知主机: $hId" } }
$audit = [ordered]@{ ts = (Get-Date).ToString('s'); host = $hId; act = $act; job = $JobId }
# 自动化测试可在 payload 里带 tag，审计接口默认隐藏带 tag 的记录：
# 否则跑一轮回归(上百条)就会把用户真实操作挤出「末 80 条」可见窗口，审计等于被测试顶掉。
if ("" + $payload.tag) { $audit.tag = "" + $payload.tag }

# ---------- 杀进程 ----------
if ($act -in @('kill', 'kill9')) {
  $pid2 = 0
  if (-not [int]::TryParse("" + $payload.pid, [ref]$pid2)) { Finish @{ ok = $false; status = 'failed'; error = 'pid 非法' } }
  $audit.pid = $pid2

  # 白名单校验 1：PID 必须在最近一次快照里（防止前端传任意数字进来）
  $latestF = Join-Path $Root "state\latest-$hId.json"
  if (-not (Test-Path -LiteralPath $latestF)) { Finish @{ ok = $false; status = 'failed'; error = '无进程快照，拒绝操作' } }
  # P1-3：共享读快照，避免与 agent 覆盖写撞上时误判「无快照」
  $fs = [IO.FileStream]::new($latestF, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)); $snapTxt = $sr.ReadToEnd(); $sr.Dispose(); $fs.Dispose()
  $snap = $snapTxt | ConvertFrom-Json
  $target = @($snap.procs | Where-Object { [int]$_.pid -eq $pid2 })[0]
  if (-not $target) { Finish @{ ok = $false; status = 'failed'; error = "PID $pid2 不在最近一次快照中，拒绝（请在面板里重新查一次）" } }

  # 白名单校验 2：deny 名单（内核线程 / 关键服务 / root 进程）
  $deny = $cfg.denyKill
  $why = $null
  if (@($deny.pids) -contains $pid2) { $why = "PID $pid2 在保护名单里" }
  elseif (@($deny.userMatch) -contains $target.user) { $why = "$($target.user) 用户的进程不允许从此面板结束" }
  else { foreach ($m in @($deny.cmdMatch)) { if (("" + $target.cmd) -like "*$m*") { $why = "命中保护关键字: $m"; break } } }
  if ($why) {
    $audit.result = 'denied'; $audit.why = $why
    Add-Content -LiteralPath (Join-Path $Root 'actions.log') -Value ($audit | ConvertTo-Json -Compress) -Encoding utf8
    Finish @{ ok = $false; status = 'denied'; error = $why; pid = $pid2; cmd = $target.cmd }
  }

  # P1-6：PID 复用二次校验——快照最长 3s 前，PID 可能已回收并分配给别的进程。
  # kill 前实时取命令行，与快照 cmd 归一化后前 40 字符比对，不一致即拒绝（避免杀无辜）。
  $chk = Ssh-Run "ps -p $pid2 -o args= 2>/dev/null | cut -c1-200" 15
  $a = ((("" + $chk.out).Trim()) -replace '\s+', ' ').Trim()
  $b = ((("" + $target.cmd)) -replace '\s+', ' ').Trim()
  $prefA = $a.Substring(0, [Math]::Min(40, $a.Length)); $prefB = $b.Substring(0, [Math]::Min(40, $b.Length))
  if ($chk.rc -ne 0 -or $prefA -ne $prefB) {
    $why2 = '进程已变化（PID 复用或已退出），请刷新后重试'
    $audit.result = 'denied'; $audit.why = $why2
    Add-Content -LiteralPath (Join-Path $Root 'actions.log') -Value ($audit | ConvertTo-Json -Compress) -Encoding utf8
    Finish @{ ok = $false; status = 'denied'; error = $why2; pid = $pid2; cmd = $target.cmd }
  }

  $cmd = if ($act -eq 'kill9') { "kill -9 $pid2; sleep 0.4; if kill -0 $pid2 2>/dev/null; then echo 'WARN: SIGKILL 后仍存在（可能是僵尸或 D 状态）'; else echo 'OK: 已结束'; fi" }
         else { "kill $pid2; sleep 1; if kill -0 $pid2 2>/dev/null; then echo 'WARN: 进程仍在运行（可能忽略了 SIGTERM，可再加强杀）'; else echo 'OK: 已正常结束'; fi" }
  $r = Ssh-Run $cmd 25
  $text = (("" + $r.out).Trim() + "`n" + ("" + $r.err).Trim()).Trim()
  $markK = Get-FailMark $text
  $okK = ($r.rc -eq 0) -and (-not $markK)
  $audit.result = $(if ($okK) { 'ok' } elseif ($markK) { "self_fail:$markK" } else { "rc=$($r.rc)" }); $audit.out = $text.Substring(0, [Math]::Min(300, $text.Length))
  Add-Content -LiteralPath (Join-Path $Root 'actions.log') -Value ($audit | ConvertTo-Json -Compress) -Encoding utf8
  Finish @{ ok = $okK; status = 'done'; rc = $r.rc; text = $text; pid = $pid2; cmd = $target.cmd;
            error = $(if ($markK) { "脚本报告 $markK：进程未按预期结束" } else { $null }) }}

# ---------- 服务 ----------
if ($act -in @('svc_start', 'svc_stop', 'svc_log')) {
  $sid = "" + $payload.svc
  $svc = @($H.services | Where-Object { $_.id -eq $sid })[0]
  if (-not $svc) { Finish @{ ok = $false; status = 'failed'; error = "未配置的服务: $sid" } }
  $audit.svc = $sid

  $cmd = switch ($act) {
    'svc_log' { if ($svc.logCmd) { $svc.logCmd } else { "echo '(该服务未配置日志命令)'" } }
    default {
      if ($svc.kind -eq 'systemd') {
        if ($act -eq 'svc_start') {
          # P0-3：allowEnable 才 enable --now；否则只 start（--now 与 start 连用是冗余无效参数）
          $en = if ($svc.allowEnable) { 'enable --now' } else { 'start' }
          "sudo -n systemctl $en $($svc.unit) 2>&1; echo state=`$(systemctl is-active $($svc.unit))"
        } else {
          # P0-3：只停，不 disable——停止服务不应顺手取消开机自启
          "sudo -n systemctl stop $($svc.unit) 2>&1; echo state=`$(systemctl is-active $($svc.unit))"
        }
      }
      elseif ($svc.kind -eq 'pattern') {
        if ($act -eq 'svc_start') { $svc.startCmd } else { $svc.stopCmd }
      }
      else { "echo 'ERR: 不支持的服务类型 $($svc.kind)'" }
    }
  }
  if (-not $cmd) { Finish @{ ok = $false; status = 'failed'; error = '该服务未配置对应命令' } }

  $r = Ssh-Run $cmd $(if ($act -eq 'svc_log') { 20 } else { 40 })
  $text = (("" + $r.out).Trim() + "`n" + ("" + $r.err).Trim()).Trim()
  if (-not $text) { $text = '(无输出)' }
  $mark = if ($act -eq 'svc_log') { $null } else { Get-FailMark $text }   # svc_log 只读：日志正文里的 FAIL/ERROR 不代表读取失败
  $okRc = ($r.rc -eq 0) -and (-not $mark) -and ($text -notmatch 'sudo:.*(password|a password)')
  $audit.result = $(if ($okRc) { 'ok' } elseif ($mark) { "self_fail:$mark" } elseif ($r.rc -ne 0) { "rc=$($r.rc)" } else { 'sudo_password' }); $audit.out = $text.Substring(0, [Math]::Min(400, $text.Length))
  Add-Content -LiteralPath (Join-Path $Root 'actions.log') -Value ($audit | ConvertTo-Json -Compress) -Encoding utf8
  Finish @{ ok = $okRc; status = 'done'; rc = $r.rc; text = $text; svc = $sid; label = $svc.label;
            error = $(if ($mark) { "脚本报告 $mark：服务未按预期变更" } elseif (-not $okRc -and $r.rc -ne 0) { "远端返回 rc=$($r.rc)" } else { $null })
            hint = $(if ($text -match 'password') { '服务器未给该用户配置免密 sudo，请在服务器执行: sudo visudo 加一行 your-ssh-user ALL=(ALL) NOPASSWD: /usr/bin/systemctl' } else { $null }) }
}

$audit.result = 'unknown_act'
Finish @{ ok = $false; status = 'failed'; error = "未知动作: $act" }
