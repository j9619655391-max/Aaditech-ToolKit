# Agent-Collect.ps1 - IT-Toolkit Enterprise agent worker
# Part of IT-Toolkit Enterprise (Phase 3). Wraps EXISTING toolkit scripts
# WITHOUT modifying them: runs them, sanitizes output, queues locally, and
# ships to the enterprise server. This is the file packaged as
# IT-Toolkit-Agent.exe by ps2exe and installed by the MSI.

[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\ITToolkit-Agent\agent.json",
    [string]$QueueDb = "$env:ProgramData\ITToolkit-Agent\queue.sqlite3",
    [int]$LoopMinutes = 0,
    [switch]$CollectOnly,
    [switch]$FlushOnly,
    [switch]$ElevatedOnce
)

$ErrorActionPreference = 'Stop'

function Resolve-ToolkitRoot {
    # Installed layout:  <InstallRoot>\Scripts\Modules, <InstallRoot>\Config
    # Repo layout:       <repo>\Scripts\Modules,       <repo>\Config
    $candidates = @(
        (Join-Path $PSScriptRoot 'Scripts\Modules'),
        (Join-Path $PSScriptRoot '..\..\Scripts\Modules')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'SanitizeEngine.psm1')) {
            return Split-Path (Split-Path $c -Parent) -Parent   # <root>\Scripts\Modules -> <root>
        }
    }
    return $PSScriptRoot
}
$script:RepoRoot    = Resolve-ToolkitRoot
$script:ModulesPath = Join-Path $script:RepoRoot 'Scripts\Modules'

function Write-AgentLog {
    param([string]$Message)
    $dir = Split-Path $ConfigPath -Parent
    $logDir = Join-Path $dir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $logDir 'agent.log') -Value $line -ErrorAction SilentlyContinue
    Write-Verbose $line
}

# E4: whether THIS process is running with an elevated (admin) token. The
# routine scheduled task runs as NETWORK SERVICE (least privilege), so elevated
# collectors (bitlocker, licenses, printer-fix, user inventory…) only run under
# the on-demand elevated task; they are opt-in here and skipped otherwise.
function Test-IsElevated {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-ElevatedTaskRequestPath {
    return (Join-Path (Split-Path $ConfigPath -Parent) 'elevated-job.json')
}

# E4: hand an admin-required operation (msiexec self-upgrade, reboot) to the
# on-demand elevated task (ITToolkitAgentElevated). The main task is unprivileged,
# so any action that needs SYSTEM is staged as a small JSON request file and the
# elevated task is asked to run it once. Returns $true when the request was
# staged and the elevated task is available.
function Request-ElevatedJob {
    param(
        [string]$Action,
        [hashtable]$Payload = @{}
    )
    try {
        $req = [ordered]@{ action = $Action; requested = (Get-Date).ToString('o') } + $Payload
        ($req | ConvertTo-Json -Compress -Depth 6) | Set-Content (Get-ElevatedTaskRequestPath) -ErrorAction Stop
        # Ask the Task Scheduler for a one-time run of the elevated task. The
        # task is registered by the MSI as SYSTEM/Highest; if it is missing
        # (manual/dev installs) the request file alone keeps the operation
        # visible to any later elevated pass.
        try {
            (& schtasks.exe /run /tn ITToolkitAgentElevated 2>&1 | Out-Null)
            Write-AgentLog "Elevated task triggered for $Action"
        }
        catch { Write-AgentLog "Elevated task not triggered ($($_.Exception.Message)); request kept for next elevated pass" }
        return $true
    }
    catch {
        Write-AgentLog "Could not stage elevated request ($Action): $($_.Exception.Message)"
        return $false
    }
}

function Clear-ElevatedRequest {
    $p = Get-ElevatedTaskRequestPath
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

function Read-AgentConfig {
    if (-not (Test-Path $ConfigPath)) {
        throw "Agent config not found at $ConfigPath. Reinstall the MSI or run build-agent.ps1."
    }
    try { $cfg = (Get-Content $ConfigPath -Raw | ConvertFrom-Json) }
    catch { throw "Invalid agent.json: $($_.Exception.Message)" }

    # Registry override knob (A4): HKLM\SOFTWARE\ITToolkit\Agent\EndpointUrl
    # and/or ApiToken override agent.json at startup. This is what makes the
    # GPO/manual redirect real without a reinstall. Empty/missing values fall
    # back to the file.
    $regKey = 'HKLM:\SOFTWARE\ITToolkit\Agent'
    if (Test-Path $regKey) {
        $endpoint = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).EndpointUrl
        $token    = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).ApiToken
        if ($endpoint) { $cfg.endpoint = $endpoint; Write-AgentLog "Registry override: endpoint -> $endpoint" }
        if ($token)    { $cfg.token    = $token;    Write-AgentLog 'Registry override: token applied' }
    }
    return $cfg
}

# ---------------------------------------------------------------- mTLS client cert (hardening)
# When the config carries an enroll_url, the agent fetches a client-auth cert
# signed by the server's local CA once (bearer token auth) and then presents it
# to the agent mTLS endpoint (port 9443). Without enroll_url the agent keeps
# using plain bearer-token auth, so this is fully backward compatible.

