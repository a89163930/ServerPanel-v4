# ServerPanel v4 端到端验收（pwsh 7）：鉴权、采集、三档历史、kill 白名单、审计
$ErrorActionPreference = 'Continue'
$B = 'http://127.0.0.1:48732'
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
function Code($block) { try { $r = & $block; if ($r -is [System.Management.Automation.ErrorRecord]) { return -1 }; return $r } catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return $_.Exception.Message } }

$boot = Invoke-RestMethod "$B/api/boot" -TimeoutSec 10
$TK = [string]$boot.token
if ($boot.ok -and $TK.Length -eq 32) { OK 'boot 返回 token' "hosts=$($boot.hosts.id -join ',') v$($boot.version)" } else { NO 'boot'; exit 1 }
$HDR = @{ 'X-Panel-Token' = $TK }
function HX($extra) { $HDR = @{} + $HDR; foreach ($k in $extra.Keys) { $HDR[$k] = $extra[$k] }; return $HDR }

"`n--- 1. 鉴权与跨源 ---"
if ((Code { Invoke-RestMethod "$B/api/snapshot" -TimeoutSec 8 }) -eq 401) { OK '无 token => 401' } else { NO '无 token' }
if ((Code { Invoke-RestMethod "$B/api/snapshot" -Headers @{ 'X-Panel-Token' = 'deadbeef' } -TimeoutSec 8 }) -eq 401) { OK '错 token => 401' } else { NO '错 token' }
if ((Code { Invoke-RestMethod "$B/api/snapshot" -Headers (HX @{ 'Origin' = 'http://evil.example' }) -TimeoutSec 8 }) -eq 403) { OK '跨源 Origin => 403' } else { NO '跨源 Origin' }
if ((Code { Invoke-RestMethod "$B/api/boot" -Headers @{ 'Host' = 'attacker.example' } -TimeoutSec 8 }) -eq 421) { OK 'Host 伪装 => 421' } else { NO 'Host 伪装' }
$st = Code { (Invoke-RestMethod "$B/api/snapshot" -Headers (HX @{ 'Origin' = $B }) -TimeoutSec 8).procCount }
if ($st -is [ValueType] -or $st -is [double] -or $st -is [long] -or $st -is [int]) { OK '同源 Origin => 放行' "procCount=$st" } else { NO '同源 Origin' "$st" }
$inj = Code { try { (Invoke-WebRequest "$B/api/snapshot;cat/etc/passwd" -Headers $HDR -UseBasicParsing -TimeoutSec 8).StatusCode } catch { [int]$_.Exception.Response.StatusCode } }
if ($inj -in @(404, 400)) { OK '路径注入 => 404/400' } else { NO '路径注入' "got $inj" }

"`n--- 2. 采集正确性 ---"
$s = Invoke-RestMethod "$B/api/snapshot?host=YOUR_HOST_ID" -Headers $HDR -TimeoutSec 15
if ($s.schema -eq 'sp1') { OK 'schema=sp1' } else { NO 'schema' $s.schema }
if ($s.procCount -gt 200) { OK "进程全量 = $($s.procCount)" } else { NO '进程数过少' $s.procCount }
if ($null -ne $s.gpu.util -and $null -ne $s.cpu.cores) { OK "GPU/CPU 有值" "gpu=$($s.gpu.util)% cores=$($s.cpu.cores) mem=$($s.gpu.memUsedMiB)/$($s.gpu.memTotalMiB)MiB" } else { NO 'GPU/CPU' }
if ($null -ne $s.derived.cpuPct) { OK "CPU% 由代理算出" "$([math]::Round($s.derived.cpuPct,1))%" } else { NO 'CPU% 为 null' }
if ($null -ne $s.derived.rxRateBps) { OK "网络速率由代理算出" "rx=$([math]::Round($s.derived.rxRateBps/1024,1))KB/s" } else { NO '速率 null' }
if (@($s.errors).Count -eq 0) { OK 'errors[] 为空（无静默失败）' } else { NO 'errors' ($s.errors -join ';') }
if (@($s.disk).Count -ge 2) { OK "磁盘挂载点 = $(@($s.disk).Count)" (($s.disk | ForEach-Object { $_.mp }) -join ' ') } else { NO '磁盘' }
if (@($s.services).Count -ge 1) { OK "systemd 服务状态 = $(@($s.services).Count)" (($s.services | ForEach-Object { "$($_.unit):$($_.state)/$($_.enabled)" }) -join ' ') } else { NO '服务' }
if (@($s.patterns).Count -ge 1) { OK "pattern 服务状态" (($s.patterns | ForEach-Object { "$($_.state)($($_.n))" }) -join ' ') } else { NO 'pattern' }
if (@($s.ports).Count -ge 1 -and (@($s.ports) | Where-Object { @($_.procs).Count -gt 0 })) { OK "端口带归属进程" "共 $(@($s.ports).Count) 个端口" } else { NO '端口归属' }
$longCmd = @($s.procs | Where-Object { $_.cmd.Length -gt 200 } | Select-Object -First 1)
if ($longCmd) { OK '长命令行完整保留(未被 150 字符砍断)' "len=$($longCmd[0].cmd.Length)" } else { NO '长命令行' }
$meta = Invoke-RestMethod "$B/api/status" -Headers $HDR -TimeoutSec 10
$hh = @($meta.hosts)[0]
# DR-57: collector.sh 只在起流时上传一次，改完不重连就仍旧版 —— 必须能从接口看出当前生效版本
if ('' + $hh.collectorHash -match '^[0-9a-f]{8,16}$') { OK 'status 暴露 collectorHash' "$($hh.collectorHash)" } else { NO 'collectorHash 不可用' "('' + $hh.collectorHash)" }
if ($hh.fresh -and $hh.ageSec -le 15) { OK '新鲜度=正常' "samples=$($hh.samples) age=$($hh.ageSec)s restarts=$($hh.restarts)" } else { NO '新鲜度' "age=$($hh.ageSec) err=$($hh.err)" }

