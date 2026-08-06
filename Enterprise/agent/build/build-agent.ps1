# build-agent.ps1 - builds IT-Toolkit-Agent.exe (ps2exe) and stages config.
#
# The server endpoint + token are read from agent-config.json (produced by
# deploy.sh with the server's IP auto-detected) and baked into the exe.
#
# Prereqs (run on Windows, or a windows-latest CI job):
#   Install-Module ps2exe -Scope CurrentUser
#
# Outputs to Enterprise/agent/build/out/

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\agent-config.json",
    [string]$OutDir = "$PSScriptRoot\out"
)

$ErrorActionPreference = 'Stop'

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
Write-Host "Next: build the MSI from Enterprise/agent/wix (see wix/README.md), or copy agent-config.json to ProgramData\ITToolkit-Agent\agent.json for manual install."
