@echo off
rem ServerPanel v4 launcher. ASCII-only content on purpose: avoids GBK/UTF-8 console mojibake.
setlocal
cd /d "%~dp0"
where pwsh >nul 2>nul
if errorlevel 1 goto nopwsh
start "" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0panel.ps1"
rem Readiness probe hidden: if the panel fails to start it pops a visible log window,
rem instead of the old silent no-op. On success nothing extra is shown.
start "" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0build\launch-probe.ps1"
exit /b 0
:nopwsh
echo [ServerPanel v4] PowerShell 7 pwsh is required.
echo Install with: winget install Microsoft.PowerShell
pause
exit /b 1
