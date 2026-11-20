# 用构造样本单测 collector.sh 的外连管线(conns_filter)。
# 为什么必须离线测：真实 established 连接不可控，而"列位取错"这种 bug 的表现是
# jq capture 全部失配 -> conns 静默为空数组，界面零数据却没有任何 errors[] 痕迹。
# 实测旧代码正是如此：ss 带 `state established` 后 NF=4(Local=$3,Peer=$4)，
# 旧代码取 $4" "$5 使第二个字段为空。
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$B = 'http://127.0.0.1:48732'
try { $null = Invoke-RestMethod "$B/api/boot" -TimeoutSec 5 } catch { 'BLOCKED 面板未运行，跳过(不计为通过)'; exit 2 }
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }

# 样本里刻意包含：两行环回(应丢)、同对端重复两行(应聚合 n=2)、
# 一个含 ::1 子串的全球 IPv6(旧 grep 子串过滤会误杀，现在必须保留)
$canned = @'
Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
0      0          127.0.0.1:1234     127.0.0.1:5678
0      0          [::1]:111          [::1]:44444
0      0          10.0.0.3:22      10.0.0.184:59073
0      0          10.0.0.3:22      10.0.0.184:59073
0      0          10.0.0.3:22      10.0.0.184:58512
0      0          [2001:db8::1]:443  [2001:db8::2]:51000
0      0          10.0.0.5:80        10.0.0.9:3333
'@
$bCanned = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($canned -replace "`r`n", "`n")))
$coll = ([IO.File]::ReadAllText((Join-Path $root 'collector.sh'), [Text.UTF8Encoding]::new($false))) -replace "`r`n", "`n" -replace "`r", "`n"
$bColl = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($coll))

$inner = @'
PANEL_LIB=1 . /tmp/sp_cf_col.sh
printf '%s' '__CANNED__' | base64 -d > /tmp/sp_cf_in.txt
conns_filter < /tmp/sp_cf_in.txt
'@
$inner = $inner.Replace('__CANNED__', $bCanned)
$bInner = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($inner -replace "`r`n", "`n")))
$cmd = "printf '%s' '$bColl' | base64 -d > /tmp/sp_cf_col.sh; printf '%s' '$bInner' | base64 -d | bash"
$json = (& ssh -o BatchMode=yes -o ConnectTimeout=6 Linux_3090 $cmd 2>&1 | Out-String).Trim()
"远端返回: " + ($json -replace '\s+', ' ').Substring(0, [Math]::Min(150, $json.Length))

if ($json -notmatch '^\[') { NO '管线未产出 JSON 数组(旧代码的典型表现：空/报错)' ''; "`n=== test-collector-conns: PASS=$pass FAIL=$fail ==="; exit 1 }
$arr = @($json | ConvertFrom-Json)
if ($arr.Count -eq 4) { OK '聚合后 4 条(环回已排除)' "n=$($arr.Count)" } else { NO '条目数不对' "期望 4 实际 $($arr.Count)" }
if ($arr.Count -gt 0 -and [int]$arr[0].n -eq 2) { OK '同对端重复已聚合 n=2' "$($arr[0].local) -> $($arr[0].remote)" } else { NO '聚合计数错误' (($arr | ForEach-Object { $_.n }) -join ',') }
if ($arr | Where-Object { $_.remote -eq '[2001:db8::2]:51000' }) { OK '含 ::1 子串的全球 IPv6 未被误杀' } else { NO '全球 IPv6 被误杀' }
# 注意：-like 的 [::1] 是字符类(匹配 : 或 1 中的单个字符)，会把 192.168.x 误判为环回；
# 这里必须用字面量 StartsWith（与产品里 grep '::1' 子串误杀是同一类陷阱）。
$badLb = @($arr | Where-Object {
  $_.local.StartsWith('127.') -or $_.remote.StartsWith('127.') -or
  $_.local.StartsWith('[::1]') -or $_.remote.StartsWith('[::1]') -or
  $_.local -eq '::1' -or $_.remote -eq '::1'
})
if ($badLb.Count -eq 0) { OK '环回连接已全部排除' } else { NO '仍有环回' ($badLb | ForEach-Object { "$($_.local)->$($_.remote)" }) -join ' ' }
$half = @($arr | Where-Object { -not $_.local -or -not $_.remote })
if ($half.Count -eq 0) { OK '每条都有完整 local+remote(列位正确)' } else { NO "$($half.Count) 条缺字段：列位取错" (($half | ForEach-Object { "[$($_.local)][$($_.remote)]" }) -join ' ') }
"`n=== test-collector-conns: PASS=$pass FAIL=$fail ==="
exit $fail
