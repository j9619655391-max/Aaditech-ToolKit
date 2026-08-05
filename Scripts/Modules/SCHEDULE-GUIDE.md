# SCHEDULE GUIDE

Schedule IT Toolkit scripts to run automatically (Phase 3 automation) using the
Windows Task Scheduler via a lightweight PowerShell wrapper module.

## Requirements

- Windows (uses `schtasks.exe`)
- Target script must be runnable non-interactively (no prompts)

## Module functions

`Scripts/Modules/TaskScheduler.psm1`:

| Function | Purpose |
|----------|---------|
| `New-CronExpression` | Builds a cron descriptor string (pure, cross-platform/testable) |
| `Register-ToolkitScheduledTask` | Creates a weekly scheduled task for a script |
| `Get-ToolkitScheduledTask` | Lists tasks (optionally filter by name) |
| `Remove-ToolkitScheduledTask` | Deletes a scheduled task |
| `Get-TaskSchedulerAvailable` | `$true` only on Windows with `schtasks.exe` |

## Example

```powershell
Import-Module .\Scripts\Modules\TaskScheduler.psm1

# Weekly inventory run, Mondays at 7:30am
Register-ToolkitScheduledTask `
    -TaskName 'ITK-Inventory' `
    -ScriptPath 'C:\IT-Toolkit\Scripts\User-Inventory.ps1' `
    -WeeklyDays 'MON' `
    -AtTime '07:30'

# List what is scheduled
Get-ToolkitScheduledTask -Filter 'ITK-'

# Remove
Remove-ToolkitScheduledTask -TaskName 'ITK-Inventory'
```

## Conventions

- Non-interactive scripts only. Scripts that call `Read-Host` will hang when
  scheduled; wrap them or add a `-Unattended` parameter.
- Time format is 24-hour `HH:MM` (e.g. `14:05`).
- Store credentials with `CredentialManager` (`Save-ToolkitCredential`) rather
  than scheduling interactive logins.

## Tested automatically

`New-CronExpression` and the platform guard are covered by the test suite
(Pester + CI). `schtasks.exe` registration itself requires a Windows host and
is verified via the manual smoke guidance in this folder.