function Get-ClientCertPath {
    param($Config)
    if (-not $Config.enroll_url) { return $null }
    $dir = Split-Path $ConfigPath -Parent
    return Join-Path $dir 'client.pfx'
}

function Get-AgentTokenPath {
    # B6: after enrolling, the agent stores its OWN per-agent token beside the
    # cert. That token replaces the shared fleet token for ingest/commands, so a
    # leaked fleet token can't impersonate every box.
    $dir = Split-Path $ConfigPath -Parent
    return Join-Path $dir 'agent.token'
}

function Get-AgentToken {
    # Prefer the per-agent token from enroll (B6); fall back to the shared
    # config token (bootstrap / pre-B6 agents).
    param($Config)
    $path = Get-AgentTokenPath
    if (Test-Path $path) {
        $tok = (Get-Content $path -Raw -ErrorAction SilentlyContinue).Trim()
        if ($tok) { return $tok }
    }
    return $Config.token
}

function Install-ServerCa {
    # The agent talks to the mTLS endpoint (https://<host>:9443) whose server
    # cert is signed by the server's INTERNAL CA. For Invoke-RestMethod to
    # accept that cert, the CA must be trusted on this machine. We install it
    # into the LocalMachine Root store (agent runs as SYSTEM) once. certutil
    # exits non-zero if the cert is already present, which is fine.
    param([string]$CaPem)
    if ([string]::IsNullOrWhiteSpace($CaPem)) { return }
    $dir = Split-Path $ConfigPath -Parent
    $caPath = Join-Path $dir 'ca.crt'
    try {
        [IO.File]::WriteAllText($caPath, $CaPem)
        & certutil.exe -addstore Root $caPath 2>&1 | Out-Null
        Write-AgentLog "Installed IT-Toolkit CA into LocalMachine\Root (server trust)"
    }
    catch {
        Write-AgentLog "CA trust install failed: $($_.Exception.Message)"
    }
}

