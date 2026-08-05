<#
.SYNOPSIS
    Tests Windows Firewall status and connectivity to common ports.
.DESCRIPTION
    Checks if Windows Firewall is enabled/disabled, displays firewall rules status,
    tests connectivity to common ports (80, 443, 22, 3389, DNS), and saves a report.
    Report is saved to the Logs folder for ticket attachments.
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
$reportPath = Join-Path $logsDir "FirewallTest_$timestamp.txt"

Write-Host "Scanning Windows Firewall settings..." -ForegroundColor Cyan

# Collect firewall status for all profiles
try {
    $firewallStatus = Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
} catch {
    Write-Host "Error retrieving firewall status: $_" -ForegroundColor Red
    $firewallStatus = $null
}

# Count enabled firewall rules
try {
    $inboundRules = (Get-NetFirewallRule -Direction Inbound -Enabled $true | Measure-Object).Count
    $outboundRules = (Get-NetFirewallRule -Direction Outbound -Enabled $true | Measure-Object).Count
} catch {
    $inboundRules = "N/A"
    $outboundRules = "N/A"
}

Write-Host "Testing connectivity to common ports..." -ForegroundColor Cyan

# Test connectivity to common ports
$timeoutMs = 2000
if ($config -and $config.scriptParameters -and $config.scriptParameters.firewallTestTimeoutMs) {
    $timeoutMs = [int]$config.scriptParameters.firewallTestTimeoutMs
}

$testHosts = @(
    @{ Name = "Google DNS (UDP:53)"; Host = "8.8.8.8"; Port = 53; Protocol = "UDP" },
    @{ Name = "Cloudflare DNS (UDP:53)"; Host = "1.1.1.1"; Port = 53; Protocol = "UDP" },
    @{ Name = "HTTP (TCP:80)"; Host = "www.google.com"; Port = 80; Protocol = "TCP" },
    @{ Name = "HTTPS (TCP:443)"; Host = "www.google.com"; Port = 443; Protocol = "TCP" },
    @{ Name = "SSH (TCP:22)"; Host = "github.com"; Port = 22; Protocol = "TCP" },
    @{ Name = "RDP (TCP:3389)"; Host = "$env:COMPUTERNAME"; Port = 3389; Protocol = "TCP" }
)
if ($config -and $config.firewallTest -and $config.firewallTest.customPorts) {
    foreach ($custom in $config.firewallTest.customPorts) {
        if ($custom.name -and $custom.host -and $custom.port -and $custom.protocol) {
            $testHosts += [PSCustomObject]@{
                Name     = "$($custom.name) ($($custom.protocol):$($custom.port))"
                Host     = $custom.host
                Port     = [int]$custom.port
                Protocol = $custom.protocol
            }
        }
    }
}

$results = @()
foreach ($testHost in $testHosts) {
    try {
        if ($testHost.Protocol -eq "TCP") {
            $socket = New-Object System.Net.Sockets.TcpClient
            $iar = $socket.BeginConnect($testHost.Host, $testHost.Port, $null, $null)
            $wait = $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)
            if ($socket.Connected) {
                $status = "✓ OPEN"
                $socket.Close()
            } else {
                $status = "✗ TIMEOUT"
            }
        } else {
            # UDP test - try to send
            $udp = New-Object System.Net.Sockets.UdpClient
            $iar = $udp.BeginConnect($testHost.Host, $testHost.Port, $null, $null)
            $wait = $iar.AsyncWaitHandle.WaitOne(2000, $false)
            if ($wait) {
                $status = "✓ REACHABLE"
            } else {
                $status = "✗ TIMEOUT"
            }
            $udp.Close()
        }
    } catch {
        $status = "✗ ERROR"
    }
    
    $results += [PSCustomObject]@{
        Test = $testHost.Name
        Status = $status
    }
}

# Build report
$report = @()
$report += "=================================="
$report += "  IT TOOLKIT - FIREWALL REPORT"
$report += "=================================="
$report += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += "Computer: $env:COMPUTERNAME"
$report += ""
$report += "=== WINDOWS FIREWALL PROFILES ==="
if ($firewallStatus) {
    $report += ($firewallStatus | Format-Table -AutoSize | Out-String)
}
$report += ""
$report += "=== FIREWALL RULES COUNT ==="
$report += "Inbound Rules (Enabled):  $inboundRules"
$report += "Outbound Rules (Enabled): $outboundRules"
$report += ""
$report += "=== CONNECTIVITY TESTS ==="
$report += ($results | Format-Table -AutoSize | Out-String)
$report += ""
$report += "=== NOTES ==="
$report += "• OPEN/REACHABLE = port is accessible from this machine"
$report += "• TIMEOUT = no response (port blocked or service not running)"
$report += "• UDP tests may timeout on restricted networks (expected)"
$report += "• RDP test on localhost may fail if RDP service is disabled (expected)"

# Save report
$report -join "`n" | Out-File -FilePath $reportPath -Encoding UTF8

if (Get-Command Export-ToCSV -ErrorAction SilentlyContinue) {
    Export-ToCSV -Data $results -Path (Join-Path $logsDir "FirewallTest_Summary_$timestamp.csv") | Out-Null
}
if (Get-Command Export-ToJSON -ErrorAction SilentlyContinue) {
    Export-ToJSON -Data $results -Path (Join-Path $logsDir "FirewallTest_Summary_$timestamp.json") | Out-Null
}
if (Get-Command New-HTMLReport -ErrorAction SilentlyContinue) {
    New-HTMLReport -Data $results -Title "Firewall Connectivity Summary" -Path (Join-Path $logsDir "FirewallTest_Summary_$timestamp.html") | Out-Null
}

# Output location
Write-Host ""
Write-Host "Firewall test report saved to:" -ForegroundColor Green
Write-Host $reportPath -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to return to menu" -ForegroundColor Yellow
Read-Host