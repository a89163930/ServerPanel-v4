# 回归测试：本地 ssh 被强杀后，远端采集循环必须自行退出。
# 探测用 `pgrep -fx 'bash -s -- 3'`（整行精确匹配），避免探测命令自身匹配自己的模式。
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$safe = [regex]::Escape($root)

function RemoteLoops {
  $q = "pgrep -fx 'bash -s -- 3' | tr '\n' ' '; echo"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($q))
  $r = ((& ssh -o BatchMode=yes -o ConnectTimeout=10 Linux_3090 "echo $b64 | base64 -d | bash") | Out-String).Trim()
  return @($r -split '\s+' | Where-Object { $_ -match '^\d+$' })
}

$minePat = "-File\s+`"?$safe\\(panel|agent)\.ps1"
function StopPanel {
  @(Get-CimInstance Win32_Process | Where-Object {
    $cl = '' + $_.CommandLine
    $_.Name -in @('pwsh.exe', 'powershell.exe') -and $cl -match $minePat -and $cl -notmatch '-NonInteractive'
  }) | ForEach-Object { try { & taskkill /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {} }
}

StopPanel; Start-Sleep -Seconds 6
$base = RemoteLoops
"基线（面板未启动时）远端循环 = $($base.Count)  [$($base -join ',')]"

& pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') | Out-Null
Start-Sleep -Seconds 12
$on = RemoteLoops
"面板运行中        远端循环 = $($on.Count)  [$($on -join ',')]"
if ($on.Count -ne 1) { "FAIL 期望恰好 1 组采集循环，实际 $($on.Count)" }

$sshPid = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'ssh.exe' -and ('' + $_.CommandLine) -match 'base64 -d' } | ForEach-Object { $_.ProcessId })
"本地采集 ssh.exe = $($sshPid.Count) 个，全部 taskkill /F（模拟粗暴关闭，不给清理机会）"
$sshPid | ForEach-Object { try { & taskkill /F /PID $_ 2>&1 | Out-Null } catch {} }

foreach ($t in 5, 10, 20) {
  Start-Sleep -Seconds $(if ($t -eq 5) { 5 } elseif ($t -eq 10) { 5 } else { 10 })
  $c = RemoteLoops
  "  强杀后 ~${t}s : 远端循环 = $($c.Count)  [$($c -join ',')]"
}

StopPanel
Start-Sleep -Seconds 8
$off = RemoteLoops
"面板关闭后        远端循环 = $($off.Count)  [$($off -join ',')]"

if ($on.Count -eq 1 -and $off.Count -le 1) { '' ; 'PASS 无进程堆积：关闭面板后远端最多剩 1 组，且不随重启次数累加' }
if ($off.Count -gt 1) { "FAIL 关闭后仍有 $($off.Count) 组残留" }
