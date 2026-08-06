# Get-SoftwareInventory.ps1 - installed software collector (kind: software)
# Enterprise/agent/collectors/ - emits one JSON object.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

$apps = @(
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
) | Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName -Unique

[pscustomobject]@{
    count = @($apps).Count
    apps  = @($apps)
} | ConvertTo-Json -Compress -Depth 4
