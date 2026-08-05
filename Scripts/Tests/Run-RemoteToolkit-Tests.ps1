<#
Run-RemoteToolkit-Tests.ps1

Simple runner for RemoteToolkit tests. Usage:
  pwsh -File .\Run-RemoteToolkit-Tests.ps1

If Pester is not installed, this script will suggest installation instructions.
#>

#if running inside Windows PowerShell/Core, ensure Pester is available
if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
    Write-Host 'Pester not found. Install with: Install-Module -Name Pester -Scope CurrentUser' -ForegroundColor Yellow
    exit 2
}

#$PSScriptRoot is Tests folder; run Invoke-Pester against this file
Invoke-Pester -Script (Join-Path $PSScriptRoot 'RemoteToolkit.tests.ps1') -EnableExit