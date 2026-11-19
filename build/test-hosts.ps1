# 主机管理回归验收（pwsh 7）：界面增删改、UTF-8 中文无损、注入拦截、agent 随配置起停
# 前提：面板已在跑（pwsh -File panel.ps1 -NoBrowser）。自带夹具，结束前清理主机；
#       注意本脚本会触发 Save-Config 重排 config.json 格式，跑完可用 git checkout 还原。
$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$B = 'http://127.0.0.1:48732'
$Cfg = Join-Path $Root 'config.json'
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
function Code($block) { try { $r = & $block; if ($r -is [System.Management.Automation.ErrorRecord]) { return -1 }; return $r } catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return $_.Exception.Message } }

$boot = Invoke-RestMethod "$B/api/boot" -TimeoutSec 10
if (-not $boot.ok) { NO 'boot'; exit 1 }
$HDR = @{ 'X-Panel-Token' = [string]$boot.token }

# 关键：请求体必须是 UTF-8 字节。若直接传 string，PowerShell 会按本地 ANSI 代码页编码，
# 中文在服务端解出来就成了 '?'——这正是历史上 config 里出现问号的根因（客户端侧，非面板侧）。
function PostJson($obj) {
  $o = @{} + $obj; $o['tag'] = 'e2e'   # 标记为测试记录，不顶掉用户的操作审计默认可见窗口
  $bytes = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress -Depth 6))
  Invoke-RestMethod "$B/api/hosts" -Method POST -Headers $HDR -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 15
}
function DiskCfg { [IO.File]::ReadAllText($Cfg, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
function DiskHost($id) { $c = DiskCfg; @($c.hosts) | Where-Object { $_.id -eq $id } }
function AgentIds {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'pwsh.exe' -and ('' + $_.CommandLine) -match 'agent\.ps1' } |
    ForEach-Object { if ('' + $_.CommandLine -match '-HostId\s+(\S+)') { $matches[1] } })
}
function DelHost($id) { try { PostJson @{ op = 'remove'; id = $id } | Out-Null } catch {} }

$T1 = 'zzhanshutest1'   # 中文夹具
$T2 = 'zzhanshutest2'   # 注入/参数夹具
$cnLabel = '训练三号机'
$cnSub = 'YOUR_SERVER_IP · Your GPU Model · 备注中文（全角）'

"`n--- 0. 夹具清场 ---"
foreach ($t in @($T1, $T2)) { if (DiskHost $t) { DelHost $t; Start-Sleep -Milliseconds 400 } }

"`n--- 1. 添加主机 + 中文无损落盘 ---"
$a = PostJson @{ op = 'add'; id = $T1; label = $cnLabel; sshHost = 'YOUR_HOST_ALIAS'; sub = $cnSub; intervalSec = 5; enabled = $true }
if ($a.ok) { OK 'add 受理' "id=$($a.id)" } else { NO 'add' ($a | ConvertTo-Json -Compress) }
$dh = DiskHost $T1
if (@($dh).Count -eq 1 -and $dh[0].label -eq $cnLabel -and $dh[0].sub -eq $cnSub) { OK '中文按 UTF-8 原样落盘' "label=$($dh[0].label)" }
else { NO '中文落盘' "label=[$($dh[0].label)] sub=[$($dh[0].sub)]" }
if ($dh[0].label -notmatch '\?' -and $dh[0].sub -notmatch '\?') { OK '未退化为问号' } else { NO '问号回归' "$($dh[0].label) / $($dh[0].sub)" }
if ($dh[0].historyEverySamples -eq 3) { OK '默认历史抽样补齐' } else { NO '默认抽样' $dh[0].historyEverySamples }
$raw = [IO.File]::ReadAllText($Cfg, [Text.UTF8Encoding]::new($false))
if ($raw -match [regex]::Escape($cnLabel)) { OK '磁盘原文可检索到中文' } else { NO '磁盘原文' }
# 原有主机的中文不能被一次改写冲掉（Save-Config 往返完整性）
$g0 = DiskHost 'YOUR_HOST_ID'
if ($g0[0].sub -match '·' -and (@($g0[0].services).Count -ge 1) -and (@($g0[0].services)[0].desc -match '\S')) { OK '既有主机中文/服务定义往返无损' "svc=$(@($g0[0].services).Count)" } else { NO '既有主机往返' $g0[0].sub }