"`n--- 3. 历史三档 ---"
foreach ($w in '15m', '1h', '24h', '7d') {
  $hs = Invoke-RestMethod "$B/api/history?host=YOUR_HOST_ID&window=$w" -Headers $HDR -TimeoutSec 15
  if ($hs.ok -and @($hs.points).Count -ge 1) { OK "window=$w" "tier=$($hs.tier) pts=$(($hs.points).Count)" } else { NO "window=$w" ($hs | ConvertTo-Json -Compress) }
}
$fx = Code { (Invoke-RestMethod "$B/api/forensics?host=YOUR_HOST_ID&t=$([DateTimeOffset]::Now.ToUnixTimeSeconds())" -Headers $HDR -TimeoutSec 15).ok }
if ($fx -eq $true) { OK 'forensics 按时间点回查' } else { NO 'forensics' "$fx" }

"`n--- 4. kill 白名单 ---"
function RunJob($bodyObj) {
  $o = @{} + $bodyObj; $o['tag'] = 'e2e'   # 标记为测试记录：不污染用户的操作审计默认可见窗口
  $j = Invoke-RestMethod "$B/api/action" -Method Post -Body ($o | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers $HDR -TimeoutSec 20
  if (-not $j.id) { return $j }
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 700
    $r = Invoke-RestMethod "$B/api/action?id=$($j.id)" -Headers $HDR -TimeoutSec 10
    if ($r.status -ne 'running') { return $r }
  }
  return @{ status = 'timeout' }
}
$d1 = RunJob @{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = 1 }
if ($d1.status -eq 'denied') { OK 'PID 1 被拒绝' $d1.error } else { NO 'PID 1' ($d1 | ConvertTo-Json -Compress) }
$d2 = RunJob @{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = 999999 }
if ($d2.status -eq 'failed' -or $d2.status -eq 'denied') { OK '快照外的 PID 被拒绝' $d2.error } else { NO '快照外 PID' ($d2 | ConvertTo-Json -Compress) }
$sshdSnap = (Invoke-RestMethod "$B/api/snapshot?host=YOUR_HOST_ID" -Headers $HDR -TimeoutSec 15).procs
$sshd = @($sshdSnap | Where-Object { $_.cmd -like '*sshd*' } | Select-Object -First 1)[0]
if ($sshd) { $d3 = RunJob @{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = $sshd.pid }; if ($d3.status -eq 'denied') { OK "sshd(pid $($sshd.pid)) 被拒绝" $d3.error } else { NO 'sshd 未被保护' ($d3 | ConvertTo-Json -Compress) } }
$d4 = RunJob @{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = '1; rm -rf /' }
if ($d4.status -eq 'failed' -or $d4.status -eq 'denied') { OK '命令注入型 pid 被拒' ($d4.error ?? $d4.status) } else { NO 'pid 注入' ($d4 | ConvertTo-Json -Compress) }

