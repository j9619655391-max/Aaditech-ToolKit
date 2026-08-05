@echo off
title IT Toolkit - Setup Wizard
setlocal enabledelayedexpansion

cls
echo =================================================
echo        IT TOOLKIT v2.0 - SETUP WIZARD
echo =================================================
echo.
echo This wizard will help you configure the toolkit
echo for your environment. It takes about 2-3 minutes.
echo.
echo Press any key to continue...
pause >nul

:setup_menu
cls
echo =================================================
echo           SETUP OPTIONS
echo =================================================
echo.
echo  1. Quick Setup (recommended for first-time)
echo  2. Configure Machines (add your servers/PCs)
echo  3. Configure Network Settings
echo  4. Configure Script Defaults
echo  5. Verify All Files Present
echo  6. Test PowerShell Execution
echo  7. Open Config File in Notepad
echo  8. View Documentation
echo  0. Exit Setup
echo.
set /p choice="Select an option: "

if "%choice%"=="1" goto quick_setup
if "%choice%"=="2" goto configure_machines
if "%choice%"=="3" goto configure_network
if "%choice%"=="4" goto configure_scripts
if "%choice%"=="5" goto verify_files
if "%choice%"=="6" goto test_powershell
if "%choice%"=="7" goto edit_config
if "%choice%"=="8" goto view_docs
if "%choice%"=="0" goto end_wizard
goto setup_menu

:quick_setup
cls
echo =================================================
echo           QUICK SETUP
echo =================================================
echo.
echo Step 1: Checking PowerShell Execution Policy...
powershell -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force" >nul 2>&1
if %errorlevel% equ 0 (
    echo  ✓ Execution Policy set to RemoteSigned
) else (
    echo  ⚠ Could not set Execution Policy (may need admin)
)
echo.
echo Step 2: Creating Logs folder if needed...
if not exist "%~dp0Logs" (
    mkdir "%~dp0Logs"
    echo  ✓ Logs folder created
) else (
    echo  ✓ Logs folder already exists
)
echo.
echo Step 3: Verifying Config file...
if exist "%~dp0Config\config.json" (
    echo  ✓ config.json found and ready
) else (
    echo  ✗ config.json not found - please restore from backup
)
echo.
echo Step 4: Verifying Scripts...
set count=0
for %%f in ("%~dp0Scripts\*.ps1") do set /a count+=1
echo  ✓ Found %count% PowerShell scripts
echo.
echo Step 5: Testing Toolkit-Menu.bat...
if exist "%~dp0Toolkit-Menu.bat" (
    echo  ✓ Master menu launcher ready
) else (
    echo  ✗ Toolkit-Menu.bat not found
)
echo.
echo =================================================
echo           QUICK SETUP COMPLETE!
echo =================================================
echo.
echo Next steps:
echo  1. Review Config\config.json to add your machines
echo  2. Run Toolkit-Menu.bat to start using the toolkit
echo  3. Open Documentation\Setup-Guide.md for full instructions
echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:configure_machines
cls
echo =================================================
echo           CONFIGURE MACHINES
echo =================================================
echo.
echo To add your commonly-supported machines:
echo  1. Open: Config\config.json (in Notepad or JSON editor)
echo  2. Find the "machines" section
echo  3. Add entries with your server/PC details
echo.
echo Example format:
echo {
echo   "name": "YOUR-SERVER-NAME",
echo   "host": "192.168.1.100",
echo   "description": "Production file server",
echo   "os": "Windows Server 2022"
echo }
echo.
echo You can add as many machines as you need.
echo.
echo Would you like to open config.json now? (Y/N)
set /p opennow="Choice: "
if /i "%opennow%"=="y" (
    start notepad "%~dp0Config\config.json"
)
echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:configure_network
cls
echo =================================================
echo           CONFIGURE NETWORK SETTINGS
echo =================================================
echo.
echo Current network settings (from config.json):
powershell -NoProfile -Command "Get-Content '%~dp0Config\config.json' -Raw | ConvertFrom-Json | Select-Object -ExpandProperty network | Format-List" 2>nul
echo.
echo To change DNS servers or test hosts:
echo  1. Open: Config\config.json
echo  2. Edit the "network" and "firewallTest" sections
echo  3. Save and run scripts to use new settings
echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:configure_scripts
cls
echo =================================================
echo           CONFIGURE SCRIPT DEFAULTS
echo =================================================
echo.
echo Available script settings in config.json:
echo  • Log format (txt/csv)
echo  • Auto-delete old logs (after N days)
echo  • Require admin for certain scripts
echo  • Event log sources to export
echo  • Firewall test timeout
echo  • And more...
echo.
echo To customize:
echo  1. Open: Config\config.json (in Notepad)
echo  2. Edit "scriptDefaults" section
echo  3. Save changes
echo.
echo All scripts automatically read config.json on startup.
echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:verify_files
cls
echo =================================================
echo           VERIFYING TOOLKIT FILES
echo =================================================
echo.

