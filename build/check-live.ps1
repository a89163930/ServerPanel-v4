# 用 pwsh7 校验实时链路字段（5.1 会把空 JSON 数组折成 $null，导致计数读数失真）
$ErrorActionPreference = 'Stop'
$B = 'http://127.0.0.1:48732'
$boot = Invoke-RestMethod "$B/api/boot" -TimeoutSec 10
$H = @{ 'X-Panel-Token' = [string]$boot.token }
$s = Invoke-RestMethod "$B/api/snapshot?host=gpu3090" -Headers $H -TimeoutSec 20
$props = $s.PSObject.Properties.Name
$hasPortsTotal = $props -contains 'portsTotal'
$fail = 0
function CK($name, $cond, $detail) { if ($cond) { "PASS  $name  $detail" } else { $script:fail++; "FAIL  $name  $detail" } }
CK 'schema' ($s.schema -eq 'sp2') $s.schema
CK 'errors 为空数组' (@($s.errors).Count -eq 0 -and $null -ne $s.errors) ("type=" + ($s.errors | ForEach-Object { $_.GetType().Name } | Select-Object -First 1))
CK '含 portsTotal 字段' ($props -contains 'portsTotal') "值=$($s.portsTotal)"
CK 'conns 每条字段完整' (@($s.conns | Where-Object { -not $_.local -or -not $_.remote }).Count -eq 0) "$(@($s.conns).Count) 条，首条 $(if(@($s.conns).Count){$s.conns[0].local + ' -> ' + $s.conns[0].remote}else{'无'})"
CK 'portsTotal >= ports 长度' ([int]$s.portsTotal -ge @($s.ports).Count) "$($s.portsTotal) vs $((@($s.ports)).Count)"
CK 'procTotal >= procCount' ([int]$s.procTotal -ge [int]$s.procCount) "$($s.procTotal)/$($s.procCount)"
# R-80：GPU 显存必须并进进程表（pid 匹配 + 数值相等），否则界面新列永远空转
$gj = @(); foreach ($g in @($s.gpus)) { if ($g.procs) { $gj += @($g.procs) } }
if (@($gj).Count -gt 0) {
  $joined = $true; $cmpN = 0
  foreach ($gp in @($gj)) {
    $cmpN++
    $hit = @($s.procs | Where-Object { [int]$_.pid -eq [int]$gp.pid })[0]
    if (-not $hit) { $joined = $false; continue }
    $hv = $hit.gpuMemMiB
    if ($null -eq $hv -or "" -eq $hv -or ([int][math]::Floor([double]$hv) -ne [int][math]::Floor([double]$gp.memMiB))) { $joined = $false }
  }
  CK 'procs 已并入 GPU 显存(gpuMemMiB)' $joined "比对 $cmpN 条占显存进程"
} else { CK 'procs 已并入 GPU 显存(gpuMemMiB)' $true '本周期无占显存进程，跳过口径比对' }
# 同样避开 -like 的 [..] 字符类陷阱，用字面量 StartsWith
$lbBad = @($s.conns | Where-Object {
  $_.local.StartsWith('127.') -or $_.remote.StartsWith('127.') -or
  $_.local.StartsWith('[::1]') -or $_.remote.StartsWith('[::1]') -or
  $_.local -eq '::1' -or $_.remote -eq '::1'
})
$lbNote = if ($lbBad.Count -eq 0) { '' } else { "; 残留 $($lbBad.Count) 条" }
CK 'conns 无环回' ($lbBad.Count -eq 0) "共 $(@($s.conns).Count) 条$lbNote"
$st = Invoke-RestMethod "$B/api/status" -Headers $H -TimeoutSec 10
$h0 = @($st.hosts)[0]
CK 'status 暴露 collectorHash' ('' + $h0.collectorHash -match '^[0-9a-f]{12}$') $h0.collectorHash
CK '采集新鲜' ($h0.fresh -eq $true) "age=$($h0.ageSec)s samples=$($h0.samples) restarts=$($h0.restarts)"
$expect = (Get-FileHash (Join-Path $PSScriptRoot '..\collector.sh') -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
CK 'live 跑的是当前工作区版本 collector.sh' ($h0.collectorHash -eq $expect) "live=$($h0.collectorHash) local=$expect 不等于则重启 agent(taskkill /T /F 那个 agent pid)才会上新版"
"=== live-check: " + $(if ($fail -eq 0) { 'PASS' } else { "FAIL=$fail" }) + " ==="
exit $fail
