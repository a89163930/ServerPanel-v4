# 把项目里所有 .sh 规范化为 UTF-8 无 BOM + LF（远端 bash 要求）
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Get-ChildItem $root -Recurse -Filter '*.sh' | ForEach-Object {
  $t = [IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n" -replace "`r", "`n"
  [IO.File]::WriteAllText($_.FullName, $t, [Text.UTF8Encoding]::new($false))
  "LF-normalized: $($_.FullName.Substring($root.Length + 1))"
}
