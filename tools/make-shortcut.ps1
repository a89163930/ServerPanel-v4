# 生成桌面快捷方式。关键点：路径全部由 $PSScriptRoot 推导，
# 绝不写死绝对路径（v3 的 _sc3.ps1 写死了已废弃的 C:\Users\wangz\Tools\... ，重跑一次就把启动器指到不存在的目录）
param([switch]$NoIcon)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bat = Join-Path $root '启动-服务器管家v4.bat'
if (-not (Test-Path -LiteralPath $bat)) { throw "找不到启动脚本: $bat" }
$desk = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desk '服务器管家v4.lnk'))
$lnk.TargetPath = $bat
$lnk.WorkingDirectory = $root
$lnk.IconLocation = 'shell32.dll,232'
$lnk.Description = '服务器管家 v4 - Linux GPU 服务器监控面板'
$lnk.Save()
Write-Output "SHORTCUT = $(Join-Path $desk '服务器管家v4.lnk')"
Write-Output "TARGET   = $bat"
Write-Output "WORKDIR  = $root"
# 自校验：重读一遍，确认指向存在的路径
$l2 = $ws.CreateShortcut($lnk.FullName)
$ok = (Test-Path -LiteralPath $l2.TargetPath) -and ($l2.WorkingDirectory -eq $root)
Write-Output ("VERIFY   = " + $(if ($ok) { 'OK 目标存在且工作目录正确' } else { "FAIL target=$($l2.TargetPath)" }))
if (-not $ok) { exit 1 }
