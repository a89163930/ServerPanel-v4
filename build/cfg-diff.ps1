# ASCII-only helper: canonical-JSON compare of two config files (used to prove Save-Config is lossless).
param([string]$A = '', [string]$B = '')
function Can([string]$p) {
  $o = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  return ($o | ConvertTo-Json -Depth 30)
}
$a = Can $A; $b = Can $B
if ($a -eq $b) { 'SEMANTIC EQUAL: yes'; exit 0 }
'SEMANTIC EQUAL: NO'
$la = $a -split "`r?`n"; $lb = $b -split "`r?`n"
$max = [Math]::Max($la.Count, $lb.Count)
for ($i = 0; $i -lt $max; $i++) {
  $x = if ($i -lt $la.Count) { $la[$i].Trim() } else { '<none>' }
  $y = if ($i -lt $lb.Count) { $lb[$i].Trim() } else { '<none>' }
  if ($x -ne $y) { "L$($i+1) base=[$x]  now=[$y]" }
}
exit 1
