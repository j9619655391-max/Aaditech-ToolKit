<#
.SYNOPSIS
    One-click printer troubleshooting: restarts spooler, clears stuck jobs,
    and lists installed printers with their status.
.NOTE
    Must be run as Administrator (right-click > Run with PowerShell as Administrator)
    because it stops/starts a Windows service.
#>

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Please re-run this script as Administrator." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "              PRINTER QUICK FIX                   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Write-Host "`n[1] Stopping Print Spooler service..." -ForegroundColor Yellow
Stop-Service -Name Spooler -Force
Start-Sleep -Seconds 2

Write-Host "[2] Clearing stuck print jobs..." -ForegroundColor Yellow
$spoolPath = "$env:SystemRoot\System32\spool\PRINTERS\*"
Remove-Item -Path $spoolPath -Force -ErrorAction SilentlyContinue
Write-Host "    Cleared." -ForegroundColor Green

Write-Host "[3] Starting Print Spooler service..." -ForegroundColor Yellow
Start-Service -Name Spooler
Start-Sleep -Seconds 2
$status = (Get-Service -Name Spooler).Status
Write-Host "    Spooler status: $status" -ForegroundColor Green

Write-Host "`n[4] Installed printers and status:" -ForegroundColor Yellow
Get-Printer | Format-Table Name, DriverName, PortName, PrinterStatus -AutoSize

Write-Host "`nIf the issue persists, check:" -ForegroundColor Cyan
Write-Host " - Is the printer reachable? Test-Connection <printer-ip>"
Write-Host " - Is the correct driver installed? (see Get-Printer output above)"
Write-Host " - Try removing and re-adding the printer port"
Read-Host "`nPress Enter to close"