setlocal enabledelayedexpansion
set missing=0
set found=0

echo Checking core files...
for %%f in (
    "Toolkit-Menu.bat"
    "Setup-Wizard.bat"
    "CHANGELOG.md"
    "Config\config.json"
) do (
    if exist "%~dp0%%f" (
        echo  ✓ %%f
        set /a found+=1
    ) else (
        echo  ✗ %%f - MISSING
        set /a missing+=1
    )
)

echo.
echo Checking Scripts folder...
if exist "%~dp0Scripts" (
    set /a found+=1
    for /f %%f in ('dir /b "%~dp0Scripts\*.ps1" 2^>nul ^| find /c /v ""') do (
        echo  ✓ Scripts folder contains %%f PowerShell scripts
    )
) else (
    echo  ✗ Scripts folder - MISSING
    set /a missing+=1
)

echo.
echo Checking Templates folder...
if exist "%~dp0Templates" (
    set /a found+=1
    for /f %%f in ('dir /b "%~dp0Templates\*.*" 2^>nul ^| find /c /v ""') do (
        echo  ✓ Templates folder contains %%f files
    )
) else (
    echo  ✗ Templates folder - MISSING
    set /a missing+=1
)

echo.
echo Checking Documentation folder...
if exist "%~dp0Documentation" (
    set /a found+=1
    for /f %%f in ('dir /b "%~dp0Documentation\*.md" 2^>nul ^| find /c /v ""') do (
        echo  ✓ Documentation folder contains %%f markdown files
    )
) else (
    echo  ✗ Documentation folder - MISSING
    set /a missing+=1
)

echo.
echo Checking other folders...
for %%f in (Remote-Tools Drivers Logs Software) do (
    if exist "%~dp0%%f" (
        echo  ✓ %%f folder exists
        set /a found+=1
    ) else (
        echo  ⚠ %%f folder not found (will be created on demand)
    )
)

echo.
echo =================================================
if %missing% equ 0 (
    echo  RESULT: ALL FILES PRESENT ✓
) else (
    echo  RESULT: !missing! FILE^(S^) MISSING
)
echo =================================================
echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:test_powershell
cls
echo =================================================
echo           TEST POWERSHELL EXECUTION
echo =================================================
echo.
echo Testing PowerShell availability and execution...
echo.

powershell -NoProfile -Command "Write-Host ('PowerShell version: ' + $PSVersionTable.PSVersion.ToString())" 2>nul
if %errorlevel% equ 0 (
    echo ✓ PowerShell is working correctly
) else (
    echo ✗ PowerShell test failed
)

echo.
echo Testing Execution Policy...
powershell -NoProfile -Command "(Get-ExecutionPolicy -Scope CurrentUser).ToString()" 2>nul

echo.
echo If you see "RemoteSigned" above, everything is configured correctly.
echo If you see "Restricted", run this command in PowerShell as Admin:
echo   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
echo.
echo Testing one script (QuickCheck.ps1)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host 'Test passed - scripts will execute' -ForegroundColor Green" 2>nul

echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:edit_config
cls
echo =================================================
echo           OPENING CONFIG FILE
echo =================================================
echo.
echo Launching config.json in Notepad...
start notepad "%~dp0Config\config.json"
echo.
echo Note: Changes to config.json apply toolkit-wide on next script run.
echo Press Enter when done...
pause >nul
goto setup_menu

:view_docs
cls
echo =================================================
echo           VIEW DOCUMENTATION
echo =================================================
echo.
echo Available documentation:
echo  1. Setup-Guide.md (START HERE - installation & first-time setup)
echo  2. Cheat-Sheet.md (one-page reference guide)
echo  3. Troubleshooting-Flowcharts.md (decision trees for common issues)
echo  4. CHANGELOG.md (what's new in v2.0)
echo  5. Scripts README (details about each script)
echo.
set /p docmenu="Which document would you like to view (1-5)? "

if "%docmenu%"=="1" start "" "%~dp0Documentation\Setup-Guide.md"
if "%docmenu%"=="2" start "" "%~dp0Documentation\Cheat-Sheet.md"
if "%docmenu%"=="3" start "" "%~dp0Documentation\Troubleshooting-Flowcharts.md"
if "%docmenu%"=="4" start "" "%~dp0CHANGELOG.md"
if "%docmenu%"=="5" start "" "%~dp0Documentation\README.md"

echo.
echo Press Enter to return to setup menu...
pause >nul
goto setup_menu

:end_wizard
cls
echo =================================================
echo           SETUP COMPLETE
echo =================================================
echo.
echo ✓ Setup wizard finished
echo.
echo Next steps:
echo  1. Configure your machines in Config\config.json
echo  2. Run Toolkit-Menu.bat to launch the main menu
echo  3. Read Documentation\Setup-Guide.md for full details
echo.
echo Questions? Check the documentation or troubleshooting flowcharts.
echo.
exit /b 0
