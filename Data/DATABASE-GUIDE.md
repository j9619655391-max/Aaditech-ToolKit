# DATA LAYER GUIDE

The IT Toolkit data layer (Phase 2) stores structured inventory, diagnostics,
and audit data in a cross-platform **SQLite** database.

## Why SQLite

- **Zero-config** – the `sqlite3` command-line tool ships with Windows 10/11,
  macOS, and virtually every Linux distribution. No service, no setup.
- **Cross-platform** – the same module works on any machine with PowerShell +
  `sqlite3`. No .NET SQLite provider dependency.
- **Single file** – the whole database is one file you can copy for backup or
  attach to a ticket.

## Files

| Path | Purpose |
|------|---------|
| `Data/ToolkitData.sqlite3` | Active database (created at runtime; git-ignored) |
| `Scripts/Modules/ToolkitData.psm1` | Cross-platform SQLite wrapper module |
| `Data/README.txt` | Directory placeholder (keeps folder in git) |

> The database file is **not committed**. It is restored/generated on first use
> by `Initialize-ToolkitDatabase`.

## Schema

Table       | Purpose
------------|------------------------------------------
`schema_meta` | Key/value metadata
`inventory`   | Per-computer inventory snapshots (`computer_name`, `captured_at`, `payload` JSON)
`diagnostics` | Diagnostic results (`run_at`, `computer_name`, `kind`, `payload` JSON)

## Using the module

```powershell
Import-Module .\Scripts\Modules\ToolkitData.psm1

# 1. Ensure the database + schema exist (returns the DB path)
$db = Initialize-ToolkitDatabase

# 2. Store an inventory snapshot
Add-ToolkitInventoryRecord -ComputerName 'PC-01A' -InventoryObject @{ OS='Windows 11'; CPU='i7'; RAM=16 }

# 3. Read it back
Get-ToolkitInventory                 # all
Get-ToolkitInventory -ComputerName '01A'   # LIKE filter
Get-ToolkitInventory -Limit 10       # limit

# 4. Store a diagnostic result
Add-ToolkitDiagnostic -Kind 'network' -ComputerName 'PC-01A' -Result @{ ping='ok'; latency=2 }

# 5. Delete (destructive)
Remove-ToolkitData
```

Every function accepts `-DatabasePath` to target a non-default file (useful for
tests or isolated stores).

## Configuration

Add to `Config/config.json` to override the database location:

```json
"data": {
  "databasePath": "Data/ToolkitData.sqlite3"
}
```

Relative paths are resolved against the toolkit root. If omitted, the default
above is used.

## Integration points (roadmap)

The data layer is designed to be the persistence backbone for:
- `Scaling Plan/ARCHITECTURE.md` Phase 2 intelligence features
- Daily inventory history and drift reporting (vs. the transient
  `User-Inventory.ps1` text output)
- Diagnostic history so technicians can compare a machine over time

## Testing

Covered by `Scripts/Tests/Phase1-Regression.Tests.ps1` (test suite): the module
round-trips records against a temporary database when `sqlite3` is available.