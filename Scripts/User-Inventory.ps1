<#
.SYNOPSIS
    Generates a comprehensive user inventory report for the local machine.
.DESCRIPTION
    Collects system info, hardware specs, installed applications, network config,
    logged-in users, services, and Windows updates, then saves to the Logs folder.
    Report includes CPU, RAM, disk space, OS version, and more for asset tracking.
#>

# Load configuration if available
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "..\Config\config.json"
$logsDir = Join-Path $scriptDir "..\Logs"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        # ignore config parse errors, use default
    }
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    $rootPath = Split-Path -Parent $scriptDir
    return Join-Path $rootPath $Path
}

if ($config -and $config.paths -and $config.paths.logs) {
    $logsDir = Resolve-ToolPath $config.paths.logs
}

# Import Phase 1 modules for export and cleanup when available
$modulePath = Join-Path $scriptDir "Modules"
if (Test-Path (Join-Path $modulePath 'ExportEngine.psm1')) { Import-Module (Join-Path $modulePath 'ExportEngine.psm1') -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $modulePath 'LogManager.psm1')) { Import-Module (Join-Path $modulePath 'LogManager.psm1') -ErrorAction SilentlyContinue }

if (!(Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

if ($config -and $config.logRetention -and $config.logRetention.autoCleanup -and (Get-Command Remove-OldLogs -ErrorAction SilentlyContinue)) {
    $retentionDays = if ($config.logRetention.retentionDays) { [int]$config.logRetention.retentionDays } else { 90 }
    Remove-OldLogs -LogsPath $logsDir -RetentionDays $retentionDays | Out-Null
}

# Generate unique report filename
$timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$reportPath = Join-Path $logsDir "UserInventory_$timestamp.txt"

Write-Host "Scanning system inventory..." -ForegroundColor Cyan

# Collect system information
$os = Get-ComputerInfo
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
$disk = Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name='Free(GB)';Expression={[math]::Round($_.Free/1GB,2)}}, @{Name='Used(GB)';Expression={[math]::Round(($_.Used/1GB),2)}}

# Collect installed applications
Write-Host "Reading installed applications (may take a moment)..." -ForegroundColor Cyan
$installedApps = @()
$maxApps = 50
if ($config -and $config.userInventory -and $config.userInventory.maxApplicationsInReport) {
    $maxApps = [int]$config.userInventory.maxApplicationsInReport
} elseif ($config -and $config.scriptParameters -and $config.scriptParameters.userInventoryMaxApplications) {
    $maxApps = [int]$config.scriptParameters.userInventoryMaxApplications
}
try {
    $installedApps += Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName }
    $installedApps += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName }
    $installedApps = $installedApps | Sort-Object DisplayName -Unique | Select-Object DisplayName, @{Name='Version';Expression={$_.DisplayVersion}}, Publisher
} catch {
    $installedApps = @()
}

# Collect network adapters
$networkAdapters = @()
if (-not ($config -and $config.userInventory -and $config.userInventory.includeNetworkAdapters -eq $false)) {
    $networkAdapters = Get-NetAdapter | Select-Object Name, Status, @{Name='Speed';Expression={if($_.LinkSpeed) {$_.LinkSpeed} else {'N/A'}}}
}

# Collect logged-in users
$loggedUsers = @()
if (-not ($config -and $config.userInventory -and $config.userInventory.includeLoggedInUsers -eq $false)) {
    $loggedUsers = Get-CimInstance Win32_LoggedOnUser | Select-Object @{Name='User';Expression={$_.Name}}
}

# Collect running services count
$runningServices = (Get-Service | Where-Object {$_.Status -eq 'Running'}).Count
$totalServices = (Get-Service).Count

# Collect Windows updates
Write-Host "Reading Windows Update history..." -ForegroundColor Cyan
$lastUpdate = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1

# Collect BIOS/Firmware info
$bios = Get-CimInstance Win32_BIOS | Select-Object -First 1

