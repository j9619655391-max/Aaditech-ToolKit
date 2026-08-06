# Get-SystemHealth.ps1 - runtime health collector (kind: health)
# Enterprise/agent/collectors/ - uptime, load, reboot-pending, critical services.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

$os    = Get-CimInstance Win32_OperatingSystem
$up    = (Get-Date) - $os.LastBootUpTime
$cpu   = Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average |
    Select-Object -ExpandProperty Average
$memPct = if ($os.TotalVisibleMemorySize -gt 0) {
    [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
} else { 0 }

$pending = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $pending = $true }

$crit = @(Get-Service | Where-Object { $_.Status -eq 'Stopped' -and $_.StartType -eq 'Automatic' } |
    Select-Object Name, DisplayName)

$temp = Get-CimInstance -Namespace root\cimv2 -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue |
    Select-Object -First 1
$tempC = if ($temp.CurrentTemperature) { [math]::Round(($temp.CurrentTemperature / 10) - 273.15, 1) } else { $null }

[pscustomobject]@{
    uptime_hours              = [math]::Round($up.TotalHours, 1)
    cpu_percent               = $cpu
    memory_percent            = $memPct
    temperature_celsius       = $tempC
    reboot_pending            = $pending
    critical_services_stopped = $crit
} | ConvertTo-Json -Compress -Depth 4
