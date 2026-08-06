# Get-WindowsUpdateStatus.ps1 - update compliance collector (kind: updatecompliance)
# Enterprise/agent/collectors/ - last successful update activity (best-effort
# without the WU API); pending-count is a helper for future WU integration.

[CmdletBinding()]
$ErrorActionPreference = 'SilentlyContinue'

$session = Get-CimInstance -Namespace root\Microsoft\Windows\WindowsUpdate `
    -ClassName MSFT_WUOperationsSession -ErrorAction SilentlyContinue |
    Sort-Object StartTime -Descending | Select-Object -First 1

$lastDate = $null
if ($session -and $session.EndTime) { $lastDate = $session.EndTime.ToString('yyyy-MM-dd HH:mm') }

$lastInstall = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties.Name -contains 'InstallDate' } |
    Sort-Object { $_.GetValue('InstallDate') } -Descending | Select-Object -First 1
$lastInstallDate = if ($lastInstall) { $lastInstall.GetValue('InstallDate') } else { $null }

[pscustomobject]@{
    last_session_end    = $lastDate
    last_session_result = $session.Result
    last_install_date   = $lastInstallDate
    pending_updates     = $null
} | ConvertTo-Json -Compress
