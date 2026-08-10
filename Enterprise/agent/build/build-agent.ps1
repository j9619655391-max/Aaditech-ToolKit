# build-agent.ps1 - builds IT-Toolkit-Agent.exe (ps2exe) and stages config.
#
# The server endpoint + token are read from agent-config.json (produced by
# deploy.sh with the server's IP auto-detected) and baked into the exe.
#
# Prereqs (run on Windows, or a windows-latest CI job):
#   Install-Module ps2exe -Scope CurrentUser
#
# MScholtes/PS2EXE only works under Windows PowerShell 5.1 (it uses the .NET
# Framework compiler); under PowerShell 7 it fails. If we detect we're running
# under pwsh, we re-launch ourselves with the Windows PowerShell 5.1 engine.
#
# Outputs to Enterprise/agent/build/out/

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\agent-config.json",
    [string]$OutDir = "$PSScriptRoot\out"
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $ps51) {
        Write-Host "Running under PowerShell Core - re-invoking with Windows PowerShell 5.1 (required by ps2exe)"
        & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ConfigPath $ConfigPath -OutDir $OutDir
        exit $LASTEXITCODE
    }
    Write-Warning "PowerShell 5.1 not found ($ps51) - attempting ps2exe under PowerShell Core (may fail)"
}

if (-not (Test-Path $ConfigPath)) {
    throw "No agent-config.json found at $ConfigPath. Run Enterprise/deploy/deploy.sh on the server first (it generates this file with the server IP)."
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if ($config.endpoint -match 'CHANGE-ME') {
    throw "agent-config.json still has placeholder endpoint. Run deploy.sh first."
}

if (-not (Get-Module ps2exe -ListAvailable)) {
    throw "ps2exe module not installed. Run: Install-Module ps2exe -Scope CurrentUser"
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$source = Join-Path $PSScriptRoot '..\Agent-Collect.ps1'

Write-Host "Baking endpoint $($config.endpoint) into $source"
Invoke-PS2EXE -InputFile $source -OutputFile (Join-Path $OutDir 'IT-Toolkit-Agent.exe') -NoConsole

Copy-Item $ConfigPath (Join-Path $OutDir 'agent-config.json') -Force

Write-Host "Built: $OutDir\IT-Toolkit-Agent.exe"
Write-Host "Next: build the MSI from Enterprise/agent/wix (Enterprise/agent/wix/build-msi.ps1), or copy agent-config.json to ProgramData\ITToolkit-Agent\agent.json for manual install."
