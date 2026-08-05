<#
.SYNOPSIS
    Phase 1 regression tests for IT Toolkit export and alert modules.
.DESCRIPTION
    Runs export, HTML generation, alert threshold, and log cleanup validation checks.
    Designed to be executed on a Windows machine with PowerShell.
#>

Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir = Join-Path $scriptDir ".."
$moduleDir = Join-Path $rootDir "Modules"
$logsDir = Join-Path $rootDir "..\Logs"
$testDir = Join-Path $scriptDir "TempTest"

if (-not (Test-Path $testDir)) {
    New-Item -ItemType Directory -Path $testDir | Out-Null
}

$ScriptHadFailures = $false

function Assert-True {
    param(
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$true)][string]$Message
    )

    if (-not $Condition) {
        Write-Host "FAIL: $Message" -ForegroundColor Red
        $global:ScriptHadFailures = $true
    } else {
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Message
    )

    Assert-True -Condition (Test-Path $Path) -Message $Message
}

function Clean-TestFiles {
    if (Test-Path $testDir) {
        Get-ChildItem -Path $testDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Import-Phase1Modules {
    foreach ($module in @('ExportEngine.psm1', 'AlertEngine.psm1', 'ReportGenerator.psm1', 'LogManager.psm1')) {
        $path = Join-Path $moduleDir $module
        if (Test-Path $path) {
            Import-Module $path -Force -ErrorAction Stop
            Write-Host "Loaded module: $module" -ForegroundColor Cyan
        } else {
            throw "Missing module: $path"
        }
    }
}

function Test-ExportEngine {
    Write-Host "\n=== Running ExportEngine tests ===" -ForegroundColor Cyan

    $data = @(
        [PSCustomObject]@{ Name = 'TestA'; Value = 10 },
        [PSCustomObject]@{ Name = 'TestB'; Value = 20 }
    )

    $csvPath = Join-Path $testDir 'export_test.csv'
    $excelPath = Join-Path $testDir 'export_test_excel.csv'
    $jsonPath = Join-Path $testDir 'export_test.json'

    $csvResult = Export-ToCSV -Data $data -Path $csvPath -IncludeTimestamp
    Assert-PathExists -Path $csvResult -Message 'CSV export file created'
    if (Test-Path $csvResult) {
        $imported = Import-Csv -Path $csvResult -ErrorAction Stop
        $cols = @($imported[0].PSObject.Properties.Name)
        Assert-True -Condition (($cols -contains 'Name') -and ($cols -contains 'Value')) -Message 'CSV output contains Name and Value header columns'
    }

    $jsonResult = Export-ToJSON -Data $data -Path $jsonPath -Depth 5
    Assert-PathExists -Path $jsonResult -Message 'JSON export file created'
    if (Test-Path $jsonResult) {
        $json = Get-Content -Path $jsonResult -Raw | ConvertFrom-Json -ErrorAction Stop
        Assert-True -Condition ($json.Count -eq 2) -Message 'JSON output contains two objects'
    }

    $excelResult = Export-ToExcel -Data $data -Path $excelPath
    Assert-PathExists -Path $excelResult -Message 'Excel-compatible CSV export file created'
    if (Test-Path $excelResult) {
        $excelImported = Import-Csv -Path $excelResult -ErrorAction Stop
        $excelCols = @($excelImported[0].PSObject.Properties.Name)
        Assert-True -Condition (($excelCols -contains 'Name') -and ($excelCols -contains 'Value')) -Message 'Excel-compatible output contains Name and Value header columns'
    }
}

function Test-ReportGenerator {
    Write-Host "\n=== Running ReportGenerator tests ===" -ForegroundColor Cyan

    $data = @(
        [PSCustomObject]@{ Host = 'host1'; Status = 'OK' },
        [PSCustomObject]@{ Host = 'host2'; Status = 'Fail' }
    )
    $reportPath = Join-Path $testDir 'report_test.html'

    $result = New-HTMLReport -Data $data -Title 'Report Generator Test' -Path $reportPath
    Assert-PathExists -Path $result -Message 'New-HTMLReport file created'
    if (Test-Path $result) {
        $content = Get-Content -Path $result -Raw -ErrorAction Stop
        Assert-True -Condition ($content -match 'Report Generator Test') -Message 'HTML report title included'
        Assert-True -Condition ($content -match '<table') -Message 'HTML report contains a table'
    }
}

function Test-AlertEngine {
    Write-Host "\n=== Running AlertEngine tests ===" -ForegroundColor Cyan

    $alert = Test-AlertThreshold -Type 'Disk' -Value 92 -Threshold 85
    Assert-True -Condition ($alert.Severity -eq 'Warning') -Message 'Disk threshold 92% with warning=85 returns Warning'
    Assert-True -Condition ($alert.IsAlert) -Message 'Disk alert IsAlert is true'

    $criticalAlert = Test-AlertThreshold -Type 'Disk' -Value 96 -Threshold 85
    Assert-True -Condition ($criticalAlert.Severity -eq 'Critical') -Message 'Disk threshold 96% with critical=95 returns Critical'
    Assert-True -Condition ($criticalAlert.IsAlert) -Message 'Critical disk alert IsAlert is true'

    $severity = Get-AlertSeverity -Value 85 -WarningThreshold 75 -CriticalThreshold 90
    Assert-True -Condition ($severity -eq 'Warning') -Message 'Get-AlertSeverity returns Warning'
}

function Test-LogManager {
    Write-Host "\n=== Running LogManager tests ===" -ForegroundColor Cyan

    $oldFile = Join-Path $testDir 'old_log.txt'
    $newFile = Join-Path $testDir 'recent_log.txt'

    'old' | Out-File -FilePath $oldFile -Encoding UTF8
    'new' | Out-File -FilePath $newFile -Encoding UTF8

    (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-3)
    (Get-Item $newFile).LastWriteTime = (Get-Date).AddMinutes(-10)

    Remove-OldLogs -LogsPath $testDir -RetentionDays 1 | Out-Null

    Assert-True -Condition (-not (Test-Path $oldFile)) -Message 'Old log file removed'
    Assert-PathExists -Path $newFile -Message 'Recent log file preserved'
}

try {
    Import-Phase1Modules
    Clean-TestFiles
    Test-ExportEngine
    Test-ReportGenerator
    Test-AlertEngine
    Test-LogManager
} catch {
    Write-Host "Unexpected test failure: $_" -ForegroundColor Red
    $ScriptHadFailures = $true
} finally {
    if (Test-Path $testDir) {
        Get-ChildItem -Path $testDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $testDir -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "\n=== Phase 1 regression test summary ===" -ForegroundColor Cyan
if ($ScriptHadFailures) {
    Write-Host 'Some tests failed.' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'All Phase 1 regression tests passed.' -ForegroundColor Green
    exit 0
}
