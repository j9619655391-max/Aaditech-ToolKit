# IT Toolkit v2.0 — Frontend Audit

**Date:** 2026-08-05

## Scope

There is **no web frontend** in this repository. No React/Vue/Angular/Next.js code, no `package.json`, no bundler, no state-management library, and no client-side routing exist. The "frontend" of this tool is a **Windows batch-file menu** (`Toolkit-Menu.bat`) plus interactive PowerShell console output.

Per RULE #22: any metric that cannot be calculated is reported as **NOT MEASURABLE** rather than invented.

---

## Audit of the actual CLI "frontend"

### Toolkit-Menu.bat — CRITICAL DEFECT

- **File:** `Toolkit-Menu.bat`
- **Evidence:** The file contains 17 menu entries and 19 references to `%choice%` (lines 28-46) but **never reads user input**. There is no `set /p choice=` statement anywhere in the file (verified by grep: only `Setup-Wizard.bat` has `set /p` lines).
- **Function:** The master launcher is supposed to be the "front door" of the toolkit per `Documentation/Setup-Guide.md:11` ("MASTER LAUNCHER - double-click this first, every time").
- **Impact:** When a user double-clicks `Toolkit-Menu.bat`, the menu prints and immediately loops back via `goto menu` (line 48). No option can ever be selected. **The entire frontend menu is non-functional.**
- **Risk:** Critical — the primary entry point for all users is broken.
- **Suggested fix:** Add `set /p choice="Select an option: "` before the `if "%choice%"...` chain, add input validation, and only `goto menu` after executing.
- **Estimated effort:** 30 minutes
- **Priority:** P0

### Setup-Wizard.bat — Defects

- `Setup-Wizard.bat:269`: `Write-Host '✓ PowerShell v' + ([PSVersionTable].PSVersion.Major)` — `[PSVersionTable]` is **invalid syntax** (verified at runtime: `Unable to find type [PSVersionTable]`). Should be `$PSVersionTable`.
- `Setup-Wizard.bat:278`: `Get-ExecutionPolicy ... | Select-Object -ExpandProperty value` — `Get-ExecutionPolicy` returns a string, not an object with a `.value` property; the pipe fails.
- Impact: The "Test PowerShell Execution" (option 6) path produces errors or blank output.
- **Priority:** P1

### Console UX notes (minor)

- `QuickCheck.ps1` menu is clear and well-labeled (13 options). Good UX for a CLI tool.
- `Run-FullHealthCheck` writes a text report then opens Notepad automatically — acceptable UX.

---

## Frontend metrics

| Metric | Value |
|---|---|
| Web frontend | NOT MEASURABLE (does not exist) |
| Framework | None (Batch + PowerShell console) |
| Components/Hooks/Routing | 0 (N/A) |
| Accessibility | N/A |
| Dark mode / SEO / bundle size / lazy loading | N/A |

## Verdict

**NOT RELEASABLE.** The user-facing master menu is broken. A user cannot launch any tool through the documented primary entry point.
