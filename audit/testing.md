# IT Toolkit v2.0 — Testing Audit

**Date:** 2026-08-05
**Method:** Executed the actual test suites with PowerShell 7 (`pwsh`). Results below are from real runs, not assumptions.

---

## Test Inventory (discovered, not assumed)

| Test file | Type | Framework | Status |
|---|---|---|---|
| `Scripts/Tests/Phase1-Regression.Tests.ps1` | Regression (custom harness) | Custom `Assert-True` functions | **3 FAILURES** |
| `Scripts/Tests/RemoteToolkit.tests.ps1` | Pester | Pester `Describe`/`It` | **Broken (cannot run)** |
| `Scripts/Tests/Run-RemoteToolkit-Tests.ps1` | Runner | `Invoke-Pester` | Runner only |

**Total test files discovered:** 5 (including runner + README, 3 are actual test content)
**Coverage tooling:** None present. No coverage measurement exists.

---

## Empirical Result — `Phase1-Regression.Tests.ps1`

Executed with `pwsh -NoProfile -File Scripts/Tests/Phase1-Regression.Tests.ps1`:

```
PASS: CSV export file created
FAIL: CSV output contains header row
PASS: JSON export file created
PASS: JSON output contains two objects
PASS: Excel-compatible CSV export file created
FAIL: Excel-compatible output contains header row
PASS: New-HTMLReport file created
PASS: HTML report title included
PASS: HTML report contains a table
FAIL: Disk threshold returns Critical
PASS: Disk alert IsAlert is true
PASS: Get-AlertSeverity returns Warning
PASS: Old log file removed
PASS: Recent log file preserved
>>> Some tests failed. (exit 1)
```

**3 failures confirmed:**

1. **CSV header check fails (x2).** `Phase1-Regression.Tests.ps1:80` asserts `$content[0] -match 'Name,Value'`. PowerShell 7's `Export-Csv` writes `"Name","Value"` (quoted), so the regex `Name,Value` does not match `"Name","Value"`. This is a **test bug** (fragile assertion), not an export bug. It fails on PowerShell 7 and passes on Windows PowerShell 5.1 — a cross-version inconsistency.

2. **Alert threshold returns Warning instead of Critical.** `Phase1-Regression.Tests.ps1:120` calls `Test-AlertThreshold -Type 'Disk' -Value 92 -Threshold 85` and asserts `Severity -eq 'Critical'`. The function (`AlertEngine.psm1:62-66`) computes `Critical = Min(100, Threshold + 10) = 95`; value 92 < 95 → returns `Warning`. **The test's expectation is wrong** (or the default severity model is surprising). Either the test or the function default must change; currently they disagree.

---

## Empirical Result — `RemoteToolkit.tests.ps1`

**This suite cannot pass in its current form:**

- `RemoteToolkit.tests.ps1:31` calls `Test-RemoteConnection -ComputerName 'invalid-host.example.local' -TimeoutSeconds 3`. The `Test-RemoteConnection` function (`RemoteToolkit.psm1:20-47`) only defines parameters `ComputerName`, `Port`, `UseSSL` — **there is no `-TimeoutSeconds` parameter**. The call would throw a parameter-binding error, not return `$false`.
- Additionally, **`RemoteToolkit.psm1` fails to import at all** (parse error at line 38 — see code-quality report CRIT-001), so `Import-Module` on line 8 silently fails (`-ErrorAction SilentlyContinue`) and `Get-Command Invoke-RemoteCommand` throws.

**Net:** the Phase 2 remote test suite is non-functional.

---

## What is NOT tested

- `Network-Diagnostic.ps1` — no automated tests
- `Printer-Fix.ps1` — no automated tests
- `Export-EventLogs.ps1` — no automated tests
- `User-Inventory.ps1` — no automated tests
- `Firewall-Test.ps1` — no automated tests (and it contains a runtime-breaking `$host` loop variable bug — see code-quality)
- `Pin-QuickAccess-Folders.ps1` — no automated tests
- `Generate-RDP-Shortcuts.ps1` — no automated tests
- `Toolkit-Menu.bat` — no automated tests (contains a critical no-input bug — see code-quality CRIT-002)
- `Setup-Wizard.bat` — no automated tests (contains invalid `[PSVersionTable]` syntax — see code-quality)

---

## Metrics (computed)

| Metric | Value |
|---|---|
| Unit tests present | 2 files (1 broken, 1 has 3 failures) |
| Integration tests | 0 |
| E2E tests | 0 |
| Test count (total `It`/asserts) | ~14 assertions in Phase1; 5 `It` blocks in RemoteToolkit |
| Passing | 11 / 14 (Phase1) |
| Failing | 3 / 14 (Phase1) |
| Skipped | 0 |
| Coverage measurement | **NOT MEASURABLE** (no coverage tooling installed/configured) |
| CI execution | NONE (no CI config exists) |

## Verdict

**NOT TEST-READY.** The one passing suite contradicts its own documented claim ("All Phase 1 regression tests passed") in `Scripts/README.md` and `audit/ledger.json`. A regression suite with 3 known failures and a second suite that cannot execute means the project cannot claim test coverage. **Testing score must reflect this.**