# Build report with proper formatting
$report = @()
$report += "=================================="
$report += "  IT TOOLKIT - USER INVENTORY"
$report += "=================================="
$report += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += "Computer: $($os.CsName)"
$report += ""
$report += "=== OPERATING SYSTEM ==="
$report += "OS Name: $($os.OsName)"
$report += "OS Version: $($os.OsVersion)"
$report += "OS Build: $($os.OsBuildNumber)"
$report += "Install Date: $($os.OsInstallDate)"
$report += ""
$report += "=== HARDWARE INFORMATION ==="
$report += "CPU: $($cpu.Name)"
$report += "CPU Cores (Logical): $($cpu.NumberOfLogicalProcessors)"
$report += "CPU Max Speed: $($cpu.MaxClockSpeed) MHz"
$report += "RAM: $([math]::Round($ram,2)) GB"
$report += ""
$report += "=== STORAGE ==="
foreach ($d in $disk) {
    $report += "Drive $($d.Name): Free=$($d.'Free(GB)') GB | Used=$($d.'Used(GB)') GB"
}
$report += ""
$report += "=== FIRMWARE ==="
$report += "BIOS Manufacturer: $($bios.Manufacturer)"
$report += "BIOS Version: $($bios.SMBIOSBIOSVersion)"
$report += ""
if ($networkAdapters.Count -gt 0) {
    $report += "=== NETWORK ADAPTERS (TOP 5) ==="
    $report += ($networkAdapters | Select-Object -First 5 | Format-Table -AutoSize | Out-String)
    $report += ""
}
if ($loggedUsers.Count -gt 0) {
    $report += "=== LOGGED-IN USERS ==="
    $report += ($loggedUsers | Format-Table -AutoSize | Out-String)
    $report += ""
}
$report += "=== SERVICES ==="
$report += "Running: $runningServices / Total: $totalServices"
$report += ""
$report += "=== LATEST WINDOWS UPDATE ==="
if ($lastUpdate) {
    $report += "KB: $($lastUpdate.HotFixID)"
    $report += "Installed: $($lastUpdate.InstalledOn)"
    $report += "Description: $($lastUpdate.Description)"
} else {
    $report += "No updates found"
}
$report += ""
$report += "=== INSTALLED APPLICATIONS (TOP 30) ==="
if ($installedApps.Count -gt 0) {
    $report += ($installedApps | Select-Object -First 30 | Format-Table -AutoSize | Out-String)
    if ($installedApps.Count -gt 30) {
        $report += "`n[... and $($installedApps.Count - 30) more applications]"
    }
} else {
    $report += "Unable to read installed applications"
}

# Save report
$report -join "`n" | Out-File -FilePath $reportPath -Encoding UTF8

$summaryObject = [PSCustomObject]@{
    Timestamp            = Get-Date
    Computer             = $os.CsName
    OS                   = $os.OsName
    OSVersion            = $os.OsVersion
    CPU                  = $cpu.Name
    RAM_GB               = [math]::Round($ram,2)
    TotalDrives          = $disk.Count
    InstalledApplications = $installedApps.Count
    LastUpdateKB         = if ($lastUpdate) { $lastUpdate.HotFixID } else { 'None' }
}

if (Get-Command Export-ToCSV -ErrorAction SilentlyContinue) {
    Export-ToCSV -Data @($summaryObject) -Path (Join-Path $logsDir "UserInventory_Summary_$timestamp.csv") | Out-Null
}
if (Get-Command Export-ToJSON -ErrorAction SilentlyContinue) {
    Export-ToJSON -Data @($summaryObject) -Path (Join-Path $logsDir "UserInventory_Summary_$timestamp.json") | Out-Null
}
if (Get-Command New-HTMLReport -ErrorAction SilentlyContinue) {
    New-HTMLReport -Data @($summaryObject) -Title "User Inventory Summary" -Path (Join-Path $logsDir "UserInventory_Summary_$timestamp.html") | Out-Null
}

# Output location
Write-Host ""
Write-Host "User inventory report saved to:" -ForegroundColor Green
Write-Host $reportPath -ForegroundColor Green
Write-Host "Applications found: $($installedApps.Count)" -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to return to menu" -ForegroundColor Yellow
Read-Host
