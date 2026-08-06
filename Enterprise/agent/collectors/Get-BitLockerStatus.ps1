# Get-BitLockerStatus.ps1 - encryption status collector (kind: bitlocker)
# Enterprise/agent/collectors/ - volume encryption state (no keys, just state).

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    [pscustomobject]@{ available = $false; volumes = @() } | ConvertTo-Json -Compress
    exit 0
}

$volumes = @(Get-BitLockerVolume -ErrorAction SilentlyContinue |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage)

[pscustomobject]@{
    available = $true
    volumes   = $volumes
} | ConvertTo-Json -Compress -Depth 4