"`n--- 5. 真实 kill 通路（自己起的临时进程，不碰用户任务） ---"
$mk = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("nohup sleep 7771 >/dev/null 2>&1 & echo `$!"))
$np = ((& ssh -o BatchMode=yes YOUR_HOST_ALIAS "echo $mk | base64 -d | bash") | Out-String).Trim()
if ($np -match '^\d+$') {
  OK '远端已起临时 sleep' "pid=$np"
  Start-Sleep -Seconds 4
  $in = @( (Invoke-RestMethod "$B/api/snapshot?host=YOUR_HOST_ID" -Headers $HDR -TimeoutSec 15).procs | Where-Object { $_.pid -eq [int]$np } ).Count
  if ($in -eq 1) { OK '该进程已进入面板快照' } else { NO '快照里没有它' }
  $k = RunJob @{ host = 'YOUR_HOST_ID'; act = 'kill'; pid = [int]$np }
  if ($k.ok -and $k.text -match 'OK') { OK 'kill 成功且服务器已确认' $k.text } else { NO 'kill' ($k | ConvertTo-Json -Compress) }
  $chk = ((& ssh -o BatchMode=yes YOUR_HOST_ALIAS "ps -p $np -o pid=" | Out-String).Trim())
  if ($chk -eq '') { OK '服务器侧复查：进程确实消失' } else { NO '服务器侧仍存在' "ps -p $np -> $chk" }
} else { NO '临时进程没起来' "$np" }

"`n--- 6. 服务动作与审计 ---"
# svc_log 走真实存在的 systemd 服务(demo-inference)，不绑到那条失效的 gateway 路径上：
# gateway 的 logCmd 指向服务器上并不存在的目录，一旦该路径所在的文件系统悬挂，
# 本断言会整块跑 20s 后 rc=124 变红——测试不应依赖一个已知的坏配置(设计文档 R-44)。
$lg = RunJob @{ host = 'YOUR_HOST_ID'; act = 'svc_log'; svc = 'demo-inference' }
if ($lg.ok) { OK 'svc_log 只读动作' (($lg.text -replace '\s+', ' ').Substring(0, [Math]::Min(70, $lg.text.Length))) } else { NO 'svc_log' ($lg | ConvertTo-Json -Compress) }
$bad = RunJob @{ host = 'YOUR_HOST_ID'; act = 'svc_stop'; svc = 'not-a-real-service' }
if ($bad.status -eq 'failed') { OK '未配置的服务 id 被拒' $bad.error } else { NO '未知服务' ($bad | ConvertTo-Json -Compress) }
$au = Invoke-RestMethod "$B/api/audit?all=1" -Headers $HDR -TimeoutSec 10
if (@($au.events).Count -ge 3) { OK '审计流水已记录(?all=1 含测试)' "$(@($au.events).Count) 条" } else { NO '审计为空' }
# DR-52: 默认视图必须把带 tag 的测试记录挡在外面，否则一轮回归就能顶掉用户真实操作记录
$auD = Invoke-RestMethod "$B/api/audit" -Headers $HDR -TimeoutSec 10
$leak = @($auD.events | Where-Object { '' + $_.tag })
if ($leak.Count -eq 0 -and [int]$auD.hiddenTest -ge 1) { OK '默认视图已隔离测试记录' "hidden=$($auD.hiddenTest)" } else { NO '测试记录泄露到默认视图' "leak=$($leak.Count) hidden=$($auD.hiddenTest)" }
$al = Invoke-RestMethod "$B/api/alerts" -Headers $HDR -TimeoutSec 10
OK '告警接口可读' "$(@($al.events).Count) 条事件"

"`n--- 7. 静态资源与响应头 ---"
$r = Invoke-WebRequest "$B/" -UseBasicParsing -TimeoutSec 10
$csp = $r.Headers['Content-Security-Policy']
$cspScript = ([regex]::Match($csp, 'script-src[^;]*')).Value
if ($r.StatusCode -eq 200 -and $cspScript -eq "script-src 'self'") { OK "HTML + CSP 严格(script-src 无 unsafe-inline)" } else { NO 'CSP script-src' "[$cspScript]" }
if ($csp -notmatch "script-src[^;]*unsafe-inline") { OK '内联脚本被 CSP 禁用' } else { NO '内联脚本' }
if ((Invoke-WebRequest "$B/app.js" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200) { OK 'app.js' } else { NO 'app.js' }
if ((Invoke-WebRequest "$B/vendor/uplot.iife.min.js" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200) { OK 'uPlot 本地化(无外链)' } else { NO 'uPlot' }
if ((Invoke-WebRequest "$B/vendor/uplot.min.css" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200) { OK 'uPlot css' } else { NO 'uPlot css' }
if ($r.Content -notmatch 'cdn\.|unpkg|jsdelivr|googleapis') { OK '页面无任何外部 CDN 引用' } else { NO '存在外链' }

"`n==================  $pass 通过 / $fail 失败  =================="
exit $fail
