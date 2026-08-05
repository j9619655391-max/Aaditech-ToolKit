<#
Run-RemoteToolkit-Tests.ps1

Simple runner for RemoteToolkit tests. Usage:
  pwsh -File .\Run-RemoteToolkit-Tests.ps1

If Pester is not installed, this script will suggest installation instructions.
#>

#ensure Pester is available (works with Pester 5.x and 6.x)
if (-not (Get-Module -ListAvailable Pester -ErrorAction SilentlyContinue)) {
    Write-Host 'Pester not found. Install with: Install-Module -Name Pester -Scope CurrentUser' -ForegroundColor Yellow
    exit 2
}
Import-Module Pester
$testFile = Join-Path $PSScriptRoot 'RemoteToolkit.tests.ps1'

if ((Get-Module Pester).Version.Major -ge 6) {
    Invoke-Pester -Path $testFile            # Pester 6+: no -EnableExit (exit by result)
}
else {
    Invoke-Pester -Script $testFile -EnableExit
}