# ToolkitData.psm1 - Cross-platform SQLite data layer for IT Toolkit
# Part of IT Toolkit - Phase 2 (data persistence)

<#
.SYNOPSIS
    Persistent storage structured inventory, diagnostics, and audit data
    using SQLite.

.DESCRIPTION
    Wraps the `sqlite3` command-line client (present on Windows, macOS, Linux)
    so the module works anywhere PowerShell is installed without a .NET SQLite
    provider. Default database: <repo>/Data/ToolkitData.sqlite3, overridable via
    Config/config.json -> data.databasePath.

.NOTES
    Author: IT Toolkit Team
    Version: 1.0
    Part of: Phase 2 Implementation
#>

$script:ModulesPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:ModulesPath)

function Get-ToolkitData {
    <#
    .SYNOPSIS
        Resolves the active SQLite database path (config override or default).
    #>
    $configPath = Join-Path $script:RepoRoot 'Config/config.json'
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.data -and $cfg.data.databasePath) {
                $p = $cfg.data.databasePath
                if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:RepoRoot $p }
                return $p
            }
        } catch { }
    }
    $dataDir = Join-Path $script:RepoRoot 'Data'
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    return Join-Path $dataDir 'ToolkitData.sqlite3'
}

function Test-SQLiteBinary {
    <#
    .SYNOPSIS
        Returns $true when the `sqlite3` command is available.
    #>
    return [bool](Get-Command sqlite3 -ErrorAction SilentlyContinue)
}

function Invoke-SQLite {
    <#
    .SYNOPSIS
        Runs a single SQL batch and returns the raw sqlite3 output string.

    .PARAMETER Query
        SQL text to execute.

    .PARAMETER DatabasePath
        Override database path (defaults to configured store).

    .PARAMETER AsJson
        When set, uses sqlite3 -json so SELECT returns JSON text.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][string]$DatabasePath,
        [Parameter(Mandatory=$false)][switch]$AsJson
    )
    if (-not (Test-SQLiteBinary)) { throw 'sqlite3 not found on PATH. Install SQLite to use ToolkitData.' }
    $db = if ($DatabasePath) { $DatabasePath } else { (Get-ToolkitData) }
    $parent = Split-Path $db -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $args = if ($AsJson) { @('-json', $db, $Query) } else { @($db, $Query) }
    $output = & sqlite3 @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 error: $($output -join ' ')" }
    if ($AsJson) { return ($output -join "`n") }   # coalesce lines into one JSON doc
    return $output
}

function Initialize-ToolkitDatabase {
    <#
    .SYNOPSIS
        Ensures the SQLite schema exists (idempotent; safe to run repeatedly).

    .DESCRIPTION
        Creates tables:
          schema_meta    - key/value metadata
          inventory      - inventory snapshots per computer
          diagnostics    - text/JSON diagnostic results
    .OUTPUTS
        Full path to the database file.
    #>
    param(
        [Parameter(Mandatory=$false)][string]$DatabasePath
    )
    $db = if ($DatabasePath) { $DatabasePath } else { (Get-ToolkitData) }
    if (-not (Test-Path (Split-Path $db -Parent))) { New-Item -ItemType Directory -Path (Split-Path $db -Parent) -Force | Out-Null }
    $schema = @"
CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS inventory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  computer_name TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  payload TEXT
);
CREATE TABLE IF NOT EXISTS diagnostics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_at TEXT DEFAULT (datetime('now')),
  computer_name TEXT,
  kind TEXT,
  payload TEXT
);
"@
    Invoke-SQLite -Query $schema -DatabasePath $db | Out-Null
    return $db
}

