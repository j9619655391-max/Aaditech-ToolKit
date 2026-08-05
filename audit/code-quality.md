# IT Toolkit v2.0 — Code Quality Audit

**Date:** 2026-08-05

---

## Critical defects (verified at runtime)

### CRIT-001 — `RemoteToolkit.psm1` parse error → module cannot import
- **File:** `Scripts/Modules/RemoteToolkit.psm1:38` (also 72, 118)
- **Code:** `$uri = if ($UseSSL) { "https://$ComputerName:$Port/wsman" } else { "http://$ComputerName:$Port/wsman" }`
- **Why it's a bug:** In PowerShell, `$ComputerName:` is parsed as a drive-qualified variable reference (like `$env:PATH`). Since `ComputerName` is not a registered PSDrive, this is a **parse/terminating error**.
- **Verified:** `Import-Module RemoteToolkit.psm1` → `RemoteToolkit FAILED TO IMPORT`. Error text: *"Variable reference is not valid. ':' was not followed by a valid variable name character. Consider using ${} to delimit the name."*
- **Fix:** Use `${ComputerName}:$Port` and `${computer}:$Port` and `${computer}:5986`.
- **Impact:** All Phase 2 remote execution is dead on arrival.
- **Effort:** 15 minutes. **Priority:** P0.

### CRIT-002 — `Toolkit-Menu.bat` never reads user input
- **File:** `Toolkit-Menu.bat` (whole file, lines 3-48)
- **Evidence:** 19 references to `%choice%` with zero `set /p choice=`. Grep across the repo shows `set /p` only in `Setup-Wizard.bat`.
- **Impact:** Master menu loops forever; no tool can be launched.
- **Effort:** 30 minutes. **Priority:** P0.

### CRIT-003 — `Firewall-Test.ps1` uses read-only automatic variable `$host` as loop variable
- **File:** `Scripts/Firewall-Test.ps1:107`
- **Code:** `foreach ($host in $testHosts) {`
- **Verified:** PowerShell raises `Cannot overwrite variable Host because it is read-only or constant.` (`$Host` is a read-only automatic variable.)
- **Impact:** The entire connectivity-test loop throws; script fails at runtime.
- **Fix:** Rename loop variable to `$testHost`.
- **Effort:** 5 minutes. **Priority:** P0.

### CRIT-004 — `Setup-Wizard.bat` invalid `[PSVersionTable]` syntax
- **File:** `Setup-Wizard.bat:269`
- **Verified:** `Unable to find type [PSVersionTable].` Should be `$PSVersionTable`.
- **Impact:** "Test PowerShell" path errors.
- **Effort:** 5 minutes. **Priority:** P1.

---

## High-severity issues

### CODE-001 — `Get-ToolkitCredential` regex uses single quotes (no interpolation)
- `Scripts/Modules/CredentialManager.psm1:53`: `if ($output -match 'Target: $TargetName')` — matches literal `$TargetName`, never matches. Function always returns `$null`. **Verified.**
- **Priority:** P1.

### CODE-002 — `Remove-OldLogs` deletes non-log files
- `Scripts/Modules/LogManager.psm1:56-59`. **Runtime-verified** deletion of `Logs/README.txt`.
- **Priority:** P1.

### CODE-003 — Duplicated `Resolve-ToolPath` + config loading block
- Appears identically in `QuickCheck.ps1:22-38`, `User-Inventory.ps1:22-38`, `Firewall-Test.ps1:22-38`, `Network-Diagnostic.ps1:23-39`. Four copies of the same bootstrap code. Extract to a `Toolkit.Common.psm1`.
- **Priority:** P2.

### CODE-004 — No input validation on remote hostnames / paths
- `RemoteToolkit.psm1` and `Scripts/Remote/*.ps1` accept arbitrary `ComputerName`/`ToolkitRoot` strings. Combine with `-ExecutionPolicy Bypass` → SEC-001.
- **Priority:** P1.

### CODE-005 — Test fragility / cross-version failure
- `Phase1-Regression.Tests.ps1:80,94` assert unquoted CSV header `Name,Value`, which PS7 quotes as `"Name","Value"`. Suite passes on Windows PowerShell 5.1 but fails on PowerShell 7. Use `ConvertFrom-Csv` instead of string regex.
- **Priority:** P1.

---

## Measured quality metrics (computed)

| Metric | Value |
|---|---|
| Total LOC (code: ps1/psm1/bat) | 2,368 (PowerShell) + 402 (Batch) = ~2,770 |
| Cyclomatic complexity | NOT MEASURABLE (no analyzer present; PowerShell complexity tooling not installed) |
| Maintainability index | NOT MEASURABLE |
| Code duplication (Resolve-ToolPath blocks) | 4 copies |
| God classes / long methods | `QuickCheck.ps1` `Run-FullHealthCheck` (~97 lines, 163-259) is a long method |
| Unused exports | `Export-ToExcel` in ExportEngine is exported but only used in tests; `Test-CredentialValid` exported but unused |
| Unused variables | `$wait` in Firewall-Test.ps1:112 assigned but not meaningfully used (minor) |
| Race conditions | None identified (single-threaded) |
| Blocking operations | `Start-Job`/`Wait-Job` in `Invoke-ParallelRemoteExecution` blocks; network tests block up to timeout |
| Memory leaks | None observed in code |

---

## Verdict

**CODE QUALITY: POOR.** Four critical defects (2 verified at runtime, 1 verified parse error, 1 verified input bug) make the two "Phase 2" modules and the master menu non-functional. The Phase 1 module layer is decently structured but has a doc-deletion bug and a failing test suite.
