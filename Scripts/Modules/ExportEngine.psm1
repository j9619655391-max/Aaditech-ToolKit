# ExportEngine.psm1 - Export data to various formats
# Part of IT Toolkit v2.0 Enhancement - Phase 1

<#
.SYNOPSIS
    Exports data to CSV, JSON, and other formats.

.DESCRIPTION
    This module provides functions to export PowerShell objects to various file formats
    for analysis and reporting purposes.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 1 Implementation
#>

# Get the script directory for path resolution
$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Export-ToCSV {
    <#
    .SYNOPSIS
        Exports PowerShell objects to CSV format.
    
    .DESCRIPTION
        Converts an array of PowerShell objects to CSV format and saves to a file.
        Automatically adds timestamp to filename if not specified.
    
    .PARAMETER Data
        The data to export (array of objects).
    
    .PARAMETER Path
        The file path to save the CSV. If not specified, saves to Logs folder.
    
    .PARAMETER IncludeTimestamp
        If specified, adds timestamp to the filename.
    
    .EXAMPLE
        Export-ToCSV -Data $results -Path "C:\Reports\output.csv"
    
    .EXAMPLE
        Export-ToCSV -Data $results -IncludeTimestamp
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Data,
        
        [Parameter(Mandatory=$false)]
        [string]$Path,
        
        [Parameter(Mandatory=$false)]
        [switch]$IncludeTimestamp
    )
    
    try {
        # Determine output path
        if (-not $Path) {
            $logsDir = Join-Path (Split-Path -Parent $script:ModulesPath) "..\Logs"
            if (-not (Test-Path $logsDir)) {
                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            }
            $baseName = "Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $Path = Join-Path $logsDir "$baseName.csv"
        }
        
        if ($IncludeTimestamp) {
            $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            if ($fileName -notmatch '\d{8}_\d{6}$') {
                $dir = Split-Path $Path -Parent
                $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
                $ext = [System.IO.Path]::GetExtension($Path)
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $Path = Join-Path $dir "${base}_${timestamp}$ext"
            }
        }
        
        # Export to CSV
        $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        
        Write-Host "CSV exported successfully to: $Path" -ForegroundColor Green
        return $Path
    }
    catch {
        Write-Error "Failed to export CSV: $_"
        return $null
    }
}

function Export-ToJSON {
    <#
    .SYNOPSIS
        Exports PowerShell objects to JSON format.
    
    .DESCRIPTION
        Converts PowerShell objects to JSON format and saves to a file.
        Useful for programmatic processing and integration.
    
    .PARAMETER Data
        The data to export (array of objects).
    
    .PARAMETER Path
        The file path to save the JSON. If not specified, saves to Logs folder.
    
    .PARAMETER Depth
        The depth of the JSON serialization (default: 10).
    
    .EXAMPLE
        Export-ToJSON -Data $results -Path "C:\Reports\output.json"
    
        Export-ToJSON -Data $results -Depth 5
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$Data,
        
        [Parameter(Mandatory=$false)]
        [string]$Path,
        
        [Parameter(Mandatory=$false)]
        [int]$Depth = 10
    )
    
    try {
        # Determine output path
        if (-not $Path) {
            $logsDir = Join-Path (Split-Path -Parent $script:ModulesPath) "..\Logs"
            if (-not (Test-Path $logsDir)) {
                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            }
            $baseName = "Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $Path = Join-Path $logsDir "$baseName.json"
        }
        
        # Export to JSON
        $Data | ConvertTo-Json -Depth $Depth -Compress | Out-File -FilePath $Path -Encoding UTF8
        
        Write-Host "JSON exported successfully to: $Path" -ForegroundColor Green
        return $Path
    }
    catch {
        Write-Error "Failed to export JSON: $_"
        return $null
    }
}

function Export-ToExcel {
    <#
    .SYNOPSIS
        Exports PowerShell objects to Excel-compatible format.
    
    .DESCRIPTION
        Exports data to CSV format that can be opened in Excel.
        This is an alias for Export-ToCSV with Excel-friendly defaults.
    
    .PARAMETER Data
        The data to export.
    
    .PARAMETER Path
        The file path to save.
    
    .EXAMPLE
        Export-ToExcel -Data $results
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Data,
        
        [Parameter(Mandatory=$false)]
        [string]$Path
    )
    
    # Use CSV export with Excel-friendly settings
    return Export-ToCSV -Data $Data -Path $Path
}

# Export all functions
Export-ModuleMember -Function Export-ToCSV, Export-ToJSON, Export-ToExcel