# 告警链路验证：临时把 load 规则阈值压到必然触发，观察 防抖 -> 触发 -> 事件落盘 -> status.activeAlerts
# 测完自动还原 config.json
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cfgPath = Join-Path $root 'config.json'
$bak = "$cfgPath.bak"
Copy-Item $cfgPath $bak -Force

try {
  $c = [IO.File]::ReadAllText($cfgPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  $r = @($c.alerts | Where-Object { $_.id -eq 'load' })[0]
  $r.threshold = 0.01; $r.forSec = 0; $r.cooldownSec = 0
  [IO.File]::WriteAllText($cfgPath, ($c | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  'config 已临时改为必然触发 (load > 0.01, forSec=0)'

  & pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') -KeepState | Out-Null
  Start-Sleep -Seconds 16

  $B = 'http://127.0.0.1:48732'
  $tk = (Invoke-RestMethod "$B/api/boot" -TimeoutSec 10).token
  $H = @{ 'X-Panel-Token' = "$tk" }
  $st = Invoke-RestMethod "$B/api/status" -Headers $H -TimeoutSec 10
  $al = Invoke-RestMethod "$B/api/alerts" -Headers $H -TimeoutSec 10

  $act = @($st.activeAlerts)
  if ($act.Count -ge 1) { "PASS  status.activeAlerts 有条目  [" + (($act | ForEach-Object { "$($_.rule)=$($_.level)" }) -join ', ') + ']' }
  else { "FAIL  activeAlerts 为空 -> 阈值/防抖逻辑没跑起来" }
  $loadHit = @($act | Where-Object { $_.rule -eq 'load' })
  if ($loadHit.Count -eq 1) {
    "PASS  load 规则已触发  since=$($loadHit[0].since) dur=$($loadHit[0].durSec)s value=$($loadHit[0].value) level=$($loadHit[0].level)"
    if ($loadHit[0].durSec -is [int] -or $null -ne $loadHit[0].durSec) { 'PASS  持续时长可计算' } else { 'FAIL  durSec 缺失' }
    if ($loadHit[0].level) { 'PASS  告警级别已下发' } else { 'FAIL  level 缺失' }
    if ($loadHit[0].text -and $loadHit[0].text -notmatch '\{value\}') { "PASS  横幅文案已插值: $($loadHit[0].text)" } else { "FAIL  文案: [$($loadHit[0].text)]" }
  } else { "FAIL  load 规则未触发 (得到 $(@($act).Count) 条: $($act.rule -join ','))" }

  $ev = @($al.events)
  if ($ev.Count -ge 1 -and (@($ev | Where-Object { $_.state -eq 'fired' }).Count -ge 1)) { "PASS  alerts.log 有 fired 事件  $($ev.Count) 条" }
  else { "FAIL  alerts.log fired 事件 ($($ev.Count) 条)" }

  # 恢复阈值 -> 应产生 resolved 事件（轮询观察，别靠固定 sleep 猜）
  Copy-Item $bak $cfgPath -Force
  & pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') -KeepState | Out-Null
  $resolved = $false
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 4
    try {
      $tk2 = (Invoke-RestMethod "$B/api/boot" -TimeoutSec 10).token
      $st2 = Invoke-RestMethod "$B/api/status" -Headers @{ 'X-Panel-Token' = "$tk2" } -TimeoutSec 10
      if (@($st2.activeAlerts | Where-Object { $_.rule -eq 'load' }).Count -eq 0) { $resolved = $true; "  第 $($i+1) 次轮询：告警已解除 (samples=$($st2.hosts[0].samples))"; break }
    } catch { "  轮询异常: $($_.Exception.Message)" }
  }
  if ($resolved) { 'PASS  阈值恢复正常后告警自动解除' }
  else {
    'FAIL  告警未解除 —— 现场:'
    '  state/alerts: ' + (Get-Content (Join-Path $root 'state\alerts-gpu3090.json') -Raw -Encoding UTF8)
    '  meta:         ' + (Get-Content (Join-Path $root 'state\meta-gpu3090.json') -Raw -Encoding UTF8)
  }
  $al2 = Invoke-RestMethod "$B/api/alerts" -Headers @{ 'X-Panel-Token' = "$tk2" } -TimeoutSec 10
  if (@($al2.events | Where-Object { $_.state -eq 'resolved' }).Count -ge 1) { 'PASS  alerts.log 记录了 resolved' }
  else { 'FAIL  没有 resolved 事件'; Get-Content (Join-Path $root 'alerts.log') -Encoding UTF8 | ForEach-Object { "  $_" } }
} finally {
  if (Test-Path $bak) { Move-Item -LiteralPath $bak -Destination $cfgPath -Force; "`nconfig.json 已还原" }
}
"--- 还原后的 load 规则 ---"
([IO.File]::ReadAllText($cfgPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).alerts | Where-Object { $_.id -eq 'load' } | Format-List | Out-String
