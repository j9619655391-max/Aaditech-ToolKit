<#
.SYNOPSIS
    IT Toolkit - QuickCheck: One-click desktop support diagnostics menu.
.DESCRIPTION
    Double-click "Run-QuickCheck.bat" (or right-click this file > Run with PowerShell)
    to launch a menu of the most common desktop support checks.
    No installation required. Safe to run on any Windows 10/11 machine.
#>

# Load configuration
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Shared config/path helpers (single source of truth)
Import-Module (Join-Path $scriptDir "Modules\ToolkitConfig.psm1") -ErrorAction SilentlyContinue
$config = Get-ToolkitConfig -ScriptDir $scriptDir
$logsDir = Get-ToolkitDirectory -Config $config -Key "logs" -Default "Logs" -ScriptDir $scriptDir
$scriptsDir = Get-ToolkitDirectory -Config $config -Key "scripts" -Default "Scripts" -ScriptDir $scriptDir
$templatesDir = Get-ToolkitDirectory -Config $config -Key "templates" -Default "Templates" -ScriptDir $scriptDir

# Import required Phase 1 modules
$modulePath = Join-Path $scriptDir "Modules"
if (Test-Path (Join-Path $modulePath 'ExportEngine.psm1')) {
    Import-Module (Join-Path $modulePath 'ExportEngine.psm1') -ErrorAction SilentlyContinue
}
if (Test-Path (Join-Path $modulePath 'AlertEngine.psm1')) {
    Import-Module (Join-Path $modulePath 'AlertEngine.psm1') -ErrorAction SilentlyContinue
}
if (Test-Path (Join-Path $modulePath 'ReportGenerator.psm1')) {
    Import-Module (Join-Path $modulePath 'ReportGenerator.psm1') -ErrorAction SilentlyContinue
}
if (Test-Path (Join-Path $modulePath 'LogManager.psm1')) {
    Import-Module (Join-Path $modulePath 'LogManager.psm1') -ErrorAction SilentlyContinue
}

function Initialize-Toolkit {
    if ($config -and $config.logRetention -and $config.logRetention.autoCleanup -and (Get-Command Remove-OldLogs -ErrorAction SilentlyContinue)) {
        $retentionDays = if ($config.logRetention.retentionDays) { [int]$config.logRetention.retentionDays } else { 90 }
        Remove-OldLogs -LogsPath $logsDir -RetentionDays $retentionDays | Out-Null
    }
}
Initialize-Toolkit

function Show-Menu {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "           IT TOOLKIT - QUICK CHECK MENU          " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host " 1.  System Info (Get-ComputerInfo)"
    Write-Host " 2.  Installed Applications"
    Write-Host " 3.  Disk Space"
    Write-Host " 4.  Running Services"
    Write-Host " 5.  Last Boot / Uptime"
    Write-Host " 6.  Network Config (ipconfig /all)"
    Write-Host " 7.  Ping Gateway + DNS Test"
    Write-Host " 8.  Top 10 CPU/RAM Processes"
    Write-Host " 9.  Startup Programs"
    Write-Host "10.  Recent System Errors (Event Viewer, last 24h)"
    Write-Host "11.  Disk Health (SMART status)"
    Write-Host "12.  Run FULL Health Check (saves report to Logs folder)"
    Write-Host "13.  Repair Tools (sfc / DISM / chkdsk menu)"
    Write-Host " 0.  Exit"
    Write-Host "=================================================" -ForegroundColor Cyan
}

function Pause-Return {
    Write-Host ""
    Read-Host "Press Enter to return to menu"
}

function Get-SystemAlerts {
    param(
        [Parameter(Mandatory=$false)]
        [Hashtable]$Thresholds
    )

    if (-not $Thresholds) { return @() }
    if (-not (Get-Command Test-AlertThreshold -ErrorAction SilentlyContinue)) { return @() }

    $alerts = @()

    try {
        $diskDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and $_.Free -ne $null }
        if ($diskDrives.Count -gt 0) {
            $maxDisk = $diskDrives | ForEach-Object {
                $percent = if (($_.Used + $_.Free) -gt 0) { [math]::Round(($_.Used / ($_.Used + $_.Free)) * 100,1) } else { 0 }
                [PSCustomObject]@{
                    Name         = $_.Name
                    UsagePercent = $percent
                    Free         = $_.Free
                    Used         = $_.Used
                }
            } | Sort-Object UsagePercent -Descending | Select-Object -First 1

            if ($maxDisk) {
                $alerts += Test-AlertThreshold -Type "Disk" -Value $maxDisk.UsagePercent -Threshold $Thresholds.diskUsagePercent
            }
        }

        $osInfo = Get-CimInstance Win32_OperatingSystem
        if ($osInfo) {
            $totalMemory = $osInfo.TotalVisibleMemorySize * 1KB
            $freeMemory = $osInfo.FreePhysicalMemory * 1KB
            if ($totalMemory -gt 0) {
                $memoryPercent = [math]::Round((($totalMemory - $freeMemory) / $totalMemory) * 100,1)
                $alerts += Test-AlertThreshold -Type "Memory" -Value $memoryPercent -Threshold $Thresholds.memoryUsagePercent
            }
        }

        try {
            $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
            $cpuValue = if ($cpuCounter.CounterSamples.Count -gt 0) { [math]::Round($cpuCounter.CounterSamples[-1].CookedValue,1) } else { 0 }
            $alerts += Test-AlertThreshold -Type "CPU" -Value $cpuValue -Threshold $Thresholds.cpuUsagePercent
        } catch {
            Write-Warning "Unable to read CPU usage counter: $_"
        }
    } catch {
        Write-Warning "Failed to evaluate system alerts: $_"
    }

    return $alerts
}