"`n--- 2. agent 随新主机自动拉起（无需重启面板） ---"
Start-Sleep -Seconds 3
$ag = AgentIds
if ($ag -contains $T1) { OK '新主机 agent 已拉起' "agents=$($ag -join ',')" } else { NO 'agent 未拉起' "agents=$($ag -join ',')" }

"`n--- 3. 非法输入一律拦在落盘之前 ---"
$badCases = @(
  @{ n = 'ssh 目标带 ssh 选项(- 开头)'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = '-oProxyCommand=touch /tmp/pwned' } }
  @{ n = 'ssh 目标带空格'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'Linux 3090' } }
  @{ n = 'ssh 目标带分号注入'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'a;rm -rf /' } }
  @{ n = 'ssh 目标带引号反引号'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'a`whoami`' } }
  @{ n = 'ssh 目标带管道重定向'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'a>/tmp/x' } }
  @{ n = 'ID 以 - 开头(防被当参数)'; b = @{ op = 'add'; id = '-evil'; label = 'x'; sshHost = 'YOUR_HOST_ALIAS' } }
  @{ n = 'ID 带路径穿越'; b = @{ op = 'add'; id = '..\..\x'; label = 'x'; sshHost = 'YOUR_HOST_ALIAS' } }
  @{ n = 'ID 超长'; b = @{ op = 'add'; id = ('a' * 33); label = 'x'; sshHost = 'YOUR_HOST_ALIAS' } }
  @{ n = '重复 ID'; b = @{ op = 'add'; id = $T1; label = 'x'; sshHost = 'YOUR_HOST_ALIAS' } }
  @{ n = '显示名空'; b = @{ op = 'add'; id = $T2; label = '  '; sshHost = 'YOUR_HOST_ALIAS' } }
  @{ n = '采集间隔 0'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'YOUR_HOST_ALIAS'; intervalSec = 0 } }
  @{ n = '采集间隔 999'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'YOUR_HOST_ALIAS'; intervalSec = 999 } }
  @{ n = '备注超长(>120)'; b = @{ op = 'add'; id = $T2; label = 'x'; sshHost = 'YOUR_HOST_ALIAS'; sub = ('x' * 121) } }
  @{ n = '未知 op'; b = @{ op = 'frobnicate'; id = $T1 } }
  @{ n = 'update 未知主机'; b = @{ op = 'update'; id = 'nosuchhost'; label = 'x' } }
)
foreach ($c in $badCases) {
  $resp = $null; $code = Code { $script:resp = Invoke-WebRequest "$B/api/hosts" -Method POST -Headers $HDR -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($c.b | ConvertTo-Json -Compress -Depth 6))) -UseBasicParsing -TimeoutSec 15; 200 }
  if ($code -eq 400 -or $code -eq 404) { OK $c.n "http=$code" } else { NO $c.n "got $code body=$(($resp | Out-String).Trim())" }
}
if (-not (DiskHost $T2)) { OK '非法请求未污染 config' } else { NO '非法请求已落盘' }

"`n--- 4. 编辑：中文改名 + 间隔 ---"
$u = PostJson @{ op = 'update'; id = $T1; label = '中文改名验证'; intervalSec = 8 }
$dh = DiskHost $T1
if ($u.ok -and $dh[0].label -eq '中文改名验证' -and $dh[0].intervalSec -eq 8) { OK 'update 落盘' "label=$($dh[0].label) iv=$($dh[0].intervalSec)" } else { NO 'update' "label=$($dh[0].label) iv=$($dh[0].intervalSec)" }
if ($dh[0].label -notmatch '\?') { OK 'update 未产生问号' } else { NO 'update 问号' $dh[0].label }

"`n--- 5. 禁用停采 / 启用复采 ---"
PostJson @{ op = 'update'; id = $T1; enabled = $false } | Out-Null
$dh = DiskHost $T1
$disabled = (@($dh).Count -eq 1 -and $dh[0].enabled -eq $false)
if ($disabled) { OK 'enabled=false 落盘' } else { NO 'enabled 落盘' $dh[0].enabled }
Start-Sleep -Seconds 2
if ((AgentIds) -notcontains $T1) { OK '禁用后 agent 已回收' } else { NO '禁用后 agent 仍在' }
PostJson @{ op = 'update'; id = $T1; enabled = $true } | Out-Null
Start-Sleep -Seconds 3
if ((AgentIds) -contains $T1) { OK '重新启用后 agent 复起' } else { NO '重新启用未复起' (AgentIds -join ',') }

