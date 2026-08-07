<#
deploy.ps1 - SaaS-style one-command bring-up for Windows Server.

Everything is auto-detected / auto-generated / auto-published. The ONLY manual
step is the browser setup page (company, admin, SMTP). Specifically this script:

  1. Detects this machine's LAN IP (or pins SERVER_HOST in .env).
  2. Generates .env secrets if missing (DB password, API token, session secret).
  3. Generates Enterprise/agent/agent-config.json with the mTLS endpoint
     (https://<IP>:9443/ingest) + enroll_url + token + live feature list baked in.
  4. docker compose up -d --build   (db + api + caddy)
  5. Waits for /healthz.
  6. Auto-generates the internal code-signing CA + cert if missing
     (Enterprise/agent/build/codesign/).
  7. Builds IT-Toolkit-Agent.exe (ps2exe) and IT-Toolkit-Agent.msi (WiX) ON THIS
     SERVER, then signs both with the internal CA.
  8. Publishes the signed MSI into the agent_artifacts volume so the portal
     serves it at /api/agent-msi (no CI, no GitHub needed).
  9. Prints the portal URL — the only remaining step is the setup wizard.

Prereqs (one-time, on the Windows Server):
  - Docker (Linux containers) + docker compose v2
  - PowerShell 5.1+ (or pwsh) — ships with Windows
  - Optional for signing: Windows SDK signtool (auto-warned if missing)

Usage:
  pwsh ./Enterprise/deploy/deploy.ps1          # bring up + build + publish
  pwsh ./Enterprise/deploy/deploy.ps1 -SkipBuild    # server only, build later
  pwsh ./Enterprise/deploy/deploy.ps1 -Regen        # regenerate secrets on a NEW machine

Idempotent: re-running only recreates changed containers; DB + secrets persist.
#>

[CmdletBinding()]
param(
    [switch]$Public,     # advertise the public IP instead of the LAN IP
    [switch]$Regen,      # delete .env and regenerate (move to a new machine)
    [switch]$SkipBuild   # bring up the server only; skip agent exe/msi build
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Here '.env'
$ConfigOut = Join-Path $Here 'agent\agent-config.json'
$ComposeFile = Join-Path $Here 'docker-compose.yml'
$RepoRoot = Split-Path -Parent $Here

function Log  { Write-Host "[deploy] $args" -ForegroundColor Cyan }
function Die  { Write-Host "[deploy][ERROR] $args" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- secrets / IP

function New-Secret {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

function Get-LanIp {
    $prefs = 'Ethernet', 'Ethernet0', 'Ethernet 2', 'Wi-Fi', 'Local Area Connection'
    $nic = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Sort-Object @{ Expression = {
            $name = $_.InterfaceAlias
            $idx = [Array]::IndexOf($prefs, $name)
            if ($idx -lt 0) { 100 } else { $idx }
        } } | Select-Object -First 1
    if ($nic -and $nic.IPv4Address) {
        return ($nic.IPv4Address | Select-Object -First 1).IPAddress
    }
    return $null
}

function Get-PublicIp {
    foreach ($src in @('https://api.ipify.org', 'https://ifconfig.me')) {
        try { return (Invoke-RestMethod -Uri $src -TimeoutSec 5).Trim() } catch { }
    }
    return $null
}

$Mode = 'lan'
if ($Public) { $Mode = 'public' }

if ($Regen -and (Test-Path $EnvFile)) {
    Log "--Regen: removing existing .env"
    Remove-Item $EnvFile -Force
}

$HOST = ''
if (Test-Path $EnvFile) {
    $line = (Get-Content $EnvFile | Where-Object { $_ -like 'SERVER_HOST=*' } | Select-Object -First 1)
    if ($line) {
        $val = $line -replace '^SERVER_HOST=', ''
        if ($val -and $val -ne 'auto') { $HOST = $val.Trim() }
    }
}

if (-not $HOST) {
    $ip = if ($Mode -eq 'public') { Get-PublicIp } else { Get-LanIp }
    if (-not $ip) { $ip = Get-PublicIp }
    if (-not $ip) { Die "Cannot detect server IP. Set SERVER_HOST=<host> in .env." }
    $HOST = $ip
    Log "Detected server address: $HOST (mode: $Mode)"
}

# scheme: bare IP -> http on the main port (Caddy :80); hostname -> https (:443)
$IsIp = $HOST -match '^\d{1,3}(\.\d{1,3}){3}$'
$Scheme = if ($IsIp) { 'http' } else { 'https' }
$CaddyHost = if ($IsIp) { ':80' } else { $HOST }
Log "Serving main portal on $Scheme`://$HOST/"

# ---------------------------------------------------------------- .env

if (-not (Test-Path $EnvFile)) {
    Log "Creating .env with generated secrets"
    @"
POSTGRES_DB=ittoolkit
POSTGRES_USER=ittoolkit
POSTGRES_PASSWORD=$(New-Secret)
API_TOKEN=$(New-Secret)
SESSION_SECRET=$(New-Secret)
SERVER_HOST=$HOST
CADDY_HOST=$CaddyHost
BUILD_MODE=local_windows
"@ | Set-Content $EnvFile -Encoding utf8
}
else {
    # fix placeholders + ensure required keys exist
    foreach ($key in 'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'API_TOKEN', 'SESSION_SECRET', 'SERVER_HOST', 'CADDY_HOST', 'BUILD_MODE') {
        $hit = Get-Content $EnvFile | Where-Object { $_ -like "$key=*" } | Select-Object -First 1
        if (-not $hit) {
            $val = switch ($key) {
                'POSTGRES_DB' { 'ittoolkit' }
                'POSTGRES_USER' { 'ittoolkit' }
                'POSTGRES_PASSWORD' { New-Secret }
                'API_TOKEN' { New-Secret }
                'SESSION_SECRET' { New-Secret }
                'SERVER_HOST' { $HOST }
                'CADDY_HOST' { $CaddyHost }
                'BUILD_MODE' { 'local_windows' }
            }
            Add-Content $EnvFile "$key=$val"
            Log "Added missing $key to .env"
        }
        else {
            $val = $hit -replace "^$key=", ''
            if ($val -in @('', 'change-me', 'change-me-strong', 'change-me-random-token')) {
                $new = if ($key -in @('POSTGRES_DB', 'POSTGRES_USER', 'CADDY_HOST')) { $val } else { New-Secret }
                (Get-Content $EnvFile) -replace "^$key=.*", "$key=$new" | Set-Content $EnvFile
                Log "Regenerated placeholder $key"
            }
        }
    }
}

# load .env into the process so docker compose substitution works
foreach ($line in (Get-Content $EnvFile)) {
    if ($line -match '^([A-Z_]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
$env:CADDY_HOST = $CaddyHost

# ---------------------------------------------------------------- agent config

$featuresJson = Get-Content (Join-Path $Here 'api\features.json') -Raw | ConvertFrom-Json
$features = @($featuresJson.features | ForEach-Object {
    [pscustomobject]@{ name = $_.name; script = $_.script; enabled = [bool]$_.default_enabled }
})

# mTLS: agents always talk to the :9443 client-auth port (TLS via internal CA).
# enroll_url goes over the MAIN port because Caddy :9443 only routes /ingest and
# /api/commands/* (a fresh agent has no client cert yet to enroll over 9443).
$cfg = [ordered]@{
    endpoint = "https://$HOST`:9443/ingest"
    enroll_url = "$Scheme`://$HOST/api/agent/enroll"
    token = $env:API_TOKEN
    agent_version = '1.0.0'
    interval_minutes = 30
    features = $features
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigOut
Log "Agent config written: $ConfigOut"
Log "  ingest endpoint : https://$HOST`:9443/ingest (mTLS)"
Log "  enroll_url      : $Scheme`://$HOST/api/agent/enroll"

# ---------------------------------------------------------------- bring up

Log "Starting containers (db + api + caddy)"
Push-Location $Here
try {
    docker compose -f $ComposeFile up -d --build
}
finally { Pop-Location }

Log "Waiting for health..."
$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:80/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $healthy = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $healthy) { Die "Server did not become healthy in 60s. Check: docker compose -f $ComposeFile ps" }

Write-Host ""
Write-Host "[deploy] Server is UP at $Scheme`://$HOST/" -ForegroundColor Green

if ($SkipBuild) {
    Write-Host "[deploy] -SkipBuild: agent exe/msi NOT built. Run without -SkipBuild to build+sign+publish."
    Write-Host "[deploy] Only manual step: open the setup wizard and enter company/admin/SMTP."
    exit 0
}

# ---------------------------------------------------------------- code-signing CA

$CodesignDir = Join-Path $Here 'agent\build\codesign'
$Pfx = Join-Path $CodesignDir 'IT-Toolkit-CodeSign-CA.pfx'
if (-not (Test-Path $Pfx)) {
    Log "Code-signing CA missing - generating now"
    $gen = Join-Path $Here 'agent\build\new-codesign-cert.ps1'
    if (-not (Test-Path $gen)) { Die "new-codesign-cert.ps1 not found at $gen" }
    & $gen
    if (-not (Test-Path $Pfx)) { Die "Code-signing CA generation failed" }
}
else {
    Log "Code-signing CA present ($Pfx)"
}

# ---------------------------------------------------------------- build exe + msi

if (-not (Get-Module ps2exe -ListAvailable)) {
    Log "Installing ps2exe module"
    Install-Module ps2exe -Scope CurrentUser -Force
}

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    Log "Installing WiX toolset (dotnet tool)"
    dotnet tool install --global wix --version "5.*"
    $env:Path = "$env:USERPROFILE\.dotnet\tools;$env:Path"
}

$BuildOut = Join-Path $Here 'agent\build\out'
Log "Building IT-Toolkit-Agent.exe + MSI"
& (Join-Path $Here 'agent\build\build-agent.ps1')
$env:Path = "$env:USERPROFILE\.dotnet\tools;$env:Path"
& (Join-Path $Here 'agent\wix\build-msi.ps1')

# ---------------------------------------------------------------- sign

$Exe = Join-Path $BuildOut 'IT-Toolkit-Agent.exe'
$Msi = Join-Path $BuildOut 'IT-Toolkit-Agent.msi'
if (Test-Path $Pfx) {
    $passFile = Join-Path $CodesignDir 'codesign-password.txt'
    $pass = if (Test-Path $passFile) { (Get-Content $passFile -Raw).Trim() } else { '' }

    # locate signtool (Windows SDK)
    $sdk = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $signtool = Get-ChildItem $sdk -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\d+\.\d+\.\d+\.\d+\\x64' } |
        Sort-Object FullName -Descending | Select-Object -First 1

    if ($signtool) {
        # import the internal root so `signtool verify` can validate the chain
        $rootCer = Join-Path $CodesignDir 'IT-Toolkit-CodeSign-Root.cer'
        if (Test-Path $rootCer) {
            Import-Certificate -FilePath $rootCer -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null
            Import-Certificate -FilePath $rootCer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($t in @($Exe, $Msi)) {
            if (Test-Path $t) {
                Log "Signing $t"
                & $signtool.FullName sign /f $Pfx /p $pass /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $t 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Log "WARNING: signtool failed on $t (timestamp host may be unreachable) - retrying without timestamp"
                    & $signtool.FullName sign /f $Pfx /p $pass /fd SHA256 $t 2>$null
                }
                & $signtool.FullName verify /pa /v $t 2>$null | Out-Null
            }
        }
    }
    else {
        Log "WARNING: signtool.exe not found (Windows SDK not installed) - artifacts left UNSIGNED."
        Log "  Install: winget install Microsoft.WindowsSDK (or full Visual Studio) then re-run."
    }
}
else {
    Log "WARNING: code-signing PFX missing - artifacts left UNSIGNED"
}

# ---------------------------------------------------------------- publish to portal

if (Test-Path $Msi) {
    Log "Publishing MSI into agent_artifacts volume (portal /api/agent-msi)"
    docker compose -f $ComposeFile cp $Msi api:/artifacts/ | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "docker compose cp failed - is the api container running?" }
    Log "MSI published."
}
else {
    Log "WARNING: no MSI produced - portal download not available"
}

# ---------------------------------------------------------------- done

Write-Host ""
Write-Host "[deploy] SaaS bring-up complete." -ForegroundColor Green
Write-Host "  Portal:       $Scheme`://$HOST/"
Write-Host "  MSI download: $Scheme`://$HOST/api/agent-msi (after setup, logged in)"
Write-Host ""
Write-Host "Only manual step: open the setup wizard (company, admin, SMTP)." -ForegroundColor Yellow
Write-Host "Build mode is pre-set to 'local_windows' (this server builds + signs + publishes the MSI)."
Write-Host "Agents: install the MSI or push via Intune/GPO/SCCM (msiexec /i IT-Toolkit-Agent.msi /qn)."
