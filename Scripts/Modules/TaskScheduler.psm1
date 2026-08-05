# TaskScheduler.psm1 - Schedule toolkit tasks via Windows Task Scheduler
# Part of IT Toolkit - Phase 3 (automation)

<#
.SYNOPSIS
    Registers, queries, and removes scheduled toolkit runs on Windows.

.DESCRIPTION
    Thin wrapper around the schtasks.exe command-line tool so scripts can be
    scheduled without interactive Task Scheduler UI. Cross-checks existence
    and returns friendly objects. Windows-only for the scheduling operations;
    the helper New-CronExpression is pure and testable anywhere.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 3 Implementation
#>

$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:ModulesPath)

function Get-TaskSchedulerAvailable {
    <#
    .SYNOPSIS
        Returns $true on Windows where schtasks.exe exists.
    #>
    if (-not ($env:OS -eq 'Windows_NT')) { return $false }
    return [bool](Get-Command schtasks.exe -ErrorAction SilentlyContinue)
}

function New-CronExpression {
    <#
    .SYNOPSIS
        Builds a daily/weekly cron-style recurrence descriptor string used by
        the toolkit's scheduler wrapper. Pure string helper (testable anywhere).

    .PARAMETER EveryDays
        Recurrence interval in days (1 = daily).

    .PARAMETER AtTime
        HH:MM 24h start time (default '08:00').
    #>
    param(
        [Parameter(Mandatory=$false)][int]$EveryDays = 1,
        [Parameter(Mandatory=$false)][string]$AtTime = '08:00'
    )
    if ($EveryDays -lt 1) { $EveryDays = 1 }
    return "cron: 0 $([int]::Parse($AtTime.Split(':')[1])) $([int]::Parse($AtTime.Split(':')[0])) * * */$EveryDays"
}

function Register-ToolkitScheduledTask {
    <#
    .SYNOPSIS
        Creates a scheduled task that runs a toolkit script.

    .PARAMETER TaskName
        Unique name for the scheduled task.

    .PARAMETER ScriptPath
        Absolute path to the .ps1 to run.

    .PARAMETER WeeklyDays
        Space-joined day names for a weekly schedule (e.g. 'MON THU').

    .PARAMETER AtTime
        HH:mm 24 start time (default 08:00).

    .EXAMPLE
        Register-ToolkitScheduledTask -TaskName 'ITK-Inventory' `
          -ScriptPath 'C:\IT-Toolkit\Scripts\User-Inventory.ps1' `
          -WeeklyDays 'MON' -AtTime '07:30'
    #>
    param(
        [Parameter(Mandatory=$true)][string]$TaskName,
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [Parameter(Mandatory=$false)][string]$WeeklyDays = 'MON',
        [Parameter(Mandatory=$false)][string]$AtTime = '08:00'
    )
    if (-not (Get-TaskSchedulerAvailable)) { throw 'Task scheduling requires Windows + schtasks.exe.' }
    if (-not (Test-Path $ScriptPath)) { throw "Script not found: $ScriptPath" }

    $time = [regex]::Match($AtTime, '^\d{1,2}:\d{2}$')
    if (-not $time.Success) { throw "Invalid time '$AtTime'. Use HH:mm 24h." }

    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $daylist = $WeeklyDays -join ',' -replace '(?i)\s*,\s*', ','
    & schtasks.exe /Create /TN $TaskName /TR $cmd /SC WEEKLY /D $daylist /ST $AtTime /F 2>&1 | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Get-ToolkitScheduledTask {
    <#
    .SYNOPSIS
        Lists registered toolkit tasks matching a name filter.
    #>
    param([Parameter(Mandatory=$false)][string]$Filter)
    if (-not (Get-TaskSchedulerAvailable)) { return $null }
    if ($Filter) { & schtasks.exe /Query /TN $Filter /FO LIST 2>$null | Out-Host; return }
    & schtasks.exe /Query /FO LIST 2>$null | Out-Host
}

function Remove-ToolkitScheduledTask {
    <#
    .SYNOPSIS
        Unregisters a scheduled task.

    .PARAMETER TaskName
        Name of the task to remove.
    #>
    param([Parameter(Mandatory=$true)][string]$TaskName)
    if (-not (Get-TaskSchedulerAvailable)) { return $false }
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Export-ModuleMember -Function New-CronExpression, Register-ToolkitScheduledTask, Get-ToolkitScheduledTask, Remove-ToolkitScheduledTask, Get-TaskSchedulerAvailable