"`n--- 6. setActive 持久化 ---"
$sa = PostJson @{ op = 'setActive'; id = $T1 }
if ($sa.ok -and (DiskCfg).activeHost -eq $T1) { OK 'activeHost 落盘' } else { NO 'activeHost' ((DiskCfg).activeHost) }
PostJson @{ op = 'setActive'; id = 'YOUR_HOST_ID' } | Out-Null
if ((DiskCfg).activeHost -eq 'YOUR_HOST_ID') { OK '切回原主机' } else { NO '切回失败' }

"`n--- 7. GET 全量含禁用 + 实时状态 ---"
PostJson @{ op = 'update'; id = $T1; enabled = $false } | Out-Null
$all = Invoke-RestMethod "$B/api/hosts" -Headers $HDR -TimeoutSec 15
$one = @($all.hosts | Where-Object { $_.id -eq $T1 })
if (@($one).Count -eq 1 -and $one[0].enabled -eq $false) { OK '含禁用主机可见' "共 $(@($all.hosts).Count) 台" } else { NO 'GET 全量' }
if ($null -ne $one[0].running -and $null -ne $one[0].fresh -and $one[0].PSObject.Properties['ageSec']) { OK '带 running/fresh/ageSec 状态位' "running=$($one[0].running) fresh=$($one[0].fresh)" } else { NO '状态位' }
$g = @($all.hosts | Where-Object { $_.id -eq 'YOUR_HOST_ID' })
if (@($g).Count -eq 1 -and $g[0].label) { OK 'boot 外主机字段一致' "$($g[0].label)" } else { NO '字段一致' }
PostJson @{ op = 'update'; id = $T1; enabled = $true } | Out-Null

"`n--- 8. sshTest 参数校验（非法目标不起 ssh，秒回） ---"
$t0 = Get-Date
$r = Invoke-RestMethod "$B/api/action" -Method POST -Headers $HDR -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{ act = 'sshTest'; sshHost = '-oProxyCommand=touch /tmp/pwned'; tag = 'e2e' } | ConvertTo-Json -Compress))) -TimeoutSec 15
$job = $null
for ($i = 0; $i -lt 20; $i++) {
  Start-Sleep -Milliseconds 300
  $job = Invoke-RestMethod "$B/api/action?id=$($r.id)" -Headers $HDR -TimeoutSec 8
  if ($job.status -ne 'running') { break }
}
$el = [int]((Get-Date) - $t0).TotalSeconds
if ($job -and -not $job.ok -and ('' + $job.error) -match '非法') { OK '非法 ssh 目标被拒' "${el}s err=$($job.error)" } else { NO 'sshTest 校验' ($job | ConvertTo-Json -Compress) }
if (Test-Path 'C:\tmp\pwned') { NO '疑似执行了注入命令' } elseif ($el -lt 5) { OK '秒回(未挂起等密码/未起 ssh)' "${el}s" } else { NO '耗时异常' "${el}s" }

"`n--- 9. 删除 + 回收 ---"
$rb = PostJson @{ op = 'remove'; id = $T1 }
if (-not (DiskHost $T1) -and $rb.ok) { OK 'remove 落盘' } else { NO 'remove' }
Start-Sleep -Seconds 2
if ((AgentIds) -notcontains $T1) { OK '删除后 agent 已回收' } else { NO '删除后 agent 仍在' }
$c = DiskCfg
$hs = @($c.hosts)
if (@($hs | Where-Object { $_.id -like 'zzhanshu*' }).Count -eq 0) { OK '夹具已清场' "剩余=$($hs.id -join ',')" } else { NO '夹具残留' }
if ($hs.Count -eq 2) { OK '主机数回到基线 2' } else { NO '主机数' $hs.Count }

"`n--- 10. 禁用当前活动主机时 activeHost 自动迁走 ---"
PostJson @{ op = 'update'; id = 'second'; enabled = $true } | Out-Null
PostJson @{ op = 'setActive'; id = 'second' } | Out-Null
PostJson @{ op = 'update'; id = 'second'; enabled = $false } | Out-Null
$ah = (DiskCfg).activeHost
if ($ah -ne 'second') { OK 'activeHost 不指向已禁用主机' "->$ah" } else { NO 'activeHost 悬空' $ah }
PostJson @{ op = 'setActive'; id = 'YOUR_HOST_ID' } | Out-Null   # 上面已禁用 second，此处只复位活动主机

"`n=== test-hosts: PASS=$pass FAIL=$fail ==="
exit $fail
