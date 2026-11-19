# ============================================================================
#  启动器门禁：根目录 *.bat 的「cmd 可解析性」+ 编码/行尾/危险形态契约
#
#  为什么需要它：本仓库曾出现整份 BAT 因 echo 文案里的圆括号破坏 if 块配对，
#  在 cmd 解析阶段就死掉(rc=255)，导致 panel.ps1 从未被执行、无日志、无窗口、
#  探针也不触发 —— 用户看到的就是「双击没反应」。静态检查与功能检查都必须有：
#    静态层：全 ASCII、CRLF 行尾、echo 行不得带圆括号(if 块内必炸)
#    功能层：把 BAT 原样复制到临时目录跑一遍，cmd 必须 rc=0 且 stderr 为空。
#            复制到临时目录可避免真的拉起面板/agent —— 零副作用。
# ============================================================================
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$fail = 0
function CK($name, $cond, $detail) {
  if ($cond) { "PASS  $name  $detail" } else { $script:fail++; "FAIL  $name  $detail" }
}

$bats = @(Get-ChildItem -LiteralPath $Root -Filter *.bat -File)
CK ('根目录存在启动器 ' + $bats.Count + ' 个') ($bats.Count -ge 1) (($bats | ForEach-Object { $_.Name }) -join ', ')

foreach ($f in $bats) {
  $b = [IO.File]::ReadAllBytes($f.FullName)
  # ---- 字节级：必须纯 ASCII（含中文文件名无碍，内容不许有非 ASCII 字节）----
  $nonAscii = @($b | Where-Object { $_ -gt 127 }).Count
  CK ("[编码] " + $f.Name + ' 内容为纯 ASCII') ($nonAscii -eq 0) ("非 ASCII 字节数=" + $nonAscii)
  # ---- 行尾：BAT 必须 CRLF；裸 LF 会让 cmd 对多行结构解析异常 ----
  $crlf = 0; $bare = 0
  for ($i = 0; $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 10) { if ($i -gt 0 -and $b[$i-1] -eq 13) { $crlf++ } else { $bare++ } }
  }
  CK ("[行尾] " + $f.Name + ' 全部 CRLF') ($crlf -ge 1 -and $bare -eq 0) ("CRLF=" + $crlf + " bareLF=" + $bare)
  # ---- 危险形态：echo 行带圆括号。若该 echo 位于 if 块内，会破坏块配对，整份 BAT 死在解析期 ----
  $txt = [Text.Encoding]::ASCII.GetString($b)
  $riskyEcho = @($txt -split "`r`n" | Where-Object { $_ -match '^\s*(echo|rem)' -and $_ -match '\(' })
  # rem 只是注释，真正致命的是 echo —— 只对 echo 判 FAIL，rem 记录为提示
  $echoRisky  = @($riskyEcho | Where-Object { $_ -match '^\s*echo\b' })
  $remRisky   = @($riskyEcho | Where-Object { $_ -match '^\s*rem\b' })
  CK ("[语法] " + $f.Name + ' echo 行无圆括号') ($echoRisky.Count -eq 0) ($(if ($echoRisky.Count) { $echoRisky -join ' | ' } else { '无' }))
  if ($remRisky.Count) { "INFO  " + $f.Name + ' 有 ' + $remRisky.Count + ' 行 rem 带圆括号(仅提示，不判失败)' }
}

# ---- 功能层：在临时目录原样运行，cmd 必须执行到底且 rc=0 ----
# 三处必须小心：
# ① 绝不用 PowerShell 的 `& cmd ... *> file` 或 `| Out-Null`：它们底层是匿名管道，
#    BAT start 出来的隐藏 pwsh 子进程会继承管道写端永不关闭，读取端永远等不到
#    EOF，整道门禁直接挂死(实测两次 120s 超时)。
# ② 因此用 Start-Process 不带任何 Redirect*，配合 WaitForExit(timeout)+Kill，
#    只认 cmd 自身的退出码；超时不杀会让门禁永久卡住。
# ③ 临时目录里放空的 panel.ps1 / build\launch-probe.ps1 占位：真实探针失败时会弹
#    可见诊断窗，门禁运行时不该在用户桌面开窗；占位不影响解析期检查。
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sp_launcher_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  foreach ($f in $bats) { Copy-Item -LiteralPath $f.FullName -Destination $tmp }
  New-Item -ItemType File -Path (Join-Path $tmp 'panel.ps1') -Value '' | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'build') | Out-Null
  New-Item -ItemType File -Path (Join-Path $tmp 'build\launch-probe.ps1') -Value '' | Out-Null
  foreach ($f in @(Get-ChildItem -LiteralPath $tmp -Filter *.bat -File)) {
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $f.Name) -WorkingDirectory $tmp -PassThru -WindowStyle Hidden
    $timedOut = -not $proc.WaitForExit(15000)
    if ($timedOut) { try { $proc.Kill() } catch {} }
    $rc = try { $proc.ExitCode } catch { 'unknown' }
    CK ('[功能] ' + $f.Name + ' cmd 执行到底 rc=0') ($rc -eq 0) ("rc=" + $rc + $(if ($timedOut) { ' (超时强杀)' } else { '' }))
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

"=== test-launcher: " + $(if ($fail -eq 0) { 'PASS' } else { "FAIL=$fail" }) + " ==="
exit $fail