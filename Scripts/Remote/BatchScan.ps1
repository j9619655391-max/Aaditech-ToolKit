<#
.SYNOPSIS
    Batch scan multiple remote machines using the IT Toolkit.
.DESCRIPTION
    Accepts a list of machines and invokes remote QuickCheck scans in parallel.
#>

param(
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerNames,

    [Parameter(Mandatory=$false)]
    [int]$MaxParallel = 5,

    [Parameter(Mandatory=$false)]
    [string]$ToolkitRoot,

    [Parameter(Mandatory=$false)]
    [switch]$UseSSL
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $scriptDir "..\..\Config\config.json"
if (-not $ToolkitRoot -and (Test-Path $configPath)) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($config.remoteExecution -and $config.remoteExecution.toolkitRoot) {
            $ToolkitRoot = $config.remoteExecution.toolkitRoot
        }
    } catch {
        Write-Warning "Unable to read remoteExecution.toolkitRoot from config.json: $_"
    }
}

if (-not $ToolkitRoot) { $ToolkitRoot = "C:\IT-Toolkit" }
if (-not $ComputerNames -or $ComputerNames.Count -eq 0) {
    $input = Read-Host 'Enter remote computer names or IPs (comma-separated)'
    $ComputerNames = $input -split '\s*,\s*' | Where-Object { $_ }
}

if (-not $ComputerNames -or $ComputerNames.Count -eq 0) {
    Write-Error 'No remote computers specified.'
    exit 1
}

$moduleDir = Join-Path $scriptDir "..\Modules"

if (Test-Path (Join-Path $moduleDir 'RemoteToolkit.psm1')) {
    Import-Module (Join-Path $moduleDir 'RemoteToolkit.psm1') -ErrorAction Stop
} else {
    Write-Error "RemoteToolkit module not found."
    exit 1
}

$credential = $null
if (Get-Command Get-ToolkitCredential -ErrorAction SilentlyContinue) {
    $credential = Get-ToolkitCredential -TargetName 'ITToolkitRemote'
}

Invoke-ParallelRemoteExecution -ComputerNames $ComputerNames -ScriptBlock {
    param($remoteRoot)
    $quickCheckScript = Join-Path $remoteRoot 'Scripts\QuickCheck.ps1'
    if (Test-Path $quickCheckScript) {
        & powershell -ExecutionPolicy Bypass -File $quickCheckScript
    } else {
        Write-Error "QuickCheck script not found at $quickCheckScript"
    }
} -Credential $credential -MaxParallel $MaxParallel -ArgumentList $ToolkitRoot
