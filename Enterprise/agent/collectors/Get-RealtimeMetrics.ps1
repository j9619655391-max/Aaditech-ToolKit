# Get-RealtimeMetrics.ps1 - real-time resource metrics collector (kind: metrics)
# Enterprise/agent/collectors/ - sampled on its own fast cadence (agent.json
# metrics_interval_seconds, default 60s) by Agent-Collect.ps1, separately from
# the slower inventory collectors. Emits ONE JSON object per sample.
#
# Payload shape (stable keys the portal + rollup render from):
#   cpu, cpu_per_core [], mem_pct, mem_used_gb, mem_total_gb, temp_celsius,
#   disks[{drive,total_gb,free_gb,used_pct,read_bps,write_bps}],
#   net[{iface,rx_bps,tx_bps}],
#   gpu_util, gpu_vram_pct (best-effort; null when unavailable),
#   battery_pct, battery_status (null on desktops without a battery).

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

# One batched Get-Counter call is far cheaper at a 60s cadence than 6 separate
# calls. If any counter path is missing (e.g. no GPU engines), the whole call
# fails and we degrade to nulls rather than throwing everything away.
$samples = @()
try {
    $samples = @((Get-Counter -Counter @(
        '\Processor(*)\% Processor Time',
        '\LogicalDisk(*)\Disk Read Bytes/sec',
        '\LogicalDisk(*)\Disk Write Bytes/sec',
        '\Network Interface(*)\Bytes Received/sec',
        '\Network Interface(*)\Bytes Sent/sec',
        '\GPU Engine(*)\Utilization Percentage'
    ) -ErrorAction Stop).CounterSamples)
}
catch { $samples = @() }

$perCore = @($samples |
    Where-Object { $_.Path -like '\Processor(*)\% Processor Time' -and $_.InstanceName -ne '_total' } |
    Select-Object -ExpandProperty CookedValue |
    ForEach-Object { [math]::Round($_, 1) })

$diskRead  = @{}
$diskWrite = @{}
foreach ($s in $samples) {
    if     ($s.Path -like '\LogicalDisk(*)\Disk Read Bytes/sec')  { $diskRead[$s.InstanceName]  = $s.CookedValue }
    elseif ($s.Path -like '\LogicalDisk(*)\Disk Write Bytes/sec') { $diskWrite[$s.InstanceName] = $s.CookedValue }
}

$netRx = @{}
$netTx = @{}
foreach ($s in $samples) {
    if     ($s.Path -like '\Network Interface(*)\Bytes Received/sec') { $netRx[$s.InstanceName] = $s.CookedValue }
    elseif ($s.Path -like '\Network Interface(*)\Bytes Sent/sec')     { $netTx[$s.InstanceName] = $s.CookedValue }
}

$gpuVals = @($samples |
    Where-Object { $_.Path -like '*\GPU Engine(*)\Utilization Percentage' } |
    Select-Object -ExpandProperty CookedValue)
$gpuUtil = if ($gpuVals.Count) { [math]::Round(($gpuVals | Measure-Object -Maximum).Maximum, 1) } else { $null }

$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$totalKB = [double]$os.TotalVisibleMemorySize
$freeKB  = [double]$os.FreePhysicalMemory
$memPct    = if ($totalKB -gt 0) { [math]::Round(($totalKB - $freeKB) / $totalKB * 100, 1) } else { 0 }
$memUsedGB = if ($totalKB -gt 0) { [math]::Round(($totalKB - $freeKB) / 1MB, 1) }            else { 0 }
$memTotalGB= if ($totalKB -gt 0) { [math]::Round($totalKB / 1MB, 1) }                        else { 0 }

$temp = Get-CimInstance -Namespace root\cimv2 -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue |
    Select-Object -First 1
$tempC = if ($temp.CurrentTemperature) { [math]::Round(($temp.CurrentTemperature / 10) - 273.15, 1) } else { $null }

$disks = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    $total = [double]$_.Size
    $free  = [double]$_.FreeSpace
    $d = $_.DeviceID
    [pscustomobject]@{
        drive      = $d
        total_gb   = if ($total) { [math]::Round($total / 1GB, 1) } else { $null }
        free_gb    = if ($free)  { [math]::Round($free  / 1GB, 1) } else { $null }
        used_pct   = if ($total -gt 0) { [math]::Round(($total - $free) / $total * 100, 1) } else { $null }
        read_bps   = [long](($diskRead[$d]  | Select-Object -First 1))
        write_bps  = [long](($diskWrite[$d] | Select-Object -First 1))
    }
})

$net = @($netRx.Keys | Where-Object { $_ -and $_ -like '*' -and $_ -notlike 'Loopback*' -and $_ -notlike 'isatap*' } | ForEach-Object {
    [pscustomobject]@{
        iface  = $_
        rx_bps = [long]$netRx[$_]
        tx_bps = [long]$netTx[$_]
    }
})

$batteryPct    = $null
$batteryStatus = $null
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bat) {
    $batteryPct = if ($bat.EstimatedChargeRemaining) { [int]$bat.EstimatedChargeRemaining } else { $null }
    $batteryStatus = switch ([int]$bat.BatteryStatus) {
        1 { 'discharging' } 2 { 'on-ac' } 3 { 'fully-charged' } 4 { 'low' } default { 'unknown' }
    }
}

[pscustomobject]@{
    cpu           = if ($null -ne $cpu) { [math]::Round([double]$cpu.LoadPercentage, 1) } else { 0 }
    cpu_per_core  = $perCore
    mem_pct       = $memPct
    mem_used_gb   = $memUsedGB
    mem_total_gb  = $memTotalGB
    temp_celsius  = $tempC
    disks         = $disks
    net           = $net
    gpu_util      = $gpuUtil
    gpu_vram_pct  = $null
    battery_pct   = $batteryPct
    battery_status= $batteryStatus
} | ConvertTo-Json -Compress -Depth 6