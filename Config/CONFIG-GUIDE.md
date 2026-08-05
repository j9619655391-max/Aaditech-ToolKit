# CONFIGURATION GUIDE

`Config/config.json` is the central settings file read by toolkit scripts.
All scripts default safely when a key is absent.

## Structure

| Section | Purpose | Adders |
|---------|---------|--------|
| `metadata` | Description, version | — |
| `paths` | Folder locations (relative to toolkit root) | Toolkit-Menu |
| `machines` | Known/example machines for RDP + reference | Remote-Tools |
| `network` | DNS, gateway, test hosts | Network-Diagnostic |
| `remoteAccess` | RDP/SSH toggles + ports | Remote-Tools |
| `remoteExecution` | WinRM port, SSL, timeout, vault, toolkit root | RemoteToolkit |
| `scriptDefaults` | Logging, admin-required mapping | LogManager |
| `alertThresholds` | Disk/mem/CPU thresholds | AlertEngine |
| `logRetention` | Log cleanup policy | LogManager |
| `scriptParameters` | Per-script timeouts | scripts |
| `eventLogSettings` | Event export sources/days/max | Export-EventLogs |
| `firewallTest` | Ports/protocols to test | Firewall-Test |
| `userInventory` | Report inclusions | User-Inventory |
| `security` | RDP/log/sanitize/encrypt toggles | various |
| `sanitization` | PII masking toggles (email/IP/account/hostname) | SanitizeEngine |
| `data` | SQLite database path | ToolkitData |
| `ui` | Output color/encoding | various |
| `knowledge_base` | KB file + categories | Toolkit-Menu |
| `notes` | Guidance | maintainers |

## New sections

- **`sanitization`** – toggle each masking rule used by
  `SanitizeEngine.psm1` (maskEmails, maskIPs, maskAccounts, maskHostnames).
  Disable a mask only for a trusted destination.
- **`data`** – `databasePath` locates the SQLite store used by
  `ToolkitData.psm1`. Relative paths resolve against the toolkit root.

## Safety rules

- **Never** store passwords/secrets here (it is plaintext and may be
  committed). Use `CredentialManager` (`Save-ToolkitCredential`).
- Relative paths are best; scripts resolve `$PSScriptRoot`/config root.
- Validate before committing: `Get-Content Config/config.json -Raw | ConvertFrom-Json`

## Validation

CI validates `config.json` on every run (JSON parse). Keeping this file
parseable and documented keeps all consumers healthy.