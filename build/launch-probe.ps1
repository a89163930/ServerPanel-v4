# ============================================================================
#  BAT 启动就绪探测（隐藏运行）
#  面板由 BAT 以隐藏窗口拉起，若启动即崩溃，用户原本看到的就是「无反应」。
#  本脚本静默等待 /api/boot 就绪；超时未就绪则弹出一个可见窗口展示
#  log\panel-run*.log（每实例一份，取最新）尾部，把静默失败变成可诊断的失败。
# ============================================================================
param([string]$Root = (Split-Path $PSScriptRoot -Parent))
$Port = 48732
try { $Port = [int](Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).port } catch {}
$ok = $false
foreach ($i in 1..14) {
  Start-Sleep -Milliseconds 900
  try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/api/boot" -TimeoutSec 2).ok) { $ok = $true; break } } catch {}
}
if ($ok) { exit 0 }

$logs = @(Get-ChildItem -LiteralPath (Join-Path $Root 'log') -Filter 'panel-run*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$log = if ($logs.Count) { $logs[0].FullName } else { Join-Path $Root 'log\panel-run.log' }
$tail = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Tail 30 -ErrorAction SilentlyContinue) -join "`r`n" } else { '(no log file found)' }
$msg = @"
[ServerPanel v4] Panel did not start within ~13 seconds.

Last log lines (newest of log\panel-run*.log):
----------------------------------------
$tail
----------------------------------------
Common causes:
  - port $Port held by a stuck previous instance
  - config.json parse error
  - PowerShell 7 (pwsh) missing from PATH
Close this window and retry the BAT; if it keeps failing, send this log.
"@
$diag = Join-Path $Root 'log\launch-fail.txt'
try { Set-Content -LiteralPath $diag -Value $msg -Encoding UTF8 } catch {}
Start-Process pwsh -ArgumentList '-NoProfile', '-NoExit', '-Command', "Get-Content -LiteralPath '$diag'"
exit 1