# 重启面板（保留 state 用 -KeepState；-IdleSec 覆盖空闲退出秒数）。
#
# 识别自己人的三代教训：
#  1) 早先用 `-notmatch 'opensquilla'` 想避免误杀网关，但项目路径本身含 Opensquilla，
#     结果把自己的 panel/agent 全排除 → 多 agent 并发覆写同一份 state。
#  2) 改成必须 `-File <绝对项目路径>\(panel|agent).ps1` 后，用相对路径启动的面板
#     (`-File panel.ps1`，在项目目录里手敲就会这样) 匹配不上 → 旧 hub 存活、新实例被
#     双启动保护劝退，留下「旧 hub + 新 agent」的混版本状态，脚本却照样打印 restarted。
#  3) 现在：绝对/相对两种形式都认，另外用 state/hub.json 里的权威 pid 兜底，
#     并在结尾实测「服务 48732 的进程确实换成新的」，不换人就报失败退出非零。
param([switch]$KeepState, [int]$IdleSec = -999)
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$safeRoot = [regex]::Escape($root)
$absPat = '-File\s+"?' + $safeRoot + '\\(panel|agent)\.ps1(\s|$)'
$relPat = '-File\s+"?\.?\\?(panel|agent)\.ps1(\s|$)'      # 在项目目录里用裸文件名启动
$hubPid = $null
try { $hubPid = [int](('' + (Get-Content (Join-Path $root 'state\hub.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pid)) } catch {}

function Get-MyProcs {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $cl = '' + $_.CommandLine
    ($_.Name -in @('pwsh.exe', 'powershell.exe')) -and
    (($cl -match $absPat) -or ($cl -match $relPat)) -and
    ($cl -notmatch '-NonInteractive') -and
    ($cl -notmatch '\s-Command(\s|$)')
  }) | Where-Object { $_.ProcessId -ne $PID }
}

$victims = Get-MyProcs
# hub.json 说的算：它记录的是当前真正在监听端口的面板 pid，即便启动形式没被正则覆盖也能抓到
if ($hubPid -gt 0) {
  $hubProc = @(Get-CimInstance Win32_Process -Filter "ProcessId=$hubPid" -ErrorAction SilentlyContinue |
    Where-Object { ('' + $_.CommandLine) -match '(panel|agent)\.ps1' })
  foreach ($hp in $hubProc) { if (-not ($victims.ProcessId -contains $hp.ProcessId)) { $victims += $hp } }
}

if (-not $victims) { '没有需要结束的旧进程' }
foreach ($v in $victims) {
  "结束 pid=$($v.ProcessId) $($v.Name) " + $(if ('' + $v.CommandLine -match '(panel)\.ps1') { '(hub)' } else { '(agent)' })
  try { & taskkill /T /F /PID $v.ProcessId 2>&1 | Out-Null } catch {}
}
$oldPids = @($victims.ProcessId)
if ($victims) { Start-Sleep -Seconds 2 }

if (-not $KeepState) {
  Remove-Item (Join-Path $root 'state\*') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $root 'history\*') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $root 'alerts.log'), (Join-Path $root 'actions.log') -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'state\actions') | Out-Null
Start-Sleep -Milliseconds 300
$extra = @()
if ($IdleSec -ne -999) { $extra = @('-IdleSec', "$IdleSec") }
$p = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList ((@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'panel.ps1'), '-NoBrowser') + $extra))
"panel 已启动 pid=$($p.Id)" + $(if ($IdleSec -ne -999) { " idleSec=$IdleSec" } else { '' })

# --- 收尾校验：真的换人了吗 ---
$port = 48732
try { $port = [int](Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).port } catch {}
$served = $null; $servedPid = $null
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  try { if ((Invoke-RestMethod "http://127.0.0.1:$port/api/boot" -TimeoutSec 3).ok) { $served = $true } } catch { continue }
  try { $servedPid = [int](('' + (Get-Content (Join-Path $root 'state\hub.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pid)) } catch {}
  break
}
if (-not $served) { "FAIL 端口 $port 无响应，面板没起来（看 log\panel-run*.log，每实例一份）"; exit 1 }
if ($oldPids -contains $servedPid) { "FAIL 仍在为旧 pid=$servedPid 服务，等于没重启"; exit 1 }
if ($servedPid -ne $p.Id) { "WARN 服务者 pid=$servedPid 与本次启动的 pid=$($p.Id) 不同（可能有第二个实例接管，请核对）"; exit 1 }
"OK 已确认由新面板 pid=$servedPid 服务 http://127.0.0.1:$port"
exit 0
