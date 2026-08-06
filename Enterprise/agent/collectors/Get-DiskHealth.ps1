# Get-DiskHealth.ps1 - disk health / SMART collector (kind: diskhealth)
# Enterprise/agent/collectors/ - emits one JSON object.
# Reports physical-disk health where available plus SMART failure prediction.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

$disks = @()
if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    $disks = @(Get-PhysicalDisk | ForEach-Object {
        [pscustomobject]@{
            Name               = $_.FriendlyName
            MediaType          = $_.MediaType
            SizeGB             = [math]::Round($_.Size / 1GB, 1)
            HealthStatus       = $_.HealthStatus
            OperationalStatus  = $_.OperationalStatus
            WearPercent        = if ($_.Type -eq 'SSD') { $_.Wear } else { $null }
        }
    })
} else {
    $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
        [pscustomobject]@{
            Name              = $_.Model
            MediaType         = 'Unknown'
            SizeGB            = [math]::Round($_.Size / 1GB, 1)
            HealthStatus      = 'Unknown'
            OperationalStatus = 'Unknown'
            WearPercent       = $null
        }
    })
}

$smart = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue)
$failures = @()
foreach ($s in $smart) {
    if ($s.PredictFailure) {
        $failures += [pscustomobject]@{
            Disk       = $s.InstanceName
            Reason     = $s.Reason
            Prediction = $s.PredictionFailure
        }
    }
}

[pscustomobject]@{
    disks             = $disks
    smart_failures    = $failures
    predicted_failure = (@($failures).Count -gt 0)
} | ConvertTo-Json -Compress -Depth 5