function Ensure-ClientCert {
    param($Config)
    $pfx = Get-ClientCertPath -Config $Config
    if (-not $pfx) { return $null }
    $dir = Split-Path $ConfigPath -Parent
    $caPath = Join-Path $dir 'ca.crt'
    $tokenPath = Get-AgentTokenPath

    # If a CA was already bundled (e.g. copied by install.cmd) or previously
    # enrolled, make sure it is trusted before the first mTLS call. Pre-B6
    # agents have a cert but no per-agent token: re-enroll once (idempotent,
    # server keeps the same cert+token) so they get their own token too.
    if (Test-Path $pfx) {
        # C6: cert exists but is near expiry / missing token -> renew. The server
        # re-issues a fresh cert (issue_client_cert renews expiring ones), so we
        # drop the old cert and re-enroll below.
        if ((Test-ClientCertExpiry -PfXPath $pfx) -or (-not (Test-Path $tokenPath))) {
            Write-AgentLog "Client cert expired/near-expiry or token missing — renewing cert (C6)"
            Remove-Item $pfx -Force -ErrorAction SilentlyContinue
            Remove-Item $tokenPath -Force -ErrorAction SilentlyContinue
        }
        else {
            if (-not (Test-Path $caPath)) {
                $dir2 = Split-Path $pfx -Parent
                $cand = Join-Path $dir2 'ca.crt'
                if (Test-Path $cand) { Copy-Item $cand $caPath -Force }
            }
            if (Test-Path $caPath) { Install-ServerCa (Get-Content $caPath -Raw) }
            return $pfx
        }
    }

    Write-AgentLog "Enrolling for mTLS client cert from $($Config.enroll_url)"
    try {
        $resp = Invoke-RestMethod -Uri $Config.enroll_url -Method Get `
            -Headers @{ Authorization = "Bearer $($Config.token)" }
        if (-not $resp.pfx) { throw "enroll returned no pfx" }
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($resp.pfx))
        if ($resp.agent_token) {
            [IO.File]::WriteAllText($tokenPath, [string]$resp.agent_token)
            Write-AgentLog "Per-agent token persisted (B6)"
        }
        if ($resp.ca) {
            [IO.File]::WriteAllText($caPath, $resp.ca)
            Install-ServerCa $resp.ca
        }
        Write-AgentLog "Client cert saved to $pfx"
        return $pfx
    }
    catch {
        Write-AgentLog "mTLS enroll failed: $($_.Exception.Message) — falling back to bearer auth"
        return $null
    }
}

function Get-RestCertificate {
    param($Config)
    $pfx = Get-ClientCertPath -Config $Config
    if (-not $pfx -or -not (Test-Path $pfx)) { return $null }
    try { return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx) }
    catch { Write-AgentLog "Failed to load client cert: $($_.Exception.Message)"; return $null }
}

function Test-ClientCertExpiry {
    # C6: True when the persisted client cert is already expired or within the
    # renewal window (default 45 days). Near-expiry triggers a re-enroll so the
    # agent never gets stranded after mTLS cert expiry (Caddy needs client auth).
    param(
        [string]$PfXPath,
        [int]$RenewDays = 45
    )
    if (-not (Test-Path $PfXPath)) { return $true }  # missing -> (re)enroll
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfXPath)
        $daysLeft = ($cert.NotAfter - (Get-Date)).TotalDays
        Write-AgentLog ("Client cert " + $cert.NotAfter.ToString('yyyy-MM-dd') + " — " + [math]::Floor($daysLeft) + " days left")
        return ($daysLeft -le $RenewDays)
    }
    catch {
        # unreadable/corrupt -> treat as needing renewal
        Write-AgentLog "Client cert unreadable ($($_.Exception.Message)) — will re-enroll"
        return $true
    }
}

function Add-BundledSqliteToPath {
    # The MSI installs sqlite3.exe beside the agent exe so the queue works on
    # stock Windows (no system-wide SQLite needed). Prepend that directory to
    # PATH so the shared ToolkitData module's `sqlite3` lookup finds it.
    $candidates = @(
        $PSScriptRoot,
        (Join-Path $script:RepoRoot 'Scripts\Modules')
    ) | Select-Object -Unique
    foreach ($dir in $candidates) {
        $sqlite = Join-Path $dir 'sqlite3.exe'
        if (Test-Path $sqlite) {
            if ($env:PATH -split ';' -notcontains $dir) {
                $env:PATH = "$dir;$env:PATH"
            }
            return
        }
    }
    Write-AgentLog "sqlite3.exe not found beside the agent; relying on PATH"
}

function Import-ToolkitModules {
    # Reuse existing modules unchanged.
    Add-BundledSqliteToPath
    Import-Module (Join-Path $script:ModulesPath 'SanitizeEngine.psm1') -Force
    Import-Module (Join-Path $script:ModulesPath 'ToolkitData.psm1') -Force
}

function Initialize-Queue {
    if (-not (Test-Path (Split-Path $QueueDb -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path $QueueDb -Parent) -Force | Out-Null
    }
    $schema = @"
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  sanitized INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  status TEXT NOT NULL DEFAULT 'pending'
);
CREATE TABLE IF NOT EXISTS executed_commands (
  command_id   INTEGER PRIMARY KEY,
  status       TEXT NOT NULL,
  output       TEXT NOT NULL DEFAULT '',
  exit_code    INTEGER NOT NULL DEFAULT 0,
  executed_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
"@
    Invoke-SQLite -Query $schema -DatabasePath $QueueDb | Out-Null
}

# C5: at-most-once command execution. Once a command's result is computed it is
# recorded here; a re-delivered copy (poll window/5-min) is skipped — the agent
# re-posts the saved result instead of re-running it.
function Get-ExecutedCommand {
    param($CommandId)
    $json = Invoke-SQLite -Query "SELECT command_id, status, output, exit_code FROM executed_commands WHERE command_id = $CommandId;" -DatabasePath $QueueDb -AsJson 2>$null
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    $rows = @($json | ConvertFrom-Json)
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Record-ExecutedCommand {
    param([int]$CommandId, $Result)
    $esc = $Result.output.Replace("'", "''")
    Invoke-SQLite -Query @"
INSERT INTO executed_commands (command_id, status, output, exit_code) VALUES ($CommandId, '$($Result.status)', '$esc', $([int]$Result.exit_code))
ON CONFLICT(command_id) DO UPDATE SET status = excluded.status, output = excluded.output, exit_code = excluded.exit_code;
"@ -DatabasePath $QueueDb | Out-Null
}

function ConvertFrom-CollectorOutput {
    # Collectors (Enterprise/agent/collectors/*) emit one JSON object so the
    # server can build fleet panels. Anything that doesn't parse as JSON is
    # treated as plain text and wrapped in { text = ... } as before.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return ($Raw | ConvertFrom-Json) }
    catch { return $Raw }
}

function ConvertTo-JsonPayload {
    param([object]$Result)
    if ($null -eq $Result) { return (@{} | ConvertTo-Json -Compress) }
    if ($Result -is [string]) {
        $sanitized = ConvertTo-SanitizedText -Text $Result
        return (@{ text = $sanitized } | ConvertTo-Json -Compress)
    }
    $sanitized = $Result | Protect-SanitizedContent
    return ($sanitized | ConvertTo-Json -Compress -Depth 10)
}

function Invoke-AgentScript {
    param(
        [string]$ScriptPath,
        [int]$TimeoutSeconds = 300
    )
    # W7: feature scripts (QuickCheck, Network-Diagnostic, Export-EventLogs, ...)
    # contain interactive Read-Host prompts and some spawn GUI apps (notepad).
    # Under the Task Scheduler NETWORK SERVICE context there is no console, so a
    # Read-Host would block forever and stall the collection cycle. Run each
    # script in an isolated child PowerShell with stdin fed from NUL (EOF makes
    # any Read-Host return immediately) and a hard timeout, then return output.
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        (Get-Process -Id $PID).Path
    }
    $childArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-Command', "& `"$ScriptPath`" 2>&1 | Out-String")
    # Start-Process requires the redirected stdin file to already exist (EOF
    # means any Read-Host in the child returns immediately instead of hanging).
    $stdinFile = Join-Path $env:TEMP 'itk-agent-stdin.txt'
    $stdoutFile = Join-Path $env:TEMP 'itk-agent-stdout.txt'
    $stderrFile = Join-Path $env:TEMP 'itk-agent-stderr.txt'
    Set-Content -Path $stdinFile -Value '' -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $psExe -ArgumentList $childArgs -NoNewWindow `
        -RedirectStandardInput $stdinFile `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        throw "Script timed out after ${TimeoutSeconds}s: $ScriptPath"
    }
    $out = ''
    if (Test-Path $stdoutFile) { $out = Get-Content $stdoutFile -Raw }
    $err = ''
    if (Test-Path $stderrFile) { $err = Get-Content $stderrFile -Raw }
    Remove-Item $stdinFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "Script exited with code $($p.ExitCode): $ScriptPath $err" }
    return $out
}

