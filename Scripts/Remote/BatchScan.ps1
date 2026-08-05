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
    if (-not $remoteRoot -or $remoteRoot.Trim() -eq '') {
        throw 'ToolkitRoot must not be empty.'
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($remoteRoot)
    $quickCheckPath = Join-Path $resolvedRoot 'Scripts/QuickCheck.ps1'
    $fullPath = [System.IO.Path]::GetFullPath($quickCheckPath)
    $scriptsDir = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot 'Scripts'))
    $isInside = $fullPath -eq $scriptsDir -or $fullPath.StartsWith($scriptsDir + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isInside) {
        throw "Refusing to execute script outside toolkit Scripts directory: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "QuickCheck script not found at $fullPath"
    }
    & $fullPath
} -Credential $credential -MaxParallel $MaxParallel -ArgumentList $ToolkitRoot
