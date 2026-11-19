# 诊断：用 agent.ps1 完全相同的构造函数生成远端命令，前台跑 8 秒看有没有行回来
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cfg = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw -Encoding utf8 | ConvertFrom-Json
$H = @($cfg.hosts | Where-Object { $_.id -eq 'YOUR_HOST_ID' })[0]
$units = (@($H.services | Where-Object { $_.kind -eq 'systemd' } | ForEach-Object { $_.unit }) -join ' ')
$pats = @($H.services | Where-Object { $_.kind -eq 'pattern' } | ForEach-Object { $_.pattern })
$patB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($pats -join "`n")))
$head = "export PANEL_UNITS=`"$units`"`nexport PANEL_PATTERNS=`"`$(printf '%s' '$patB64' | base64 -d)`"`n"
$raw = ([IO.File]::ReadAllText((Join-Path $Root 'collector.sh'))) -replace "`r`n", "`n" -replace "`r", "`n"
$b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($head + "`n" + $raw))
$remoteCmd = "echo $b64 | base64 -d | bash -s -- 3"
"remoteCmd length = $($remoteCmd.Length)"
"head preview:`n$($head.Substring(0,90))..."

$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'ssh'
$psi.Arguments = ((@($cfg.sshOpts) + @($H.sshHost, $remoteCmd)) -join ' ')
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$p = [Diagnostics.Process]::Start($psi)
$readTask = $p.StandardOutput.ReadLineAsync()
$done = $readTask.Wait(9000)
"got first line within 9s: $done"
if ($done) {
  $l = $readTask.Result
  "first line length = $($l.Length)"
  "first 220 chars: $($l.Substring(0,[Math]::Min(220,$l.Length)))"
  $o = $l | ConvertFrom-Json
  "parsed: schema=$($o.schema) procs=$($o.procCount) gpu.util=$($o.gpu.util) errors=[$($o.errors -join ',')]"
} else {
  'STDERR:'; $p.StandardError.ReadToEnd()
}
try { $p.Kill($true) } catch {}