function Export-HealthSummary {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject[]]$Data,

        [Parameter(Mandatory=$true)]
        [string]$Timestamp
    )

    if (Get-Command Export-ToCSV -ErrorAction SilentlyContinue) {
        Export-ToCSV -Data $Data -Path (Join-Path $logsDir "HealthCheck_Summary_$Timestamp.csv") | Out-Null
    }
    if (Get-Command Export-ToJSON -ErrorAction SilentlyContinue) {
        Export-ToJSON -Data $Data -Path (Join-Path $logsDir "HealthCheck_Summary_$Timestamp.json") | Out-Null
    }
    if (Get-Command New-HTMLReport -ErrorAction SilentlyContinue) {
        New-HTMLReport -Data $Data -Title "Full Health Check Summary" -Path (Join-Path $logsDir "HealthCheck_Summary_$Timestamp.html") | Out-Null
    }
}

function Run-FullHealthCheck {
    $logDir = $logsDir
    if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $file = Join-Path $logDir "HealthCheck_$stamp.txt"

    $healthSummary = [PSCustomObject]@{
        ComputerName            = $env:COMPUTERNAME
        User                    = $env:USERNAME
        Generated               = Get-Date
        OS                      = ''
        OSVersion               = ''
        ComputerArchitecture    = ''
        MaxDiskUsagePercent     = 0
        LastBoot                = $null
        TopProcess              = ''
        AutomaticServicesStopped = 0
        RecentSystemErrors      = 0
        CPUUsagePercent         = 0
        AlertCount              = 0
    }

    "IT TOOLKIT - FULL HEALTH CHECK REPORT" | Out-File $file
    "Generated: $($healthSummary.Generated)" | Out-File $file -Append
    "Computer: $($healthSummary.ComputerName) | User: $($healthSummary.User)" | Out-File $file -Append
    "=================================================" | Out-File $file -Append

    "`n--- SYSTEM INFO ---" | Out-File $file -Append
    $systemInfo = Get-ComputerInfo | Select-Object OsName, OsVersion, OsArchitecture, CsManufacturer, CsModel, CsProcessors, OsTotalVisibleMemorySize
    $systemInfo | Out-String | Out-File $file -Append
    $healthSummary.OS = $systemInfo.OsName
    $healthSummary.OSVersion = $systemInfo.OsVersion
    $healthSummary.ComputerArchitecture = $systemInfo.OsArchitecture

    "`n--- DISK SPACE ---" | Out-File $file -Append
    $diskInfo = Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name='UsedGB';Expression={[math]::Round($_.Used/1GB,2)}}, @{Name='FreeGB';Expression={[math]::Round($_.Free/1GB,2)}}, @{Name='UsedPercent';Expression={if (($_.Used + $_.Free) -gt 0) {[math]::Round(($_.Used / ($_.Used + $_.Free)) * 100,1)} else {0}}}
    $diskInfo | Format-Table -AutoSize | Out-String | Out-File $file -Append
    $healthSummary.MaxDiskUsagePercent = ($diskInfo | Sort-Object UsedPercent -Descending | Select-Object -First 1).UsedPercent

    "`n--- LAST BOOT ---" | Out-File $file -Append
    $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $lastBoot | Out-File $file -Append
    $healthSummary.LastBoot = $lastBoot

    "`n--- TOP 10 PROCESSES BY MEMORY ---" | Out-File $file -Append
    $topProcesses = Get-Process | Sort-Object WS -Descending | Select-Object -First 10 Name, Id, CPU, @{N='RAM(MB)';E={[math]::Round($_.WS/1MB,1)}}
    $topProcesses | Format-Table -AutoSize | Out-String | Out-File $file -Append
    $healthSummary.TopProcess = if ($topProcesses.Count -gt 0) { $topProcesses[0].Name } else { '' }

    "`n--- SERVICES NOT RUNNING (Automatic) ---" | Out-File $file -Append
    $notRunning = Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
    $notRunning | Format-Table Name, Status -AutoSize | Out-String | Out-File $file -Append
    $healthSummary.AutomaticServicesStopped = $notRunning.Count

    "`n--- RECENT SYSTEM ERRORS (24h) ---" | Out-File $file -Append
    $recentErrors = Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message -First 15
    $recentErrors | Format-List | Out-String | Out-File $file -Append
    $healthSummary.RecentSystemErrors = $recentErrors.Count

    "`n--- NETWORK CONFIG ---" | Out-File $file -Append
    ipconfig /all | Out-File $file -Append

    $alerts = if ($config -and $config.alertThresholds) { Get-SystemAlerts -Thresholds $config.alertThresholds } else { Get-SystemAlerts -Thresholds @{ diskUsagePercent = 85; memoryUsagePercent = 80; cpuUsagePercent = 90 } }
    if ($alerts.Count -gt 0) {
        "`n--- ALERTS ---" | Out-File $file -Append
        foreach ($alert in $alerts) {
            $alert.Message | Out-File $file -Append
            if (Get-Command Format-AlertMessage -ErrorAction SilentlyContinue) {
                Format-AlertMessage -Alert $alert
            }
        }
        $healthSummary.AlertCount = $alerts.Count
    } else {
        "`n--- ALERTS ---" | Out-File $file -Append
        "No alerts triggered." | Out-File $file -Append
        $healthSummary.AlertCount = 0
    }

    "`n--- PERFORMANCE ---" | Out-File $file -Append
    $cpuResult = $null
    try {
        $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
        $cpuResult = [math]::Round($cpuCounter.CounterSamples[-1].CookedValue,1)
        "CPU Usage: $cpuResult%" | Out-File $file -Append
        $healthSummary.CPUUsagePercent = $cpuResult
    } catch {
        Write-Warning "CPU counter unavailable: $_"
    }

    Export-HealthSummary -Data @($healthSummary) -Timestamp $stamp

    Write-Host "`nReport saved to: $file" -ForegroundColor Green
    if (Get-Command New-HTMLReport -ErrorAction SilentlyContinue) {
        Write-Host "Summary exports saved to Logs folder." -ForegroundColor Green
    }
    notepad.exe $file
}