function Invoke-AgentCollection {
    param($Config)
    $results = @()
    $endpoint = $Config.endpoint
    $token = $Config.token

    foreach ($feature in $Config.features) {
        if (-not $feature.enabled) { continue }
        # Phase A: the real-time metrics collector runs on its own fast cadence
        # (metrics_interval_seconds) via the dedicated sampling loop, so it is
        # NOT part of the slow inventory pass - that would only give one sample
        # per cycle. Skipping it here keeps a single sample per 60s stream.
        if ($feature.name -eq 'metrics') { continue }
        # E4: collectors needing elevation are opt-in. Under the least-privilege
        # NETWORK SERVICE task these run only when this process is elevated
        # (i.e. the on-demand elevated task, which reuses this same loop).
        $needsElev = [bool]$feature.requires_elevation
        if ($needsElev -and -not (Test-IsElevated)) {
            Write-AgentLog "Skipping $($feature.name): requires elevation (opt-in; runs only under the elevated task)"
            continue
        }
        $scriptPath = $feature.script
        if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
            $scriptPath = Join-Path $script:RepoRoot $feature.script
        }
        if (-not (Test-Path $scriptPath)) {
            Write-AgentLog "Skipping $($feature.name): script missing $scriptPath"
            continue
        }
        try {
            Write-AgentLog "Running $($feature.name) ($scriptPath)"
            $output = Invoke-AgentScript -ScriptPath $scriptPath
            $structured = ConvertFrom-CollectorOutput -Raw $output
            $payload = ConvertTo-JsonPayload -Result $structured
            Invoke-SQLite -Query "INSERT INTO outbox (kind, payload, sanitized) VALUES ('$($feature.name)', '$($payload.Replace("'","''"))', 1);" -DatabasePath $QueueDb | Out-Null
            $results += $feature.name
        }
        catch {
            Write-AgentLog "Collection failed for $($feature.name): $($_.Exception.Message)"
            # Still queue the error so the server sees agent health issues.
            $err = @{ feature = $feature.name; error = $_.Exception.Message } | ConvertTo-Json -Compress
            Invoke-SQLite -Query "INSERT INTO outbox (kind, payload, sanitized) VALUES ('agent-error', '$($err.Replace("'","''"))', 1);" -DatabasePath $QueueDb | Out-Null
        }
    }
    return $results
}

# ---------------------------------------------------------------- real-time metrics (Phase A)

function Get-MetricsCollectorPath {
    # The collector lives at the same relative path the feature manifest uses.
    $p = Join-Path $script:RepoRoot 'Enterprise\agent\collectors\Get-RealtimeMetrics.ps1'
    if (Test-Path $p) { return $p }
    Write-AgentLog 'Realtime metrics collector not found (Get-RealtimeMetrics.ps1)'
    return $null
}

function Get-MetricsIntervalSeconds {
    # Cadence knob for the fast metrics stream (default 60s). Independent of
    # interval_minutes which still drives the slow inventory pass.
    if ($Config.metrics_interval_seconds) { return [int]$Config.metrics_interval_seconds }
    return 60
}

function Invoke-MetricsSample {
    # Sample real-time metrics exactly once and enqueue it as kind=metrics.
    # Reuses the same outbox + sanitize path as the inventory collectors, so a
    # sample inherits queuing, dedup (client_msg_id), batching and backoff.
    $scriptPath = Get-MetricsCollectorPath
    if (-not $scriptPath) { return $false }
    try {
        $output = Invoke-AgentScript -ScriptPath $scriptPath -TimeoutSeconds 60
        $structured = ConvertFrom-CollectorOutput -Raw $output
        $payload = ConvertTo-JsonPayload -Result $structured
        Invoke-SQLite -Query "INSERT INTO outbox (kind, payload, sanitized) VALUES ('metrics', '$($payload.Replace("'","''"))', 1);" -DatabasePath $QueueDb | Out-Null
        return $true
    }
    catch {
        Write-AgentLog "Metrics sample failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-AgentHostname {
    foreach ($candidate in @($env:COMPUTERNAME, $env:HOSTNAME)) {
        if ($candidate) { return $candidate }
    }
    $hn = (& hostname 2>$null)
    if ($hn) { return $hn.Trim() }
    return 'unknown-host'
}

