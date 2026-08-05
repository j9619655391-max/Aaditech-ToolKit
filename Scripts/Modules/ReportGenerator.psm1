# ReportGenerator.psm1 - Generate styled HTML reports from PowerShell objects
# Part of IT Toolkit v2.0 Enhancement - Phase 1

<##
.SYNOPSIS
    Generates HTML reports from PowerShell object data.

.DESCRIPTION
    This module reads a reusable HTML template, builds table content from object data,
    and writes a polished HTML report to disk. It is intended for toolkit exports.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 1 Implementation
#>

$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Convert-ObjectArrayToHtmlTable {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Data
    )

    if (-not $Data -or $Data.Count -eq 0) {
        return '<p><em>No data available.</em></p>'
    }

    $headers = $Data[0].PSObject.Properties | ForEach-Object { $_.Name }
    $headerHtml = '<tr>' + ($headers | ForEach-Object { "<th>$($_)</th>" }) -join '' + '</tr>'

    $rowHtml = ''
    foreach ($item in $Data) {
        $cells = $headers | ForEach-Object { "<td>$([System.Web.HttpUtility]::HtmlEncode($item.$_))</td>" }
        $rowHtml += '<tr>' + ($cells -join '') + '</tr>'
    }

    return "<table class='report-table'>`n$headerHtml`n$rowHtml`n</table>"
}

function New-HTMLReport {
    <#
    .SYNOPSIS
        Creates an HTML report from object data.

    .DESCRIPTION
        Reads a reusable HTML template and fills in the report title, timestamp,
        and table content generated from PowerShell objects.

    .PARAMETER Data
        The collection of PowerShell objects to include in the report.

    .PARAMETER Title
        The report title.

    .PARAMETER Path
        The file path to save the HTML report.

    .PARAMETER TemplatePath
        The path to the HTML template file. If not specified, the default template
        in Scripts/Templates is used.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Data,

        [Parameter(Mandatory=$false)]
        [string]$Title = "IT Toolkit Report",

        [Parameter(Mandatory=$false)]
        [string]$Path,

        [Parameter(Mandatory=$false)]
        [string]$TemplatePath
    )

    try {
        if (-not $Path) {
            $logsDir = Join-Path (Split-Path -Parent $script:ModulesPath) "..\Logs"
            if (-not (Test-Path $logsDir)) {
                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            }
            $baseName = "Report_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            $Path = Join-Path $logsDir "$baseName.html"
        }

        if (-not $TemplatePath) {
            $TemplatePath = Join-Path (Split-Path -Parent $script:ModulesPath) "..\Templates\Report-Template.html"
        }

        $reportHtml = Convert-ObjectArrayToHtmlTable -Data $Data
        $template = if (Test-Path $TemplatePath) { Get-Content $TemplatePath -Raw } else { $null }

        if ($template) {
            $html = $template -replace '\{\{Title\}\}', [System.Web.HttpUtility]::HtmlEncode($Title)
            $html = $html -replace '\{\{Timestamp\}\}', (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $html = $html -replace '\{\{ReportBody\}\}', $reportHtml
        }
        else {
            $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset='UTF-8'>
    <title>$Title</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .report-table { border-collapse: collapse; width: 100%; }
        .report-table th, .report-table td { border: 1px solid #bbb; padding: 8px; }
        .report-table th { background-color: #2a7bb8; color: white; }
        .report-table tr:nth-child(even) { background-color: #f9f9f9; }
        .report-title { margin-bottom: 10px; }
        .report-footer { color: #666; font-size: 0.9em; margin-top: 20px; }
    </style>
</head>
<body>
    <h1 class='report-title'>$Title</h1>
    <p class='report-footer'>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
    $reportHtml
</body>
</html>
"@
        }

        $html | Out-File -FilePath $Path -Encoding UTF8
        Write-Host "HTML report generated successfully: $Path" -ForegroundColor Green
        return $Path
    }
    catch {
        Write-Error "Failed to generate HTML report: $_"
        return $null
    }
}

Export-ModuleMember -Function Convert-ObjectArrayToHtmlTable, New-HTMLReport