function Run-RepairMenu {
    Write-Host ""
    Write-Host "1. SFC Scan (sfc /scannow)"
    Write-Host "2. DISM Restore Health"
    Write-Host "3. CHKDSK (schedule on next reboot)"
    Write-Host "4. Flush DNS + Reset Winsock"
    $c = Read-Host "Choose an option"
    switch ($c) {
        "1" { sfc /scannow }
        "2" { DISM /Online /Cleanup-Image /RestoreHealth }
        "3" { Write-Host "This will schedule a check on next restart."; chkdsk C: /f }
        "4" { ipconfig /flushdns; netsh winsock reset; Write-Host "Restart required for Winsock reset to take effect." -ForegroundColor Yellow }
        default { Write-Host "Invalid option" }
    }
}

do {
    Show-Menu
    $choice = Read-Host "Select an option"
    switch ($choice) {
        "1"  { Get-ComputerInfo | Format-List OsName, OsVersion, OsArchitecture, CsManufacturer, CsModel, CsProcessors, OsTotalVisibleMemorySize; Pause-Return }
        "2"  { Get-Package | Sort-Object Name | Format-Table Name, Version -AutoSize | Out-Host -Paging; Pause-Return }
        "3"  { Get-PSDrive -PSProvider FileSystem | Format-Table Name, Used, Free -AutoSize; Pause-Return }
        "4"  { Get-Service | Sort-Object Status -Descending | Format-Table Name, Status, StartType -AutoSize | Out-Host -Paging; Pause-Return }
        "5"  { "Last Boot: " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; "Uptime: " + ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime); Pause-Return }
        "6"  { ipconfig /all | Out-Host -Paging; Pause-Return }
        "7"  {
                $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
                Write-Host "Gateway detected: $gw"
                if ($gw) { Test-Connection $gw -Count 4 }
                Write-Host "`nTesting DNS (google.com)..."
                Resolve-DnsName google.com -ErrorAction SilentlyContinue
                Pause-Return
             }
        "8"  { Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, CPU, @{N='RAM(MB)';E={[math]::Round($_.WS/1MB,1)}} | Format-Table -AutoSize; Pause-Return }
        "9"  { Get-CimInstance Win32_StartupCommand | Format-Table Name, Command, Location -AutoSize; Pause-Return }
        "10" { Get-WinEvent -FilterHashtable @{LogName='System'; Level=2; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, Message -First 15 | Format-List; Pause-Return }
        "11" { Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus | Format-Table -AutoSize; Pause-Return }
        "12" { Run-FullHealthCheck; Pause-Return }
        "13" { Run-RepairMenu; Pause-Return }
        "0"  { Write-Host "Goodbye!" -ForegroundColor Green }
        default { Write-Host "Invalid option, try again." -ForegroundColor Red; Pause-Return }
    }
} while ($choice -ne "0")
