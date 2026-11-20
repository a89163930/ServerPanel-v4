# 开发期工具：把本地脚本以 base64 送到远端 bash 执行（绕开 PowerShell 引号地狱）
# 用法: pwsh -File build\rr.ps1 -Script collector.sh [-HostAlias Linux_3090] [-Env 'PANEL_ONCE=1']
param(
  [Parameter(Mandatory = $true)][string]$Script,
  [string]$HostAlias = 'Linux_3090',
  [string]$Env = ''
)
$raw = [IO.File]::ReadAllText($Script)
$raw = $raw -replace "`r`n", "`n" -replace "`r", "`n"
# 环境变量优先从 build/_env.sh 读（避开 PowerShell -> pwsh -File 的参数引号问题）
$envFile = Join-Path $PSScriptRoot '_env.sh'
if (Test-Path $envFile) { $raw = [IO.File]::ReadAllText($envFile).Replace("`r`n", "`n") + "`n" + $raw }
elseif ($Env) { $raw = "`n" + $Env + "`n" + $raw }
$b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($raw))
try { $prev = [Console]::OutputEncoding } catch { $prev = $null }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
& ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 $HostAlias "echo $b64 | base64 -d | bash" 2>&1 | Out-String -Stream | ForEach-Object { $_ }
if ($prev) { [Console]::OutputEncoding = $prev }
