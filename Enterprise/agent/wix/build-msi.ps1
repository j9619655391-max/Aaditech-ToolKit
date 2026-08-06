# build-msi.ps1 - produces IT-Toolkit-Agent.msi.
#
# Stages the built agent exe, its config, and the toolkit files it wraps into
# wix\stage\ (the WXS references stage\...), then invokes WiX.
#
# Prereqs: WiX v5 toolset (`dotnet tool install --global wix --version "5.*"`).
# (WiX v7 requires accepting the OSMF EULA; v5 is MIT and uses the same v4 WXS schema.)
# Steps:
#   1. run Enterprise/agent/build/build-agent.ps1  (produces build/out/)
#   2. run this script                               (produces build/out/IT-Toolkit-Agent.msi)

[CmdletBinding()]
param(
    [string]$BuildOut = "$PSScriptRoot\..\build\out",
    [string]$WixDir = $PSScriptRoot,
    [string]$RepoRoot = "$PSScriptRoot\..\..\.."
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $BuildOut 'IT-Toolkit-Agent.exe'))) {
    throw "build/out/IT-Toolkit-Agent.exe missing. Run build-agent.ps1 first."
}
if (-not (Test-Path (Join-Path $BuildOut 'agent-config.json'))) {
    throw "build/out/agent-config.json missing. Run build-agent.ps1 first."
}

$Stage = Join-Path $WixDir 'stage'
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

Copy-Item (Join-Path $BuildOut 'IT-Toolkit-Agent.exe') (Join-Path $Stage 'IT-Toolkit-Agent.exe') -Force
Copy-Item (Join-Path $BuildOut 'agent-config.json') (Join-Path $Stage 'agent.json') -Force

# bundle the toolkit files the agent wraps (scripts + modules + config)
Copy-Item (Join-Path $RepoRoot 'Scripts') (Join-Path $Stage 'Scripts') -Recurse -Force
Copy-Item (Join-Path $RepoRoot 'Config')  (Join-Path $Stage 'Config')  -Recurse -Force

# bundle the support-engineer collectors (installed as <root>\Enterprise\agent\collectors\,
# same relative path the agent.json feature scripts use in the repo)
$collectors = Join-Path $RepoRoot 'Enterprise\agent\collectors'
if (Test-Path $collectors) {
    $stageCollectors = Join-Path $Stage 'Enterprise\agent\collectors'
    New-Item -ItemType Directory -Path $stageCollectors -Force | Out-Null
    Copy-Item (Join-Path $collectors '*.ps1') $stageCollectors -Force
}

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) { throw "WiX toolset not found. Install: dotnet tool install --global wix" }

# Run wix from the WXS directory so its relative Source paths (stage\...) resolve
# against the WXS location regardless of the caller's working directory.
Push-Location $WixDir
try {
    & $wix.Source build 'Agent.wxs' -o "$(Join-Path $BuildOut 'IT-Toolkit-Agent.msi')"
}
finally {
    Pop-Location
}

Write-Host "MSI built: $BuildOut\IT-Toolkit-Agent.msi"
Write-Host "Deploy with: msiexec /i IT-Toolkit-Agent.msi /qn   (or push via Intune/GPO/SCCM)"
