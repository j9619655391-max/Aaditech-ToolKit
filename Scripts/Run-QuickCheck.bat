@echo off
REM Double-click this file to launch the QuickCheck menu.
REM No admin rights required for most checks (a few repair options will prompt if needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0QuickCheck.ps1"
pause
