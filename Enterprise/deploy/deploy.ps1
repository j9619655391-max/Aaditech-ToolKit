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

# A7: restrict a secrets file to SYSTEM + Administrators (drop inherited Users
# read). Windows analogue of chmod 600 on the Unix deploy script.
function Set-SecretFileAcl {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        icacls $Path /inheritance:r /grant:r "SYSTEM:(R,W)" "Administrators:(R,W)" | Out-Null
        Log "Restricted ACL on $Path (SYSTEM + Administrators only)"
    }
    catch {
        Log "WARN: could not restrict ACL on $Path : $($_.Exception.Message)"
    }
}

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
POSTGRES_PASSWORD=$(New-Secret)
API_TOKEN=$(New-Secret)
SERVER_HOST=$HOST
CADDY_HOST=$CaddyHost
ENVIRONMENT=prod
BUILD_MODE=local_windows
"@ | Set-Content $EnvFile -Encoding utf8
}
else {
    # fix placeholders + ensure required keys exist.
    # NOTE: SESSION_SECRET is deliberately NOT set here — it is auto-generated
    # at first-time setup (POST /api/setup) and persisted under DATA_DIR so the
    # operator can download it once. Setting it via .env would win over that
    # file on restart and invalidate the downloaded key.
    foreach ($key in 'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'API_TOKEN', 'SERVER_HOST', 'CADDY_HOST', 'ENVIRONMENT', 'BUILD_MODE') {
        $hit = Get-Content $EnvFile | Where-Object { $_ -like "$key=*" } | Select-Object -First 1
        if (-not $hit) {
            $val = switch ($key) {
                'POSTGRES_DB' { 'ittoolkit' }
                'POSTGRES_USER' { 'ittoolkit' }
                'POSTGRES_PASSWORD' { New-Secret }
                'API_TOKEN' { New-Secret }
                'SERVER_HOST' { $HOST }
                'CADDY_HOST' { $CaddyHost }
                'ENVIRONMENT' { 'prod' }
                'BUILD_MODE' { 'local_windows' }
            }
            Add-Content $EnvFile "$key=$val"
            Log "Added missing $key to .env"
        }
        else {
            $val = $hit -replace "^$key=", ''
            if ($val -in @('', 'change-me', 'change-me-strong', 'change-me-random-token')) {
                $new = if ($key -in @('POSTGRES_DB', 'POSTGRES_USER', 'CADDY_HOST', 'ENVIRONMENT')) { $val } else { New-Secret }
                (Get-Content $EnvFile) -replace "^$key=.*", "$key=$new" | Set-Content $EnvFile
                Log "Regenerated placeholder $key"
            }
        }
    }
}
# remove any stale SESSION_SECRET line (management moved to setup-time rotation)
(Get-Content $EnvFile) | Where-Object { $_ -notlike 'SESSION_SECRET=*' } | Set-Content $EnvFile
Set-SecretFileAcl $EnvFile  # A7: .env holds API token + DB password