function Get-AgentIP {
    <#
    .SYNOPSIS
        Best-effort IPv4 address of this machine ('' on any failure so a flush
        can never be killed by IP discovery).
    #>
    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' } |
                Select-Object -First 1 -ExpandProperty IPAddress
            if ($ip) { return $ip }
        }
        # fallback: parse ifconfig/ipconfig output
        $raw = (& ifconfig 2>$null) -join "`n"
        if ($raw) {
            $m = [regex]::Match($raw, '(?m)inet (addr:)?(\d{1,3}(\.\d{1,3}){3})')
            if ($m.Success) {
                $cand = $m.Groups[2].Value
                if ($cand -notlike '127.*') { return $cand }
            }
        }
    } catch { }
    return ''
}

function Send-AgentHeartbeat {
    param($Config)
    # E1: lightweight liveness ping on the dedicated heartbeat route (same
    # mTLS origin as /ingest), so last_seen stays fresh even when the queue is
    # empty and there are no pending commands to poll.
    $body = @{
        hostname      = (Get-AgentHostname)
        os            = [System.Environment]::OSVersion.VersionString
        agent_version = (Get-InstalledAgentVersion)
        ip            = (Get-AgentIP)
    } | ConvertTo-Json -Compress
    $uri = "$(Get-CommandsApiRoot)/api/agent/heartbeat"
    $cert = Get-RestCertificate -Config $Config
    if ($cert) {
        Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body -Certificate $cert
    }
    else {
        Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body
    }
}

function Send-AgentBatch {
    param($Config)
    $pending = Invoke-SQLite -Query "SELECT id, kind, payload, sanitized, created_at FROM outbox WHERE status='pending' ORDER BY id ASC LIMIT 50;" -DatabasePath $QueueDb -AsJson
    if ([string]::IsNullOrWhiteSpace($pending)) { return 0 }

    $events = foreach ($row in ($pending | ConvertFrom-Json)) {
        @{
            kind         = $row.kind
            payload      = ($row.payload | ConvertFrom-Json)
            sanitized    = [bool]$row.sanitized
            client_msg_id = "$($env:COMPUTERNAME):$($row.id)"
            captured_at  = $row.created_at
        }
    }
    $body = @{
        hostname      = (Get-AgentHostname)
        os            = [System.Environment]::OSVersion.VersionString
        agent_version = (Get-InstalledAgentVersion)
        ip            = (Get-AgentIP)
        events        = @($events)
    } | ConvertTo-Json -Compress -Depth 12

    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            $resp = Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body -Certificate $cert
        }
        else {
            $resp = Invoke-RestMethod -Uri $Config.endpoint -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body
        }
        $ids = (@($pending | ConvertFrom-Json) | ForEach-Object { $_.id }) -join ','
        Invoke-SQLite -Query "UPDATE outbox SET status='delivered' WHERE id IN ($ids);" -DatabasePath $QueueDb | Out-Null
        $script:FlushBackoff = 0
        Write-AgentLog "Flushed batch: $($resp.accepted) events accepted"
        return $resp.accepted
    }
    catch {
        $script:FlushBackoff++
        $wait = Get-NextBackoffSleepSeconds -FailedConsecutive $script:FlushBackoff
        Write-AgentLog "Flush failed ($($_.Exception.Message)) — backoff run $($script:FlushBackoff); next retry in ~$wait s"
        Invoke-QueueSleep -SleepSeconds ([Math]::Min($wait, 15))
        return 0
    }
}

# ---------------------------------------------------------------- queue hygiene (E2)

# Bounded outbox no matter what the collectors enqueue. Delivery is
# best-effort: rows that age out while delivered keep the DB small, and a
# runaway collector can't grow the queue without bound. Retention/caps are read
# lazily so agent.json overrides (queue_retention_days, max_outbox_rows) apply
# even though they ship after $Config is loaded.

function Get-QueueRetentionDays {
    if ($Config.queue_retention_days) { return [int]$Config.queue_retention_days }
    return 7
}

function Get-MaxOutboxRows {
    if ($Config.max_outbox_rows) { return [int]$Config.max_outbox_rows }
    return 5000
}

function Prune-Queue {
    # E2: drop delivered rows past retention + cap total rows (oldest first).
    try {
        $retention = Get-QueueRetentionDays
        Invoke-SQLite -Query "DELETE FROM outbox WHERE status='delivered' AND created_at < datetime('now', '-$retention days');" -DatabasePath $QueueDb | Out-Null
        $count = Invoke-SQLite -Query "SELECT COUNT(*) AS n FROM outbox;" -DatabasePath $QueueDb -AsJson 2>$null
        $total = 0
        if ($count -and $count.Trim()) { $total = [int]((($count | ConvertFrom-Json) | Select-Object -First 1).n) }
        $max = Get-MaxOutboxRows
        if ($total -gt $max) {
            $excess = $total - $max
            Invoke-SQLite -Query "DELETE FROM outbox WHERE id IN (SELECT id FROM outbox ORDER BY id ASC LIMIT $excess);" -DatabasePath $QueueDb | Out-Null
            Write-AgentLog "Outbox size cap: pruned $excess oldest rows (total was $total)"
        }
    }
    catch { Write-AgentLog "Queue prune skipped: $($_.Exception.Message)" }
}

