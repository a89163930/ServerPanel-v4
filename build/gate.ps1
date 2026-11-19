# 全量门禁唯一入口。为什么需要它：本仓库有 7 套互补门禁，手工分批跑会出两种事故——
# (1) 改了某个脚本却沿用旧结果(部分验证假绿)；(2) 面板没在跑时 API 门禁大面积 FAIL，
# 看起来像代码坏了，其实只是依赖缺失。这里把两者都堵住：一次跑完，且缺依赖记成 BLOCKED
# 而不是 PASS 或 FAIL，并明确 exit=2 提示先起面板。
# 用法: pwsh -File build/gate.ps1 [-Only <名字子串>] [-List] [-TimeoutSec 300]
param([string]$Only = '', [switch]$List, [int]$TimeoutSec = 300)
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $pwsh) { 'FAIL  找不到 pwsh(需要 PowerShell 7)'; exit 3 }
$logDir = Join-Path $root 'log\gate'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if (-not (Test-Path (Join-Path $root 'state'))) { New-Item -ItemType Directory (Join-Path $root 'state') | Out-Null }
$port = 48732
try { $port = [int](([IO.File]::ReadAllText((Join-Path $root 'config.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).port) } catch {}
if ($port -lt 1) { $port = 48732 }

# Needs: '' 纯静态 / 'panel' 需要面板在跑 / 'node' 需要 node
$gates = @(
  @{ n = 'launcher'; s = 'build/test-launcher.ps1'; needs = '' }
  @{ n = 'syntax';  s = 'build/syntax-check.ps1';       needs = '' }
  @{ n = 'hosts';   s = 'build/test-hosts.ps1';         needs = 'panel' }
  @{ n = 'e2e';     s = 'build/test.ps1';               needs = 'panel' }
  @{ n = 'p0';      s = 'build/verify-p0.ps1';          needs = 'panel' }
  @{ n = 'jsonfold';s = 'build/test-jsonfold.ps1';      needs = '' }
  @{ n = 'hygiene'; s = 'build/test-audit-hygiene.ps1'; needs = '' }
  @{ n = 'collect'; s = 'build/test-collector-errors.ps1'; needs = '' }
  @{ n = 'loopback'; s = 'build/test-loopback.ps1'; needs = '' }
  @{ n = 'conns';   s = 'build/test-collector-conns.ps1'; needs = 'panel' }
  @{ n = 'live';    s = 'build/check-live.ps1'; needs = 'panel' }
  @{ n = 'chart';   s = 'build/verify-chart.ps1'; needs = 'panel' }
  @{ n = 'pill';    s = 'build/test-auditpill.ps1';     needs = 'node' }
)
if ($List) { $gates | ForEach-Object { "{0,-9} {1}  needs={2}" -f $_.n, $_.s, $_.needs }; exit 0 }
if ($Only) { $gates = @($gates | Where-Object { $_.n -like "*$Only*" -or $_.s -like "*$Only*" }) }
if (-not $gates.Count) { "FAIL  -Only '$Only' 没匹配到任何门禁"; exit 3 }

$panelOk = $false
try { $panelOk = [bool](Invoke-RestMethod "http://127.0.0.1:$port/api/boot" -TimeoutSec 3).ok } catch {}
$nodeOk = [bool](Get-Command node -ErrorAction SilentlyContinue)
$depLine = 'pwsh=yes  panel=' + $(if ($panelOk) { 'yes' } else { "NO(见下)" }) + '  node=' + $(if ($nodeOk) { 'yes' } else { 'NO' })
"依赖探测: $depLine  地址=http://127.0.0.1:$port"
''

$rows = @(); $failed = 0; $blocked = 0
foreach ($g in $gates) {
  $missing = switch ($g.needs) { 'panel' { if (-not $panelOk) { 'panel' } } 'node' { if (-not $nodeOk) { 'node' } } default { $null } }
  if ($missing) {
    $blocked++
    $rows += [pscustomobject]@{ Gate = $g.n; Status = 'BLOCKED'; Info = "缺少 $missing"; Log = '-' }
    "  BLOCKED  $($g.n)  需要 $missing 在跑"
    continue
  }
  $out = Join-Path $logDir "$($g.n).txt"; $err = Join-Path $logDir "$($g.n).err.txt"
  $p = Start-Process -FilePath $pwsh.Source -ArgumentList ('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root $g.s)) `
    -WorkingDirectory $root -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch {}
    $failed++
    $rows += [pscustomobject]@{ Gate = $g.n; Status = 'FAIL'; Info = "超时 ${TimeoutSec}s"; Log = $out }
    "  FAIL     $($g.n)  超时 ${TimeoutSec}s"
    continue
  }
  $txt = if (Test-Path $out) { [IO.File]::ReadAllText($out, [Text.UTF8Encoding]::new($false)) } else { '' }
  $sumLine = (@($txt -split "`r?`n") | Where-Object { $_ -match '通过 /|PASS=|个错误|全部通过|:.*(PASS|FAIL)' -or $_ -match '^(PASS|FAIL)\s' } | Select-Object -Last 1)
  $info = if ($sumLine) { ('' + $sumLine).Trim() } elseif ($p.ExitCode -eq 0) { 'ok' } else { "exit=$($p.ExitCode)" }
  # 约定: exit 0=通过, 1=失败, 2=因环境缺依赖未全跑(门禁自己上报)
  if ($p.ExitCode -eq 2) {
    $blocked++
    "  BLOCKED  $($g.n)  门禁自报未全跑  $info"
    $rows += [pscustomobject]@{ Gate = $g.n; Status = 'BLOCKED'; Info = "门禁自报: $info"; Log = (Split-Path $out -Leaf) }
    continue
  }
  if ($p.ExitCode -eq 0) { "  pass     $($g.n)  $info" } else { "  FAIL     $($g.n)  $info" }
  if ($p.ExitCode -ne 0) {
    $failed++
    $errTxt = if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) { "  stderr见 $err" } else { '' }
    if ($errTxt) { $info += $errTxt }
  }
  $rows += [pscustomobject]@{ Gate = $g.n; Status = $(if ($p.ExitCode -eq 0) { 'pass' } else { 'FAIL' }); Info = $info; Log = (Split-Path $out -Leaf) }
}

''
'================ 门禁汇总 ================'
$rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Output
"pass={0}  FAIL={1}  BLOCKED={2}" -f @($rows | Where-Object { $_.Status -eq 'pass' }).Count, $failed, $blocked
if ($blocked -gt 0) {
  "有 $blocked 套门禁因缺依赖未执行 —— 这不是通过。面板未跑时先: pwsh -File panel.ps1 -NoBrowser"
  exit 2
}
if ($failed -gt 0) { "有 $failed 套门禁失败" ; exit 1 }
'全部门禁通过'
exit 0
