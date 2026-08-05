<#
.SYNOPSIS
    Runs a step-by-step network diagnostic in the exact order a desktop
    support engineer should check things, and prints a clear PASS/FAIL summary.
#>

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "           NETWORK DIAGNOSTIC - STEP BY STEP       " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# Load configuration if available
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "..\Config\config.json"
$logsDir = Join-Path $scriptDir "..\Logs"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        # ignore config parse errors, use defaults
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

# Import Phase 1 export and cleanup modules
$modulePath = Join-Path $scriptDir "Modules"
if (Test-Path (Join-Path $modulePath 'ExportEngine.psm1')) { Import-Module (Join-Path $modulePath 'ExportEngine.psm1') -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $modulePath 'LogManager.psm1')) { Import-Module (Join-Path $modulePath 'LogManager.psm1') -ErrorAction SilentlyContinue }

$timeoutMs = 2000
if ($config -and $config.scriptParameters -and $config.scriptParameters.networkDiagnosticTimeoutMs) {
    $timeoutMs = [int]$config.scriptParameters.networkDiagnosticTimeoutMs
}

if (!(Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

if ($config -and $config.logRetention -and $config.logRetention.autoCleanup -and (Get-Command Remove-OldLogs -ErrorAction SilentlyContinue)) {
    $retentionDays = if ($config.logRetention.retentionDays) { [int]$config.logRetention.retentionDays } else { 90 }
    Remove-OldLogs -LogsPath $logsDir -RetentionDays $retentionDays | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmm"

# 1. IP Configuration
Write-Host "`n[1] Checking local IP configuration..." -ForegroundColor Yellow
$adapter = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -ne $null } | Select-Object -First 1
if ($adapter) {
    Write-Host "PASS - IP Address: $($adapter.IPv4Address.IPAddress)" -ForegroundColor Green
    $gw = $adapter.IPv4DefaultGateway.NextHop
    Write-Host "       Gateway: $gw"
} else {
    Write-Host "FAIL - No active IPv4 adapter found. Check cable/Wi-Fi and driver." -ForegroundColor Red
}

# 2. Ping Gateway
Write-Host "`n[2] Pinging default gateway..." -ForegroundColor Yellow
if ($gw) {
    $pingGw = Test-Connection -ComputerName $gw -Count 2 -Quiet
    if ($pingGw) { Write-Host "PASS - Gateway is reachable." -ForegroundColor Green }
    else { Write-Host "FAIL - Gateway unreachable. Check switch/router/cable." -ForegroundColor Red }
} else {
    Write-Host "SKIP - No gateway detected." -ForegroundColor DarkYellow
}

# 3. DNS Resolution
Write-Host "`n[3] Testing DNS resolution..." -ForegroundColor Yellow
try {
    $dns = Resolve-DnsName -Name "google.com" -ErrorAction Stop
    Write-Host "PASS - DNS resolved google.com to $($dns[0].IPAddress)" -ForegroundColor Green
} catch {
    Write-Host "FAIL - DNS resolution failed. Check DNS server settings." -ForegroundColor Red
}

# 4. Internet Reachability
Write-Host "`n[4] Testing internet reachability (8.8.8.8)..." -ForegroundColor Yellow
$pingInternet = Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet
if ($pingInternet) { Write-Host "PASS - Internet is reachable." -ForegroundColor Green }
else { Write-Host "FAIL - No internet route. Possible ISP/firewall/router issue." -ForegroundColor Red }

# 5. Firewall Status
Write-Host "`n[5] Checking Windows Firewall status..." -ForegroundColor Yellow
Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize

# 6. Trace Route (only if internet failed, to locate the break point)
if (-not $pingInternet) {
    Write-Host "`n[6] Internet failed - running tracert to locate the break point..." -ForegroundColor Yellow
    tracert -h 15 8.8.8.8
}

# Save a simple summary object collection
$summaryObjects = @(
    [PSCustomObject]@{
        Timestamp         = Get-Date
        Gateway           = $gw
        GatewayStatus     = if ($pingGw) { 'Reachable' } else { 'Unreachable' }
        DNSStatus         = if ($dns) { 'Resolved' } else { 'Failed' }
        InternetStatus    = if ($pingInternet) { 'Reachable' } else { 'Unreachable' }
        TraceRouteRun     = if (-not $pingInternet) { 'Yes' } else { 'No' }
    }
)

if (Get-Command Export-ToCSV -ErrorAction SilentlyContinue) {
    Export-ToCSV -Data $summaryObjects -Path (Join-Path $logsDir "NetworkDiagnostic_Summary_$timestamp.csv") | Out-Null
}
if (Get-Command Export-ToJSON -ErrorAction SilentlyContinue) {
    Export-ToJSON -Data $summaryObjects -Path (Join-Path $logsDir "NetworkDiagnostic_Summary_$timestamp.json") | Out-Null
}
if (Get-Command New-HTMLReport -ErrorAction SilentlyContinue) {
    New-HTMLReport -Data $summaryObjects -Title "Network Diagnostic Summary" -Path (Join-Path $logsDir "NetworkDiagnostic_Summary_$timestamp.html") | Out-Null
}

Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host " Diagnostic complete. Review any FAIL/RED lines above first." -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Read-Host "Press Enter to close"
