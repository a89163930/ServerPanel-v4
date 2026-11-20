# 把 /api/forensics 的处理逻辑原样搬出来跑，暴露真实异常
$Root = 'K:\Opensquilla\ServerPanel-v4'
$ts = [double](Get-Content (Join-Path $Root 'history\2026-11-13.jsonl') -TotalCount 1 -Encoding UTF8 | ForEach-Object { ($_ | ConvertFrom-Json).t })
"ts = $ts  type=$($ts.GetType().Name)"
$day = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts).LocalDate
"fdate = $($day.ToString('yyyy-MM-dd'))"
$f = Join-Path $Root ("history\{0}.jsonl" -f $day.ToString('yyyy-MM-dd'))
"file = $f  exists=$(Test-Path -LiteralPath $f)"

$rx = [regex]'"t":(\d+)'
$best = $null; $bd = [double]::MaxValue; $scanned = 0
try {
  $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
  $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false))
  try {
    while ($null -ne ($l = $sr.ReadLine())) {
      if (-not $l -or $l[0] -ne '{') { continue }
      $scanned++
      $m = $rx.Match($l); if (-not $m.Success) { continue }
      $d = [math]::Abs([double]$m.Groups[1].Value - $ts)
      if ($d -lt $bd) { $bd = $d; $best = $l }
    }
  } finally { $sr.Dispose(); $fs.Dispose() }
} catch { "SCAN THREW: $($_.Exception.GetType().FullName) :: $($_.Exception.Message)"; exit 1 }
"scanned=$scanned bestDelta=$bd bestLen=$($best.Length)"
try { $bo = $best | ConvertFrom-Json; 'ConvertFrom-Json OK' } catch { "JSON THREW: $($_.Exception.Message)"; exit 1 }
try {
  $bo | Add-Member -Force -NotePropertyMembers @{ ok = $true; matched = $true; deltaSec = [int]$bd; scanned = $scanned }
  'Add-Member OK'
} catch { "ADD MEMBER THREW: $($_.Exception.GetType().FullName) :: $($_.Exception.Message)" }
try { $j = $bo | ConvertTo-Json -Compress -Depth 8; "Serialize OK len=$($j.Length)"; $j.Substring(0, 200) } catch { "SERIALIZE THREW: $($_.Exception.GetType().FullName) :: $($_.Exception.Message)" }