# Exponential backoff w/ jitter. State persists across cycles within one agent
# process; the server's per-agent outbox is unbounded so the client pacing here
# is what stops a thundering herd when the endpoint is degraded or down.
$script:FlushBackoff = 0

function Get-NextBackoffSleepSeconds {
    param([int]$FailedConsecutive)
    $base = 30          # seconds
    $cap  = 900         # 15 min
    if ($FailedConsecutive -lt 1) { return 0 }
    $exp = [Math]::Min($base * [Math]::Pow(2, $FailedConsecutive - 1), $cap)
    # jitter ±30% so many agents with the same failure don't stay synchronized.
    $jit = 0.7 + (Get-Random -Minimum 0 -Maximum 100) / 100.0 * 0.6
    return [Math]::Min([Math]::Round($exp * $jit), $cap)
}

function Invoke-QueueSleep {
    param($SleepSeconds)
    if ($SleepSeconds -gt 0) {
        Write-AgentLog "Backing off $SleepSeconds s after failure"
        Start-Sleep -Seconds $SleepSeconds
    }
}

# ------------------------------------------------------------------ self-update (E3)

function Get-InstalledAgentVersion {
    # Source of truth: HKLM stamp the MSI wrote at install time. Falls back to
    # the bundled config (pre-E3 agents / non-MSI installs).
    $v = $Config.agent_version
    try {
        $regKey = 'HKLM:\SOFTWARE\ITToolkit\Agent'
        if (Test-Path $regKey) {
            $stamp = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).Installed
            if ($stamp) { $v = [string]$stamp }
        }
    }
    catch { }
    return $v
}

function Get-AgentUpdateInfo {
    param($Config)
    $hn = [uri]::EscapeDataString((Get-AgentHostname))
    $uri = "$(Get-CommandsApiRoot)/api/agent/update?hostname=$hn"
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            return Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -Certificate $cert
        }
        else {
            return Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" }
        }
    }
    catch {
        Write-AgentLog "Update check failed: $($_.Exception.Message)"
        return $null
    }
}

