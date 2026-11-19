# 语法/编码自检：PS7 解析器检查所有 .ps1，UTF8 读取检查 .json，远端 bash -n 检查 collector.sh
$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot\..
$fail = 0

foreach ($f in (Get-ChildItem -Filter '*.ps1')) {
  $tok = $null; $err = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err) | Out-Null
  if ($err.Count) { $fail++; "FAIL ps1  $($f.Name)"; $err | ForEach-Object { "      L$($_.Extent.StartLineNumber): $($_.Message)" } }
  else { "OK   ps1  $($f.Name)" }
}

foreach ($f in (Get-ChildItem -Filter '*.json')) {
  try {
    $o = [IO.File]::ReadAllText($f.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    "OK   json  $($f.Name)  (hosts=$(@($o.hosts).Count) alerts=$(@($o.alerts).Count))"
  } catch { $fail++; "FAIL json  $($f.Name) : $($_.Exception.Message)" }
}

# collector.sh: 无 BOM + LF + 远端 bash -n
$cp = Join-Path (Get-Location) 'collector.sh'
$bytes = [IO.File]::ReadAllBytes($cp)
$bom = ($bytes.Length -gt 2 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$crlf = ([regex]::Matches([Text.Encoding]::ASCII.GetString($bytes), "`r`n")).Count
if ($bom -or $crlf) { $fail++; "FAIL sh   collector.sh  BOM=$bom CRLF=$crlf" } else { "OK   sh    collector.sh  (UTF-8 无 BOM, LF)" }

$raw = [IO.File]::ReadAllText($cp) -replace "`r`n", "`n"
$b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($raw))
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = 'ssh'
$psi.Arguments = "-o BatchMode=yes -o ConnectTimeout=8 YOUR_HOST_ALIAS ""echo $b64 | base64 -d | bash -n"""
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$p = [Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.ReadToEnd(); $se = $p.StandardError.ReadToEnd(); $p.WaitForExit()
if ($p.ExitCode -eq 0) { "OK   sh    collector.sh  远端 bash -n 通过" }
else { $fail++; "FAIL sh    远端 bash -n :"; ($so + $se) -split "`n" | ForEach-Object { "      $_" } }

"`n== 结果: $(if ($fail) { "$fail 项失败" } else { '全部通过' }) =="
exit $fail