function Add-ToolkitInventoryRecord {
    <#
    .SYNOPSIS
        Inserts an inventory snapshot for a computer.

    .PARAMETER ComputerName
        Machine name the snapshot belongs to.

    .PARAMETER InventoryObject
        Object (or hashtable) to persist as JSON payload.

    .PARAMETER DatabasePath
        Optional override for the database file (defaults to configured store).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][object]$InventoryObject,
        [Parameter(Mandatory=$false)][string]$DatabasePath
    )
    $db = Initialize-ToolkitDatabase -DatabasePath $DatabasePath
    $json = ($InventoryObject | ConvertTo-Json -Compress -Depth 10).Replace("'", "''")
    $name = $ComputerName.Replace("'", "''")
    Invoke-SQLite -Query "INSERT INTO inventory (computer_name, captured_at, payload) VALUES ('$name', datetime('now'), '$json');" -DatabasePath $db | Out-Null
    return $true
}

function Get-ToolkitInventory {
    <#
    .SYNOPSIS
        Returns stored inventory records.

    .PARAMETER ComputerName
        Optional LIKE filter on computer name.

    .PARAMETER Limit
        Max rows to return (default 100).

    .PARAMETER DatabasePath
        Optional override for the database file (defaults to configured store).
    #>
    param(
        [Parameter(Mandatory=$false)][string]$ComputerName,
        [Parameter(Mandatory=$false)][int]$Limit = 100,
        [Parameter(Mandatory=$false)][string]$DatabasePath
    )
    $db = Initialize-ToolkitDatabase -DatabasePath $DatabasePath
    $sql = 'SELECT id, computer_name AS computerName, captured_at AS capturedAt, payload FROM inventory'
    if ($ComputerName) {
        $esc = $ComputerName.Replace("'", "''")
        $sql += " WHERE computer_name LIKE '%$esc%'"
    }
    $sql += " ORDER BY captured_at DESC LIMIT $Limit;"
    $jsonText = Invoke-SQLite -Query $sql -DatabasePath $db -AsJson
    if ([string]::IsNullOrWhiteSpace($jsonText)) { return @() }
    try { return ConvertFrom-Json $jsonText } catch { return @() }
}

function Add-ToolkitDiagnostic {
    <#
    .SYNOPSIS
        Stores a diagnostic result.

    .PARAMETER ComputerName
        Machine the diagnostic pertains to (may be empty).

    .PARAMETER Kind
        Short label/type of diagnostic (e.g. network, eventlog, inventory).

    .PARAMETER Result
        Object/string result to store.

    .PARAMETER DatabasePath
        Optional override for the database file (defaults to configured store).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$false)][string]$ComputerName = '',
        [Parameter(Mandatory=$false)][object]$Result,
        [Parameter(Mandatory=$false)][string]$DatabasePath
    )
    $db = Initialize-ToolkitDatabase -DatabasePath $DatabasePath
    $payload = if ($Result -is [string]) { $Result.Replace("'", "''") } else { ($Result | ConvertTo-Json -Compress -Depth 8).Replace("'", "''") }
    $kind = $Kind.Replace("'", "''")
    $comp = $ComputerName.Replace("'", "''")
    Invoke-SQLite -Query "INSERT INTO diagnostics (computer_name, kind, payload) VALUES ('$comp', '$kind', '$payload');" -DatabasePath $db | Out-Null
    return $true
}

function Remove-ToolkitData {
    <#
    .SYNOPSIS
        Deletes the toolkit SQLite database (destructive).
    #>
    param([Parameter(Mandatory=$false)][string]$DatabasePath)
    $db = if ($DatabasePath) { $DatabasePath } else { (Get-ToolkitData) }
    if (Test-Path $db) { Remove-Item $db -Force -ErrorAction SilentlyContinue }
    @($db, "$db-wal", "$db-shm") | ForEach-Object { if (Test-Path $_) { Remove-Item $_ -Force -ErrorAction SilentlyContinue } }
    return $true
}

Export-ModuleMember -Function Get-ToolkitData, Initialize-ToolkitDatabase, Add-ToolkitInventoryRecord, Get-ToolkitInventory, Add-ToolkitDiagnostic, Remove-ToolkitData, Test-SQLiteBinary, Invoke-SQLite