function Update-AgentIfNeeded {
    param($Config)
    $info = Get-AgentUpdateInfo -Config $Config
    if ($null -eq $info) { return $false }
    $current = Get-InstalledAgentVersion
    if (-not $info.update_available) {
        Write-AgentLog "Agent is current ($current = $($info.target_version))"
        return $false
    }
    Write-AgentLog "Update available: $current -> $($info.target_version)"

    # Download the MSI (agent bearer token + client cert, same mTLS channel).
    $hn = [uri]::EscapeDataString((Get-AgentHostname))
    $uri = "$(Get-CommandsApiRoot)/api/agent/msi?hostname=$hn"
    $tmp = Join-Path $env:TEMP 'IT-Toolkit-Agent-update.msi'
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -OutFile $tmp -UseBasicParsing -Certificate $cert
        }
        else {
            Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -OutFile $tmp -UseBasicParsing
        }
        $size = (Get-Item $tmp).Length
        if ($size -lt 1KB) { throw "Download too small ($size bytes) — likely not an MSI" }
        Write-AgentLog "Downloaded $([math]::Round($size/1KB)) KB MSI -> $tmp"
    }
    catch {
        Write-AgentLog "MSI download failed: $($_.Exception.Message)"
        return $false
    }

    # Silent in-place upgrade. The task GUID/install folder are stable, so the
    # scheduled task keeps pointing at the same exe after the MSI is replaced.
    # msiexec /i needs an elevated token; the routine task is NETWORK SERVICE,
    # so an actual install is deferred to the on-demand elevated task (E4).
    if (-not (Test-IsElevated)) {
        $ok = Request-ElevatedJob -Action 'update'
        Write-AgentLog "MSI install requires elevation — staged for elevated task: $ok"
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $ok
    }
    try {
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$tmp`" /qn /norestart" -Wait -PassThru
        Write-AgentLog "msiexec exit code: $($p.ExitCode)"
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return ($p.ExitCode -eq 0)
    }
    catch {
        Write-AgentLog "MSI install failed: $($_.Exception.Message)"
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $false
    }
}

# ------------------------------------------------------------------ commands (P5)

function Get-CommandsApiRoot {
    # same origin as the ingest endpoint, minus the /ingest suffix
    return ($Config.endpoint -replace '/ingest\s*$', '')
}

function Get-PendingCommands {
    param($Config)
    $hn = [uri]::EscapeDataString((Get-AgentHostname))
    $uri = "$(Get-CommandsApiRoot)/api/commands/poll?hostname=$hn"
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -Certificate $cert
        }
        else {
            $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" }
        }
        return @($resp)
    }
    catch {
        Write-AgentLog "Command poll failed: $($_.Exception.Message)"
        return @()
    }
}

function Send-WakeOnLan {
    param([string]$Mac, [string]$TargetIp)
    $bytes = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    $parts = $Mac -split '[:-]'
    if ($parts.Count -ne 6) { throw "Invalid MAC address: $Mac" }
    $macBytes = @($parts | ForEach-Object { [Convert]::ToByte($_, 16) })
    for ($i = 0; $i -lt 16; $i++) { $bytes += $macBytes }
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        if ($TargetIp) { $client.Send($bytes, $bytes.Length, $TargetIp, 9) | Out-Null }
        else { $client.Send($bytes, $bytes.Length, '255.255.255.255', 9) | Out-Null }
    }
    finally { $client.Close() }
}

function Invoke-RemoteCommand {
    param($Config, $Cmd)
    $kind = $Cmd.kind
    $payload = $Cmd.payload
    switch ($kind) {
        'reboot' {
            $delay = [int]$payload.delay_seconds
            # E4: reboot needs SeShutdownPrivilege; the routine task runs as
            # NETWORK SERVICE, so defer to the on-demand elevated task.
            if (-not (Test-IsElevated)) {
                $ok = Request-ElevatedJob -Action 'reboot' -Payload @{ delay_seconds = $delay }
                return @{ status = if ($ok) { 'completed' } else { 'failed' }; output = 'Reboot deferred to elevated task (least privilege)'; exit_code = if ($ok) { 0 } else { 1 } }
            }
            if ($delay -gt 0) {
                & shutdown.exe /r /t $delay /f 2>&1 | Out-Null
            }
            else {
                Restart-Computer -Force -ErrorAction Stop
            }
            return @{ status = 'completed'; output = "Reboot issued (delay $delay s)"; exit_code = 0 }
        }
        'wake' {
            try {
                Send-WakeOnLan -Mac $payload.mac -TargetIp $payload.ip
                return @{ status = 'completed'; output = "Wake-on-LAN sent to $($payload.mac)"; exit_code = 0 }
            }
            catch {
                return @{ status = 'failed'; output = $_.Exception.Message; exit_code = 1 }
            }
        }
        'run-script' {
            $script = $payload.script
            if (-not $script) { return @{ status = 'failed'; output = 'No script specified'; exit_code = 1 } }
            # C5: agent-side allowlist defense-in-depth. Even if a rogue server
            # (or a replayed/mutated command) asks for a script, only scripts the
            # operator allowlisted at deploy time run here.
            $allow = @($Config.run_script_allowlist | Where-Object { $_ })
            if ($allow.Count -gt 0 -and $allow -notcontains $script) {
                return @{ status = 'failed'; output = "Script '$script' is not in the agent allowlist"; exit_code = 1 }
            }
            $path = Join-Path $script:RepoRoot $script
            if (-not (Test-Path $path)) { return @{ status = 'failed'; output = "Script not found: $script"; exit_code = 1 } }
            try {
                $out = (& $path 2>&1 | Out-String)
                return @{ status = 'completed'; output = $out; exit_code = $LASTEXITCODE }
            }
            catch {
                return @{ status = 'failed'; output = $_.Exception.Message; exit_code = 1 }
            }
        }
        default { return @{ status = 'failed'; output = "Unknown command kind: $kind"; exit_code = 1 } }
    }
}

function Send-CommandResult {
    param($Config, $CmdId, $Result)
    # C5: sanitize command output before it leaves the box (run-script output
    # can contain PII/keys). The SanitizeEngine module is already imported.
    $cleanOutput = $Result.output
    if (-not [string]::IsNullOrEmpty($cleanOutput)) {
        $cleanOutput = ConvertTo-SanitizedText -Text ([string]$cleanOutput)
    }
    $uri = "$(Get-CommandsApiRoot)/api/commands/$CmdId/result"
    $body = @{
        hostname  = (Get-AgentHostname)
        status    = $Result.status
        output    = $cleanOutput
        exit_code = $Result.exit_code
    } | ConvertTo-Json -Compress
    try {
        $cert = Get-RestCertificate -Config $Config
        if ($cert) {
            Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body -Certificate $cert | Out-Null
        }
        else {
            Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $(Get-AgentToken -Config $Config)" } -ContentType 'application/json' -Body $body | Out-Null
        }
        Write-AgentLog "Posted result for command $CmdId : $($Result.status)"
    }
    catch {
        Write-AgentLog "Result post failed for command $CmdId : $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ main

Import-ToolkitModules
Initialize-Queue
$Config = Read-AgentConfig

Write-AgentLog "Agent cycle start (endpoint: $($Config.endpoint))"

# mTLS: fetch the client cert once before the first endpoint call.
$null = Ensure-ClientCert -Config $Config

# E4: on-demand elevated task (-ElevatedOnce). Runs exactly one privileged
# cycle (elevated collectors run, self-upgrade installs, reboot is possible)
# then clears any staged elevated request. Never loops.
if ($ElevatedOnce) {
    Write-AgentLog "Elevated once run (privileged cycle)"

    # Perform any staged reboot. The routine (NETWORK SERVICE) task cannot
    # reboot, so it stages a request that this privileged pass consumes.
    $jobPath = Get-ElevatedTaskRequestPath
    if (Test-Path $jobPath) {
        try {
            $job = (Get-Content $jobPath -Raw | ConvertFrom-Json)
            if ($job.action -eq 'reboot') {
                $delay = [int]$job.delay_seconds
                if ($delay -gt 0) { & shutdown.exe /r /t $delay /f 2>&1 | Out-Null }
                else { Restart-Computer -Force -ErrorAction Stop }
                Write-AgentLog "Elevated reboot executed (delay $delay s)"
            }
        }
        catch { Write-AgentLog "Elevated reboot failed: $($_.Exception.Message)" }
    }

    Prune-Queue
    try { $null = Send-AgentHeartbeat -Config $Config }
    catch { Write-AgentLog "Heartbeat failed: $($_.Exception.Message)" }

    if (-not $CollectOnly -and -not $FlushOnly) { $null = Update-AgentIfNeeded -Config $Config }

    if (-not $FlushOnly) {
        $ran = Invoke-AgentCollection -Config $Config
        Write-AgentLog "Elevated collection: $($ran -join ', ')"
    }
    if (-not $CollectOnly) {
        $null = Send-AgentBatch -Config $Config
    }
    if (-not $FlushOnly -and -not $CollectOnly) {
        $cmds = Get-PendingCommands -Config $Config
        foreach ($cmd in $cmds) {
            if ($null -ne $cmd.id -and (Get-ExecutedCommand -CommandId $cmd.id)) {
                Write-AgentLog "Command $($cmd.id) already executed — skipping (at-most-once)"
                continue
            }
            $result = Invoke-RemoteCommand -Config $Config -Cmd $cmd
            if ($null -ne $cmd.id) { Record-ExecutedCommand -CommandId $cmd.id -Result $result }
            Send-CommandResult -Config $Config -CmdId $cmd.id -Result $result
        }
    }

    Clear-ElevatedRequest
    Write-AgentLog "Elevated once complete"
    exit 0
}

do {
    # E2: keep the outbox bounded (retention + size cap) once per cycle.
    Prune-Queue

    # E1: heartbeat every cycle — an idle agent (empty queue, no commands)
    # still updates last_seen, so the fleet view + agent-offline rule stay correct.
    try { $null = Send-AgentHeartbeat -Config $Config }
    catch { Write-AgentLog "Heartbeat failed (will retry next cycle): $($_.Exception.Message)" }

    # E3: staged self-upgrade. Runs best-effort each cycle; skips network work
    # when the server reports the installed version is already current.
    if (-not $CollectOnly -and -not $FlushOnly) {
        $null = Update-AgentIfNeeded -Config $Config
    }

    if (-not $FlushOnly) {
        $ran = Invoke-AgentCollection -Config $Config
        Write-AgentLog "Collected: $($ran -join ', ')"
    }

    if (-not $CollectOnly) {
        $sent = Send-AgentBatch -Config $Config
        Write-AgentLog "Sent: $sent events"
    }

    if (-not $FlushOnly -and -not $CollectOnly) {
        $cmds = Get-PendingCommands -Config $Config
        foreach ($cmd in $cmds) {
            if ($null -ne $cmd.id -and (Get-ExecutedCommand -CommandId $cmd.id)) {
                # C5: already ran on a previous cycle (poll re-delivered it while
                # the result post was in flight). Skip re-execution entirely.
                Write-AgentLog "Command $($cmd.id) already executed — skipping re-run (at-most-once)"
                continue
            }
            Write-AgentLog "Executing command $($cmd.id) kind=$($cmd.kind)"
            $result = Invoke-RemoteCommand -Config $Config -Cmd $cmd
            if ($null -ne $cmd.id) { Record-ExecutedCommand -CommandId $cmd.id -Result $result }
            Send-CommandResult -Config $Config -CmdId $cmd.id -Result $result
        }
        if (@($cmds).Count -gt 0) { Write-AgentLog "Executed $($cmds.Count) command(s)" }
    }

    Write-AgentLog "Agent cycle complete"

    if ($LoopMinutes -gt 0) {
        # Between inventory cycles, stream real-time metrics on their own fast
        # cadence. The scheduled task keeps running the exe every interval_minutes
        # and each run loops for ~its own duration, so we simply sample at
        # metrics_interval_seconds until the cycle window elapses - no scheduler
        # change needed and the inventory pass stays at interval_minutes.
        $metricsInt = Get-MetricsIntervalSeconds
        $windowEnd  = (Get-Date).AddMinutes($LoopMinutes)
        $jitter     = (Get-Random -Minimum -15 -Maximum 15) / 100.0
        while ((Get-Date) -lt $windowEnd) {
            if (-not $FlushOnly) {
                if (Invoke-MetricsSample) { Write-AgentLog "Metrics sample queued (every ${metricsInt}s)" }
            }
            if (-not $CollectOnly) {
                $sent = Send-AgentBatch -Config $Config
                if ($sent -gt 0) { Write-AgentLog "Metrics batch sent: $sent events" }
            }
            $remaining = ($windowEnd - (Get-Date)).TotalSeconds
            if ($remaining -le 0) { break }
            $sleep = [Math]::Min($metricsInt, $remaining)
            $sleep = [Math]::Max(1, [Math]::Round($sleep * (1 + $jitter)))
            Start-Sleep -Seconds $sleep
        }
    }
} while ($LoopMinutes -gt 0)
