$d = 'C:\path\to\ServerPanel-v4\state\actions'
New-Item -ItemType Directory -Force -Path $d | Out-Null
$p = Join-Path $d 't1.json'
$t = Join-Path $d 't1.json.tmpX'

# 1) File.Replace（当前 action.ps1 用的方案）
[IO.File]::WriteAllText($p, '{"old":1}')
[IO.File]::WriteAllText($t, '{"new":2}')
try { [IO.File]::Replace($t, $p, $null); "1 Replace OK  -> $( [IO.File]::ReadAllText($p) )" }
catch { "1 Replace THREW $($_.Exception.GetType().Name) -> $($_.Exception.Message)"; "  inner: $($_.Exception.InnerException.Message)" }
"  tmp exists after: $(Test-Path $t)"
Remove-Item $p, $t -Force -ErrorAction SilentlyContinue

# 2) File.Move(overwrite)
[IO.File]::WriteAllText($p, '{"old":1}')
[IO.File]::WriteAllText($t, '{"new":2}')
try { [IO.File]::Move($t, $p, $true); "2 File.Move(overwrite) OK -> $( [IO.File]::ReadAllText($p) )" }
catch { "2 File.Move THREW -> $($_.Exception.Message)" }
"  tmp exists after: $(Test-Path $t)"
Remove-Item $p, $t -Force -ErrorAction SilentlyContinue

# 3) Move-Item -Force
[IO.File]::WriteAllText($p, '{"old":1}')
[IO.File]::WriteAllText($t, '{"new":2}')
try { Move-Item -LiteralPath $t -Destination $p -Force; "3 Move-Item -Force OK -> $( [IO.File]::ReadAllText($p) )" }
catch { "3 Move-Item THREW -> $($_.Exception.Message)" }
"  tmp exists after: $(Test-Path $t)"

# 4) 模拟并发读：面板正在 ReadAllBytes 时覆盖
[IO.File]::WriteAllText($p, ('{"x":"' + ('A' * 50000) + '"}'))
$fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')     # 共享读，模拟 HTTP 层
[IO.File]::WriteAllText($t, ('{"y":"' + ('B' * 50000) + '"}'))
try { Move-Item -LiteralPath $t -Destination $p -Force; "4 覆盖进行中的读者: OK" } catch { "4 THREW -> $($_.Exception.Message)" }
$fs.Position = 0
$buf = New-Object byte[] 200
$n = $fs.Read($buf, 0, 200); $fs.Close()
"  读者看到的开头: " + ([Text.Encoding]::UTF8.GetString($buf, 0, $n)).Substring(0, 24)
Remove-Item $p, $t -Force -ErrorAction SilentlyContinue
