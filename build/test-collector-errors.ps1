# collector.sh 回归：errors[] 必须「每样本独立」，不得随流式周期累积。
# 缺陷原型(R-56)：errs 只在脚本顶层清零一次，流式主循环反复 emit => fail() 累积的字符串
# 永久残留，errors[] 逐周期增长(实测 1,2,3,4,5,6)，把 latest 快照撑大并让界面长期假红。
# 做法：把工作区 collector.sh 上传远端，用一个必定失败的 nvidia-smi 影子跑若干周期，
# 断言每个样本的 errors 条数恒定；再做一次不带影子的干净跑，断言 errors 为空。
# 需要免密 SSH 与远端 jq；不可用时 exit 2（未执行，不算通过）。
$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }
function Send-File([string]$localPath, [string]$remotePath) {
  $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(
    ([IO.File]::ReadAllText($localPath, [Text.UTF8Encoding]::new($false)) -replace "`r`n", "`n")))
  $r = (& ssh -o BatchMode=yes -o ConnectTimeout=8 YOUR_HOST_ALIAS "printf '%s' '$b64' | base64 -d > $remotePath; wc -c < $remotePath") 2>&1 | Out-String
  return ('' + $r).Trim()
}
function Remote($script) {
  $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes(($script -replace "`r`n", "`n")))
  return ((& ssh -o BatchMode=yes -o ConnectTimeout=8 YOUR_HOST_ALIAS "echo $b64 | base64 -d | bash") 2>&1 | Out-String)
}

'--- 0. 远端可用性 ---'
$alive = Remote 'command -v jq >/dev/null && command -v nvidia-smi >/dev/null && echo SP_TOOL_OK || echo SP_TOOL_NO'
if ($alive -notmatch 'SP_TOOL_OK') {
  '  SKIP  远端缺 jq/nvidia-smi 或 SSH 不可达 -> 本门禁未执行'
  "=== test-collector-errors: 未执行(环境不满足) ==="
  exit 2
}
OK '远端可跑 (jq + nvidia-smi 存在)' ('' + $alive).Trim()

$bytes = Send-File (Join-Path $root 'collector.sh') '/tmp/sp_col_test.sh'
if ($bytes -notmatch '^\d+$' -or [int]$bytes -lt 2000) { NO 'collector.sh 上传' "$bytes"; exit 1 }
OK 'collector.sh 上传远端' "$bytes bytes"

'--- 1. 持续失败注入：errors[] 不得随周期累积 ---'
$bad = Remote @'
set -u
TD=$(mktemp -d /tmp/sptool.XXXXXX)
printf '#!/bin/sh\necho "stub: nvidia-smi unavailable" >&2\nexit 9\n' > "$TD/nvidia-smi"
chmod +x "$TD/nvidia-smi"
PATH="$TD:$PATH" bash /tmp/sp_col_test.sh 1 > /tmp/sp_bad.jsonl 2>/dev/null &
P=$!; sleep 6; kill $P 2>/dev/null; wait $P 2>/dev/null
rm -rf "$TD"
n=$(wc -l < /tmp/sp_bad.jsonl | tr -d " ")
echo "SAMPLES=$n"
echo "LENS=$(jq -s "[.[].errors|length]" /tmp/sp_bad.jsonl | tr -d "\n []")"
echo "UNIQ=$(jq -s "[.[].errors|length] | unique | length" /tmp/sp_bad.jsonl | tr -d "\n ")"
echo "MAXLEN=$(jq -s "[.[].errors|length] | max" /tmp/sp_bad.jsonl | tr -d "\n ")"
'@
$bad -split "`r?`n" | Where-Object { $_ -match '^  ' } | ForEach-Object { $_ }
if ($bad -notmatch 'SAMPLES=(\d+)') { NO '失败注入跑未产出样本' ($bad -replace '\s+', ' ') }
else {
  $samples = [int]$matches[1]
  if ($samples -ge 3) { OK '连续失败下产出 >=3 个样本' "n=$samples" } else { NO '样本太少，无法判定累积' "n=$samples" }
  if ($bad -match 'UNIQ=(\d+)') {
    $uniq = [int]$matches[1]
    if ($uniq -eq 1) { OK 'errors 条数逐周期恒定(未累积)' ($bad -replace '(?s).*LENS=', 'LENS=' -replace '(?s)MAXLEN=.*', '' | ForEach-Object { ('' + $_).Trim() }) }
    else { NO 'errors 随周期累积' "unique长度类=$uniq 明细: $(($bad -split "`n" | Where-Object { $_ -match '^LENS=' }))" }
  }
  if ($bad -match 'MAXLEN=(\d+)') {
    $max = [int]$matches[1]
    if ($max -le 2) { OK '单样本 errors 上限受控' "max=$max" } else { NO '单样本 errors 膨胀' "max=$max" }
  }
}

'--- 2. 干净跑：errors[] 应为空 ---'
$clean = Remote @'
bash /tmp/sp_col_test.sh 1 > /tmp/sp_ok.jsonl 2>/dev/null &
P=$!; sleep 4; kill $P 2>/dev/null; wait $P 2>/dev/null
echo "SAMPLES=$(wc -l < /tmp/sp_ok.jsonl | tr -d " ")"
echo "BADLINES=$(grep -cv '^{' /tmp/sp_ok.jsonl || true)"
echo "ERRN=$(jq -s "[.[].errors|length] | max // 0" /tmp/sp_ok.jsonl | tr -d "\n ")"
echo "SCHEMA=$(jq -s '[.[].schema] | unique | join(",")' /tmp/sp_ok.jsonl | tr -d "\n \"""")"
echo "INVARIANT=$(jq -s '[.[] | select(.procTotal < .procCount)] | length' /tmp/sp_ok.jsonl | tr -d "\n ")"
echo "PAIRS=$(jq -s '[.[] | "\(.procTotal)/\(.procCount)"] | unique | join(" ")' /tmp/sp_ok.jsonl | tr -d "\n")"
rm -f /tmp/sp_col_test.sh /tmp/sp_bad.jsonl /tmp/sp_ok.jsonl
'@
if ($clean -match 'ERRN=(\d+)') {
  $e = [int]$matches[1]
  if ($e -eq 0) { OK '健康主机上 errors[] 为空' } else { NO '干净跑仍有 errors' "max=$e" }
} else { NO '干净跑无输出' ($clean -replace '\s+', ' ') }
# procTotal 与 procCount 同源于一次 ps 后，前者永远不得低于后者
if ($clean -match 'INVARIANT=(\d+)') {
  if ([int]$matches[1] -eq 0) { OK 'procTotal >= procCount 恒成立' (($clean -split "`n" | Where-Object { $_ -match '^PAIRS=' }) -join '') }
  else { NO 'procTotal < procCount 出现' "$($matches[1]) 个样本" }
} else { NO '未能判定 procTotal 不变量' (($clean -replace '\s+', ' ').Substring(0, [Math]::Min(160, ('' + $clean).Length))) }
if ($clean -match 'SCHEMA=(\S+)') {
  if ($matches[1] -eq 'sp1') { OK 'schema 仍为 sp1' } else { NO 'schema 变化' $matches[1] }
}

"`n=== test-collector-errors: PASS=$pass FAIL=$fail ==="
exit $fail
