# LogManager.psm1 - Log retention and cleanup utilities
# Part of IT Toolkit v2.0 Enhancement - Phase 1

<##
.SYNOPSIS
    Removes old log files based on retention settings.

.DESCRIPTION
    Deletes files older than the configured retention period in the Logs folder.
    This module helps keep the toolkit log directory clean and manageable.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 1 Implementation
#>

$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Remove-OldLogs {
    <#
    .SYNOPSIS
        Deletes old log files.

    .DESCRIPTION
        Removes files from the Logs directory that are older than the specified
        retention period.

    .PARAMETER LogsPath
        Path to the Logs folder. If omitted, uses the default Logs folder.

    .PARAMETER RetentionDays
        Number of days to keep logs. Files older than this will be deleted.
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$LogsPath,

        [Parameter(Mandatory=$false)]
        [int]$RetentionDays = 90
    )

    try {
        if (-not $LogsPath) {
            $LogsPath = Join-Path (Split-Path -Parent $script:ModulesPath) "..\Logs"
        }

        if (-not (Test-Path $LogsPath)) {
            Write-Host "Logs folder does not exist; nothing to clean." -ForegroundColor Yellow
            return $null
        }

        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        $deletedFiles = @()

        Get-ChildItem -Path $LogsPath -File -ErrorAction Stop | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
            Remove-Item -Path $_.FullName -Force -ErrorAction Stop
            $deletedFiles += $_.FullName
        }

        if ($deletedFiles.Count -gt 0) {
            Write-Host "Removed $($deletedFiles.Count) old log file(s) from $LogsPath." -ForegroundColor Green
            return $deletedFiles
        }
        else {
            Write-Host "No log files older than $RetentionDays days were found." -ForegroundColor Cyan
            return @()
        }
    }
    catch {
        Write-Error "Failed to remove old logs: $_"
        return $null
    }
}

Export-ModuleMember -Function Remove-OldLogs
