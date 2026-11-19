# 界面实证：常驻模式起面板 -> 无头 Edge 截图 + dump-dom -> 从渲染后的 DOM 里取真实数字
# （浏览器工具受系统代理影响访问不到回环地址，所以这里显式 --no-proxy-server）
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$log = Join-Path $root 'log'
New-Item -ItemType Directory -Force -Path $log | Out-Null
Remove-Item (Join-Path $log 'v4-*.png'), (Join-Path $log 'v4-dom.html') -Force -ErrorAction SilentlyContinue

& pwsh -NoProfile -File (Join-Path $root 'build\restart.ps1') -IdleSec 1800
Start-Sleep -Seconds 12
$B = 'http://127.0.0.1:48732'
try { $tk = (Invoke-RestMethod "$B/api/boot" -TimeoutSec 8).token } catch { "FAIL 面板没起来: $($_.Exception.Message)"; exit 1 }
$st = Invoke-RestMethod "$B/api/status" -Headers @{ 'X-Panel-Token' = "$tk" } -TimeoutSec 8
"面板就绪 idleLimit=$($st.idleLimit)s samples=$($st.hosts[0].samples) fresh=$($st.hosts[0].fresh)"

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$ud = Join-Path $env:TEMP ('spprof' + (Get-Random))
$base = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-proxy-server', "--user-data-dir=$ud")

foreach ($tab in '', 'perf', 'proc', 'net', 'svc', 'alarm') {   # DR-31：六页全覆盖（补 net）
  $tag = if ($tab) { $tab } else { 'ov' }
  $url = "$B/" + $(if ($tab) { "#$tab" } else { '' })
  # 每个截图用独立 profile：共享 user-data-dir 会让并发的 headless 实例互相抢锁
  Start-Process $edge -ArgumentList ((@('--headless=new', '--disable-gpu', '--no-first-run', '--no-proxy-server', "--user-data-dir=$ud-$tag") + @('--window-size=1280,1060', '--virtual-time-budget=25000', "--screenshot=$(Join-Path $log "v4-$tag.png")", $url))) -WindowStyle Hidden
  Start-Sleep -Seconds 2
}
Start-Process $edge -ArgumentList ($base + @('--virtual-time-budget=25000', '--dump-dom', "$B/")) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $log 'v4-dom.html') -RedirectStandardError (Join-Path $log 'v4-dom.err')

# 等文件真正落盘（交接进程会先退出，必须轮询）
$png = Join-Path $log 'v4-ov.png'; $dom = Join-Path $log 'v4-dom.html'
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 2
  if (@(Get-ChildItem $log -Filter 'v4-*.png').Count -ge 5) { break }
}
Start-Sleep -Seconds 3
'--- 截图产物 ---'
Get-ChildItem $log -Filter 'v4-*.png' | ForEach-Object { "  {0,-16} {1,8} bytes" -f $_.Name, $_.Length }

if ((Get-Item $dom -ErrorAction SilentlyContinue).Length -gt 2000) {
  $t = Get-Content $dom -Raw -Encoding UTF8
  '--- 渲染后的关键节点（JS 真跑起来才会有值） ---'
  foreach ($id in 'cpuV', 'gpuV', 'vmV', 'memV', 'diskV', 'netV', 'upChip', 'lastSync') {
    $m = [regex]::Match($t, "id=""$id""[^>]*>(.{0,120}?)</")
    "  {0,-9} = {1}" -f $id, ($m.Groups[1].Value -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
  }
  $v = [regex]::Match($t, 'id="verdict"[^>]*>(.*?)</div>\s*</div>')
  '  verdict   = ' + (($v.Groups[1].Value -replace '<[^>]+>', ' | ') -replace '\s+', ' ').Trim()
  '  canvas    = ' + ([regex]::Matches($t, '<canvas') | Measure-Object).Count
  '  uPlot DOM = ' + ([regex]::Matches($t, 'uplot|u-canvas-over|u-over') | Measure-Object).Count + ' 处'
  '  服务卡片  = ' + ([regex]::Matches($t, 'class="svc"') | Measure-Object).Count
  '  表格行数  = ' + ([regex]::Matches($t, '<tr>') | Measure-Object).Count
  '  错误横幅  = ' + $(if ($t -match 'id="alertBar"[^>]*style="[^"]*display:block') { '有' } else { '无' })
  $pMeta = [regex]::Match($t, 'id="pMeta"[^>]*>(.{0,200}?)</div>')
  '  进程表头  = ' + ($pMeta.Groups[1].Value -replace '<[^>]+>', '')
}
# DR-32：截图用 virtual-time-budget 会让 uPlot 空白（假象），改用像素级校验断言曲线真实渲染
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build\verify-chart.ps1')
"--- 结束面板，保持零残留 ---"
$safe = [regex]::Escape($root)
$killPat = "-File\s+`"$safe\\(panel|agent)\.ps1|-File\s+$safe\\(panel|agent)\.ps1"
@(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('pwsh.exe', 'powershell.exe') -and ('' + $_.CommandLine) -match $killPat }) | ForEach-Object {
  "结束 $($_.ProcessId)"; try { & taskkill /T /F /PID $_.ProcessId 2>&1 | Out-Null } catch {}
}
Start-Sleep -Seconds 5
"remaining panel procs = " + @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('pwsh.exe', 'powershell.exe') -and ('' + $_.CommandLine) -match "-File\s+`"?$([regex]::Escape($root))\\(panel|agent)\.ps1" }).Count
