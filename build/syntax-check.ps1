# 语法门：用 pwsh7 解析器检查核心脚本与全部 build/*.ps1（只解析不执行）。
# 用法: pwsh -File build/syntax-check.ps1 [-Path <单个文件>]
# 必须用 pwsh 7 跑：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按本地 GBK 读，
# 含中文的字符串会误报「表达式或语句中包含意外的标记」——脚本本身没问题。
param([string]$Path = '')
# 说明：哈希字面量的重复键已交给 pwsh7 解析器本身（实测会报「哈希文本中不允许重复的键」，
# 含大小写不敏感与引号键），这里不再叠一层冗余 AST 检查。

# 重复键检测：[ordered]@{ a=1; a=2 } 在解析期不报错，运行期才抛“已添加项”。
# 这类缺陷真实发生过：agent.ps1 的 lastDropAt 被写了两行，agent 起来就崩，
# 靠面板启动退避跑了 10 次才在 meta 里看到痕迹。把它们提前拦在静态门。
function Get-DupHashKeys($ast) {
  $out = @()
  if (-not $ast) { return $out }
  $hts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
  foreach ($h in $hts) {
    $seen = @{}
    foreach ($kvp in $h.KeyValuePairs) {
      $raw = ('' + $kvp.Key.Extent.Text).Trim()
      if ($raw.Length -ge 2 -and ((($raw[0] -eq '"') -and ($raw[-1] -eq '"')) -or (($raw[0] -eq "'") -and ($raw[-1] -eq "'")))) {
        $name = $raw.Substring(1, $raw.Length - 2)
      } else { $name = $raw }
      # 只判常量键；变量键($k = ...) 无法静态定名，跳过
      if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
      $ln = $kvp.Extent.StartLineNumber
      $key = $name.ToLowerInvariant()   # PowerShell 哈希键大小写不敏感
      if ($seen.ContainsKey($key)) { $out += "L$ln 重复键 '$name'（首次出现 L$($seen[$key])）" }
      else { $seen[$key] = $ln }
    }
  }
  return $out
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$targets = if ($Path) { , @([IO.Path]::GetFullPath($Path)) }
else {
  @(
    (Join-Path $root 'panel.ps1'), (Join-Path $root 'agent.ps1'), (Join-Path $root 'action.ps1')
  ) + @(Get-ChildItem (Join-Path $root 'build') -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
}
$bad = 0
foreach ($t in $targets) {
  if (-not (Test-Path -LiteralPath $t)) { "SKIP  $t"; continue }
  if ($PSVersionTable.PSVersion.Major -lt 7) { "FAIL  $t  (必须用 pwsh 7 跑)" ; $bad++; continue }
  $e = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($t, [ref]$null, [ref]$e)
  $rel = $t.Substring($root.Length).TrimStart('\')
  if ($e -and $e.Count) { $bad++; "FAIL  $rel"; $e | ForEach-Object { '        L' + $_.Extent.StartLineNumber + ': ' + $_.Message } }
  else { "OK    $rel" }
}
"--- syntax-check: {0} 个文件, {1} 个错误 (pwsh {2}) ---" -f $targets.Count, $bad, $PSVersionTable.PSVersion
# *.sh 必须是 LF：Windows 侧工具常把 .sh 写成 CRLF，远端 bash 会因 shebang 带 \r 报 bad interpreter。
# 本仓库靠 .gitattributes 保持入库为 LF，但工作副本写坏时 upload/scp 或直接执行仍会炸，故单独把门。
foreach ($sh in @(Get-ChildItem $root -Filter '*.sh' -File -Recurse -ErrorAction SilentlyContinue)) {
  $bytes = [IO.File]::ReadAllBytes($sh.FullName)
  $cr = 0
  for ($k = 1; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 10 -and $bytes[$k - 1] -eq 13) { $cr++ } }
  $rel2 = $sh.FullName.Substring($root.Length).TrimStart('\')
  if ($cr -gt 0) { $bad++; "FAIL  $rel2  含 $cr 处 CRLF —— 跑 pwsh -File build/lf.ps1 修正" }
  else { "OK    $rel2  LF" }
}
exit $bad
