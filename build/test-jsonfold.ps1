# Format-CompactJson 单测：从 panel.ps1 抠出纯函数本体执行，逐条断言「语义绝不改变」。
# 折叠器写坏会污染人手维护的 config.json（它同时是运行时唯一配置源），所以每条用例都做双向解析比对。
# 用法: pwsh -File build/test-jsonfold.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = [IO.File]::ReadAllText((Join-Path $root 'panel.ps1'), [Text.UTF8Encoding]::new($false))
$m = [regex]::Match($src, '(?ms)^function Format-CompactJson.*?^\}\s*$')
if (-not $m.Success) { 'FAIL  从 panel.ps1 抠不到 Format-CompactJson'; exit 1 }
Invoke-Expression $m.Value

$pass = 0; $fail = 0
function SameJson([string]$a, [string]$b) {
  ($a | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress) -eq ($b | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress)
}
# 结构粒度断言：语义不变 + 幂等 + 必须出现/不得出现的行
function TX($name, [string]$input_, [string[]]$mustHave, [string[]]$mustNotHave) {
  $out = Format-CompactJson $input_
  if (-not (SameJson $input_ $out)) { $script:fail++; "FAIL  $name  语义被改写"; return }
  if ((Format-CompactJson $out) -ne $out) { $script:fail++; "FAIL  $name  非幂等"; return }
  $ls = @($out -split "`r?`n")
  # 序数包含判断：待测文本全是 [ ] { } 这类字符，-like 会把它们当通配符字符类
  foreach ($m in @($mustHave)) {
    if ($null -eq ($ls | Where-Object { $_.Contains($m) } | Select-Object -First 1)) {
      $script:fail++; "FAIL  $name  缺少预期行 [$m]"; "      out: " + ($ls -join ' | '); return
    }
  }
  foreach ($n in @($mustNotHave)) {
    if ($null -ne ($ls | Where-Object { $_.Contains($n) } | Select-Object -First 1)) {
      $script:fail++; "FAIL  $name  出现禁止行 [$n]"; return
    }
  }
  $script:pass++; "PASS  $name"
}
function T($name, [string]$input_, [bool]$expectFolded = $true) {
  $out = Format-CompactJson $input_
  # 语义必须完全一致（最关键断言，任何情况下不许破）
  $semOk = try { SameJson $input_ $out } catch { $false }
  if (-not $semOk) { $script:fail++; "FAIL  $name  语义被改写"; "      in : $($input_ -replace "`r?`n", ' ')"; "      out: $($out -replace "`r?`n", ' ')"; return }
  $oneLineCount = @($out -split "`r?`n").Count
  $inLineCount = @($input_ -split "`r?`n").Count
  $didFold = $oneLineCount -lt $inLineCount
  if ($didFold -ne $expectFolded) {
    $script:fail++; "FAIL  $name  折叠判定不符预期 (期望折=$expectFolded 实际=$didFold, 行数 $inLineCount->$oneLineCount)"; return
  }
  # 幂等：配置会被反复保存，fold 必须是自身不动点
  $out2 = Format-CompactJson $out
  if ($out2 -ne $out) { $script:fail++; "FAIL  $name  非幂等(二次折叠结果变了)"; return }
  $script:pass++; "PASS  $name  行数 $inLineCount->$oneLineCount"
}

'--- 1. 基本标量数组 ---'
T '字符串数组折成一行' ('{' + "`n" + '  "sshOpts": [' + "`n" + '    "-o",' + "`n" + '    "BatchMode=yes"' + "`n" + '  ]' + "`n" + '}')
T '数字/布尔/null 混合' ('{' + "`n" + '  "pids": [' + "`n" + '    1,' + "`n" + '    2,' + "`n" + '    true,' + "`n" + '    null' + "`n" + '  ]' + "`n" + '}')

'--- 2. 危险字符串：不能被内容带偏 ---'
T '元素内含右括号与逗号' ('{' + "`n" + '  "cmd": [' + "`n" + '    "u81:2-rtw_tx_wq]",' + "`n" + '    "a,b"' + "`n" + '  ]' + "`n" + '}')
T '元素内含转义引号' ('{' + "`n" + '  "cmd": [' + "`n" + '    "say \"hi\"",' + "`n" + '    "ok"' + "`n" + '  ]' + "`n" + '}')
T '元素内含花括号与中括号' ('{' + "`n" + '  "t": [' + "`n" + '    "{value}% 剩 [2] 个",' + "`n" + '    "b"' + "`n" + '  ]' + "`n" + '}')
T '元素内含反斜杠路径' ('{' + "`n" + '  "p": [' + "`n" + '    "C:\\a\\b",' + "`n" + '    "d"' + "`n" + '  ]' + "`n" + '}')

'--- 3. 不许误折的结构(断言到具体粒度: 外层必须保持展开, 内层纯标量可以折) ---'
$inObj = '{' + "`n" + '  "hosts": [' + "`n" + '    {' + "`n" + '      "id": "a",' + "`n" + '      "label": "A"' + "`n" + '    }' + "`n" + '  ]' + "`n" + '}'
TX '含对象成员: 外层不折/内层可折' $inObj @('  "hosts": [', '{ "id": "a", "label": "A" }') @('{"id"')
$inArr = '{' + "`n" + '  "m": [' + "`n" + '    [' + "`n" + '      1,' + "`n" + '      2' + "`n" + '    ],' + "`n" + '    [3]' + "`n" + '  ]' + "`n" + '}'
TX '嵌套数组: 外层不折/内层可折' $inArr @('  "m": [', '[1, 2]') @('[1,2]')

'--- 4. 超长不折(可读性优先) ---'
$long = 'x' * 300
T '超长成员保持展开' ('{' + "`n" + '  "s": {' + "`n" + '    "startCmd": "' + $long + '",' + "`n" + '    "id": "z"' + "`n" + '  }' + "`n" + '}') $false

'--- 5. 真实 config.json 全量往返 ---'
$cfgPath = Join-Path $root 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
  $cfg = [IO.File]::ReadAllText($cfgPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  $expanded = $cfg | ConvertTo-Json -Depth 12
  $folded = Format-CompactJson $expanded
  if (-not (SameJson $expanded $folded)) { $fail++; 'FAIL  真实配置语义被改写' }
  else {
    $le = @($expanded -split "`r?`n").Count; $lf = @($folded -split "`r?`n").Count
    if ($lf -ge $le) { $fail++; "FAIL  真实配置没有变短 $le -> $lf" }
    elseif ((Format-CompactJson $folded) -ne $folded) { $fail++ ; 'FAIL  真实配置非幂等' }
    else { $pass++; "PASS  真实 config.json 往返 $le -> $lf 行(语义不变且幂等)" }
    "      sshOpts 行: " + ((($folded -split "`r?`n") | Where-Object { $_ -match 'sshOpts' } | Select-Object -First 1) -replace '^\s*', '')
    "      pids 行:   " + ((($folded -split "`r?`n") | Where-Object { $_ -match '"pids"' } | Select-Object -First 1) -replace '^\s*', '')
  }
} else { 'SKIP  无 config.json' }

"`n=== test-jsonfold: PASS=$pass FAIL=$fail ==="
exit $fail
