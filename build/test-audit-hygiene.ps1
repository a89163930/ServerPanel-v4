# 审计卫生门（DR-52）：自动化脚本打给 /api/action 的请求必须带 tag='e2e'。
# 为什么需要静态检查：tag 靠每个脚本自觉添加，新增/修改测试时很容易忘——
# verify-p0 就连打过 20 次 kill 而漏标，把用户真实操作顶出了「末 80 条」默认可见窗口。
# 静态检查不需要跑面板，漏标立刻在此处失败。
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pass = 0; $fail = 0
function OK($n, $d = '') { $script:pass++; "  PASS  $n  $d" }
function NO($n, $d = '') { $script:fail++; "  FAIL  $n  $d" }

'--- 1. 扫描 build/*.ps1 里的 /api/action POST ---'
$files = Get-ChildItem (Join-Path $root 'build') -Filter '*.ps1' -File
$checked = 0; $missed = @()
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName, [Text.UTF8Encoding]::new($false))
  # 只看写动作的行；GET 轮询(?id=) 不算
  foreach ($line in ($text -split "`r?`n")) {
    if ($line -match '/api/action' -and $line -match '-Method\s+Post' -and $line -notmatch '\?id=') {
      $checked++
      # tag 可能在同行字面量里，也可能由 helper 注入（ConvertTo-Json 的变量在该函数内补 tag）
      $hasTagInline = $line -match "tag\s*="
      if (-not $hasTagInline) { $missed += , @($f.Name, $line.Trim()) }
    }
  }
}
if ($checked -eq 0) { NO '没有扫到任何动作 POST（检查失效）' } else { OK '扫到动作 POST' "$checked 处" }

# 允许通过 helper 集中打标：把「函数内注入 tag」也算合格
$bad = @()
foreach ($m in $missed) {
  $file = $m[0]; $line = $m[1]
  $text = [IO.File]::ReadAllText((Join-Path $root "build\$file"), [Text.UTF8Encoding]::new($false))
  # 若该行把 body 交给一个变量（如 $o / $bodyObj），检查同文件是否存在 "$[..] = 'e2e'" 或 tag 注入
  $varBody = $line -match '-Body\s+\(\$?(\w+)'
  if ($varBody) {
    $var = $matches[1]
    if ($text -match ("$([regex]::Escape($var))\s*(\[['`"]tag['`"]]\s*=|\.tag\s*=)\s*'e2e'")) { continue }
  }
  $bad += , $m
}
if ($bad.Count -eq 0) { OK '所有动作 POST 都已打 tag' "含 helper 集中注入" }
else { foreach ($b in $bad) { NO "漏标 tag: $($b[0])" ($b[1].Substring(0, [Math]::Min(110, $b[1].Length))) } }

'--- 2. 服务端契约：默认视图不得出现带 tag 的记录 ---'
try {
  $boot = Invoke-RestMethod 'http://127.0.0.1:48732/api/boot' -TimeoutSec 5
  $h = @{ 'X-Panel-Token' = [string]$boot.token }
  $d = Invoke-RestMethod 'http://127.0.0.1:48732/api/audit' -Headers $h -TimeoutSec 8
  $leak = @($d.events | Where-Object { '' + $_.tag })
  if ($leak.Count -eq 0) { OK '默认视图无 tag 泄漏' "events=$(@($d.events).Count) hiddenTest=$($d.hiddenTest)" }
  else { NO '默认视图泄漏 tag 记录' "leak=$($leak.Count)" }
  if ($null -ne $d.PSObject.Properties['all'] -and $d.all -eq $false) { OK '响应标明当前为非 all 视图' } else { NO '响应缺少 all 标记' }
  $a = Invoke-RestMethod 'http://127.0.0.1:48732/api/audit?all=1' -Headers $h -TimeoutSec 8
  if (@($a.events).Count -ge @($d.events).Count) { OK '?all=1 条数不少于默认视图' "all=$(@($a.events).Count) default=$(@($d.events).Count)" }
  else { NO '?all=1 反而更少' }
} catch {
  '  SKIP  服务端契约检查未执行：面板不可达 (' + $_.Exception.Message + ')'
  '  静态 tag 检查仍已生效; 面板起来后重跑本脚本才能覆盖服务端契约'
  "`n=== test-audit-hygiene: PASS=$pass FAIL=$fail SKIP=panel-down ==="
  if ($fail -gt 0) { exit 1 }
  exit 2   # 2 = 部分未执行(环境缺失), 既不算通过也不算代码失败
}

"`n=== test-audit-hygiene: PASS=$pass FAIL=$fail ==="
exit $fail