# load .env into the process so docker compose substitution works
foreach ($line in (Get-Content $EnvFile)) {
    if ($line -match '^([A-Z_]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
$env:CADDY_HOST = $CaddyHost

# ---------------------------------------------------------------- Caddyfile (B3)
# Render the per-mode Caddyfile from the template. Hostname/public deploys keep
# ACME auto-TLS on {$CADDY_HOST}; bare-IP deploys add an internal-CA TLS site on
# :443 (for agents/browsers that trust our CA) AND keep the plain :80 HTTP site
# so the first-time setup wizard works exactly as before the change.
$CaddyfileTpl = Join-Path $Here 'deploy\Caddyfile.template'
$CaddyfileOut = Join-Path $Here 'deploy\Caddyfile'
$mainSites = if ($Scheme -eq 'https') {
    Log "Caddyfile: ACME auto-TLS on $HOST (hostname mode)"
    '{0} {{
    encode gzip

    import main_routes
}}' -f '{$CADDY_HOST}'
}
else {
    Log "Caddyfile: :443 (internal CA TLS) + :80 (HTTP wizard) on $HOST"
    @'
:443 {
    encode gzip
    tls /agent_data/certs/server.crt /agent_data/certs/server.key
    import main_routes
}

:80 {
    encode gzip
    import main_routes
}
'@
}
$caddyfile = Get-Content $CaddyfileTpl -Raw
$caddyfile = $caddyfile.Replace('__URL_MAIN_SITES__', $mainSites)
# B4: gate API docs at the edge — proxy only when ENVIRONMENT=dev.
if ($env:ENVIRONMENT -eq 'dev') {
    $docsRule = @'
    reverse_proxy /api-docs* api:8000
    reverse_proxy /openapi.json api:8000
    reverse_proxy /redoc api:8000
    reverse_proxy /docs api:8000
'@
}
else {
    $docsRule = @'
    @docs path /docs /redoc /openapi.json /api-docs/*
    respond @docs 404
'@
    Log "Caddyfile: API docs blocked (ENVIRONMENT != dev)"
}
$caddyfile = $caddyfile.Replace('__DOCS_RULE__', $docsRule)
Set-Content -Path $CaddyfileOut -Value $caddyfile -Encoding utf8
Log "Caddyfile rendered -> deploy\Caddyfile"

# ---------------------------------------------------------------- agent config

$featuresJson = Get-Content (Join-Path $Here 'api\features.json') -Raw | ConvertFrom-Json
$features = @($featuresJson.features | ForEach-Object {
    [pscustomobject]@{
        name               = $_.name
        script             = $_.script
        enabled            = [bool]$_.default_enabled
        requires_elevation = [bool]$_.requires_elevation
    }
})

# Agent version + interval come from agent/agent-version.json (single source of
# truth, A2). Also copy it into the api build context so the running container
# can read the same values (bundle.py).
$AgentVersionJson = Join-Path $Here 'agent\agent-version.json'
$agentMeta = Get-Content $AgentVersionJson -Raw | ConvertFrom-Json
$AgentVersion = [string]$agentMeta.agent_version
$IntervalMinutes = [int]$agentMeta.interval_minutes
Copy-Item $AgentVersionJson (Join-Path $Here 'api\agent-version.json') -Force

# mTLS: agents always talk to the :9443 client-auth port (TLS via internal CA).
# enroll_url goes over the MAIN port because Caddy :9443 only routes /ingest and
# /api/commands/* (a fresh agent has no client cert yet to enroll over 9443).
$cfg = [ordered]@{
    endpoint = "https://$HOST`:9443/ingest"
    enroll_url = "$Scheme`://$HOST/api/agent/enroll"
    token = $env:API_TOKEN
    agent_version = $AgentVersion
    interval_minutes = $IntervalMinutes
    # C5: agent-side run-script allowlist (mirror of RUN_SCRIPT_ALLOWLIST).
    run_script_allowlist = @($env:RUN_SCRIPT_ALLOWLIST -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    features = $features
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigOut
Set-SecretFileAcl $ConfigOut  # A7: agent-config.json contains the API token
Log "Agent config written: $ConfigOut"
Log "  ingest endpoint : https://$HOST`:9443/ingest (mTLS)"
Log "  enroll_url      : $Scheme`://$HOST/api/agent/enroll"

# ---------------------------------------------------------------- bring up

# A5 (Caddy cert timing): Caddy :9443 (agent mTLS) needs server.crt/ca.crt,
# but Caddy FAILS to start when those files are missing. So we cannot start
# Caddy before setup. Instead: bring up db+api, generate the certs inside the
# api container (it owns /data/certs), then start Caddy. The wizard's later
# ensure_certs() is idempotent and keeps these files (SAN matches $HOST).

Log "Starting containers (db + api)"
Push-Location $Here
try {
    docker compose -f $ComposeFile up -d --build db api
}
finally { Pop-Location }

Log "Waiting for api health..."
# The api service is NOT port-published to the host (only caddy is, on
# 80/443/9443), so we probe its healthcheck inside the container instead of
# hitting localhost:8000 (which would always time out).
$apiHealthy = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        Push-Location $Here
        try {
            $probe = docker compose -f $ComposeFile exec -T api python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz',timeout=3)"
            if ($LASTEXITCODE -eq 0) { $apiHealthy = $true }
        }
        finally { Pop-Location }
        if ($apiHealthy) { break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $apiHealthy) { Die "api container never became healthy after 60s — check: docker compose -f $ComposeFile logs api" }

Log "Generating mTLS CA + server cert for $HOST (A5)"
Push-Location $Here
try {
    docker compose -f $ComposeFile exec -T api python -c "from app.certs import ensure_certs; ensure_certs('$HOST')"
}
finally { Pop-Location }

# Extract the CA to a temp file so openssl can verify the :9443 server cert.
$CaTemp = Join-Path $env:TEMP 'itk-ca-healthcheck.crt'
Push-Location $Here
try {
    docker compose -f $ComposeFile exec -T api cat /data/certs/ca.crt | Set-Content $CaTemp -NoNewline
}
finally { Pop-Location }

Log "Starting Caddy (certs now present)"
Push-Location $Here
try {
    docker compose -f $ComposeFile up -d caddy
}
finally { Pop-Location }

Log "Waiting for health (main + mTLS :9443)..."
$healthy = $false
for ($i = 0; $i -lt 30; $i++) {
    $mainOk = $false
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:80/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $mainOk = $true }
    } catch { }
    $mtlsOk = $false
    if ($mainOk) {
        $handshake = & openssl s_client -connect localhost:9443 -CAfile $CaTemp 2>&1
        if (($handshake -join "`n") -match 'Verify return code: 0') { $mtlsOk = $true }
    }
    if ($mainOk -and $mtlsOk) { $healthy = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $healthy) { Die "Server did not become healthy in 60s (main:$mainOk mTLS:$mtlsOk). Check: docker compose -f $ComposeFile ps" }

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
# build-msi.ps1 now emits a versioned artifact name.
$Msi = Join-Path $BuildOut "IT-Toolkit-Agent-$AgentVersion.msi"
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
    docker compose -f $ComposeFile cp $Msi api:/artifacts/IT-Toolkit-Agent.msi | Out-Null
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
