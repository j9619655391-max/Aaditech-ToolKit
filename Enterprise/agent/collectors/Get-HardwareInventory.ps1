# Get-HardwareInventory.ps1 - fleet hardware collector (kind: hardware)
# Enterprise/agent/collectors/ - runs on the client, emits one JSON object.
# Zero changes to the existing toolkit Scripts/ tree.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

function Get-BatteryWear {
    $bat = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $bat) { return $null }
    $designed = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $full = $bat.FullChargedCapacity
    if ($designed -and $designed.DesignedCapacity -gt 0) {
        $wear = [math]::Round((1 - $full / $designed.DesignedCapacity) * 100, 1)
        return @{ designed_mwh = $designed.DesignedCapacity; current_mwh = $full; wear_percent = $wear }
    }
    return @{ current_mwh = $full }
}

function Get-BatteryInfo {
    $info = Get-BatteryWear
    $charge = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($charge -and $charge.EstimatedChargeRemaining) {
        $info.charge_percent = [int]$charge.EstimatedChargeRemaining
        $info.status_code = $charge.BatteryStatus
        $info.status = switch ([int]$charge.BatteryStatus) {
            1 { 'discharging' } 2 { 'on-ac' } 3 { 'fully-charged' } 4 { 'low' } default { 'unknown' }
        }
    }
    return $info
}

$cs    = Get-CimInstance Win32_ComputerSystem
$bios  = Get-CimInstance Win32_BIOS
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$os    = Get-CimInstance Win32_OperatingSystem
$gpu   = Get-CimInstance Win32_VideoController | Select-Object -First 1
$ram   = Get-CimInstance Win32_PhysicalMemory
$ramGB = if ($ram) { [math]::Round((($ram | Measure-Object Capacity -Sum).Sum) / 1GB, 1) } else { 0 }
$disks = Get-CimInstance Win32_DiskDrive |
    Select-Object Model, SerialNumber, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }

[pscustomobject]@{
    manufacturer  = $cs.Manufacturer
    model         = $cs.Model
    serial        = $bios.SerialNumber
    bios_version  = $bios.SMBIOSBIOSVersion
    cpu           = $cpu.Name
    cores         = $cpu.NumberOfCores
    logical_cores = $cpu.NumberOfLogicalProcessors
    ram_total_gb  = $ramGB
    gpu           = $gpu.Name
    os            = $os.Caption
    os_version    = $os.Version
    disks         = @($disks)
    battery       = Get-BatteryInfo
} | ConvertTo-Json -Compress -Depth 6
