@echo off
REM ===================================================================
REM  FortressOne launcher.
REM  Double-click this file. That is the whole procedure.
REM
REM  It does three things you would otherwise have to type by hand:
REM    1. Clears the "downloaded from the internet" flag Windows puts on
REM       every file in a downloaded ZIP, which otherwise blocks the script.
REM    2. Bypasses the execution policy for this run only. Your system-wide
REM       setting is not changed.
REM    3. Starts FortressOne, which then asks for administrator rights
REM       itself. Click Yes on the prompt.
REM ===================================================================

cd /d "%~dp0"

echo.
echo  Preparing FortressOne...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FortressOne.ps1"

echo.
echo  FortressOne has closed. You can close this window.
echo.
pause
