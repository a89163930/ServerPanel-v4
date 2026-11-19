# P0 验收（需面板在跑）。用法: pwsh -File build/verify-p0.ps1
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$B = 'http://127.0.0.1:48732'
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
$boot = Invoke-RestMethod "$B/api/boot" -TimeoutSec 10
$H = @{ 'X-Panel-Token' = [string]$boot.token }

"`n--- P0-1 forensics 契约 ---"
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$fx = Invoke-RestMethod "$B/api/forensics?host=YOUR_HOST_ID&t=$now" -Headers $H -TimeoutSec 15
if ($fx.ok -and $fx.matched -and ($null -ne $fx.match) -and ($null -ne $fx.match.PSObject.Properties['gproc'])) { OK '命中: ok/matched/match.gproc 齐全' "deltaSec=$($fx.deltaSec)" } else { NO '命中契约' ($fx | ConvertTo-Json -Compress -Depth 3) }
$nm = Invoke-RestMethod "$B/api/forensics?host=YOUR_HOST_ID&t=1" -Headers $H -TimeoutSec 15
if ((-not $nm.ok) -and $nm.error -eq 'no_match') { OK '无命中: ok=false + error=no_match' "note=$($nm.note)" } else { NO '无命中契约' ($nm | ConvertTo-Json -Compress) }

"`n--- P0-2 历史无重复时间点 ---"
$rf = Join-Path $root 'state\rollup-YOUR_HOST_ID.json'
if (Test-Path $rf) {
  $d = Get-Content $rf -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($k in 'fine', 'mid', 'coarse') {
    $ts = @($d.$k | ForEach-Object { $_[0] })
    $dups = @($ts | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dups.Count -eq 0) { OK "rollup.$k 无重复" "n=$($ts.Count)" } else { NO "rollup.$k 重复" ($dups -join ',') }
  }
} else { NO 'rollup 文件不存在' }
foreach ($w in '15m', '1h', '24h', '7d') {
  $hs = Invoke-RestMethod "$B/api/history?host=YOUR_HOST_ID&window=$w" -Headers $H -TimeoutSec 15
  $ts = @($hs.points | ForEach-Object { $_[0] })
  $mono = $true; for ($i = 1; $i -lt $ts.Count; $i++) { if ($ts[$i] -le $ts[$i - 1]) { $mono = $false; break } }
  if ($hs.ok -and $mono) { OK "history $w t严格递增" "n=$($ts.Count)" } else { NO "history $w 单调性" "mono=$mono" }
}

"`n--- P0-4 action 竞态（20 连击 kill pid=1 必拒） ---"
$maxMs = 0; $denied = 0; $timeout = 0
for ($i = 0; $i -lt 20; $i++) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # tag='e2e' 不能忘：这一招会连打 20 次 kill，不标记就会把用户真实操作挤出审计默认可见窗口
  $j = Invoke-RestMethod "$B/api/action" -Method Post -Body (@{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = 1; tag = 'e2e' } | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers $H -TimeoutSec 15
  $st = 'running'
  for ($k = 0; $k -lt 30; $k++) {
    Start-Sleep -Milliseconds 150
    $r = Invoke-RestMethod "$B/api/action?id=$($j.id)" -Headers $H -TimeoutSec 10
    if ($r.status -ne 'running') { $st = $r.status; break }
  }
  $sw.Stop(); if ($sw.ElapsedMilliseconds -gt $maxMs) { $maxMs = $sw.ElapsedMilliseconds }
  if ($st -eq 'denied') { $denied++ } elseif ($st -eq 'running') { $timeout++ }
}
if ($denied -eq 20 -and $timeout -eq 0) { OK '20/20 denied 无 timeout' "maxMs=$maxMs" } else { NO 'action 竞态' "denied=$denied timeout=$timeout maxMs=$maxMs" }

"`n--- P0-5 status 含 exitReason，运行时 err 为空 ---"
$stt = Invoke-RestMethod "$B/api/status" -Headers $H -TimeoutSec 10
$h0 = $stt.hosts[0]
if ($null -ne $h0.PSObject.Properties['exitReason']) { OK 'status 输出 exitReason' "exitReason='$($h0.exitReason)' err='$($h0.err)' running=$($h0.running)" } else { NO 'status 缺 exitReason' }
if ($h0.running -and (-not $h0.err)) { OK '运行时 err 为空（无假故障）' } else { NO '运行时 err 非空' "err=$($h0.err)" }

"`n==================  $pass 通过 / $fail 失败  =================="
exit $fail