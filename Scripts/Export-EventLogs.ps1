<#
.SYNOPSIS
    Exports recent System + Application error/warning events to a text file
    you can attach directly to a ticket or share with a vendor/escalation team.
#>

$logDir = Join-Path $PSScriptRoot "..\Logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$file = Join-Path $logDir "EventExport_$stamp.txt"

$hours = Read-Host "How many hours back should I check? (default 24)"
if ([string]::IsNullOrWhiteSpace($hours)) { $hours = 24 }

"EVENT LOG EXPORT - Last $hours hours" | Out-File $file
"Generated: $(Get-Date) | Computer: $env:COMPUTERNAME" | Out-File $file -Append
"=================================================" | Out-File $file -Append

foreach ($log in @("System", "Application")) {
    "`n--- $log LOG (Errors + Warnings) ---" | Out-File $file -Append
    Get-WinEvent -FilterHashtable @{LogName=$log; Level=2,3; StartTime=(Get-Date).AddHours(-[int]$hours)} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Format-List | Out-File $file -Append
}

Write-Host "`nExported to: $file" -ForegroundColor Green
notepad.exe $file
