<#
.SYNOPSIS
    Invoke Network Diagnostic on a remote machine.
.DESCRIPTION
    Uses the RemoteToolkit module to execute the Network-Diagnostic script on a remote host via WinRM.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ComputerName,

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
if (-not $ComputerName) { $ComputerName = Read-Host 'Enter remote computer name or IP' }

$moduleDir = Join-Path $scriptDir "..\Modules"

if (Test-Path (Join-Path $moduleDir 'RemoteToolkit.psm1')) {
    Import-Module (Join-Path $moduleDir 'RemoteToolkit.psm1') -ErrorAction Stop
} else {
    Write-Error "RemoteToolkit module not found in $moduleDir"
    exit 1
}

$credentials = $null
if (Get-Command Get-ToolkitCredential -ErrorAction SilentlyContinue) {
    $credentials = Get-ToolkitCredential -TargetName 'ITToolkitRemote'
}

Invoke-RemoteNetworkDiagnostic -ComputerName $ComputerName -ToolkitRoot $ToolkitRoot -Credential $credentials -UseSSL:$UseSSL
