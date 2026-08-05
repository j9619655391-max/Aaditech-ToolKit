@echo off
title IT Toolkit - Master Menu
:menu
cls
echo =================================================
echo               IT TOOLKIT - MASTER MENU
echo =================================================
rem Load configuration
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "Get-Content -Raw -Path \"%~dp0Config\config.json\" | ConvertFrom-Json | Select-Object -ExpandProperty paths.logs"`) do set "CONFIG_LOGS_PATH=%%A"
echo  1. QuickCheck (system info, disk, services, etc.)
echo  2. Network Diagnostic (step-by-step)
echo  3. Printer Fix (restart spooler, clear queue)  [Admin]
echo  4. Export Event Logs (for ticket attachments)
echo  5. Pin Common Folders to Quick Access
echo  6. Generate RDP Shortcuts
echo  7. User Inventory Report
echo  8. Firewall Status & Connectivity Test
echo  9. Open Knowledge Base (Excel)
echo 10. Open Ticket Reply Templates
echo 11. Open CMD Commands Reference
echo 12. Open AI Assistant Prompts
echo 13. Open Cheat Sheet
echo 14. Open Troubleshooting Flowcharts
echo 15. Remote QuickCheck
echo 16. Batch Remote Scan
echo 17. Remote Network Diagnostic

if "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\QuickCheck.ps1"
if "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Network-Diagnostic.ps1"
if "%choice%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Scripts\Printer-Fix.ps1\"'"
if "%choice%"=="4" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Export-EventLogs.ps1"
if "%choice%"=="5" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Pin-QuickAccess-Folders.ps1"
if "%choice%"=="6" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remote-Tools\Generate-RDP-Shortcuts.ps1"
if "%choice%"=="7" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\User-Inventory.ps1"
if "%choice%"=="8" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Firewall-Test.ps1"
if "%choice%"=="9" start "" "%~dp0Templates\Knowledge-Base.xlsx"
if "%choice%"=="10" start "" "%~dp0Templates\Ticket-Reply-Templates.txt"
if "%choice%"=="11" start "" "%~dp0Templates\CMD-Commands-Reference.txt"
if "%choice%"=="12" start "" "%~dp0Templates\AI-Assistant-Prompts.txt"
if "%choice%"=="13" start "" "%~dp0Documentation\Cheat-Sheet.md"
if "%choice%"=="14" start "" "%~dp0Documentation\Troubleshooting-Flowcharts.md"
if "%choice%"=="15" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\Invoke-RemoteQuickCheck.ps1"
if "%choice%"=="16" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\BatchScan.ps1"
if "%choice%"=="17" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\Invoke-RemoteNetworkDiagnostic.ps1"
if "%choice%"=="0" exit
if "%choice%"=="0" exit

goto menu
