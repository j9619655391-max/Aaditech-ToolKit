@echo off
title IT Toolkit - Master Menu
setlocal enabledelayedexpansion
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
echo  0. Exit
echo =================================================
set "choice="
set /p choice="Select an option (0-17): "

if "%choice%"=="0" goto end
if "%choice%"=="1" goto run_quickcheck
if "%choice%"=="2" goto run_network
if "%choice%"=="3" goto run_printer
if "%choice%"=="4" goto run_eventlogs
if "%choice%"=="5" goto run_pinquickaccess
if "%choice%"=="6" goto run_rdpshortcuts
if "%choice%"=="7" goto run_userinventory
if "%choice%"=="8" goto run_firewalltest
if "%choice%"=="9" goto open_knowledgebase
if "%choice%"=="10" goto open_ticketreplies
if "%choice%"=="11" goto open_cmdreference
if "%choice%"=="12" goto open_aiprompts
if "%choice%"=="13" goto open_cheatsheet
if "%choice%"=="14" goto open_flowcharts
if "%choice%"=="15" goto run_remotequickcheck
if "%choice%"=="16" goto run_batchscan
if "%choice%"=="17" goto run_remotenetwork
goto invalid

:run_quickcheck
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\QuickCheck.ps1"
goto menu

:run_network
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Network-Diagnostic.ps1"
goto menu

:run_printer
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Scripts\Printer-Fix.ps1\"'"
goto menu

:run_eventlogs
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Export-EventLogs.ps1"
goto menu

:run_pinquickaccess
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Pin-QuickAccess-Folders.ps1"
goto menu

:run_rdpshortcuts
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remote-Tools\Generate-RDP-Shortcuts.ps1"
goto menu

:run_userinventory
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\User-Inventory.ps1"
goto menu

:run_firewalltest
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Firewall-Test.ps1"
goto menu

:open_knowledgebase
start "" "%~dp0Templates\Knowledge-Base.xlsx"
goto menu

:open_ticketreplies
start "" "%~dp0Templates\Ticket-Reply-Templates.txt"
goto menu

:open_cmdreference
start "" "%~dp0Templates\CMD-Commands-Reference.txt"
goto menu

:open_aiprompts
start "" "%~dp0Templates\AI-Assistant-Prompts.txt"
goto menu

:open_cheatsheet
start "" "%~dp0Documentation\Cheat-Sheet.md"
goto menu

:open_flowcharts
start "" "%~dp0Documentation\Troubleshooting-Flowcharts.md"
goto menu

:run_remotequickcheck
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\Invoke-RemoteQuickCheck.ps1"
goto menu

:run_batchscan
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\BatchScan.ps1"
goto menu

:run_remotenetwork
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Remote\Invoke-RemoteNetworkDiagnostic.ps1"
goto menu

:invalid
echo.
echo Invalid option: "%choice%"
echo Please enter a number between 0 and 17.
echo.
pause
goto menu

:end
echo.
echo Goodbye!
exit /b 0
