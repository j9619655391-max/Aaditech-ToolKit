# IT Toolkit v2.0 — Backend Audit

**Date:** 2026-08-05
The "backend" of this project is the PowerShell script/module layer (21 `.ps1`/`.psm1` files, 2,368 lines).

---

## Layered review

| Layer | Files | Assessment |
|---|---|---|
| Controllers / Entry | `Toolkit-Menu.bat`, `Setup-Wizard.bat`, `Run-QuickCheck.bat` | **Menu is broken** (see CRIT-002) |
| Services (modules) | `Scripts/Modules/*.psm1` (6 modules) | See module-by-module below |
| Scripts (workflows) | `Scripts/*.ps1`, `Scripts/Remote/*.ps1`, `Remote-Tools/*.ps1` | See findings |
| Repositories | None | No data layer (flat-file only) |
| DTOs / Entities | `[PSCustomObject]` inline | Ad-hoc; no typing |
| Utilities | `Resolve-ToolPath` duplicated in 4 scripts | Duplication (see CRIT-008) |
| Dependency Injection | None | Modules loaded by direct path checks |
| Validation | Minimal `ValidateSet` on `AlertEngine` Type | Missing on hostnames/paths |
| Caching | None | N/A |
| Logging | `LogManager.psm1` + inline `Out-File` | Logs unencrypted; may contain PII |
| Error handling | `try/catch` with `Write-Error`/`Write-Warning` | Inconsistent (some errors silent) |
| Retry logic | None | Network scripts have no retry |

---

## Module-by-module findings

### AlertEngine.psm1 (Phase 1) — FUNCTIONAL
- Exports `Test-AlertThreshold`, `Get-AlertSeverity`, `Format-AlertMessage`, `Test-MultipleThresholds`.
- Verified working via runtime test (returns `Warning` for value 92/threshold 85 — see testing.md for the mismatch with the regression test's expectation).
- Severity model `Critical = Threshold + 10` is counterintuitive but consistent.

### ExportEngine.psm1 (Phase 1) — FUNCTIONAL
- `Export-ToCSV`, `Export-ToJSON`, `Export-ToExcel`. Runtime-verified working.
- Default path construction `Join-Path (Split-Path -Parent $script:ModulesPath) "..\Logs"` — works when Modules is `Scripts\Modules`, resolves to `Scripts\..\Logs` = `Logs`. OK.

### LogManager.psm1 (Phase 1) — BUG
- `Remove-OldLogs` deletes ALL files older than N days in the folder, including non-log files. **Runtime-proven**: running the test deleted `Logs/README.txt`.
- Filter by extension needed.

### ReportGenerator.psm1 (Phase 1) — FUNCTIONAL with dependency caveat
- `New-HTMLReport` uses `[System.Web.HttpUtility]::HtmlEncode`. Works when `System.Web` is available (verified OK on this pwsh). On minimal PowerShell Core installs the assembly may need explicit `Add-Type`. Minor portability caveat.

### RemoteToolkit.psm1 (Phase 2) — CRITICALLY BROKEN
- **Parse error at line 38**: `$uri = if ($UseSSL) { "https://$ComputerName:$Port/wsman" } else { "http://$ComputerName:$Port/wsman" }` — `$ComputerName:` is interpreted by PowerShell as a drive-qualified variable reference. **Verified: the module FAILS TO IMPORT** (`RemoteToolkit FAILED TO IMPORT`). Use `${ComputerName}:$Port`.
- Same pattern at line 72 (`"https://$ComputerName:5986/wsman"`) and line 118.
- Every Phase 2 script that imports this module (`BatchScan.ps1:49`, `Invoke-RemoteNetworkDiagnostic.ps1:38`, `Invoke-RemoteQuickCheck.ps1:38`) fails at import.

### CredentialManager.psm1 (Phase 2) — STUB
- `Get-ToolkitCredential` always returns `$null` (regex bug — single-quoted `$TargetName` never interpolates).
- `Store-ToolkitCredential` exposes password on cmdkey CLI (see SEC-002).

---

## Backend metrics (computed)

| Metric | Value |
|---|---|
| Controllers/entry points | 3 (1 broken) |
| Service modules | 6 (1 broken, 1 stub) |
| Workflow scripts | 11 (0 automated tests) |
| Duplicated `Resolve-ToolPath` | 4 occurrences (QuickCheck, User-Inventory, Firewall-Test, Network-Diagnostic) |
| Circular dependencies | None |
| DI container | None |
| Validation coverage | ~5 functions with `[ValidateSet]`; 0 on remote inputs |

## Verdict

**NOT PRODUCTION-READY.** One of the two Phase 2 modules is entirely non-importable; the other is a non-functional stub. Phase 1 modules work but have a doc-deletion bug and a test that contradicts its own assertions.
