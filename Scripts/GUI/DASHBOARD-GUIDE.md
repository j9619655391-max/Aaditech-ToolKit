# DASHBOARD GUIDE

The IT Toolkit dashboard (Phase 3) is a **graphical launcher** for the toolkit,
available on Windows.

## Requirements

- Windows 10/11 or Windows Server 2016+ (PowerShell 5.1 or pwsh)
- Interactive desktop session

## Launch

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\GUI\Toolkit-GUI.ps1
# or, when using PowerShell 7:
pwsh -NoProfile -File .\Scripts\GUI\Toolkit-GUI.ps1
```

> The script guards on platform/session: on non-Windows it prints a message and
> exits 2. The parsing is still validated by CI on every commit.

## Features

| Button | Action |
|--------|--------|
| 1. QuickCheck | Runs `Scripts/QuickCheck.ps1` in a new console |
| 2. Network Diagnostic | Runs `Scripts/Network-Diagnostic.ps1` |
| 3. Printer Fix | Elevated launch of `Scripts/Printer-Fix.ps1` |
| 4. Export Event Logs | Runs `Scripts/Export-EventLogs.ps1` |
| 5. User Inventory | Runs `Scripts/User-Inventory.ps1` |
| 6. Firewall Test | Runs `Scripts/Firewall-Test.ps1` |
| 7. Snap inventory | Stores an inventory snapshot into the SQLite data layer (`ToolkitData.psm1`) |
| 8. Open Cheat Sheet | Opens `Documentation/Cheat-Sheet.md` |

## Data-layer button

Button 7 calls `Add-ToolkitInventoryRecord` (from `ToolkitData.psm1`) with OS,
CPU, and RAM from the local machine, writing into `Data/ToolkitData.sqlite3`.
See `Data/DATABASE-GUIDE.md`.

## Manual smoke test (recommended)

On a Windows workstation:

1. Double-click or run the launch command above.
2. Verify the window opens centered with 8 buttons + version footer.
3. Click **1. QuickCheck** — a console window should open and run.
4. Click **7. Snap inventory** — expect an "Inventory snapshot saved" dialog.
5. Confirm a row appears: `sqlite3 Data\ToolkitData.sqlite3 "select * from inventory;"`

## What is tested automatically

- CI parses the script (no syntax errors).
- CI checks the platform guard logic by static analysis.
- The WinForms UI itself requires a Windows interactive session, which CI
  cannot provide; the manual smoke steps above cover that gap.