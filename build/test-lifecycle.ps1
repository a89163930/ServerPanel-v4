# 生命周期验证：启动面板 -> 确认 hub+agent+ssh 都在 -> 用 restart.ps1 的同一套匹配逻辑结束 -> 确认一个不剩
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$safe = [regex]::Escape($root)
$pat = "$safe\\\(panel|agent)\.ps1"     # 注意：字符串里 \\ 就是两个字符，正则里代表一个字面反斜杠
"匹配用正则 = $pat"

function Snap($tag) {
  $p = @(Get-CimInstance Win32_Process | Where-Object {
      $_.Name -in @('pwsh.exe', 'powershell.exe', 'ssh.exe') -and ('' + $_.CommandLine) -match $pat
    })
  Write-Host ("{0} : {1}" -f $tag, $(if ($p.Count) { ($p | ForEach-Object { "$($_.ProcessId)/$($_.Name)" }) -join '  ' } else { '（无）' }))
  return $p
}

& pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') | Out-Null
Start-Sleep -Seconds 10
$before = Snap '启动后 '
if ($before.Count -lt 2) { "FAIL 应该至少有 hub + agent 两个进程，实际 $($before.Count)" }

& pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') -KeepState
Start-Sleep -Seconds 3
$after = Snap '重启后 '
"in-use  : 重启前 $($before.Count) 个 -> 现在 $($after.Count) 个（重启会新起 hub+agent，所以应为 2）"
if ($after.Count -le 2) { 'PASS  旧进程被干净结束，没有堆积' } else { "FAIL  进程堆积：$($after.Count) 个，说明上一代的 hub/agent 没被杀掉，会残留 SSH 会话" }

# 只结束，不再启动，验证“一个不留”
Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('pwsh.exe','powershell.exe','ssh.exe') -and ('' + $_.CommandLine) -match $pat } |
  ForEach-Object { try { & taskkill /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {} }
Start-Sleep -Seconds 3
$end = Snap '全杀后 '
if ($end.Count -eq 0) { 'PASS  面板关闭后不留任何 pwsh/ssh 残留' } else { 'FAIL  仍有残留' }
"--- 远端是否残留采集循环 ---"
$rc = ((& ssh -o BatchMode=yes Linux_3090 "pgrep -fc 'base64 -d' || echo 0") | Out-String).Trim()
"远端匹配 base64 -d 的进程数(含本次 ssh 自身) = $rc"
