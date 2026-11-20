# is_loopback 单元测试：用 collector.sh 的 PANEL_LIB 接缝 source 进来跑真值表。
# 为什么必须离线跑：本机造不出「目的地址含 ::1 子串的全球 IPv6」真连接，
# 而旧实现 grep -v '::1' 恰恰在这种地址上误杀（实测把 [2001:db8::1]:443、[fe80::1]:22 一起丢掉）。
# 用法: pwsh -File build/test-loopback.ps1   （需免密 SSH；不可用时 exit=2 表示未执行）
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hostAlias = 'Linux_3090'

# 单层 base64：只把 collector.sh 传上去，真值表用普通命令串下发。
# （之前套两层 base64 + 管道给 bash 的写法会让远端静默无输出，排查成本很高）
$table = @'
set -u
if ! bash -n "$PANEL_COL"; then echo SYNTAX=FAIL; exit 1; fi
echo SYNTAX=ok
PANEL_LIB=1 . "$PANEL_COL"
declare -F is_loopback >/dev/null || { echo MISSING_FUNC=1; exit 1; }
p=0; f=0
while IFS='|' read -r addr want; do
  [ -z "$addr" ] && continue
  if is_loopback "$addr"; then got=Y; else got=N; fi
  if [ "$got" = "$want" ]; then p=$((p+1)); else f=$((f+1)); echo "BAD $addr want=$want got=$got"; fi
done <<'EOF'
127.0.0.1:5555|Y
127.3.2.1:1|Y
[::1]:8080|Y
::1|Y
localhost:1234|Y
[2001:db8::1]:443|N
[2001:db8::11]:443|N
[fe80::1]:22|N
[::]:22|N
10.0.0.5:993|N
10.0.0.3:22|N
EOF
echo "RES=$p/$((p+f))"
[ "$f" -eq 0 ] || exit 1
exit 0
'@

function Remote([string]$script) {
  $b = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($script -replace "`r`n", "`n")))
  $out = & ssh -o BatchMode=yes -o ConnectTimeout=6 $hostAlias "echo $b | base64 -d | bash" 2>&1
  return @{ rc = $LASTEXITCODE; text = (($out | Out-String)) }
}

$ping = Remote 'command -v bash jq >/dev/null && echo LBOK || echo LBNODOC'
if ($ping.rc -ne 0 -or $ping.text -notmatch 'LBOK') { 'BLOCKED 远端不可达或缺 bash/jq，is_loopback 单测未执行'; exit 2 }

$coll = ([IO.File]::ReadAllText((Join-Path $root 'collector.sh'), [Text.UTF8Encoding]::new($false))) -replace "`r`n", "`n" -replace "`r", "`n"
$b64c = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($coll))

# 把真值表脚本本身也 base64 下发改为：直接拼成一条 bash -c 命令，避免管道套管道
$tblB64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($table -replace "`r`n", "`n")))
$r = Remote "printf '%s' '$b64c' | base64 -d > /tmp/sp_lbc.sh; printf '%s' '$tblB64' | base64 -d > /tmp/sp_lbt.sh; PANEL_COL=/tmp/sp_lbc.sh bash /tmp/sp_lbt.sh; echo DONE_RC=`$?; rm -f /tmp/sp_lbc.sh /tmp/sp_lbt.sh"
$t = '' + $r.text

$fail = 0
if ($t -match 'DONE_RC=(\d+)') { if ([int]$matches[1] -eq 0) { 'PASS  远端执行完成' } else { $fail++; "FAIL  远端执行 rc=$($matches[1])" } } else { $fail++; 'FAIL  远端无有效输出' }
if ($t -match 'SYNTAX=ok') { 'PASS  collector.sh 通过 bash -n' } else { $fail++; 'FAIL  collector.sh 语法不通' }
if ($t -match 'MISSING_FUNC=1') { $fail++; 'FAIL  找不到 is_loopback（PANEL_LIB 接缝失效）' }
if ($t -match 'RES=(\d+)/(\d+)') {
  $ok = [int]$matches[1]; $all = [int]$matches[2]
  if ($ok -eq $all -and $all -ge 10) { "PASS  is_loopback 真值表 $ok/$all 全对" }
  else { $fail++; "FAIL  is_loopback 真值表 $ok/$all"; ($t -split "`n" | Where-Object { $_ -match '^BAD ' } | ForEach-Object { '      ' + $_.Trim() }) }
} else { $fail++; 'FAIL  未取得真值表结果'; $t }
"=== test-loopback: " + $(if ($fail -eq 0) { 'PASS' } else { "FAIL=$fail" }) + " ==="
exit $fail
